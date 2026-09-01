# Code Review Report — Story 1c: Download-Gate Enforcement — Cycle 1 (Re-Review after Cycle-0 Fix)

**Verdict:** CLEAN / APPROVE. 0 MAJOR, 1 new MINOR (low-impact, non-blocking), several INFO carried.

## Cycle-0 finding disposition

- **MAJOR-1** (`String.to_existing_atom/1` uncaught raise → 500) — **RESOLVED.** New `parse_state/1` helper in `db.ex` rescues `ArgumentError` to a sentinel atom `:__unrecognized_media_state__`, which falls through `download_gate/1`'s catch-all to 451 M_NOT_YET_UPLOADED (not 404 — verified this is the spec-correct choice per AC6/ADR-026, better than the reviewer's originally-suggested `{:error, :not_found}` fix, which would have wrongly classified a pending/future state as terminal-404). Sentinel confirmed not to collide with any real `download_gate/1` clause.
- **MINOR-2** (AC6 tests never exercised the real string→atom path) — **RESOLVED.** New `server/test/nebu/media/media_download_gate_db_integration_test.exs` (`@moduletag :integration`) grows the `media_state` ENUM at runtime and drives a genuinely-never-interned raw string through the real `Nebu.Media.DB.lookup/2`, asserting 451. Structure verified sound (real-connection guard, cleanup, AC7 flunk-guard). `:integration` tagging confirmed conventional (mirrors `media_files_state_backfill_test.exs`), not a fast-suite coverage gap.
- **MINOR-3** (comment misattribution) — **RESOLVED.** Comment now correctly attributes atom-safety to both `download_gate/1` (5 states) and `Nebu.Media.StateMachine` (3 states).
- **MINOR-4** (deleted/state dual-source-of-truth) — **STILL OPEN by design**, correctly left untouched as an accepted epic-level follow-up. No regression.

## AC re-verification: all 7 ACs still MET, no regression introduced by the fix.

## New findings

### MINOR-A (NEW) — integration test leaks the `:media_storage_get_fun` app-env key
**Location:** `server/test/nebu/media/media_download_gate_db_integration_test.exs:111-119`.
**Detail:** `setup` sets four `:nebu_http` keys but `on_exit` only tears down three — `:media_storage_get_fun` (the AC7 flunking fake) is left set after the file finishes. Contradicts this suite's own isolation convention (every `Application.put_env/3` key torn down in `on_exit`), which the sibling unit file honors for this exact key.
**Impact:** low — every other media test that uses `MediaFakes.Storage` sets its own `:media_storage_get_fun`, so the leak is currently always overwritten before use. Latent risk only (a future test that forgets to set it would inherit a flunking fake).
**Fix:** add `:media_storage_get_fun` to the `on_exit` teardown list (one line).

### INFO (carried, unchanged, non-blocking)
- ENUM value growth in test DB is by-design/documented, disposable-stack assumption holds.
- 451-vs-404 status-only anonymity leak is intentional per ADR-026.
- "Media not found" string exists as 3 literals rather than 1 shared constant — convention-enforced, low risk.
- deleted/state drift — epic-level follow-up (same as MINOR-4).

## Summary
0 MAJOR. 1 new MINOR (MINOR-A, trivial one-line fix). No cycle-0 issue persists. Recommended: apply the one-line MINOR-A fix, then proceed.
