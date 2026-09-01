-- Reverses 000022_media_state_machine_foundation.up.sql.
--
-- Order matters: drop dependents before the types/tables they reference.
-- Trigger -> trigger function -> table (CASCADE also drops its FK/index) ->
-- media_files columns -> the two new ENUM types (columns/table must be gone
-- first, since they reference these types).
DROP TRIGGER IF EXISTS media_state_transitions_no_mutate ON media_state_transitions;
DROP FUNCTION IF EXISTS media_state_transitions_immutable();
DROP TABLE IF EXISTS media_state_transitions CASCADE;

ALTER TABLE media_files
    DROP COLUMN IF EXISTS state,
    DROP COLUMN IF EXISTS file_hash,
    DROP COLUMN IF EXISTS scan_metadata,
    DROP COLUMN IF EXISTS storage_key,
    DROP COLUMN IF EXISTS compressed,
    DROP COLUMN IF EXISTS archived_at,
    DROP COLUMN IF EXISTS deleted_at,
    DROP COLUMN IF EXISTS hard_deleted_at;

DROP TYPE IF EXISTS media_state;
DROP TYPE IF EXISTS media_transition_actor_type;
