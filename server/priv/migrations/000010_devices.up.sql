-- 000010_devices.up.sql
-- Story s1-device-registry-model (epic device-management).
--
-- Makes a DEVICE a first-class entity with its own identity + metadata, separate from the
-- optional cryptographic key blob it may publish (device_keys, migration 000009). A device
-- must be listable/manageable even when the client never uploads E2EE device keys — device
-- existence is driven by the session/login (S2), independent of keys.
--
-- 000009 is SHIPPED / immutable (the fix-device-key-registration bugfix reaches the operator's
-- Stackit installation). This is a NEW FORWARD migration: it must NOT edit 000009 and must
-- BACKFILL from existing device_keys rows so an already-deployed DB (with device_keys rows
-- written by 000009) upgrades cleanly without data loss. A `devices` row can exist with NO key
-- material (keyless device).
--
-- This is ORTHOGONAL to end-to-end encryption (ADR-011 managed model): persisting device
-- identity encrypts nothing. E2EE is only enabled when a client sends an m.room.encryption
-- state event, which Nebu rejects.
--
-- PostgreSQL-backed (cluster-correct per ADR-020). All timestamps are BIGINT epoch-millis
-- (schema-wide convention). Idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING) so applying on
-- a fresh or already-migrated instance is harmless.

-- Device identity + management metadata. last_seen_ip is new (no source in device_keys; left
-- NULL on backfill). The PK matches device_keys so the keys table references a device 1:1.
CREATE TABLE IF NOT EXISTS devices (
    user_id      TEXT   NOT NULL,
    device_id    TEXT   NOT NULL,
    display_name TEXT,
    last_seen_ts BIGINT,
    last_seen_ip TEXT,
    created_at   BIGINT NOT NULL,
    updated_at   BIGINT NOT NULL,
    PRIMARY KEY (user_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_devices_user ON devices (user_id);

-- Backfill: every device that already published keys (a device_keys row from the shipped 000009)
-- becomes a `devices` row, carrying over display_name/last_seen_ts/created_at/updated_at. There is
-- no source for last_seen_ip in device_keys, so it stays NULL. ON CONFLICT DO NOTHING keeps this
-- idempotent and safe to re-run.
INSERT INTO devices (user_id, device_id, display_name, last_seen_ts, created_at, updated_at)
SELECT user_id, device_id, display_name, last_seen_ts, created_at, updated_at
FROM device_keys
ON CONFLICT (user_id, device_id) DO NOTHING;

-- ─── Runtime grants (dual-role: nebu_migrate owns, nebu_app operates) ────────
GRANT SELECT, INSERT, UPDATE, DELETE ON devices TO nebu_app;
