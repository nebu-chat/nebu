-- 000060_device_list_changes.up.sql
-- Story device-key-directory (epic e2ee-client-support, REQ-2026-013): the device-list change STREAM behind `GET /keys/changes` and the `device_lists`
-- of /sync (Matrix CS v1.18 "Tracking the device list of a user"). Directory metadata only: no key material is stored here (ADR-011 stays: this enables
-- no E2EE room). No federation.
--
-- device_list_changes holds the LATEST change per (user_id, room_id), so it is bounded by users and memberships (an upsert, no log):
--   kind 'keys'  (room_id ''): the user's device identity keys, device list or cross-signing keys changed (written by the application),
--   kind 'join' / 'leave' (room_id = the room): the user joined / left the room (written by the trigger on room_members below, so every writer is covered).
-- `pos` is the stream position, drawn from the existing sequence sync_global_pos_seq AT COMMIT: the writers insert / update the row with pos NULL and the
-- DEFERRABLE INITIALLY DEFERRED constraint trigger assigns the position at the end of the transaction under ONE global advisory lock that is held until the
-- commit has finished. A transaction becomes visible before it releases its locks, so the visible positions are a gap-tolerant prefix: a reader that has seen
-- position M never later sees a row at or below M (a transaction that wrote early and commits late is never skipped). A reader that needs "now" takes the same
-- lock for an instant (see Nebu.Matrix.DeviceListStore.position/0).
--
-- user_id is the DELETE key of the GDPR erasure (erased_tables/0). room_id has no foreign key (a row may outlive its room; the reader joins room_members).
-- UpCloud managed PostgreSQL has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role gets its grants here. Row level security is ENABLEd and
-- FORCEd with a policy for each command.
--
-- OPERATOR NOTE: CREATE TRIGGER on room_members takes a brief SHARE ROW EXCLUSIVE lock on it (writers wait for an instant); run it when no long transaction
-- is open on room_members. The trigger function runs with the rights of the writing role (SECURITY INVOKER); nebu_app has INSERT / UPDATE on the new table.
-- Only a new table, one trigger and one nullable column: rolling-deploy safe (an old node writes room_members and the trigger stamps it; old nodes never read the
-- stream and ignore the column).
--
-- device_fallback_keys.key_id (nullable): the id part of the uploaded fallback key "<algorithm>:<key_id>" (the table kept only the algorithm). POST /keys/claim
-- returns the fallback key under its own id, so the id must be stored. A row stored before this migration has NULL; the claim names it "<algorithm>:fallback".
ALTER TABLE device_fallback_keys ADD COLUMN IF NOT EXISTS key_id TEXT;

CREATE TABLE IF NOT EXISTS device_list_changes (
    user_id    TEXT        NOT NULL,
    room_id    TEXT        NOT NULL DEFAULT '',
    kind       TEXT        NOT NULL CHECK (kind IN ('keys', 'join', 'leave')),
    pos        BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, room_id)
);

CREATE INDEX IF NOT EXISTS device_list_changes_pos_idx ON device_list_changes (pos);
CREATE INDEX IF NOT EXISTS device_list_changes_room_idx ON device_list_changes (room_id, pos);

GRANT SELECT, INSERT, UPDATE, DELETE ON device_list_changes TO nebu_app;

ALTER TABLE device_list_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_list_changes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS device_list_changes_select ON device_list_changes;
CREATE POLICY device_list_changes_select ON device_list_changes FOR SELECT USING (true);
DROP POLICY IF EXISTS device_list_changes_insert ON device_list_changes;
CREATE POLICY device_list_changes_insert ON device_list_changes FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS device_list_changes_update ON device_list_changes;
CREATE POLICY device_list_changes_update ON device_list_changes FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS device_list_changes_delete ON device_list_changes;
CREATE POLICY device_list_changes_delete ON device_list_changes FOR DELETE USING (true);

-- the commit-time stamp: assigns the position of every row this transaction left with pos NULL.
-- A cross-signing key write (CrossSigningKeyStore.put_keys/2) leaves cross_signing_keys.changed_pos at the PENDING marker -1 and stamps the (user, '') 'keys' row:
-- the position drawn here is ALSO the changed_pos of that row, so one key change draws ONE position (the commit order of the stream is the order of changed_pos too).
CREATE OR REPLACE FUNCTION device_list_changes_stamp() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    stamped BIGINT;
BEGIN
    PERFORM pg_advisory_xact_lock(4760, 60);
    UPDATE device_list_changes SET pos = nextval('sync_global_pos_seq')
     WHERE user_id = NEW.user_id AND room_id = NEW.room_id AND pos IS NULL
    RETURNING pos INTO stamped;
    IF stamped IS NOT NULL AND NEW.room_id = '' THEN
        UPDATE cross_signing_keys SET changed_pos = stamped WHERE user_id = NEW.user_id AND changed_pos = -1;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS device_list_changes_stamp_trigger ON device_list_changes;
CREATE CONSTRAINT TRIGGER device_list_changes_stamp_trigger
    AFTER INSERT OR UPDATE ON device_list_changes
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (NEW.pos IS NULL)
    EXECUTE FUNCTION device_list_changes_stamp();

-- membership: a join (a new row, or a rejoin that clears left_at) and a leave (left_at set) of room_members stamp (user, room)
CREATE OR REPLACE FUNCTION device_list_changes_member() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.left_at IS NULL THEN
            INSERT INTO device_list_changes (user_id, room_id, kind, pos) VALUES (NEW.user_id, NEW.room_id, 'join', NULL)
            ON CONFLICT (user_id, room_id) DO UPDATE SET kind = 'join', pos = NULL;
        END IF;
    ELSIF OLD.left_at IS NULL AND NEW.left_at IS NOT NULL THEN
        INSERT INTO device_list_changes (user_id, room_id, kind, pos) VALUES (NEW.user_id, NEW.room_id, 'leave', NULL)
        ON CONFLICT (user_id, room_id) DO UPDATE SET kind = 'leave', pos = NULL;
    ELSIF OLD.left_at IS NOT NULL AND NEW.left_at IS NULL THEN
        INSERT INTO device_list_changes (user_id, room_id, kind, pos) VALUES (NEW.user_id, NEW.room_id, 'join', NULL)
        ON CONFLICT (user_id, room_id) DO UPDATE SET kind = 'join', pos = NULL;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS device_list_changes_member_trigger ON room_members;
CREATE TRIGGER device_list_changes_member_trigger
    AFTER INSERT OR UPDATE OF left_at ON room_members
    FOR EACH ROW
    EXECUTE FUNCTION device_list_changes_member();
