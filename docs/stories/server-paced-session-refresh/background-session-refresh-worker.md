---
story_id: background-session-refresh-worker
title: "Server-paced background session refresh worker for opaque Matrix tokens"
epic: server-paced-session-refresh
status: done
security_review: required
matrix: true
ui: false
created: 2026-07-03
---

# Background Session Refresh Worker

## Story

**As** the Nebu platform,
**I want** to proactively keep opaque Matrix access tokens alive by automatically redeeming each device's stored upstream OIDC refresh token in the background before the session bound expires,
**so that** clients (Element, FluffyChat, etc.) using the legacy Element Web SSO-token-login path never need to call `POST /refresh` to stay logged in and never experience a 401 due to session expiry as long as the background refresh keeps succeeding.

### Background / current state

Element Web's classic SSO redirect + token-login flow (`redirect_uri` = client's own `/login` endpoint) ends with the server issuing an opaque Matrix access token that is bound to the user's `matrix_sessions` row. Unlike modern Matrix clients that call `POST /refresh` proactively, Element Web never calls `/refresh` and never requests `refresh_token: true` at login — the session was historically a fire-and-forget issuance.

**Current lifetime behavior:**
- At login (`respond_login` in `server/lib/nebu/matrix/http_public.ex`, line ~380), `session_expires_at(claims)` computes the session bound as `min(oidc_exp, now + 8h)` — capped by the upstream OIDC token's expiry (e.g. 5-minute Dex tokens) and an 8-hour rolling ceiling.
- The `matrix_sessions` row stores this `expires_at` in Postgres, plus an AES-256-GCM-encrypted copy of the upstream OIDC refresh token (`oidc_refresh_token` column, see `000001_init.up.sql` line 329).
- Per-request checks (`OidcPlug.call_opaque`, `server/lib/nebu/web/plugs/oidc_plug.ex` line 71) verify the opaque access token is not expired and not revoked.

**The gap:**
Today, no background process redeems the upstream OIDC refresh token to extend the session's bound. The session simply expires at its initially-set `expires_at`, because:
- `Nebu.Matrix.Session.Sweeper` (line 1) runs hourly but only cleans up expired `jwt_device_bindings` and UIA sessions — it never touches `matrix_sessions`.
- There is no other periodic/background process for `matrix_sessions`.

**Result:** Even though the infrastructure to redeem the OIDC RT and extend the session exists (used by `POST /refresh` in `do_refresh_with/2`), Element Web users relying on the legacy login path eventually get logged out when the initial session bound passes, because that background refresh never fires.

### The solution

Add a **server-paced, per-device background refresh worker** that:
1. Runs periodically (e.g., every 5 minutes or hourly).
2. For each `matrix_sessions` row nearing its bound `expires_at` (within a configurable lookahead window, e.g. 1 hour), redeems that row's stored upstream OIDC refresh token.
3. On success, updates `expires_at` to a new bounded rolling window (`now + 8h`, still capped by the fresh upstream `oidc_exp` when known), transparently extending the session.
4. On failure (upstream rejection, revocation, decryption failure, or any IdP error), the session simply expires at its already-set `expires_at` with no further extension — no local-only fallback.

The client (Element Web) simply keeps using the same opaque access token without calling `/refresh`, never sees a 401, and stays logged in indefinitely (as long as the background refresh keeps succeeding and the upstream account remains active).

---

## Acceptance Criteria

**AC1: Background worker exists and refreshes nearing sessions.**

A new periodic worker (GenServer or simple scheduled loop) exists that, for each `matrix_sessions` row with `revoked_at IS NULL` and `expires_at` within a reasonable lookahead window (e.g. ≤1 hour in the future from now), redeems the row's stored upstream OIDC refresh token and extends `expires_at` by the same bounded rolling-window logic used at login — without requiring any client request.

---

**AC2: Per-device failure isolation.**

The worker operates per `(user_id, device_id)` session row. A failure or upstream rejection for one device's session does not affect any other device's session, including other devices of the same user. Each row is refreshed independently; if device A's upstream session is revoked, device B's session continues and can be refreshed.

---

