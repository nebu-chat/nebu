## Security Review — 6c-infected-override

**Diff scope:** `git diff --cached` (14 files) — new migration `000030_media_admin_override_role`
(adds `users.media_admin_override`), `Nebu.Media.admin_override_infected/3` +
`validate_reason/1` + `authorize_override/1` + `check_infected/1` + `scan_signature/1`,
`Nebu.Media.DB.check_override_role/1` + `lookup_scan_metadata/1`, the guard-table edge
`infected: [:deleted, :released]`, `AuditWriter.@known_actions` addition, and
`Nebu.Admin.MediaLive`'s new override button + CSP-safe confirm modal + JS focus-trap hook.

**Date:** 2026-07-19

### Memory check performed

Read `BOND.md`'s Sensitive Surfaces entry for this epic (the "Attacker-controlled content in the
admin same-origin context" watch-item, re-checked at 6b 2026-07-19 and confirmed still open/not
triggered because 6b ships no preview surface). Read `MEMORY.md`'s 6b entry (confirmed zero
`raw/1` usage anywhere in the media admin surfaces reviewed so far — HEEx-only auto-escaping is
the established, verified pattern). No accepted-risk entries in `BOND.md` apply to this diff.

### Independent re-verification of self-reported fixes (not rubber-stamped)

1. **`check_infected/1` guard (the real ATDD-caught bug).** Read `server/lib/nebu/media.ex`
   directly: `admin_override_infected/3`'s `with` chain is
   `validate_reason → authorize_override → lookup_state → check_infected → transition`.
   `check_infected(:infected)` → `:ok`; `check_infected(other)` →
   `{:error, {:invalid_transition, other, :released}}`, returned *before* `transition/4` is ever
   called. Confirmed real and correctly placed — this closes the privilege-relevant gap where
   `:scanning`/`:admin_blocked`/`:scan_failed` files (which legitimately have their own
   `-> :released` edges for other callers) could otherwise have been released through this
   narrowly-gated function without ever having been `:infected`.
2. **Confirm-button disabled wiring.** Confirmed `phx-change="validate_override_reason"` on the
   form, `handle_event("validate_override_reason", ...)` updating `@override_reason`, and
   `disabled={String.trim(@override_reason) == ""}` on the submit button. This is a client-side
   affordance only; independently confirmed `validate_reason/1` in `Nebu.Media` still performs the
   real server-side rejection regardless of what the UI allows (test 5/6/7/17 exercise this via
   `render_submit/1`, which bypasses the `disabled` HTML attribute by design).
3. **Focus-trap fix.** Confirmed `MediaOverrideConfirmModal`'s trap selector in
   `server/priv/static/assets/app.js` now excludes `:disabled` elements
   (`button:not(:disabled)`, etc.). Read the logic: without this exclusion, the disabled submit
   button (default state when the modal opens with an empty reason) would be tracked as the trap's
   "last" element while never actually receiving focus via native Tab order, so the wrap-around
   branch would never fire and Tab would escape the modal. This is a real UI/accessibility defect
   this reviewer independently re-derived as plausible from the code, not merely trusted from the
   dev's own claim — the fix is correct.

### Targeted checks (per orchestrator's explicit request)

1. **Stored-XSS via the new `reason` free text.** Traced where `reason` ends up:
   `media_state_transitions.metadata` (via `StateMachine.transition/4`'s existing write path) and
   `audit_log.metadata` (via `AuditWriter.log/6`). Grepped `server/lib/nebu/admin/media_live/detail.ex`
   (6b's detail view, the only surface that reads `media_state_transitions.metadata` at all) for
   any rendering of the per-transition `metadata` field — **none exists**; 6b's detail view only
   renders `scan_metadata`'s signature block (line ~356), never the transition-row `metadata` map
   itself. Result: this story's `reason` value is **not rendered anywhere in the current codebase**.
   Even if a future story added such rendering, the established, independently-verified convention
   across every media admin surface reviewed so far (5a, 6a, 6b) is HEEx-only auto-escaping with
   zero `raw/1` calls — the mechanism that would make this exploitable (an unescaped render) is not
   present anywhere in this domain today. Additionally, `reason` here is **admin-supplied**, not
   attacker/uploader-supplied — the realistic threat model for a self-authored value is self-XSS at
   worst, not the attacker-controlled-content class BOND.md's watch-item is about (uploaded file
   content). **Not a finding.** BOND.md's watch-item itself is unaffected by this story (no preview
   surface added) — forwarding it unchanged, as 6b did.
