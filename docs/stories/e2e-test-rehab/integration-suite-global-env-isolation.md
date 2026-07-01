---
epic: e2e-test-rehab
story: integration-suite-global-env-isolation
security_review: not-needed
---

# Story: Fix order/seed-dependent global-env test-isolation failures in the integration suite

Status: backlog

## Story

As a developer running the full integration suite,
I want tests that mutate shared `:nebu_http` Application-env (and other global state) to
save+restore it, so that the suite passes deterministically regardless of ExUnit ordering/seed
instead of leaking state into later tests.

## Context

While rebasing `client-crypto-setup` onto main (2026-06-30), the full integration suite
(`mix test --include integration`) showed order/seed-dependent failures rooted in shared global
`:nebu_http` Application-env leaking across tests:

- **Already fixed in client-crypto-setup** (precedent/pattern): two admin tests set
  `:admin_csrf_bypass` without restoring it (`users_index_link_test` did `delete_env` →
  dropped to the `false` default; `device_management_test` "CSRF" describe set `false` with no
  `on_exit`). Depending on ExUnit order, this leaked CSRF enforcement into later admin tests →
  14 spurious `Plug.CSRFProtection.InvalidCSRFTokenError`. Fixed via save+restore.

- **Still failing on `origin/main` itself** (this story): the full integration suite on
  `origin/main` fails **3** tests, of which **2 are isolation failures** (the 3rd is a flaky
  perf test, see below):
  - `Nebu.Web.OidcPlugTest` — "token denylist (F-1): a denylisted token (by jti) → 401
    M_UNKNOWN_TOKEN even though it verifies"
  - `Nebu.Matrix.MatrixSsoTest` — "callback mints loginToken; POST /login completes … single-use"

  Both pass in isolation; both fail in the full suite. Same class as the admin_csrf_bypass leak:
  a test elsewhere in the suite leaves shared global state dirty (likely OIDC config seam
  `:oidc_config_source` / `:oidc_jwks` / `:server_name`, the `Nebu.Web.TokenDenylist` ETS, or
  the SSO/login store) that breaks these when they run in the polluted window.

This is **pre-existing main debt** — not introduced by `client-crypto-setup` (it reproduces on
`origin/main`'s own full suite). It is currently masked because the CI `integration-test` job is
`manual` + `allow_failure`.

## Repro

```
docker compose up -d --wait
# against origin/main (or any branch):
mix test --include integration
# → ~3 failures: OidcPlugTest (token denylist), MatrixSsoTest (loginToken), RegressionSyncLoadTest
# Each of the first two PASSES when run in isolation:
mix test --include integration test/nebu/web/oidc_plug_test.exs
mix test --include integration test/nebu/matrix/matrix_sso_test.exs
```

## Acceptance Criteria

1. Identify the polluting test(s) that leave shared global state dirty for `OidcPlugTest` and
   `MatrixSsoTest` (bisect by file/seed; suspects: tests mutating `:nebu_http` OIDC seam env,
   the token denylist ETS, or SSO/login global state without `on_exit` restore).
2. Fix the offending tests to **save + restore** prior global state (the pattern used for
   `admin_csrf_bypass` in `client-crypto-setup`), or isolate the state per test.
3. `mix test --include integration` passes deterministically across multiple seeds (e.g.
   `--seed 0`, `--seed 1`, and a few random) with **0 isolation failures** — only genuinely
   flaky/perf tests may remain (AC4).
4. `Nebu.Web.RegressionSyncLoadTest` (200 concurrent /sync, median latency ≤150ms) is a
   timing-sensitive perf test, not an isolation failure. Either stabilize it (raise/parameterize
   the latency bound for CI hardware) or tag it so it does not count as a suite failure. Document
   the decision.
5. Optional hardening: a lightweight ExUnit `on_exit`/setup audit (or a shared helper) so future
   tests don't reintroduce `:nebu_http` env leaks.

## Acceptance Tests

1. OidcPlug + MatrixSso green in full suite — Integration
   - Given: the full integration suite runs (any seed)
   - When: `mix test --include integration`
   - Then: `Nebu.Web.OidcPlugTest` and `Nebu.Matrix.MatrixSsoTest` pass (no order-dependent failure)

2. Deterministic across seeds — Integration
   - Given: seeds 0, 1, and 2 random seeds
   - When: the full suite runs each
   - Then: 0 isolation failures in every run
