-- media-security-admin-control/2e-reserved-upload-cleanup-cron (ADR-025): Oban
-- schema bootstrap. Oban is not yet a dependency anywhere in this codebase — this
-- story lands first in actual build order (ahead of 4b, which originally expected
-- to be the one to bootstrap it), so 2e absorbs the one-time schema setup.
--
-- Nebu's migration runner (Nebu.Release) applies raw numbered .up.sql/.down.sql
-- files directly via Postgrex — it is NOT Ecto-Migration-based (see the moduledoc
-- of Nebu.Release). Oban ships its schema as an `Oban.Migration`/`Ecto.Migration`
-- (`deps/oban/lib/oban/migrations/postgres.ex` + postgres/v01.ex..v14.ex once
-- `mix deps.get` fetches the `~> 2.18` dependency), which this project's runner
-- cannot execute directly. This migration is a hand-translation of that official
-- schema (Oban 2.23.0, schema version 14) into this project's raw-SQL convention.
--
-- What's included, and what's deliberately left out:
--   * oban_job_state ENUM + oban_jobs table + its final (V01-V14 cumulative)
--     indexes/constraints — required for Oban.Testing/Oban itself to function.
--   * oban_peers table (Oban.Peers.Database, the DEFAULT peer/leadership module —
--     see deps/oban/lib/oban/peer.ex) — required so Oban.Plugins.Cron elects a
--     single leader instead of every node trying to run the crontab.
--   * NO pg_notify trigger/function on oban_jobs. The official schema created one
--     in V01/V08 but DROPS both the trigger and the function in V08's successor,
--     V12 (`deps/oban/lib/oban/migrations/postgres/v12.ex`: "DROP TRIGGER IF EXISTS
--     oban_notify" / "DROP FUNCTION IF EXISTS oban_jobs_notify()") — as of schema
--     version 14 (what "~> 2.18" installs fresh), Oban's default Postgres notifier
--     issues `pg_notify` directly from the client connection rather than relying on
--     a DB-side trigger, so a trigger here would be dead weight the real dependency
--     itself no longer creates. Confirmed by direct inspection of the fetched
--     dependency's own migration source, not assumed.
--
-- Timestamp columns use TIMESTAMPTZ (this project's house convention — see
-- 000022_media_state_machine_foundation) rather than Ecto's raw
-- `timestamp(6) without time zone` — both are UTC-based in practice (Oban always
-- writes `timezone('UTC', now())`), so this is a safe, consistent substitution.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'oban_job_state') THEN
    CREATE TYPE oban_job_state AS ENUM (
      'available',
      'suspended',
      'scheduled',
      'executing',
      'retryable',
      'completed',
      'discarded',
      'cancelled'
    );
  END IF;
END$$;

-- ─── oban_jobs ───────────────────────────────────────────────────────────────
CREATE TABLE oban_jobs (
    id            BIGSERIAL      PRIMARY KEY,
    state         oban_job_state NOT NULL DEFAULT 'available',
    queue         TEXT           NOT NULL DEFAULT 'default',
    worker        TEXT           NOT NULL,
    args          JSONB          NOT NULL DEFAULT '{}'::jsonb,
    errors        JSONB[]        NOT NULL DEFAULT '{}',
    attempt       INTEGER        NOT NULL DEFAULT 0,
    max_attempts  INTEGER        NOT NULL DEFAULT 20,
    inserted_at   TIMESTAMPTZ    NOT NULL DEFAULT timezone('UTC', now()),
    scheduled_at  TIMESTAMPTZ    NOT NULL DEFAULT timezone('UTC', now()),
    attempted_at  TIMESTAMPTZ,
    completed_at  TIMESTAMPTZ,
    attempted_by  TEXT[],
    discarded_at  TIMESTAMPTZ,
    priority      INTEGER        NOT NULL DEFAULT 0,
    tags          TEXT[]         NOT NULL DEFAULT '{}',
    meta          JSONB          DEFAULT '{}'::jsonb,
    cancelled_at  TIMESTAMPTZ,

    CONSTRAINT worker_length CHECK (char_length(worker) > 0 AND char_length(worker) < 128),
    CONSTRAINT queue_length CHECK (char_length(queue) > 0 AND char_length(queue) < 128),
    CONSTRAINT positive_max_attempts CHECK (max_attempts > 0),
    CONSTRAINT attempt_range CHECK (attempt BETWEEN 0 AND max_attempts),
    CONSTRAINT non_negative_priority CHECK (priority >= 0)
);

-- Final (V08/V09-cumulative) primary work-selection index.
CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index
    ON oban_jobs (state, queue, priority, scheduled_at, id);

-- V10 — unique-check / meta-lookup performance.
CREATE INDEX oban_jobs_args_index ON oban_jobs USING GIN (args);
CREATE INDEX oban_jobs_meta_index ON oban_jobs USING GIN (meta);

-- V13 — cancelled/discarded lookups (e.g. Oban Web, admin inspection).
CREATE INDEX oban_jobs_state_cancelled_at_index ON oban_jobs (state, cancelled_at);
CREATE INDEX oban_jobs_state_discarded_at_index ON oban_jobs (state, discarded_at);

-- ─── oban_peers ──────────────────────────────────────────────────────────────
-- Table-based leadership (Oban.Peers.Database, the default peer module) — only
-- the leader's global plugins (Cron, Lifeline, Stager, ...) run, preventing every
-- node in a cluster from independently firing the same cron entry.
CREATE TABLE oban_peers (
    name        TEXT        PRIMARY KEY,
    node        TEXT        NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL
);

-- ─── Grants (post-squash migration convention, MigrationsGrantTest) ─────────
-- In production (UpCloud managed PostgreSQL) nebu_migrate owns tables and
-- nebu_app is the runtime role; there is no ALTER DEFAULT PRIVILEGES there, so
-- every table Oban itself reads/writes at runtime needs an explicit grant.
GRANT SELECT, INSERT, UPDATE, DELETE ON oban_jobs TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE oban_jobs_id_seq TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON oban_peers TO nebu_app;
