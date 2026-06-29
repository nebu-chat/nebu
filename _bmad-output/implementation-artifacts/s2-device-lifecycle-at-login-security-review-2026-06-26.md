# Security Review — device-management / s2-device-lifecycle-at-login (SEC Gate 1)

**Reviewer:** Kassandra (adversarial security reviewer)
**Date:** 2026-06-26
**Branch:** feature/device-management
**Diff scope:** `git diff --staged` — production code:
- `server/lib/nebu/matrix/session/device_binding.ex` (NEW — token→device binding store)
- `server/lib/nebu/matrix/http_public.ex` (login: device register + JWT bind)
- `server/lib/nebu/web/plugs/oidc_plug.ex` (assigns `:device_id`)
- `server/lib/nebu/web/router/protected.ex` (`/keys/upload` mismatch reject, lazy bind, `/sync` throttled last_seen)
- `server/lib/nebu/matrix/device_key_store.ex` (`sole_device_id` removed; `touch_last_seen` added)
- `server/priv/migrations/000011_jwt_device_bindings.{up,down}.sql`

This story is the HIGH-density S2 item from my 2026-06-26 whole-epic design review. Each
Watch-List item (MEMORY.md S2 section) is verified below.

---

## Verdict: APPROVED / CLEAN — no CRITICAL, no HIGH.

The three story security goals (G1 no cross-device transfer, G2 refresh cannot re-bind,
G3 refresh non-regression) are met. Findings are LOW/INFO hardening + watch-flags only.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | LOW | protected.ex:332-350 (lazy bind) | Intra-user device-key clobber via an **unbound** raw-JWT: a same-user token with no binding can name an existing device and overwrite its directory key blob. Same principal, no cross-user/cross-tenant crossing, non-E2EE directory (ADR-011). Window closes once a token is bound. | Optionally refuse lazy-bind to a device that already has a *different* bound token, or require the device be keyless/owned-by-this-token. Track for S3. |
| F-2 | LOW | device_binding.ex:96-123 | Per-node ETS TTL cache is process-independent and unbounded in entry count (no eviction beyond TTL staleness check on read). Memory growth under high token churn. | Periodic sweep or `:ets` size cap; mirror OidcPlug provisioning-cache hygiene if it has one. |
| F-3 | LOW | 000011 up.sql | `jwt_device_bindings` has no RLS policy (family-wide gap shared with `matrix_sessions`/`device_keys`/`devices`). Consistent, not a regression. | Address as a family-wide defense-in-depth follow-up, or document the deliberate omission. |
| F-4 | INFO | device_binding.ex:42-48 | `put/3` `ON CONFLICT (token_hash) DO UPDATE SET user_id, device_id` — token_hash is SHA-256 of the verified JWT; a hash collision or token reuse across users is cryptographically infeasible. Recorded for completeness. | None. |

---

## Story Security Goals — verification

### G1 — No cross-device session transfer. **MET.**

The device a request acts as is resolved **solely server-side**:
- Opaque sessions: `OidcPlug.call_opaque` assigns `:device_id` from `sess.device_id`
  (matrix_sessions row) — oidc_plug.ex:110. Server-authoritative.
- Raw JWT: `OidcPlug.call_jwt` assigns `:device_id` from
  `DeviceBinding.get_device(token)` — oidc_plug.ex:136. The binding row is keyed by
  `SHA-256(token)`; the device comes from that row, never from request input.

