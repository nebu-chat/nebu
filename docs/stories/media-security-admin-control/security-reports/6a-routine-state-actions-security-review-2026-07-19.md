# Security Review — 6a-routine-state-actions

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Date:** 2026-07-19 · **Epic:** media-security-admin-control
**Story flag:** `security_review: required` — mandatory gate.

## Verdict: APPROVED post-fix (1 CRITICAL found and fixed in this review, 0 remaining CRITICAL/HIGH/MEDIUM/LOW)

## Scope

`server/lib/nebu/media.ex` (new `admin_block/3`, `admin_unblock/2`, `admin_delete/2`,
`admin_rescan/2`, `write_admin_audit/4`, `audit_writer/0`, `blank_to_nil/1`; also the CRITICAL fix
below to `download_gate/1`), `server/lib/nebu/media/db.ex` (new `lookup_state/1`),
`server/lib/nebu/compliance/audit_writer.ex` (`@known_actions` +4), `server/lib/nebu/admin/
media_live.ex` (6 new `handle_event` clauses, confirm modal, row actions, `@action_flash`),
`server/priv/static/assets/app.js` (`MediaDeleteConfirmModal` hook), `server/priv/migrations/
000029_media_state_transitions_actor_id_text.{up,down}.sql`, `server/lib/nebu/media/
state_machine.ex` (actor_id type change), plus the new/extended test files.

## CRITICAL — `:admin_blocked` download response was distinguishable by status line alone (FIXED)

`download_gate(:admin_blocked)` returned `{451, "M_NOT_FOUND"}` — the JSON body was anonymized to
match a genuine 404, but the HTTP *status line* did not. This exact gap was pre-registered as a
dormant finding in Kassandra's own sanctum (`_bmad/memory/nebu-agent-kassandra/MEMORY.md`,
Recurring Patterns, 1c-download-gate 2026-07-13): *"(451, M_NOT_FOUND) UNIQUELY fingerprints
admin_blocked... Dormant until the mutation path (Story 6a admin-block trigger) ships → then
live."* This story is that trigger — it is the first story to ever drive a real file into
`:admin_blocked` via `Nebu.Media.admin_block/3` (Story 1b's own tests only ever seeded the state
directly via SQL, never through a real admin action).

**Why the earlier documentation-only fix in this same dev pass was insufficient:** before this
security review ran, an ADR-026 table-vs-prose contradiction (carried forward from 1c, flagged by
the coordinator) was "resolved" by rewriting the prose to argue: *"the HTTP status stays honestly
at 451... only the JSON errcode/body is anonymized... a bare 451 does not by itself signal an
admin action."* This is the **exact reasoning the sanctum's own prior finding already refuted** —
`(451, M_NOT_FOUND)` together, not either alone, is the unique fingerprint. A reviewer (or a dev
agent doing a documentation-only pass) who does not cross-check the diff against the sanctum's
Recurring Patterns can independently re-derive and re-codify a previously-refuted argument.

**Fix:** `download_gate(:admin_blocked)` now returns `{404, "M_NOT_FOUND"}` — byte-identical status
line AND body to `:infected`/`:deleted`/`:hard_deleted`/a genuine unknown-`media_id` 404. No other
observable channel (headers, timing-relevant code path) differs between these branches either —
all four share the exact same `error/4` → `send_json/3` call shape.

**Verified NOT to affect Story 2d's stall mechanism:** `maybe_await_stall/3` gates on
`state in [:quarantined, :scanning]` only, evaluated entirely before `download_gate/1` runs — it
has no dependency on which deny-status `:admin_blocked` (or any other denied state) eventually
maps to.

