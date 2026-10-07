-- Code-review cycle 1 addendum (MAJOR-1, bugfix sync-state-events-missing-fields):
-- backfills ONE authoritative m.room.power_levels event per pre-existing room that
-- has power_levels set but NO backing event row yet.
--
-- Why this is needed: before this bugfix, Nebu.Matrix.Room.Server's
-- handle_call({:set_power_levels, ...}) (server/lib/nebu/matrix/room/server.ex)
-- only ever wrote the denormalised rooms.power_levels_json column — it never
-- called insert_event (unlike :join's emit_membership_event/3). Post-fix, every
-- NEW set_power_levels call emits a real event via emit_power_levels_event/3, but
-- rooms whose power levels were last set BEFORE this fix still have NO
-- m.room.power_levels row in `events` at all. build_state_events/2
-- (event_dispatcher/server.ex) then falls back to {"", 0} for those rooms, and
-- /sync ships event_id: ""/origin_server_ts: 0 (epoch 1970) to clients — exactly
-- the bug class this whole fix exists to close, just scoped to rooms that predate
-- it. This migration closes that gap once, for every such room, in one pass.
--
-- Scope (idempotent, safe to re-run):
--   - every room with a power_levels_json value (including the literal default
--     '{}') and NO existing m.room.power_levels event row (state_key = '') gets
--     one backfilled. Code-review cycle 2 (MAJOR-2): an earlier version of this
--     migration excluded rooms whose power_levels_json was still the trivial
--     '{}' default, reasoning there was "nothing meaningful" to backfill — but
--     '{}' IS that room's real, current power-levels state (not a guessed
--     default), and skipping it left those rooms still shipping the
--     event_id: ""/origin_server_ts: 0 sentinels this whole migration exists to
--     eliminate. Widened to backfill those rooms too;
--   - AND only rooms with NO existing m.room.power_levels event row (state_key =
--     '') — a room that already has one (e.g. create_personal_room/2's own real
--     pl_event write, or any post-fix set_power_levels call) is left completely
--     untouched, never duplicated;
--   - the NOT EXISTS guard is what makes this migration idempotent: re-running it
--     after it already backfilled a room finds that room now HAS a matching
--     event and skips it on the second pass.
--
-- sender: the room's creator — the sender of its earliest persisted
-- m.room.create event, the SAME lookup Nebu.Matrix.Room.DB.get_room_creator/1
-- (server/lib/nebu/matrix/room/db.ex) uses in application code. A room with no
-- m.room.create event at all (extremely old / pre-create-persistence legacy
-- data) gets '' — content/power levels are still backfilled; sender is
-- best-effort, matching get_room_creator/1's own {:error, :not_found} fallback
-- behaviour elsewhere in the codebase.
--
-- origin_server_ts: rooms.created_at — the room's ACTUAL creation time, never
-- "now". AC1's rationale (bug-context.md) against the pre-existing
-- initial_sync_state_event/3 synthetic-timestamp precedent applies here too: a
-- fake "just happened" timestamp would actively mislead every client about when
-- this room's power levels were really set.
--
-- content: rooms.power_levels_json AS-IS — the room's CURRENT power levels (not
-- a guessed/synthesized default), so the backfilled event matches exactly what
-- /sync already reports for this room today via the live GenServer state.
--
-- event_id: this is a pure-SQL data migration — Nebu.Release applies every
-- *.up.sql file as a raw script via Postgrex (server/lib/nebu/release.ex); there
-- is no Elixir runtime available mid-migration to call
-- Nebu.Matrix.EventId.generate/1 directly (architecture rule #7 governs RUNTIME
-- event emission; this is a one-time backfill of historical data for rooms
-- whose real emission moment already passed, uncaptured, under the old code).
-- We reproduce EventId.generate/1's OUTPUT FORMAT — "$" followed by an unpadded
-- URL-safe base64 SHA-256 digest — using PostgreSQL's built-in sha256(bytea)
-- function (core since PG 11, no pgcrypto extension required), hashing a string
-- that is deterministic AND unique per room (room_id is part of the hashed
-- input, and room_id is itself already globally unique), then translating
-- standard base64 to the unpadded URL-safe alphabet
-- Base.url_encode64(_, padding: false) produces elsewhere in this codebase.
-- This is NOT a byte-for-byte reproduction of EventId.generate/1's
-- canonical-JSON content hash — no code path in this codebase calls
-- Nebu.Matrix.EventId.verify/2 against a stored event (grep confirms zero call
-- sites outside event_id.ex's own doctests), so no runtime invariant depends on
-- the id actually covering the signed content. It IS: deterministic (safe to
-- re-run), globally unique, and spec-valid in shape ("$" + 43 URL-safe base64
-- characters — the exact same shape every other event_id in this table has).
--
-- signatures: set to a distinguishing JSONB marker (NOT a real Ed25519
-- signature — this migration cannot access the server's signing key, which only
-- exists in :persistent_term at runtime) so the paired .down.sql can cleanly
-- and exclusively target rows THIS migration inserted, never a real signed
-- event that happens to share the same (room_id, event_type, state_key).
-- Nothing in the application reads/verifies events.signatures against event_id
-- for m.room.* events (grep confirms), so this is safe.
--
-- GRANT: none needed. This migration INSERTs into the EXISTING `events` table
-- only — no new table, no new sequence. Verified (not assumed): nebu_app
-- already has INSERT on `events` via migration 000001_init.up.sql's blanket
-- `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO
-- nebu_app`, which covers `events` (created in that same file) — every normal
-- event write (Nebu.Matrix.Room.DB.insert_event/1) already depends on exactly
-- this grant today. Nebu.Matrix.MigrationsGrantTest's per-migration-GRANT
-- requirement (AC1) is scoped to NEW tables created by post-000001 migrations;
-- this migration creates none (mirrors the 000034_media_config_scan_kill_switch
-- precedent, which likewise needed no GRANT for the same reason).

INSERT INTO events (
    event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key
)
SELECT
    '$' || rtrim(
        translate(
            replace(
                encode(
                    sha256(
                        convert_to(
                            r.room_id || '|m.room.power_levels|' || r.power_levels_json || '|' || r.created_at::text,
                            'UTF8'
                        )
                    ),
                    'base64'
                ),
                E'\n', ''
            ),
            '+/', '-_'
        ),
        '='
    ),
    r.room_id,
    COALESCE(creator.sender, ''),
    'm.room.power_levels',
    r.power_levels_json::jsonb,
    r.created_at,
    '{"nebu_backfill_migration": "000035_backfill_power_levels_events"}'::jsonb,
    ''
FROM rooms r
LEFT JOIN LATERAL (
    SELECT e.sender
    FROM events e
    WHERE e.room_id = r.room_id AND e.event_type = 'm.room.create'
    ORDER BY e.origin_server_ts ASC
    LIMIT 1
) creator ON TRUE
WHERE r.power_levels_json IS NOT NULL
  AND r.power_levels_json <> ''
  AND NOT EXISTS (
      SELECT 1 FROM events ex
      WHERE ex.room_id = r.room_id
        AND ex.event_type = 'm.room.power_levels'
        AND ex.state_key = ''
  );
