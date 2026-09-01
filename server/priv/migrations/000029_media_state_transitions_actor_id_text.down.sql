-- media_state_transitions.actor_id down-migration: restore UUID. Note: this will
-- fail once any row's actor_id holds a real, non-UUID Matrix-ID string (which is
-- the whole point of the up-migration) — best-effort reversal, consistent with this
-- project's other type/constraint-loosening down-migrations (see 000025's and
-- 000027's down for the same "best-effort, may fail against real post-migration
-- data" pattern).
ALTER TABLE media_state_transitions
    ALTER COLUMN actor_id TYPE UUID USING actor_id::uuid;
