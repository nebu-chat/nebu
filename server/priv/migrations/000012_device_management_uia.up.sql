-- 000012_device_management_uia.up.sql
-- Story s3-matrix-device-endpoints (epic device-management).
--
-- The WRITE side of Matrix device management (PUT /devices/{id} rename,
-- DELETE /devices/{id}, POST /delete_devices) is User-Interactive-Authentication
-- gated via the m.login.sso stage with a 15-minute fresh-auth window (Option B).
-- This forward migration adds the columns + table that the freshness gate, the
-- bound-JWT kill-switch, and the UIA session store need:
--
--   * matrix_sessions.auth_time — the user's LAST FRESH authentication time
--     (unix SECONDS), captured at login from the id_token's auth_time/iat claim.
--     The 15-min window compares now - auth_time. A token *refresh* must NOT reset
--     it (rotate_tokens copies it verbatim), so a refresh can never defeat the gate.
--
--   * jwt_device_bindings.exp — the verified JWT's exp (unix SECONDS), populated by
--     DeviceBinding.put/3. Feeds the F-1 kill-switch: deleting a device denylists
--     every JWT bound to (user, device) until its own exp via TokenDenylist, and
--     the binding-sweeper evicts rows whose exp has passed.
--
--   * idx_jwt_device_bindings_user_device — the kill-switch enumerates bindings by
--     (user_id, device_id) to denylist each bound token; this index serves it.
--
--   * uia_sessions — server-issued, single-use UIA sessions bound to
--     (user_id, op, params). DB-backed (NOT node-local ETS) because the session is
--     minted on one node, completed via the browser SSO fallback on possibly another,
--     and the re-submit may hit a third — cluster-correct per ADR-020. consumed flips
--     true on first successful use (single-use, G2); stage_complete flips true when
--     the SSO callback validates the fresh login. The SSO callback resolves the UIA
--     session via SsoStore state -> uia_session and Uia.complete/1 keys by session_id,
--     so the row stores no SSO-state linkage of its own.
--
-- 000009/000010/000011 are SHIPPED / immutable — this is a NEW FORWARD migration and
-- does NOT edit them. All timestamps are BIGINT epoch (SECONDS for auth_time/exp/UIA,
-- matching the verified-claim and TokenDenylist conventions). Idempotent
-- (IF NOT EXISTS / ADD COLUMN IF NOT EXISTS) so applying on a fresh or already-migrated
-- instance is harmless.

-- Fresh-auth tracking for opaque sessions (Option B 15-min window). Nullable: a row
-- written before this migration has no auth_time and is treated as "stale" (challenge).
ALTER TABLE matrix_sessions ADD COLUMN IF NOT EXISTS auth_time BIGINT;

-- The verified JWT's exp, so the kill-switch can denylist a bound token until its own
-- expiry and the sweeper can evict expired binding rows.
ALTER TABLE jwt_device_bindings ADD COLUMN IF NOT EXISTS exp BIGINT;

-- The kill-switch enumerates bindings for a (user, device) pair to revoke each token.
CREATE INDEX IF NOT EXISTS idx_jwt_device_bindings_user_device
    ON jwt_device_bindings (user_id, device_id);

-- Server-issued, single-use UIA sessions, DB-backed for cluster-correctness (ADR-020).
CREATE TABLE IF NOT EXISTS uia_sessions (
    session_id     TEXT    NOT NULL PRIMARY KEY,
    user_id        TEXT    NOT NULL,
    op             TEXT    NOT NULL,
    params         TEXT,                         -- canonical-JSON of the bound operation params
    stage_complete BOOLEAN NOT NULL DEFAULT FALSE,
    consumed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     BIGINT  NOT NULL,             -- unix seconds
    expires_at     BIGINT  NOT NULL              -- unix seconds
);

CREATE INDEX IF NOT EXISTS idx_uia_sessions_expires_at ON uia_sessions (expires_at);
