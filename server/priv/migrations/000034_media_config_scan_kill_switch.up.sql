-- media-security-admin-control/10d-scan-kill-switch (AC2): extend
-- media_config's mutable-key allowlist (ADR-027, Story 9a) with this
-- story's own scan_kill_switch key — same incremental-extension precedent
-- 9a's own migration documents, and the one 10c's own 000033 already
-- followed (ALTER POLICY, not DROP+CREATE, so the policy's OID/dependents
-- stay stable across this extension).
--
-- This story adds no new table (only a new media_config KEY, a worker
-- branch, and an audit-allowlist entry) — the GRANT-on-new-table
-- requirement (MigrationsGrantTest) does not apply to this migration.
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
        'scan_failed_rate_alert_pct',
        'scan_kill_switch'
    ));
