-- 000009_device_keys.down.sql
-- Reverses 000009_device_keys.up.sql.
-- WARNING: dropping these tables discards the device-key directory — after a down+up cycle,
-- clients must re-publish their device/one-time/fallback keys (clients do this automatically
-- on next /keys/upload), and peers' /keys/query results are empty until then.

DROP INDEX IF EXISTS idx_device_otk_unclaimed;
DROP INDEX IF EXISTS idx_device_keys_user;
DROP TABLE IF EXISTS device_fallback_keys;
DROP TABLE IF EXISTS device_one_time_keys;
DROP TABLE IF EXISTS device_keys;
