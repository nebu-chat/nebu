-- media-security-admin-control/10c-media-alerts-triggers: rollback for
-- 000033_media_alerts.up.sql.
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
        'mime_denylist'
    ));

DROP INDEX IF EXISTS media_alerts_open_unique_idx;
DROP INDEX IF EXISTS media_alerts_open_idx;
DROP TABLE IF EXISTS media_alerts;
DROP TYPE IF EXISTS media_alert_severity;
