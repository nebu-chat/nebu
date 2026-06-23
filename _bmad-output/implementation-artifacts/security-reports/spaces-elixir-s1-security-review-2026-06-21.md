# Security Review (SEC Gate 1) — spaces-elixir-s1-foundation — 2026-06-21
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL/HIGH/MEDIUM. Cleared.

createRoom now merges client creation_content into m.room.create; new rooms.room_type column (mig 000004); proto CreateRoomRequest +room_type/+creation_content_json.

## Verified
- Server-field override DEFEATED: Map.merge(client, server) → server wins (creator/room_version); creator also session-derived (OidcPlug current_user, never params) — 2 layers. Merge scoped to content only (sender/type/state_key built separately). content.type carries no privilege (Matrix auth keys on power levels).
- Injection/DoS: room_type bound $2; non-object creation_content → ignored not crashed; Jason.decode fail → %{}; 1MB body cap bounds content.
- Migration 000004: ADD COLUMN IF NOT EXISTS (idempotent, nullable, no rewrite/lock, reversible down); rooms has no RLS so no policy interaction.

## LOW (advisory)
- L-1: no per-event 64KiB cap (pre-existing 1MB body ceiling governs all sends; out of scope).
- L-2: content.predecessor client-settable but inert (no room-upgrade feature); watch when added.

## Forward warning (S2-S5)
m.space.child/parent + generic state PUT will let clients write arbitrary state content — re-verify no server-authoritative key (sender/power levels/membership) is client-overridable.
