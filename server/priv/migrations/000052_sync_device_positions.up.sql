-- 000052_sync_device_positions.up.sql
-- Story sync-token-per-device (epic oauth-broker, follow-up `fd`), D9: the global account data and the own cross-signing change are
-- delivered per DEVICE by two positions stored in the device's sync_tokens row instead of the per-user consume-once flags.
--
--   sync_global_pos_seq             ONE sequence for both sources; every write that sets a flag also stamps a position from it
--   account_data.stream_pos         position of the latest insert OR update of the row (AccountDataStore.put/3 draws it in both
--                                   upsert branches; the existing rows are stamped by the volatile default of this ALTER)
--   cross_signing_keys.changed_pos  position of the latest CrossSigningKeyStore.put_keys/2 (exactly where cross_signing_changed is set)
--   sync_tokens.account_data_pos    the highest account_data.stream_pos this device has been sent
--   sync_tokens.cross_signing_pos   the highest changed_pos this device has been sent (a SEPARATE column: the two sources are read at
--                                   different moments, so one shared column could jump over an account data row committed in between)
--
-- Both writers take pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0)) first, so for one user the position order of
-- each table is its commit order. The flags stay: device-less requests (an unbound raw IdP JWT) still use them. Existing sync_tokens rows
-- start at 0 (every device-bound client falls back to one initial sync after the update anyway, D3). Transaction-safe (no CONCURRENTLY).
--
-- Cost and deploy (see the release note in docs/architecture/07-deployment.md): the VOLATILE default nextval(...) of
-- account_data.stream_pos forces a full REWRITE of account_data (content up to 1 MB per row, TOAST included) under an ACCESS
-- EXCLUSIVE lock, and the index is built in the same transaction (not concurrently): every global account data read and write
-- waits until the migration commits. The three other columns have a constant default (catalog-only). An OLD node does not crash
-- on the new columns, but it is NOT a correct writer: its overwrite of an account_data row keeps the old stream_pos and its
-- put_keys does not stamp changed_pos (and takes no lock), so such a write reaches device-bound clients only with the type's next
-- change or their next initial sync. Deploy without a mixed-version window (or accept that).

CREATE SEQUENCE IF NOT EXISTS sync_global_pos_seq;

ALTER TABLE account_data       ADD COLUMN IF NOT EXISTS stream_pos        BIGINT NOT NULL DEFAULT nextval('sync_global_pos_seq');
ALTER TABLE cross_signing_keys ADD COLUMN IF NOT EXISTS changed_pos       BIGINT NOT NULL DEFAULT 0;
ALTER TABLE sync_tokens        ADD COLUMN IF NOT EXISTS account_data_pos  BIGINT NOT NULL DEFAULT 0;
ALTER TABLE sync_tokens        ADD COLUMN IF NOT EXISTS cross_signing_pos BIGINT NOT NULL DEFAULT 0;

-- list_since/2 and pending_since?/2: the rows of ONE user above a position
CREATE INDEX IF NOT EXISTS account_data_user_pos_idx ON account_data (user_id, stream_pos);

-- the runtime role draws the positions (nextval in the writers' SQL and in the stream_pos default)
GRANT USAGE, SELECT ON SEQUENCE sync_global_pos_seq TO nebu_app;
