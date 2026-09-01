-- media_files.uploader_user_id down-migration: restore NOT NULL (2e,
-- code-review CRITICAL fix, 2026-07-14). Note: this will fail if any row has
-- already been hard-deleted with a NULL uploader_user_id by the time this
-- runs — best-effort reversal, consistent with this project's other
-- nullable-column down-migrations (see 000025's down for the same pattern).
ALTER TABLE media_files
    ALTER COLUMN uploader_user_id SET NOT NULL;
