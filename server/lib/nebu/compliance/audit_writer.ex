defmodule Nebu.Compliance.AuditWriter do
  require Logger

  @moduledoc """
  Generic audit log writer. Every call to log/6 or log/7 inserts exactly one
  row into `audit_log` via a separate Repo.transaction/1 — never inside the
  caller's transaction. A caller rollback cannot suppress the audit record.

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
  # writes one of these.
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
    room_unarchived
    room_auto_join_changed
    room_visibility_changed
    member_added
    member_removed
    device_renamed
    device_deleted
    server_config_updated
    room_upgraded
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
