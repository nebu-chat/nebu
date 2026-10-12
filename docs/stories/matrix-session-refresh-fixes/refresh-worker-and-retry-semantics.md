---
story_id: refresh-worker-and-retry-semantics
title: "Bug: RefreshWorker invalidates client sessions; refresh retry not spec-compliant"
type: bug
severity: high
epic: matrix-session-refresh-fixes
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-07
branch: bugfix/matrix-session-refresh
---

## Summary

Legacy Matrix sessions (opaque tokens, `refresh_token: true` at login, e.g. FluffyChat) are logged out although the
server-paced `RefreshWorker` is meant to keep them alive.

**Root cause (code reading, not yet reproduced live):**

1. `Nebu.Matrix.Session.RefreshWorker.rotate/3` calls `MatrixSessionStore.rotate_tokens/1` with NEW access and refresh
   tokens. The client never receives them. `rotate_tokens/1` soft-revokes the old row immediately
   (`revoked_at = NOW()`, old refresh token only `grace_until = NOW() + 60s`). `OidcPlug.call_opaque/1` answers a revoked
   access token with `401 M_UNKNOWN_TOKEN` WITHOUT `soft_logout`. The client's own `/refresh` with the old refresh token
   fails once the 60s grace is over, so the SDK clears the session. The worker runs up to 1h before `expires_at`.
2. Matrix CS API (v1.19, "Refreshing access tokens" / "Refresh token grant"): the old refresh token "remains valid until
   the new access token or refresh token is used"; a client that lost the response retries with the old token LATER.
   The fixed 60s window in `rotate_tokens/1` is not compliant. The comment in `matrix_session_store.ex` (~l.20-30)
   cites the spec incorrectly.

## Story

As a Matrix user on a client that refreshes its own tokens,
I want my session to stay valid when the server extends it in the background and when my refresh response gets lost,
so that I am not logged out without a reason.

## Acceptance Criteria

**AC1 — Worker never rotates tokens the client must know:**
`RefreshWorker` extends a session by updating `expires_at` (and a provider-rotated encrypted OIDC refresh token) IN PLACE
on the same row. Access token and refresh token stay unchanged. No new row, no `revoked_at`, no grace window is created.
The `expires_at` cap stays `session_expires_at/1` (`min(fresh_oidc_exp, now + ceiling)`).

**AC2 — Worker and client refresh do not invalidate each other:**
After a worker cycle, the client's existing access token still authenticates and its existing refresh token still works
on `POST /_matrix/client/v3/refresh`. A client `/refresh` followed by a worker cycle (and the reverse) leaves exactly one
non-revoked row per device whose tokens are the ones last returned to the client.

**AC3 — Old refresh token stays valid until the new token is used (spec):**
After `/refresh` rotation, the OLD refresh token still yields a successful refresh (returning a response for the
session) until the NEW access token has been used on an authenticated request OR the new refresh token has been used.
It is not limited to 60 seconds. Bound: the old token is never valid beyond the session's own `expires_at`.

**AC4 — Consumed refresh token is rejected, session destroyed:**
Once the new access token has been used (or the new refresh token redeemed), presenting the old refresh token returns
`401 M_UNKNOWN_TOKEN` WITHOUT `soft_logout: true` (spec: the session is destroyed, so the client must discard its state;
Oracle 2026-10-07). Reuse of a consumed token additionally hard-invalidates the session for that device only (spec
SHOULD, borrowed from the OAuth refresh grant as an allowed hardening). Other devices of the user are unaffected.
An expired access token with a still-valid refresh token keeps `401 M_UNKNOWN_TOKEN` + `soft_logout: true`.

**AC5 — Cluster safety (ADR-020):**
Rotation, "mark used" and worker extension are atomic single-row statements (`UPDATE ... WHERE ... revoked_at IS NULL`
style). Two nodes racing on the same row yield exactly one winner and never delete or revoke the winner's row.

**AC6 — Failure handling unchanged:**
Transient IdP/DB errors in the worker still leave the row intact; confirmed IdP rejection still hard-deletes only the
exact row (`delete_by_access_token/1`). No tokens, codes or OIDC refresh tokens are logged.

**AC7 — Transient failures on /refresh are 5xx, never 4xx (spec client rule):**
A transient failure in `POST /refresh` (IdP unreachable/discovery failure, IdP 5xx/429, DB hiccup, `:transient_check_failed`)
returns `503` (`M_UNKNOWN`/`M_LIMIT_EXCEEDED` style body as appropriate) with `Retry-After` where applicable, and leaves
the session untouched, because clients log out on any 4xx and retry on 5xx. Only CONFIRMED rejection (IdP explicit
rejection, decrypt failure, deactivated user) returns 401 and invalidates the session. Today `do_refresh_with/2` returns
401 for `:transient_check_failed` and hard-deletes the session for every other error, including IdP-unreachable. The
worker's `transient?/1` classification is reused (single source of truth).

