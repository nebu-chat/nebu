-- 000009_device_keys.up.sql
-- Story fix-device-key-registration (bugfix epic login-bugs).
--
-- The device-key DIRECTORY: where Matrix clients publish their per-device identity keys
-- (Ed25519 + Curve25519), one-time keys (signed_curve25519), and fallback keys via
-- POST /keys/upload, and where peers read them back via POST /keys/query.
--
-- This is ORTHOGONAL to end-to-end encryption (ADR-011 managed model). Storing/echoing
-- these public keys encrypts nothing — E2EE is only enabled when a client sends an
-- m.room.encryption state event, which Nebu rejects (see do_set_room_state guardrail).
-- The directory exists so Element can register a device cleanly (no "device could not be
-- registered" error) and — forward-looking — so the device Ed25519 public key is durably
-- available for message-signature verification / non-repudiation (PRD FR25–FR27).
--
-- PostgreSQL-backed (not ETS) because the directory must be cluster-correct (ADR-020:
-- an upload and a later query may land on different nodes) and survive restarts.
--
-- All timestamps are BIGINT epoch-millis (schema-wide convention). Idempotent
-- (IF NOT EXISTS) so applying on a fresh or already-migrated instance is harmless.

-- Per-device identity keys (the signed device_keys object from /keys/upload, stored verbatim).
CREATE TABLE IF NOT EXISTS device_keys (
    user_id          TEXT   NOT NULL,
    device_id        TEXT   NOT NULL,
    device_keys_json TEXT   NOT NULL,
    display_name     TEXT,
    last_seen_ts     BIGINT,
    created_at       BIGINT NOT NULL,
    updated_at       BIGINT NOT NULL,
    PRIMARY KEY (user_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_device_keys_user ON device_keys (user_id);

-- One-time keys. PK includes key_id so re-uploading the same key is a no-op (store-once,
-- per Matrix spec). `claimed_at` lets /keys/claim consume a key exactly once; the unclaimed
-- count per algorithm is what /keys/upload and /sync report.
CREATE TABLE IF NOT EXISTS device_one_time_keys (
    user_id    TEXT   NOT NULL,
    device_id  TEXT   NOT NULL,
    algorithm  TEXT   NOT NULL,
    key_id     TEXT   NOT NULL,
    key_json   TEXT   NOT NULL,
    claimed_at BIGINT,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (user_id, device_id, algorithm, key_id)
);

CREATE INDEX IF NOT EXISTS idx_device_otk_unclaimed
    ON device_one_time_keys (user_id, device_id, algorithm)
    WHERE claimed_at IS NULL;

-- Fallback keys — at most one per (device, algorithm); re-upload replaces. `used` drives
-- the /sync device_unused_fallback_key_types list (an algorithm is "unused" while used=false).
CREATE TABLE IF NOT EXISTS device_fallback_keys (
    user_id    TEXT    NOT NULL,
    device_id  TEXT    NOT NULL,
    algorithm  TEXT    NOT NULL,
    key_json   TEXT    NOT NULL,
    used       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at BIGINT  NOT NULL,
    PRIMARY KEY (user_id, device_id, algorithm)
);

-- ─── Runtime grants (dual-role: nebu_migrate owns, nebu_app operates) ────────
GRANT SELECT, INSERT, UPDATE, DELETE ON device_keys TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON device_one_time_keys TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON device_fallback_keys TO nebu_app;
