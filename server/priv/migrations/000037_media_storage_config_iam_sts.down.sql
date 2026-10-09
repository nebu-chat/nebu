-- media_storage_config_iam_sts down-migration: drop both columns added by
-- the companion .up.sql. Dropping a column drops any data in it; no other
-- object (index/constraint/RLS policy) references either column.
--
-- code review (cycle 1, MINOR-1): IF EXISTS guards added below — matches the
-- established repo convention for every other column-dropping down-migration
-- (000002, 000004, 000012, 000019, 000021).
ALTER TABLE media_storage_config
    DROP COLUMN IF EXISTS iam_endpoint,
    DROP COLUMN IF EXISTS sts_endpoint;
