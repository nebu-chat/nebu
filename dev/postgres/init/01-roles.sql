-- dev/postgres/init/01-roles.sql
-- Runs as postgres superuser at first container start
-- (mounted via docker-entrypoint-initdb.d).
--
-- DEV ONLY: passwords are hardcoded here for development convenience.
-- Production deployments MUST use secrets management (Kubernetes Secrets,
-- Vault, AWS Secrets Manager) — never hardcode credentials in production.
--
-- Two roles:
--   nebu_migrate — LEGACY: no longer required for fresh deployments as of Story 13.14.
--                  The squashed migration (000001_init.up.sql) runs as nebu_app only.
--                  Kept here for backward compatibility with existing dev volumes that
--                  were created before Story 13.14. Devs upgrading from older volumes
--                  will still have nebu_migrate in their DB; removing it here would
--                  cause the init script to fail on first run against those volumes.
--                  New fresh deployments (docker compose down --volumes) only need
--                  nebu_app. nebu_migrate will eventually be removed in a future story.
--                  (Story 13.14 squash — 2026-05-18)
--   nebu_app    — runtime gateway connection and migration owner in single-role model.
--                  Runs all golang-migrate migrations. NOT superuser.
--                  Owns all tables/sequences/functions in the squashed migration.
--
-- Story 5.29a — AC1 (FB-51-01), Story 13.14 (squash + single-role model)

DO $$
BEGIN
  -- nebu_migrate: legacy role, kept for backward compat with existing dev volumes.
  -- Not required for fresh deployments after Story 13.14 squash.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nebu_migrate') THEN
    CREATE ROLE nebu_migrate LOGIN PASSWORD 'nebu_migrate_dev_pw' CREATEDB BYPASSRLS;
  ELSE
    -- Ensure existing nebu_migrate has BYPASSRLS (devs upgrading from an earlier
    -- 5-29a iteration may have it without). Idempotent.
    ALTER ROLE nebu_migrate BYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nebu_app') THEN
    CREATE ROLE nebu_app LOGIN PASSWORD 'nebu_app_dev_pw'
      NOSUPERUSER NOINHERIT NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  ELSE
    -- Defense-in-depth: ensure existing nebu_app retains the safe defaults.
    ALTER ROLE nebu_app NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END $$;

-- Grant connection privileges to the nebu database (created by POSTGRES_DB env var).
GRANT CONNECT ON DATABASE nebu TO nebu_app;
GRANT CONNECT ON DATABASE nebu TO nebu_migrate;

-- Grant USAGE on public schema so roles can reference objects in it.
GRANT USAGE ON SCHEMA public TO nebu_app;
GRANT USAGE ON SCHEMA public TO nebu_migrate;

-- PostgreSQL 15+ revoked the default CREATE on schema public from non-owners.
-- nebu_migrate: legacy role; kept for backward compat.
GRANT CREATE ON SCHEMA public TO nebu_migrate;
-- nebu_app: after Story 13.14 squash, nebu_app runs migrations directly.
-- Must be able to CREATE the schema_migrations table and all migration objects.
GRANT CREATE ON SCHEMA public TO nebu_app;

-- Default privileges: tables/sequences/functions created by nebu_migrate
-- will automatically be accessible to nebu_app at SELECT/INSERT/UPDATE/DELETE
-- level. The append-only invariant on audit_log is enforced at the application
-- layer (the gateway never issues DELETE/UPDATE outside audit_log_purge()); see
-- comment in gateway/migrations/000001_init.up.sql. Not by withholding DELETE
-- globally, because many normal-operation flows (session cleanup, JWT denylist
-- rollover, bootstrap_draft clear, etc.) need DELETE on other tables.
ALTER DEFAULT PRIVILEGES FOR ROLE nebu_migrate IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO nebu_app;
ALTER DEFAULT PRIVILEGES FOR ROLE nebu_migrate IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO nebu_app;
ALTER DEFAULT PRIVILEGES FOR ROLE nebu_migrate IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO nebu_app;
