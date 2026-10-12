# Test review — refresh-worker-and-retry-semantics (pre-dev)
Verdict: 0 MAJOR, 8 MINOR, 7 INFO. AC1–AC7 each have ≥1 test; AC8 (docs/comments) intentionally untested. No crash/restart test needed (RefreshWorker holds no state; Postgres is source of truth).

## MINOR (hand to dev-story; fix in tests where noted)
- M-1 (AC6): add `capture_log` + `refute log =~` for access token, refresh token, decrypted OIDC RT in worker transient + confirmed-rejection paths and in /refresh failure paths (No-Sensitive-Data law).
- M-2 (AC5): concurrent 8x /refresh test must also assert every 200 is consistent and that at least one 200 carries `access_token == active_row.access_token`, and that this AT works on whoami.
- M-3: worker-vs-refresh overlap is not forceable; document in a comment. Check DB pool size in test env (<8 may cause 5xx timeouts).
- M-4 (AC7): Retry-After not asserted. Decision for dev: 503 responses carry a `Retry-After` header; own rate limiter keeps `retry_after_ms` in body (429, legacy-only for non-refresh endpoints; see oracle: 429 on refresh makes clients log out — evaluate whether /refresh rate limit should answer 503+Retry-After; if changed, update the test).
- M-5: AC3D (old RT after expires_at in past => 401) vs AC4F (current RT with expired expires_at => 200): document the difference in a comment, add `refute soft_logout` to AC3D and assert the NEW RT behavior explicitly.
- M-6/M-7: backdating writes `created_at`, `revoked_at`, `grace_until` and "active row" = `revoked_at IS NULL`. If the dev's migration changes these (e.g. `consumed_at`), adapt tests to behavior, keep intent.
- M-8: remove vacuous assertion in AC3A (`Enum.all?(..., fn _ -> true end)`); replace by: old row revoked/marked, new row active. Avoid coupling AC3A to AC4 by consuming the old RT twice.

## INFO
- I-1: worker cycle is driven by `send(pid, :refresh)` + `:sys.get_state`; keep `handle_info(:refresh)` synchronous (no Task.async in cycle).
- I-2: worker processes ALL near-expiry rows in shared DB; tests are async:false with cleanup.
- I-3: existing `Process.sleep(10)`/`(5)` in refresh_worker_test.exs are outside this diff.
- I-4: 429 rate-limit test (40 req) depends on configured limit (regression guard).
- I-5 (optional): transient IdP failure on /refresh with an already rotated row must neither consume nor revoke.
- I-6: DB hiccup is simulated via `{:transient_check_failed, :db_down}` override only.
- I-7: ~18 of 46 tests are green regression guards by design.

## Run instructions from ATDD
Throwaway Postgres container `nebu_atdd_pg` on docker network `nebu_atdd` (already migrated); runner script `/private/tmp/claude-501/atdd_run.sh "<mix command>"`. Equivalent repo form: `make test-integration-elixir`.
