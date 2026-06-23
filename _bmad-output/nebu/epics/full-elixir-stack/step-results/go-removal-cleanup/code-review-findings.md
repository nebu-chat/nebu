# Code Review — go-removal-cleanup (admin OIDC login addition)

Date: 2026-06-17
Reviewer: pipeline (combined code-review + focused security pass per coordinator directive)
Cycle: 0
Scope reviewed: the admin OIDC Authorization-Code + PKCE login added to close the
coverage gap (NebuHttp.Admin.Auth, LoginController, Admin.Router, OidcPlug.verify_token/2,
runtime.exs, docker-compose.yml, helm secrets doc). The Go-removal work itself (ACs 1–6)
was reviewed in the prior dev-story pass and is unchanged here.

## Acceptance-criteria coverage

- The deleted Go admin login (gateway/internal/admin/auth.go LoginStartHandler +
  CallbackHandler) now has a migrated Elixir equivalent → the BLOCKED coverage gap is closed.
- AC1 no-go-files smoke: exit 0. AC2 compose: core-only, no gateway/media. AC3/AC5/AC6
  CI/renovate/Makefile: unchanged from prior pass. AC7 full-green CI: unit-elixir + smoke
  green; live integration/E2E deferred (stack down) — recorded, not silently capped.

## Findings

No MAJOR/CRITICAL. No MINOR requiring a dev cycle.

INFO-1 — `exchange_code/4` and `discover/2` perform live HTTP and are therefore covered
only by the live-Dex E2E (deferred here), not by ExUnit. This is inherent (no token
endpoint without a network). The pure security logic (PKCE derivation, state/nonce
validation, audience override, admin gate, session-expiry cap) IS unit-covered (13 tests).
Accepted: the E2E feature + steps are authored and will exercise the HTTP legs against the
running stack.

INFO-2 — `prompt=login` is always sent on the authorize request (parity with the Go
`oauth2.SetAuthURLParam("prompt","login")`). Forces re-auth; intentional.

## Focused security review (admin login) — Kassandra checklist

- PKCE: S256 only; verifier = 32 CSPRNG bytes → 43-char base64url (RFC 7636 range);
  challenge = BASE64URL(SHA256(verifier)) — asserted by unit test. PLAIN never offered. PASS
- State / CSRF: state generated CSPRNG, stored in the SIGNED Phoenix session (not a
  forgeable param), compared constant-time (Plug.Crypto.secure_compare), fail-closed on
  missing/expired (600s TTL). Forged callback → 400. PASS
- Nonce / replay: nonce in session, compared constant-time to the ID-token `nonce` claim;
  fail-closed when the stored nonce is absent (cannot match an absent token nonce). PASS
- ID-token validation: reuses OidcPlug.verify_token (alg allowlist → blocks alg:none + HMAC
  confusion; JWKS signature; fail-closed iss; exp; sub) + audience override (fail-closed; a
  Matrix-audience token is rejected on the admin path — asserted by a dedicated test). PASS
- Open redirect: redirect_uri is fixed server config (NEVER derived from Host/X-Forwarded
  headers); post-login target is the hardcoded /admin/rooms. PASS
- Session fixation: configure_session(renew: true) rotates the session id at login. PASS
- Unbounded session: session_exp capped at min(idToken.exp, now+8h), enforced in on_mount
  (expired admin → redirect to login). PASS
- Cookie flags: admin session cookie http_only:true, secure:true (default; relaxed only in
  test), SameSite=Lax (required for the cross-site OIDC callback). PASS
- Admin-claim gate: check_admin enforced before put_current_user; non-admin → 403. PASS
- TLS: token endpoint + JWKS + discovery all use verify_peer + hostname check for https
  (http only for the dev-internal Dex per ADR-012). PASS

### /_matrix + media auth-bypass re-verification (post Go removal)

NebuHttp.Router: public endpoints (login, auth_issuer/metadata, profile GET) → MatrixPublic
(intentionally unauthenticated); `/_matrix/media` and the catch-all `/_matrix` → Media /
Protected routers, which run OidcPlug. The admin change is confined to the separately
dispatched /admin subtree. verify_token/2 is backward-compatible (default opts preserve the
Matrix audience check; all existing OidcPlug tests pass). No new bypass window. PASS

## Verdict

CLEAN. No CRITICAL/HIGH/MAJOR. Proceed to commit.
