/**
 * Nebu OAuth metadata / JWKS / token-refresh compatibility test (matrix-js-sdk 41.3.0)
 *
 * Story oauth-broker/oauth-token-endpoint, oracle C6 (Must #36), C1, C7, C11:
 *   1. validateAuthMetadataAndKeys(auth_metadata) passes: jwks_uri is REQUIRED by the SDK, the JWKS
 *      must be a `keys` array served as application/json; every key is a public EC/ES256 key.
 *   2. discoverAndValidateOIDCIssuerWellKnown(issuer) fetches EXACTLY
 *      new URL(".well-known/openid-configuration", issuer) (what OidcTokenRefresher does before
 *      every refresh, C7) and passes.
 *   3. OidcTokenRefresher.doRefreshAccessToken against the token endpoint:
 *        200 (refresh_token always present, C11)        => tokens, incl. refreshToken
 *        503 `{}` (Nebu's 5xx body, T20/C1)             => a retryable error, NOT TokenRefreshLogoutError
 *        400 {"error":"invalid_grant"}                  => TokenRefreshLogoutError (logout)
 *        503 {"error":"temporarily_unavailable"} (neg.) => TokenRefreshLogoutError — documents WHY
 *                                                          Nebu never sends `error` in a 5xx (C1)
 *
 * Story oauth-broker/oauth-versions-switch (story 9, AC6 / V11, Must #36, #48, #49):
 *   4. validateAuthMetadataAndKeys passes on the live document incl. story 6's account_management_uri /
 *      account_management_actions_supported.
 *   5. MatrixClient.getAuthMetadata() with a stubbed fetchFn: /versions = versions_on (fixture) =>
 *      requests /_matrix/client/v1/auth_metadata (isVersionSupported("v1.15")); versions_off =>
 *      requests /_matrix/client/unstable/org.matrix.msc2965/auth_metadata.
 *   6. S4 replay: versions_off + the unstable alias answering 503 {"errcode":"M_UNKNOWN"} =>
 *      getAuthMetadata() throws (observed behaviour, recorded, not "fixed").
 *   7. S3 replay: versions_off => the request goes to the unstable alias path (on Nebu the IdP
 *      passthrough, decision 7); only the requested path is asserted.
 *   A fixture WITHOUT versions_on / versions_off is a failure (the story-9 writer always adds both);
 *   skipped (logged) only in NEBU_MATRIX_URL mode.
 *
 * Inputs (one of):
 *   NEBU_OAUTH_FIXTURE=<path>  JSON {auth_metadata, jwks, openid_configuration} written by the ExUnit
 *                              test oauth_signing_keys_test.exs (NEBU_OAUTH_FIXTURE_OUT=<path>) from the
 *                              REAL Nebu responses. All fetches are stubbed (no network).
 *   NEBU_MATRIX_URL=<base>     a live Nebu with OAuth enabled: metadata, JWKS and openid-configuration are
 *                              fetched from it; ONLY the token endpoint is stubbed (scripted responses).
 *
 * Run ONLY from a copy of tests/matrix_compat (never `npm ci` inside the main checkout):
 *   cp package.json package-lock.json oauth_metadata_test.js /tmp/x && cd /tmp/x && npm ci
 *   NEBU_OAUTH_FIXTURE=/path/fixture.json node oauth_metadata_test.js
 *
 * Exit codes: 0 pass, 1 assertion failure, 2 not executed (no input configured).
 */

const FIXTURE = process.env.NEBU_OAUTH_FIXTURE;
const MATRIX_URL = process.env.NEBU_MATRIX_URL;

if (!FIXTURE && !MATRIX_URL) {
  console.log("[oauth-compat] not executed: NEBU_OAUTH_FIXTURE or NEBU_MATRIX_URL required");
  process.exit(2);
}

import { readFileSync } from "node:fs";

