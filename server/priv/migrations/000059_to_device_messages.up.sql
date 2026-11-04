-- 000059_to_device_messages.up.sql
-- Story to-device-messaging (epic e2ee-client-support, REQ-2026-012): Matrix CS v1.18 "Send-to-Device messaging" (PUT /sendToDevice/{eventType}/{txnId},
-- `to_device.events` of /sync). Transport only: the server queues OPAQUE event content per (user, device) until the device acknowledges it with the
-- `since` token of its next /sync, and never decrypts, interprets or logs it (ADR-011 stays: this enables no E2EE room). No federation.
--
-- to_device_messages: the queue. `stream_pos` orders the messages of a device (arrival order). `delivery_seq` is NULL until a /sync response carries the
--   message; the response that first carries it stamps it with the next value of `to_device_delivery_seq`, and that value is the to-device position of the
--   response token. The message is deleted only when a later /sync presents a token whose position covers its `delivery_seq` (a retry with an older token
--   delivers it again). `bytes` is the canonical content size (the budgets count it plus 128 bytes of row overhead). `sender` is the authenticated user id.
-- to_device_txns: the idempotency record of (user, device, event type, txn id): persisted, so a retry after a restart or on another node is not queued again.
--
-- Both tables are per-user data: `user_id TEXT NOT NULL` (the GDPR erasure deletes `WHERE user_id = $1`; messages SENT by an erased user are deleted by
-- `sender`), and `device_id` (a device delete / logout / revoke deletes the rows of that device through `DeviceKeyStore.delete_device`).
-- UpCloud managed PostgreSQL has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role gets its grants here. Row level security is
-- ENABLEd and FORCEd with a policy for each command. Only new tables: no existing table is touched (rolling-deploy safe).

CREATE SEQUENCE IF NOT EXISTS to_device_delivery_seq;

CREATE TABLE IF NOT EXISTS to_device_messages (
    stream_pos   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      TEXT        NOT NULL,
    device_id    TEXT        NOT NULL,
    sender       TEXT        NOT NULL,
    event_type   TEXT        NOT NULL,
    content      TEXT        NOT NULL,
    bytes        INTEGER     NOT NULL,
    delivery_seq BIGINT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS to_device_messages_device_idx ON to_device_messages (user_id, device_id, stream_pos);
CREATE INDEX IF NOT EXISTS to_device_messages_sender_idx ON to_device_messages (sender, user_id, device_id);
CREATE INDEX IF NOT EXISTS to_device_messages_created_idx ON to_device_messages (created_at);

CREATE TABLE IF NOT EXISTS to_device_txns (
    user_id    TEXT        NOT NULL,
    device_id  TEXT        NOT NULL,
    event_type TEXT        NOT NULL,
    txn_id     TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, device_id, event_type, txn_id)
);

CREATE INDEX IF NOT EXISTS to_device_txns_created_idx ON to_device_txns (created_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON to_device_messages TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON to_device_txns TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE to_device_delivery_seq TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE to_device_messages_stream_pos_seq TO nebu_app;

ALTER TABLE to_device_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE to_device_messages FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS to_device_messages_select ON to_device_messages;
CREATE POLICY to_device_messages_select ON to_device_messages FOR SELECT USING (true);
DROP POLICY IF EXISTS to_device_messages_insert ON to_device_messages;
CREATE POLICY to_device_messages_insert ON to_device_messages FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS to_device_messages_update ON to_device_messages;
CREATE POLICY to_device_messages_update ON to_device_messages FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS to_device_messages_delete ON to_device_messages;
CREATE POLICY to_device_messages_delete ON to_device_messages FOR DELETE USING (true);

ALTER TABLE to_device_txns ENABLE ROW LEVEL SECURITY;
ALTER TABLE to_device_txns FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS to_device_txns_select ON to_device_txns;
CREATE POLICY to_device_txns_select ON to_device_txns FOR SELECT USING (true);
DROP POLICY IF EXISTS to_device_txns_insert ON to_device_txns;
CREATE POLICY to_device_txns_insert ON to_device_txns FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS to_device_txns_update ON to_device_txns;
CREATE POLICY to_device_txns_update ON to_device_txns FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS to_device_txns_delete ON to_device_txns;
CREATE POLICY to_device_txns_delete ON to_device_txns FOR DELETE USING (true);