`/keys/upload` cross-device transfer (attack surface #1) — traced precisely:
- `bound_device = conn.assigns[:device_id]` (server-side), `body_device =
  device_keys["device_id"]` (client). protected.ex:315-316.
- The **up-front mismatch check** (protected.ex:328-330) fires when both are present and
  differ → `403 M_FORBIDDEN` **before any write**. So token T_A (bound DEV_A) naming
  `device_id="DEV_B"` is rejected. ✓
- `upload_device_id` (protected.ex, post-diff) orders bound-device FIRST, body-device
  second, nil last. So when a binding exists, the body device_id can only *match* it
  (mismatch already 403'd) — it is never authority. ✓ The removed `sole_device_id/1`
  heuristic (which could mis-attribute a multi-device user's OTK upload to a wrong device)
  is gone — confirmed in device_key_store.ex diff. ✓

Lazy JWT binding (`maybe_bind_jwt_device`, attack surface #2) — adversarial sub-cases:
- **(a) bind a token to a device it doesn't own / (b) re-bind an already-bound token:**
  `maybe_bind_jwt_device` no-ops when `conn.assigns[:device_id]` is already set
  (protected.ex:1158-1160). A bound token can NEVER re-bind. And any token that goes
  through S2 login is bound at login (`DeviceBinding.put`, http_public.ex). So re-bind/
  promotion is blocked. ✓
- **(c) hijack another USER's device:** impossible — `user = conn.assigns[:current_user]`
  is the verified-token identity; `user_id` is never body-supplied on any write
  (`put_device_keys`/`store_*`/`upsert_device` all take the authenticated `user`).
  No cross-user reach. ✓
- **(d) clobber a victim device's keys within the SAME user:** the one residual path
  (F-1, LOW). Requires the attacker to already be the user (hold a valid unbound JWT for
  that user) — a same-principal action on a non-E2EE directory entry, not a security-
  boundary crossing. The token cannot thereby reach any *other* user's data. Window
  exists only for pre-S2 / never-login-bound JWTs; login always binds. Severity LOW.

A stolen/copied token masquerading as another device: the token resolves to exactly the
device its server-side binding records; it cannot be promoted to a different device
(re-bind blocked) nor name a different device (mismatch 403). ✓

### G2 — Refresh cannot re-bind the device. **MET.**

`MatrixSessionStore.rotate_tokens/1` (store:146-162) reads `user_id, device_id` from the
OLD row and copies them verbatim into the new row's INSERT. device_id is never taken from
the caller. The raw-JWT `jwt_device_bindings` row is keyed by token hash and is **not
touched by the refresh path at all** (refresh is the opaque-session flow; Element uses the
raw JWT directly and does not refresh). No way to obtain a token for a different device via
refresh. ✓

### G3 — Refresh feature non-regression. **MET.**

`rotate_tokens/1` is untouched by this diff except being exercised unchanged; grace-window
logic (`mark_access_token_used`, `has_open_grace_window?`), `expires_in_ms`, soft-logout
401 paths are all unmodified. The new `:device_id` assign is additive in both
`call_opaque` and `call_jwt`. No regression surface. ✓ (CI/unit gate confirms the
oidc-session-refresh tests stay green — out-of-band of this static review.)

---

## Attack-surface sweep

3. **Token at rest / log leakage:** `jwt_device_bindings.token_hash` stores only
   `SHA-256(token)` hex (device_binding.ex:94; migration header documents it). The raw
   token is never persisted and never logged in the new code. ✓

4. **Refresh re-bind:** covered under G2. ✓

5. **SQLi / IDOR / timing / body-vs-token user_id:**
   - All new SQL parameterized (`$1..$5`) — `put`, `get_device`, `touch_last_seen`,
     `upsert_device`. No interpolation. ✓ (ADR-018 inline SQL is the sanctioned pattern.)
   - IDOR: every device read/write is scoped to `conn.assigns[:current_user]`; `user_id`
     is never body-supplied on writes. `get_device`/`list_devices` are caller-scoped. ✓
   - Timing: token lookup is a hash-keyed PK equality in PostgreSQL, not a byte-compare of
     a secret in app code — no constant-time concern; the token is already
     cryptographically verified by OidcPlug before the binding lookup runs. ✓
   - Body `user_id` vs token: there is no body `user_id` on these paths; identity is the
     verified token. ✓

6. **ETS TTL cache (attack surface #6):** keyed by `SHA-256(full token)` → no cross-token
   collision, no poisoning (value is server-derived device or nil). A bound token's device
   never changes; `put/3` primes the cache on bind, so the negative-cache (`nil`) entry
   cannot serve a stale wrong device on the binding node. Cross-node stale `nil` (≤60s)
   resolves to "no bound device" → request treated as unbound (no-op write), i.e.
   **fail-safe** — never a wrong-device resolution, never an auth bypass. ✓ (F-2 LOW:
   memory growth only.)

7. **`/sync` last_seen throttle (attack surface #7):** `client_ip(conn)` reads
   `conn.remote_ip` (the directly-connected peer) — NOT `X-Forwarded-For`. The codebase
   deliberately does not trust XFF (rate_limit.ex:40-41). So no XFF-spoof injection into
   `last_seen_ip`; the value is server-observed and stored via parameter `$4`. The whole
   path is best-effort (`safe_query` swallows errors, never raises) so it cannot crash
   `/sync` (protected.ex `touch_device_last_seen`, device_key_store.ex `touch_last_seen`).
   DoS via forced writes is bounded by the 60s throttle (`WHERE last_seen_ts < cutoff`) —
   at most one write per device per 60s regardless of request rate. ✓

8. **Migration 000011 (attack surface #8):** forward-only, idempotent
   (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`). The per-request lookup
   `WHERE token_hash = $1` hits the PRIMARY KEY → index scan, no seq scan, no DoS. The
   secondary `idx_jwt_device_bindings_user` supports S3's device-delete enumeration. No
   sensitive data stored plaintext. `release_test.exs` count bumped to include 11. ✓

---

## Watch-List carry-forward to S3 (from MEMORY.md S2/S3 sections)

S2 lays the binding store S3 needs for device-delete completeness (pattern #70). Confirm at
S3 SEC Gate 1:
- Device delete must revoke **opaque rows AND denylist every JWT** bound to the device. The
  binding store records `token_hash` + `user_id` + `device_id` per row — note it does NOT
  store the JWT `jti` or `exp`. **S3's device-delete will need exp (to denylist) and may
  need to enumerate by (user_id, device_id)** — the `idx_jwt_device_bindings_user` index
  helps, but the table lacks an `exp` column and a `(user_id, device_id)` index. S3 must
  either add them or denylist by reading exp from the verified token at delete time. (HIGH
  at S3 if skipped — incomplete kill-switch.)
- UIA fresh-auth `auth_time` verification (HIGH-1/HIGH-2 design findings) — still pending
  S3, untouched here.
- `auth_time` must not be reset by refresh — S3 adds the column; this diff's
  `rotate_tokens` correctly copies user_id/device_id, so the carrying pattern is in place.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 3 (F-1 intra-user clobber on unbound JWT; F-2 ETS cache memory hygiene; F-3 no RLS — family-wide)
- INFO: 1

**Verdict: APPROVED / CLEAN.** G1, G2, G3 all met. No commit-blocking findings. LOWs are
hardening advisories; F-1 and the S3 carry-forward (binding store lacks `exp` for JWT
denylist on device-delete) are the items to track into S3.