// ── browser globals oidc-client-ts / OidcTokenRefresher expect ───────────────
class MemoryStorage {
  constructor() { this.m = new Map(); }
  get length() { return this.m.size; }
  key(i) { return [...this.m.keys()][i] ?? null; }
  getItem(k) { return this.m.has(k) ? this.m.get(k) : null; }
  setItem(k, v) { this.m.set(k, String(v)); }
  removeItem(k) { this.m.delete(k); }
  clear() { this.m.clear(); }
}
globalThis.window = globalThis.window ?? { sessionStorage: new MemoryStorage(), localStorage: new MemoryStorage(), location: { href: "https://client.example.com/" } };
globalThis.sessionStorage = globalThis.sessionStorage ?? window.sessionStorage;
globalThis.localStorage = globalThis.localStorage ?? window.localStorage;

const realFetch = globalThis.fetch.bind(globalThis);
const fetched = [];
let tokenResponse = { status: 500, body: {} };
let tokenRequests = [];

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

let failures = 0;
function check(cond, msg) {
  if (cond) {
    console.log(`  ok   ${msg}`);
  } else {
    failures++;
    console.error(`  FAIL ${msg}`);
  }
}

async function loadDocuments() {
  if (FIXTURE) {
    const f = JSON.parse(readFileSync(FIXTURE, "utf8"));
    return {
      meta: f.auth_metadata,
      jwks: f.jwks,
      oidc: f.openid_configuration,
      tokens: f.token_responses ?? null,
      versionsOn: f.versions_on ?? null,
      versionsOff: f.versions_off ?? null,
      live: false
    };
  }
  const base = MATRIX_URL.replace(/\/$/, "");
  const meta = await (await realFetch(`${base}/_matrix/client/v1/auth_metadata`)).json();
  return { meta, jwks: null, oidc: null, tokens: null, live: true };
}

const docs = await loadDocuments();
const issuer = docs.meta.issuer;
const wellKnown = new URL(".well-known/openid-configuration", issuer).toString();

globalThis.fetch = async (input, init = {}) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
  fetched.push(url);
  if (url === docs.meta.token_endpoint) {
    tokenRequests.push({ method: init.method, body: String(init.body ?? "") });
    return json(tokenResponse.status, tokenResponse.body);
  }
  if (!docs.live) {
    if (url === wellKnown) return json(200, docs.oidc);
    if (url === docs.meta.jwks_uri) return json(200, docs.jwks);
    return json(404, { errcode: "M_UNRECOGNIZED", error: "not stubbed: " + url });
  }
  return realFetch(input, init);
};

const { validateAuthMetadataAndKeys, discoverAndValidateOIDCIssuerWellKnown, OidcTokenRefresher } = await import(
  "matrix-js-sdk/lib/oidc/index.js"
);
const { TokenRefreshLogoutError } = await import("matrix-js-sdk/lib/http-api/errors.js");

console.log(`[oauth-compat] issuer ${issuer} (${docs.live ? "live" : "fixture"})`);

// 1. validateAuthMetadataAndKeys (C6)
console.log("validateAuthMetadataAndKeys(auth_metadata)");
check(typeof docs.meta.jwks_uri === "string" && docs.meta.jwks_uri.startsWith("https://"), "jwks_uri present and https");
try {
  const validated = await validateAuthMetadataAndKeys(docs.meta);
  const keys = validated.signingKeys ?? [];
  check(Array.isArray(keys) && keys.length > 0, `signingKeys non-empty (${keys.length})`);
  check(keys.every((k) => k.kty === "EC" && k.crv === "P-256" && k.alg === "ES256" && k.use === "sig"), "every key EC P-256 ES256 sig");
  check(keys.every((k) => !("d" in k)), "no private member d in the JWKS");
} catch (e) {
  check(false, `validateAuthMetadataAndKeys threw: ${e && e.message}`);
}

