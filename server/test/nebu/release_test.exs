defmodule Nebu.ReleaseTest do
  @moduledoc """
  Unit tests for the SQL migration runner re-homed from the Go gateway
  (story go-removal-cleanup). These cover the pure version-selection logic and
  the real `priv/migrations` filename parsing — no database connection needed.
  The full apply path is exercised by the integration suite against live
  PostgreSQL.
  """
  use ExUnit.Case, async: true

  alias Nebu.Release

  describe "list_up_migrations/1 — reads the canonical priv/migrations" do
    test "parses the real migration files into {version, path}, ignoring .down.sql" do
      dir = Path.join(:code.priv_dir(:nebu), "migrations")
      result = Release.list_up_migrations(dir)

      versions = result |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      # priv/migrations now ships 000001–000007 (000004 add_room_type,
      # 000005 space_hierarchy_index, 000006 auto_join_opt_outs,
      # 000007 config_refresh_mode_mutable).
      assert versions == [1, 2, 3, 4, 5, 6, 7]

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
end
