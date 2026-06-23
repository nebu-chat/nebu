-- 000006_auto_join_opt_outs.down.sql
-- Reverses 000006_auto_join_opt_outs.up.sql.
-- WARNING: dropping this table discards all recorded auto-join opt-outs — after a
-- down+up cycle, previously-left auto-join rooms will be re-joined on next login.

DROP INDEX IF EXISTS idx_auto_join_opt_outs_user;
DROP TABLE IF EXISTS auto_join_opt_outs;
