# Security Review — `oidc-middleware-migration` (SEC Gate 1)

- **Reviewer:** Kassandra (adversarial security review)
- **Date:** 2026-06-17
- **Story:** `docs/stories/full-elixir-stack/oidc-middleware-migration.md` (status: review, `security_review: required`)
- **Scope:** Elixir-side OIDC Bearer-token validation (Plug + JWKS cache) and the dormant Go pass-through toggle.
- **Branch:** `feature/full-elixir-stack`

## Verdict

**SECURITY: CLEAN — 0 CRITICAL / 0 HIGH** (commit not blocked)

3 MEDIUM, 2 LOW, 2 INFO follow-up advisories. None block the commit. The auth-critical JWT validation path is sound for the RSA/Dex deployment this story ships; the MEDIUMs are hardening items that must be closed before the Elixir `OidcPlug` becomes the live request authority in `matrix-api-migration`.

## Files reviewed

- `core/apps/nebu_http/lib/nebu_http/plugs/oidc_plug.ex`
- `core/apps/nebu_http/lib/nebu_http/jwks_cache.ex`
- `core/apps/nebu_http/lib/nebu_http/router.ex`, `.../router/protected.ex`
- `core/apps/nebu_http/lib/nebu_http/application.ex`
- `core/config/runtime.exs`, `core/config/test.exs`
- `gateway/internal/middleware/auth.go`
- `docker-compose.yml`
- Dependency: `core/deps/assent/lib/assent/jwt_adapter/assent_jwt.ex` (0.3.1) — the actual verifier behind `Assent.JWTAdapter.verify/3`

## Adversarial trace of the JWT validation path (the core of this review)

`OidcPlug.verify_token/1` chains: `peek_kid` → `select_key(kid)` → `Assent.JWTAdapter.verify(token, jwk, [])` → `check_exp` → `check_issuer` → `check_audience` → `check_subject`.

**alg-confusion (RSA→HMAC) — BLOCKED.** The default adapter is `Assent.JWTAdapter.AssentJWT` (no override passed). Its `verify_message/4` HMAC clause is guarded by `when is_binary(secret)`. The key handed in is a JWK **map** (`%{"kty"=>"RSA",...}`), so a forged `alg:"HS256"` token does not match the HMAC clause; it falls through to the `<<_, "S", sha_bit_size::binary>>` clause (which `"HS256"` *does* structurally match), decodes the RSA public key, and runs `:public_key.verify/4` — the HMAC bytes fail RSA verification → `verified?: false` → `:bad_signature` → 401. Confirmed fail-closed.

**alg:none — BLOCKED.** `verify_message(_, _, "none", _) -> {:ok, false}` → `verified?: false` → 401.

**Unknown/unmatched alg — BLOCKED.** No catch-all `verify_message` clause exists; an unmatched alg raises `FunctionClauseError`, caught by the `rescue`/`catch` in `assent_verify/2` → `{:error, :verify_failed}` → 401.

**Missing `exp` — REJECTED** (`check_exp/1` fallback clause → `:missing_exp`; cycle-0 MINOR-3). Verified by test.
**Missing/empty/non-string `sub` — REJECTED** (`check_subject/1`; cycle-0 MINOR-4). Verified by two tests.
**Tampered signature — REJECTED** (test flips a signature byte → 401). Verified.
**iss / aud — CHECKED** when configured; `aud` correctly handles both string and list forms. `NEBU_OIDC_ISSUER` and `NEBU_OIDC_AUDIENCE` are both set on the `core` service in `docker-compose.yml` (lines 117–118), so both checks are live in the shipped stack.

**Conclusion:** the cycle-0 fixes are real and the validation path has no exploitable bypass for the RSA-keyed Dex/Keycloak deployment this story targets.

## Dormancy confirmation (AC6)

