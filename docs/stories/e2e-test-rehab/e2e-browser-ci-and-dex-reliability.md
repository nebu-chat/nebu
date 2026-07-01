---
epic: e2e-test-rehab
story: e2e-browser-ci-and-dex-reliability
security_review: not-needed
---

# Story: Reliable browser e2e — Dex up + amd64 CI + emulation-tolerant timeouts

Status: done

## Story

As a developer running Element e2e locally and in CI,
I want the browser suite to run against a reachable Dex with timeouts that tolerate
slow/emulated environments,
so that browser verification is dependable instead of timing out.

## Context

During `client-crypto-setup` verification (2026-06-29):
- **Dex was not running** in the dev compose set (only element/minio/postgres/server were up).
  All OIDC failed (`econnrefused dex:5556`, SSO redirect → 503, JWKS empty → old tokens
  `M_UNKNOWN_TOKEN: no_keys`). Starting `docker compose up -d dex` fixed reachability.
- On Apple Silicon, the `dexidp/dex` image is **amd64 emulated on arm64** and slow; the
  global-setup storageState warming (`page.waitForURL`, 30s) and `loginViaOidcBrowser` timed
  out before token capture, so token sidecars were never written.

Aligns with the known brittle-e2e workstream (memory: project_e2e_suite_health).

## Acceptance Criteria

1. The e2e runner fails fast with a clear message if Dex is not reachable (preflight check on
   `/_matrix/client/v3/login/sso/redirect` or Dex discovery), instead of silent 30s timeouts.
2. Warmup / login navigation timeouts are configurable (env) and raised enough to tolerate
   emulated Dex locally (e.g. 60–90s), without masking genuine hangs.
3. The `element-web` Playwright project runs in CI on an **amd64** runner (non-emulated Dex),
   wired into the pipeline CI gate, with Dex brought up as a dependency.
4. `make` target / docs note that `make dev` (not just `make redeploy`) must bring up Dex for
   browser e2e.

## Acceptance Tests

1. preflight fails clearly without Dex — ExUnit/script or Playwright global-setup assertion
   - Given: Dex is down
   - When: the e2e suite starts
   - Then: it aborts with "Dex unreachable" within a few seconds (not a 30s navigation timeout).

2. element-web suite green in CI (amd64) — CI pipeline
   - Given: the CI element-web job with Dex up
   - When: `@ac6-login` runs
   - Then: it passes (no emulation timeout).
