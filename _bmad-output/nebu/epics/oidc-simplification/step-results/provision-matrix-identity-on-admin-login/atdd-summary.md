# ATDD Step Result — provision-matrix-identity-on-admin-login

File modified: `server/test/nebu/admin/admin_oidc_login_test.exs` (existing file, per story's Implementation Map) — appended 4 new `describe` blocks.

## Tests added

- **AC1** (3 tests, `describe "AC1: normal_callback/2 provisions..."`) — use the `@behaviour Nebu.Matrix.Session.TokenValidator` + `:session_manager, :validator_module` seam (same DI point the real Matrix login uses) to assert a `validate/4`-equivalent call fires with the correct `matrix_user_id` for both `normal_callback/2` and `bootstrap_confirm_claim/2`, plus an idempotency test (two sequential admin logins, both must succeed).
  - **RED result**: all 3 FAIL with explicit assertion failures — correct RED, neither callback currently calls any Matrix provisioning path.
- **AC2** (1 test) — uses the `messages_db_module`/`:auto_join_test_listener` pattern from `auto_join_rooms_test.exs` to assert NO auto-join membership insert happens for a brand-new admin-provisioned identity.
  - Passes vacuously today (nothing provisioned yet). Test comment flags: once AC1 ships, this must keep passing UNLESS dev deviates from "no auto-join by default" with documented justification, in which case the assertion must flip to `assert_received`.
- **AC3/AC5** (2 tests, tagged `:integration`, mirroring `search_users_db_test.exs`) — real-Postgres tests asserting the admin-only-provisioned user appears in `Nebu.Admin.DB.list_users/3` and a subsequent real Matrix login doesn't duplicate/error. Excluded from unit run per project convention; run via `make test-integration`.
- **Regression guard** (2 tests) — pins existing `POST /_matrix/client/v3/login` 403 `M_FORBIDDEN` / 400 `M_NOT_JSON` contract untouched. Both PASS (baseline, unaffected).

## Full directory run

`test/nebu/admin/`: 234/237 passed, 21 excluded, 3 failed — the 3 failures are exactly the new AC1 RED tests. No collateral regression, clean seam isolation (proper `on_exit` cleanup, no global state leakage).

## Seams reused (no new seams invented)
- `:session_manager, :validator_module` (TokenValidator DI, same as real Matrix login path)
- `messages_db_module` / `:auto_join_test_listener` pattern (from `auto_join_rooms_test.exs`)
- Integration test tagging convention mirrored from `search_users_db_test.exs`
