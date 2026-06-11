-- gateway/migrations/000002_add_missing_structures.up.sql
-- Idempotent schema additions for Stackit instances that ran the original
-- migration 000001 (pre-squash) and are therefore missing structures added
-- in migrations 2–49 that were squashed into the new 000001_init.up.sql.
-- All statements use IF NOT EXISTS / DROP … IF EXISTS guards so applying on
-- a fresh (post-squash) instance is also harmless.

-- ─── users.personal_room_id ──────────────────────────────────────────────────
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS personal_room_id TEXT REFERENCES rooms(room_id);

-- ─── rooms.is_auto_join ──────────────────────────────────────────────────────
ALTER TABLE rooms
    ADD COLUMN IF NOT EXISTS is_auto_join BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS rooms_auto_join_idx
    ON rooms (is_auto_join) WHERE is_auto_join = true;

-- ─── rooms_created_at index ──────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS rooms_created_at_id_idx
    ON rooms (created_at DESC, room_id);

-- ─── events.state_key (migration 38) ─────────────────────────────────────────
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS state_key TEXT;

CREATE INDEX IF NOT EXISTS events_room_state_idx
    ON events (room_id, event_type, state_key, origin_server_ts DESC)
    WHERE state_key IS NOT NULL;

-- ─── events.search_vector (migration 43) ─────────────────────────────────────
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS search_vector tsvector;

CREATE INDEX IF NOT EXISTS events_search_vector_gin_idx
    ON events USING GIN (search_vector);

CREATE INDEX IF NOT EXISTS events_relates_to_event_id_idx
    ON events ((content->'m.relates_to'->>'event_id'))
    WHERE content ? 'm.relates_to';

-- ─── events search vector trigger ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION events_search_vector_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.search_vector := to_tsvector('pg_catalog.simple',
    coalesce(NEW.content->>'body', ''));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS events_search_vector_trigger ON events;
CREATE TRIGGER events_search_vector_trigger
  BEFORE INSERT OR UPDATE OF content ON events
  FOR EACH ROW
  EXECUTE FUNCTION events_search_vector_update();

-- ─── media_files.deleted (migration 23) ──────────────────────────────────────
ALTER TABLE media_files
    ADD COLUMN IF NOT EXISTS deleted BOOLEAN NOT NULL DEFAULT false;

-- ─── admin_sessions.refresh_token (migration 39) ─────────────────────────────
ALTER TABLE admin_sessions
    ADD COLUMN IF NOT EXISTS refresh_token TEXT;

-- ─── matrix_sessions ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS matrix_sessions (
    access_token        TEXT        PRIMARY KEY,
    refresh_token       TEXT        UNIQUE NOT NULL,
    oidc_refresh_token  TEXT,
    user_id             TEXT        NOT NULL,
    device_id           TEXT        NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    grace_until         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_matrix_sessions_refresh_token
    ON matrix_sessions (refresh_token);
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_user_id
    ON matrix_sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_expires_at
    ON matrix_sessions (expires_at);

-- ─── audit_log ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
    id            BIGSERIAL    PRIMARY KEY,
    event_time    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    actor_user_id TEXT         NOT NULL,
    action        TEXT         NOT NULL,
    target_type   TEXT,
    target_id     TEXT,
    metadata      JSONB,
    outcome       TEXT         NOT NULL,
    error_detail  TEXT
);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_insert_allow ON audit_log;
CREATE POLICY audit_log_insert_allow ON audit_log FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS audit_log_select_allow ON audit_log;
CREATE POLICY audit_log_select_allow ON audit_log FOR SELECT USING (true);

DROP POLICY IF EXISTS audit_log_no_update ON audit_log;
CREATE POLICY audit_log_no_update ON audit_log FOR UPDATE USING (false);

DROP POLICY IF EXISTS audit_log_no_delete ON audit_log;
CREATE POLICY audit_log_no_delete ON audit_log FOR DELETE USING (false);

REVOKE UPDATE, DELETE ON audit_log FROM nebu_app;