**AC3: TOCTOU-safe execution — re-check before redemption.**

At the exact moment the worker is about to call the upstream IdP (Keycloak/Dex) to redeem a refresh token, it MUST re-check that the session row still exists and `revoked_at IS NULL` — not relying on a session list from an earlier time. If a session is revoked or deleted between being selected for refresh and the redemption call, the worker MUST NOT refresh it (regression test: delete the device between "worker lists candidates" and "worker executes redemption" — the session must not be resurrected).

---

**AC4: Grace-window-safe row selection.**

`matrix_sessions` allows multiple rows per `(user_id, device_id)` during token-rotation grace periods (old + new token both briefly valid). When selecting sessions to refresh, the worker must choose only the currently-active row (`revoked_at IS NULL`, latest `expires_at`) per device — refreshing a stale grace-period row would create conflicting sibling tokens for the same device.

---

**AC5: Bounded rolling TTL — never unbounded expiry.**

`expires_at` after a background refresh is never extended beyond the existing bounded window ceiling (reuse/assert the same cap logic as `session_expires_at(claims)` — `min(oidc_exp, now + 8h)`). There is no code path that produces an unbounded or ever-growing expiry, regardless of how many successful refresh cycles have run.

---

**AC6: Fail-closed on upstream rejection.**

If the background redemption of a device's stored upstream refresh token is rejected by Keycloak/Dex (revoked, expired, IdP-side session/account state changed), the session is not kept alive by any other mechanism — it expires normally at its already-set `expires_at` with no further extension. No local-only fallback and no retry loop.

---

**AC7: Existing deactivation liveness-check unchanged.**

The existing per-request deactivation/liveness check in `OidcPlug` (call_opaque, `server/lib/nebu/web/plugs/oidc_plug.ex` line 71-114) with ≤60s TTL provisioned-user cache (via `provision/2`) is untouched and its behavior is unchanged. A device deletion or deactivation is still detected within the existing ≤60s bound, independent of the new worker's interval (regression test asserting deactivation liveness within the existing bound, independent of the refresh worker's cadence).

---

**AC8: Delete is the fast path, TTL is the fail-safe.**

If device deletion (`delete_one_device` in `server/lib/nebu/web/router/protected.ex` line 1401) fails/errors, the session is still bounded by its existing `expires_at` cap — no new code path exists that would let a session survive indefinitely past that cap due to a failed delete. This is a design/reasoning check, not necessarily new code: the bounded-cap property from AC5 and AC6 already provides it as a fail-safe. (Note: by design, this story does NOT add any new guarantee to the delete path; the bounded cap is the existing safety net.)

---

## Acceptance Tests

### Tests written FIRST (BDD/ExUnit `:integration`):

1. **Background refresh extends a nearing session** — ExUnit `:integration`
   - Given: a `matrix_sessions` row with `expires_at = now + 30m` and a valid encrypted upstream OIDC refresh token (backed by a test override)
   - When: the background worker runs and selects this row as nearing
   - Then: `expires_at` is updated to `now + 8h` (or the bounded window cap), and the session's opaque access token still works for authenticated requests

2. **Per-device failure isolation** — ExUnit `:integration`
   - Given: two devices of the same user, each with a nearing session; device A's upstream token is revoked, device B's is valid
   - When: the background worker runs
   - Then: device A's session expires normally (or fails-closed on next request); device B's session is refreshed and extended

3. **TOCTOU-safe: session deleted after selection, before redemption** — ExUnit `:integration`
   - Given: a nearing `matrix_sessions` row
   - When: the worker lists candidates, then (before redemption) the row is deleted (e.g. via `delete_one_device`)
   - Then: the worker detects the row is gone (re-checks before calling the IdP) and does NOT refresh it; no resurrection occurs

4. **Grace-period sibling safety** — ExUnit `:integration`
   - Given: a device with two active rows (old token in grace period, new token active) both nearing expiry
   - When: the background worker runs
   - Then: only the new (active, non-revoked) row is refreshed, not the grace-period sibling

