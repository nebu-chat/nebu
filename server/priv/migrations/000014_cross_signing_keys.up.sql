-- 000010_cross_signing_keys.up.sql
-- Story cross-signing-readback (epic client-crypto-setup).
--
-- The cross-signing key DIRECTORY: where Matrix clients publish their per-user
-- cross-signing keys (master / self-signing / user-signing) via
-- POST /keys/device_signing/upload, and where peers read them back via
-- POST /keys/query. Signatures added via POST /keys/signatures/upload are merged
-- into the relevant stored key object's `signatures` map (kept inside the JSON blob).
--
-- This is ORTHOGONAL to end-to-end encryption (ADR-011 managed model). Storing and
-- echoing these public cross-signing keys encrypts nothing — E2EE is only enabled
-- when a client sends an m.room.encryption state event, which Nebu rejects (see
-- do_set_room_state guardrail). The directory exists so Element completes its
-- cross-signing / recovery bootstrap (no "Schlüssel können nicht eingerichtet
-- werden" error) and the session shows as verifiable.
--
-- PostgreSQL-backed (not ETS) because the directory must be cluster-correct (ADR-020:
-- an upload and a later query may land on different nodes) and survive restarts.
--
-- All timestamps are BIGINT epoch-millis (schema-wide convention). Idempotent
-- (IF NOT EXISTS) so applying on a fresh or already-migrated instance is harmless.
--
-- One row per user. Each *_key_json column stores the opaque cross-signing key
-- object verbatim (its `signatures` map lives inside that JSON). user_signing_key
-- is nullable (clients may omit it). `cross_signing_changed` is a consume-once flag
-- (set true on upload; the next incremental /sync reads-and-clears it via
-- UPDATE ... RETURNING) that drives device_lists.changed (CS §Cross-signing).

CREATE TABLE IF NOT EXISTS cross_signing_keys (
    user_id               TEXT    NOT NULL,
    master_key_json       TEXT,
    self_signing_key_json TEXT,
    user_signing_key_json TEXT,
    cross_signing_changed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at            BIGINT  NOT NULL,
    updated_at            BIGINT  NOT NULL,
    PRIMARY KEY (user_id)
);
