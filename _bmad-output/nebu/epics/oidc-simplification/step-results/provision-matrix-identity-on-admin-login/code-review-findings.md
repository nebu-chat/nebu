# Code Review Report — provision-matrix-identity-on-admin-login

**Cycle 0** | Staged files: `server/lib/nebu/matrix.ex`, `server/lib/nebu/admin/auth.ex`, `server/test/nebu/admin/admin_oidc_login_test.exs`, `docs/architecture/08-concepts.md`, `docs/stories/oidc-simplification/provision-matrix-identity-on-admin-login.md`

## Verdict: PASS — no MAJOR or MINOR issues found. 2 INFO items.

The implementation is correct, ADR-020-compliant, well-tested, and matches the real Matrix `/login` provisioning path exactly where it should while deliberately diverging (auto-join) where AC2 requires.

## Acceptance Criteria coverage

| AC | Status | Evidence |
|----|--------|----------|
| AC1 — Admin login provisions Matrix identity | MET | `provision_matrix_identity/1` called in BOTH `normal_callback/2` (auth.ex:582) and `bootstrap_confirm_claim/2` (auth.ex:813), routed via `Nebu.Matrix.provision_identity/2` → `TokenValidator.validate/4` + `Profile.DB.upsert_profile/3` — the same pair the real `/login` path (`http_public.ex:332`) uses. Same `matrix_user_id` derived via `UserId.from_claims/2` with the same `server_name/0` the session carries. |
| AC2 — Auto-join decision | MET | Decision (provision YES, auto-join NO) implemented and documented in `docs/architecture/08-concepts.md` and story. `provision_identity/2` never calls `run_post_login_provisioning/2`. |
| AC3 — Admin appears in users list | MET | Integration test (admin_oidc_login_test.exs:961) asserts visibility via `Nebu.Admin.DB.list_users/3`. |
| AC4 — No duplicate-provisioning conflict | MET | Idempotency inherited from shared code: `UserProvisioner` UPDATE is `WHERE signing_key_id IS NULL`; `Profile.DB.upsert_profile` uses `COALESCE`. Integration test (line 883) asserts no duplicate row + user-set displayname survives. |
| AC5 — Regression test | MET | Integration test (line 961) covers admin-only-then-Matrix-login. |

## Oracle / Matrix-spec MUST checks

- User-ID grammar + same identity → same row: SATISFIED.
- Idempotency invariant: SATISFIED via shared idempotent code paths.
- ADR-020 (Admin reaches provisioning ONLY via `Nebu.Matrix` facade): SATISFIED.
- Three `validate/4` callers don't wrongly converge: CONFIRMED.

## Focus-point verification (all three cleared)

1. `repo_reachable?/0` guard — sound, does not gate-keep production provisioning.
2. Best-effort error swallowing — intentional, logged.
3. Ordering (`provision_matrix_identity` before `put_current_user`) — confirmed at both call sites.

## Test-review fix verification (all landed)

- MAJOR-1 (vacuous AC2 test): FIXED.
- MINOR-2 (AC4/AC5 split): FIXED.
- MINOR-3 (COALESCE displayname survival): FIXED.

## Findings

### INFO-1 — Persistent provisioning failure is invisible to operators (by design, monitoring gap)
Not actionable this cycle; flag if a future story adds provisioning-failure metrics.

### INFO-2 — Positive: avoided the read-only-guard/blank-placeholder anti-pattern
No action needed.

## Notes
- Only the 5 relevant files are staged; the unstaged `deploy/tofu/examples/upcloud/server.tf` change is unrelated and correctly excluded.
- `system_role` defaults to `"user"` in `provision_identity/2`, matching the real `/login` path.

No MAJOR/CRITICAL issues requiring user decision. No MINOR issues to hand back to the dev agent.
