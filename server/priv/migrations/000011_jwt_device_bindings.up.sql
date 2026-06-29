-- 000011_jwt_device_bindings.up.sql
-- Story s2-device-lifecycle-at-login (epic device-management).
--
-- AC3 / SECURITY G1: a raw OIDC-JWT access token must resolve to a server-side device binding,
-- exactly like an opaque Nebu session resolves its device via matrix_sessions.device_id. The JWT
-- is issued by the IdP (Nebu can NOT embed a device_id in it), so login persists a token->device
-- association here at login time, and OidcPlug looks the device up on every authenticated request.
--
-- The token is NEVER stored in the clear: the primary key is the SHA-256 hex digest of the access
-- token (the verified JWT). This makes the binding server-authoritative — the device a request acts
-- as comes from this row, never from attacker-controllable request input — and means a leaked DB
-- dump does not expose usable bearer tokens.
--
-- PostgreSQL-backed (cluster-correct per ADR-020 — login and a later request may land on different
-- nodes). created_at is BIGINT epoch-millis (schema-wide convention). Idempotent.

CREATE TABLE IF NOT EXISTS jwt_device_bindings (
    token_hash TEXT   NOT NULL PRIMARY KEY,
    user_id    TEXT   NOT NULL,
    device_id  TEXT   NOT NULL,
    created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_jwt_device_bindings_user ON jwt_device_bindings (user_id);