5. **Bounded TTL ceiling asserted** — ExUnit `:integration`
   - Given: a session that has been successfully background-refreshed multiple times
   - When: each refresh completes
   - Then: `expires_at` is always `≤ min(fresh_oidc_exp, now + 8h)` — never unbounded, never drifting further into the future than the ceiling

6. **Fail-closed on upstream rejection** — ExUnit `:integration`
   - Given: a nearing session whose upstream OIDC token is expired/revoked (IdP returns 400/401 on grant_type=refresh_token)
   - When: the background worker attempts to redeem the token
   - Then: the worker logs the error, the session's `expires_at` is NOT extended, and the session expires normally at the original bound (AC6)

7. **Deactivation liveness unchanged** — ExUnit `:integration`
   - Given: a user with a valid, non-expired opaque session AND the worker configured to run (e.g. every 60s)
   - When: the user is deactivated and the next per-request comes in
   - Then: within ≤60s (the liveness-check TTL), the request is rejected with deactivation (does NOT depend on the worker's interval or whether a background refresh just happened)

8. **Design check: delete failure is bounded by TTL** — Reasoning/code review (not necessarily a new test)
   - Verify that `delete_one_device` failures do not create a code path that leaves a session alive indefinitely past its `expires_at` cap (existing logic + AC5/AC6 cap already guarantee this).

---

## Dev Notes

### Architecture & Design Principles

1. **No ADR changes needed.** This story introduces no new deployable, no new client-registration model, and does not affect ADR-022 (OIDC Bootstrap-Only) or any other existing ADR. It is a bounded, additive hardening of the existing legacy-login session-refresh path.

2. **Reuse the existing refresh redemption logic, don't duplicate.** `Nebu.Matrix.HttpPublic` already implements the core "redeem stored encrypted upstream RT, get a fresh one, extend the session" mechanics for the client-driven `POST /refresh` path (lines 556-699, including `revalidate_with_idp/1`, `exchange_oidc_refresh_token/1`, `do_rotate/3`). The new background worker should **reuse** this same core logic — specifically `revalidate_with_idp/1` and the rotation path — triggered by a timer instead of an incoming HTTP request. Do NOT write a second, parallel implementation.

3. **Follow ADR-018 (No Domain Model) and ADR-021 (Pure Elixir, in-process).** SQL is inline in the worker module (no Repository/Service layer). The worker itself is a GenServer or a simple scheduled loop (Process.send_after pattern, as in `Sweeper`), in-process plain Elixir — no external job queue (not a project dependency anyway).

4. **Per-device grain, not per-user.** The schema already defines `matrix_sessions(user_id, device_id, ...)` with a per-row, independently encrypted `oidc_refresh_token`. Iterating the worker over session rows (not users) gives per-device failure isolation for free: one device's revoked/expired upstream session must not affect sibling devices of the same user (AC2).

5. **Orthogonal liveness checks.** The existing ≤60s per-request deactivation check (via `provision/2`) is fully decoupled from this worker. Do NOT make the background worker's interval double as a liveness check, do NOT replace it, and do NOT lengthen the liveness-check TTL just because the refresh worker runs — the ≤60s deactivation-detection guarantee must be preserved exactly as-is (AC7, per memory feedback_oidc_session_refresh_learnings and OIDC Scopes Law in .claude/memory/).

6. **Delete is the fast path, TTL is the fail-safe.** This mirrors the accepted risk pattern in the codebase (from the oidc-session-refresh epic, SEC Gate 2, 2026-06-22): *"residual deactivation-lag window is ≤ TTL and applies ONLY if the row-delete is ever missed."* Device deletion (`delete_one_device` in `server/lib/nebu/web/router/protected.ex` line 1401-1430, which already hard-deletes all `matrix_sessions` rows for a given `(user_id, device_id)` on device removal) remains the fast, near-immediate revocation path. If that delete ever fails for any reason (transient DB error, etc.), the worst case is bounded to "at most one rolling TTL window's worth of extra life" (AC5, AC6) — not indefinite survival. Do NOT build retry/guarantee machinery around the delete path; the bounded TTL is the correctness guarantee by design.

### Key Code Locations (exact current line numbers)

Current code reviewed 2026-07-03:

- **Session expiry cap logic**: `server/lib/nebu/matrix/http_public.ex`, `session_expires_at/1` function, lines 470-481. This computes `min(oidc_exp, now + 8h)` — the exact same logic the background worker MUST use to compute the new `expires_at` after a successful refresh. **CRITICAL**: reuse this function, don't re-implement the ceiling logic.

- **Refresh redemption logic (reuse this)**: `server/lib/nebu/matrix/http_public.ex`, `revalidate_with_idp/1` function (lines 609-618) and `exchange_oidc_refresh_token/1` (lines 662-676). These handle decrypt, IdP round-trip, and fresh claims extraction. **CRITICAL**: the background worker should call these same functions (or a shared extracted version) rather than duplicating the OIDC exchange logic.

- **Rotation + `expires_at` update**: `server/lib/nebu/matrix/http_public.ex`, `do_rotate/3` function (lines 683-705) and `Nebu.Matrix.Session.MatrixSessionStore.rotate_tokens/2` (lines 150-206). This function soft-revokes the old row and inserts a new row with the fresh `expires_at`. The background worker must call `rotate_tokens/2` (or a variant) to apply the refresh.

- **Session store queries**: `server/lib/nebu/matrix/session/matrix_session_store.ex`, full module (lines 1-350+). Key functions:
  - `get_by_access_token/1` (line 108) — looks up a session by AT.
  - `rotate_tokens/2` (line 150) — atomically soft-revokes old row + inserts new row (reuse for background refresh).
  - `delete_for_user_device/2` (line 327) — deletes all rows for a `(user_id, device_id)` (used by device removal).

- **Existing background sweeper pattern**: `server/lib/nebu/matrix/session/sweeper.ex`, full module (lines 1-62). This GenServer is the template for a background worker in this codebase — hourly interval, safe_query pattern, idempotent SQL, let-it-crash error handling.

- **Per-request opaque token validation**: `server/lib/nebu/web/plugs/oidc_plug.ex`, `call_opaque/1` function (lines 71-114). This includes the existing ≤60s liveness check via `provision/2` (line 97). MUST NOT change this behavior (AC7).

- **Device deletion**: `server/lib/nebu/web/router/protected.ex`, `delete_one_device/3` function (lines 1401-1430). This shows how device deletion hard-deletes `matrix_sessions` rows (line 1424). The background worker MUST respect this as the fast-path revocation.

- **Database schema**: `server/priv/migrations/000001_init.up.sql`, lines 322-339. The `matrix_sessions` table definition, including the per-row `oidc_refresh_token` (AES-256-GCM encrypted) column and indices. No migration is needed for this story (the table already exists and has all required columns).

- **Existing liveness check implementation**: `server/lib/nebu/web/plugs/oidc_plug.ex`, line 97 calls `provision/2` (not defined in this module; likely in `Nebu.Matrix.Session`). This is the per-request deactivation gate with ≤60s cache TTL. AC7 mandates this is untouched.

### Critical Design Constraints (all are hard requirements)

1. **Per-device grain, not per-user.** Each `(user_id, device_id)` is refreshed independently. Iterate rows, not users.

2. **Bounded rolling TTL.** `expires_at` must never exceed `min(oidc_exp, now + 8h)`. Reuse `session_expires_at/1`.

3. **TOCTOU-safe.** Re-check `revoked_at IS NULL` before calling the IdP (line ~564 in http_public.ex shows the pattern — re-read the session row before the actual exchange).

4. **Grace-period safe.** Select only the active (non-revoked, latest) row per `(user_id, device_id)`.

5. **Fail-closed upstream rejection.** No local fallback; let the session expire at its bound.

6. **Reuse core logic.** Call `revalidate_with_idp/1` and `rotate_tokens/2`, don't duplicate.

7. **Orthogonal liveness checks.** Do NOT modify the per-request deactivation check or its ≤60s TTL.

8. **No new ADR/architecture changes.** Pure in-process scheduled loop or GenServer, inline SQL, no new deployable.

### Cluster Safety (ADR-020)

The background worker runs on every node. Since row selection (nearing sessions) is deterministic (based on `expires_at` wall-clock comparison), multiple nodes MAY attempt to refresh the same row concurrently. The `rotate_tokens/2` transaction (soft-revoke old + insert new) should be idempotent:
- If node A wins, the old row is soft-revoked and a new row is inserted. Node B's subsequent call will find the old row is already revoked (or grace-expired) and skip it.
- The per-row locking is via the `refresh_token UNIQUE NOT NULL` constraint — two concurrent inserts of a new RT for the same old AT will race, but this is acceptable since both are attempting the same (idempotent) operation.

Alternatively, a simpler approach: use a compare-and-swap pattern or a version field to ensure only the first successful refresh applies. The Go reference implementation (if available) may offer guidance here.

---

## Tasks / Subtasks

- [ ] **T1 — Worker module skeleton.** Create `server/lib/nebu/matrix/session/refresh_worker.ex` as a GenServer (or scheduled loop) that:
  - Starts via `Nebu.Application` supervision tree
  - Runs on a periodic interval (e.g. 5 minutes or hourly)
  - Has a `handle_info(:refresh, state)` handler that calls a private `refresh()` function

- [ ] **T2 — Session selection query.** Implement inline SQL to select all `matrix_sessions` rows where `revoked_at IS NULL` and `expires_at <= now + <lookahead_window>` (e.g. ≤1 hour). Group by `(user_id, device_id)` to ensure only the active row per device is selected.

- [ ] **T3 — Per-row refresh logic.** For each selected row, implement the TOCTOU-safe refresh:
  1. Re-check the row exists and `revoked_at IS NULL`
  2. Call `revalidate_with_idp/1` to redeem the encrypted OIDC RT
  3. On success, call `rotate_tokens/2` to update `expires_at`
  4. On failure, log and move to the next row (fail-closed, no extension)

- [ ] **T4 — Error handling & logging.** Ensure all errors (IdP rejection, decrypt failure, DB hiccup, etc.) are logged with sufficient context (user_id, device_id, reason) but do NOT raise — the worker must continue iterating to refresh other sessions.

- [ ] **T5 — Integration test: session refresh extends expiry.** Test AC1 — a nearing session is refreshed and `expires_at` is extended.

- [ ] **T6 — Integration test: per-device failure isolation.** Test AC2 — one device's refresh failure does not affect another device's refresh.

- [ ] **T7 — Integration test: TOCTOU safety.** Test AC3 — delete the session after selection but before redemption; verify no resurrection.

- [ ] **T8 — Integration test: grace-period sibling safety.** Test AC4 — with two rows (active + grace), only the active row is refreshed.

- [ ] **T9 — Integration test: bounded TTL ceiling.** Test AC5 — multiple refresh cycles never push `expires_at` beyond the cap.

- [ ] **T10 — Integration test: fail-closed upstream rejection.** Test AC6 — IdP rejection does NOT extend the session.

- [ ] **T11 — Regression test: liveness-check unchanged.** Test AC7 — deactivation is detected within ≤60s, independent of the worker's interval.

- [ ] **T12 — Supervision tree integration.** Register the worker in `server/lib/nebu/application.ex` so it starts automatically on application boot.

---

## Questions / Clarifications (for review)

1. **Lookahead window:** Should the worker refresh all sessions expiring within 1 hour? Or a different window? The story uses 1 hour as a reasonable default; confirm if this aligns with operational expectations.

2. **Refresh interval:** Should the worker run every 5 minutes, hourly, or something else? The story does not mandate a specific interval, only that it runs "often enough to stay ahead of each device's rolling TTL window." Recommend starting with 5-minute intervals and adjusting based on load.

3. **Cluster coordination:** Should nodes coordinate (e.g., via a lease/mutex) to avoid concurrent refresh attempts on the same row? Or accept that concurrent refreshes are fine (both idempotent)? The story assumes idempotent concurrent refreshes are acceptable; confirm with architecture if a distributed lock is needed.

4. **Logging verbosity:** Per-row refresh success/failure should be logged, but at what level? Recommend INFO for success, WARNING for expected failures (IdP rejection), ERROR for unexpected failures (DB hiccup, etc.).

---
