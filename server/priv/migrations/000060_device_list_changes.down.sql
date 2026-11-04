-- 000060_device_list_changes.down.sql
-- Reverses 000060_device_list_changes.up.sql: the membership trigger first, then the stamp trigger, both functions and the table.
-- WARNING: dropping the table DISCARDS the device-list change stream. After a down + up cycle a client that presents a token with a device-list
-- position finds no history: /keys/changes and /sync answer conservatively (every user the caller shares a joined room with is "changed" once).
-- Story device-key-directory (the reader of the stream) must be reverted first.

DROP TRIGGER IF EXISTS device_list_changes_member_trigger ON room_members;
DROP TRIGGER IF EXISTS device_list_changes_stamp_trigger ON device_list_changes;
DROP FUNCTION IF EXISTS device_list_changes_member();
DROP FUNCTION IF EXISTS device_list_changes_stamp();
DROP TABLE IF EXISTS device_list_changes;
ALTER TABLE device_fallback_keys DROP COLUMN IF EXISTS key_id;
