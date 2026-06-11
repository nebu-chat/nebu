-- gateway/migrations/000002_add_missing_structures.down.sql
-- Reverses 000002_add_missing_structures.up.sql.
-- WARNING: dropping these tables/columns removes data permanently.

DROP TABLE IF EXISTS forgotten_rooms;
DROP TABLE IF EXISTS room_defaults;
DROP TABLE IF EXISTS role_overrides;
DROP TABLE IF EXISTS pushers;
DROP TABLE IF EXISTS push_rules;
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS room_account_data;
DROP TABLE IF EXISTS compliance_sessions;
DROP TABLE IF EXISTS compliance_requests;
DROP TABLE IF EXISTS matrix_sessions;
DROP TABLE IF EXISTS audit_log;

DROP TRIGGER IF EXISTS events_search_vector_trigger ON events;

DROP FUNCTION IF EXISTS audit_log_purge(INT);
DROP FUNCTION IF EXISTS audit_log_event_time_force();
DROP FUNCTION IF EXISTS events_search_vector_update();

ALTER TABLE media_files DROP COLUMN IF EXISTS deleted;
ALTER TABLE admin_sessions DROP COLUMN IF EXISTS refresh_token;
ALTER TABLE events DROP COLUMN IF EXISTS search_vector;
ALTER TABLE events DROP COLUMN IF EXISTS state_key;
ALTER TABLE rooms DROP COLUMN IF EXISTS is_auto_join;
ALTER TABLE users DROP COLUMN IF EXISTS personal_room_id;