2. **`admin_id` provenance in the LiveView handler.** Confirmed
   `admin_id = actor_id(socket.assigns.current_user)` in `handle_event("confirm_override", ...)` —
   derived from the authenticated session assign, never from `params` (the event payload only
   supplies `media_id` and `reason`). A forged/replayed `phx-click`/form-submit payload cannot
   spoof `admin_id` to impersonate a different admin; it can at most attempt the action as the
   actual authenticated session's own identity, which `authorize_override/1` then independently
   re-checks against `media_admin_override`. No spoofing vector found.
3. **GRANT reasoning for migration 000030.** Independently read
   `server/priv/migrations/000001_init.up.sql:672`:
   `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app;` — a
   schema-wide, table-level grant (not column-scoped). PostgreSQL privileges are granted at the
   table level unless explicit column-level `GRANT ... (column) ON table` syntax is used, which it
   is not here; a table-level grant automatically covers any column added later via
   `ALTER TABLE ... ADD COLUMN`. Migration 000030 only `ALTER TABLE users ADD COLUMN
   media_admin_override ...` — no `CREATE TABLE` — so no additional `GRANT` statement is required.
   Confirmed correct, not merely asserted.
4. **Information-leak via check ordering.** Traced the exact sequence for an authenticated admin
   who lacks `media_admin_override`: `validate_reason/1` (pure function, no I/O) →
   `authorize_override/1` → `db_module().check_override_role(admin_id)`, a query keyed **only on
   `admin_id`** (`SELECT media_admin_override FROM users WHERE user_id = $1`) — it does not
   reference `media_id` at all. Because this check runs *before* `lookup_state(media_id)`, an
   unauthorized admin's call is rejected with `{:error, :forbidden}` **without ever querying the
   target file**, for literally any `media_id` value — nonexistent, released, infected, or any
   other state produce byte-identical rejection behavior and an identical (constant, media_id-
   independent) DB round trip. There is no differential timing or error-message channel by which
   an unauthorized admin could learn anything about a specific file's existence or state through
   this function. This is a well-designed property, not merely an absence of a flaw — worth naming
   explicitly rather than only checking the box.

### Additional scope checks (standard dimensions)

- **SQL injection:** both new queries (`check_override_role/1`, `lookup_scan_metadata/1`) use
  `Ecto.Adapters.SQL.query/3` with `$1` placeholders and a list parameter — no string
  interpolation. Clean.
- **CSRF:** no new HTTP endpoint; this is a LiveView `phx-*` event over the existing authenticated
  socket connection (same session/CSRF-token establishment as every other `Nebu.Admin.MediaLive`
  event, unchanged by this story). Clean.
- **Auth bypass / IDOR:** the override function requires both `system_role = 'instance_admin'`
  (the existing `on_mount(:require_admin)` gate to reach `/admin/media` at all) **and**
  `media_admin_override = true` (server-side re-checked, not UI-only) — a strictly narrower
  privilege than 6a's four routine actions. No route or event bypasses this. Clean.
- **Secrets:** no secrets, tokens, or credentials touched by this diff. Clean.
- **Migration safety:** `ALTER TABLE users ADD COLUMN ... BOOLEAN NOT NULL DEFAULT false` is a
  metadata-only operation in modern PostgreSQL (no full-table rewrite for a constant default) —
  no availability/performance concern on a live `users` table. Down-migration is a clean
  `DROP COLUMN`. Clean.
- **Security headers / CSP:** the confirm modal is CSP-safe by construction (no `window.confirm`,
  no inline `<script>`, JS logic lives in the existing bundled `app.js` referenced via `phx-hook`,
  consistent with the CSP posture already verified for 6a's Delete modal). Clean.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No CRITICAL, HIGH, MEDIUM, or LOW findings. | — |

### Detail

**INFO-1 — Mount-time-only grant flag (informational, not a vulnerability).**
`socket.assigns.media_admin_override?` is computed once at `mount/3` and never re-evaluated for
the lifetime of a LiveView connection. If an operator revokes an admin's `media_admin_override`
grant mid-session, that admin's already-open `/admin/media` tab keeps showing the Override button
until they reload or remount. This is a UI-staleness issue only — `authorize_override/1` re-checks
the grant server-side on every actual `confirm_override` call, so a revoked admin cannot complete
an override even with a stale button visible; they would see `{:error, :forbidden}`. Not a
security gap requiring a fix; noted for completeness, same category as this module's existing
mount-time-only `current_user` assign in general.

**INFO-2 — BOND.md watch-item re-confirmed unaffected (carried forward, not new).** The standing
"attacker-controlled content in the admin same-origin context" watch-item (uploaded file
preview/thumbnail rendering) does not apply to this story — 6c adds no file-content preview
surface, only an admin-authored reason textarea (HEEx-escaped, unrendered elsewhere) and a static
warning string. Forwarding this watch-item unchanged to whichever future story adds an actual
preview.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 2 (both non-blocking, informational only)

**Verdict: APPROVED**
