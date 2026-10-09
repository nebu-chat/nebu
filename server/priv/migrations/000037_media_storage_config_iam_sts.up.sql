-- bugfix-add-sts-iam-endpoints-to-admin-ui (AC1): adds DB-override columns
-- for the two UpCloud Managed Object Storage endpoint URLs
-- (iam_endpoint/sts_endpoint) that bugfix-upcloud-s3-iam-sts-endpoints
-- (commit ac70bc4b) already resolves from NEBU_MINIO_IAM_ENDPOINT/
-- NEBU_MINIO_STS_ENDPOINT, env-only, with no admin-settable DB column. These
-- are nullable, no-default optional TEXT columns — same shape as the
-- existing optional `archive_bucket` column on this table (see
-- 000024_media_storage_config.up.sql). Not secrets, never encrypted at rest
-- (unlike access_key_encrypted/secret_key_encrypted), never masked by
-- Nebu.Media.StorageConfig.mask_map/1.
--
-- code review (cycle 1, MINOR-1): IF NOT EXISTS guards added below — matches
-- the established repo convention for every other column-adding migration
-- (000002, 000004, 000012, 000019, 000021), making a re-run against an
-- instance that somehow already has these columns a no-op instead of an
-- error.
ALTER TABLE media_storage_config
    ADD COLUMN IF NOT EXISTS iam_endpoint TEXT,
    ADD COLUMN IF NOT EXISTS sts_endpoint TEXT;

-- No new GRANT needed: this is an ALTER TABLE on media_storage_config, which
-- 000024_media_storage_config.up.sql already granted
-- `GRANT SELECT, INSERT, UPDATE, DELETE ON media_storage_config TO nebu_app;`
-- for. That table-level grant covers the two new columns automatically — the
-- known pipeline/CI gotcha (a migration with no grant on a NEW table
-- fail-opens in prod while CI stays green) does not apply here, since no new
-- table is created. No RLS policy change needed either: the existing
-- `storage_config_read_all`/`storage_config_insert_only`/
-- `storage_config_update_singleton` policies are table/row-scoped
-- (`id = 1`), not column-scoped.
