-- media-security-admin-control/8b-orphan-detection-gdpr: rollback for
-- 000031_events_content_gin_index.up.sql.
DROP INDEX IF EXISTS events_content_gin_idx;
