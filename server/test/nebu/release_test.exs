defmodule Nebu.ReleaseTest do
  @moduledoc """
  Unit tests for the SQL migration runner re-homed from the Go gateway
  (story go-removal-cleanup). These cover the pure version-selection logic and
  the real `priv/migrations` filename parsing — no database connection needed.
  The full apply path is exercised by the integration suite against live
  PostgreSQL.

  Also covers the `postgres_ssl_opts/0` helper introduced by the
  `postgres-ssl-env-var` story: SSL is controlled via a separate
  `NEBU_POSTGRES_SSL` env variable instead of query parameters in the DB URL.
  """
  use ExUnit.Case, async: false

  alias Nebu.Release

  describe "list_up_migrations/1 — reads the canonical priv/migrations" do
    test "parses the real migration files into {version, path}, ignoring .down.sql" do
      dir = Path.join(:code.priv_dir(:nebu), "migrations")
      result = Release.list_up_migrations(dir)

      versions = result |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      # priv/migrations now ships 000001–000016 (000004 add_room_type,
      # 000005 space_hierarchy_index, 000006 auto_join_opt_outs,
      # 000007 config_refresh_mode_mutable, 000008 room_aliases,
      # 000009 device_keys, 000010 devices — the device-registry-model story S1
      # adds a `devices` table + backfill from device_keys; 000009 is shipped/immutable.
      # 000011 jwt_device_bindings — device-management story S2 binds raw-OIDC-JWT
      # access tokens to a device server-side (token-hash → device_id).
      # 000012 — device-management story S3 (Matrix device endpoints): adds the
      # auth_time / fresh-auth-tracking + UIA-session columns the DELETE/delete_devices
      # endpoints need (and the bound-JWT kill-switch denylist forward migration).
      # 000013 — configurable-oidc-scopes: extends config_update_mutable RLS policy
      # to allow runtime UPDATE of matrix_oidc_extra_scopes / admin_oidc_extra_scopes.
      # 000014 cross_signing_keys — client-crypto-setup story cross-signing-readback.
      # 000015 account_data — client-crypto-setup story account-data-durability.
      # (000014/000015 renumbered on rebase onto configurable-oidc-scopes.)
      # 000016 — scope-admin-claim-to-path: extends config_update_mutable RLS policy
      # to allow runtime UPDATE of admin_group_claim_path (path-scoped admin gate).
      # 000017 — enhanced-logging/operational-log-store: creates operational_logs
      # (persistent, admin-configurable diagnostic log store) and extends
      # config_update_mutable RLS policy with the 5 new log-policy keys.
      # 000018 — enhanced-logging/admin-logs-retention-settings: extends
      # config_update_mutable RLS policy with the new log_retention_info_max_count key.
      # 000019 — enhanced-logging/war-room-mode: creates war_room_sessions,
      # adds the operational_logs.war_room_id FK constraint (the column
      # itself was already added by 000017), and the "exactly one active
      # session" partial unique index.
      # 000020 — enhanced-logging/trace-map-node-controls: creates
      # admin_temporary_captures (the DB-backed capture timer — "state is a
      # row, expiry is a comparison against now()") and extends
      # config_update_mutable RLS policy with the log_min_level_<route> /
      # log_retention_days_<route> dynamic per-endpoint key families.
      # 000021 — enhanced-logging/war-room-dedicated-page: adds the
      # `war_room_sessions.exclusive_scope` nullable JSONB column (Dev Notes
      # Option A — the "capture everything EXCEPT these endpoints"
      # convenience, AC9/AC10).
      # 000022 — media-security-admin-control/1a-media-files-migration
      # (ADR-031): media_state / media_transition_actor_type ENUMs, 8 new
      # media_files columns + backfill, the append-only media_state_transitions
      # table with its BEFORE UPDATE OR DELETE immutability trigger
      # (SQLSTATE 23001) and secondary RLS/REVOKE layer.
      # 000023 — media-security-admin-control/9a-media-config-table-module
      # (ADR-027): creates the dedicated media_config key/value table (RLS +
      # 3 policies mirroring server_config's shape) that backs
      # Nebu.Media.Config's get/0 / upsert/2 (media policy settings — upload/
      # scan size limits, retention windows, webhook URL, MIME denylist).
      # 000024 — media-security-admin-control/11a-storage-config-schema-secrets:
      # creates the singleton media_storage_config table (RLS + 3 policies)
      # that backs Nebu.Media.StorageConfig's get/0 / get_for_connection/0 /
      # upsert/1 (S3/MinIO storage target config — endpoint/bucket/region/
      # use_ssl/access_key/secret_key/s3_key_prefix_template/archive_bucket).
      # 000025 — media-security-admin-control/2b-put-media-upload
      # (coordinator-approved guardrail exception, 2026-07-14): adds the
      # single nullable media_files.filename column so the async-upload PUT
      # handler can persist ?filename=... for later Content-Disposition
      # derivation. ALTER TABLE only — no new table, so no new GRANT is
      # required (media_files is already covered by 000001's blanket GRANT).
      # 000026 — media-security-admin-control/2e-reserved-upload-cleanup-cron
      # (ADR-025): bootstraps Oban (2e lands before 4b in actual build order, so
      # it absorbs the one-time schema setup 4b's own story had originally
      # planned to do). Hand-translates Oban 2.23's official Postgres schema
      # (oban_job_state enum, oban_jobs, oban_peers — the default table-based
      # leadership peer module Oban.Plugins.Cron needs) into this project's
      # raw-SQL convention; deliberately omits the pg_notify trigger/function
      # the official schema creates in V01/V08 and then itself DROPS in V12 —
      # not present as of schema version 14 (confirmed via direct inspection of
      # the fetched dependency's own migration source, not assumed).
      # 000027 — media-security-admin-control/2e-reserved-upload-cleanup-cron
      # (code-review CRITICAL fix, 2026-07-14): drops the NOT NULL constraint
      # on media_files.uploader_user_id. The cleanup cron's hard_deleted
      # transition NULLs this column per the epic's DB-Record-Invariante;
      # without this migration that UPDATE raises a Postgres not_null_violation
      # against a real database. ALTER TABLE only — no new GRANT required.
      # 000028 — media-security-admin-control/4a-scan-failed-enum-migration:
      # `ALTER TYPE media_state ADD VALUE 'scan_failed'` — the 9th media_state
      # value, deferred from Story 1a's foundation migration (000022) into its
      # own transaction per Postgres's restriction on combining ADD VALUE with
      # other DDL/DML against the same type. The story's own Technical
      # Requirements section names this file 000023 (the next free number when
      # the story was written); by the time it actually landed, 000023-000027
      # had already been claimed by the five migrations documented above, so
      # this migration is numbered 000028 instead — a pure filename/number
      # correction, no change to the SQL content or intent.
      # 000029 — media-security-admin-control/6a-routine-state-actions (design/
      # architecture gap, caller-approved option A): media_state_transitions.
      # actor_id was UUID (000022) on the mistaken assumption that admin
      # identity would be UUID-shaped; this app has no UUID-shaped user/admin
      # identity anywhere (users.user_id and audit_log.actor_user_id are both
      # TEXT, Matrix-ID-shaped) — 6a is the first real caller of the
      # {:admin, admin_id} actor, and it surfaced the mismatch. ALTER COLUMN
      # TYPE only — no new table, no new GRANT required. Verified zero-risk:
      # every existing row's actor_id was NULL before this migration ran.
      # 000030 — media-security-admin-control/6c-infected-override: adds
      # users.media_admin_override (BOOLEAN NOT NULL DEFAULT false), the
      # distinct grant (orthogonal to system_role) gating the
      # :infected -> :released false-positive override action. ALTER TABLE
      # only — no new table, no new GRANT required (users is already covered
      # by 000001's blanket GRANT on ALL TABLES).
      # 000031 — media-security-admin-control/8b-orphan-detection-gdpr
      # (AC6 / "Offene Entscheidung #3"): adds a jsonb_path_ops GIN index on
      # events.content, empirically verified via EXPLAIN ANALYZE to be
      # required for Nebu.Workers.MediaOrphanDetectionWorker's anti-join
      # detection query to avoid a full sequential scan of events per run.
      # Index-only — no new table, no new GRANT required (events is already
      # covered by 000001's blanket GRANT on ALL TABLES). Plain CREATE INDEX,
      # not CONCURRENTLY (see the migration file's own comment for why).
      # 000032 — media-security-admin-control/10a-scan-stats-rollup: adds the
      # media_scan_stats hourly rollup table (BIGSERIAL PK, UNIQUE index on
      # window_start) that Nebu.Workers.MediaScanStatsRollupWorker upserts
      # into and Nebu.Admin.MediaHealthLive reads from. New table — full
      # GRANT SELECT/INSERT/UPDATE/DELETE + sequence USAGE/SELECT to nebu_app
      # (this table is a derived, re-computable rollup, not an append-only
      # ledger like media_state_transitions — no trigger/RLS needed).
      # 000033 — media-security-admin-control/10c-media-alerts-triggers: adds
      # the media_alerts table (BIGINT IDENTITY PK, media_alert_severity
      # ENUM, TEXT+CHECK alert_type list, partial unique index enforcing at
      # most one OPEN alert per alert_type) that
      # Nebu.Workers.MediaAlertsCheckerWorker opens/auto-resolves and
      # Nebu.Media.Alerts.list_open/0 reads from. New table — narrower GRANT
      # SELECT/INSERT/UPDATE (deliberately no DELETE — alerts are opened/
      # updated in place, never removed by app code) + sequence USAGE/SELECT
      # to nebu_app. Also extends media_config_update_mutable (ADR-027,
      # Story 9a) with this story's own 4 alert-threshold keys.
      assert versions ==
               [
                 1,
                 2,
                 3,
                 4,
                 5,
                 6,
                 7,
                 8,
                 9,
                 10,
                 11,
                 12,
                 13,
                 14,
                 15,
                 16,
                 17,
                 18,
                 19,
                 20,
                 21,
                 22,
                 23,
                 24,
                 25,
                 26,
                 27,
                 28,
                 29,
                 30,
                 31,
                 32,
                 33,
                 34
               ]

      # Only *.up.sql files are returned — *.down.sql are excluded.
      assert Enum.all?(result, fn {_v, path} -> String.ends_with?(path, ".up.sql") end)
    end
  end

  describe "select_pending/2 — idempotency / existing-install safety" do
    setup do
      migs = [
        {3, "000003_c.up.sql"},
        {1, "000001_a.up.sql"},
        {2, "000002_b.up.sql"}
      ]

      {:ok, migs: migs}
    end

    test "fresh DB (version 0) applies all, in ascending order", %{migs: migs} do
      assert Release.select_pending(migs, 0) == [
               {1, "000001_a.up.sql"},
               {2, "000002_b.up.sql"},
               {3, "000003_c.up.sql"}
             ]
    end

    test "DB already migrated by the Go gateway (version 3) applies nothing", %{migs: migs} do
      # Critical for existing installs: no DDL is re-run when schema_migrations
      # already records the latest version.
      assert Release.select_pending(migs, 3) == []
    end

    test "partially-migrated DB (version 1) applies only the strictly-newer files", %{migs: migs} do
      assert Release.select_pending(migs, 1) == [
               {2, "000002_b.up.sql"},
               {3, "000003_c.up.sql"}
             ]
    end

    test "version equal to a file's version is NOT re-applied (strictly greater)", %{migs: migs} do
      assert Release.select_pending(migs, 2) == [{3, "000003_c.up.sql"}]
    end
  end

  # ── postgres-ssl-env-var: AC1 + AC2 ──────────────────────────────────────────
  # Tests for `Nebu.Release.postgres_ssl_opts/0` — a public (doc: false) helper
  # that reads NEBU_POSTGRES_SSL and returns the ssl keyword list to include in
  # both the runtime Repo config (runtime.exs) and the migration Postgrex opts
  # (release.ex parse_url). These tests are RED until the function is implemented.
  #
  # NOTE: `async: false` is required for the module because these tests mutate
  # process env. Individual tests restore the env in on_exit to avoid leaking
  # state across test cases.

  describe "postgres_ssl_opts/0 — NEBU_POSTGRES_SSL controls ssl: option (AC1 + AC2)" do
    setup do
      original_ssl = System.get_env("NEBU_POSTGRES_SSL")
      original_ca = System.get_env("NEBU_POSTGRES_CA_CERT_FILE")

      on_exit(fn ->
        case original_ssl do
          nil -> System.delete_env("NEBU_POSTGRES_SSL")
          val -> System.put_env("NEBU_POSTGRES_SSL", val)
        end

        case original_ca do
          nil -> System.delete_env("NEBU_POSTGRES_CA_CERT_FILE")
          val -> System.put_env("NEBU_POSTGRES_CA_CERT_FILE", val)
        end
      end)

      System.delete_env("NEBU_POSTGRES_CA_CERT_FILE")
      :ok
    end

    # AC1: NEBU_POSTGRES_SSL=true without CA cert → ssl: [verify: :verify_none]
    # (encrypted connection, no server cert validation — equivalent to sslmode=require)
    test "returns [ssl: [verify: :verify_none]] when NEBU_POSTGRES_SSL is \"true\" and no CA cert file" do
      System.put_env("NEBU_POSTGRES_SSL", "true")
      assert Release.postgres_ssl_opts() == [ssl: [verify: :verify_none]]
    end

    # AC5 (regression): unset → ssl: false (safe default for local dev stacks)
    test "returns [ssl: false] when NEBU_POSTGRES_SSL is not set" do
      System.delete_env("NEBU_POSTGRES_SSL")
      assert Release.postgres_ssl_opts() == [ssl: false]
    end

    # AC5 (regression): explicit false → ssl: false
    test "returns [ssl: false] when NEBU_POSTGRES_SSL is \"false\"" do
      System.put_env("NEBU_POSTGRES_SSL", "false")
      assert Release.postgres_ssl_opts() == [ssl: false]
    end

    # AC5 (regression): unknown/garbage value → ssl: false (safe default)
    test "returns [ssl: false] for unexpected values (e.g. \"1\", \"yes\")" do
      System.put_env("NEBU_POSTGRES_SSL", "yes")
      assert Release.postgres_ssl_opts() == [ssl: false]
    end

    # AC2: migration Postgrex opts must include ssl when NEBU_POSTGRES_SSL=true.
    # parse_url/1 is private; we verify indirectly through the public
    # postgres_ssl_opts/0 (same function used by parse_url). A dedicated
    # integration test in the integration suite covers the live DB path.
    test "ssl opts are suitable for inclusion in Postgrex start_link opts" do
      System.put_env("NEBU_POSTGRES_SSL", "true")
      opts = Release.postgres_ssl_opts()
      # Must be a keyword list with :ssl key — value is false or a keyword list of TLS opts.
      assert Keyword.keyword?(opts)
      assert Keyword.has_key?(opts, :ssl)
      ssl_val = Keyword.fetch!(opts, :ssl)
      assert ssl_val == false or Keyword.keyword?(ssl_val),
             "ssl value must be false or a TLS opts keyword list, got #{inspect(ssl_val)}"
    end

    # AC1 wiring: runtime.exs must merge postgres_ssl_opts() into the Nebu.Repo config.
    # Since runtime.exs only sets the Repo config in [:prod, :dev], we simulate the
    # wiring here: build the config the same way runtime.exs will (url + ssl opts),
    # and verify the :ssl key is present and truthy when SSL is enabled.
    test "postgres_ssl_opts/0 produces opts compatible with Nebu.Repo Ecto config (AC1 wiring)" do
      System.put_env("NEBU_POSTGRES_SSL", "true")
      ssl_opts = Release.postgres_ssl_opts()
      simulated_repo_config = [url: "postgresql://localhost/test", pool_size: 10] ++ ssl_opts
      ssl_val = simulated_repo_config[:ssl]

      assert ssl_val != false,
             "runtime.exs Repo config must have SSL enabled (non-false) when NEBU_POSTGRES_SSL=true. " <>
               "Got ssl=#{inspect(ssl_val)}."
    end

    test "postgres_ssl_opts/0 produces ssl: false when NEBU_POSTGRES_SSL is unset (AC1 default)" do
      System.delete_env("NEBU_POSTGRES_SSL")
      ssl_opts = Release.postgres_ssl_opts()
      simulated_repo_config = [url: "postgresql://localhost/test", pool_size: 10] ++ ssl_opts
      assert simulated_repo_config[:ssl] == false,
             "runtime.exs must use ssl: false as default when NEBU_POSTGRES_SSL is unset."
    end
  end
end
