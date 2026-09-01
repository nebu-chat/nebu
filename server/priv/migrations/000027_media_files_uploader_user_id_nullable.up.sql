-- media-security-admin-control/2e-reserved-upload-cleanup-cron (code-review
-- CRITICAL fix, 2026-07-14): the cleanup cron transitions abandoned :reserved
-- rows to :hard_deleted, and per the epic's DB-Record-Invariante that
-- transition must NULL uploader_user_id (accountability is cleared once a
-- row reaches its terminal state, consistent with the GDPR Art. 17 framing
-- used elsewhere in the epic). uploader_user_id was TEXT NOT NULL since
-- 000001_init.up.sql — nulling it on hard-delete would otherwise raise a
-- Postgres not_null_violation (23502) every time the real StateMachine
-- transition path runs against a live database. This migration is the schema
-- change that makes Nebu.Media.StateMachine's hard_deleted-specific UPDATE
-- (state_machine.ex) legal.
--
-- No new GRANT required: media_files is already covered by migration 000001's
-- blanket GRANT ... ON ALL TABLES IN SCHEMA public TO nebu_app. This
-- migration only ALTERs an existing table's column constraint, it does not
-- CREATE TABLE.
ALTER TABLE media_files
    ALTER COLUMN uploader_user_id DROP NOT NULL;
