-- media-security-admin-control/1a-media-files-migration (AC1-AC10, ADR-031):
-- database foundation for the media state machine — a `state` column on
-- media_files (the quarantine -> scan -> release lifecycle) and a new
-- append-only media_state_transitions table that records every state change
-- as a compliance ledger. No Elixir behavior changes here; this is
-- schema-only (ADR-018). The guard logic (Nebu.Media.StateMachine, Story 1b)
-- and the HTTP enforcement point (download-gate, Story 1c) build on top of
-- this schema in later stories.

-- ─── media_state / media_transition_actor_type ENUMs ────────────────────────
CREATE TYPE media_state AS ENUM (
    'reserved', 'quarantined', 'scanning', 'released',
    'infected', 'admin_blocked', 'deleted', 'hard_deleted'
);
-- NOTE: 'scan_failed' is intentionally NOT included here — added later via
-- ALTER TYPE media_state ADD VALUE 'scan_failed' in Story 4a.

CREATE TYPE media_transition_actor_type AS ENUM ('system', 'admin');

-- ─── media_files: additive columns ──────────────────────────────────────────
-- media_files already exists (000001_init.up.sql) and is in production use
-- by the upload/download handlers (Nebu.Media.DB, Nebu.Media.Storage,
-- Nebu.Media.Crypto). This only ADDS columns — none of the 9 pre-existing
-- columns (media_id, server_name, content_type, file_size, aes_key_hex,
-- nonce_hex, uploader_user_id, uploaded_at, deleted) are touched.
ALTER TABLE media_files
    ADD COLUMN state          media_state NOT NULL DEFAULT 'released',
    ADD COLUMN file_hash      TEXT,
    ADD COLUMN scan_metadata  JSONB,
    ADD COLUMN storage_key    TEXT,
    ADD COLUMN compressed     BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN archived_at    TIMESTAMPTZ,
    ADD COLUMN deleted_at     TIMESTAMPTZ,
    ADD COLUMN hard_deleted_at TIMESTAMPTZ;

-- Backfill: legacy `deleted` boolean rows become state='deleted'; everything
-- else defaults to 'released' from the ADD COLUMN above already.
UPDATE media_files SET state = 'deleted' WHERE deleted = true;

-- Backfill: storage_key mirrors media_id, matching what Nebu.Media.DB.lookup/2
-- already derives at read time today (server/lib/nebu/media/db.ex).
UPDATE media_files SET storage_key = media_id WHERE storage_key IS NULL;

-- ─── media_state_transitions: append-only ledger ────────────────────────────
CREATE TABLE media_state_transitions (
    id          BIGSERIAL                   PRIMARY KEY,
    media_id    TEXT                        NOT NULL REFERENCES media_files(media_id),
    from_state  media_state,
    to_state    media_state                 NOT NULL,
    actor_type  media_transition_actor_type  NOT NULL,
    actor_id    UUID,
    metadata    JSONB,
    inserted_at TIMESTAMPTZ                 NOT NULL DEFAULT NOW()
);

CREATE INDEX media_state_transitions_media_id_idx ON media_state_transitions (media_id);

-- ─── Primary immutability guarantee (ADR-031 §1) ────────────────────────────
-- Provably append-only, not append-only-by-convention: this BEFORE UPDATE OR
-- DELETE trigger fires for every row and every role, including the table
-- owner (nebu_migrate/nebu_app in single-role dev/CI), and raises SQLSTATE
-- 23001 (restrict_violation). This is the authoritative guarantee — the
-- RLS/REVOKE block below is defense-in-depth only (see Dev Agent Guardrails
-- / R-006).
CREATE OR REPLACE FUNCTION media_state_transitions_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    RAISE EXCEPTION
        'media_state_transitions is append-only: % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation';   -- SQLSTATE 23001
END;
$$;

CREATE TRIGGER media_state_transitions_no_mutate
    BEFORE UPDATE OR DELETE ON media_state_transitions
    FOR EACH ROW EXECUTE FUNCTION media_state_transitions_immutable();

-- ─── Secondary layer: RLS + REVOKE (ADR-031 §2, mirrors audit_log) ──────────
ALTER TABLE media_state_transitions ENABLE ROW LEVEL SECURITY;
-- No FORCE RLS — same posture as audit_log; this layer is secondary only,
-- the trigger above is authoritative (see ADR-031).

CREATE POLICY media_state_transitions_insert ON media_state_transitions FOR INSERT WITH CHECK (true);
CREATE POLICY media_state_transitions_select ON media_state_transitions FOR SELECT USING (true);
CREATE POLICY media_state_transitions_no_update ON media_state_transitions FOR UPDATE USING (false);
CREATE POLICY media_state_transitions_no_delete ON media_state_transitions FOR DELETE USING (false);

-- ─── Grants (post-squash migration convention, MigrationsGrantTest) ─────────
GRANT SELECT, INSERT, UPDATE, DELETE ON media_state_transitions TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE media_state_transitions_id_seq TO nebu_app;

-- Defense-in-depth: revoke the UPDATE/DELETE just granted above. No-op if
-- nebu_app is the table owner (single-role dev/CI); meaningful in dual-role
-- deployments. The trigger, not this REVOKE, is what closes ADR-031/R-006.
REVOKE UPDATE, DELETE ON media_state_transitions FROM nebu_app;

-- Deliberately NO media_state_transitions_purge() elevated-privilege function
-- here — retention/rollup for this table is out of scope (epic Offene
-- Entscheidung #5). See ADR-031 §3 for the sanctioned escape hatch if a
-- future story needs one.
