-- media-security-admin-control/2b-put-media-upload (AC2, coordinator-approved
-- guardrail exception, 2026-07-14): the async-upload PUT handler persists the
-- optional `?filename=...` query parameter so later downloads can derive a
-- Content-Disposition header from it. No column existed for this — 2b's own
-- "Do Not Change: migrations" guardrail was written under the false assumption
-- it already did. This is the only column this migration adds.
--
-- Nullable: 2a's genesis rows (state='reserved', created before this column
-- existed) and any upload that omits ?filename= have no value here.
--
-- No new GRANT required: media_files is already covered by migration 000001's
-- blanket `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
-- TO nebu_app`. MigrationsGrantTest only requires a new GRANT block for
-- migrations that CREATE TABLE — this migration only ALTERs an existing one.
ALTER TABLE media_files
    ADD COLUMN filename TEXT;
