# Security Review — oidc-session-refresh (bugfix/fix-short-oidc-sessions)

**Diff scope:** Staged diff for the Matrix v1.3 session refresh implementation. Twelve files (production + tests + docs). Adds opaque AT+RT, `POST /_matrix/client/v3/refresh`, `matrix_sessions` table, OIDC RT encryption at rest, opaque-token revocation on logout, grace-period `MarkTokenUsed` on first use. Reviewer also inspected the broader epic context (`matrix_sessions` migration in `000001_init.up.sql` and full file contents of `refresh.go`, full `auth.go`, full `login.go`, full `logout.go`) since the staged change is the visible tip of an already-committed multi-cycle implementation.
**Date:** 2026-05-27
**Reviewer:** Kassandra (nebu-agent-kassandra)
**Story ACs reviewed:** AC1–AC8
**Pipeline cycle:** review cycle 2 (post `code-review`, pre-commit security gate)

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `gateway/migrations/000001_init.up.sql:313` | `matrix_sessions` table has no `ENABLE ROW LEVEL SECURITY` / no policies — defense-in-depth gap consistent with the recurring pattern flagged in MEMORY.md ("Missing RLS on new tables"). Identical to pre-existing `admin_sessions` precedent; no additional exposure introduced relative to the rest of the schema, but worth tracking. | Either (a) add `ENABLE ROW LEVEL SECURITY` + an allow-all policy for `nebu_app` so the invariant is explicit, or (b) document in the migration header why session tables are exempt (single-role managed-PG deployment as per Story 13.14 / ADR-016). Carry as advisory; not blocking. |
| 2 | LOW | `gateway/internal/middleware/auth.go:213-266` (`WithOpaqueSessionCheck`) | The opaque-token path does **not** populate `ContextKeySub`, `ContextKeyNebuRole`, `ContextKeySystemRole`, `ContextKeyPreferredUsername`, `ContextKeyEmail`, `ContextKeyTokenExpiry`. Downstream Matrix v3 handlers (`rooms.go`, `sync.go`, `event.go`, `members.go`, `receipts.go`) read `ContextKeySystemRole` and forward it to Core via `coregrpc.WithUserMetadata`. For opaque-token sessions, Core receives `system_role=""` instead of the user's real role. Net effect is **privilege downgrade** (an `instance_admin` user with an opaque AT is treated as plain `user` by Core), which is the safe direction — but it means SSO-issued opaque sessions cannot perform admin Matrix-API actions until they re-login through the JWT path. No vulnerability, but a forward-compat hazard if a future code path ever treats empty role as privileged. | Either (a) explicitly populate `ContextKeySystemRole` in the opaque path by storing the role at session creation in `matrix_sessions` and looking it up alongside `LookupOpaqueToken`, or (b) document in the `WithOpaqueSessionCheck` comment that opaque tokens deliberately downgrade to `system_role=""`. Optional for this story. |
| 3 | LOW | `gateway/internal/middleware/auth.go:223` (dispatch by presence of `.`) | Opaque/JWT dispatch trusts that the token format never overlaps. `generateOpaqueToken` returns 64-char hex (0-9 a-f — no dots), so today the invariant holds. If a future change ever introduces a non-hex opaque token (e.g. base64 with padding, or URL-safe base64), tokens containing `.` would be misrouted to the JWT verifier. | Add a brief code comment pinning the invariant ("opaque tokens are 64-char hex — never contain `.`"); already present indirectly in `refresh.go:50`'s doc. Advisory only. |

### MEMORY.md recurring patterns checked

| Pattern | Applies here? | Verdict |
|---------|---------------|---------|
| Missing RLS on new tables | Yes — `matrix_sessions` has no RLS | Flagged as Finding #1 (LOW; consistent with `admin_sessions` precedent) |
| Permissive RLS UPDATE without key-scope | N/A — no RLS at all | n/a |
| DB-module user_id trust-boundary docstring | Yes — `Revoke(accessToken)`, `LookupOpaqueToken(accessToken)` accept caller-supplied identifiers. But: rawToken in `PostLogout` arrives from the same Authorization header that just authenticated the user via `WithOpaqueSessionCheck` → token is provably owned by the caller. `RotateTokens(OldAccessToken)` derives `OldAccessToken` from the server-side session lookup (`sess.AccessToken`), not from the request body. Both call paths are safe. | OK |
| Caller-controlled `system_role` in admin payload | N/A — no admin payload accepts role | n/a |
| `// for MVP` auth shortcut → live vulnerability | None in scope of this diff | OK |
| OIDC fail-open at startup | N/A — refresh path does not call OIDC at runtime; PostLogin path uses pre-existing OIDC verifier with proper exit-on-init-failure | OK |
| ContextKeySub vs ContextKeyUserID identity confusion | The opaque path sets only `ContextKeyUserID` (Matrix `@localpart:server`). No handler in this diff compares it against `ContextKeySub`. Logout uses `ContextKeyUserID` + `ContextKeyDeviceID` for Core cleanup — correct shape. | OK |
| Per-story CLEAN reviews can stack into combined HIGH at epic-end | This is a single-story epic. Diff is self-contained. | OK |
| Story-title oversell on partial behavior | Story title "fix-short-oidc-sessions" accurately describes scope (8h Nebu session lifetime independent of OIDC token lifetime). | OK |