// 2. discovery under the issuer (C7)
console.log("discoverAndValidateOIDCIssuerWellKnown(issuer)");
check(new URL(issuer).pathname === "/" || new URL(issuer).pathname === "", "issuer has an empty path (T31)");
try {
  fetched.length = 0;
  const cfg = await discoverAndValidateOIDCIssuerWellKnown(issuer);
  check(fetched[0] === wellKnown, `fetched ${wellKnown}`);
  check(cfg.issuer === issuer, "openid-configuration issuer byte-equal to auth_metadata issuer");
  check(cfg.jwks_uri === docs.meta.jwks_uri, "same jwks_uri");
} catch (e) {
  check(false, `discoverAndValidateOIDCIssuerWellKnown threw: ${e && e.message}`);
}

// 3. OidcTokenRefresher error mapping (C1, C11)
console.log("OidcTokenRefresher.doRefreshAccessToken");
const now = Math.floor(Date.now() / 1000);
const clientId = "compat-client";
const idTokenClaims = { iss: issuer, sub: "@alice:test.local", aud: clientId, iat: now, exp: now + 300, auth_time: now - 10 };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const fakeIdToken = `${b64({ alg: "ES256", kid: "k", typ: "JWT" })}.${b64({ ...idTokenClaims, iat: now + 1 })}.c2ln`;

async function refreshWith(status, body) {
  tokenResponse = { status, body };
  tokenRequests = [];
  const r = new OidcTokenRefresher(issuer, clientId, "https://client.example.com/cb", "AbCdEfGhIj", idTokenClaims);
  try {
    return { ok: await r.doRefreshAccessToken("a".repeat(64)) };
  } catch (e) {
    return { err: e };
  }
}

// Nebu's REAL answers when the fixture carries them (captured by oauth_signing_keys_test.exs),
// otherwise the documented shapes.
const real = docs.tokens;
if (real) console.log("  (replaying the token-endpoint responses captured from Nebu)");
const okResp = real ? real.ok : {
  status: 200,
  body: {
    access_token: "b".repeat(64),
    token_type: "Bearer",
    expires_in: 900,
    refresh_token: "c".repeat(64),
    scope: "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj",
    id_token: fakeIdToken
  }
};
const unavailableResp = real ? real.unavailable : { status: 503, body: {} };
const invalidResp = real ? real.invalid_grant : { status: 400, body: { error: "invalid_grant", error_description: "The refresh token is invalid." } };
{
  const res = await refreshWith(okResp.status, okResp.body);
  check(res.ok && res.ok.accessToken === okResp.body.access_token && res.ok.refreshToken === okResp.body.refresh_token, `200 => new tokens incl. refreshToken${res.err ? " (threw " + res.err.message + ")" : ""}`);
  const req = tokenRequests[0];
  check(req && req.method === "POST" && /grant_type=refresh_token/.test(req.body) && /client_id=compat-client/.test(req.body), "refresh request is form POST with grant_type + client_id");
  check(req && !/scope=/.test(req.body) && !/redirect_uri=/.test(req.body), "the refresher sends no scope and no redirect_uri (T13, C12)");
}
{
  const res = await refreshWith(unavailableResp.status, unavailableResp.body);
  check(res.err && !(res.err instanceof TokenRefreshLogoutError), `${unavailableResp.status} ${JSON.stringify(unavailableResp.body)} => retryable error, NOT a logout (${res.err && res.err.constructor.name})`);
}
{
  const res = await refreshWith(invalidResp.status, invalidResp.body);
  check(res.err instanceof TokenRefreshLogoutError, `${invalidResp.status} ${invalidResp.body.error} => TokenRefreshLogoutError (logout)`);
}
{
  const res = await refreshWith(503, { error: "temporarily_unavailable" });
  check(res.err instanceof TokenRefreshLogoutError, "negative control: a 5xx WITH an error member logs out (why Nebu sends {}) (C1)");
}

