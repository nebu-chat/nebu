/**
 * Stub servers for the OAuth client redirect targets of the e2e suite.
 *
 * WHY: the oauth / legacy-SSO scenarios send the browser through a REAL server redirect (`302 Location:
 * https://app.e2e.example/cb?code=...`) to a "client" that does not exist in the stack. Playwright cannot
 * intercept that hop: `page.route` / `context.route` are called ONLY for the first URL of a redirect chain
 * (https://playwright.dev/docs/network, "Redirects"), the browser follows the redirect on its own and would try
 * to connect to the real target (ERR_CONNECTION_REFUSED / ERR_NAME_NOT_RESOLVED). The scenarios read the final
 * URL (code / error / state / iss), so something has to answer there. This module does it at the network level:
 *
 *   - http://localhost:53682 (the native loopback client) and http://localhost:7070 (the Element origin of the
 *     plain-http compose stack, only started when nothing listens there) answer a stub page,
 *   - an HTTPS stub (self-signed certificate generated at runtime with `openssl`, never committed) listens on
 *     STUB_HTTPS_PORT; playwright.config.ts maps `*.e2e.example:443` and `evil.example.com:443` to it with
 *     Chromium's `--host-resolver-rules` and sets `ignoreHTTPSErrors` for the admin-ui project.
 *
 * Nothing here weakens the system under test: the stubs only answer the CLIENT side of the redirects.
 */
import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import * as os from 'node:os';
import * as path from 'node:path';

export const STUB_HTTPS_PORT = Number(process.env.NEBU_E2E_STUB_HTTPS_PORT ?? 8443);

/** Chromium args: the fake client hosts resolve to the local HTTPS stub (port 443 -> STUB_HTTPS_PORT). */
export const STUB_HOST_RESOLVER_RULES =
  `MAP *.e2e.example:443 127.0.0.1:${STUB_HTTPS_PORT}, MAP evil.example.com:443 127.0.0.1:${STUB_HTTPS_PORT}`;

/**
 * Chromium launch args of every browser of the suite: the fake client hosts resolve to the stub, and certificate errors are ignored
 * browser-wide (the stub's self-signed certificate; the local CA of the https oauth stack, dev/tls): a browser-wide flag, because
 * `browser.newContext()` of the steps does NOT inherit the `ignoreHTTPSErrors` of the project `use`.
 */
export const STUB_CHROMIUM_ARGS = [`--host-resolver-rules=${STUB_HOST_RESOLVER_RULES}`, '--ignore-certificate-errors'];

// The page of the legacy SSO scenarios (their STUB_HTML): reports whether a popup kept its opener (data-opener) and offers window.startLogin.
const PAGE =
  '<!doctype html><html><head><meta charset="utf-8"><title>client stub</title></head><body data-opener="pending"><p>client</p>' +
  '<script>document.body.setAttribute("data-opener", String(window.opener !== null));' +
  'window.startLogin = function (u) { window.open(u); return true; };</script></body></html>';

function handler(_req: http.IncomingMessage, res: http.ServerResponse): void {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(PAGE);
}

function listen(server: http.Server | https.Server, port: number): Promise<boolean> {
  return new Promise((resolve, reject) => {
    server.once('error', (e: NodeJS.ErrnoException) => (e.code === 'EADDRINUSE' ? resolve(false) : reject(e)));
    server.listen(port, '0.0.0.0', () => resolve(true));
  });
}

/** Starts the stubs; resolves to the teardown function (Playwright calls it after the run). */
export async function startClientStubs(): Promise<() => Promise<void>> {
  const servers: Array<http.Server | https.Server> = [];

  for (const port of [53682, 7070]) {
    const s = http.createServer(handler);
    if (await listen(s, port)) servers.push(s);
    else console.log(`[client-stubs] port ${port} is already served (the real thing): no stub started`);
  }

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nebu-e2e-stub-'));
  const key = path.join(dir, 'key.pem');
  const crt = path.join(dir, 'crt.pem');
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=nebu-e2e-client-stub',
    '-keyout', key, '-out', crt,
  ], { stdio: 'pipe' });
  const secure = https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(crt) }, handler);
  if (await listen(secure, STUB_HTTPS_PORT)) servers.push(secure);
  else console.log(`[client-stubs] port ${STUB_HTTPS_PORT} is already in use: HTTPS stub not started`);
  fs.rmSync(dir, { recursive: true, force: true });

  console.log(`[client-stubs] started (${servers.length} listeners)`);
  return async () => {
    await Promise.all(servers.map((s) => new Promise<void>((r) => s.close(() => r()))));
  };
}
