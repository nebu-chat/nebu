-- 000058_room_key_backup.down.sql
-- Reverses 000058_room_key_backup.up.sql.
-- WARNING: dropping these tables DISCARDS every user's server-side key backup (all versions and all stored sessions). After a down + up
-- cycle clients find "no backup" (404 on GET /room_keys/version) and must create a new backup from their own device keys; chat history that
-- was only recoverable from the backup stays unreadable for devices that no longer hold the keys.

DROP TABLE IF EXISTS room_key_backup_sessions;
DROP TABLE IF EXISTS room_key_backup_versions;