CREATE OR REPLACE FUNCTION audit_log_purge(retention_days INT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    IF retention_days IS NULL OR retention_days < 1 OR retention_days > 36500 THEN
        RAISE EXCEPTION 'audit_log_purge: retention_days must be between 1 and 36500 (got %)', retention_days
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    DELETE FROM audit_log
    WHERE event_time < NOW() - make_interval(days => retention_days);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION audit_log_purge(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit_log_purge(INT) TO nebu_app;

CREATE OR REPLACE FUNCTION audit_log_event_time_force()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.event_time := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audit_log_event_time_force_trigger ON audit_log;
CREATE TRIGGER audit_log_event_time_force_trigger
  BEFORE INSERT ON audit_log
  FOR EACH ROW
  EXECUTE FUNCTION audit_log_event_time_force();

-- ─── compliance_requests ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance_requests (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_user_id TEXT        NOT NULL,
    room_id           TEXT        NOT NULL,
    time_range_start  TIMESTAMPTZ NOT NULL,
    time_range_end    TIMESTAMPTZ NOT NULL,
    justification     TEXT        NOT NULL,
    status            TEXT        NOT NULL DEFAULT 'pending',
    approver_user_id  TEXT,
    approved_at       TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT compliance_requests_status_check
        CHECK (status IN ('pending', 'approved', 'rejected'))
);

CREATE INDEX IF NOT EXISTS compliance_requests_status_created_at_idx
    ON compliance_requests (status, created_at DESC);

ALTER TABLE compliance_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_requests FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS compliance_requests_insert ON compliance_requests;
CREATE POLICY compliance_requests_insert ON compliance_requests FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS compliance_requests_select ON compliance_requests;
CREATE POLICY compliance_requests_select ON compliance_requests FOR SELECT USING (true);

DROP POLICY IF EXISTS compliance_requests_update ON compliance_requests;
CREATE POLICY compliance_requests_update ON compliance_requests FOR UPDATE USING (true);

DROP POLICY IF EXISTS compliance_requests_no_delete ON compliance_requests;
CREATE POLICY compliance_requests_no_delete ON compliance_requests FOR DELETE USING (false);

-- ─── compliance_sessions ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS compliance_sessions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id  UUID        NOT NULL REFERENCES compliance_requests(id),
    token_hash  BYTEA       NOT NULL,
    issued_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked_at  TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS compliance_sessions_active_request_idx
    ON compliance_sessions (request_id)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS compliance_sessions_expires_at_idx
    ON compliance_sessions (expires_at)
    WHERE revoked_at IS NULL;

ALTER TABLE compliance_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_sessions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS compliance_sessions_insert ON compliance_sessions;
CREATE POLICY compliance_sessions_insert ON compliance_sessions FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS compliance_sessions_select ON compliance_sessions;
CREATE POLICY compliance_sessions_select ON compliance_sessions FOR SELECT USING (true);

DROP POLICY IF EXISTS compliance_sessions_update ON compliance_sessions;
CREATE POLICY compliance_sessions_update ON compliance_sessions FOR UPDATE USING (true);

DROP POLICY IF EXISTS compliance_sessions_no_delete ON compliance_sessions;
CREATE POLICY compliance_sessions_no_delete ON compliance_sessions FOR DELETE USING (false);

-- ─── room_account_data ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS room_account_data (
    user_id     TEXT        NOT NULL,
    room_id     TEXT        NOT NULL,
    event_type  TEXT        NOT NULL,
    content     JSONB       NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, room_id, event_type)
);

ALTER TABLE room_account_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_account_data FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS room_account_data_nebu_app_policy ON room_account_data;
CREATE POLICY room_account_data_nebu_app_policy ON room_account_data
    FOR ALL
    TO nebu_app
    USING (user_id = current_setting('app.user_id', true))
    WITH CHECK (user_id = current_setting('app.user_id', true));

-- ─── notifications ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notifications (
    id          BIGSERIAL   PRIMARY KEY,
    user_id     TEXT        NOT NULL,
    room_id     TEXT        NOT NULL,
    event_id    TEXT        NOT NULL,
    event_json  JSONB       NOT NULL,
    actions     JSONB       NOT NULL DEFAULT '["notify"]',
    read        BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS notifications_user_created
    ON notifications (user_id, created_at DESC);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_nebu_app_policy ON notifications;
CREATE POLICY notifications_nebu_app_policy ON notifications
    FOR ALL
    TO nebu_app
    USING (user_id = current_setting('app.user_id', true))
    WITH CHECK (user_id = current_setting('app.user_id', true));

-- ─── push_rules ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS push_rules (
    id           BIGSERIAL PRIMARY KEY,
    user_id      TEXT    NOT NULL,
    scope        TEXT    NOT NULL DEFAULT 'global',
    kind         TEXT    NOT NULL,
    rule_id      TEXT    NOT NULL,
    priority     INT     NOT NULL DEFAULT 0,
    enabled      BOOLEAN NOT NULL DEFAULT TRUE,
    conditions   JSONB   NOT NULL DEFAULT '[]',
    actions      JSONB   NOT NULL DEFAULT '["notify"]',
    default_rule BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (user_id, scope, kind, rule_id)
);

CREATE INDEX IF NOT EXISTS idx_push_rules_user_scope
    ON push_rules (user_id, scope);

ALTER TABLE push_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_rules FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS push_rules_nebu_app_policy ON push_rules;
CREATE POLICY push_rules_nebu_app_policy ON push_rules
    FOR ALL
    TO nebu_app
    USING (user_id = current_setting('app.user_id', true))
    WITH CHECK (user_id = current_setting('app.user_id', true));

-- ─── pushers ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pushers (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             TEXT NOT NULL,
    pushkey             TEXT NOT NULL,
    kind                TEXT NOT NULL,
    app_id              TEXT NOT NULL,
    app_display_name    TEXT NOT NULL,
    device_display_name TEXT NOT NULL,
    lang                TEXT NOT NULL DEFAULT 'en',
    data                JSONB NOT NULL DEFAULT '{}',
    UNIQUE (user_id, app_id, pushkey)
);

CREATE INDEX IF NOT EXISTS idx_pushers_user_id ON pushers (user_id);

ALTER TABLE pushers ENABLE ROW LEVEL SECURITY;
ALTER TABLE pushers FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pushers_nebu_app_policy ON pushers;
CREATE POLICY pushers_nebu_app_policy ON pushers
    FOR ALL
    TO nebu_app
    USING (user_id = current_setting('app.user_id', true))
    WITH CHECK (user_id = current_setting('app.user_id', true));

-- ─── role_overrides ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS role_overrides (
    user_id    TEXT        NOT NULL,
    role       TEXT        NOT NULL,
    granted_by TEXT        NOT NULL,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, role),
    CONSTRAINT role_overrides_role_check
        CHECK (role IN ('instance_admin', 'compliance_officer'))
);

CREATE INDEX IF NOT EXISTS role_overrides_user_id_idx ON role_overrides (user_id);

-- ─── room_defaults ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS room_defaults (
    id                    SERIAL  PRIMARY KEY,
    default_max_members   INTEGER NOT NULL DEFAULT 0
        CHECK (default_max_members >= 0),
    default_visibility    TEXT    NOT NULL DEFAULT 'private'
        CHECK (default_visibility IN ('public', 'private')),
    set_at                BIGINT  NOT NULL
);

INSERT INTO room_defaults (default_max_members, default_visibility, set_at)
SELECT 0, 'private', 0
WHERE NOT EXISTS (SELECT 1 FROM room_defaults);

-- ─── forgotten_rooms ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS forgotten_rooms (
    user_id         TEXT    NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    room_id         TEXT    NOT NULL,
    forgotten_at_ms BIGINT  NOT NULL DEFAULT (EXTRACT(EPOCH FROM now()) * 1000)::BIGINT,
    PRIMARY KEY (user_id, room_id)
);

-- ─── server_config mutable-keys RLS policy (migration 49) ────────────────────
DROP POLICY IF EXISTS config_update_mutable ON server_config;
CREATE POLICY config_update_mutable ON server_config
    FOR UPDATE
    USING (key IN (
        'max_users', 'registration_enabled', 'default_room_visibility',
        'default_max_members', 'bootstrap_completed',
        'oidc_user_id_claim', 'oidc_displayname_claim', 'oidc_email_claim',
        'oidc_directory_enabled', 'oidc_directory_endpoint',
        'gdpr_retention_days', 'signing_key_id', 'compliance_mode_enabled',
        'scim_token_hash'
    ));

-- ─── Seed data ────────────────────────────────────────────────────────────────
INSERT INTO server_config (key, value, set_at) VALUES
  ('oidc_user_id_claim',      'name',  (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint),
  ('oidc_displayname_claim',  'name',  (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint),
  ('oidc_email_claim',        'email', (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint)
ON CONFLICT (key) DO NOTHING;

INSERT INTO server_config (key, value, set_at) VALUES
    ('oidc_directory_enabled',  'false', (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint),
    ('oidc_directory_endpoint', '',      (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint)
ON CONFLICT (key) DO NOTHING;
