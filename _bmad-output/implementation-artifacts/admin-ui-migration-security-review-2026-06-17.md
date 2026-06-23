# Security Review — admin-ui-migration (SEC Gate 1, story-level)

**Reviewer:** Kassandra (adversarial security review)
**Diff scope:** `git diff --staged` — Phoenix LiveView Admin UI migration in `core/apps/nebu_http` (auth gate, rooms/users/bootstrap LiveViews, login controller, admin endpoint, router dispatch, config, compose, e2e + ExUnit tests).
**Date:** 2026-06-17
**Story security_review:** required
**ADR-018 in force:** inline SQL is intended; no "extract to repository / add schema" findings raised.

---

## Classification: **MEDIUM** — APPROVED (no CRITICAL, no HIGH)

No blocking findings. Two MEDIUM defense-in-depth items and three LOW hardening notes. The admin gate is sound and fail-closed, the at-rest crypto is AEAD-correct, no secrets are logged, and there is no open redirect, SQLi, or XSS.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `admin/bootstrap_live.ex:305-318` (`at_rest_key/0`) | OIDC client-secret at-rest key derives from `NEBU_INTERNAL_SECRET_FILE`→`NEBU_INTERNAL_SECRET`→`""`. No fail-fast; on a node where neither is set the secret is encrypted under `SHA-256("")` — a known/weak key. Also a var-name split (`_FILE` path vs raw value) vs the gateway. | Raise at boot (or refuse to encrypt) when the resolved internal secret is empty; assert `byte_size(secret) > 0` in `at_rest_key/0`. Mirror the `secret_key_base` prod-raise. |
| F-2 | MEDIUM | `admin_endpoint.ex` `@session_options` | Admin session cookie has no `secure: true` flag; `same_site: "Lax"` only. On any deployment where TLS is not strictly terminated in front of `:4000` the signed admin session can traverse plaintext HTTP. | Add `secure: true` to `@session_options` (gate behind a dev override if local HTTP testing is needed). Cookie is signed not encrypted, so confidentiality of the flag matters. |
| F-3 | LOW | `admin_endpoint.ex` `Plug.Parsers` | No `length:` cap on the admin endpoint's `Plug.Parsers` (Phoenix default 8 MB, multipart accepted) vs the main router's `JsonBody` 1 MB cap. No admin route is currently a body-POST surface (all data ops are LiveView socket events; login is GET), so practical DoS surface is near-zero today. | Set an explicit small `length:` (e.g. 1 MB) on the admin `Plug.Parsers` for parity and future-proofing. |
| F-4 | LOW | `admin/bootstrap_live.ex` `decrypt_secret/1` | `Base.decode16(..., case: :mixed)` on the at-rest blob is lenient; GCM auth-tag still gates integrity so no bypass, but mixed-case acceptance differs from Go's lower-case `hex` parity claim. | Use `case: :lower` to match the documented Go `hex(...)` layout exactly; functionally harmless. |
| F-5 | LOW (informational) | `admin/auth.ex` `put_current_user/2` | Defined but never called anywhere in the Phoenix codebase. The `on_mount :require_admin` reads `session["current_user"]`, which is only ever populated by tests today. Effect: the gate is **fail-closed** (no Phoenix-minted admin session exists yet — the Go gateway still owns the OIDC exchange, as documented). Not a vulnerability, but the cross-service session-bridge is incomplete and must be security-reviewed when wired. | When the OIDC-exchange leg is ported (deferred follow-up), re-review: cookie format bridging, `configure_session(renew: true)` session fixation defense, and that `admin_claim?` is computed from *verified* ID-token claims only. |

---

## Detail

