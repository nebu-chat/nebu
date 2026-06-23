# Security Re-Review — `oidc-session-refresh` cycle-2 (Kassandra HIGH #1)

- **Reviewer:** Kassandra (nebu-agent-kassandra)
- **Date:** 2026-06-22
- **Scope:** Focused re-review of the cycle-2 fix for the single HIGH raised in the cycle-1 review (deactivation bypass on the opaque Matrix session path).
- **Branch:** feature/full-elixir-stack

## Verdict: **LOW only** — no CRITICAL, no HIGH. Commit is unblocked.

## HIGH #1 — RESOLVED (yes)

**Original finding:** Admin deactivation via `deactivate_user/2` bypassed `matrix_sessions`
deletion. A deactivated user kept a working opaque AT for up to 8h and `POST /refresh`
minted fresh tokens, because `deactivate_user/2` called `destroy_session/1` directly
(never reaching the `invalidate_user_sessions/2` choke-point that cycle-1 had patched),
and `call_opaque` had no per-request `is_active` re-check.

**The cycle-2 fix is sound, and is defense-in-depth (two independent layers):**

### Layer 1 (PRIMARY) — delete-on-deactivate at the real entry point
`server/lib/nebu/matrix/event_dispatcher/server.ex:3336` — after the
`admin_db_module().set_is_active(user_id, false)` DB commit returns `:ok`,
`deactivate_user/2` now calls `Nebu.Matrix.Session.MatrixSessionStore.delete_for_user(user_id)`,
in the correct AFTER-DB-commit sequencing position (alongside `destroy_session/1`).

- I confirmed `set_is_active(_, false)` has **exactly one call site** in the codebase
  (server.ex:3318, inside `deactivate_user/2`). There is no second deactivation entry
  point that could bypass the new delete — the cycle-1 root cause (a sibling entry point)
  cannot recur for deactivation.
- `delete_for_user/1` (matrix_session_store.ex:274) issues
  `DELETE FROM matrix_sessions WHERE user_id = $1` — removing **all** AT+RT rows across
  every device. After this:
  - `get_by_access_token/1` → `:error` → `call_opaque` returns 401 (`M_UNKNOWN_TOKEN`).
  - `get_by_refresh_token/1` → `:error` → `do_refresh_with` returns 401 (`M_UNKNOWN_TOKEN`).
    The `/refresh` handler (http_public.ex:415) resolves the RT purely from the DB row,
    so once the row is gone, refresh cannot mint new tokens. No independent is_active
    check in `/refresh` is needed — row absence is the gate.

### Layer 2 (BACKSTOP) — per-request is_active re-check on the opaque path
`server/lib/nebu/web/plugs/oidc_plug.ex:95` — `call_opaque` now evaluates
`provision(sess.user_id, %{}) == :deactivated` and, if so, returns 401 with
`soft_logout: true`. This uses the **same** `provision/2` + ≤60s-TTL provisioned-user
ETS cache the JWT path (`call_jwt`) already used, giving the two token paths parity.
`provision/2` → `do_provision/2` → `TokenValidator.validate/4`, which returns
`{:error, :deactivated}` when `is_active = false` (token_validator.ex), mapped to the
`:deactivated` atom. A deactivated user is **never** cached (only a successful validate
calls `mark_provisioned/1`), so the deactivated verdict is never masked by a stale cache
entry.

### Residual window analysis (acceptable)
A residual deactivation-lag window of **≤ the provision-cache TTL (60s)** exists *only*
in the conjunction of all of:
1. the Layer-1 row delete is missed (only possible on a transient DB error —
   `delete_for_user/1` is best-effort and log-swallows to `:ok`), AND
2. the user was already in the provisioned cache from a recent good request (a fresh
   cache *miss* re-validates and returns `:deactivated` immediately — zero window).

This is **acceptable and is exactly the JWT path's own behaviour** (the JWT path has the
identical ≤60s window by design, matching the Go gateway `makeStatusChecker` is_active
TTL). The two layers are complementary: Layer 1 makes the common case instantaneous;
Layer 2 caps the worst case at 60s if Layer 1 ever fails. The best-effort (log-swallow)
nature of `delete_for_user/1` does **not** leave the hole open precisely because Layer 2
is the backstop for that case. Confirmed correct design.

### Reactivation
`reactivate_user/2` (server.ex:3366) sets `is_active = true` and intentionally does NOT
destroy sessions — but the deactivated user's opaque rows were already deleted, so
reactivation simply requires a fresh login. No stale-session resurrection. Correct.

## New-issue audit on the cycle-2 changes — CLEAN

- **DoS / hot-path cost:** the `provision/2` re-check is gated by the warm ETS cache; a
  recently-confirmed-good user takes the fast path with no DB round-trip. A brand-new
  opaque token is not in the cache, but that token's first request would provision
  anyway — no *new* cost is introduced on the hot path (`/sync` long-poll included). No
  DoS amplification.
- **Deactivation-check bypass:** none — the re-check reads `user_id` from the
  server-resolved session row (`sess.user_id`), not from any client input.
- **JWT path:** untouched (`call_jwt` unchanged); the same `provision/2` is shared, so no
  divergence.
- **Timing leak:** the deactivated branch returns a constant-shape 401; no secret
  comparison and no data-dependent branching that leaks identity state beyond the
  already-public "this token doesn't work."
- **`upsert_profile` in the opaque path:** only runs inside `do_provision/2` on a cache
  miss (unchanged behaviour); the opaque re-check normally hits the cache fast path and
  never reaches `upsert_profile`. No unexpected write on the hot path.

## Carry-over advisories (unchanged from cycle-1 — advisory only, do NOT block)

- **LOW — no RLS on `matrix_sessions`.** The table has no `ENABLE ROW LEVEL SECURITY`
  policy. Defense-in-depth gap only; all access goes through parameterised queries in
  `MatrixSessionStore` scoped by the server-resolved `user_id`. Recurring project pattern
  ("Missing RLS on new tables"). Advisory.
- **INFO — `cleanup_expired/0` sweeper not wired.** `matrix_session_store.ex:320` exists
  but is not called by any supervised periodic task; expired/revoked rows accumulate until
  a manual call. No security boundary crossed (expiry is enforced at read time by
  `expired?/1` and `revoked_at`/`grace_until` filters). Advisory.

## INFO (new, advisory — out of scope for this HIGH)

- `invalidate_all_admin_sessions/2` (server.ex:1404) — the OIDC-config-change re-auth
  path destroys ETS sessions but does NOT call `delete_for_user/1`, so opaque
  `matrix_sessions` survive an OIDC issuer/client rotation until their 8h `expires_at`.
  This is a re-authentication-on-config-change concern, not a deactivation kill-switch
  concern, so it does not reopen HIGH #1. If an operator expects "rotate OIDC config ⇒
  all sessions die now," this path should also delete opaque rows. Recommend a separate
  small follow-up; not blocking.

## CRITICAL/HIGH remaining: **NONE.** Commit unblocked.
