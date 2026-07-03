# Fresh code-read grounding (2026-07-01) — line numbers verified against current auth.ex, NOT story file

The story's line-number references (619-636, 244-268) are stale — three prior epic stories
(centralize-claim-resolution, admin-liveview-session-refresh, centralize-scope-resolution) touched
this same file. Current locations verified by direct read:

- `put_current_user/2` — server/lib/nebu/admin/auth.ex:282-315
  Builds: sub, email, admin, matrix_user_id (via `Nebu.Matrix.UserId.from_claims(claims, server_name())`),
  session_exp, refresh_grace_exp (added by admin-liveview-session-refresh HIGH fix).
- `bootstrap_confirm_claim/2` — server/lib/nebu/admin/auth.ex:633-704
  Hand-rolled session map at lines 673-683: sub, email, admin=true, session_exp, refresh_grace_exp.
  **Missing matrix_user_id** — confirmed bug, matches story description exactly.
- `bootstrap_callback/2` — server/lib/nebu/admin/auth.ex:561-589
  Stashes `bootstrap_sub` (raw string), `bootstrap_email` (raw string), and `bootstrap_claims`
  (JSON list of `[dotted_key, value]` pairs via `encode_discovered_claims/1` →
  `Nebu.Web.OidcClaims.flatten_discovered_claims/2`, which recursively flattens nested claim
  objects into dot-paths, e.g. `"realm_access.roles" => "admin"`).

## Why AC2 (full claims survival) is a REAL gap, not just defensive

`Nebu.Matrix.UserId.from_claims/2` (server/lib/nebu/matrix/user_id.ex:17) calls `localpart/1`
which does direct flat-key lookups: `claims[configured_claim]`, `claims["preferred_username"]`,
`claims["name"]`, `claims["sub"]` — on the ORIGINAL (non-flattened) claims map.

The current `bootstrap_claims` stash is a flattened `[[dotted_key, value], ...]` JSON list built
for the claim-SELECTION UI (`select_claim_html/1`), not a claims map suitable for
`UserId.from_claims/2`. Reconstructing a usable claims map from it would be lossy/fragile (dot-path
un-flattening is not a real inverse — e.g. `"a.b"` could mean nested map OR a literal dotted key).

**Correct fix direction (AC2):** stash the raw verified claims map as a SEPARATE JSON blob (e.g.
`bootstrap_full_claims`) in the draft at `bootstrap_callback/2` time (alongside the existing
`bootstrap_sub`/`bootstrap_email`/`bootstrap_claims`, which stay for the claim-selection UI —
AC4 requires those assertions stay green). `bootstrap_confirm_claim/2` then JSON-decodes it back
into a map and calls `put_current_user/2` (or a shared refactor of it) with that map, exactly as
`normal_callback/2` does with its freshly-verified `claims`.

## AC1's "denselben Code-Pfad" — structural note

`put_current_user/2` does two things beyond map-building: `configure_session(renew: true)` +
`put_session` + `assign` (session mechanics — bootstrap_confirm_claim/2 duplicates these too,
lines 685-688) AND the map contents. The fix must route bootstrap through the actual
`put_current_user/2` function call, not just copy its field list again — that is the literal
duplication AC1 prohibits ("nicht über eine zweite, separate Map-Konstruktion").

One structural wrinkle: `put_current_user/2` computes `session_exp` via `session_expiry(claims)`
(auth.ex:335, `min(claims["exp"], now + admin_session_ttl_seconds)`), whereas
`bootstrap_confirm_claim/2` computes `bootstrap_exp` via
`System.system_time(:second) + SessionConfig.admin_session_ttl_seconds()` — no `claims["exp"]`
floor. If the full claims map (including `exp`) is now available, calling the real
`session_expiry/1` (i.e. calling real `put_current_user/2`) will floor the bootstrap session by
`claims["exp"]` same as a normal login. This is a **behavior change survivors must be aware of**:
AC4 says "additive, no behavior change to session_exp" — verify whether flooring by the token's own
`exp` on this ONE bootstrap-completion session actually changes observed session_exp in existing
tests (likely fine — `exp` in test JWTs is typically far in the future — but must be checked, not
assumed).

## Cache-timing check (AC2, "identical to a subsequent normal re-login")

`Nebu.Matrix.OidcClaimCache.get/0` (server/lib/nebu/matrix/oidc_claim_cache.ex) lazily populates a
node-local `persistent_term` on FIRST call and never re-queries on a confirmed value (including
confirmed-`nil`). `complete_bootstrap/2` (auth.ex:1408) writes `oidc_user_id_claim` to
`server_config` and explicitly refreshes `OidcConfig`/`JwksCache` (auth.ex:1449-1462) but does
**NOT** call `Nebu.Matrix.invalidate_oidc_claim_cache/0`.

Verified via grep: `OidcClaimCache.get/0` / `UserId.from_claims/2` are called ONLY from
`put_current_user/2` (auth.ex:294), `OidcPlug` (oidc_plug.ex:124), `http_public.ex:327`, and
`sso_login.ex:263` — none of which run during the bootstrap wizard flow itself (OidcPlug rejects
all Bearer tokens with 401 before bootstrap completes, per ADR-022 "server boots without OIDC
config"). So in practice the cache is untouched (`:unset`) until `put_current_user/2` is first
called post-bootstrap — its lazy first-read will pick up the JUST-WRITTEN `oidc_user_id_claim` row
correctly. **This should be verified by an explicit test** (mint bootstrap session with a
non-default `oidc_user_id_claim` configured in the SAME bootstrap flow, confirm `matrix_user_id`
uses it) rather than assumed — this is exactly the kind of cross-story interaction the epic's
security consultation flagged as a recurring risk class.

## AC3 test-fixture risk (already flagged by story, confirmed real)

server/test/nebu/admin/admin_create_room_test.exs — MUST verify current session fixtures don't
already hand-roll a complete session (with `matrix_user_id` present) that would mask the bug.
Grep the file's `put_session("current_user", ...)` / conn-setup helpers before writing the AC3
regression test — the new test must construct its session via the SAME path
`bootstrap_confirm_claim/2` actually uses (or by calling the real controller action end-to-end),
not a hand-rolled fixture.
