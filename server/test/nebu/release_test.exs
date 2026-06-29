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
      # priv/migrations now ships 000001–000012 (000004 add_room_type,
      # 000005 space_hierarchy_index, 000006 auto_join_opt_outs,
      # 000007 config_refresh_mode_mutable, 000008 room_aliases,
      # 000009 device_keys, 000010 devices — the device-registry-model story S1
      # adds a `devices` table + backfill from device_keys; 000009 is shipped/immutable.
      # 000011 jwt_device_bindings — device-management story S2 binds raw-OIDC-JWT
      # access tokens to a device server-side (token-hash → device_id).
      # 000012 — device-management story S3 (Matrix device endpoints): adds the
      # auth_time / fresh-auth-tracking + UIA-session columns the DELETE/delete_devices
      # endpoints need (and the bound-JWT kill-switch denylist forward migration).
      # RED until the 000012 migration file lands.
      assert versions == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

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