**F-1 — Empty-string fallback for the at-rest encryption key [MEDIUM]**
`at_rest_key/0` resolves the AES-256 key as: `:admin_secret_at_rest` app env (test seam) → `NEBU_INTERNAL_SECRET_FILE` (read file) → `NEBU_INTERNAL_SECRET` (raw env) → `""`, then `SHA-256` of whatever it got. `runtime.exs` never enforces a non-empty internal secret for the core (it raises only for `NEBU_OIDC_ISSUER`, `NEBU_OIDC_AUDIENCE`, `NEBU_DB_URL`, `NEBU_PII_ENCRYPTION_KEY`, and `secret_key_base`). A node booted without the internal secret encrypts the OIDC client secret under `SHA-256("")` — a publicly computable key — defeating the entire at-rest protection. The AEAD primitive itself is correct (random 12-byte nonce per call, 32-byte key, `ciphertext‖tag` layout, Go parity); the weakness is solely the unguarded key source. This is the same class as the recurring "fail-open at startup" pattern (MEMORY #43/#71): make it fail-fast. Recommend raising in prod when the resolved secret is empty.

**F-2 — Session cookie missing `secure` flag [MEDIUM]**
`@session_options` sets `same_site: "Lax"` but not `secure: true`. `put_secure_browser_headers` does not add the secure attribute. In Compose the admin rides `:4000`/`:8008`; if any environment exposes that without front TLS, the signed admin session cookie can be sent over HTTP and captured. Signed-not-encrypted means an attacker who replays it is authenticated as the admin until expiry. Low likelihood in the reference topology, hence MEDIUM not HIGH.

**Re-verification of items prior review flagged (independently confirmed):**

- **`on_mount {:require_admin}` on all 4 LiveViews — CONFIRMED.** All live routes (`/rooms`, `/rooms/:id`, `/users`, `/bootstrap`) sit inside `live_session :admin, on_mount: {NebuHttp.Admin.Auth, :require_admin}`. `live_session` runs the `on_mount` hook on **both** the static HTTP render and the websocket socket connect, so there is no socket-only bypass. A session without `%{"admin" => true}` is `{:halt, redirect to "/admin/login"}`. `/admin/login`, `/admin/login/start`, and `/admin` (root redirect) are intentionally public. **No auth bypass.**
- **`admin_claim?/1` all-claims scan — NOT a privesc vector here.** It is byte-faithful parity with Go `auth.MatchesAdminGroupClaim` (scan every claim value; match string equality or membership in a string-list). It is computed only from the **verified ID-token claims** map (the same trust source the Go gateway uses). A user cannot set an arbitrary non-group claim to `instance_admin` unless the IdP both (a) lets the user control that claim's value and (b) emits it in the ID token — which is an IdP-configuration concern identical to the existing Go behaviour, not introduced by this diff. The default value `instance_admin` is operator-overridable via `server_config.admin_group_claim` (inline SQL, parameterless query — no injection). **No new privesc.** (Worth a one-line operator-doc note that the admin claim should be a dedicated groups/roles claim, not a free-form attribute — carried as advisory, not a finding.)
- **`/admin/login/start` open redirect — CONFIRMED ABSENT.** The redirect target comes exclusively from `Application.get_env(:nebu_http, :admin_oidc_login_url)` (server config / `NEBU_ADMIN_OIDC_LOGIN_URL`), never from request params (`start/2` ignores params). Path-prefix `/` → `:to` (same-origin); else `:external`. An attacker cannot influence the target. **No open redirect.**
- **`oidc_client_secret` AES-256-GCM at rest — AEAD-CORRECT.** Key = `SHA-256(internal secret)` (32 bytes → AES-256), nonce = `:crypto.strong_rand_bytes(12)` fresh per encrypt (GCM nonce-uniqueness satisfied; no counter/static nonce reuse), output `hex(nonce ‖ ciphertext ‖ tag)` via `Media.Crypto.encrypt/3` (`ciphertext‖16-byte tag`, Go `gcm.Seal` parity). `decrypt_secret/1` returns `""` on any tag mismatch rather than crashing. Verified the secret is **never logged** (no `Logger`/`IO.inspect`/`inspect` of claims, draft, or secret anywhere under `admin/`). Only weakness is the key *source* (F-1), not the construction.
- **`secret_key_base` — fail-fast in prod CONFIRMED.** `runtime.exs` raises when neither `NEBU_ADMIN_SECRET_KEY_BASE` nor `NEBU_INTERNAL_SECRET_FILE` is set in prod; dev gets a random key; the file form is SHA-512-stretched to ≥64 bytes. Short/empty key cannot reach prod for the session signing path.
- **CSP / XFO / nosniff — PRESENT.** Admin router sets a non-`unsafe-eval`, non-`unsafe-inline`-script CSP (`script-src 'self'`, vendored JS only; `connect-src 'self' ws: wss:` for the LiveView socket; `frame-ancestors 'self'`). `put_secure_browser_headers` adds XFO/nosniff/referrer; the main `NebuHttp.Router` also force-sets `x-content-type-options: nosniff` via `register_before_send`. The deprecated `plugin-types` directive (MEMORY #47) is **not** present — good.
- **CSRF — CORRECTLY WIRED.** `:protect_from_forgery` is in the `:browser` pipeline; the root layout emits `<meta name="csrf-token">`; `app.js` passes it as `_csrf_token` on the LiveSocket connect, which LiveView verifies against the signed session at socket join. State-changing operations are LiveView events over the CSRF-validated, session-signed socket — no separate CSRF-exposed POST endpoint exists.
- **IDOR on toggle / bootstrap handlers — NONE.** `toggle_auto_join` and the bootstrap `save_step`/`finish` handlers act on client-supplied `room_id`/form values, but the **entire** `/admin` subtree is behind the single `:require_admin` gate — every admin operates with full instance scope (instance-admin, not per-room ownership), so trusting client-supplied `room_id` within an authenticated admin session is by design, not IDOR. SQL is parameterized (`$1/$2`) — no injection via `room_id`. `complete_bootstrap` guards against replay with a `bootstrap_completed?` check before promotion (parity with Go `ErrAlreadyCompleted`).
- **JWT/OIDC validation** — not in this diff's scope; the OIDC exchange remains in the Go gateway (documented deferral). The Elixir `OidcPlug` path (separate stories) is unchanged here.

---

## Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 2 (F-1 empty-key fallback, F-2 cookie secure flag) — advisory, address before epic end
LOW: 3 (F-3 parser cap, F-4 hex case, F-5 dead-but-fail-closed put_current_user) — advisory

**Verdict: APPROVED** (no CRITICAL/HIGH). The two MEDIUMs are defense-in-depth and should be folded into a small follow-up before the epic-end SEC Gate 2; the cross-service admin session bridge (F-5) is the mandatory re-review trigger when the OIDC exchange is ported to Phoenix.
