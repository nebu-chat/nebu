-- Reverses 000064_grant_missing_table_privileges.up.sql.
--
-- Intentional no-op: the up migration only adds privileges and owns no object.
-- The tables belong to 000014/000015/000017/000019/000020, whose down migrations
-- drop them (which discards their privileges). An explicit revoke here would
-- reintroduce the permission-denied bug after a code-only rollback.
SELECT 1;
