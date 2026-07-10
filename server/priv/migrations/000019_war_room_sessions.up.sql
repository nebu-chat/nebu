-- enhanced-logging/war-room-mode (AC1, AC2, AC3, AC5, AC10): bounded,
-- self-terminating diagnostic logging sessions.
--
-- war_room_sessions: at most ONE row may be "active" (ended_at IS NULL) at
-- any given time (AC2, strict v1 simplification). See the partial unique
-- index below for the real correctness backstop — the app layer
-- (Nebu.Admin.WarRoomManager.start_session/1) also checks this itself (to
-- return a friendly, human-readable conflict message), but the index is
-- what actually prevents two genuinely concurrent starts from both
-- succeeding.
CREATE TABLE IF NOT EXISTS war_room_sessions (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_by         TEXT NOT NULL,
    reason             TEXT NOT NULL,
    scope              TEXT,
    filter             JSONB,
    max_entries        INT NOT NULL,
    max_duration_s     INT NOT NULL,
    ended_at           TIMESTAMPTZ,
    ended_reason       TEXT,
    entries_collected  INT NOT NULL DEFAULT 0
);

-- AC2: "exactly one active session" as a genuine DB-level invariant, not
-- just an app-level SELECT-then-INSERT race. A partial unique index over a
-- constant expression, scoped to rows where ended_at IS NULL — a second
-- INSERT attempting to create a second active row hits this and fails with
-- a unique-violation, regardless of what the app-level check already did
-- (design-decisions.md #8).
CREATE UNIQUE INDEX IF NOT EXISTS war_room_sessions_single_active_idx
    ON war_room_sessions ((1)) WHERE ended_at IS NULL;

-- AC10 (cross-story coordination fallback): operational-log-store's own
-- migration (000017_operational_logs.up.sql) already added this column
-- (nullable, no FK yet — the FK could not be added there because
-- war_room_sessions did not exist at that point). This IF NOT EXISTS guard
-- is a defensive no-op on the expected case (the column already exists)
-- and a genuine fallback add on any database where it somehow does not
-- (design-decisions.md #2).
ALTER TABLE operational_logs ADD COLUMN IF NOT EXISTS war_room_id UUID;

-- The FK constraint 000017 deliberately deferred is added here, now that
-- war_room_sessions exists. Guarded (checks pg_constraint by name) so
-- re-applying this migration, or applying it to a database that already
-- has the constraint via some other path, is a no-op rather than an error.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'operational_logs_war_room_id_fkey'
    ) THEN
        ALTER TABLE operational_logs
            ADD CONSTRAINT operational_logs_war_room_id_fkey
            FOREIGN KEY (war_room_id) REFERENCES war_room_sessions(id);
    END IF;
END $$;

-- Endpoint-level (scope) matching and the admin monitoring-view's AC12
-- war_room_id filter both look up operational_logs by war_room_id.
CREATE INDEX IF NOT EXISTS operational_logs_war_room_id_idx
    ON operational_logs (war_room_id);
