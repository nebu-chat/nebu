---
story_id: 4c-infected-scanfailed-audit-bridge
title: "Async Scan Worker: Compliance Audit Bridge (infected / scan_failed)"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

`media_state_transitions` (ADR-031) is the authoritative, append-only, per-file history of
every state change a media file goes through, but it is not the surface compliance officers
and auditors actually use — that is the global `audit_log`, surfaced via
`Nebu.Admin.AuditLogLive` (ADR-028). Two system-driven scan outcomes are compliance-relevant
beyond their own file's history: a confirmed malware detection (`:infected`) and a scan that
could never complete after exhausting retries (`scan_failed`). This story adds the bridge:
`Nebu.Workers.MediaScanWorker` (Story 4b) writes an additional `audit_log` entry — via
`Nebu.Compliance.AuditWriter`'s existing public logging function, never by reaching into
`Nebu.Compliance` internals — whenever a file transitions into either of these two states.

This is a small, single-purpose story, but it carries a known repo-level footgun: adding a
new audit action string without registering it in `AuditWriter.@known_actions`
(`server/lib/nebu/compliance/audit_writer.ex`) causes `AuditWriter.log/6` to silently reject
the write (`{:error, :audit_unknown_action}`, logged only at `Logger.error` level) — the malware
detection or scan-failure event would vanish from the compliance record with no caller-visible
error. This has broken the audit trail before in this repo after a branch merge (see
`audit_writer_member_actions_test.exs`, added as a regression test for `member_added` /
`member_removed` / `room_visibility_changed` falling out of the allowlist). This story makes
the allowlist update an explicit, testable acceptance criterion rather than an implicit
assumption, exactly to avoid repeating that incident.

## User Story

