-- media-security-admin-control/10d-scan-kill-switch: rollback for
-- 000034_media_config_scan_kill_switch.up.sql — restores the
-- media_config_update_mutable allowlist to its pre-10d (post-10c) state.
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
