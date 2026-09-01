-- media_files.filename down-migration: drop the column (2b, coordinator-approved
-- guardrail exception, 2026-07-14).
ALTER TABLE media_files
    DROP COLUMN filename;
