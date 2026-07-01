/**
 * Dex / OIDC preflight reachability check (canonical implementation).
 *
 * Story: e2e-browser-ci-and-dex-reliability (epic e2e-test-rehab) — AC1.
 *
 * Problem this solves:
 *   When Dex is NOT running in the local compose set, every OIDC flow fails deep
 *   inside the browser navigation (econnrefused dex:5556, SSO redirect → 503,
 *   empty JWKS). Playwright then surfaces this as a *silent* 30s navigation
 *   timeout in `loginViaOidcBrowser` / `global-setup`, which is slow and gives no
 *   actionable signal.
 *
 *   This preflight makes a couple of fast HTTP probes BEFORE any browser work and
 *   aborts within a few seconds with a clear "Dex unreachable" message that names
 *   the URL and the fix (`make dev`), instead of waiting out the navigation
 *   timeout.
 *
 * Plain ESM JavaScript (no transpile step) so it runs standalone via
 *   `node fixtures/dex-preflight.mjs`  (npm run preflight)
 * AND is importable from the TypeScript globalSetup (see dex-preflight.ts).
 * Dependency-free: uses the global `fetch` available in Node 18+.
 */

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
// Dex's OIDC discovery document. In local dev Dex is reached via the `dex` host
// alias (see `127.0.0.1 dex` in /etc/hosts); the issuer path is `/dex`.
const DEX_ISSUER = process.env.NEBU_OIDC_ISSUER ?? 'http://dex:5556/dex';

// How long a single probe may take before it counts as "unreachable".
// Kept short on purpose — the whole point is to fail FAST, not to wait out the
// 30s navigation timeout we are replacing. Configurable for very slow CI.
const PREFLIGHT_TIMEOUT_MS = Number(process.env.NEBU_E2E_PREFLIGHT_TIMEOUT_MS ?? 5_000);

export class DexUnreachableError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DexUnreachableError';
  }
}

async function probe(url, opts = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PREFLIGHT_TIMEOUT_MS);
  try {
    return await fetch(url, {
      method: opts.method ?? 'GET',
      redirect: 'manual',
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Assert that the OIDC stack (Dex + the server's SSO redirect) is reachable.
 *
 * Two complementary probes:
 *   1. The server's SSO redirect endpoint — `/_matrix/client/v3/login/sso/redirect`.
 *      With Dex up this returns a 3xx redirect (or 200); with Dex down the server
 *      cannot reach its issuer and returns 503 / errors.
 *   2. Dex's own OIDC discovery document — the authoritative reachability signal.
 *
 * Throws DexUnreachableError with an actionable message on failure. Resolves
 * (void) when the stack is reachable.
 */
export async function assertDexReachable() {
  const ssoUrl = `${MATRIX_BASE}/_matrix/client/v3/login/sso/redirect`;
  const discoveryUrl = `${DEX_ISSUER}/.well-known/openid-configuration`;

  // Probe 1: server SSO redirect. A reachable server returns a redirect (3xx) or
  // 200; a 5xx means the server is up but cannot reach Dex.
  let ssoStatus = 0;
  let ssoErr = null;
  try {
    const res = await probe(ssoUrl);
    ssoStatus = res.status;
  } catch (e) {
    ssoErr = e.message;
  }

  if (ssoErr) {
    throw new DexUnreachableError(
      `[preflight] Server SSO redirect unreachable at ${ssoUrl}: ${ssoErr}\n` +
      `  The Matrix server appears to be down. Start the stack with:  make dev\n` +
      `  (Browser e2e needs server + Dex up — not just \`make redeploy\`.)`
    );
  }

  if (ssoStatus >= 500) {
    throw new DexUnreachableError(
      `[preflight] Server SSO redirect returned ${ssoStatus} at ${ssoUrl}.\n` +
      `  This usually means Dex (the OIDC provider) is NOT running, so the server\n` +
      `  cannot reach its issuer. Bring Dex up:  docker compose up -d dex   (or: make dev)\n` +
      `  Aborting fast instead of waiting out a 30s browser navigation timeout.`
    );
  }

  // Probe 2: Dex discovery document — the authoritative reachability check.
  // Note: from the host this requires `127.0.0.1 dex` in /etc/hosts (the issuer
  // host is `dex`). If that mapping is missing the DNS lookup fails here with a
  // clear message rather than a browser timeout.
  try {
    const res = await probe(discoveryUrl);
    if (res.status >= 500 || res.status === 404) {
      throw new DexUnreachableError(
        `[preflight] Dex discovery at ${discoveryUrl} returned ${res.status}.\n` +
        `  Dex is not serving OIDC discovery. Bring it up:  docker compose up -d dex`
      );
    }
  } catch (e) {
    if (e instanceof DexUnreachableError) throw e;
    throw new DexUnreachableError(
      `[preflight] Dex discovery unreachable at ${discoveryUrl}: ${e.message}\n` +
      `  Either Dex is down, or \`127.0.0.1 dex\` is missing from /etc/hosts.\n` +
      `  Fix:  docker compose up -d dex   AND   'echo "127.0.0.1 dex" | sudo tee -a /etc/hosts'\n` +
      `  Aborting fast instead of waiting out a 30s browser navigation timeout.`
    );
  }
}

// Standalone CLI: `node fixtures/dex-preflight.mjs` (npm run preflight).
// Detect "run directly" by comparing the resolved module URL to argv[1].
const invokedDirectly =
  import.meta.url === `file://${process.argv[1]}` ||
  /dex-preflight\.mjs$/.test(process.argv[1] ?? '');

if (invokedDirectly) {
  assertDexReachable()
    .then(() => {
      console.log('[preflight] OIDC stack reachable (Dex + server SSO redirect). OK.');
      process.exit(0);
    })
    .catch((e) => {
      console.error(e.message);
      process.exit(1);
    });
}
