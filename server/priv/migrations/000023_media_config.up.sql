-- ─── media_config ─────────────────────────────────────────────────────────
-- Key-value store for runtime-configurable media policy values (ADR-027).
-- Dedicated table, NOT an extension of server_config — see ADR-027's
-- rationale: media_config writes must never trigger server_config's
-- (OIDC/SSO/logging) cache-invalidation path, and vice versa.
--
-- Migration number: story 9a-media-config-table-module claims 000023 (the
-- next free slot at ATDD time — no other story had claimed 000023/000024 on
-- disk yet; per the epic's "whichever lands first keeps its number" migration
-- convention already used across 4a/4b, this may be renumbered at merge time
-- if another story's migration lands first).
CREATE TABLE media_config (
    key    TEXT   PRIMARY KEY,
    value  TEXT   NOT NULL,
    set_at BIGINT NOT NULL
);

ALTER TABLE media_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_config FORCE ROW LEVEL SECURITY;

CREATE POLICY media_config_read_all ON media_config FOR SELECT USING (true);
CREATE POLICY media_config_insert_only ON media_config FOR INSERT WITH CHECK (true);

-- Mutable-keys allowlist (Story 9a's initial catalog, see AC2). New keys
-- introduced by later stories (10c thresholds, 10d fail-open/fail-closed
-- mode, etc.) extend this policy via their own migration, same precedent
-- as server_config's 000007/000013/000016/000018.
CREATE POLICY media_config_update_mutable ON media_config
    FOR UPDATE
    USING (key IN (
        'max_upload_size_bytes',
        'max_file_size_bytes',
        'max_pending_per_user',
        'max_stall_ms',
        'deleted_days',
        'infected_days',
        'orphaned_hours',
        'webhook_url',
        'released_delete_after_days',
        'mime_denylist'
    ));

-- Security review (Kassandra, 2026-07-13, F-1 — HIGH): in production
-- (UpCloud managed PostgreSQL) `nebu_migrate` owns tables and `nebu_app` is
-- the runtime role; there is no `ALTER DEFAULT PRIVILEGES` there (that only
-- exists in the dev docker-compose setup, which is why this omission stayed
-- green in CI/dev). Without this GRANT, nebu_app has ZERO privilege on
-- media_config in production: get/0's loader hits `permission denied`,
-- silently falls back to compile-time defaults (fail-open on a
-- security-relevant cache — mime_denylist, upload/scan size limits), and
-- every upsert/3 call errors. Every post-squash migration (000002+) that
-- creates a table MUST include this GRANT — see
-- Nebu.Matrix.MigrationsGrantTest for the regression guard. This table has
-- no auto-incrementing integer columns, so no companion GRANT on a sequence
-- object is needed.
GRANT SELECT, INSERT, UPDATE, DELETE ON media_config TO nebu_app;