**Updated to match:** `docs/architecture/adr/ADR-026-media-http-status-codes.md` (table + prose,
with the corrected reasoning — identical status AND body required, not one or the other),
`server/test/nebu/media/media_download_gate_test.exs` (2 tests: the dedicated admin_blocked test
and the anonymity-comparison test), `server/test/nebu/media/media_download_stall_test.exs`
(`@deny_table` + the dedicated admin_blocked-mid-wait test), `server/test/nebu/media_admin_actions_test.exs`
(this story's own new end-to-end anonymity test, Acceptance Test 18),
`docs/stories/media-security-admin-control/1c-download-gate-enforcement.md` (Dev Agent Record
correction note), this story's own Dev Agent Record.

## What held up (verified, not assumed)

- **Authorization (AC5):** all 4 new actions route through the pre-existing
  `on_mount({Nebu.Admin.Auth, :require_admin}, ...)` gate (Story 5a's, unchanged) — confirmed the
  existing "non-admin session redirected before mount" test proves every `handle_event` clause in
  this LiveView (5a's and 6a's alike) is unreachable pre-mount; no new/parallel auth mechanism was
  introduced, no `media_admin_override` role check was added (correctly out of scope — that's 6c's).
- **Audit-bridge completeness (AC6/AC7):** `AuditWriter.@known_actions` gained all 4 new action
  strings in the SAME commit as the `Nebu.Media` functions that reference them. Verified via a
  standalone allowlist-regression test (mirrors the `member_added`/`member_removed`/4c precedent) —
  a future refactor that regresses the allowlist fails loudly here, not as a buried
  `{:error, :audit_unknown_action}` deep in an action test.
- **Idempotency (AC9) writes nothing:** Block-already-blocked / Unblock-already-released
  short-circuit BEFORE `StateMachine.transition/4` is ever called — real-DB tests confirm zero new
  `media_state_transitions` rows and zero new `audit_log` entries for the no-op path, not merely
  the right return atom.
- **Guard-table rejections (AC8) write nothing:** an invalid-transition attempt (verified via
  `:infected → :admin_blocked`, `:quarantined → :released`, `:reserved`/`:scanning → :deleted`,
  `:released → rescan`) produces zero rows in both `media_state_transitions` and `audit_log` — a
  rejected attempt is not itself a compliance-relevant event.
- **`admin_id` type-mismatch fix (migration 000029) is zero-risk:** verified via a live query
  BEFORE writing the migration that all 42 existing `media_state_transitions` rows had
  `actor_id = NULL` (every writer to date uses `{:system, nil}`) — not a lossy backfill. No
  injection risk: the column is still written via a fully parameterized
  `Ecto.Adapters.SQL.query!/3` bind (never string-interpolated) both before and after — the fix
  changes the wire TYPE (UUID binary → TEXT), not the parameterization discipline. The new identity
  shape (`admin_id`, a Matrix-ID string) matches `audit_log.actor_user_id`/`users.user_id` exactly,
  which is a net auditability improvement (a single identity shape correlates across both ledgers,
  rather than requiring a UUID↔Matrix-ID join that doesn't exist anywhere in this schema).
- **Reason field / stored-XSS surface:** `reason` (admin-supplied free text, AC11) is written to
  `media_state_transitions.metadata`/`audit_log.metadata` via parameterized JSONB binds — no SQL
  injection surface (ADR-018 convention, unchanged). This story does NOT render `reason` (or any
  other metadata) back anywhere in its own UI scope — that surface belongs to Story 6b's detail
  view, correctly out of scope here per this story's own Guardrails. The pre-existing 1b INFO note
  ("metadata stored verbatim in JSONB... Story 6 admin-UI rendering is a stored-XSS surface")
  remains open and unexercised by 6a; carry it into 6b's review.
- **DOM ids / new LiveView markup:** every new `id`/`data-*` attribute is built from
  `row.media_id`/`@confirm_delete_media_id` (server-generated random 16-byte base64 media ids, never
  user-controllable free text) via ordinary HEEx `{...}`/attribute interpolation — auto-escaped,
  `raw/1` used nowhere in the new template code. Verified against the existing HEEx-auto-escaping
  regression test in `media_live_test.exs` (unaffected, still green).
- **Delete confirm modal CSP compliance:** no `window.confirm`, no `position: fixed` (epic's
  explicit constraint — `absolute inset-0` used instead, so the overlay scrolls with the page
  rather than staying pinned). The new `MediaDeleteConfirmModal` hook lives in the existing
  same-origin `priv/static/assets/app.js` (`script-src 'self'`-compatible) with no inline `on*=`
  handlers — consistent with the sanctum's own pattern #76 (dead inline confirmations under this
  CSP).
- **Rescan's Oban surface:** reuses the EXISTING `:media_scan_enqueue_module` seam
  (`Nebu.Media.ScanEnqueue`, already a real `Oban.insert/1` since Story 4b) rather than a second,
  parallel enqueue call site — `media_id` is fully server-derived at this call site (the admin's
  row-click, never a client-supplied job payload), no new Oban attack surface.
- **Invariant tests:** `state_machine_invariant_test.exs`'s grep-based check (no raw
  `UPDATE ... media_files ... SET state` outside `state_machine.ex`) stays green — every new
  function in this diff only ever reads (`SELECT state`) or delegates state changes through
  `StateMachine.transition/4`.

## Accepted risks this session

None newly accepted.

## Follow-up

None new beyond the pre-existing, still-open 1b metadata-rendering stored-XSS watch-flag (carry
into Story 6b's review).
