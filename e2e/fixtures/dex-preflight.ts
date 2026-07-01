/**
 * Dex / OIDC preflight reachability check — typed facade.
 *
 * Story: e2e-browser-ci-and-dex-reliability (epic e2e-test-rehab) — AC1.
 *
 * The canonical implementation lives in `dex-preflight.mjs` (plain ESM, no
 * transpile step) so it can run standalone via `npm run preflight`
 * (`node fixtures/dex-preflight.mjs`). This `.ts` file is the typed entry point
 * imported by `global-setup.ts`, re-exporting the same symbols with types so the
 * `tsc --noEmit` typecheck gate stays meaningful.
 *
 * Single source of truth: do NOT duplicate the probe logic here — only types.
 */

// @ts-expect-error — .mjs has no .d.ts; types are declared by this facade.
import { assertDexReachable as _assertDexReachable, DexUnreachableError as _DexUnreachableError } from './dex-preflight.mjs';

/**
 * Assert that the OIDC stack (Dex + the server's SSO redirect) is reachable.
 * Throws `DexUnreachableError` with an actionable message on failure; resolves
 * (void) when reachable. Fails fast (~5s, configurable via
 * NEBU_E2E_PREFLIGHT_TIMEOUT_MS) instead of waiting out a 30s navigation timeout.
 */
export const assertDexReachable: () => Promise<void> = _assertDexReachable;

/** Thrown by {@link assertDexReachable} when the OIDC stack is not reachable. */
export const DexUnreachableError: typeof Error = _DexUnreachableError;