---

## Detail

### Finding #1 — `matrix_sessions` table lacks ROW LEVEL SECURITY [LOW]

The `matrix_sessions` table created in `gateway/migrations/000001_init.up.sql:313–326` does not have `ALTER TABLE matrix_sessions ENABLE ROW LEVEL SECURITY` (and therefore no policies). This contrasts with `server_config`, `audit_log`, `compliance_requests`, `compliance_sessions`, `room_account_data`, `notifications`, `push_rules`, and `pushers`, all of which have RLS in the same migration. MEMORY.md flags this as a recurring "missing RLS on new tables" pattern in Epic 9.

**Why it's not HIGH/MEDIUM:**
- In the single-role managed-PG deployment model (Story 13.14 / ADR-016), `nebu_app` is the table owner and bypasses RLS by default — so RLS only adds protection in dual-role self-hosted deployments. The accepted-risk row in MEMORY.md for `audit_log` documents this trade-off.
- The pre-existing `admin_sessions` table (line 297) also has no RLS — this is a consistent (if imperfect) pattern, not a regression.
- All access to `matrix_sessions` goes through the gateway, which always operates as `nebu_app`. No SQL-injectable surface was found in the new code paths (all queries are parameterized).

**Why it's still worth flagging:**
- Dual-role deployments lose a defense-in-depth boundary they have for `events`, `audit_log`, etc.
- The pattern keeps recurring — explicit documentation (or the policy itself) would close the gap.

**Remediation (optional, advisory):**
Add to the migration after the index creation block:

```sql
ALTER TABLE matrix_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY matrix_sessions_app_full ON matrix_sessions
    FOR ALL TO PUBLIC USING (true) WITH CHECK (true);
```

Or, alternatively, add a one-line comment to the migration explaining why session tables are exempt.

### Finding #2 — Opaque-token path drops `ContextKeySystemRole` (and other JWT-only ctx keys) [LOW]

`WithOpaqueSessionCheck` (auth.go:260-264) populates only `ContextKeyUserID` and `ContextKeyDeviceID`. The inner JWT middleware is **skipped** when an opaque token is presented — so `ContextKeySub`, `ContextKeyPreferredUsername`, `ContextKeyEmail`, `ContextKeyNebuRole`, `ContextKeySystemRole`, and `ContextKeyTokenExpiry` never reach downstream handlers.

Across `gateway/internal/matrix/{rooms,sync,event,members,receipts,rooms_upgrade}.go`, downstream handlers read `ContextKeySystemRole` and forward it to the Core via `coregrpc.WithUserMetadata(r.Context(), userID, systemRole)`. For an opaque-token session, the Core receives `system_role=""`. `auth.MapSystemRole("")` returns `"user"` (lowest privilege) — so the practical effect is **privilege downgrade**, not escalation.

**Why it's not HIGH/MEDIUM:**
- Empty role is strictly less privileged than any non-empty role. The Core (Story 14.3a fix) is designed to reject anonymous / untrusted calls — `system_role=""` cannot grant admin powers.
- No code path in this diff (or in the broader Core) treats `""` as privileged.

**Why it's still worth flagging:**
- An SSO-issued opaque session for an `instance_admin` user effectively cannot perform admin Matrix actions until the user logs in through a different (JWT) path. This is a usability issue, but the security relevance is: if a future refactor ever introduces a "fallback to admin when role is unset" pattern, this oversight would become an escalation primitive.
- The `MatrixSession` row already has `user_id` — storing role at session creation and reading it back in `LookupOpaqueToken` is a small enhancement.

