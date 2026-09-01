---
story_id: 10d-scan-kill-switch
title: "Scan Health & Alerts Dashboard: Kill-Switch (fail-open / fail-closed)"
epic: media-security-admin-control
status: done
security_review: required
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

When `clamd` is unreachable, every in-flight upload eventually reaches
`Nebu.Workers.MediaScanWorker`'s scan attempt (Story 4b) and hits a scanner error. Story 4b
already handles the *generic* scanner-error case (retry with exponential backoff, discard to
`scan_failed` after `max_attempts`, Story 4c's audit bridge) — but it treats "clamd is
completely down" the same as any transient hiccup. This story adds an explicit, admin-configurable
**policy** for the specific case where the health-check (Story 3, `Nebu.Media.ClamAV`) reports
the scanner as unavailable: should the file be released **unscanned** so the platform stays
available, or should it stay held until scanning capacity returns?

This is a genuine security/availability tradeoff, not a cosmetic setting:

- **fail-open** trades *safety* for *availability*: uploads are never blocked by a scanner outage,
  but a file can end up downloadable by other room members without ever having been scanned for
  malware. This is only acceptable when made an explicit, audited, admin opt-in — never a silent
  default.
- **fail-closed** trades *availability* for *safety*: uploads simply queue up (retry-with-backoff,
  same as any other scan error) until `clamd` comes back, or eventually land in `scan_failed`
  (visible to admins, already alertable per Story 10c) if it never does. No file is ever served
  to a Matrix client without having passed a scan.

**Chosen default: `fail_closed`.** ADR-024 (ClamAV scanner selection) does not address this
question at all — it is silent on kill-switch posture entirely. The epic's own Story 10d draft
text parenthetically labels `fail_open` as "(Default: ...)" but gives no rationale for that
choice, and it predates this story's fuller design (worker-level integration reusing 4b's
retry/discard machinery, the audit-entry requirement, and Story 10c's alerting). Nebu's target
audience is German municipalities and public authorities under DSGVO; the epic elsewhere commits
to conservative, audited-by-default postures for comparably risky decisions (Two-Eyes-Delete,
Legal-Hold, `released_delete_after_days` defaulting to `nil`/disabled). Silently letting unscanned
files reach other room members by default would be inconsistent with that posture and with the
entire reason this epic's quarantine pipeline exists. This story therefore treats the epic's
draft parenthetical as an unreconciled early note, not a binding decision, and ships `fail_closed`
as the shipped default — an admin who understands the tradeoff can still explicitly opt into
`fail_open` via `/admin/media/settings` (Story 9b), and that opt-in itself is audit-logged
(Story 9a's `media_config_updated` action already covers config *changes*; this story adds the
audit entry for the kill-switch actually *firing* in fail-open mode).

## User Story

As the Nebu server operator, I want to explicitly decide — and be able to change without a
redeploy — whether uploads are released unscanned or held when ClamAV is unreachable, and I want
every unscanned release to be visible in the compliance audit log, so that an outage in the
malware scanner never silently and invisibly exposes unscanned files to my organization's users.

## Acceptance Criteria

1. **AC1 — `scan_kill_switch` config value.** `Nebu.Media.Config.get/0` (Story 9a) gains a new
   key `scan_kill_switch` with allowed values `"fail_open"` / `"fail_closed"`, default
   `"fail_closed"` (see Summary — the default is `fail_closed` unless an admin has explicitly
   written `"fail_open"` via `Nebu.Media.Config.upsert/1`). `upsert/1` rejects any other value
   with `{:error, :invalid_scan_kill_switch}` (or the established `{:error, reason}` shape 9a's
   other per-key validations use) without writing a row.
2. **AC2 — Migration extends `media_config_update_mutable`.** A new migration (this story's own,
   per 9a's established incremental-key precedent — see Dependencies) adds `'scan_kill_switch'`
   to the `media_config_update_mutable` RLS policy's key allowlist. This story does not touch
   9a's original migration file.
3. **AC3 — Kill-switch check happens before the scan attempt, not after.** In
   `Nebu.Workers.MediaScanWorker` (Story 4b), immediately after entering `:scanning` and before
   fetching/decrypting the file or calling `Nebu.Media.ClamAV.scan_binary/1`, the worker checks
   ClamAV's health via the surface Story 3 exposes (`Nebu.Media.ClamAV.health_check/0` or
   equivalent). When healthy, behavior is completely unchanged from Story 4b (scan proceeds
   normally) — this story adds a branch, it does not alter the happy path.
4. **AC4 — Unhealthy + `fail_open` → release unscanned.** When the health-check reports ClamAV
   unavailable and `scan_kill_switch == "fail_open"`, the worker skips the storage
   fetch/decrypt/decompress/scan_binary steps entirely and transitions `:scanning → :released`
   (via `Nebu.Media.StateMachine.transition/4`, actor `{:system, nil}`) with metadata
   `%{unscanned: true, reason: "clamav_unavailable"}`, then broadcasts on `"media:#{media_id}"`
   exactly like Story 4b's other terminal outcomes (AC8 there). The job completes (`:ok`), it is
   not retried — this is a deliberate, policy-driven terminal outcome, not a scan failure.
5. **AC5 — Unhealthy + `fail_closed` → hold and retry via the existing scan-error path.** When
   the health-check reports ClamAV unavailable and `scan_kill_switch == "fail_closed"`, the
   worker treats this exactly like any other scanner error in Story 4b's AC9: transition
   `:scanning → :quarantined` with metadata `%{reason: "clamav_unavailable"}`, then return
   `{:error, :clamav_unavailable}` so Oban retries with its existing exponential backoff. If
   `job.attempt >= job.max_attempts` on this same check, the worker instead transitions to
   `scan_failed` and returns `{:discard, :clamav_unavailable}` — the identical exhausted-retries
   branch Story 4b already has, which already triggers Story 4c's `media_scan_failed` audit-log
   entry with no new code needed for that path. **No new ENUM state is introduced by this
   story** — `:quarantined` (retry-pending) and `scan_failed` (exhausted) are Story 1a's/4a's
   existing states, reused as-is.
6. **AC6 — Policy change takes effect without a restart.** Because the worker reads
   `Nebu.Media.Config.get/0` fresh on every `perform/1` invocation (never caches the kill-switch
   value at process start or compile time), a `scan_kill_switch` change made via
   `Nebu.Media.Config.upsert/1` is observed by the very next `MediaScanWorker` job that hits an
   unhealthy ClamAV — this is a consequence of correctly using 9a's existing live-config
   mechanism (ETS + `:pg` broadcast + TTL fallback), not new plumbing this story has to build.
7. **AC7 — Audit entry on every fail-open unscanned release (non-negotiable).** Every time AC4's
   branch actually fires (fail-open policy AND ClamAV unhealthy AND a release happens), the
   worker calls `Nebu.Compliance.AuditWriter.log/6` with a new action `"media_unscanned_release"`,
   `target_type: "media"`, `target_id: media_id`, `outcome: "success"`, and `metadata` containing
   at minimum `media_id`, `filename`, `sha256` (`file_hash`), `uploader_id`, and
   `reason: "clamav_unavailable"`. `actor_user_id` uses the same system-actor sentinel already
   used for other system-driven audit writes (Story 4c). `media_unscanned_release` is added to
   `AuditWriter.@known_actions` in the same commit (see Story 4c's documented footgun — a missed
   allowlist entry silently no-ops the write).
8. **AC8 — Normal scanning is unaffected regardless of configured policy.** When ClamAV is
   healthy, `scan_kill_switch`'s value is never consulted and has no observable effect — files
   scan normally (`:scanning → :released` clean, `:infected` on detection, Story 4b/4c unchanged)
   whether the config is `fail_open` or `fail_closed`. The kill-switch only ever engages on an
   actual health-check failure.
9. **AC9 — No audit entry for the fail-closed path from this story.** The `fail_closed` branch
   (AC5) writes no new audit entry of its own — it reuses Story 4b's `:quarantined` retry write
   (no `audit_log` entry, per ADR-028's "routine transitions stay in `media_state_transitions`
   only") and, on exhaustion, Story 4c's existing `media_scan_failed` audit entry. This story
   does not duplicate that write.

## Acceptance Tests

Test file: `server/test/nebu/workers/media_scan_worker_kill_switch_test.exs` (colocated with
Story 4b's `MediaScanWorker` tests, same `Oban.Testing`/fake-seam conventions as
`media_scan_worker_test.exs` and `media_scan_worker_audit_bridge_test.exs`).

1. `test "fail-open releases unscanned with an audit entry when ClamAV is down"` — fake
   `Nebu.Media.ClamAV.health_check/0` reports unhealthy, config seam returns
   `scan_kill_switch: "fail_open"`; `perform_job/3` on a `:quarantined` row; asserts the fake
   `scan_binary/1` is **never called**, the fake StateMachine recorded
   `:quarantined → :scanning → :released` with `metadata.unscanned == true`, a
   `{:media_state_transition, id, :released}` broadcast fired, and exactly one
   `AuditWriter`-routed row exists with `action == "media_unscanned_release"`,
   `metadata.reason == "clamav_unavailable"`.
2. `test "fail-closed holds and retries when ClamAV is down"` — fake `health_check/0` reports
   unhealthy, config seam returns `scan_kill_switch: "fail_closed"`; asserts `scan_binary/1` is
   never called, the fake StateMachine recorded `:scanning → :quarantined`, the job returns
   `{:error, :clamav_unavailable}` (Oban records this as retryable, not a discard), and no
   `AuditWriter` row was written.
3. `test "fail-closed transitions to scan_failed and audit-logs media_scan_failed after
   max_attempts exhausted while ClamAV stays down"` — same as test 2 but with
   `attempt: 5, max_attempts: 5`; asserts the job returns `{:discard, :clamav_unavailable}`, the
   final state is `scan_failed`, and Story 4c's existing audit bridge produced a
   `media_scan_failed` row (proving this story needed no new discard-path audit code).
4. `test "normal scanning behavior is unaffected when ClamAV is healthy regardless of policy"`
   — parameterized over `scan_kill_switch: "fail_open"` and `"fail_closed"`, fake `health_check/0`
   reports healthy; asserts `scan_binary/1` **is** called in both cases and the outcome (clean →
   `:released`, infected → `:infected`) is identical to Story 4b's own tests — this is the
   explicit regression guard that the kill-switch branch never engages on the happy path.
5. `test "policy change takes effect live between two worker invocations without a process
   restart"` — first `perform_job/3` call with the config seam returning `"fail_closed"` and
   ClamAV unhealthy (asserts `:quarantined` retry outcome); config seam is then updated to
   `"fail_open"` (via `Nebu.Media.Config.upsert/1` against the real/fake config module, not by
   restarting any process) and a second `perform_job/3` call (new job/attempt, same unhealthy
   ClamAV) asserts an unscanned `:released` outcome with the audit entry — proving the read is
   live, not cached.
6. `test "media_unscanned_release must be registered in AuditWriter.@known_actions"` — mirrors
   Story 4c's Test 4 / `audit_writer_media_actions_test.exs` shape: calls
   `Nebu.Compliance.AuditWriter.log/6` directly with `action: "media_unscanned_release"` and
   asserts `result == :ok`, not `{:error, :audit_unknown_action}`.
7. `test "upsert/1 rejects an invalid scan_kill_switch value"` — `Nebu.Media.Config.upsert("scan_kill_switch", "sometimes")`
   returns `{:error, _}` and writes no row; `"fail_open"` and `"fail_closed"` are both accepted.
8. `test "a fresh media_config table with no scan_kill_switch row defaults to fail_closed"` —
   `Nebu.Media.Config.get/0` on an empty table returns `scan_kill_switch: "fail_closed"`.

## Technical Requirements

### Where the check lives — `Nebu.Workers.MediaScanWorker.scan_and_transition/3` (Story 4b)

The health-check-then-branch is inserted at the *top* of `scan_and_transition/3`, before the
existing `with` chain that fetches/decrypts/decompresses the file — a kill-switch decision never
needs the file bytes at all (fail-open releases without inspecting them; fail-closed just retries
without ever having fetched them), so checking first avoids a wasted S3 round-trip and decrypt on
every retry while `clamd` is down:

```elixir
defp scan_and_transition(media_id, attempt, max_attempts) do
  if clamav_healthy?() do
    do_scan(media_id, attempt, max_attempts)  # Story 4b's existing body, unchanged
  else
    handle_kill_switch(media_id, attempt, max_attempts)
  end
end

defp clamav_healthy?, do: clamav().health_check() == :healthy  # adapt to Story 3's exact return shape

defp handle_kill_switch(media_id, attempt, max_attempts) do
  case media_config().get().scan_kill_switch do
    "fail_open" ->
      metadata = %{unscanned: true, reason: "clamav_unavailable"}
      {:ok, :released} = state_machine().transition(media_id, :released, {:system, nil}, metadata)
      audit_unscanned_release(media_id, metadata)
      broadcast(media_id, :released)
      :ok

    "fail_closed" ->
      scan_error(media_id, :clamav_unavailable, attempt, max_attempts)  # Story 4b's existing
      # AC9 function, reused verbatim — retries with backoff, discards to scan_failed on
      # exhaustion, which already triggers Story 4c's media_scan_failed audit bridge.
  end
end

defp audit_unscanned_release(media_id, metadata) do
  row = db().lookup_for_scan(media_id)  # same lookup 4b already uses for filename/sha256/uploader
  Nebu.Compliance.AuditWriter.log(
    system_actor_id(),
    "media_unscanned_release",
    "media",
    media_id,
    Map.merge(%{media_id: media_id, filename: row.filename, sha256: row.file_hash,
                uploader_id: row.uploader_id}, metadata),
    "success"
  )
end

defp media_config, do: Application.get_env(:nebu, :media_config_module, Nebu.Media.Config)
```

`scan_error/4` is Story 4b's **existing, unmodified** function — this is the key design decision:
the `fail_closed` branch is not a new retry/discard mechanism, it is the generic scanner-error
path with a specific reason atom (`:clamav_unavailable`). This is exactly the reuse the task
called for ("check 4b's story for the closest existing mechanism to reuse") and it means Story
4c's audit bridge for `scan_failed` needs zero changes to also cover the fail-closed kill-switch's
exhausted-retries case.

### Config — `Nebu.Media.Config` (Story 9a)

Add `"scan_kill_switch" => "fail_closed"` to `@defaults` and a validation clause in `upsert/1`:
value must be exactly `"fail_open"` or `"fail_closed"`, else `{:error, :invalid_scan_kill_switch}`.
This mirrors 9a's existing per-key validation style (e.g. its `webhook_url`/`mime_denylist`
clauses) — add one more `case`/`cond` branch, do not restructure `upsert/1`'s validate-then-write
shape.

### Migration — extend, do not re-create, the mutable-key allowlist

New migration (number **TBD at merge time** — next available after whichever of 9a's
`000024_media_config`, 4a's `scan_failed` migration, and 4b's `000023_oban_jobs` land first;
follow the same "whoever lands first keeps its number, others bump" convention already documented
across this epic's migration-numbered stories):

```sql
-- Extends media_config_update_mutable (from 000024_media_config) with the kill-switch key
-- introduced by Story 10d. Same incremental-allowlist precedent as server_config's
-- 000007/000013/000016/000018 and this table's own 9a → 10c → 10d sequence.
DROP POLICY media_config_update_mutable ON media_config;
CREATE POLICY media_config_update_mutable ON media_config
    FOR UPDATE
    USING (key IN (
        'max_upload_size_bytes', 'max_file_size_bytes', 'max_pending_per_user',
        'max_stall_ms', 'deleted_days', 'infected_days', 'orphaned_hours',
        'webhook_url', 'released_delete_after_days', 'mime_denylist',
        'scan_kill_switch'
    ));
```

(Exact full key list depends on whether Story 10c's alert-threshold keys have already landed and
extended this same policy — if so, append `'scan_kill_switch'` to that migration's list rather
than reconstructing the pre-10c set. The dev agent must inspect the current HEAD migration state
before writing the `.up.sql`.)

### Audit — new action + known-actions allowlist

`server/lib/nebu/compliance/audit_writer.ex`'s `@known_actions` gains `media_unscanned_release`,
with a one-line comment naming this story, matching the existing convention (cf. Story 4c's
`media_infected_detected`/`media_scan_failed` entries). This is the exact same footgun Story 4c
documents — code review must independently verify the allowlist entry, not assume "tests pass"
covers it, per that story's checklist convention.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/workers/media_scan_worker.ex` | UPDATE | Add health-check branch at the top of `scan_and_transition/3`; `handle_kill_switch/3`, `audit_unscanned_release/2` |
| `server/lib/nebu/media/config.ex` | UPDATE | Add `scan_kill_switch` (default `"fail_closed"`) to `@defaults` + `upsert/1` validation |
| `server/priv/migrations/0000XX_media_config_scan_kill_switch.up.sql` (number TBD) | NEW | Extend `media_config_update_mutable` allowlist with `'scan_kill_switch'` |
| `server/priv/migrations/0000XX_media_config_scan_kill_switch.down.sql` | NEW | Restore the prior allowlist (without `'scan_kill_switch'`) |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE | Add `media_unscanned_release` to `@known_actions` |
| `server/test/nebu/workers/media_scan_worker_kill_switch_test.exs` | NEW | Acceptance Tests above |
| `server/test/nebu/compliance/audit_writer_media_actions_test.exs` | UPDATE | Add the `media_unscanned_release` allowlist regression test (Test 6), alongside 4c's existing entries |
| `server/test/nebu/media/config_test.exs` | UPDATE | Add `scan_kill_switch` default/validation tests (Tests 7–8) |

## Dev Agent Guardrails

### Do Not Change

- **The default MUST be `fail_closed` unless an admin has explicitly written `"fail_open"` via
  `Nebu.Media.Config.upsert/1`. Never silently default to `fail_open`** — this is the single most
  important guardrail in this story. The epic's own early draft text for Story 10d parenthetically
  suggests `fail_open` as a default; that note is superseded by this story's Summary reasoning
  and must not be resurrected. If a later reviewer wants `fail_open` as the shipped default, that
  requires an explicit epic/ADR update with stated rationale, not a quiet reversion during
  implementation.
- **The fail-open audit entry (AC7) is non-negotiable.** Every unscanned release caused by the
  kill-switch actually firing must produce a `media_unscanned_release` audit-log row. This is the
  one security-sensitive event this whole story exists to make visible — do not gate it behind a
  future story, do not fold it into `media_config_updated` (that action is for the *policy
  setting* changing, not for the kill-switch actually *releasing a file*), and do not skip it "for
  now."
- Do not introduce a new `media_files.state` ENUM value. Reuse `:quarantined`/`:released`/
  `scan_failed`, exactly as Story 4b/4a already define them.
- Do not duplicate Story 4b's retry/backoff/discard logic. The `fail_closed` branch must call the
  existing `scan_error/4` (or equivalently-named private function) unmodified — do not write a
  second retry loop.
- Do not duplicate Story 4c's `scan_failed` audit bridge. The exhausted-retries-under-fail-closed
  case must produce exactly one `media_scan_failed` audit row via the existing 4c code path, not a
  second, kill-switch-specific audit call for the same event.
- Do not bypass `Nebu.Compliance.AuditWriter.log/6` (ADR-020) — no direct `Repo.insert` against
  `audit_log` from `Nebu.Media`/`Nebu.Workers` code.
- Do not cache `scan_kill_switch` outside of `Nebu.Media.Config`'s own ETS/`:pg` mechanism (e.g. in
  worker process state, application env read once at boot) — doing so would break AC6 (live
  policy change).

## Dependencies

- **3 — `Nebu.Media.ClamAV` GenServer**: provides the health-check surface
  (`health_check/0` or equivalent) this story's branch condition reads.
- **4b — `MediaScanWorker` (Async Scan Worker)**: the exact integration point — this story adds a
  branch at the top of its `scan_and_transition/3` and reuses its existing `scan_error/4`
  retry/discard mechanism for the `fail_closed` path. Depends on 4b having landed first.
- **9a — `media_config` table + `Nebu.Media.Config` module**: the config source
  (`scan_kill_switch` key, default, validation) and the live-cache mechanism that satisfies AC6
  for free.
- **4c — Infected/scan_failed compliance-audit bridge**: establishes the audit-log convention
  (`AuditWriter.log/6`, `@known_actions` allowlist discipline, the exact footgun this story's
  guardrails call out again) this story's `media_unscanned_release` entry follows, and is the
  existing code path the `fail_closed` exhausted-retries case rides on for its `scan_failed`
  audit entry — no new code needed there.
