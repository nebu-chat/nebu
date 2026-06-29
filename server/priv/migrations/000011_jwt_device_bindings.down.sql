-- 000011_jwt_device_bindings.down.sql
-- Reverses 000011_jwt_device_bindings.up.sql.
-- Dropping this table un-binds raw-JWT access tokens from their device (they would then fall back
-- to having no device_id assigned). Opaque sessions are unaffected (their binding is in matrix_sessions).

DROP INDEX IF EXISTS idx_jwt_device_bindings_user;
DROP TABLE IF EXISTS jwt_device_bindings;
