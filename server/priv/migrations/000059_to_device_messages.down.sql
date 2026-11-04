-- 000059_to_device_messages.down.sql
-- Reverses 000059_to_device_messages.up.sql.
-- WARNING: dropping these tables DISCARDS every queued, not yet acknowledged to-device message and every idempotency record. Clients lose pending
-- verification requests and key requests (they retry); nothing else is stored in them.

DROP TABLE IF EXISTS to_device_txns;
DROP TABLE IF EXISTS to_device_messages;
DROP SEQUENCE IF EXISTS to_device_delivery_seq;
