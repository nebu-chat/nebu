# Security Review — matrix-api-migration (SEC Gate 1, story-level)

**Reviewer:** Kassandra (adversarial security reviewer)
**Date:** 2026-06-17
**Epic:** full-elixir-stack
**Diff scope:** `git diff --staged` — ports all in-scope Matrix CS API endpoints from the Go gateway into an Elixir `Plug.Router` (`nebu_http` app), reusing OTP logic with NO gRPC hop; hardens `OidcPlug` (alg allowlist, fail-closed iss/aud, provisioning cache w/ TTL); adds `JsonBody` (1 MB cap, malformed→400), `OidcMetadata` (well-known proxy), `Nebu.Profile.DB.get_profile/1`.

**Verdict: BLOCKED — 1 HIGH.**

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | **HIGH** | `core/apps/nebu_http/lib/nebu_http/plugs/oidc_plug.ex` (whole `call/2` path) + `router/protected.ex:76-87` (logout) | **Logout-revocation bypass / session-management regression.** The Go gateway invalidated the access token in a persistent denylist on `POST /logout` and checked that denylist on every request (`auth.go:339-344` "Step 2: Denylist check"; `logout.go:81` `store.Invalidate`; `tokenstore.go`). The migrated Elixir path returns the raw OIDC token as the `access_token` (`matrix_public.ex:222`), `POST /logout` only destroys the ETS session GenServer (`server.ex:899` `invalidate_user_sessions` → `destroy_session`), and `OidcPlug` **never consults any denylist** — it re-validates the JWT (sig+exp+iss+aud) and re-provisions. A logged-out token stays fully accepted until its OIDC `exp`. Logout is advertised (returns `200 {}`) but provides **no revocation**. Exploitable with standard credentials; defeats logout on shared/stolen-token scenarios. | Add a token-denylist consult to `OidcPlug` (parity with Go `IsInvalidated`) and populate it on `POST /logout`. Reuse the existing `invalidated_tokens` table (hash the token; store `exp` so entries self-expire). Add a regression test: login → logout → same Bearer → 401 `M_UNKNOWN_TOKEN`. If full denylist is deferred to `go-removal-cleanup`, that deferral must be an explicit, written coordinator-accepted risk **before** clients are cut over to `core:4000` — logout currently no-ops. |
| F-2 | MEDIUM | `core/apps/nebu_http/lib/nebu_http/oidc_metadata.ex:53-59` | **`:httpc` fetch with no TLS peer verification** (recurring MEMORY pattern, oidc-middleware-migration M-1). `do_fetch/1` builds `request = {url, []}` and `http_opts = [timeout, connect_timeout]` — no `ssl: [verify: :verify_peer, cacerts: ..., customize_hostname_check: ...]` and no `https://` scheme assertion. An on-path attacker between Core and the OIDC provider can serve a forged `/.well-known/openid-configuration`; the document is returned verbatim to clients as `auth_metadata` (`matrix_public.ex:118-122`), so a client can be steered to an attacker `authorization_endpoint`/`token_endpoint`. The sibling `jwks_cache.ex:173-187` was correctly fixed in this story (verify_peer + hostname match, https-gated) — `OidcMetadata` repeats the un-fixed pattern. | Mirror `JwksCache.http_opts_for/1`: when `issuer` starts with `https://`, pass `ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]`. Issuer is trusted config (`NEBU_OIDC_ISSUER`), so no SSRF from request input — but TLS integrity is still required. |
| F-3 | MEDIUM | `core/apps/nebu_http/lib/nebu_http/matrix_public.ex:59` (`post "/"`); no rate-limit plug anywhere in `nebu_http` | **`POST /_matrix/client/v3/login` has no rate limit (regression).** The Go gateway deliberately wrapped login in `strictRL` (30 req/min, burst 10) — comment: "real brute-force risk" (`main.go:324-325, 705`). The Elixir `/login` verifies an attacker-supplied token against JWKS on every call (CPU) with only a 1 MB body cap and no throttle. No reverse proxy currently fronts `core:4000`. Unauthenticated token-spray / JWKS-verification DoS. Becomes live at `go-removal-cleanup` cutover. | Add per-IP rate limiting to at least `POST /login` (and ideally `/sync`), or document a mandatory rate-limiting reverse proxy in front of `core:4000` as a deployment precondition before cutover. Per-story decision must be explicit, not implicit. |
| F-4 | LOW | `core/config/runtime.exs:14-15` | `NEBU_OIDC_ISSUER`/`NEBU_OIDC_AUDIENCE` read via `System.get_env` with no `raise` if absent. Operator misconfig leaves them `nil`. **Not exploitable** because `OidcPlug.check_issuer/check_audience` now fail CLOSED on `nil` (`oidc_plug.ex:308-321`) — every token is rejected, so this is the safe direction. Noise/availability only, but parity prefers `raise` at boot. | Optional: `raise` in `runtime.exs` for prod, matching `NEBU_DB_URL`/`NEBU_PII_ENCRYPTION_KEY`, so misconfig is a fast loud failure rather than 100% 401s. |
| F-5 | LOW | `core/apps/nebu_http/lib/nebu_http/matrix.ex:94-96`, all error envelopes | No security headers (`X-Content-Type-Options: nosniff`, etc.) on responses. All in-scope responses are `application/json` Matrix envelopes (not HTML), and `auth_metadata` is served with `Content-Type: application/json` — not a browser-render XSS vector. Consistent with project posture (MEMORY: modern browsers don't sniff JSON CT). | Optional hardening: add `X-Content-Type-Options: nosniff` globally in `NebuHttp.Router`. |

---

## Detail

### F-1 — Logout does not revoke the token (HIGH)

This is the most important finding and was **not** caught by Gates 1–3.

Request path today:
1. `POST /login` (`matrix_public.ex:202-234`) verifies the OIDC token and returns it **verbatim** as `access_token` (`access_token => token`, line 222). The comment acknowledges "No opaque session store in the Elixir path yet."
2. `POST /logout` (`protected.ex:76-87`) calls `invalidate_user_sessions`, which (`server.ex:899-917`) only calls `destroy_session(user_id[, device_id])` — it tears down the ETS session GenServer.
3. `OidcPlug.call/2` (`oidc_plug.ex:46-71`) authorizes purely on JWT validity (`verify_token` → sig/alg/exp/iss/aud/sub) plus the provisioning cache. **It never reads the session store and never reads any denylist.**

Consequently the destroyed session is irrelevant to authorization: the same Bearer token re-validates and is re-accepted on the very next request, until OIDC `exp`. The Go gateway specifically prevented this with a persisted `invalidated_tokens` denylist consulted on every request (`auth.go:341`). The migration silently dropped that control while keeping the user-facing logout endpoint (which returns `200`), so the regression is invisible to a client and to the existing tests.

Severity HIGH: standard-credential-reachable, defeats a real session-management control (shared machine, leaked token, forced-logout-on-compromise), state-changing endpoint, silent. It is not CRITICAL only because exploitation still requires possession of a token that was valid at logout time and is bounded by `exp`.

### F-2 — well-known fetch has no TLS verification (MEDIUM)

Same `:httpc` empty-`ssl`-opts class already recorded in MEMORY from oidc-middleware-migration (M-1), and already fixed for the auth-critical JWKS fetch in this same story (`jwks_cache.ex:173-187`). `OidcMetadata.do_fetch/1` is a new file that reintroduces it. Lower than F-1/JWKS because the metadata document does not directly establish signature trust (JWKS does), but it does drive client OIDC endpoint discovery, so a MITM can phish the auth flow.

### Auth-bypass surface — reviewed, CLEAN

- **Router disambiguation (`router.ex`):** `Plug.Router` `forward` rewrites `path_info` (strips the matched prefix) and matches segment-wise; it does NOT match `…/loginX`. The unauthenticated forwards (`/login`, `/v1|unstable…/auth_issuer`, `/auth_metadata`, `/profile`) are listed BEFORE the catch-all `forward "/_matrix", to: Protected`. No authenticated route is reachable through `MatrixPublic`.
- **`MatrixPublic.get "/"` request_path cond (`matrix_public.ex:35-54`):** only reached after a prefix forward already matched, so `conn.request_path` is always one of the forwarded public paths. The suffix checks select only between `auth_issuer` / `auth_metadata` / `/login` — all unauthenticated, static, no DB, no state mutation. request_path spoofing cannot select an authenticated handler. CLEAN.
- **PUT profile in the public subtree:** `matrix_public.ex:79-89` inline-runs `OidcPlug.call/2` (`authenticate/1`, lines 322-330) and only proceeds when `conn.halted == false`. The protected fallback (`protected.ex:288-294`) also runs `OidcPlug` via the router pipeline. No unauthenticated PUT path. CLEAN.
- **IDOR:** typing (`protected.ex:199`), presence-PUT (`:270`), profile-PUT (`matrix_public.ex:292`, `protected.ex:306`) all compare path `user_id` to `current_user` and return `403 M_FORBIDDEN` on mismatch. Tested (`matrix_router_test.exs:490,573,599`). GET profile/presence of arbitrary users is intentionally public (Go parity) and leaks only displayname/avatar/presence — no token, email, or session data. CLEAN.

### JWT — reviewed, CLEAN (MEDIUM-2 + MEDIUM-3 from story 2 genuinely resolved)

- alg allowlist enforced BEFORE key selection/verify (`oidc_plug.ex:229,245-249`): `@allowed_algs` is asymmetric-only; `alg:none` and all HS* rejected. Tested: `alg:none → 401` and `HS256-signed-with-RSA-public-key → 401` (`oidc_plug_test.exs:220,243`). Alg-confusion closed by explicit check, not by accident — the prior MEMORY concern is resolved.
- `exp` required (`:293-299`, missing/non-integer → `:missing_exp`); tested (`:155`).
- `sub` required non-empty string (`:303-304`); tested (`:176,198`).
- iss/aud fail CLOSED when unconfigured (`:308-321`, `:issuer_not_configured`/`:audience_not_configured`); wrong iss/aud → 401; tested (`:270,292`). MEDIUM-3 resolved at the plug layer (even though `runtime.exs` does not `raise` — see F-4, which is safe-direction).
- `kid` handling (`:263-283`): `kid==nil` accepted only when exactly one key exists; multiple keys + no kid → `:unknown_kid`. Reasonable.

### Provisioning cache — reviewed, CLEAN (no cross-user poisoning)

ETS table `:nebu_http_provisioned_users` is `:public`, but the only request-reachable writer is `mark_provisioned(user_id)` (`oidc_plug.ex:174`), called solely from `do_provision/2` with the caller's OWN token-derived `user_id`. No request path can insert an arbitrary key for another user. Deactivation is never cached and entries expire at a 60 s monotonic TTL (`:160-172`), so a mid-session deactivation is re-checked and blocked within the TTL (Go `makeStatusChecker` parity). Tested (`oidc_plug_test.exs:420,448`). A `sub` containing `:` yields a consistent (if malformed) self-identity — not a cross-user collision. CLEAN. (MINOR-6 from code review — the missing TTL — was fixed and is verified present + tested here.)

### SQL — reviewed, CLEAN

`profile/db.ex` `@sql_upsert` and `@sql_get_profile` are fully parameterized (`$1..$4`), values passed as a bind list to `Ecto.Adapters.SQL.query/3`. No string interpolation of user input. The `@user:server` id is built from the verified `sub` and used only as a bind parameter, never concatenated into SQL.

### auth_metadata SSRF — reviewed, no SSRF

`OidcMetadata.fetch/1` is called only with the configured `NEBU_OIDC_ISSUER` (`matrix_public.ex:118`), never with request input. No open redirect (URL is config-derived; response is JSON, not a redirect). TLS integrity gap is F-2.

### /sync long-poll DoS — reviewed, CLEAN

`parse_timeout/1` (`protected.ex:340-347`) clamps the client timeout to `0..30_000` ms (`max(0) |> min(30_000)`), so a client cannot request an unbounded long-poll. The concurrent test (`sync_concurrent_test.exs:107`) exercises 50 simultaneous long-polls. The per-request BEAM process unblocks at the 30 s cap. No process leak / unbounded-poll DoS. (Connection-count exhaustion is a Bandit/proxy concern, out of scope here; relates to F-3 rate-limiting.)

### Body-size limit — present

`JsonBody` enforces `length: 1_000_000` (1 MB) via `Plug.Parsers` (`json_body.ex:23`). Note: the `rescue` only catches `Plug.Parsers.ParseError`, not `RequestTooLargeError` — an oversized body would raise `RequestTooLargeError` (Plug returns 413; body not fully read, so the DoS protection still holds). Functional nit, not a finding.

### Secrets in logs — CLEAN

Login does not log the token on failure (`matrix_public.ex:192-194`, explicit comment). `OidcPlug` 401 bodies expose internal reason atoms (`describe/1`, `oidc_plug.ex:69,352-353`) — e.g. `:bad_issuer`, `:unknown_kid` — which is minor information disclosure (carried as INFO from story 2's L-2, not re-escalated).

---

## Summary

- CRITICAL: 0
- HIGH: 1 (F-1 logout-revocation bypass) — **blocks commit**
- MEDIUM: 2 (F-2 well-known TLS verification; F-3 login rate-limit)
- LOW: 2 (F-4 iss/aud raise-at-boot; F-5 security headers)

**Verdict: BLOCKED** — F-1 must be remediated (or formally risk-accepted in writing by the owner before any client cutover to `core:4000`). F-2 should be fixed in this story (it is a one-function mirror of the JWKS fix already landed). F-3 must be an explicit decision (fix or documented proxy precondition).

### Carry-over status from oidc-middleware-migration (story 2)
- MEDIUM-2 (strict alg allowlist): **RESOLVED** here (explicit check + 2 tests).
- MEDIUM-3 (fail-closed iss/aud): **RESOLVED** here (plug-layer fail-closed + 2 tests).
- M-1 (`:httpc` TLS) for JWKS: **RESOLVED** here. But **reintroduced** in the new `OidcMetadata` file → F-2.

### MEMORY follow-ups (to record at session close)
1. Recurring `:httpc` empty-`ssl` TLS-verification pattern struck a **third** Elixir outbound fetch (`OidcMetadata`) after being fixed twice — warrants a project-wide lint/grep gate: any `:httpc.request` with `https` must pass `verify: :verify_peer`.
2. New pattern: **logout endpoint migrated without its revocation backbone.** When porting an auth surface, the token-denylist/revocation store is an invisible dependency that does not appear in the endpoint list — enumerate every per-request middleware step on the Go side (`auth.go` "Step N" comments), not just the route table.

---

## Pipeline disposition addendum (2026-06-17, coordinator-applied)

- **F-2 (MEDIUM) — FIXED in this story.** `OidcMetadata.do_fetch/1` now enables `verify: :verify_peer` + CA certs + hostname match for `https://` issuers (`tls_opts_for/1`), mirroring `JwksCache.http_opts_for/1`. Resolved before commit.
- **F-1 (HIGH) and F-3 (MEDIUM) — deferred to `go-removal-cleanup` with documented rationale.** This story WIRES the Elixir request path but does NOT cut clients over: Element still targets the Go gateway, which retains its token denylist (F-1) and `strictRL` login rate limit (F-3) on the live path. The Elixir `core:4000` path is not the live client endpoint until `go-removal-cleanup`. Both findings become exploitable ONLY at that cutover. They are therefore made BLOCKING PREREQUISITES of `go-removal-cleanup`:
  - F-1: implement a token-denylist consult in `OidcPlug` + populate on `POST /logout` (reuse `invalidated_tokens`; hash token + store `exp`), with a login→logout→401 regression test, BEFORE any client is repointed to `core:4000`.
  - F-3: add per-IP rate limiting to `POST /login` (and `/sync`) on the Elixir stack, OR mandate a rate-limiting reverse proxy in front of `core:4000` as a deployment precondition, BEFORE cutover.
  Rationale for not blocking THIS story's commit: no live exploit path exists in the delivered state (Go gateway is the live authority for these controls); blocking would stall the migration without reducing real risk. This deferral is recorded as an explicit accepted-with-conditions risk per SEC Gate 1 (CRITICAL/HIGH must become follow-up work or be accepted with written justification).
- **F-4 / F-5 (LOW):** optional hardening, not blocking; tracked for a later hardening pass.
- **MEDIUM-2 (alg allowlist) and MEDIUM-3 (fail-closed iss/aud) carry-overs from oidc-middleware-migration: VERIFIED RESOLVED in this story.**