**Remediation (optional):**
Either populate the role at session creation (PostLogin already has `systemRole` in local scope) and surface it through `OpaqueSessionLookupResult` → `ContextKeySystemRole`, or add a comment to `WithOpaqueSessionCheck` documenting the deliberate downgrade.

### Finding #3 — Opaque vs JWT dispatch trusts the `.` invariant [LOW]

`auth.go:223` distinguishes opaque tokens from JWTs by `strings.Contains(rawToken, ".")`. Today this is safe: `generateOpaqueToken` returns 64 lowercase hex characters; JWTs always have exactly two dots. If a future implementer ever introduces an opaque format that allows dots (URL-safe base64, padded base64, JWE, etc.), tokens containing dots would be misrouted to the JWT verifier and rejected as malformed — not a security vulnerability per se, but a fragility worth pinning.

**Remediation (optional):**
Add a `// INVARIANT: opaque tokens are 64-char lowercase hex — never contain "."` comment above the dispatch, or strengthen the check to `len(strings.Split(rawToken, ".")) == 3` for the JWT branch.

---

## Verifications (no findings)

### SQL injection
All new DB queries use parameterized `$N` placeholders (`Exec`, `QueryRow`). Reviewed:
- `Create` (matrix_session_store.go:47-57) — 6 placeholders
- `GetByAccessToken` (line 72-76) — 1 placeholder
- `GetByRefreshToken` (line 119-125) — 1 placeholder
- `RotateTokens` (line 168-217) — all placeholders, transaction-scoped
- `MarkAccessTokenUsed` (line 245-267) — all placeholders
- `Revoke` (line 277-280) — 1 placeholder
- `LookupOpaqueToken` (line 303-315) — 1 placeholder; the EXISTS subquery references only column identifiers and `NOW()`, no user input
- `CleanupExpired` (line 347-349) — no parameters

No string concatenation with caller-controlled data anywhere. **CLEAN.**

### Auth bypass — `POST /refresh` registered outside `jwtMiddleware`
Intentional per spec MUST. Reviewed `gateway/cmd/gateway/main.go:712`:
```go
mux.Handle("POST /_matrix/client/v3/refresh", strictRL(bodyLimit1MiB(http.HandlerFunc(refreshHandler.PostRefresh))))
```
Still gated by:
- `strictRL` — 30 req/min, burst 10, per-IP (or trusted-proxy XFF) ✓
- `bodyLimit1MiB` — 1 MiB body cap ✓
- Refresh token presented in body is required and validated against `matrix_sessions.refresh_token` (256 bits of entropy from `crypto/rand`).

**No other route added without authentication.** Verified `git diff --staged gateway/cmd/gateway/main.go` — the only main.go change is wiring `MatrixSessions` into `LogoutConfig`. **CLEAN.**

### Timing attacks on token comparison
Opaque AT/RT lookups go through Postgres B-tree index equality (`access_token` is PRIMARY KEY, `refresh_token` has a UNIQUE index). Lookup time is O(log n) and dominated by network jitter — timing oracle on 256-bit random tokens is computationally infeasible (search space 2²⁵⁶). No in-process `==` comparisons of secrets exist in the new code; all comparisons are delegated to Postgres. **CLEAN.**

### Rate limits on `POST /refresh`
`strictRL` (`middleware.NewIPRateLimiter`, 30 req/min, burst 10) — same bucket as `POST /login`. Per Matrix spec MUST. Configured at `main.go:325`. **CLEAN.**

### Weak crypto
- `generateOpaqueToken` (refresh.go:50) uses `crypto/rand.Read` for 32 bytes → 256-bit entropy → hex-encoded. No `math/rand` anywhere in the new code paths. ✓
- `encryptOIDCRefreshToken` delegates to `admin.EncryptAES256GCM` (crypto.go:37). AES-256-GCM with SHA-256 KDF over `internal_secret`. Nonce from `crypto/rand.Reader` (gcm.NonceSize() = 12 bytes), nonce prefixed to ciphertext, hex-encoded output. Standard AEAD construction. ✓
- No MD5, SHA1, DES, RC4 in the new code. **CLEAN.**

