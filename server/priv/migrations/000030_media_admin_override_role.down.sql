-- media-security-admin-control/6c-infected-override: down-migration for
-- 000030_media_admin_override_role.up.sql. No GRANT statements here (AC4,
-- migrations_grant_test.exs) — dropping a column is not a table drop, and
-- rollback grants are moot regardless.
ALTER TABLE users DROP COLUMN media_admin_override;
