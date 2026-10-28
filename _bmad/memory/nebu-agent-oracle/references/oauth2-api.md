---
name: oauth2-api
code: oauth2-api
description: Deep reference for the Matrix OAuth 2.0 API (spec v1.15–v1.19, MSC2964/2965/2966/2967/4191) and the RFC rules Nebu must meet as Authorization Server (broker model). Use for compliance reviews of any story touching auth_metadata, DCR, authorize/token/revoke, scopes, refresh or account management.
---

# Matrix OAuth 2.0 API — Review Reference

Source of truth: `matrix-spec` `content/client-server-api/_index.md`, section "OAuth 2.0 API", and
`data/api/client-server/oauth_server_metadata.yaml`. Always re-check against the live spec (context7 first). Design
context: `_bmad-output/planning-artifacts/oauth-broker-spec.md`.

## Versions

| Version | Added |
|---|---|
| 1.15 | OAuth 2.0 API (authorisation code, refresh, revocation, DCR, scopes) |
| 1.18 | Device authorisation grant (RFC 8628), account management URL/actions, "OAuth 2.0 aware clients" compat |
| 1.12 | Account locking (`M_USER_LOCKED`, soft_logout true) |

A homeserver may support legacy, OAuth, or both. The APIs are **mutually incompatible**: clients MUST keep using the API
that issued their token. UIA does not work with OAuth tokens (exception: `/keys/device_signing/upload` via `m.oauth`).

## Server metadata (`GET /_matrix/client/v1/auth_metadata`, RFC 8414)

Required: `issuer` (https, no query/fragment), `authorization_endpoint`, `token_endpoint`, `revocation_endpoint`,
`registration_endpoint`, `response_types_supported` ⊇ {`code`}, `grant_types_supported` ⊇ {`authorization_code`,
`refresh_token`}, `response_modes_supported` ⊇ {`query`,`fragment`}, `code_challenge_methods_supported` ⊇ {`S256`}.
Optional: `prompt_values_supported` (`create`), `account_management_uri`, `account_management_actions_supported`,
`device_authorization_endpoint` (1.18), grant `urn:ietf:params:oauth:grant-type:device_code`.
Clients cache by HTTP caching headers. **Review trap:** passing an upstream IdP's metadata through (Dex has no
registration endpoint and no matrix scopes) is NOT compliant.

## Registration (RFC 7591)

- Client MUST register at the start of **each** authorisation flow. Server SHOULD dedupe identical metadata and MAY delete
  registrations without an active session (MUST NOT delete ones with active session).
- Success: `201 Created` with `client_id` + registered metadata. Errors: RFC 7591 3.2.2 (not Matrix errors).
- Redirect URI rules (MUST): no fragment. `web`: https, no userinfo, host under `client_uri`. `native`: private-use scheme
  = reverse-DNS of `client_uri` host, single slash / none, no authority; OR `http` loopback (`localhost`, `127.0.0.1`,
  `[::1]`) without port, server accepts any port at flow time; OR claimed https (web rules). Strict match at authorize.
- Localised metadata uses `key#lang`.

## Scopes (MSC2967)

- `urn:matrix:client:api:*` — full CS API access.
- `urn:matrix:client:device:<device_id>` — client allocates the device ID. **Exactly one** in the login flow.
  Charset advice `[A-Za-z0-9._~-]`, ≥10 chars (server MAY reject shorter); must stay within RFC 6749 scope chars
  (`%x21 / %x23-5B / %x5D-7E`).
- Unstable scopes use `urn:matrix:client:com.example.mscXXXX:foo`.

## Grants

**Authorisation code** — servers and clients MUST: support refresh grant; PKCE `S256`; pre-registered strict redirect URIs;
`fragment` response mode for clients with an https redirect URI. Authorize params: `response_type=code`, `client_id`,
`redirect_uri`, `scope`, `state`, `response_mode`, `code_challenge`, `code_challenge_method=S256`. Callback has `state`
plus `code` or `error` (+ `error_description`, `error_uri`). Token request: `grant_type`, `code`, `redirect_uri`,
`client_id`, `code_verifier`. Response: `access_token`, `token_type`, `expires_in`, `refresh_token`, `scope`.

**Device authorisation (1.18)** — `POST device_authorization_endpoint` (`client_id`, `scope`) → `device_code`, `user_code`,
`verification_uri` (+`_complete` RECOMMENDED), `expires_in`, `interval` (default 5). Poll with
`grant_type=urn:ietf:params:oauth:grant-type:device_code`; errors `authorization_pending`, `slow_down`, `access_denied`,
`expired_token`. MUST issue a refresh token.

**Refresh** — MUST issue a refresh token with every grant; access token MUST be short-lived; server SHOULD rotate the
refresh token and invalidate the old one, but MUST let the client retry if the response was lost; SHOULD treat reuse of an
invalidated token as compromise and revoke the session. Client: network/`5xx` → retry later with old token; `4xx` →
logged out.

