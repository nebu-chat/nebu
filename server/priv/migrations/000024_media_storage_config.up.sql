-- ─── media_storage_config ────────────────────────────────────────────────
-- Singleton-row S3/MinIO storage target configuration (Story 11a). NOT an
-- extension of media_config (ADR-027/Story 9a) — see the story's Summary for
-- why this is a distinct table: one cohesive object vs. a fan-out of scalar
-- policy keys, and a distinct (rare, security-sensitive) cache-invalidation
-- domain that must not couple to media_config's hot-path invalidation group.
--
-- Migration number: 000023 was already claimed on disk by Story 9a's
-- media_config migration at ATDD time for this story, so this migration is
-- 000024 (not the story's originally-drafted 000025) — per the epic's
-- "whichever lands first keeps its number" migration convention.
CREATE TABLE media_storage_config (
    id                     SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    endpoint               TEXT,
    bucket                 TEXT,
    region                 TEXT,
    use_ssl                BOOLEAN,
    -- access_key_encrypted/secret_key_encrypted hold Nebu.Web.SecretBox
    -- ciphertext blobs (hex(nonce ‖ AES-256-GCM ciphertext ‖ tag)) — NEVER
    -- plaintext. See Nebu.Media.StorageConfig for the only read/write path.
    access_key_encrypted   TEXT,
    secret_key_encrypted   TEXT,
    s3_key_prefix_template TEXT,
    archive_bucket         TEXT,
    set_at                 BIGINT NOT NULL
);

ALTER TABLE media_storage_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_storage_config FORCE ROW LEVEL SECURITY;

CREATE POLICY storage_config_read_all ON media_storage_config FOR SELECT USING (true);
CREATE POLICY storage_config_insert_only ON media_storage_config FOR INSERT WITH CHECK (id = 1);
CREATE POLICY storage_config_update_singleton ON media_storage_config FOR UPDATE USING (id = 1);

-- REQUIRED (pre-dev test-review, cycle 1 — same F-1/HIGH class of gap
-- Kassandra found in 9a's original media_config migration, see
-- Nebu.Matrix.MigrationsGrantTest's moduledoc): in production (UpCloud
-- managed PostgreSQL) `nebu_migrate` owns tables and `nebu_app` is the
-- runtime role; there is no ALTER DEFAULT PRIVILEGES there (that only
-- exists in the dev docker-compose setup, which is why omitting this GRANT
-- would stay green in CI/dev while failing closed in production — every
-- get/0 load and upsert/1 write would hit "permission denied"). No
-- auto-incrementing columns here, so no companion sequence GRANT is needed.
GRANT SELECT, INSERT, UPDATE, DELETE ON media_storage_config TO nebu_app;
