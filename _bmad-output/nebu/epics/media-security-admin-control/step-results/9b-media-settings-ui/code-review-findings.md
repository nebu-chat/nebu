# Code review — 9b-media-settings-ui (cycle 0)

Verdict: no MAJOR/CRITICAL. All 8 ACs verified PASS (two-phase validate-then-persist confirmed,
numeric coercion correct, bounds sit inside config.exs defaults, blank<->nil both directions
correct, AC3 SSRF reuse correct, AC4 nil->value logic reads `previous` before persist and fires
only nil->value, actor_id/1 safe, AC6/7/8 satisfied, ADR-018/020 clean, router placement correct,
template<->controller param names match, nav leaf doesn't disturb existing keyboard contract).

## MINOR

**MINOR-1 — persist/2's multi-key write is not atomic at the DB layer.** If key N of 9 fails at
the DB level after keys 1..(N-1) already committed (each `Config.upsert/3` independently writes +
audits + broadcasts), the system is left partially updated while the user sees a generic "Failed
to save" flash implying nothing was saved. Low probability (values already passed both the
controller's AND Config's own validation), and there's no cross-call transaction seam in Story 9a's
public API (ADR-020 constraint) — acceptable to leave un-fixed with an explanatory comment, or fix
via MINOR-2's changed-only optimization (which shrinks the blast radius to just the fields that
actually changed).

**MINOR-2 — every save unconditionally writes all 9 keys, not just changed ones.** Consequences:
(a) audit-log noise — a no-op save produces 9 `media_config_updated` audit entries, 8 with
old_value==new_value, plus 9 refresh/broadcast round-trips; (b) "default pinning" — the first save
ever writes explicit rows for all 9 keys, so a future `config.exs` default change is silently
ignored for any key an admin has ever saved through, even unintentionally — subtly undercuts AC1's
"env-var pre-fill on first load" intent for that key going forward. Fix: diff `changes` against
`previous` (already read for AC4) and only call `Config.upsert/3` for keys whose value actually
changed. AC5's test only asserts the one changed key and does not refute others, so this is a safe,
test-compatible change.

**MINOR-3 — AC4's "nil -> value" test has the SAME shared-ETS-under-integration isolation gap the
pipeline already fixed for the "falls back to config.exs default" test (test-review-fix / ci-gate
fix already applied to a sibling test), but this test was missed.** `test/nebu/admin/
media_settings_controller_test.exs` — the "changing released_delete_after_days from unset to a
concrete value..." test sets only `:media_config_writer`, not `:media_config_source`, so `previous
= Config.get()` inside the controller reads the real shared singleton ETS cache. Under `mix test
--include integration`, if any earlier test/run left a non-nil `released_delete_after_days` row in
the real dev Postgres, this test flakes (warning never fires because old_value isn't actually nil).
Fix: add `Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)` to this test,
mirroring the sibling "concrete->concrete" test right below it (which already does this correctly)
and the earlier ci-gate fix. Test-only change.

## INFO (non-blocking, no action required)

- INFO-1: webhook_url's SSRF.check/1 runs twice per save (once in the controller's own validation,
  once inside Config.upsert's own validate_value). Benign; shrinks automatically if MINOR-2 lands.
- INFO-2: `put_status(200)` before `render/2` is redundant (render/2 already defaults to 200) but
  self-documenting; no action needed.
- INFO-3: webhook_url input is `type="text"` not `type="url"` — cosmetic only, server-side
  validation is authoritative per AC2.

## Decision

Auto-cycling to dev-story per standing instruction (MINOR findings only, no MAJOR/CRITICAL).
