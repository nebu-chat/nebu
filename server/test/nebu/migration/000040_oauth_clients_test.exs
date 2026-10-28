defmodule Nebu.Migration.Migration000040OauthClientsTest do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval`, AC5 (`oauth_clients` table,
  migration `000040_oauth_clients_and_auth_metadata`).

  Two layers:
    * static SQL-file analysis (no DB) — same style as `Nebu.Matrix.MigrationsGrantTest`
    * `:integration` introspection of the migrated schema (columns, defaults, indexes,
      uniqueness, atomic `ON CONFLICT (metadata_hash) DO NOTHING`, no FK to users)
  """
  use ExUnit.Case, async: false

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000040_oauth_clients_and_auth_metadata.up.sql"
  @down "000040_oauth_clients_and_auth_metadata.down.sql"

  @columns ~w(client_id metadata metadata_hash application_type status approved_by approved_at
              rejected_by rejected_at token_endpoint_auth_method created_at last_used_at
              created_from_ip user_agent client_host)

  defp read!(f), do: File.read!(Path.join(@dir, f))

  describe "AC5 — migration files (static)" do
    test "up and down migration exist, numbered 000040 right after 000039" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert File.exists?(Path.join(@dir, "000039_user_room_account_data.up.sql"))
    end

    test "up creates oauth_clients with every column of the story schema" do
      sql = read!(@up)
      assert sql =~ ~r/CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?oauth_clients/i
      for col <- @columns, do: assert(sql =~ ~r/\b#{col}\b/, "column #{col} missing in #{@up}")
    end

    test "client_id is the primary key and metadata_hash is UNIQUE NOT NULL; metadata is JSONB" do
      sql = read!(@up)
      assert sql =~ ~r/client_id\s+TEXT\s+PRIMARY\s+KEY/i
      assert sql =~ ~r/metadata_hash\s+TEXT\s+NOT\s+NULL\s+UNIQUE/i
      assert sql =~ ~r/metadata\s+JSONB\s+NOT\s+NULL/i
    end

    test "defaults: application_type 'web', status 'pending', token_endpoint_auth_method 'none'" do
      sql = read!(@up)
      assert sql =~ ~r/application_type\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'web'/i
      assert sql =~ ~r/status\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'pending'/i
      assert sql =~ ~r/token_endpoint_auth_method\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'none'/i
    end

    test "creates the (status, created_at DESC) and (metadata_hash) indexes" do
      sql = read!(@up)
      assert sql =~ ~r/CREATE\s+(UNIQUE\s+)?INDEX[^;]*oauth_clients\s*\(\s*status\s*,\s*created_at\s+DESC\s*\)/is
      assert sql =~ ~r/CREATE\s+(UNIQUE\s+)?INDEX[^;]*oauth_clients\s*\(\s*metadata_hash\s*\)/is
    end

    test "no foreign keys: registrations are independent of user identity" do
      refute read!(@up) =~ ~r/REFERENCES/i
    end

    test "CHECK constraints pin status and application_type to their closed value sets" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      assert sql =~ ~r/CHECK\s*\(\s*status\s+IN\s*\(\s*'pending'\s*,\s*'approved'\s*,\s*'rejected'\s*\)\s*\)/i
      assert sql =~ ~r/CHECK\s*\(\s*application_type\s+IN\s*\(\s*'web'\s*,\s*'native'\s*\)\s*\)/i
    end

    test "RLS: enabled + forced, SELECT/UPDATE open, INSERT only as pending, DELETE only for status = 'pending'" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_clients\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
      # nebu_app owns the table (single-role model): without FORCE the owner bypasses every policy.
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_clients\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i
      assert sql =~ ~r/CREATE\s+POLICY\s+\w+\s+ON\s+oauth_clients\s+FOR\s+SELECT\s+USING\s*\(\s*true\s*\)/i
      assert sql =~ ~r/CREATE\s+POLICY\s+\w+\s+ON\s+oauth_clients\s+FOR\s+INSERT\s+WITH\s+CHECK\s*\(\s*status\s*=\s*'pending'/i
      assert sql =~ ~r/CREATE\s+POLICY\s+\w+\s+ON\s+oauth_clients\s+FOR\s+UPDATE\s+USING\s*\(\s*true\s*\)/i
      assert sql =~ ~r/CREATE\s+POLICY\s+oauth_clients_delete_pending\s+ON\s+oauth_clients\s+FOR\s+DELETE\s+USING\s*\(\s*status\s*=\s*'pending'\s*\)/i
      # exactly one DELETE policy, and it is the pending-only one
      assert length(Regex.scan(~r/FOR\s+DELETE/i, sql)) == 1
    end

    test "grants DELETE to nebu_app (confined by the RLS delete policy)" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      assert sql =~ ~r/GRANT\s+[^;]*DELETE[^;]*ON\s+(TABLE\s+)?oauth_clients\s+TO\s+nebu_app/is
    end

    test "a trigger keeps a decided registration from becoming pending again" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      # no column list: the trigger fires on EVERY update (the immutability check needs it)
      assert sql =~ ~r/CREATE\s+TRIGGER\s+oauth_clients_guard_status\s+BEFORE\s+UPDATE\s+ON\s+oauth_clients/i
      assert sql =~ ~r/OLD\.status\s*<>\s*'pending'\s+AND\s+NEW\.status\s*=\s*'pending'/i
    end

    # security review F-3: the database enforces "every registration starts pending" and
    # "approved metadata is immutable" (not only the application).
    test "F-3: the INSERT policy only admits pending rows without any decision data" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      [_, policy] = String.split(sql, "CREATE POLICY oauth_clients_insert ON oauth_clients", parts: 2)
      policy = policy |> String.split(";", parts: 2) |> hd()

      assert policy =~ ~r/status\s*=\s*'pending'/i
      for col <- ~w(approved_by approved_at rejected_by rejected_at),
          do: assert(policy =~ ~r/#{col}\s+IS\s+NULL/i, "INSERT policy must require #{col} IS NULL")
    end

    test "F-3: the guard trigger refuses changes of client_id, metadata, metadata_hash, application_type, token_endpoint_auth_method" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      [_, fun] = String.split(sql, "CREATE OR REPLACE FUNCTION oauth_clients_guard_status", parts: 2)
      fun = fun |> String.split("$$ LANGUAGE", parts: 2) |> hd()

      for col <- ~w(client_id metadata metadata_hash application_type token_endpoint_auth_method client_host),
          do: assert(fun =~ ~r/NEW\.#{col}\s+IS\s+DISTINCT\s+FROM\s+OLD\.#{col}/i, "guard must pin #{col}")
    end

    test "N-3: once decided, the guard trigger pins status and every decision column" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      [_, fun] = String.split(sql, "CREATE OR REPLACE FUNCTION oauth_clients_guard_status", parts: 2)
      fun = fun |> String.split("$$ LANGUAGE", parts: 2) |> hd()

      assert fun =~ ~r/OLD\.status\s*<>\s*'pending'\s+AND\s*\(NEW\.status/i
      for col <- ~w(status approved_by approved_at rejected_by rejected_at),
          do: assert(fun =~ ~r/NEW\.#{col}\b/i and fun =~ ~r/OLD\.#{col}\b/i, "guard must pin #{col}")
    end

    test "F-3: a CHECK ties approved/rejected rows to their *_by/*_at and keeps pending rows clean" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      assert sql =~ ~r/CONSTRAINT\s+oauth_clients_decision_check\s+CHECK/i
      [_, check] = String.split(sql, "oauth_clients_decision_check", parts: 2)
      check = check |> String.split(~r/\n\);/, parts: 2) |> hd()

      for status <- ~w(pending approved rejected), do: assert(check =~ "status = '#{status}'")
      assert check =~ ~r/approved_by\s+IS\s+NOT\s+NULL/i
      assert check =~ ~r/approved_at\s+IS\s+NOT\s+NULL/i
      assert check =~ ~r/rejected_by\s+IS\s+NOT\s+NULL/i
      assert check =~ ~r/rejected_at\s+IS\s+NOT\s+NULL/i
    end

    test "F-1b: a partial index serves the per-host pending cap" do
      sql = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      assert sql =~ ~r/CREATE\s+INDEX[^;]*oauth_clients\s*\(\s*client_host\s*\)\s*WHERE\s+status\s*=\s*'pending'/is
    end

    test "documents #lang handling in a migration comment" do
      sql = read!(@up)
      assert sql =~ ~r/--[^\n]*#lang/i, "migration must document that #lang keys are dropped before hashing"
    end

    test "grants DML on oauth_clients to nebu_app (UpCloud: no ALTER DEFAULT PRIVILEGES)" do
      sql = read!(@up)
      assert sql =~ ~r/GRANT\s+[^;]*SELECT[^;]*INSERT[^;]*UPDATE[^;]*ON\s+(TABLE\s+)?oauth_clients\s+TO\s+nebu_app/is
    end

    test "down migration drops the table and contains no GRANT" do
      down = read!(@down)
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_clients/i
      refute down =~ ~r/GRANT/i
    end

    test "no auto-approval policy artefacts (no dcr_policy column/key; comments ignored)" do
      code = @up |> read!() |> String.replace(~r/--[^\n]*/, "")
      refute code =~ ~r/\bdcr_policy\b|\bauto_approve\w*\b/i
    end
  end

  # test-review m2: `oauth_enabled` is persisted in server_config, which has FORCE ROW LEVEL
  # SECURITY — an UPDATE of a key missing from the `config_update_mutable` allowlist silently
  # affects 0 rows. 000040 must therefore re-create the policy with `oauth_enabled` added
  # (same idiom as 000013/000016/000018/000020; precedent test:
  # server/test/nebu/admin/migration_oidc_scopes_mutable_test.exs).
  describe "AC1/AC2 — migration extends server_config.config_update_mutable with oauth_enabled (static)" do
    @prev_policy_file "000020_admin_temporary_captures.up.sql"

    defp policy_sql(file) do
      sql = file |> read!() |> String.replace(~r/--[^\n]*/, "")
      [_, policy] = String.split(sql, "CREATE POLICY config_update_mutable ON server_config", parts: 2)
      policy |> String.split(";", parts: 2) |> hd()
    end

    test "up drops and recreates config_update_mutable (idempotent) as FOR UPDATE" do
      sql = read!(@up)
      assert sql =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config"
      assert sql =~ "CREATE POLICY config_update_mutable ON server_config"
      assert sql =~ ~r/FOR\s+UPDATE/i
    end

    test "the recreated policy allows 'oauth_enabled'" do
      assert policy_sql(@up) =~ "'oauth_enabled'"
    end

    test "the recreated policy allows the pending TTL and cap keys" do
      assert policy_sql(@up) =~ "'oauth_pending_ttl_days'"
      assert policy_sql(@up) =~ "'oauth_pending_cap'"
      assert policy_sql(@up) =~ "'oauth_pending_host_cap'"
    end

    test "the recreated policy RETAINS every key and LIKE family of the previous policy (000020)" do
      prev = policy_sql(@prev_policy_file)
      new = policy_sql(@up)

      prev_keys = Regex.scan(~r/'([a-z_]+)'/, prev) |> Enum.map(&List.last/1)
      assert length(prev_keys) >= 20, "failed to parse the previous allowlist: #{inspect(prev_keys)}"

      for key <- prev_keys, do: assert(new =~ "'#{key}'", "key #{key} dropped from config_update_mutable")

      prev_likes = Regex.scan(~r/LIKE\s+'[^']+'/, prev) |> Enum.map(&hd/1)
      assert prev_likes != []
      for like <- prev_likes, do: assert(new =~ like, "pattern #{like} dropped from config_update_mutable")
    end

    test "down restores the previous policy WITHOUT oauth_enabled" do
      down = read!(@down)
      refute policy_sql(@down) =~ "oauth_pending"
      refute policy_sql(@down) =~ "oauth_pending_host_cap"
      assert down =~ ~r/DROP\s+FUNCTION\s+IF\s+EXISTS\s+oauth_clients_guard_status/i
      assert down =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config"
      assert down =~ "CREATE POLICY config_update_mutable ON server_config"
      refute policy_sql(@down) =~ "oauth_enabled"
      assert policy_sql(@down) =~ "'log_retention_info_max_count'", "down must restore the 000020 allowlist"
    end
  end

  describe "AC5 — migrated schema (integration)" do
    @describetag :integration

    alias Nebu.OAuth.TestSupport, as: T

    test "all columns exist; metadata is jsonb; status/app-type/auth-method defaults" do
      %{rows: rows} =
        T.sql!(
          "SELECT column_name, data_type, column_default, is_nullable FROM information_schema.columns WHERE table_name = 'oauth_clients'"
        )

      cols = Map.new(rows, fn [n, t, d, nullable] -> {n, {t, d, nullable}} end)
      for c <- @columns, do: assert(Map.has_key?(cols, c), "missing column #{c}")

      assert {"jsonb", _, "NO"} = cols["metadata"]
      assert {_, d, "NO"} = cols["status"]
      assert d =~ "pending"
      assert {_, d, "NO"} = cols["application_type"]
      assert d =~ "web"
      assert {_, d, "NO"} = cols["token_endpoint_auth_method"]
      assert d =~ "none"
      assert {_, _, "NO"} = cols["metadata_hash"]
      assert {_, _, "YES"} = cols["approved_by"]
      assert {_, _, "YES"} = cols["rejected_by"]
      assert {_, _, "YES"} = cols["rejected_at"]
    end

    test "indexes on (status, created_at DESC) and on metadata_hash exist" do
      %{rows: rows} = T.sql!("SELECT indexdef FROM pg_indexes WHERE tablename = 'oauth_clients'")
      defs = Enum.map(rows, fn [d] -> d end)
      assert Enum.any?(defs, &(&1 =~ ~r/\(status, created_at DESC\)/)), "indexes: #{inspect(defs)}"
      assert Enum.any?(defs, &(&1 =~ ~r/\(metadata_hash\)/)), "indexes: #{inspect(defs)}"
    end

    test "no foreign key constraints on oauth_clients" do
      %{rows: [[n]]} =
        T.sql!(
          "SELECT count(*) FROM pg_constraint WHERE conrelid = 'oauth_clients'::regclass AND contype = 'f'"
        )

      assert n == 0
    end

    test "ON CONFLICT (metadata_hash) DO NOTHING is atomic: second insert with the same hash adds no row" do
      hash = "atdd-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      id1 = "atdd-client-" <> hash
      id2 = "atdd-client-other-" <> hash

      on_exit(fn -> T.cleanup_clients([id1, id2]) end)

      insert = """
      INSERT INTO oauth_clients (client_id, metadata, metadata_hash)
      VALUES ($1, '{"client_name":"x"}'::jsonb, $2)
      ON CONFLICT (metadata_hash) DO NOTHING
      """

      assert %{num_rows: 1} = T.sql!(insert, [id1, hash])
      assert %{num_rows: 0} = T.sql!(insert, [id2, hash])
      assert T.count_by_hash(hash) == 1
      row = T.client_row(id1)
      assert row["status"] == "pending"
      assert row["application_type"] == "web"
      assert row["token_endpoint_auth_method"] == "none"
    end

    test "CHECK constraints reject an unknown status and an unknown application_type" do
      id = "atdd-check-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      on_exit(fn -> T.cleanup_clients([id, id <> "-b"]) end)

      # An unknown status can no longer even be INSERTed (the policy admits only 'pending'), so the
      # CHECK is exercised through an UPDATE of a pending row.
      T.sql!("INSERT INTO oauth_clients (client_id, metadata, metadata_hash) VALUES ($1, '{}'::jsonb, $1)", [id])

      assert_raise Postgrex.Error, ~r/oauth_clients_(status|decision)_check/, fn ->
        T.sql!("UPDATE oauth_clients SET status = 'aproved' WHERE client_id = $1", [id])
      end

      assert_raise Postgrex.Error, ~r/row-level security/, fn ->
        T.sql!(
          "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status) VALUES ($1, '{}'::jsonb, $1, 'aproved')",
          [id <> "-x"]
        )
      end

      assert_raise Postgrex.Error, ~r/oauth_clients_application_type_check/, fn ->
        T.sql!(
          "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type) VALUES ($1, '{}'::jsonb, $1, 'desktop')",
          [id <> "-b"]
        )
      end

      # a decided row is created the only way the policy allows: INSERT pending, then UPDATE
      cid = id <> "-pending"
      on_exit(fn -> T.cleanup_clients([cid]) end)

      assert %{num_rows: 1} =
               T.sql!("INSERT INTO oauth_clients (client_id, metadata, metadata_hash) VALUES ($1, '{}'::jsonb, $1)", [cid])

      assert %{num_rows: 1} =
               T.sql!(
                 "UPDATE oauth_clients SET status = 'approved', approved_by = '@a:t', approved_at = NOW() WHERE client_id = $1",
                 [cid]
               )
    end

    # security review F-3 (integration): the database itself enforces the invariants.
    test "F-3: the runtime role cannot INSERT an already decided row (RLS WITH CHECK)" do
      id = "atdd-rls-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      on_exit(fn -> T.cleanup_clients([id <> "-a", id <> "-b", id <> "-c"]) end)

      assert_raise Postgrex.Error, ~r/row-level security|policy/i, fn ->
        T.sql!(
          "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status, approved_by, approved_at) " <>
            "VALUES ($1, '{}'::jsonb, $1, 'approved', '@a:t', NOW())",
          [id <> "-a"]
        )
      end

      # pending but carrying decision data: also refused
      assert_raise Postgrex.Error, ~r/row-level security|policy|oauth_clients_decision_check/i, fn ->
        T.sql!(
          "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, approved_by) VALUES ($1, '{}'::jsonb, $1, '@a:t')",
          [id <> "-b"]
        )
      end

      assert_raise Postgrex.Error, ~r/row-level security|policy|oauth_clients_decision_check/i, fn ->
        T.sql!(
          "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, rejected_at) VALUES ($1, '{}'::jsonb, $1, NOW())",
          [id <> "-c"]
        )
      end
    end

    test "F-3: decided rows must carry their *_by/*_at and pending rows must not (CHECK)" do
      id = "atdd-decision-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      on_exit(fn -> T.cleanup_clients([id]) end)
      T.sql!("INSERT INTO oauth_clients (client_id, metadata, metadata_hash) VALUES ($1, '{}'::jsonb, $1)", [id])

      for sql <- [
            "UPDATE oauth_clients SET status = 'approved' WHERE client_id = $1",
            "UPDATE oauth_clients SET status = 'approved', approved_by = '@a:t' WHERE client_id = $1",
            "UPDATE oauth_clients SET status = 'rejected', rejected_by = '@a:t' WHERE client_id = $1",
            "UPDATE oauth_clients SET status = 'approved', approved_by = '@a:t', approved_at = NOW(), rejected_by = '@a:t' WHERE client_id = $1",
            "UPDATE oauth_clients SET approved_by = '@a:t' WHERE client_id = $1"
          ] do
        assert_raise Postgrex.Error, ~r/oauth_clients_decision_check/, fn -> T.sql!(sql, [id]) end
      end

      assert %{num_rows: 1} =
               T.sql!(
                 "UPDATE oauth_clients SET status = 'rejected', rejected_by = '@a:t', rejected_at = NOW() WHERE client_id = $1",
                 [id]
               )
    end

    test "F-3: client_id, metadata, metadata_hash, application_type and token_endpoint_auth_method are immutable" do
      id = "atdd-immutable-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      on_exit(fn -> T.cleanup_clients([id, id <> "-other"]) end)

      T.sql!(
        "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, client_host) VALUES ($1, '{\"redirect_uris\":[\"https://a.example.com/cb\"]}'::jsonb, $1, 'a.example.com')",
        [id]
      )

      T.sql!(
        "UPDATE oauth_clients SET status = 'approved', approved_by = '@a:t', approved_at = NOW() WHERE client_id = $1",
        [id]
      )

      for set <- [
            "metadata = '{\"redirect_uris\":[\"https://evil.example.org/cb\"]}'::jsonb",
            "metadata_hash = 'other'",
            "client_id = '#{id}-other'",
            "application_type = 'native'",
            "token_endpoint_auth_method = 'client_secret_basic'",
            "client_host = 'evil.example.org'"
          ] do
        assert_raise Postgrex.Error, ~r/immutable|check/i, fn ->
          T.sql!("UPDATE oauth_clients SET #{set} WHERE client_id = $1", [id])
        end
      end

      # ...while the columns of the lifecycle stay writable
      assert %{num_rows: 1} = T.sql!("UPDATE oauth_clients SET last_used_at = NOW() WHERE client_id = $1", [id])

      assert %{rows: [[%{"redirect_uris" => ["https://a.example.com/cb"]}]]} =
               T.sql!("SELECT metadata FROM oauth_clients WHERE client_id = $1", [id])
    end

    # security review N-3: the database makes a decision FINAL, not only the application.
    test "N-3: a decided registration cannot be flipped, re-attributed or turned pending again" do
      approved = "atdd-final-a-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      rejected = "atdd-final-r-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      on_exit(fn -> T.cleanup_clients([approved, rejected]) end)

      for id <- [approved, rejected] do
        T.sql!(
          "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, client_host, created_from_ip, user_agent) VALUES ($1, '{}'::jsonb, $1, 'a.example.com', '203.0.113.7', 'UA')",
          [id]
        )
      end

      T.sql!(
        "UPDATE oauth_clients SET status = 'approved', approved_by = '@a:t', approved_at = NOW(), created_from_ip = NULL, user_agent = NULL WHERE client_id = $1",
        [approved]
      )

      T.sql!(
        "UPDATE oauth_clients SET status = 'rejected', rejected_by = '@a:t', rejected_at = NOW() WHERE client_id = $1",
        [rejected]
      )

      refused = [
        {rejected,
         "status = 'approved', approved_by = '@evil:t', approved_at = NOW(), rejected_by = NULL, rejected_at = NULL"},
        {approved,
         "status = 'rejected', rejected_by = '@evil:t', rejected_at = NOW(), approved_by = NULL, approved_at = NULL"},
        {approved, "approved_by = '@evil:t'"},
        {approved, "approved_at = NOW() + interval '1 day'"},
        {rejected, "rejected_by = '@evil:t'"},
        {rejected, "rejected_at = NOW() + interval '1 day'"},
        {approved, "status = 'pending', approved_by = NULL, approved_at = NULL"},
        {rejected, "status = 'pending', rejected_by = NULL, rejected_at = NULL"}
      ]

      for {id, set} <- refused do
        assert_raise Postgrex.Error, ~r/final|pending again|check/i, fn ->
          T.sql!("UPDATE oauth_clients SET #{set} WHERE client_id = $1", [id])
        end
      end

      assert %{rows: [["approved", "@a:t"]]} =
               T.sql!("SELECT status, approved_by FROM oauth_clients WHERE client_id = $1", [approved])

      assert %{rows: [["rejected", "@a:t"]]} =
               T.sql!("SELECT status, rejected_by FROM oauth_clients WHERE client_id = $1", [rejected])

      # ...while last_used_at and the NULLing of the triage data stay possible on a decided row
      assert %{num_rows: 1} = T.sql!("UPDATE oauth_clients SET last_used_at = NOW() WHERE client_id = $1", [approved])

      assert %{num_rows: 1} =
               T.sql!("UPDATE oauth_clients SET created_from_ip = NULL, user_agent = NULL WHERE client_id = $1", [rejected])
    end

    test "F-1b: client_host column and the partial pending-host index exist" do
      %{rows: rows} = T.sql!("SELECT indexdef FROM pg_indexes WHERE tablename = 'oauth_clients'")
      assert Enum.any?(rows, fn [d] -> d =~ ~r/\(client_host\) WHERE \(status = 'pending'/ end), "indexes: #{inspect(rows)}"
    end

    test "a plain duplicate metadata_hash insert violates the UNIQUE constraint" do
      hash = "atdd-uniq-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      ids = ["atdd-u1-" <> hash, "atdd-u2-" <> hash]
      on_exit(fn -> T.cleanup_clients(ids) end)

      ins = "INSERT INTO oauth_clients (client_id, metadata, metadata_hash) VALUES ($1, '{}'::jsonb, $2)"
      T.sql!(ins, [Enum.at(ids, 0), hash])
      assert_raise Postgrex.Error, ~r/unique|duplicate/i, fn -> T.sql!(ins, [Enum.at(ids, 1), hash]) end
    end

    test "the runtime role can UPDATE server_config.oauth_enabled (config_update_mutable allows the key)" do
      prior = T.sql!("SELECT value FROM server_config WHERE key = 'oauth_enabled'").rows

      T.sql!(
        "INSERT INTO server_config (key, value, set_at) VALUES ('oauth_enabled', 'false', 0) ON CONFLICT (key) DO NOTHING"
      )

      on_exit(fn ->
        value =
          case prior do
            [[v]] -> v
            _ -> "false"
          end

        T.sql!("UPDATE server_config SET value = $1 WHERE key = 'oauth_enabled'", [value])
      end)

      # RLS silently turns a disallowed UPDATE into a 0-row no-op, so assert the row count AND the value.
      assert %{num_rows: 1} = T.sql!("UPDATE server_config SET value = 'true', set_at = 1 WHERE key = 'oauth_enabled'")
      assert %{rows: [["true"]]} = T.sql!("SELECT value FROM server_config WHERE key = 'oauth_enabled'")
      assert %{num_rows: 1} = T.sql!("UPDATE server_config SET value = 'false', set_at = 2 WHERE key = 'oauth_enabled'")
      assert %{rows: [["false"]]} = T.sql!("SELECT value FROM server_config WHERE key = 'oauth_enabled'")
    end

    test "the runtime role can UPDATE the pending TTL / cap / host-cap server_config keys" do
      for key <- ~w(oauth_pending_ttl_days oauth_pending_cap oauth_pending_host_cap) do
        prior = T.sql!("SELECT value FROM server_config WHERE key = $1", [key]).rows

        T.sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, '30', 0) ON CONFLICT (key) DO NOTHING", [key])

        on_exit(fn ->
          value = case prior do [[v]] -> v; _ -> "30" end
          T.sql!("UPDATE server_config SET value = $2 WHERE key = $1", [key, value])
        end)

        assert %{num_rows: 1} = T.sql!("UPDATE server_config SET value = '42', set_at = 1 WHERE key = $1", [key])
        assert %{rows: [["42"]]} = T.sql!("SELECT value FROM server_config WHERE key = $1", [key])
      end
    end

    test "row level security is enabled AND forced; only the pending delete policy exists for DELETE" do
      assert %{rows: [[true, true]]} =
               T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'oauth_clients'::regclass")

      %{rows: rows} =
        T.sql!("SELECT cmd, qual FROM pg_policies WHERE tablename = 'oauth_clients' ORDER BY cmd")

      deletes = for [cmd, qual] <- rows, cmd == "DELETE", do: qual
      assert [qual] = deletes
      assert qual =~ "pending"
      for cmd <- ~w(SELECT INSERT UPDATE), do: assert(Enum.any?(rows, fn [c, _] -> c == cmd end), "policy for #{cmd} missing")
    end

    test "the runtime role can SELECT/INSERT/UPDATE oauth_clients (grants applied)" do
      id = "atdd-grant-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      on_exit(fn -> T.cleanup_clients([id]) end)

      T.sql!("INSERT INTO oauth_clients (client_id, metadata, metadata_hash) VALUES ($1, '{}'::jsonb, $1)", [id])
      T.sql!(
        "UPDATE oauth_clients SET status = 'approved', approved_by = '@a:t', approved_at = NOW() WHERE client_id = $1",
        [id]
      )

      assert T.client_row(id)["status"] == "approved"
    end
  end
end
