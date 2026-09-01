# Code Review — 2d-download-stall-mechanism — cycle 1 re-review

**Verdict: PASS — both cycle-0 MINOR fixes verified correct, 0 MAJOR/CRITICAL introduced.**
One new MINOR surfaced (pre-existing, NOT a regression from this fix cycle) — non-blocking.

## MINOR-1 (atomics double-init race) — FIXED, verified
- `init_counter/0` (`download_stall.ex:155-161`) nil-guarded, idempotent, mirrors `:nebu_signing_key` precedent.
- Called at `application.ex:70`, strictly before `Supervisor.start_link/2` (line 159) — runs once, sequentially, before any request/await/counter_ref call is possible. Race genuinely eliminated, not narrowed.
- `counter_ref/0` (`download_stall.ex:185`) is now a pure `:persistent_term.get/1` with no fallback path. No reachable path runs it before `init_counter/0` (app boot precedes requests; `test_helper.exs:9` covers unit runs).

## MINOR-2 (negative-clamp FunctionClauseError) — FIXED, verified
- `clamped_stall_ms/1` (`media.ex:570`): `min(n, max(0, max_stall_ms()))` — re-derived exhaustively, always returns an integer `>= 0` for any config value.
- `maybe_await_stall/3` (`media.ex:581,583`) clauses (`<= 0`, `> 0`) are exhaustive for any integer — no FunctionClauseError possible for any value the clamp function can produce.
- New regression test (`media_download_stall_test.exs:555-585`, `max_stall_ms` in `[-1, 0]`) confirmed to genuinely pin the fix — traced through pre-fix code and confirmed it would have crashed/failed before the fix.

## Regression scope — clean
- Working-tree diff limited to exactly the 6 expected files. `state_machine.ex`/`scan_enqueue.ex` untouched (confirmed not in diff). `thumbnail/3` unchanged. All cycle-0 PASS items (race correctness, no duplicated deny-mapping, no busy-polling, param name, `:no_slot` degrade) still hold.
- No new startup-ordering risk introduced; `test_helper.exs` addition is idempotent and uses a private pt key untouched by any other test file.

## MINOR (new, pre-existing — NOT introduced by this fix, non-blocking)
- `media.ex:562-573` — `clamped_stall_ms/1` only has clauses for `nil` and `is_binary(raw)`. A query string producing a list value for `timeout_ms` (e.g. `?timeout_ms[]=1`) makes `conn.query_params["timeout_ms"]` a list, matching neither clause → `FunctionClauseError` → 500. Pre-existing since cycle 0 (only the binary-clause body changed for MINOR-2), not a regression from this cycle. Severity MINOR — a 500 on a malformed request, no auth/data-leak implication, no normal client triggers this. Suggested trivial fix: add a catch-all `defp clamped_stall_ms(_), do: 0`.

**Recommendation:** fixes are correct and complete; story is clear to proceed. The one new MINOR is cheap — auto-cycling once more to fold it in before moving to security-review/arc42/commit.