**Revocation (RFC 7009)** — `POST revocation_endpoint`, form `token` (+ optional `token_type_hint`), access or refresh token.

All OAuth endpoint errors use RFC 6749 5.2 / RFC 7591 / RFC 8628 formats, **never** the Matrix error object.
Resource-server errors stay Matrix-style (`M_UNKNOWN_TOKEN`, `soft_logout`).

## Account management (1.18, MSC4191)

Optional metadata fields above. Actions: `org.matrix.profile`, `org.matrix.devices_list`, `org.matrix.device_view`,
`org.matrix.device_delete`, `org.matrix.account_deactivate`, `org.matrix.cross_signing_reset`. URL params: `action`,
`device_id`. OAuth-aware clients MUST send users to the URL for deactivation and for signing out other devices.

## "OAuth 2.0 aware clients" compat (1.18)

Server using OAuth MUST also: provide `m.login.sso`, provide `m.login.password` if previously enabled, set
`oauth_aware_preferred: true` on the SSO flow, support `action=login|register` on SSO redirect. SHOULD advertise the
account management URL.

## RFC baseline reviewers must apply (RFC 9700)

Exact redirect match; PKCE for all code flows; no implicit/password grants; single-use short-lived auth codes bound to
client + redirect + challenge; refresh rotation with reuse detection; `iss` response parameter (RFC 9207) recommended;
rate limits on register/token; no secrets in URLs or logs.

## Nebu review checklist

1. Metadata is Nebu's own (issuer = Nebu public https URL), all required fields present, no IdP passthrough.
2. DCR enforces redirect validation, dedupe, rate limit, policy mode; registration errors in RFC 7591 shape.
3. Exactly one device scope validated via `Nebu.Matrix.DeviceId.valid?/1`; `scope` echoed in token response.
4. PKCE S256 mandatory; code single-use, ≤60 s, atomic consume (cluster-safe, ADR-020).
5. Refresh rotation; the OLD refresh token stays valid until the NEW token is used (spec: "remains valid until the new access token or refresh token is used"; a fixed grace window is NOT compliant); reuse of a consumed token → revoke; IdP transient errors/429 → `503` + `Retry-After` and never delete (any `4xx` on refresh logs the client out); confirmed rejection → `400 invalid_grant`.
6. Access tokens short-lived; expired → `401 M_UNKNOWN_TOKEN` + `soft_logout: true`.
7. RefreshWorker never rotates OAuth sessions.
8. Revocation returns 200 for unknown tokens and deletes the whole session.
9. Sessions record `auth_api`; no UIA expectations on OAuth sessions.
10. Logs: `code`, `code_verifier`, `device_code`, `refresh_token`, `client_secret` redacted (No-Sensitive-Data law).
11. Legacy flows still work and `oauth_aware_preferred` is set.

## Client facts verified by the oracle (2026-10-07)

- matrix-dart-sdk 13 calls `auth_metadata` only if `/versions` reports ≥ v1.15, sends ONLY the unstable scopes
  `urn:matrix:org.matrix.msc2967.client:{api:*,device:<id>}`, caches metadata 3 days, treats only `404 M_UNRECOGNIZED`
  as "no OAuth", revokes with the (possibly expired) access token. Nebu must accept both scope prefixes and echo the
  request's prefix.
- matrix-js-sdk (corrected 2026-10-10, oracle gate of story oauth-authorize-idp-delegation-code): 41.3.0 sends
  `openid` plus the UNSTABLE prefix (`openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:<id>`),
  a client `nonce`, hard-codes `response_mode=query` (also for Element Web's https redirect URI) and validates an id_token in the
  token response (`iss` = Nebu issuer, `aud` = client_id, `nonce`); 10-char random device id, reads `oauth_aware_preferred` AND
  `org.matrix.msc3824.delegated_oidc_compatibility`, checks `errcode` first (OAuth errors must not carry it), knows `m.oauth` UIA.
- Device-ID charset: scope chars `%x21 / %x23-5B / %x5D-7E` are a MUST; `Nebu.Matrix.DeviceId.valid?/1` is looser and unsuitable for the scope path.
- `auth_issuer` is not in spec 1.19. `M_USER_LOCKED` needs an account-lock feature Nebu does not have.
- Revocation: `client_id` optional, revoke anyway; MUST revoke both access and refresh token.
- Fragment response mode: the "Authorisation code grant" bullet is a joint homeserver/client MUST read as "support it"; the
  "Callback" section only says the CLIENT SHOULD choose fragment. Servers must support BOTH `query` and `fragment` and honour
  the requested mode (rejecting `query` for https redirect URIs breaks Element Web). Unknown `grant_types`/`response_types` in DCR are ignored, not rejected.

## Not in the Matrix spec (Nebu extensions — flag as such in reviews)

`client_credentials`, mTLS (RFC 8705), certificate-bound tokens, `private_key_jwt` (RFC 7523), non-spec DCR policies.
These must not change any behaviour required above and must be opt-in per registered client.
