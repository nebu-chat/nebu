-- 000011_account_data.down.sql
-- Reverses 000011_account_data.up.sql.
-- WARNING: dropping this table discards all durable account data — after a down+up
-- cycle, users' secret-storage / recovery material (m.secret_storage.*,
-- m.cross_signing.*) is gone until clients re-PUT it, and /sync delivers no
-- account_data.events until then.

DROP TABLE IF EXISTS account_data;
