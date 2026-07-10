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
 *
 * The `.mjs` MUST be loaded via dynamic `import()` (not a static import):
 * Playwright's on-the-fly transform compiles a static import in this `.ts` file
 * to CommonJS and drags the `.mjs` through the same CJS transform, which Node
 * then executes as native ESM — crashing global-setup with
 * "ReferenceError: exports is not defined in ES module scope" before any test
 * runs. A dynamic import() is left untransformed and loads the `.mjs` through
 * Node's real ESM loader. (Broke the whole suite at setup; fixed 2026-07-07,
 * pipeline story admin-sidebar-nesting.)
 */

/**
 * Assert that the OIDC stack (Dex + the server's SSO redirect) is reachable.
 * Throws `DexUnreachableError` with an actionable message on failure; resolves
 * (void) when reachable. Fails fast (~5s, configurable via
 * NEBU_E2E_PREFLIGHT_TIMEOUT_MS) instead of waiting out a 30s navigation timeout.
 */
export const assertDexReachable: () => Promise<void> = async () => {
  // @ts-expect-error — .mjs has no .d.ts; types are declared by this facade.
  const mod = await import('./dex-preflight.mjs');
  return mod.assertDexReachable();
};

/**
 * Resolve the error class thrown by {@link assertDexReachable} when the OIDC
 * stack is not reachable. Async because the canonical class lives in the ESM
 * `.mjs` (see module doc); use `err.name === 'DexUnreachableError'` for cheap
 * synchronous checks.
 */
export const getDexUnreachableError: () => Promise<typeof Error> = async () => {
  // @ts-expect-error — .mjs has no .d.ts; types are declared by this facade.
  const mod = await import('./dex-preflight.mjs');
  return mod.DexUnreachableError;
};
