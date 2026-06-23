# Security Review (SEC Gate 1) — bugfix-fix-room-view-endpoints — 2026-06-20
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL/HIGH/MEDIUM, 1 LOW (carry-over). Cleared.

Routes: GET /rooms/{id}/members (→get_room_state), GET /rooms/{id}/event/{eventId} (→get_event), POST /rooms/{id}/read_markers (200 {} no-op).

## Verified
- IDOR closed: acting user from token only (stream→trusted_identity); /event's req.user_id overwritten by trusted_identity (dead field); stream/1 system_role always "user" → system-bypass at server.ex:1085 unreachable from HTTP; x-user-id never copied from client headers.
- Cross-room exfiltration closed: both membership-gated (403 non-member); fetch_event room-scoped SQL (WHERE event_id=$1 AND room_id=$2, parameterised, explicit columns) → cross-room id → 404, no oracle.
- read_markers inert (no parse/mutation/reflection, authed).
- Info disclosure clean: whitelisted serialisers (type/state_key/content/sender/room_id/event_id/ts); synth event_id non-dereferenceable, carries no secret.
- Error envelopes: map_grpc_error discards inspect(reason); no 500/stack leak.
- AC4 relations-403: test-timing (join is synchronous GenServer.call populating members; get_relations checks same set) — no code change, regression test added.

## Non-blocking
F-1 LOW: no rate limit on these routes at core:4000 (matrix-api-migration F-3 family); inert behind OidcPlug.

Tests: 6 unit passed, 8 integration excluded (need live stack; pass against compose 14/14).
