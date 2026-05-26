# Security Review — bugfix-sso-bootstrap-credentials

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Date:** 2026-05-26
**Branch:** `bugfix/custom-scopes-in-matrix-sso` (staged worktree)
**Story:** `docs/stories/bugfix/matrix-sso-bootstrap-credentials/matrix-sso-bootstrap-credentials.md`
**security_review:** required (auth / credentials surface)
**Scope:** `git diff --staged` (8 files, ~1023 LOC, 75 net new LOC in `main.go`)

---

## Classification

**CLEAN** — 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW findings.

The change is a defensive bug fix that wires existing, proven primitives (the `claimLoader` TTL-cache pattern, `admin.DecryptAES256GCM`, the `ServerConfigReader` interface) into the Matrix SSO `LoginHandler` so that Bootstrap-configured OIDC credentials are actually used at runtime. It introduces no new auth surface, no new routes, no new secret-comparison code paths, and no new logging of sensitive material.

---

## Files Reviewed (staged)

| File | LOC delta | Nature |
|---|---:|---|
| `gateway/cmd/gateway/main.go` | +75 | Two new loader factories + wiring + startup observability |
| `gateway/internal/matrix/login.go` | +31 / −1 | New `clientIDLoader` / `clientSecretLoader` fields + `resolveClientID` / `resolveClientSecret` methods; `PostLogin` verifier now uses resolver |
| `gateway/internal/matrix/sso.go` | +5 / −5 | Replace `h.clientID` / `h.clientSecret` with `h.resolveClientID(ctx)` / `h.resolveClientSecret(ctx)` in `GetSSORedirect` + `GetSSOCallback` |
| `gateway/internal/admin/crypto.go` | +8 | Export `EncryptAES256GCM` (already had exported `DecryptAES256GCM`) |
| `gateway/cmd/gateway/loaders_test.go` | +386 | Red-phase unit tests for the two loaders (incl. AC5 corruption test + slog capture) |
| `gateway/internal/matrix/sso_bootstrap_credentials_test.go` | +332 | Red-phase acceptance tests for AC1/AC2/AC3 |
| `docs/stories/bugfix/matrix-sso-bootstrap-credentials/matrix-sso-bootstrap-credentials.md` | +169 | Story doc |
| `_bmad-output/nebu/pipeline-state.yaml` | +22 | Pipeline state |

---

## Focus-Scope Findings (per request)

| Class | Result | Reasoning |
|---|---|---|
| SQL injection | CLEAN | All DB reads go through `postgresServerConfigReader.LoadServerConfigKey`, which uses `r.db.QueryRowContext(ctx, "SELECT value FROM server_config WHERE key = $1", key)` — parameterized. The new loaders pass a hard-coded literal key (`"oidc_client_id"`, `"oidc_client_secret"`), never user input. |
| Auth bypass (missing middleware, IDOR) | CLEAN | No new HTTP routes, no middleware changes. The SSO redirect and callback handlers retain `mediumRL` rate-limiting; `POST /login` keeps `strictRL` + `bodyLimit1MiB`. The change strictly substitutes the source of `client_id` / `client_secret` for outbound OAuth2 calls and inbound JWT verification — it does not relax any authorization gate. |
| Timing attacks on secret comparison | CLEAN | The diff introduces no `==` / `bytes.Equal` comparisons on secrets. AES-GCM authentication tag verification (`gcm.Open` in `decryptAES256GCM`) is constant-time per Go stdlib `crypto/cipher` contract. No new HMAC, PSK, or token comparison paths. |
| JWT validation flaws (alg confusion, missing exp/aud/nonce) | CLEAN | `inner.Verifier(&oidc.Config{ClientID: h.resolveClientID(ctx), SupportedSigningAlgs: validate.SupportedAlgs()})` — algorithm allowlist enforced (`go-oidc` rejects `none`); `aud` enforced via `ClientID`; `exp` enforced by `go-oidc.Verify`; `nonce` extracted manually in `GetSSOCallback` (existing logic, preserved). The only change is the *source* of `ClientID` for the verifier — same value semantics. |
| Plaintext secrets in logs | CLEAN | `slog.Warn("newServerConfigClientSecretLoader: decryption failed, falling back to env var", "err", err)` logs only the error (e.g. `"ciphertext too short"`, `"cipher: message authentication failed"`, hex-decoding errors) — never the ciphertext, never the plaintext, never the env-var fallback value. Startup observability warnings log only the *absence* of credentials, not their values. No `slog.Info` / `slog.Debug` added that touch `client_secret`. |
| Weak crypto primitives | CLEAN | `admin.DecryptAES256GCM` uses AES-256-GCM (AEAD) — the existing, project-standard primitive used for `scim_bearer_token`, refresh tokens, and now `oidc_client_secret`. SHA-256 is used solely for key derivation from the variable-length PSK (`internalSecret`) — acceptable for a PSK-shaped input, not a password (no need for Argon2/PBKDF2 here). No new uses of md5, sha1, DES, or RC4. |
| AES-256-GCM correctness (nonce, authenticity) | CLEAN | Encryption (`encryptAES256GCM`) generates a fresh 12-byte nonce per call via `crypto/rand.Reader` (`io.ReadFull(rand.Reader, nonce)`), prepends it to the ciphertext, then hex-encodes. Decryption splits nonce / ciphertext using `gcm.NonceSize()` and calls `gcm.Open(nil, nonce, ciphertext, nil)`. Authentication tag is verified — any tampering yields a decryption error, which the loader catches and converts to env-var fallback + `slog.Warn`. **No nonce reuse risk:** each encryption produces an independent random nonce; decryption operates on the nonce shipped with the ciphertext. |
| Client-credentials handling: secrets in logs / URLs | CLEAN | `client_secret` flows through `LoginConfig.ClientSecretLoader` → `h.resolveClientSecret(ctx)` → `oauth2.Config{ClientSecret: ...}` → `oauth2Config.Exchange(...)`. The Go `golang.org/x/oauth2` library transmits the secret in the **POST body** of the token exchange, never as a URL query parameter. The `client_id` (non-sensitive) appears in the `AuthCodeURL` redirect; the `client_secret` does NOT. No `slog` / `fmt.Print` / `log` call in the changed code embeds either credential. |
| Race conditions on credential loading | CLEAN | `claimLoader.get(ctx)` acquires `c.mu.Lock()` for the entire critical section (TTL check + DB call + cache update). Concurrent SSO requests serialize on this mutex; only one DB query runs per TTL window. No double-read, no torn read. The closures `clientIDLoader` / `clientSecretLoader` in `main.go` capture `clientIDCached` / `clientSecretCached` by reference (pointer to `claimLoader`), so all goroutines share the same mutex-protected state. **No race.** Verified the existing `claimLoader` pattern is already in production use for `oidc_user_id_claim` / `oidc_displayname_claim` / `oidc_email_claim` (Story 11-10) with the same concurrency model. |

