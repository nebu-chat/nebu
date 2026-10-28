defmodule Nebu.Compliance.AuditWriter do
  require Logger

  @moduledoc """
  Generic audit log writer. Every call to log/6 or log/7 inserts exactly one
  row into `audit_log` via a separate Repo.transaction/1 — never inside the
  caller's transaction. A caller rollback cannot suppress the audit record.

  Carve-out (epic oauth-broker, security review F-6; extended by the OAuth switch `Nebu.OAuth.save_switch/2` and by the privileged admin config saves
  `Nebu.Admin.DB.save_config_audited/2`, story admin-config-audit-atomic, which also call `log/6` inside the save's own transaction): the admin DCR decisions of `Nebu.OAuth`
  (`approve_registration/3`, `reject_registration/3`; actions `oauth_client_approved` /
  `oauth_client_rejected`) and the admin bulk removal of pending registrations
  (`bulk_remove_pending/3`; action `oauth_clients_bulk_removed`) deliberately call `log/6` INSIDE
  the decision / deletion transaction (`Nebu.OAuth.ClientStore.decide/3`, `bulk_delete_pending/3`): `Repo.transaction/1` nests there, so the audit row and the
  status UPDATE commit or roll back TOGETHER — a decision is never unaudited and an audit row
  never describes a decision that did not happen. A failure raised by the nested insert rolls the
  decision back (the caller turns `{:error, _}` into `Repo.rollback/1`). `Nebu.Media.Config.upsert/3` does the same for the three media retention values
  (`released_delete_after_days`, `deleted_days`, `infected_days`; story media-retention-audit-atomic): it calls `log/6` (action `media_config_updated`) inside the
  transaction of the value upsert; a refused SHORTENING rolls the value back, a lengthening is retried once without the row (its caller wraps `log/6` in a
  try / rescue because only a RuntimeError is rescued here). Every other caller keeps
  the rule above.

  Error policy: never raises. On DB failure returns {:error, :audit_write_failed}
  and logs via Logger.error/2.

  Persistenz-Strategie: Option C — Stateless. No GenServer state, no queue.
  Each log/6 call is atomic in its own Repo.transaction/1.

  Story 5.29c — AC8 (FB-52-02): unknown action strings are rejected with
  {:error, :audit_unknown_action} before any DB call. The @known_actions
  allowlist covers all Epic-5 vocabulary. Adding a new audit action requires
  updating this list first.
  """

  alias Nebu.Compliance.AuditLogEntry

  # AC8 (Story 5.29c): allowlist of all valid audit action strings in Epic 5.
  # compliance_session_revoked was added by Story 5.29c (AC2).
  # user_deactivated, user_reactivated, update_user_role added for Epic 9 (Story 9.1 HIGH-1 fix).
  # member_added, member_removed added for admin-initiated room membership (room-management rm4).
  # room_visibility_changed added for admin room-visibility toggle (room-management rm1).
  # enable_temporary_capture, disable_temporary_capture added for the Trace Map's
  # off-by-default long-polling endpoints (enhanced-logging/trace-map-node-controls,
  # AC12 Option B — ANSWERED design question 2): enabling collection on a
  # previously-off endpoint is an admin-initiated logging-policy change.
  # media_config_updated added for media-security-admin-control/
  # 9a-media-config-table-module (AC6) — every successful Nebu.Media.Config.upsert/2
  # writes one of these. For the three retention values (released_delete_after_days, deleted_days, infected_days) the row is written INSIDE the
  # transaction of the value upsert (story media-retention-audit-atomic, see the carve-out in the moduledoc); every other key stays best-effort.
  # media_storage_config_updated added for media-security-admin-control/
  # 11a-storage-config-schema-secrets (AC9) — every successful
  # Nebu.Media.StorageConfig.upsert/1 writes one of these.
  # media_infected_detected, media_scan_failed added for media-security-admin-control/
  # 4c-infected-scanfailed-audit-bridge (AC1/AC3) — Nebu.Workers.MediaScanWorker
  # bridges its :infected / :scan_failed media_state_transitions writes into the
  # global audit_log via these two actions.
  # media_blocked, media_unblocked, media_deleted, media_rescanned added for
  # media-security-admin-control/6a-routine-state-actions (AC6/AC7) —
  # Nebu.Media.admin_block/3, admin_unblock/2, admin_delete/2, admin_rescan/2
  # bridge their admin-driven media_state_transitions writes (and, for Rescan,
  # its Oban enqueue) into the global audit_log via these four actions.
  # media_infected_override added for media-security-admin-control/
  # 6c-infected-override (AC5) — Nebu.Media.admin_override_infected/3 bridges
  # the distinct-role-gated :infected -> :released false-positive override
  # into the global audit_log via this action. Skipping this entry does not
  # raise/500 (the state transition still commits) — it only makes the
  # subsequent AuditWriter.log/6 call silently return
  # {:error, :audit_unknown_action}, logged at Logger.error only. Same
  # footgun 4c and 6a both independently flag; see this story's own dedicated
  # allowlist regression test.
  # media_hard_deleted added for media-security-admin-control/
  # 8a-media-cleanup-worker (AC9/AC10) — Nebu.Workers.MediaCleanupWorker
  # bridges its retention-cron :deleted/:infected -> :hard_deleted transitions
  # into the global audit_log via this action, once the S3 object delete and
  # storage_key/uploader_user_id null both succeed. Same documented footgun
  # as above — dropping this entry would silently vanish the hard-delete
  # event from the compliance record with no caller-visible failure.
  # media_orphan_detection_run added for media-security-admin-control/
  # 8b-orphan-detection-gdpr (AC2) — Nebu.Workers.MediaOrphanDetectionWorker's
  # hourly DETECTION-ONLY cron writes exactly ONE of these per run (never one
  # per candidate), reporting orphaned :quarantined media_files rows for
  # human review. This action name is deliberately housekeeping-flavoured,
  # NOT a compliance/erasure action — it does not imply or satisfy DSGVO
  # Art. 17 (see the worker's own moduledoc); do not repurpose the existing
  # gdpr_deletion action for this, and do not repurpose this action name for
  # any future erasure-request flow.
  # media_archived added for media-security-admin-control/
  # 8c-media-archive-worker (AC9) — Nebu.Workers.MediaArchiveWorker's daily
  # cron writes exactly ONE of these per row it successfully copies to the
  # archive bucket AND durably commits archived_at for (never for a losing
  # concurrent/repeated attempt). This is NOT a media_state_transitions
  # insert and NOT a lifecycle-state change (ADR-029: "No new state for
  # archival") — the state column never changes, only archived_at does; only
  # the global compliance audit log records the event. Same documented
  # footgun as every other entry above — dropping this would silently vanish
  # the archive event from the compliance record with no caller-visible
  # failure.
  # media_released_auto_deleted added for media-security-admin-control/
  # 8d-released-auto-delete (AC4) — Nebu.Workers.MediaReleasedAutoDeleteWorker's
  # daily, OPTIONAL (nil-by-default) data-minimization cron writes exactly ONE
  # of these per :released -> :deleted transition it drives via
  # Nebu.Media.StateMachine.transition/4. Same documented footgun as every
  # other entry above — dropping this would silently vanish the auto-delete
  # event from the compliance record while the state transition itself still
  # succeeds.
  # media_unscanned_release added for media-security-admin-control/
  # 10d-scan-kill-switch (AC7, non-negotiable) — Nebu.Workers.MediaScanWorker
  # writes exactly ONE of these every time the admin-configured
  # scan_kill_switch fires "fail_open" AND ClamAV's health-check reports the
  # scanner unavailable AND a :quarantined -> :scanning -> :released
  # transition actually happens without ever calling scan_binary/1. This is
  # the single most security-sensitive event this story exists to make
  # visible (an unscanned file became downloadable) — same documented
  # footgun as every other entry above — dropping this would silently vanish
  # the unscanned-release event from the compliance record while the file
  # itself is still released.
  # oauth_client_approved, oauth_client_rejected added for oauth-broker/
  # oauth-metadata-dcr-admin-approval (AC4/AC7) — the Admin UI approve/reject of a pending
  # OAuth client registration (Dynamic Client Registration) writes exactly one of these per
  # decision (target_type "oauth_client", target_id = client_id, optional rejection reason in
  # metadata.reason; NEVER the client metadata). Same documented footgun as every entry above —
  # dropping one would silently vanish the decision from the compliance record.
  # oauth_clients_bulk_removed added for oauth-broker/oauth-dcr-abuse-hardening (AH9) — the Admin UI
  # bulk removal of PENDING registrations writes exactly ONE row per run (target_type "oauth_client",
  # target_id "bulk", metadata: criteria, as_of, removed, client_ids; never client metadata) inside
  # the deletion transaction. Dropping it would make every bulk removal roll back with
  # :audit_unknown_action.
  # oauth_client_revoked, oauth_sessions_revoked_all added for oauth-broker/oauth-client-revocation (CR9,
  # CR10) — the withdrawal of an APPROVED client (Admin UI or operator rpc) writes exactly ONE
  # oauth_client_revoked row inside the revocation transaction (target_type "oauth_client", target_id =
  # client_id, metadata: devices, reauth, optional reason; NEVER client metadata or user / device ids), and
  # the operator's "revoke all OAuth sessions" writes ONE oauth_sessions_revoked_all row (target_id "all",
  # metadata: devices). Dropping either would silently vanish the event from the compliance record (and make
  # every revocation roll back with :audit_unknown_action).
  # oauth_signing_key_published, oauth_signing_key_rotated, oauth_signing_key_replaced added for oauth-broker/
  # oauth-hardening-hygiene (HY12, HY13) — the operator's id_token signing-key rotation (`Nebu.Release.
  # rotate_oauth_signing_key/0`, `replace_oauth_signing_key(:emergency)`) writes ONE row per successful call inside
  # the rotation transaction (actor "operator:rpc", target_type "oauth_signing_key", target_id = the new kid,
  # metadata: kids only, NEVER key material). Dropping one would roll every rotation back with
  # :audit_unknown_action.
  # sso_redirect_origins_changed added for oauth-broker/legacy-sso-redirect-confirmation (G3-3, SEC #5) -- the Admin UI
  # save of the operator list of https origins whose legacy SSO logins skip the confirmation page writes exactly ONE row
  # per successful save (target_type "server_config", target_id "sso_redirect_allowed_origins", metadata: origins = the
  # new normalized list, count). Without this entry the real writer answers :audit_unknown_action and the change would
  # never be audited.
  # oauth_switch_changed added for oauth-broker/admin-oauth-switch (AS7) -- the Admin UI save of the OAuth switch
  # (`oauth_enabled` / `oauth_issuer_url`, `POST /admin/config/oauth-switch`) writes exactly ONE row per change INSIDE the
  # transaction of the two server_config upserts (target_type "server_config", target_id "oauth_enabled", metadata:
  # enabled_before / enabled_after / issuer_before / issuer_after / reauth; never a secret). Without this entry the real
  # writer answers :audit_unknown_action, the transaction rolls back and OAuth could never be switched ON from the Admin UI.
  # sso_redirect_schemes_changed, oidc_claim_mapping_changed, admin_group_claim_changed added for oauth-broker/
  # admin-config-privileged-forms-sweep (cw, Y-5) -- the Admin UI saves of the legacy-SSO scheme list (metadata: schemes = the new
  # normalized list, count), of the OIDC claim mapping (metadata: the three claim names) and of the admin group claim (metadata: the group value) write exactly ONE row each after a successful save (target_type "server_config"); a failing writer never undoes the save.
  # log_settings_changed added for oauth-broker/admin-forms-gate-sweep (D5) -- the Admin UI save of the log levels and retention windows (`/admin/logs/config`; target_type
  # "server_config", target_id "log_settings", metadata: the saved keys and values, written in the same transaction as the save). Dropping it would make every
  # log retention save roll back with :audit_unknown_action.
  # oidc_scopes_changed, oidc_refresh_mode_changed (SEC review L-3) -- the saves of the extra OIDC scopes and of the refresh modes (metadata: the
  # saved scope strings / modes) change which claims the IdP issues and how long the tokens live: audited after the save like the three above.
  # Without these entries the real writer answers :audit_unknown_action and the change is never audited.
  # space_name_changed, space_topic_changed, space_child_added, space_child_removed added for oauth-broker/space-edit-audit (follow-up dj) -- the Admin UI
  # edits of a Space (`Nebu.Matrix.set_space_state/5`: name, topic, child add, child unlink) write exactly ONE row each after the successful state event (target_type "room",
  # target_id = the space room id, metadata: name / topic truncated to 256 characters or child_room_id, plus the event_id of the `events` record). Not atomic with the
  # event (Room GenServer path); a failing writer never undoes the edit. Dropping one would silently vanish the edit from the compliance record with no caller-visible failure.
  # room_power_levels_changed added for oauth-broker/power-levels-enforcement (D11) -- a COMMITTED change through PUT .../state/m.room.power_levels writes
  # exactly ONE row after the commit (target_type "room", metadata: changed_keys (only the ten v10 keys), users_changed (at most 50, sorted), users_changed_count,
  # other_keys_changed_count when client-chosen keys changed: their names are never recorded, so no client free text).
  # Best effort (the moderation precedent, follow-up fs): a failing writer never undoes the change. No row for the no-op, a refusal, createRoom or an upgrade.
  @known_actions ~w(
    admin_login
    admin_login_failed
    admin_logout
    bootstrap_completed
    bootstrap_failed
    room_created
    room_joined
    compliance_access_requested
    compliance_access_approved
    compliance_access_rejected
    compliance_session_issued
    compliance_session_expired
    compliance_session_revoked
    compliance_export_downloaded
    user_keys_deleted
    user_keys_deletion_attempted
    user_anonymized
    user_deactivated
    user_reactivated
    update_user_role
    room_archived
    room_event_redacted
    room_unarchived
    room_auto_join_changed
    room_visibility_changed
    member_added
    member_removed
    device_renamed
    device_deleted
    server_config_updated
    room_upgraded
    room_member_kicked
    room_member_banned
    room_member_unbanned
    room_power_levels_changed
    gdpr_deletion
    users_bulk_imported
    enable_temporary_capture
    disable_temporary_capture
    media_config_updated
    media_storage_config_updated
    media_infected_detected
    media_scan_failed
    media_blocked
    media_unblocked
    media_deleted
    media_rescanned
    media_infected_override
    media_hard_deleted
    media_orphan_detection_run
    media_archived
    media_released_auto_deleted
    media_unscanned_release
    oauth_client_approved
    oauth_client_rejected
    oauth_clients_bulk_removed
    oauth_client_revoked
    oauth_sessions_revoked_all
    oauth_signing_key_published
    oauth_signing_key_rotated
    oauth_signing_key_replaced
    sso_redirect_origins_changed
    oauth_switch_changed
    sso_redirect_schemes_changed
    space_name_changed
    space_topic_changed
    space_child_added
    space_child_removed
    oidc_claim_mapping_changed
    admin_group_claim_changed
    oidc_scopes_changed
    oidc_refresh_mode_changed
    log_settings_changed
  )

  # Configurable repo for test injection. Production uses Nebu.Repo.
  defp repo, do: Application.get_env(:compliance, :repo, Nebu.Repo)

  def log(actor_user_id, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
    # AC8 (Story 5.29c): reject unknown action strings before changeset validation.
    # Unknown actions indicate a bug (typo, missing allowlist entry) rather than
    # a validation error — use a distinct error atom so callers can distinguish.
    if is_binary(action) and action != "" and action not in @known_actions do
      Logger.error("AuditWriter: rejected unknown audit action",
        action: inspect(action),
        actor: actor_user_id
      )
      {:error, :audit_unknown_action}
    else
      do_log(actor_user_id, action, target_type, target_id, metadata, outcome, error_detail)
    end
  end

  defp do_log(actor_user_id, action, target_type, target_id, metadata, outcome, error_detail) do
    # Kassandra MEDIUM-3 (2026-04-23): validate via changeset so required fields
    # (actor_user_id, action, outcome) cannot be silently persisted as nil or "".
    # Without this, insert! would have written "actor_user_id=nil" and corrupted
    # the audit trail.
    changeset =
      AuditLogEntry.changeset(%AuditLogEntry{}, %{
        actor_user_id: actor_user_id,
        action:        action,
        target_type:   target_type,
        target_id:     target_id,
        metadata:      metadata,
        outcome:       outcome,
        error_detail:  error_detail
      })

    if changeset.valid? do
      entry = Ecto.Changeset.apply_changes(changeset)

      # never-raise (moduledoc Error policy): a transaction against an unstarted /
      # missing Repo raises RuntimeError from Ecto.Repo.Registry.lookup. Catch it so
      # a down DB degrades to {:error, :audit_write_failed} instead of crashing the
      # caller (e.g. an Admin device action when the Repo is unavailable).
      try do
        case repo().transaction(fn -> repo().insert!(entry) end) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error("AuditWriter: failed to write audit log",
              action: action,
              actor: actor_user_id,
              reason: inspect(reason)
            )
            {:error, :audit_write_failed}
        end
      rescue
        # Only degrade the documented case (RuntimeError from
        # Ecto.Repo.Registry.lookup on an unstarted/missing Repo) to a generic
        # audit-write failure. Narrowing to RuntimeError keeps genuine logic bugs
        # (FunctionClauseError/ArgumentError/etc.) surfacing instead of being
        # masked as :audit_write_failed.
        e in [RuntimeError] ->
          Logger.error("AuditWriter: failed to write audit log (raised)",
            action: action,
            actor: actor_user_id,
            reason: inspect(e)
          )
          {:error, :audit_write_failed}
      end
    else
      Logger.error("AuditWriter: refused to write audit log — validation failed",
        action: action,
        actor: actor_user_id,
        errors: inspect(changeset.errors)
      )
      {:error, :audit_write_invalid}
    end
  end
end
