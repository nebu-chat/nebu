# dev-story — e2e-browser-ci-and-dex-reliability

Infra/test-tooling story. Deliverables are e2e harness/config, not server code.

## Changes

### AC1 — fast Dex preflight (no silent 30s timeouts)
- `e2e/fixtures/dex-preflight.mjs` (NEW) — canonical, dependency-free ESM preflight.
  Two fast probes (server SSO redirect + Dex OIDC discovery), ~5s timeout
  (`NEBU_E2E_PREFLIGHT_TIMEOUT_MS`), throws `DexUnreachableError` with actionable
  message naming URL + fix (`make dev` / `docker compose up -d dex`). Runnable
  standalone (`npm run preflight`).
- `e2e/fixtures/dex-preflight.ts` (NEW) — typed facade re-exporting the `.mjs`
  (single source of truth; keeps `tsc --noEmit` meaningful).
- `e2e/global-setup.ts` — calls `assertDexReachable()` BEFORE any browser work.

### AC2 — emulation-tolerant, env-configurable timeouts
- `e2e/fixtures/dex-auth.ts` — navigation/form/panel waits now read
  `NEBU_E2E_NAV_TIMEOUT_MS` (default 60s, was 30/45s), `NEBU_E2E_FORM_TIMEOUT_MS`
  (60s), `NEBU_E2E_PANEL_TIMEOUT_MS` (45s). Short detection probes (consent ~6s,
  dialog dismiss ~2s, auto-redirect ~15s) left tight on purpose — raising them
  would mask genuine hangs.
- `e2e/playwright.config.ts` — element-web + admin-ui project `navigationTimeout`/
  `actionTimeout` now read `NEBU_E2E_NAV_TIMEOUT_MS` / `NEBU_E2E_ACTION_TIMEOUT_MS`.

### AC3 — element-web project wired into CI on amd64 with Dex up
- `.gitlab-ci.yml` — new `e2e-element-web` job (integration stage, docker-tagged
  amd64 DinD runner, manual + allow_failure mirroring integration-test). Runs
  `make test-e2e-element-ci`; uploads playwright-report/test-results artifacts.
- `Makefile` — new `test-e2e-element-ci` target: brings up full stack incl. Dex +
  element sidecar (`--profile e2e`), runs Playwright in a host-networked
  `mcr.microsoft.com/playwright` container with `--add-host=dex:127.0.0.1` so the
  browser reaches the localhost:7070/:8008/:5556 origins the Element config + Dex
  redirect URIs are registered for. Runs `npm run preflight` first (AC1).

### AC4 — doc note: make dev (not redeploy) for browser e2e
- `Makefile` `test-e2e-element` comment strengthened: FULL stack via `make dev`
  (NOT `make redeploy`, which doesn't start Dex); notes the preflight aborts fast
  if Dex is down.

### TS toolchain fix (env note #1 — meaningful typecheck)
- `e2e/package.json` — `typescript: ^6.0.2` (resolved to a broken pre-1.0-era
  artifact that can't parse modern TS, ~1498 tsc errors) → `~5.9.0`.
- `e2e/package-lock.json` — relocked to typescript 5.9.3.

## Validation
- `npm run typecheck` → exit 0 (was 1498 errors → 0).
- `npm run preflight` happy path → OK, ~0s. Dead Dex port → exit 1, clear
  "Dex unreachable" message, ~0s (well under 30s). Dead server port → exit 1,
  clear "server down → make dev" message.
- `npx bddgen` + `playwright test --list --project=element-web` → exit 0,
  22 tests listed (config + global-setup imports resolve).
- `make test-unit-elixir` → exit 0 (no server/ changes; regression gate clean).

## Not done (deliberate, per env notes)
- No forced green local Element browser run on emulated Dex — that flakiness is
  exactly what AC3 delegates to amd64 CI. Local validation is typecheck +
  preflight unit behavior + config load + elixir green.
