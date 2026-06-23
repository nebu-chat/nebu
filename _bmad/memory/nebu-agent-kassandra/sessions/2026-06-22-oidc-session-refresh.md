# Session 2026-06-22 — SEC Gate 1: oidc-session-refresh (Elixir port)

**Verdict: HIGH (BLOCKED).** 1 HIGH, 1 LOW, 1 INFO.

## HIGH — admin DeactivateUser does not invalidate opaque matrix_sessions
- `deactivate_user/2` (server.ex:3321) calls `destroy_session/1` directly (legacy
  sessions/sync_tokens only). The MINOR-2 fix wired `delete_for_user` ONLY into
  `invalidate_user_sessions/2` (server.ex:1377), which `deactivate_user` does NOT call.
- `call_opaque` (oidc_plug.ex:69-98) has NO per-request is_active re-check (unlike
  `call_jwt`'s `provision/2` with 60s TTL deactivation re-check). Opaque path trusts
  the row's existence + revoked_at + expires_at only.
- Net: an admin-deactivated user keeps a working opaque Matrix session up to 8h.
  JWT user would be locked out in ≤60s. Deactivation = the kill switch; it fails for opaque.
- Fix: route `deactivate_user` through `invalidate_user_sessions` OR add
  `MatrixSessionStore.delete_for_user/1` to `deactivate_user`; defense-in-depth: add
  is_active re-check to `call_opaque`. Add regression test (deactivate → opaque AT → 401).
- NOTE: this is an Elixir-port-specific regression. The Go reference routed deactivation
  through the same InvalidateUserSessions that deleted matrix_sessions (per 2026-05-27 report).
  The port split the two paths and only patched one.

## Everything else CLEAN (8 probes all confirmed)
- Opaque token: 32B CSPRNG → 64 hex, no dot, never logged. ✓
- SecretBox AES-256-GCM: SHA-256(internal_secret) key, fail-closed on "" (raises),
  random 12B nonce/call, tag verified, fail-closed decrypt. OIDC RT never logged/returned. ✓
- Rotation atomic: single txn, UPDATE WHERE revoked_at IS NULL + num_rows:0 rollback;
  row-lock serializes concurrent refresh → no double-mint. Old RT in grace is resolvable
  but cannot rotate again (revoked_at not null) → no replay-to-new-session. ✓
- soft_logout: expired opaque AT → 401 + soft_logout:true; min(oidc_exp, now+8h) enforced. ✓
- /refresh: unauth by spec, but rate-limited (30/min burst 10) + 1MB body cap (JsonBody global).
  Same 401 M_UNKNOWN_TOKEN for all RT-failure modes → no existence oracle. ✓
- Opaque vs JWT dispatch by "." sound: attacker cannot create a matrix_sessions row;
  any "."-token → full JWT verify (alg allowlist intact). JWT path byte-identical. ✓
- SQL: all $N parameterized; select_sql/1 #{where} is hardcoded literals only. ✓

## LOW — matrix_sessions has no RLS (carryover from Go #1, recurring pattern). Advisory.
## INFO — soft-revoked sibling rows leak until logout (cleanup_expired not wired to sweeper).

## Pattern recorded → MEMORY.md
"Port split an invalidation fan-out; only one branch patched" — when a Go single
choke-point (InvalidateUserSessions deleting matrix_sessions) is ported, ALL Elixir
callers of the original choke-point must be enumerated. deactivate_user bypassed it.
