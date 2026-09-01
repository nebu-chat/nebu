-- media-security-admin-control/10a-scan-stats-rollup (AC1): hourly rollup
-- table over media_state_transitions (Story 1a/4b). Unlike
-- media_state_transitions itself (ADR-031, append-only compliance ledger),
-- this table is a DERIVED, re-computable aggregate — this story's own
-- MediaScanStatsRollupWorker is expected to UPDATE it via upsert (AC3/AC4),
-- so it gets no append-only trigger, no RLS, no REVOKE. Depends only on
-- media_files/media_state_transitions existing (Story 1a) — not on any of
-- 4a's/4b's own migrations.

CREATE TABLE media_scan_stats (
    id                    BIGSERIAL     PRIMARY KEY,
    window_start          TIMESTAMPTZ   NOT NULL,
    scans_released        INTEGER       NOT NULL DEFAULT 0,
    scans_infected        INTEGER       NOT NULL DEFAULT 0,
    scans_failed          INTEGER       NOT NULL DEFAULT 0,
    scans_total           INTEGER       GENERATED ALWAYS AS
                                         (scans_released + scans_infected + scans_failed) STORED,
    avg_scan_duration_ms  INTEGER,
    p95_scan_duration_ms  INTEGER,
    backlog_depth         INTEGER       NOT NULL DEFAULT 0,
    inserted_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Upsert-safety for AC3/AC4 (ON CONFLICT (window_start) DO UPDATE) and the
-- rolling-window LiveView reads (ORDER BY window_start DESC).
CREATE UNIQUE INDEX media_scan_stats_window_start_idx ON media_scan_stats (window_start);

-- ─── Grants (post-squash migration convention, MigrationsGrantTest) ─────────
GRANT SELECT, INSERT, UPDATE, DELETE ON media_scan_stats TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE media_scan_stats_id_seq TO nebu_app;