As a compliance officer, I want every malware detection and every scan that permanently
failed to be visible in the global audit log (not just in the file's own transition history),
so that I can discover and act on security-relevant media events from the same place I audit
every other action in the system, without having to know to look at `media_state_transitions`
separately.

## Acceptance Criteria

1. **New audit action atoms.** Two new audit action strings are introduced:
   `"media_infected_detected"` (written on the `scanning → :infected` transition) and
   `"media_scan_failed"` (written on the `quarantined/scanning → :scan_failed` transition,
   i.e. from the Oban `discard/2` callback after `max_attempts` exhaustion).
2. **Written exclusively via `Nebu.Compliance.AuditWriter`'s public logging function
   (ADR-020).** `Nebu.Workers.MediaScanWorker` (`Nebu.Media` / worker namespace) calls
   `Nebu.Compliance.AuditWriter.log/6` — the same public entry point already used
   cross-domain by `Nebu.Admin.UsersController`, `Nebu.Admin.TemporaryCaptureManager`,
   and `Nebu.Matrix.EventDispatcher.Server` — for both new actions. No code in
   `Nebu.Media`/`Nebu.Workers` constructs an `AuditLogEntry` changeset directly, inserts into
   `audit_log` directly via `Repo`, or otherwise bypasses `AuditWriter.log/6`.
3. **`AuditWriter.@known_actions` is updated in the same commit — explicit, non-negotiable
   acceptance criterion.** `server/lib/nebu/compliance/audit_writer.ex` `@known_actions` gains
   both `media_infected_detected` and `media_scan_failed`. This is called out as its own AC
   (not folded into AC1) precisely because this project has a documented history of this exact
   step being forgotten on merge, silently turning audit writes into no-ops
   (`{:error, :audit_unknown_action}`) with no caller-visible failure. Code review MUST verify
   this line-item independently of the worker code (see Dev Agent Guardrails).
4. **Audit entry content — `:infected`.** The `audit_log` row written on `:infected` has:
   `action: "media_infected_detected"`, `target_type: "media"`, `target_id: <media_id>`,
   `outcome: "success"`, and `metadata` containing at minimum: `media_id`, `filename`,
   `sha256` (the file's `file_hash`), `uploader_id`, and `clamav_signature` (the signature
   string returned by `Nebu.Media.ClamAV.scan_binary/1` in the `{:ok, {:infected, sig}}`
   branch). `actor_user_id` is the system sentinel already used for system-driven audit writes
   elsewhere in the codebase (system actor, not a human admin — no admin is involved in this
   transition).
5. **Audit entry content — `scan_failed`.** The `audit_log` row written on `scan_failed` has:
   `action: "media_scan_failed"`, `target_type: "media"`, `target_id: <media_id>`,
   `outcome: "failure"`, and `metadata` containing at minimum: `media_id`, `filename`,
   `sha256` (`file_hash`), `uploader_id`, and a failure reason (the discard reason / last Oban
   error, e.g. `"max_attempts_exhausted"` or the last-observed error term as a string —
   whichever `Nebu.Workers.MediaScanWorker`'s `discard/2` callback already has in scope from
   Story 4b's retry loop).
6. **Timestamp.** Both entries carry a timestamp via `AuditLogEntry`'s standard
   `inserted_at`/`occurred_at` mechanism (whatever `AuditLogEntry`'s changeset already
   populates for every other action) — no bespoke timestamp field is introduced for these two
   actions.
7. **No `room_id` in metadata (deliberate, per ADR-028).** `media_files` has no `room_id`
   column; room attribution for a compliance report is a future query-time join against
   `events.content` keyed by `target_id = media_id` (ADR-028). This story does not attempt
   that join and does not add a `room_id` key to `metadata`.
8. **Both `media_state_transitions` and `audit_log` are written.** The bridge is additive —
   Story 4b's existing write to `media_state_transitions` (`actor_type: :system`) for the
   `:infected` / `scan_failed` transitions is unchanged; this story adds the `audit_log` entry
   alongside it, it does not replace it.
9. **Routine transitions stay out of `audit_log`.** No other Story 4b transition
   (`quarantined → scanning`, `scanning → released`, `scanning → quarantined` retry,
   `:file_too_large` skip-to-`released`) writes to `audit_log` as part of this story — only
   `:infected` and `scan_failed` bridge across (per ADR-028, "routine, non-compliance-relevant
   transitions remain exclusively in `media_state_transitions`").

## Acceptance Tests

Concrete ExUnit test names (module: `Nebu.Workers.MediaScanWorkerAuditBridgeTest`, or
equivalent — colocated with or adjacent to Story 4b's `MediaScanWorker` tests, following the
`FakeRepo`-injection pattern already established in
`server/test/nebu/compliance/audit_writer_test.exs` /
`audit_writer_member_actions_test.exs`):

1. `test "scanning -> :infected writes an audit_log entry via AuditWriter with action media_infected_detected"`
   — drives the worker through a ClamAV `{:ok, {:infected, "Eicar-Test-Signature"}}` result and
   asserts exactly one `AuditWriter`-routed row exists with
   `action == "media_infected_detected"`, `target_type == "media"`,
   `target_id == <the media_id under test>`, and `metadata` containing `media_id`, `filename`,
   `sha256`, `uploader_id`, `clamav_signature == "Eicar-Test-Signature"`.
2. `test "scanning -> :infected audit entry has outcome success and a timestamp"` — asserts
   `outcome == "success"` and that the persisted row carries a non-nil timestamp field.
3. `test "discard/2 after max_attempts writes an audit_log entry with action media_scan_failed"`
   — drives the worker's `discard/2` callback (simulating `max_attempts` exhaustion) and
   asserts exactly one row with `action == "media_scan_failed"`, `target_type == "media"`,
   `target_id == <media_id>`, `outcome == "failure"`, and `metadata` containing `media_id`,
   `filename`, `sha256`, `uploader_id`, and a non-nil failure-reason key.
4. `test "media_infected_detected and media_scan_failed must be registered in AuditWriter.@known_actions"`
   — calls `Nebu.Compliance.AuditWriter.log/6` directly (bypassing the worker) with
   `action: "media_infected_detected"` and separately with `action: "media_scan_failed"`,
   using the `FakeRepo` injection pattern from `audit_writer_test.exs`, and asserts
   `result != {:error, :audit_unknown_action}` and `result == :ok` for both. This is the
   regression test in the shape of `audit_writer_member_actions_test.exs`
   (`AuditWriterMemberActionsTest`) — it is written to fail loudly against the allowlist rather
   than against the worker, so it would have caught the `member_added`/`member_removed`-class
   incident had it existed for this action pair, and it must keep passing on every future
   merge that touches `@known_actions`.
5. `test "no audit_log entry is written for the routine quarantined -> scanning transition"`
   (and equivalently for `scanning -> released`, retry-to-`quarantined`, and the
   `:file_too_large` skip-to-`released` path) — asserts the `AuditWriter` `FakeRepo` bucket
   stays empty for these transitions, confirming the bridge does not over-fire.
6. `test "audit_log entry does not include a room_id key in metadata"` — asserts `metadata`
   has no `"room_id"` / `:room_id` key on either the `:infected` or `scan_failed` entry
   (ADR-028 contract).

## Technical Requirements

- **Exact call sites — inside `Nebu.Workers.MediaScanWorker` (Story 4b):**
  - In the branch handling `{:ok, {:infected, sig}}` (Story 4b flow step 5, immediately after
    the `scanning → infected` `media_state_transitions` write and the `scan_metadata` update),
    add a call to `Nebu.Compliance.AuditWriter.log/6` with `action: "media_infected_detected"`.
  - In the worker's `discard/2` callback (Story 4b flow: "Nach `max_attempts`-Erschöpfung
    (`discard/2`): `quarantined/scanning → scan_failed`"), immediately after the
    `→ scan_failed` `media_state_transitions` write, add a call to
    `Nebu.Compliance.AuditWriter.log/6` with `action: "media_scan_failed"`.
  - No other branch in the worker (clean, retry-to-`quarantined`, `:file_too_large` skip) gets
    a new call — those remain `media_state_transitions`-only per ADR-028.
- **`Nebu.Compliance` public function used:** `Nebu.Compliance.AuditWriter.log/6` —
  `log(actor_user_id, action, target_type, target_id, metadata, outcome)`. This is the exact
  function already called directly from other domains (`Nebu.Admin.UsersController`,
  `Nebu.Admin.TemporaryCaptureManager`, `Nebu.Matrix.EventDispatcher.Server`) — no new
  `Nebu.Compliance` facade module is introduced by this story; `AuditWriter.log/6` already is
  the public, cross-domain-callable surface for audit writes (ADR-020: cross-domain calls go
  through a namespace's public module — for `Nebu.Compliance` that module is `AuditWriter`,
  there is no other public entry point in this codebase for writing audit entries).
  `actor_user_id` uses the same system-actor sentinel value already used for other
  system-driven audit writes in this codebase (not a human admin ID).
- **Known-actions list update:** `server/lib/nebu/compliance/audit_writer.ex`, `@known_actions`
  (currently a `~w(...)` sigil list, lines ~32–67) gains two new entries:
  `media_infected_detected` and `media_scan_failed`. Follow the existing convention of a
  one-line comment above the list (or inline near the addition) naming the story that
  introduced them, matching the style of the existing comments for `compliance_session_revoked`,
  `enable_temporary_capture`/`disable_temporary_capture`, etc.
- **Metadata shape:** a plain map (matching `AuditLogEntry`'s `metadata` field convention used
  throughout the codebase, e.g. `%{"user_id" => ...}` string-keyed maps as seen in
  `audit_writer_member_actions_test.exs`) — follow whichever key convention (atom vs. string
  keys) Story 4b's worker and the existing `AuditLogEntry.changeset/2` already use elsewhere in
  `Nebu.Media`/`Nebu.Compliance` for consistency; do not introduce a third convention.
- **No transaction coupling:** per `AuditWriter`'s documented behavior (moduledoc:
  "Each log/6 call is atomic in its own `Repo.transaction/1`"), the audit write is independent
  of the `media_state_transitions` write. If the worker's own state-transition write already
  committed and the subsequent `AuditWriter.log/6` call fails (`:audit_write_failed`), the
  worker does not roll back the state transition — `AuditWriter` never raises, per its
  documented error policy, so the worker's success path is not put at risk by an audit-write
  failure. Story 4b's Oban retry logic is unaffected by this story.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/workers/media_scan_worker.ex` | UPDATE | Add `AuditWriter.log/6` calls in the `:infected` branch and the `discard/2` callback |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE | Add `media_infected_detected` and `media_scan_failed` to `@known_actions` |
| `server/test/nebu/workers/media_scan_worker_audit_bridge_test.exs` | NEW | Tests 1–3, 5, 6 from Acceptance Tests |
| `server/test/nebu/compliance/audit_writer_media_actions_test.exs` | NEW | Test 4 from Acceptance Tests (allowlist regression test, mirrors `audit_writer_member_actions_test.exs`) |

## Dev Agent Guardrails

### Do Not Change

- Do not bypass `Nebu.Compliance`'s public API (ADR-020): no direct `Repo.insert`/
  `Repo.insert!` against `audit_log` or `AuditLogEntry` from `Nebu.Media` or
  `Nebu.Workers` code. All writes go through `Nebu.Compliance.AuditWriter.log/6`.
- Do not touch `media_state_transitions` writes from Story 4b — this story is additive only.
- Do not add a `room_id` key to the metadata map (ADR-028, deliberate omission — see AC7).
- Do not modify any other entries already present in `AuditWriter.@known_actions` — append
  only, in the same style/format as existing entries.
- Do not change `AuditWriter.log/6`'s signature, error policy, or transaction behavior — this
  story only adds two allowlist entries and two call sites; it does not touch `AuditWriter`'s
  internals otherwise.

### Explicit code-review checklist item

Because this repo has previously merged a branch that added new audit action strings without
updating `AuditWriter.@known_actions` — silently breaking the audit trail for those actions
until a later regression test caught it (`audit_writer_member_actions_test.exs`) — code review
for this story MUST independently verify, as a standalone checklist item (not assumed covered
by "tests pass"):

- [ ] `media_infected_detected` is present in `AuditWriter.@known_actions`.
- [ ] `media_scan_failed` is present in `AuditWriter.@known_actions`.
- [ ] The allowlist regression test (Acceptance Test 4) exists, is not skipped, and fails if
      either entry is removed from `@known_actions` (verify by temporarily reverting the
      allowlist locally and confirming the test goes red, per this story's TDD discipline).

## Dependencies

Depends on **4b-media-scan-worker** (`Nebu.Workers.MediaScanWorker`'s `:infected` transition
and `discard/2` callback are the exact hook points this story adds calls to). Intra-split
order: 3 of 3 (after 4a, 4b).