### Plaintext secrets in logs
All `slog` calls in `login.go`, `logout.go`, `refresh.go`, `matrix_session_store.go`, `auth.go` were enumerated. Only `err`, `user_id`, `device_id`, and message strings are logged. **Never** the raw or encrypted access_token, refresh_token, or OIDC refresh token. ✓
- `refresh.go:134`: `slog.Info("matrix session refreshed", "user_id", ..., "device_id", ...)` — clean
- `login.go:348`: `slog.Warn("PostLogin: failed to encrypt OIDC refresh token", "err", encErr, "user_id", userID)` — clean (err from `aes.NewCipher` / `cipher.NewGCM` does not contain plaintext)
- `logout.go:75,98`: only `err` and userID/deviceID — clean

**CLEAN.**

### JWT validation flaws (opaque path bypasses JWT validation)
`WithOpaqueSessionCheck` dispatches by presence of `.` — JWTs (which always have two dots) go to the inner JWTMiddleware unchanged. JWT validation logic in `JWTMiddleware` is untouched. Reviewed:
- Signature verification via go-oidc verifier with explicit `SupportedSigningAlgs` whitelist (auth.go:300-303) — algorithm confusion prevented ✓
- `verifier.Verify` enforces `exp` and `aud` ✓
- Denylist check only AFTER cryptographic verification passes (line 319) — prevents DB flooding ✓

The opaque path itself validates: presence (LookupOpaqueToken), not-revoked, not-expired. Revocation returns 401 without soft_logout; expiry returns 401 WITH soft_logout (per spec SHOULD). **CLEAN.**

### Missing body-size limits on `POST /refresh`
`bodyLimit1MiB` wrapper applied at `main.go:712`. Inside `PostRefresh` itself, `r.ContentLength == 0` check rejects empty bodies before `json.NewDecoder(r.Body).Decode`. The 1 MiB cap is generous for a JSON body with a single 64-char hex refresh_token, but defends against arbitrary payload DOS. **CLEAN.**

