-- 000051_events_redacts.down.sql
-- Reverts 000051: the partial index first, then the column. RE-EXPOSURE: the stored targets of writer-made redactions are lost, the
-- redaction events stay and are served afterwards like legacy rows (never applied), so every removed message is readable again for the
-- room's members (docs/architecture/07-deployment.md).
DROP INDEX IF EXISTS events_redacts_idx;
ALTER TABLE events DROP COLUMN IF EXISTS redacts;
