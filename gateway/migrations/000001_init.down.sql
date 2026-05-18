-- gateway/migrations/000001_init.down.sql
-- Drop all tables, functions, and triggers created by the squashed migration 000001.
-- Extensions are intentionally NOT dropped (shared PostgreSQL server may use them).
-- Drop order respects foreign key dependencies (dependents before dependencies).
--
-- NOTE: schema_migrations (golang-migrate's internal version tracking table) is NOT
-- dropped here. golang-migrate manages that table itself: it creates it on first run
-- and truncates/updates it on down migrations. Dropping it here would interfere with
-- golang-migrate's internal state management and cause errors on subsequent migrate Up calls.

-- ─── Triggers ────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS events_search_vector_trigger ON events;
DROP TRIGGER IF EXISTS audit_log_event_time_force_trigger ON audit_log;

-- ─── Functions ───────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS events_search_vector_update();
DROP FUNCTION IF EXISTS audit_log_event_time_force();
DROP FUNCTION IF EXISTS audit_log_purge(INT);

-- ─── Tables (dependents first) ───────────────────────────────────────────────
DROP TABLE IF EXISTS forgotten_rooms;
DROP TABLE IF EXISTS room_defaults;
DROP TABLE IF EXISTS role_overrides;
DROP TABLE IF EXISTS pushers;
DROP TABLE IF EXISTS push_rules;
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS room_account_data;
DROP TABLE IF EXISTS compliance_sessions;
DROP TABLE IF EXISTS compliance_requests;
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS admin_sessions;
DROP TABLE IF EXISTS media_files;
DROP TABLE IF EXISTS profiles;
DROP TABLE IF EXISTS read_receipts;
DROP TABLE IF EXISTS room_invitations;
DROP TABLE IF EXISTS sync_tokens;
DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS room_members;
DROP TABLE IF EXISTS rooms;
DROP TABLE IF EXISTS bootstrap_draft;
DROP TABLE IF EXISTS invalidated_tokens;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS user_keys;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS server_config;
DROP TABLE IF EXISTS message_dead_letter;
DROP TABLE IF EXISTS message_buffer;
