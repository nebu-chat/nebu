-- 000012_device_management_uia.down.sql
-- Reverse of 000012 (story s3-matrix-device-endpoints).

DROP INDEX IF EXISTS idx_uia_sessions_expires_at;
DROP TABLE IF EXISTS uia_sessions;

DROP INDEX IF EXISTS idx_jwt_device_bindings_user_device;
ALTER TABLE jwt_device_bindings DROP COLUMN IF EXISTS exp;

ALTER TABLE matrix_sessions DROP COLUMN IF EXISTS auth_time;
