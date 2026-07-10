-- enhanced-logging/operational-log-store (AC1, AC3, AC11): persistent,
-- admin-configurable operational log store — EXPLICITLY SEPARATE from
-- Nebu.Compliance.AuditLog (mutable/pruneable diagnostic data, not the
-- tamper-evident/immutable compliance audit trail).
--
-- A central `:logger` handler (Nebu.Web.LogStore.attach_handler/0) intercepts
-- every Logger.* call app-wide: it ALWAYS broadcasts via Phoenix.PubSub (for
-- live views, independent of persistence) and CONDITIONALLY persists here per
-- server_config policy (WARN/ERROR always persist; INFO/DEBUG gated by
-- log_collect_info/log_collect_debug) via a batching Nebu.Web.LogStore.Writer
-- GenServer — never a blocking INSERT inline in the caller's process.
--
-- war_room_id (nullable UUID, AC11): unused by this story's own ACs — an
-- extension seam for the later war-room-mode story (budget-counting/scoping
-- log capture by session), assigned by the Writer before INSERT.
--
-- Idempotent (IF NOT EXISTS) so applying on a fresh or already-migrated
-- instance is harmless.
CREATE TABLE IF NOT EXISTS operational_logs (
    id             BIGSERIAL PRIMARY KEY,
    inserted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    level          TEXT NOT NULL,
    source         TEXT NOT NULL,
    route_template TEXT,
    request_id     TEXT,
    message        TEXT NOT NULL,
    metadata       JSONB,
    war_room_id    UUID
);

-- Endpoint-level aggregation ("how many WARN/ERROR entries in the last hour,
-- grouped by level") and retention-pruning scans both filter/sort by
-- (level, inserted_at) — see Nebu.Web.LogStore.Retention.
CREATE INDEX IF NOT EXISTS operational_logs_level_inserted_at_idx
    ON operational_logs (level, inserted_at);

-- Later Admin UI story (admin-logs-monitoring-view) groups/filters by
-- normalized route_template over time.
CREATE INDEX IF NOT EXISTS operational_logs_route_template_inserted_at_idx
    ON operational_logs (route_template, inserted_at);

-- AC3: widen the server_config config_update_mutable RLS allowlist (see
-- 000016_config_admin_group_claim_path.up.sql for the precedent this
-- extends) with the 5 new log-policy keys, so a SECOND upsert (an UPDATE) of
-- any of them actually takes effect — not just the first upsert of a
-- brand-new key, which is always allowed unconditionally as an INSERT via
-- the pre-existing config_insert_only policy regardless of this allowlist.
--
-- Re-create the policy with the new keys added. Idempotent (DROP IF EXISTS).
DROP POLICY IF EXISTS config_update_mutable ON server_config;
CREATE POLICY config_update_mutable ON server_config
    FOR UPDATE
    USING (key IN (
        'max_users', 'registration_enabled', 'default_room_visibility',
        'default_max_members', 'bootstrap_completed',
        'oidc_user_id_claim', 'oidc_displayname_claim', 'oidc_email_claim',
        'oidc_directory_enabled', 'oidc_directory_endpoint',
        'gdpr_retention_days', 'signing_key_id', 'compliance_mode_enabled',
        'scim_token_hash',
        'matrix_oidc_refresh_mode', 'admin_oidc_refresh_mode',
        'matrix_oidc_extra_scopes', 'admin_oidc_extra_scopes',
        'admin_group_claim_path',
        'log_collect_info', 'log_retention_info_days',
        'log_collect_debug', 'log_retention_debug_days',
        'log_retention_debug_max_count'
    ));