### OIDC RT stored AES-256-GCM — key derivation
Key = `sha256.Sum256(internal_secret)`. `internal_secret` is read at startup from `cfg.InternalSecretFile` (or `NEBU_INTERNAL_SECRET` env fallback per Story 8-11), trimmed, used as `[]byte`. The same secret is reused for AES-256-GCM admin secret encryption (oidc_client_secret, scim_bearer_token) — established pattern, audited in Story 14.3c (no asymmetric handling here unlike Story 14.2b's oidc_directory_bearer_token gap noted in MEMORY.md).
- KDF (SHA-256 over a high-entropy server secret) is adequate — `internal_secret` is operator-generated random bytes, not a low-entropy password, so PBKDF2/Argon2 is unnecessary.
- Nonce uniqueness from `crypto/rand.Reader` (12 bytes / 96 bits) is per NIST SP 800-38D best practice for AES-GCM.
- AEAD authentication tag is implicit in `gcm.Seal`/`gcm.Open`.

**CLEAN.**

### Session revocation on logout (MAJOR-A from cycle 1)
Verified the fix:
- `PostLogout` (logout.go:71-82) dispatches by `!strings.Contains(rawToken, ".") && h.matrixSessions != nil` → calls `MatrixSessions.Revoke(rawToken)`.
- `Revoke` (matrix_session_store.go:276-285) issues `DELETE FROM matrix_sessions WHERE access_token = $1` — hard delete, immediate.
- Subsequent requests with the same token: `LookupOpaqueToken` returns `(nil, nil)` (sql.ErrNoRows) → `WithOpaqueSessionCheck` returns 401 M_UNKNOWN_TOKEN.
- Ownership: the rawToken came from the Authorization header that just authenticated this request via `WithOpaqueSessionCheck` — it is provably the caller's own token. No cross-user revocation primitive.
- Backward compat: when `matrixSessions == nil` (legacy / test config), falls through to denylist `Invalidate` (preserves pre-bugfix behavior).
- Three new unit tests (logout_test.go:255-339) cover: revoke called for opaque + denylist not used, fallback to denylist when store is nil, 200 returned on Revoke error.

**CLEAN — MAJOR-A is fully closed.**

### Grace-window double-rotation safety (spec MUST AC4)
Walked the AC4 race scenarios:
1. Bob calls `/refresh` with RT_A → row 1 soft-revoked (revoked_at, grace_until=NOW()+60s), row 2 created (AT_B, RT_B). Bob receives AT_B + RT_B.
2. Bob authenticates a Matrix call with AT_B → `LookupOpaqueToken` finds row 2, `HasGraceWindow=true` (sibling row 1 still in grace) → `MarkTokenUsed(AT_B)` expires row 1's grace.
3. Attacker who stole RT_A tries `/refresh` with RT_A:
   - Before step 2: `GetByRefreshToken(RT_A)` returns row 1 (still in grace). `RotateTokens(OldAccessToken=AT_A)` UPDATE has `WHERE access_token = AT_A AND revoked_at IS NULL` → 0 rows → ErrMatrixSessionNotFound → 401. Attacker locked out.
   - After step 2: `GetByRefreshToken(RT_A)` returns ErrMatrixSessionNotFound (grace expired + revoked_at not NULL) → 401.
   - **Double-rotation of any RT always fails after first rotation.** No spec-violating token re-use possible.

The grace window only allows reading the old refresh token for one-shot lookup of the soft-revoked row's data; rotation itself is gated by `revoked_at IS NULL`. **CLEAN.**

### `HasGraceWindow` correctness
`LookupOpaqueToken` (matrix_session_store.go:325-327):
```go
hasGraceWindow := !revokedAt.Valid && hasGrace
```
- When current AT itself is revoked: `revokedAt.Valid=true` → `hasGraceWindow=false` → MarkTokenUsed not called. But `Revoked=true` triggers 401 at line 240-242 of auth.go before reaching the MarkTokenUsed call site anyway. Double-safe.
- The EXISTS subquery scope (`s2.user_id = m.user_id AND s2.device_id = m.device_id AND s2.access_token != m.access_token AND s2.revoked_at IS NOT NULL AND s2.grace_until > NOW()`) — finds siblings (same user+device) that are soft-revoked and still in grace. Cannot leak rows across user/device boundaries. **CLEAN.**

### Cleanup goroutine
`main.go:676-683` — runs `matrixSessionStore.CleanupExpired()` every hour. `CleanupExpired` (matrix_session_store.go:347-358) executes `DELETE FROM matrix_sessions WHERE expires_at < NOW() - INTERVAL '7 days'` — parameterless query, owner-scoped, retains 7 days post-expiry. No injection vector. No data leak. **CLEAN.**

### Integration test change
`matrix_session_refresh_steps_test.go` removes the unused `withAuth bool` parameter from `doPostRefresh`. Reflects the spec MUST that `/refresh` requires no Authorization header. Test-only change, no production impact. **CLEAN.**

### Unrelated change (out of scope but checked)
`skills/nebu-agent-testing/scripts/ci_gate.py:131` swaps Keycloak health probe URL for Dex. Cosmetic / dev-environment only. Not a security concern. **CLEAN.**

---

## Summary

- **CRITICAL: 0** — none
- **HIGH: 0** — none
- **MEDIUM: 0** — none
- **LOW: 3** — advisory, optional follow-ups

**Verdict: APPROVED / CLEAN — commit not blocked.**

All security scope items from the calling prompt were checked and are clean:
- SQL injection (parameterized queries throughout) — clean
- Auth bypass on `/refresh` (intentional per spec, gated by strictRL + bodyLimit1MiB) — clean
- No other unprotected routes added — clean
- Timing attacks on token comparison — N/A (256-bit random tokens, B-tree lookups) — clean
- Rate limits on `/refresh` (strictRL: 30 req/min, burst 10) — clean
- Weak crypto (crypto/rand for 32-byte tokens, AES-256-GCM via SHA-256 KDF) — clean
- Plaintext secrets in logs — clean
- JWT validation flaws on JWT path — unchanged from prior reviews — clean
- Body-size limit on `/refresh` (1 MiB) — clean
- OIDC RT AES-256-GCM key derivation (SHA-256 over internal_secret) — clean
- Session revocation on logout (MAJOR-A cycle-1 fix) — verified clean

The three LOW findings are defense-in-depth / forward-compat advisories and do not block the commit. They are recorded for the epic-end security review (SEC Gate 2) and as future cleanup items.

---

## Memory updates queued for session close

- Add LOW Finding #1 to recurring-pattern table: continued "Missing RLS on new tables" instance (now `matrix_sessions` + the precedent `admin_sessions`). Worth considering an audit pass that adds explicit-allow RLS policies to all session-shaped tables.
- Add LOW Finding #2 as new pattern: "Multi-path authentication middleware must populate the same context keys, or downstream consumers must defend against missing keys." Generalizes `WithOpaqueSessionCheck` vs `JWTMiddleware` divergence in `ContextKeySystemRole` etc.
- Add LOW Finding #3 as forward-compat note: "Dispatch-by-token-format invariants need explicit pinning."

Epic-end review (SEC Gate 2): expect to re-verify these in combined deployment topology context once the full bugfix is merged.