- `NEBU_OIDC_VALIDATION_DISABLED` appears in `docker-compose.yml` **only as a comment** (line 70) — it is never set. `oidcValidationDisabled()` defaults to `false`, so the Go gateway continues full JWT verification (`verifier.Verify`, `SupportedSigningAlgs`, exp/aud) on the live `/_matrix` path. **Confirmed OFF.**
- No reverse proxy routes `/_matrix` to `core:4000`; the Go gateway (`:8008`) remains the live Matrix entrypoint. The Elixir `OidcPlug` is not on the production request path yet. Dormancy claim holds.
- `decodeUnverifiedClaims` is reachable only inside the `validationDisabled` branch and only base64url-decodes the payload (no signature trust); since the toggle is OFF it is dead code at runtime. No issue.

---

## Findings

### MEDIUM-1 — JWKS fetched over `:httpc` with no TLS peer verification (and no scheme guard)
**File:** `core/apps/nebu_http/lib/nebu_http/jwks_cache.ex:149-150`
`:httpc.request(:get, {uri, []}, [], body_format: :binary)` passes an empty HTTP-options list — Erlang `:httpc` performs **no certificate verification** for `https://` unless `ssl: [verify: :verify_peer, cacerts: ..., customize_hostname_check: ...]` is supplied. Combined with `NEBU_OIDC_JWKS_URI` being a raw env string with no `https://` scheme assertion, an on-path attacker (or an operator who configures `http://`) can serve attacker-controlled signing keys. Because those keys are then trusted by `OidcPlug` to verify Bearer tokens, this is a **full auth-bypass primitive once `OidcPlug` goes live**. Currently MEDIUM (not HIGH) only because the plug is not yet the live authority and the dev URI is Docker-internal.
**Remediation:** Pass `ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)], depth: 3]` to the `:httpc` HTTP-options. Reject non-`https://` `NEBU_OIDC_JWKS_URI` in `runtime.exs` (mirroring the gateway's `NEBU_ALLOW_INSECURE_OIDC_ISSUER` dev-only escape hatch). Must land **before** `matrix-api-migration` flips the toggle.

### MEDIUM-2 — No algorithm allowlist in `OidcPlug` (relies on adapter pattern-match structure)
**File:** `core/apps/nebu_http/lib/nebu_http/plugs/oidc_plug.ex:106-112`
The Go side pins `SupportedSigningAlgs` (`ParseSupportedAlgs`); the Elixir side has no equivalent. Token-header `alg` is fed straight into `Assent.JWTAdapter.verify/3` and the only protection against alg-confusion is the incidental structure of `AssentJWT.verify_message/4` clauses (traced above — currently fail-closed for RSA). This is defense-by-accident: a future Assent upgrade that adds an HMAC clause accepting `map` secrets, or a deployment that adds an EC/`oct` key to the JWKS, could change the calculus. Symmetric (`oct`/HS*) keys must never be accepted from a JWKS endpoint.
**Remediation:** Before `assent_verify`, assert the token-header `alg` is in an explicit allowlist (e.g. `["RS256","RS384","RS512","ES256","ES384","ES512"]`) and reject any `HS*`/`none`/symmetric alg outright. Also reject JWKs whose `"kty"` is `"oct"`. Add a regression test pinning an `alg:"HS256"` token signed with the public-key bytes → 401.

### MEDIUM-3 — `iss`/`aud` checks silently skip when config is unset (OIDC fail-open on misconfiguration)
**File:** `core/apps/nebu_http/lib/nebu_http/plugs/oidc_plug.ex:127-139`
`check_issuer`/`check_audience` return `:ok` when `oidc_issuer`/`oidc_audience` are `nil`. `runtime.exs` reads these from env with no `raise` on absence. An operator who forgets `NEBU_OIDC_AUDIENCE`/`NEBU_OIDC_ISSUER` gets a server that accepts any validly-signed token from any audience/issuer the JWKS can verify — the recurring "OIDC fail-open at startup" pattern (MEMORY, Epic 12). Compose sets both today, so this is latent, not active.
**Remediation:** When `OidcPlug` becomes the live authority, make `oidc_issuer` and `oidc_audience` mandatory in `runtime.exs` for `:prod` (raise if unset), or have `OidcPlug` fail-closed (reject all) when they are `nil` rather than skipping the check. Decision must be explicit, not a silent default.

### LOW-1 — `peek_kid` returns `{:ok, nil}` for a header without `kid`, and `select_key` then accepts the single key
**File:** `oidc_plug.ex:73-104`
When a token omits `kid`, `select_key(nil)` falls back to "the one key if exactly one exists". This is reasonable for a single-key JWKS, but during a key-rotation window (provider publishes two keys) a `kid`-less token is rejected (`:unknown_kid`) — a correctness/availability edge, not a bypass. No attacker advantage (the key still has to verify the signature). Informational hardening.
**Remediation:** Acceptable as-is; document that production OIDC providers always emit `kid`. Optionally reject `kid == nil` outright once live.

### LOW-2 — `describe(reason)` reflects internal error atoms into the 401 response body
**File:** `oidc_plug.ex:40-41, 170-171`
The catch-all error path emits `"Invalid access token: #{describe(reason)}"`, leaking internal reason atoms (`:malformed_token`, `:no_keys`, `:unknown_kid`, `:verify_failed`, `{:unexpected, ...}`) to the caller. Minor information disclosure about internal validation state; no secret exposure. Note that for a `{:unexpected, term}` tuple, `inspect/1` could surface internal term structure.
**Remediation:** Return a single generic `"Invalid access token"` for all non-expired/non-missing failures (matches the Go side, which returns a flat `"Invalid token"`). Keep the detailed reason in a `Logger.debug` only.

### INFO-1 — `core:4000` is host-published in dev compose; the Elixir `/_matrix` OIDC stub is reachable from the host now
**File:** `docker-compose.yml:121-124`
`ports: ["4000:4000"]` exposes the Bandit endpoint (incl. the `Protected` sub-router with the `OidcPlug` gate and the `GET /client/v3/sync` stub) to the host in the dev stack. This is *intended* for the `/health` check and is dev-only, but it means MEDIUM-1/MEDIUM-2 are exercisable against the dev stack today even though the prod request path still goes through Go. Worth noting so the toggle-flip in `matrix-api-migration` is not assumed to be the first moment `OidcPlug` is reachable.
**Remediation:** None required for dev. Ensure prod/IaC does not publish `4000` beyond the internal network / load-balancer health path.

### INFO-2 — `http://dex:5556/dex/keys` plaintext JWKS is fine for dev only
**File:** `docker-compose.yml:119`
The dev JWKS URI is plaintext HTTP over the Docker-internal network — acceptable for dev (ADR-012 example-only posture), and called out here only as the concrete instance that MEDIUM-1's scheme-guard remediation must continue to permit *only* under an explicit dev flag.

---

## Cross-reference to MEMORY patterns

- **"OIDC fail-open at startup" (Epic 12):** recurs here as MEDIUM-3 (nil iss/aud → check skipped). Same class, Elixir incarnation.
- **"S3/endpoint validation missing scheme assertion" (media-gateway):** MEDIUM-1's missing `https://` guard on `NEBU_OIDC_JWKS_URI` is the same shape applied to the JWKS endpoint.
- The new pattern worth curating: **"Elixir `:httpc` fetch with empty options = no TLS verification"** — any future Core-side outbound HTTPS (SCIM, OIDC directory, webhooks) built on `:httpc` will inherit this footgun.

## Recommendation

Approve the commit (no CRITICAL/HIGH). Track MEDIUM-1, MEDIUM-2, MEDIUM-3 as **blocking prerequisites for `matrix-api-migration`** — the story that makes `OidcPlug` the live authority and flips `NEBU_OIDC_VALIDATION_DISABLED`. At that point all three escalate to HIGH because they sit directly on the live auth boundary. Recommend bundling them into a single hardening task `fix/oidc-plug-tls-and-alg-allowlist` with the three regression tests named above.
