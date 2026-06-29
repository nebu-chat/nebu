-- 000010_devices.down.sql
-- Reverses 000010_devices.up.sql.
-- WARNING: dropping `devices` discards device identity for keyless devices (devices that never
-- published keys). Devices that have a device_keys row (000009) are unaffected and would be
-- re-backfilled on the next up-migration.

DROP INDEX IF EXISTS idx_devices_user;
DROP TABLE IF EXISTS devices;
