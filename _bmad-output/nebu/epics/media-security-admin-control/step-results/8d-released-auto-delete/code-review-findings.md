# Code Review — Story 8d MediaReleasedAutoDeleteWorker (Cycle 0)

## Verdict: CLEAN (0 MAJOR/CRITICAL). 2 MINOR, 2 INFO.

### Verified correct (blast-radius / core AC checks)
- AC3/blast-radius bulletproof: nil -> zero DB writes in any branch, confirmed by reading source and Test 1.
- AC1 gate correct: nil/positive-int/everything-else classification, log+no-op on invalid.
- AC2 soft-delete-only via StateMachine, actor {:system, nil}, no hard-delete writes, no MediaCleanupWorker call.
- AC4 audit written only on {:ok, :deleted}, correct shape, known_actions updated.
- SQL: state='released' filter present, interval bound as STRING via Integer.to_string/1 (8a's DBConnection.EncodeError precedent correctly followed).
- Per-row isolation: rescue-wrapped, one file's forced error doesn't block the other (Test 2b confirms).
- "30" string test-design-bug claim independently re-verified against config.ex:448 coerce_value/2 — sound, no coverage gap (1.5 covers the non-integer branch).
- No rescue around Config.get/0 — verified validate_value/2 write-path guarantee holds; deliberate, documented, reasonable.

## MINOR findings (must fix before continuing)

1. **Effective threshold is N+1 whole days, not N — docs overstate parity with 8a.** The Elixir floor
   gate `released_for_days > days` sits on top of the sub-day SQL filter, so a file released 30 days +
   12h ago (config `30`) is skipped until it reaches a full 31 days (floor flips at `31.0`). 8a has NO
   floor gate — its boundary is pure sub-day SQL `<`. So 8d retains up to ~1 extra day versus 8a and
   versus the naive reading of the config value, yet the moduledoc, Test 4's name, and config.exs's
   comment all claim it "mirrors 8a's boundary." The behavior itself is safe (errs toward retention —
   correct direction for the largest-blast-radius worker in the epic) and is what makes Test 4
   deterministic against wall-clock drift; the issue is the misleading "mirrors 8a" framing and the
   unstated real semantic ("delete at N+1 days"). Fix: correct the moduledoc/comment wording to state
   the true N+1-day effective semantic instead of claiming exact parity with 8a.

2. **Production `released_for_days/1` clauses are untested.** Only the `is_integer` (test-only ms)
   clause is exercised by the unit test suite; the `%DateTime{}` and `%NaiveDateTime{}` clauses — the
   ONLY ones that actually run against real Postgres in production — have zero unit coverage. A
   regression in that day-arithmetic would pass the whole unit suite. Fix: add a real-DB/integration
   test (tagged `:integration` per this project's convention) that seeds a `media_state_transitions`
   row with a real `TIMESTAMPTZ` and asserts the worker correctly computes `released_for_days` against
   it end-to-end.

## INFO (non-blocking)
- The correlated `MAX(inserted_at) WHERE to_state='released'` subquery is computed twice per row
  (SELECT + WHERE); negligible at `LIMIT 1000`, a lateral join would be marginally cleaner.
- `perform` returning `:ok` on `:invalid` (no Oban retry) is the correct choice — retrying can't fix
  misconfiguration.

---

## Re-review (cycle 1) — CLEAN

Both MINOR fixes verified genuinely correct (not cosmetic):
- MINOR 1: corrected comment now accurately states the true N+1-whole-day safety-biased boundary
  semantic; confirmed 8a's process_row has NO equivalent floor guard (SQL-only boundary); config.exs
  cron comment already accurate (cadence/disjointness only, no parity claim), correctly left untouched.
- MINOR 2: new real-Postgres integration test genuinely exercises the %DateTime{} clause end-to-end;
  off-by-one sensitivity confirmed (31-day backdate vs 30-day window gives 1 day margin, a broken
  clause would fail the test, not silently pass).

3 INFO (all pre-existing convention shared with sibling media_cleanup_worker_integration_test.exs,
none blocking): unstopped Postgrex connection in migrate_role_conn!/0; non-transactional DISABLE/ENABLE
TRIGGER dance's hard-crash window; on_exit registered after seed (negligible orphan-row risk on crash).

**Verdict: CLEAN (0 MAJOR/CRITICAL).** Proceeding to security-review decision.
