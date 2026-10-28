-- 000052_sync_device_positions.down.sql
-- Reverses 000052_sync_device_positions.up.sql (story sync-token-per-device). The index and the four columns first, the sequence last
-- (the stream_pos default depends on it). The consume-once flags and every other column are untouched: no data except the positions is lost.

DROP INDEX IF EXISTS account_data_user_pos_idx;

ALTER TABLE sync_tokens        DROP COLUMN IF EXISTS cross_signing_pos;
ALTER TABLE sync_tokens        DROP COLUMN IF EXISTS account_data_pos;
ALTER TABLE cross_signing_keys DROP COLUMN IF EXISTS changed_pos;
ALTER TABLE account_data       DROP COLUMN IF EXISTS stream_pos;

DROP SEQUENCE IF EXISTS sync_global_pos_seq;
