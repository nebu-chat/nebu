# code-review — e2e-browser-ci-and-dex-reliability (in-context, infra story)

Scope: e2e harness/config only (no server code). Reviewed against the 4 ACs.

## Findings: CLEAN (0 CRITICAL / 0 MAJOR / 0 MINOR)

### Verified
- AC1: preflight runs before any browser work in global-setup; fails fast (~0s,
  bounded by NEBU_E2E_PREFLIGHT_TIMEOUT_MS default 5s) with actionable messages.
  Both failure branches (server down, Dex down) exercised — exit 1, clear text.
- AC2: nav/form/panel timeouts env-configurable with raised defaults (60/60/45s);
  short detection probes intentionally left tight so genuine hangs aren't masked.
- AC3: e2e-element-web CI job is valid YAML, present, pinned to docker/amd64,
  brings Dex up via compose, runs the element-web project; Makefile recipe parses
  and preserves the registered localhost redirect origins (--add-host=dex).
- AC4: Makefile doc note distinguishes `make dev` (starts Dex) from `make redeploy`.
- TS toolchain: typecheck restored from 1498 errors to 0.

### Notes (non-blocking)
- Preflight logic lives once in .mjs; .ts is a typed facade — no duplication.
- e2e-element-web is manual+allow_failure, matching the existing integration-test
  policy (runner availability varies); structurally correct as the amd64 gate.

## Security review: SKIPPED (story frontmatter security_review: not-needed;
no auth/crypto/SQL/router code touched — only e2e tooling + CI config).