**AC8 — Comments and docs corrected:**
The incorrect spec citation in `matrix_session_store.ex` is replaced by the accurate rule; `docs/architecture/08-concepts.md`
(grace period section and the worker section) describes the new behavior.

## Acceptance Tests

- Worker cycle on a session created with `refresh_token: true`: access token and refresh token unchanged, `expires_at`
  extended, no revoked sibling row.
- Client `/refresh` then old refresh token after 61+ seconds (simulated by backdating, no sleep): succeeds while the new
  access token is unused; fails with `soft_logout: true` once the new access token was used.
- Reuse of a consumed refresh token invalidates that device's session and no other device's session; response has no `soft_logout: true`.
- IdP unreachable / IdP 5xx / DB error on `/refresh`: 503, session row intact, retry with the same refresh token later succeeds.
- Concurrent `/refresh` with the same refresh token: one rotation wins, the loser gets a consistent response.
- Existing worker tests (`refresh_worker_test.exs`) updated to the in-place semantics; their transient/confirmed
  classification tests stay green.

## Dev Notes

- Files: `server/lib/nebu/matrix/session/refresh_worker.ex`, `matrix_session_store.ex`, `matrix/http_public.ex`
  (`do_refresh_with/2`, `do_rotate/6` + `rotate_attempt/6`), `web/plugs/oidc_plug.ex` (`call_opaque/2`, no grace handling).
  Follow-up: rename the public `has_open_grace_window?/1` (used by the plug) to pending/consumed wording.
- A migration is allowed ONLY if needed for the "valid until used" marker (e.g. nullable `grace_until` semantics /
  `consumed_at`); it must be reversible and cluster-safe. Pipeline-protected paths are touched only inside this run.
- Out of scope: hashing of stored tokens (next bugfix `token-hashing-matrix-sessions`), OAuth work (branch
  `feature/migrate-to-oauth2`, spec `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 6, 8).
- Oracle context to confirm: Matrix CS API v1.19 refresh semantics (legacy `/refresh`: server MAY keep old token valid;
  OAuth refresh grant: "remains valid until the new ... is used").
- Pending/consumed is decided by `grace_until IS NULL` / `IS NOT NULL` only (no `NOW()` comparison): `NOW()` is the
  Postgres transaction start and could read a concurrently consumed token as pending. No migration needed. Sibling
  multi-row updates lock rows in `access_token` order (deadlock-free).
- Follow-up (not in this story): pending soft-revoked rows now live until their `expires_at`, so `matrix_sessions`
  grows by one row per client refresh until logout/device delete. `Store.cleanup_expired/0` exists but is not wired to a
  periodic sweeper; wire a supervised sweeper in a follow-up story.
- Deploy transition (I-A): rows with an old time-valued `grace_until` count as consumed after deploy; a client that is
  inside the old 60 s window at deploy time is logged out once (401 without `soft_logout`).
- Security review cycle 3 (Kassandra, owner decided to fix all three):
  - F-1: `extend_in_place/3` caps the worker extension at `created_at + matrix_session_ttl_seconds` (no migration);
    at the cap the worker stops extending (normal expiry / `soft_logout` path).
  - F-2 / N-1 (final, cycle 4; replaces the cycle-3 30 s in-flight window, which was removed): `OidcPlug.call_opaque/2`
    answers EVERY soft-revoked access token (pending or consumed) with 401 `M_UNKNOWN_TOKEN` + `soft_logout: true` and never
    deletes or detects reuse in the plug. Reuse detection happens only on `/refresh` (bounded by F-3). Passive attacker
    (replays RT0 only): the victim recovers with its still-pending RT1 and wins the device back. Active attacker (uses
    AT2, which consumes the victim's RT1): the victim's `/refresh` with consumed RT1 is reuse -> device deleted -> both
    logged out = visible end of the takeover.
  - F-3: reuse detection in `resolve_refresh_token/1` is bounded: only a consumed row younger than the session TTL
    ceiling of a device that still has an active unexpired row deletes the device; otherwise a plain 401.
  - N-3: `RefreshWorker.candidates/0` excludes rows with `created_at + ttl <= NOW()` (capped rows never trigger an IdP
    call); the worker log says "revalidated (expiry extended up to the absolute cap)".
  - M-1: `extend_in_place/3` is `GREATEST(expires_at, LEAST(new, created_at + ttl))`: strictly extending, never shortens.
  - N-5 / deploy: deploy logs out nobody; rows extended beyond the cap by older worker versions keep their expiry; only
    clients inside the old 60 s grace window at deploy time are logged out once (I-A). The stale COMMENT on
    `matrix_sessions.grace_until` in `000001_init.up.sql` is not edited (applied migration, I-5).
