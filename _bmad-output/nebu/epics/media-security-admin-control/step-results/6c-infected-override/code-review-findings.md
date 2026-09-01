# Code Review — 6c-infected-override (cycle 0, self-reviewed by pipeline agent)

Diff reviewed: `git diff --cached` (1404 lines, 14 files). No sub-agents used per orchestrator
instruction — reviewed directly, adversarially, in three passes (blind logic/correctness pass,
edge-case pass, AC-conformance pass against the story text).

## Findings (all self-fixed inline, none left open)

**FIXED-1 (would have been MAJOR)** — `admin_override_infected/3` initially relied solely on
`StateMachine.transition/4`'s shared guard table to reject non-`:infected` source states, but
`:scanning -> :released`, `:admin_blocked -> :released`, and `:scan_failed -> :released` are all
independently legal edges for *other* callers (clean-scan result, 6a's admin_unblock, 4a's manual
clear). Calling `admin_override_infected/3` against a genuinely-`:scanning` file wrongly returned
`{:ok, :released}` instead of the AC1-required `{:error, {:invalid_transition, :scanning,
:released}}`. Caught by the story's own ATDD table-driven test 9 (RED against the first
non-infected state with such an edge) before dev-story completion. Fixed with an explicit
`check_infected/1` guard between `lookup_state/1` and `transition/4`. Verified via the full
table-driven test (all 7 non-infected states + `:released` separately = 8 total) — all green.

**FIXED-2 (MINOR/UX)** — The Override confirm modal's own code comment claimed "confirm button
stays disabled while reason is empty" (matching EXPERIENCE.md's explicit confirm-dialog
requirement), but no `disabled` binding or `phx-change` wiring existed — `@override_reason` never
tracked live typing, so the claim was aspirational, not implemented. Fixed: added
`handle_event("validate_override_reason", ...)` + `phx-change="validate_override_reason"` on the
form + `disabled={String.trim(@override_reason) == ""}` on the submit button. Verified: existing
test 17 (empty-reason submit) uses `render_submit/1` directly and is unaffected by the `disabled`
attribute (LiveViewTest doesn't respect it, by design — it exists specifically to prove
server-side enforcement independent of the UI affordance); re-ran the full LiveView test file
(39/39 green) plus the full 206-test scoped suite across every touched file (0 failures).

**FIXED-3 (MINOR/accessibility, self-introduced by FIXED-2, caught in the same review pass)** —
Adding the `disabled` binding to the submit button created a focus-trap leak in
`MediaOverrideConfirmModal`'s Tab-trap JS hook (`server/priv/static/assets/app.js`): a `:disabled`
element is excluded from the browser's native Tab order, so if the hook's `focusable` NodeList
still included the (now potentially disabled) submit button as its tracked "last" element,
`document.activeElement` could never actually equal it while disabled, the wrap-around branch
would never fire, and Tab from the Cancel button would escape the modal entirely whenever the
reason field is empty — the modal's own default just-opened state. Fixed by excluding disabled
elements from the trap's `querySelectorAll` selector (`:not(:disabled)` added to each element
type). `MediaDeleteConfirmModal` (6a's modal, no disabled buttons) is unaffected and left
unchanged. No automated coverage exists for real keyboard focus-trap behavior anywhere in this
repo (LiveViewTest doesn't simulate a real browser's focus/tab order) — same pre-existing gap
test-review's INFO-2 already flagged for 6a's Delete modal; not a new gap, verified by direct code
inspection of the trap logic and the `disabled` semantics rather than an automated test.

## AC Conformance (verified against final code, not just tests)

- AC1: `check_infected/1` guard, `@transitions` map extended additively (`infected -> :deleted` and
  `-> :released` both present) — confirmed.
- AC2: `validate_reason/1` — `is_binary` + `String.trim/1 != ""` check, first in the `with` chain —
  confirmed.
- AC3: sole call site of `StateMachine.transition/4` for this edge is `admin_override_infected/3`;
  no direct `Nebu.Admin.MediaLive` → `Nebu.Media.StateMachine` call anywhere (grep confirms) —
  confirmed.
- AC4: `write_admin_audit/4` called only on `{:ok, :released}`, metadata includes `reason` (trimmed)
  and `original_signature` (from `scan_metadata["clamav_signature"]`, the real 4b key) — confirmed.
- AC5: `media_infected_override` added to `@known_actions` in the same commit — confirmed.
- AC6: `authorize_override/1` re-checks `check_override_role/1` server-side independent of the
  LiveView's mount-time `media_admin_override?` flag; button hidden via `:if` in the template —
  confirmed both layers.
- AC7: literal warning text matches epic exactly; CSP-safe (`phx-hook`, no `window.confirm`, no
  `position: fixed`); Cancel has `autofocus`, Confirm never default-focused; Escape via
  `phx-window-keydown`; focus-trap fixed per FIXED-3 above — confirmed.
- AC8: no idempotent short-circuit branch exists in `admin_override_infected/3` (unlike
  `admin_block`/`admin_unblock`'s explicit `{:ok, :already_*}` cases); `override_reason` resets to
  `""` on open/cancel/success/reason_required/forbidden/invalid_transition/not_found — no caching
  path anywhere — confirmed.

## Migration / GRANT verification (per orchestrator's explicit gotcha check)

`server/priv/migrations/000030_media_admin_override_role.up.sql` only
`ALTER TABLE users ADD COLUMN ...` — does not `CREATE TABLE`. `users` already carries the blanket
`GRANT ... ON ALL TABLES IN SCHEMA public TO nebu_app` from `000001_init.up.sql`, which covers
columns added later via `ALTER TABLE ... ADD COLUMN` (no per-column GRANT exists in PostgreSQL).
Confirmed by reading `000001_init.up.sql` directly — no new GRANT statement needed, none added.
`migrations_grant_test.exs`'s down-migration list and `release_test.exs`'s version-list assertion
were both correctly extended to include `000030`.

## Verdict

**0 MAJOR/CRITICAL open. 0 MINOR open** (all three findings were caught and fixed in this same
review pass, each independently re-verified by test re-run or direct code/semantic inspection).
Proceeding to security review.
