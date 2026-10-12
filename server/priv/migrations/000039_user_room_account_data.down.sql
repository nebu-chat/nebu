-- Reverses 000039_user_room_account_data.up.sql.
-- WARNING: discards all room-scoped account data (m.marked_unread, m.fully_read, ...).
DROP TABLE IF EXISTS user_room_account_data;
DROP SEQUENCE IF EXISTS user_room_account_data_pos_seq;
