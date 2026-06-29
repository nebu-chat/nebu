# Kassandra SEC Gate 1 — forget-room-membership-purge (2026-06-28)

VERDICT: CLEAN. No CRITICAL/HIGH. Nothing blocks the commit.

## Declared scope — verified
- SQL injection: CLEAN. All 3 new queries (db.ex insert/get/remove forgotten) are
  parameter-bound ($1/$2) via Ecto.Adapters.SQL.query/3. No interpolation.
- Per-user authorization: CLEAN. user_id is sourced solely from conn.assigns[:current_user]
  (JWT sub via OidcPlug) in the forget route (protected.ex:870-880); never from the body.
  forget_room/2, join_room/2, get_initial_sync, do_incremental_sync all use request.user_id.
- No IDOR / no new oracle: CLEAN. not_found ordering unchanged from the prior stub; the
  diff only changes behavior AFTER the join-guard. A forget writes only (caller, room).

## Probes
1. Forge another user's forget via body/path/header? No — user_id is JWT-only.
2. get_forgotten_room_ids cross-user leak? No — strictly WHERE user_id = $1 (AC5 proves).
3. not_found oracle? Not new — identical ordering to the pre-existing stub.
4. function_exported?/Process.whereis abuse? No. Write (insert_forgotten_room) is unguarded
   and raises `unavailable` on DB failure (fails loud); guarded read fail-opens to empty set
   (self-healing privacy degradation, not an authz violation).
5. CASCADE/GDPR: sound. forgotten_rooms.user_id ON DELETE CASCADE (000001) — erasure removes rows.

## Auth/crypto/transport sweep
OidcPlug is first in the Protected pipeline; no new route bypasses auth. No new secret-compare,
redirect, crypto, logging, header, or path-traversal surface. Tests use real JWT flows, no
cookie forging / DB seeding, all 7 ACs covered incl. isolation + re-join-clear.

## RLS note
Missing RLS on forgotten_rooms is PRE-EXISTING (table is in 000001, no migration in this diff)
and family-wide (matrix_sessions/device_keys/devices). Not a regression here; standing LOW
watch-item, not raised as a finding for this story.
