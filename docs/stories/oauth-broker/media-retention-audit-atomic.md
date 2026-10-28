---
story_id: media-retention-audit-atomic
title: "Atomic audit of the three media retention values (follow-up dn, owner scope: released_delete_after_days, deleted_days, infected_days)"
type: bugfix
severity: low
epic: oauth-broker
status: ready
security_review: required
matrix: false
ui: false
created: 2026-10-15
branch: feature/migrate-to-oauth2
---

# Story: the retention values and their `media_config_updated` row are written in ONE transaction (follow-up `dn`, reduced scope)

Source: follow-ups row `dn`. `Nebu.Media.Config.upsert/3` writes the value first and the `media_config_updated` audit row afterwards, best-effort (a failed audit is only logged). For the three values that decide
WHEN stored media is deleted this is not enough: shortening a retention window deletes data, and a deletion policy change that leaves no audit row is exactly what an audit exists to prevent.
Owner decision 2026-10-15 ("machen wir"): ONLY `released_delete_after_days`, `deleted_days`, `infected_days`. Everything else of `dn` stays as it is (the other media policy keys, the storage target audit, the room / space
auto-join audit `room_auto_join_changed`, `Nebu.Matrix.set_room_auto_join/3` ignoring the writer's result): recorded in follow-ups.md as "not implemented, owner: only the three retention values".

## Decisions

- **D1 (where, ADR-020).** In `Nebu.Media.Config.upsert/3` (the ONLY write path of `media_config`, Media domain). For the three keys the value upsert and the `media_config_updated` row (`AuditWriter.log/6`, whose own transaction nests) run in ONE `Repo.transaction/1`, the pattern of
  `Nebu.Admin.DB.save_config_audited/2` (story admin-config-audit-atomic) and `Nebu.OAuth.save_switch/2`: a change is never unaudited and an audit row never describes a change that did not happen. The ETS cache refresh + `:pg` broadcast happen AFTER the commit.
  Every other key keeps today's sequential behaviour (unchanged).
- **D2 (policy for an unwritable audit table, per direction).** What matters is what the change does to the data:
  - SHORTENING the retention (`deleted_days` / `infected_days`: new < old; `released_delete_after_days`: off (unset or 0, see D2b) -> a number, or a number -> a smaller number) is a privileged, destructive step: the audit must succeed in the same transaction,
    otherwise NOTHING is persisted and the call answers `{:error, {:audit, reason}}` (the Admin UI shows a failure, nothing changed).
  - LENGTHENING or disabling (`deleted_days` / `infected_days`: new > old; `released_delete_after_days`: a number -> a larger number, or a number -> unset = never auto-delete) never depends on a broken audit table: if the audit write fails, the transaction is retried ONCE without the audit
    function, one value-free ERROR is logged (key only), the answer is `:ok`: the way to MORE retention must stay open when the audit table is broken (the same reason as the narrowing path of admin-config-audit-atomic). An unchanged value (new == old) is not written at all by the controller; the function itself treats it as lengthening (no data is deleted sooner).
  - The audit row is attempted in every case; "old" is read INSIDE the transaction under a row lock (`SELECT ... FOR UPDATE` of the key, or the default when no row exists: lock the key by an advisory lock / upsert order) so a concurrent save cannot turn a checked lengthening into a shortening between check and write (SEC review L-3 of admin-config-audit-atomic).
- **D2b (refusal is visible).** A refused shortening (the audit table is not writable) logs ONE value-free ERROR line naming the key and the direction (`shortening refused`), like the applied lengthening logs `applied without audit`: the operator learns about the broken audit table, the UI flash stays generic. `released_delete_after_days = 0` stays valid (the controller bound is >= 0) and, for the direction test, means "off" like nil: the worker `MediaReleasedAutoDeleteWorker.validated_window/0` treats 0 as invalid = off (decided by that behaviour, security review MEDIUM-1). So nil or 0 as the NEW value is a deactivation (lengthening); from an old nil or 0 EVERY positive number is a SHORTENING (audit mandatory, 0 -> 5 too); a positive number -> 0 is a deactivation. For `deleted_days` / `infected_days` 0 stays the shortest retention. A damaged stored old value (not a number) is unknown and never counts as a lengthening (fail-safe: a refused shortening when the audit fails, no server error).
- **D2c (order).** The controller persists the changed keys in SORTED key order (deterministic, `Enum.sort`), `upsert/3`'s spec gains `{:error, {:audit, term()}}`.
- **D3 (what a row says).** The row is the existing `media_config_updated` (target `media_config`, target_id = key, metadata `%{key, old_value, new_value}`), actor = the admin; nothing new is added to `@known_actions`.
- **D4 (validation first).** The existing validation (key known, value valid) runs before any DB call, unchanged: an invalid value has zero DB and audit side effects.
- **D5 (the Admin UI).** `MediaSettingsController` keeps its one `Config.upsert/3` call per changed key; a refused shortening (`{:error, {:audit, _}}`) shows the existing failure flash "Failed to save media settings" (value-free) and the earlier keys of the same save stay as they were committed (the known per-key limitation of the controller is unchanged and stays documented).
- **D6 (test seams).** `:media_config_writer` / `:media_config_loader` of the existing unit tests keep working for every key; a new test seam for the transaction (the pattern `:admin_config_tx`, compile-guarded `Mix.env() == :test`) lets DB-less unit tests prove the policy; the atomicity itself is proven against the real database (integration tests).

## Acceptance Criteria

1. Shortening each of the three values (`deleted_days` 30 -> 7, `infected_days` 90 -> 30, `released_delete_after_days` unset -> 14 and 30 -> 14) persists the value AND exactly one `media_config_updated` row (old / new value, admin actor) in one transaction (real DB).
2. With an audit write that fails (a failing audit function / revoked insert privilege on `audit_log`), a shortening persists NOTHING (value unchanged, no row) and answers `{:error, {:audit, _}}`; the Admin UI answers with the failure flash.
3. With an audit write that fails, a lengthening or disabling (`deleted_days` 30 -> 60, `released_delete_after_days` 14 -> 30 and 14 -> unset) is persisted without the row, one value-free ERROR is logged (key only, no values), the answer is `:ok`.
4. A rolled-back transaction leaves the ETS cache and the `:pg` peers untouched (no refresh on failure); a committed one refreshes the cache once.
5. A concurrent pair of saves cannot persist a shortening unaudited by racing a lengthening check (old value read under a lock inside the transaction; test with a deterministic interleaving seam or the lock proof of admin-config-audit-atomic).
6. Other keys (e.g. `max_upload_size_bytes`, `webhook_url`, `mime_denylist`) behave exactly as before (value, then best-effort audit): the existing `Nebu.Media.Config` and `MediaSettingsController` tests pass unchanged.
7. An invalid value / unknown key: zero DB and audit side effects (unchanged).
8. Docs: 07-deployment (policy per direction, the per-key controller limitation, the remaining best-effort audits), ADR-033 SO11 / ADR-027 as far as they describe the media policy audit, follow-ups.md: `dn` partly closed ("implemented for the three retention values; the rest not implemented, owner: only the three retention values").