// 4.-7. story 9 (AC6 / V11): account fields + getAuthMetadata() prefix choice driven by /versions
console.log("story 9: account fields + getAuthMetadata() prefix choice (versions_on / versions_off)");
if (docs.live) {
  console.log("  skip story-9 replay: live mode (NEBU_MATRIX_URL) has no versions_on / versions_off pair");
} else if (!docs.versionsOn || !docs.versionsOff) {
  // A fixture from the story-9 writer always carries both: a missing pair is a broken fixture, not a skip.
  check(false, "NEBU_OAUTH_FIXTURE is set but versions_on / versions_off are missing (regenerate the fixture)");
} else {
  check(typeof docs.meta.account_management_uri === "string" && docs.meta.account_management_uri.startsWith("https://"), "account_management_uri present and https (story 6)");
  check(Array.isArray(docs.meta.account_management_actions_supported) && docs.meta.account_management_actions_supported.length > 0, "account_management_actions_supported present");
  try {
    await validateAuthMetadataAndKeys(docs.meta);
    check(true, "validateAuthMetadataAndKeys passes with the account fields");
  } catch (e) {
    check(false, `validateAuthMetadataAndKeys with the account fields threw: ${e && e.message}`);
  }

  const { createClient } = await import("matrix-js-sdk");
  const base = "https://matrix.example.test";

  // Builds a client whose fetchFn answers /versions with `versions`; `alias` is the answer of the
  // unstable MSC2965 alias ({status, body}); the stable path answers the live metadata.
  async function replay(versions, alias) {
    const requested = [];
    const fetchFn = async (input, init = {}) => {
      const url = new URL(typeof input === "string" ? input : input.url ?? input.toString());
      requested.push(url.pathname);
      if (url.pathname === "/_matrix/client/versions") return json(200, versions);
      if (url.pathname === "/_matrix/client/v1/auth_metadata") return json(200, docs.meta);
      if (url.pathname === "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata") return json(alias.status, alias.body);
      return json(404, { errcode: "M_UNRECOGNIZED", error: "not stubbed" });
    };
    const client = createClient({ baseUrl: base, fetchFn, accessToken: "x".repeat(64), userId: "@alice:test.local" });
    try {
      const md = await client.getAuthMetadata();
      return { requested, md };
    } catch (e) {
      return { requested, err: e };
    } finally {
      client.stopClient();
    }
  }

  const authPath = (r) => r.requested.find((p) => p.endsWith("/auth_metadata"));
  const onVersions = docs.versionsOn.versions ?? [];
  check(onVersions.includes("v1.15"), `versions_on lists v1.15 (${JSON.stringify(onVersions.slice(-2))})`);
  check(!(docs.versionsOff.versions ?? []).includes("v1.15"), "versions_off does not list v1.15");

  const on = await replay(docs.versionsOn, { status: 404, body: { errcode: "M_UNRECOGNIZED" } });
  check(authPath(on) === "/_matrix/client/v1/auth_metadata", `versions_on => STABLE /_matrix/client/v1/auth_metadata (requested ${authPath(on)})`);
  check(!on.err && on.md && on.md.issuer === docs.meta.issuer, `versions_on => metadata validated${on.err ? " (threw " + on.err.message + ")" : ""}`);

  // versions_off == S3 (disabled): on Nebu the unstable alias is the IdP passthrough (decision 7);
  // only the requested path is asserted (the IdP document itself is not Nebu's contract).
  const off = await replay(docs.versionsOff, { status: 200, body: docs.meta });
  check(authPath(off) === "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata", `versions_off / S3 => UNSTABLE alias, the IdP passthrough path (requested ${authPath(off)})`);

  // S4: server_config unreadable => Nebu answers the unstable alias 503 M_UNKNOWN.
  const s4 = await replay(docs.versionsOff, { status: 503, body: { errcode: "M_UNKNOWN", error: "unavailable" } });
  check(Boolean(s4.err), `S4 (unknown config): getAuthMetadata() throws on the 503 alias (observed: ${s4.err ? s4.err.constructor.name + " " + (s4.err.errcode ?? "") : "no error"})`);
}

if (failures > 0) {
  console.error(`[oauth-compat] ${failures} failure(s)`);
  process.exit(1);
}
console.log("[oauth-compat] all checks passed");
process.exit(0);
