# Security Review (SEC Gate 1) — spaces-elixir-s4-restricted-join — 2026-06-21
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL/HIGH/MEDIUM, 1 LOW. (opus code-review APPROVED.)

MSC3083 restricted join enforcement — the gate the S2/S3 forward-warnings pointed to.

## Verified (S2→S4 chain discharged)
- Default-deny: non-member + no-invite on restricted → 403 M_FORBIDDEN.
- allow[] validation: every malformed shape (wrong type, non-string/empty/missing room_id, non-map entries, allow as map/string, dupes) filtered to []; membership check real (MapSet.member?).
- No self-grant: writing join_rules still requires the unchanged S2 PUT gate (member + PL≥state_default); user can't grant access to a room they don't moderate.
- No info leak (AC6): boolean resolver — non-existent vs existing-not-member allow-room deny identically; generic message; try/catch on dead room → no crash/timing oracle.
- Public/invite/default unchanged (gate no-op for non-restricted) — existing join tests green.

## L-1 (LOW, advisory)
Gate is fail-DEGRADED not fail-secure: get_generic_state_events error → [] → default invite → :ok. NOT exploitable today: (a) m.room.join_rules IS returned by that read normally (not excluded), so real restricted rooms enforce; (b) the error branch only fires on real SQL/connection failure, where the following Room.Server.join membership write hits the same Repo and also fails → no durable join; (c) attacker has no input that selectively fails only the read. Revisit if join membership is ever decoupled from this Repo (e.g. read replica for state).
