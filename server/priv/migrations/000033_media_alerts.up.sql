-- ─── media_alerts ───────────────────────────────────────────────────────────
-- media-security-admin-control/10c-media-alerts-triggers: operational/
-- monitoring alerts for the scan pipeline (ClamAV connectivity, freshclam
-- signature staleness, backlog depth, scan-failure rate). Distinct from
-- media_state_transitions (1a, ADR-031): this table is NOT an append-only
-- compliance ledger — rows are opened and later updated in place
-- (resolved_at) by the periodic Nebu.Workers.MediaAlertsCheckerWorker. No
-- immutability trigger, no RLS insert-only/update-mutable split (Dev Agent
-- Guardrails: do not model this table on audit_log/media_state_transitions).
--
-- alert_type is a TEXT + CHECK list (not an ENUM) deliberately: this list is
-- expected to grow as new operational conditions are added, and a CHECK
-- constraint extension is a single-migration, no-ceremony change, unlike the
-- well-known ALTER TYPE ... ADD VALUE mid-transaction restrictions. severity
-- stays a genuine ENUM since its two-value domain is stable.
CREATE TYPE media_alert_severity AS ENUM ('warning', 'critical');

-- Dev-story note: the story's own illustrative SQL types media_id as UUID,
-- but media_files.media_id (000001_init.up.sql) is TEXT, not UUID —
-- confirmed empirically (a UUID FK to a TEXT primary key fails migration
-- with Postgres error 42804 "incompatible types: uuid and text"). media_id
-- is TEXT here to match the real media_files primary key, same
-- verify-against-a-real-Postgres discipline this epic's own
-- media_scan_stats_rollup_worker.ex moduledoc documents for the story's own
-- illustrative SQL.
CREATE TABLE media_alerts (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_type         TEXT NOT NULL CHECK (alert_type IN (
                            'clamav_disconnected',
                            'signature_stale',
                            'backlog_depth',
                            'scan_failed_rate'
                        )),
    severity           media_alert_severity NOT NULL,
    message            TEXT NOT NULL,
    media_id           TEXT NULL REFERENCES media_files (media_id),
    condition_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    opened_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at        TIMESTAMPTZ NULL
);

-- Belt-and-suspenders for AC5's idempotent check-and-open: at most one OPEN
-- alert per (alert_type, media_id) at a time. COALESCE folds the
-- pipeline-level alerts' NULL media_id to a fixed sentinel so Postgres's
-- "two NULLs are never equal" default unique-index semantics don't silently
-- allow duplicate pipeline-level open rows. The sentinel is a fixed string
-- that can never collide with a real media_id (Story 2a's media_id genesis
-- always generates a non-empty id).
CREATE UNIQUE INDEX media_alerts_open_unique_idx
    ON media_alerts (alert_type, COALESCE(media_id, '__pipeline_level__'))
    WHERE resolved_at IS NULL;

CREATE INDEX media_alerts_open_idx ON media_alerts (severity, opened_at DESC)
    WHERE resolved_at IS NULL;

-- media_alerts rows are opened/updated in place but never removed by app
-- code (Dev Agent Guardrails) — deliberately narrower than the usual
-- 4-verb access other tables' migrations use (SELECT/INSERT/UPDATE only
-- below; the fourth, row-removal verb is intentionally absent).
GRANT SELECT, INSERT, UPDATE ON media_alerts TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE media_alerts_id_seq TO nebu_app;

-- Extend media_config's mutable-key allowlist (ADR-027, Story 9a) with this
-- story's own threshold keys — same incremental-extension precedent 9a's own
-- migration documents for 10c/10d, and the one server_config's
-- 000007/000013/000016/000018 already established.
ALTER POLICY media_config_update_mutable ON media_config
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
        'mime_denylist',
        'clamav_down_alert_minutes',
        'signature_stale_alert_hours',
        'backlog_depth_alert_threshold',
        'scan_failed_rate_alert_pct'
    ));