---

## Additional Checks (beyond focus-scope)

| Check | Result |
|---|---|
| Open redirect on SSO callback | CLEAN — `redirectURL` validation unchanged; this diff does not touch `ssoCallbackURL` or the deep-link scheme allowlist. |
| Missing body-size / rate limits | CLEAN — Existing `bodyLimit1MiB` on `POST /login` and `mediumRL` on SSO redirect/callback retained. |
| Missing security headers | N/A — No new response-writing paths added; headers are set by middleware unchanged. |
| Path traversal | N/A — No filesystem reads added. |
| CSRF on state-changing endpoints | N/A — The SSO redirect/callback are GET endpoints with their own state/nonce mechanism (`globalSSOState.save` / `pop`), preserved unchanged. |
| Replay protection | PRESERVED — `globalSSOState` single-use `pop()`; nonce verification in callback preserved. |
| `startupCtx` 5s timeout in main.go | INFORMATIONAL — A slow DB at startup may emit a misleading "OIDC client_id not configured" warning even when the DB does have the value. Pure log-noise concern; no security impact. The `startupCancel()` is explicit (not deferred) and the comment documents why (defer would extend context lifetime to `main()` exit). Correct. |
| Behavior on transient DB error post-bootstrap | INFORMATIONAL — When `LoadServerConfigKey` returns a transient error (DB unreachable) **after the TTL expires**, both new loaders return the *env-var fallback* rather than the previously cached DB value. This diverges from `claimLoader`'s standard "return stale on error" contract (used by `newServerConfigClaimLoader`). Practical impact: a transient DB blip after bootstrap could briefly switch SSO back to env-var credentials, which (if env vars are placeholder/empty) causes IdP rejection with `invalid_client`. **This is an availability/UX concern, not a security finding** — failing back to env credentials does not escalate any privilege; the IdP rejects mismatched credentials. Worth a follow-up MINOR ticket to align with the stale-on-error pattern, but not a blocker. |

---

## Audit-Trail Notes

- **Key alignment verified:** Bootstrap encrypts via `encryptAES256GCM(h.secret, clientSecret)` where `h.secret == internalSecret` (see `gateway/internal/admin/bootstrap.go:266` and `NewBootstrapHandler(..., []byte(internalSecret))` at `main.go:500`). The new loader decrypts via `admin.DecryptAES256GCM([]byte(internalSecret), encrypted)`. Same key material, same algorithm — round-trip safe.
- **Interface contract honored:** Both new loaders depend only on `admin.ServerConfigReader` (the existing minimal interface), keeping `main.go` free of raw SQL.
- **AC5 test coverage:** Decryption failure path explicitly tested via `loaders_test.go` "falls back to env var and logs warning on corrupted encrypted value" subtest, with `slogCapture` verifying the warning is emitted (MINOR-2 from earlier review round addressed).
- **Pre-existing accepted patterns reused:** The `claimLoader` mutex-guarded TTL-cache, the `ServerConfigReader` interface, and `admin.DecryptAES256GCM` are all production-proven primitives — no new cryptographic, concurrency, or persistence code was authored for this fix.

---

## Verdict

**Ship it.** No findings block the commit. The change correctly closes a configuration mismatch where Bootstrap-configured OIDC credentials were ignored, and does so without introducing any new attack surface. The defensive characteristics (fail-safe decryption with warning + env-var fallback, mutex-serialized cache, no secrets in logs, no SQL injection vectors, no JWT validation regressions) are all sound.

— Kassandra
