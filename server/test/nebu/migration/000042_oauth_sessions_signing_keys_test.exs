defmodule Nebu.Migration.Migration000042OauthSessionsSigningKeysTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint`, AC14 / Must #32: migration
  `000042_oauth_sessions_and_signing_keys` (`matrix_sessions` gains `auth_api`, `client_id`,
  `scope`, `session_expires_at`, `oauth_code_hash`; new table `oauth_signing_keys`; the
  `config_update_mutable` allowlist gains `oauth_access_token_ttl_seconds` /
  `oauth_idp_revalidation`).

  Mirrors `000041_oauth_authz_codes_test.exs`:
    * static SQL-file analysis (no DB)
    * `:integration` introspection + behaviour as the RUNTIME role (`nebu_app`): CHECKs, FK
      RESTRICT (privileged delete of a client with a session fails), indexes, RLS inventory,
      allowlist (every 000040 key still updatable), and a down/up round trip on the privileged
      role inside a rolled-back transaction.

  The runtime-role behaviour of `oauth_signing_keys` (no DELETE, immutable key material, no
  re-activation) is in `server/test/nebu/oauth/oauth_signing_keys_test.exs`.

  Red today: the files do not exist (000040/000041 are committed and must stay untouched).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000042_oauth_sessions_and_signing_keys.up.sql"
  @down "000042_oauth_sessions_and_signing_keys.down.sql"
  @m40 "000040_oauth_clients_and_auth_metadata.up.sql"

  @session_cols ~w(auth_api client_id scope session_expires_at oauth_code_hash)
  @key_cols ~w(kid alg public_jwk private_jwk_enc status created_at retired_at not_after)
  @new_keys ~w(oauth_access_token_ttl_seconds oauth_idp_revalidation)

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp table_sql(sql, table) do
    [_, rest] = Regex.split(~r/CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?#{table}\s*\(/i, sql, parts: 2)
    rest |> String.split(~r/\n\);/, parts: 2) |> hd()
  end

  defp policy_sql(file) do
    sql = code_sql(file)
    [_, policy] = String.split(sql, "CREATE POLICY config_update_mutable ON server_config", parts: 2)
    policy |> String.split(";", parts: 2) |> hd()
  end

  defp keys_of(policy), do: Regex.scan(~r/'([a-z_]+)'/, policy) |> Enum.map(&List.last/1)
  defp likes_of(policy), do: Regex.scan(~r/LIKE\s+'[^']+'/, policy) |> Enum.map(&hd/1)

  # ════════════════════════════════════════════════════════════════════════════
  # static
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14 — migration files (static)" do
    test "up and down exist as the next free number; exactly one 000042; 000040/000041 still there" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000042_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000042 migration"
      assert File.exists?(Path.join(@dir, @m40))
      assert File.exists?(Path.join(@dir, "000041_oauth_authz_requests_and_codes.up.sql"))
    end

    test "000040 and 000041 are untouched by this story (no auth_api / oauth_signing_keys mention)" do
      for f <- [@m40, "000040_oauth_clients_and_auth_metadata.down.sql", "000041_oauth_authz_requests_and_codes.up.sql",
                "000041_oauth_authz_requests_and_codes.down.sql"] do
        refute read!(f) =~ ~r/auth_api|oauth_signing_keys|session_expires_at/, "#{f} must not be edited (new migration instead)"
      end
    end

    test "matrix_sessions gains the five columns with the specified types and FK ON DELETE RESTRICT" do
      sql = code_sql(@up)
      assert sql =~ ~r/ALTER\s+TABLE\s+matrix_sessions/i
      assert sql =~ ~r/ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?auth_api\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'legacy'/i
      assert sql =~ ~r/ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?client_id\s+TEXT\s+REFERENCES\s+oauth_clients\s*\(\s*client_id\s*\)\s+ON\s+DELETE\s+RESTRICT/i
      assert sql =~ ~r/ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?scope\s+TEXT/i
      assert sql =~ ~r/ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?session_expires_at\s+TIMESTAMPTZ/i
      assert sql =~ ~r/ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?oauth_code_hash\s+TEXT/i
      refute sql =~ ~r/ADD\s+COLUMN\s+(IF\s+NOT\s+EXISTS\s+)?(access_token|refresh_token)\s+TEXT/i, "no plaintext token column"
    end

    test "named CHECKs matrix_sessions_auth_api_check and matrix_sessions_oauth_shape_check" do
      sql = code_sql(@up)

      assert sql =~
               ~r/CONSTRAINT\s+matrix_sessions_auth_api_check\s+CHECK\s*\(\s*auth_api\s+IN\s*\(\s*'legacy'\s*,\s*'oauth'\s*\)\s*\)/i

      assert [_, shape] = Regex.run(~r/CONSTRAINT\s+matrix_sessions_oauth_shape_check\s+CHECK\s*\((.*?)\)\s*;/is, sql),
             "named CHECK matrix_sessions_oauth_shape_check missing"

      for c <- ~w(client_id scope session_expires_at oauth_code_hash), do: assert(shape =~ c, "shape CHECK must constrain #{c}")
      assert shape =~ ~r/auth_api\s*=\s*'legacy'/i
      assert shape =~ ~r/auth_api\s*=\s*'oauth'/i
      assert shape =~ ~r/expires_at\s*<=\s*session_expires_at/i
    end

    test "indexes: (user_id, device_id) and the partial oauth_code_hash index" do
      sql = code_sql(@up)
      assert sql =~ ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?idx_matrix_sessions_user_device\s+ON\s+matrix_sessions\s*\(\s*user_id\s*,\s*device_id\s*\)/i

      assert sql =~
               ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?idx_matrix_sessions_oauth_code_hash\s+ON\s+matrix_sessions\s*\(\s*oauth_code_hash\s*\)\s+WHERE\s+oauth_code_hash\s+IS\s+NOT\s+NULL/i
    end

    test "review cycle 1: partial index on matrix_sessions(client_id) for the FK RESTRICT lookups; down drops it" do
      assert code_sql(@up) =~
               ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?idx_matrix_sessions_client_id\s+ON\s+matrix_sessions\s*\(\s*client_id\s*\)\s+WHERE\s+client_id\s+IS\s+NOT\s+NULL/i

      assert code_sql(@down) =~ ~r/DROP\s+INDEX\s+(IF\s+EXISTS\s+)?idx_matrix_sessions_client_id/i
    end

    test "oauth_signing_keys: columns, kid PK, alg CHECK ES256, status CHECK, retired CHECK, one-active partial unique index" do
      t = table_sql(code_sql(@up), "oauth_signing_keys")
      for c <- @key_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/kid\s+TEXT\s+PRIMARY\s+KEY/i
      assert t =~ ~r/alg\s+TEXT\s+NOT\s+NULL\s+CHECK\s*\(\s*alg\s*=\s*'ES256'\s*\)/i
      assert t =~ ~r/public_jwk\s+JSONB\s+NOT\s+NULL/i
      assert t =~ ~r/private_jwk_enc\s+TEXT\s+NOT\s+NULL/i
      assert t =~ ~r/status\s+TEXT\s+NOT\s+NULL\s+DEFAULT\s+'active'\s+CHECK\s*\(\s*status\s+IN\s*\(\s*'active'\s*,\s*'retired'\s*\)\s*\)/i
      assert t =~ ~r/CONSTRAINT\s+oauth_signing_keys_retired_check\s+CHECK/i
      refute t =~ ~r/private_jwk\s+(JSONB|TEXT)/i, "no plaintext private key column"

      assert code_sql(@up) =~
               ~r/CREATE\s+UNIQUE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_signing_keys_one_active\s+ON\s+oauth_signing_keys\s*\(\s*status\s*\)\s+WHERE\s+status\s*=\s*'active'/i
    end

    test "grant SELECT, INSERT, UPDATE on oauth_signing_keys to nebu_app (no DELETE, no ALL)" do
      sql = code_sql(@up)

      grant =
        (Regex.run(~r/GRANT\s+[^;]*ON\s+(TABLE\s+)?oauth_signing_keys\s+TO\s+nebu_app/is, sql) || [nil]) |> hd() ||
          flunk("GRANT ... ON oauth_signing_keys TO nebu_app missing")

      for p <- ~w(SELECT INSERT UPDATE), do: assert(grant =~ p)
      refute grant =~ ~r/DELETE|\bALL\b/i, "the runtime role must not delete keys"
    end

    test "RLS enabled AND forced; policies SELECT, INSERT (only fresh active rows), UPDATE; NO DELETE policy" do
      sql = code_sql(@up)
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_signing_keys\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_signing_keys\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i

      on = fn cmd -> Regex.scan(~r/CREATE\s+POLICY\s+\w+\s+ON\s+oauth_signing_keys\s+FOR\s+#{cmd}\b[^;]*/i, sql) |> Enum.map(&hd/1) end
      assert [_] = on.("SELECT")
      assert [ins] = on.("INSERT")
      assert ins =~ ~r/WITH\s+CHECK\s*\(\s*status\s*=\s*'active'\s+AND\s+retired_at\s+IS\s+NULL\s+AND\s+not_after\s+IS\s+NULL\s*\)/i
      assert [_] = on.("UPDATE")
      assert on.("DELETE") == [], "no DELETE policy"
      assert on.("ALL") == []
    end

    test "guard trigger oauth_signing_keys_guard BEFORE UPDATE: key material immutable, no retired -> active, retired_at required, not_after only raised" do
      sql = code_sql(@up)
      assert sql =~ ~r/CREATE\s+TRIGGER\s+oauth_signing_keys_guard\s+BEFORE\s+UPDATE\s+ON\s+oauth_signing_keys/i
      assert [_, fun] = Regex.split(~r/CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+\w*oauth_signing_keys_guard\w*/i, sql, parts: 2)
      fun = fun |> String.split(~r/\$\$\s+LANGUAGE/i, parts: 2) |> hd()
      for c <- ~w(kid alg public_jwk private_jwk_enc created_at not_after retired_at), do: assert(fun =~ ~r/\b#{c}\b/, "guard must check #{c}")
      assert fun =~ ~r/'retired'/ and fun =~ ~r/'active'/
    end

    test "config_update_mutable is re-created with 000040's key list and LIKE families VERBATIM plus the two token keys" do
      sql = code_sql(@up)
      assert sql =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config"
      assert sql =~ "CREATE POLICY config_update_mutable ON server_config"

      prev = policy_sql(@m40)
      new = policy_sql(@up)
      prev_keys = keys_of(prev)
      assert length(prev_keys) >= 25, "failed to parse the 000040 allowlist"
      for k <- prev_keys, do: assert(new =~ "'#{k}'", "key #{k} dropped from config_update_mutable (Trap 15)")
      for l <- likes_of(prev), do: assert(new =~ l, "pattern #{l} dropped from config_update_mutable")
      for k <- @new_keys, do: assert(new =~ "'#{k}'", "new key #{k} missing")
      assert new =~ ~r/FOR\s+UPDATE/i
    end

    test "no server_config values are inserted (absent keys => defaults, T4/T5)" do
      refute code_sql(@up) =~ ~r/INSERT\s+INTO\s+server_config/i
    end

    test "header comment documents T2/T3/T8/T17/T18 and the rolling-deploy safety" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      for t <- ~w(T2 T3 T8 T17 T18), do: assert(header =~ ~r/\b#{t}\b/, "header must reference #{t}")
      assert header =~ ~r/rolling/i, "header must state the rolling-deploy safety (DEFAULT legacy, no stop-the-world)"
    end

    test "both files are transaction-safe: no BEGIN/COMMIT, no CONCURRENTLY" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im, "#{f} must not manage transactions"
        refute sql =~ ~r/CONCURRENTLY/i, "#{f} must not use CONCURRENTLY"
      end
    end

    test "down restores 000040's policy, drops keys table + trigger function, deletes oauth rows, drops columns; never touches oauth_clients rows" do
      down = code_sql(@down)
      assert down =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config"
      assert down =~ "CREATE POLICY config_update_mutable ON server_config"
      restored = policy_sql(@down)
      assert Enum.sort(keys_of(restored)) == Enum.sort(keys_of(policy_sql(@m40))), "down restores 000040's key list exactly"
      for k <- @new_keys, do: refute(restored =~ k)

      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_signing_keys/i
      assert down =~ ~r/DROP\s+FUNCTION\s+(IF\s+EXISTS\s+)?\w*oauth_signing_keys_guard/i
      assert down =~ ~r/DELETE\s+FROM\s+matrix_sessions\s+WHERE\s+auth_api\s*=\s*'oauth'/i
      for c <- @session_cols, do: assert(down =~ ~r/DROP\s+COLUMN\s+(IF\s+EXISTS\s+)?#{c}\b/i, "down must drop #{c}")
      for i <- ~w(idx_matrix_sessions_user_device idx_matrix_sessions_oauth_code_hash idx_matrix_sessions_client_id), do: assert(down =~ i)
      for c <- ~w(matrix_sessions_auth_api_check matrix_sessions_oauth_shape_check), do: assert(down =~ c)
      refute down =~ ~r/(DELETE\s+FROM|UPDATE)\s+oauth_clients/i, "down must not touch oauth_clients rows"
      refute down =~ ~r/GRANT/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # integration: migrated schema + runtime-role behaviour
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14 — migrated schema (integration, runtime role)" do
    @describetag :integration

    setup do
      uid = "@atdd-m42-#{T.rand()}:test.local"
      on_exit(fn -> T.sql!("DELETE FROM matrix_sessions WHERE user_id = $1", [uid]) end)
      {:ok, cid: T.oauth_client!(["https://app.example.com/cb"]), uid: uid}
    end

    defp oauth_insert(uid, cid, opts \\ []) do
      session_exp = Keyword.get(opts, :session_expires_at, "now() + interval '8 hours'")
      exp = Keyword.get(opts, :expires_at, "now() + interval '15 minutes'")
      api = Keyword.get(opts, :auth_api, "oauth")
      scope = Keyword.get(opts, :scope, "'urn:matrix:client:api:* urn:matrix:client:device:D'")

      T.sql!(
        "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, user_id, device_id, expires_at, auth_api, client_id, " <>
          "scope, session_expires_at, oauth_code_hash, created_at) VALUES ($1, $2, $3, 'D', #{exp}, '#{api}', $4, #{scope}, " <>
          "#{session_exp}, $5, now())",
        [T.rand(32), T.rand(32), uid, cid, T.rand(32)]
      )
    end

    test "new columns, types and defaults; a legacy MatrixSessionStore.create row is 'legacy' with NULL OAuth columns", %{uid: uid} do
      %{rows: rows} =
        T.sql!("SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = 'matrix_sessions'")

      got = Map.new(rows, fn [n, t, nul, d] -> {n, {t, nul, d}} end)
      for c <- @session_cols, do: assert(Map.has_key?(got, c), "matrix_sessions.#{c} missing")
      assert {"text", "NO", default} = got["auth_api"]
      assert default =~ "legacy"
      assert {"timestamp with time zone", "YES", _} = got["session_expires_at"]
      for c <- ~w(client_id scope oauth_code_hash), do: assert({"text", "YES", _} = got[c])

      %{at: at} = T.legacy_session!(uid, "LEGACYDEV")

      assert %{rows: [["legacy", nil, nil, nil, nil]]} =
               T.sql!(
                 "SELECT auth_api, client_id, scope, session_expires_at, oauth_code_hash FROM matrix_sessions WHERE access_token_hash = $1",
                 [T.token_hash(at)]
               )
    end

    test "a valid oauth row is accepted", %{uid: uid, cid: cid} do
      assert %{num_rows: 1} = oauth_insert(uid, cid)
    end

    test "CHECKs: unknown auth_api, legacy row with client_id, oauth row without session_expires_at / scope, expires_at > session_expires_at", %{uid: uid, cid: cid} do
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> oauth_insert(uid, cid, auth_api: "other") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> oauth_insert(uid, cid, auth_api: "legacy") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> oauth_insert(uid, cid, session_expires_at: "NULL") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> oauth_insert(uid, cid, scope: "NULL") end

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        oauth_insert(uid, cid, expires_at: "now() + interval '9 hours'", session_expires_at: "now() + interval '8 hours'")
      end

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!(
          "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, user_id, device_id, expires_at, auth_api, created_at) " <>
            "VALUES ($1, $2, $3, 'D', now() + interval '1 hour', 'oauth', now())",
          [T.rand(32), T.rand(32), uid]
        )
      end
    end

    test "FK: an oauth row for an unknown client is refused", %{uid: uid} do
      assert_raise Postgrex.Error, ~r/foreign key/i, fn -> oauth_insert(uid, "no-such-client-" <> T.rand()) end
    end

    test "FK ON DELETE RESTRICT: the privileged role cannot delete an approved client with a session; cleanup (sessions first) works", %{uid: uid} do
      other = T.oauth_client!(["https://app.example.com/cb"])
      oauth_insert(uid, other)

      assert_raise Postgrex.Error, ~r/foreign key/i, fn ->
        T.privileged_sql!("DELETE FROM oauth_clients WHERE client_id = $1", [other])
      end

      assert :ok = T.cleanup_clients([other])
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM matrix_sessions WHERE client_id = $1", [other])
    end

    test "indexes exist" do
      %{rows: rows} = T.sql!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'matrix_sessions'")
      names = Enum.map(rows, &hd/1)
      assert "idx_matrix_sessions_user_device" in names
      assert "idx_matrix_sessions_oauth_code_hash" in names
      assert "idx_matrix_sessions_client_id" in names

      %{rows: krows} = T.sql!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'oauth_signing_keys'")
      assert Enum.any?(krows, fn [n, d] -> n == "oauth_signing_keys_one_active" and d =~ ~r/UNIQUE/ and d =~ ~r/WHERE/ end)
    end

    test "oauth_signing_keys: RLS enabled + forced; policies SELECT/INSERT/UPDATE only" do
      assert %{rows: [[true, true]]} =
               T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'oauth_signing_keys'")

      %{rows: cmds} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = 'oauth_signing_keys'")
      assert cmds |> List.flatten() |> Enum.sort() == ~w(INSERT SELECT UPDATE)
    end

    test "allowlist: the runtime role can UPDATE the two new keys (1 row each)" do
      for key <- @new_keys, do: assert_updatable!(key, "900")
    end

    test "allowlist: EVERY 000040 key and LIKE family is still updatable (Trap 15)" do
      keys = keys_of(policy_sql(@m40))
      for key <- keys, do: assert_updatable!(key, "probe")
      for probe <- ["log_min_level_atddprobe", "log_retention_days_atddprobe"], do: assert_updatable!(probe, "1")
    end

    # Inserts a probe row if the key is absent (removed again with the privileged role), then proves
    # an UPDATE matches 1 row WITHOUT changing an existing value (`value = value`).
    defp assert_updatable!(key, probe_value) do
      absent? = T.sql!("SELECT 1 FROM server_config WHERE key = $1", [key]).num_rows == 0

      if absent? do
        T.sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, 0)", [key, probe_value])
      end

      try do
        n = T.sql!("UPDATE server_config SET value = value WHERE key = $1", [key]).num_rows

        assert n == 1,
               "UPDATE of server_config key #{key} is a silent no-op (missing from config_update_mutable)"
      after
        if absent?, do: T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [key])
      end
    end

    test "down/up round trip (privileged role, rolled back): down removes the columns, the keys table and the new keys; up restores them" do
      down = read!(@down)
      up = read!(@up)

      probe = fn tx ->
        %{rows: [[cols]]} =
          Postgrex.query!(
            tx,
            "SELECT count(*) FROM information_schema.columns WHERE table_name = 'matrix_sessions' AND column_name = ANY($1)",
            [@session_cols]
          )

        %{rows: [[keys_table]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_signing_keys')::text", [])
        %{rows: [[qual]]} = Postgrex.query!(tx, "SELECT qual FROM pg_policies WHERE policyname = 'config_update_mutable'", [])
        %{rows: [[guard]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_proc WHERE proname LIKE '%oauth_signing_keys_guard%'", [])
        {cols, keys_table, Enum.all?(@new_keys, &String.contains?(qual, &1)), String.contains?(qual, "oauth_pending_host_cap"), guard}
      end

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, down, [], query_type: :text)
            after_down = probe.(tx)
            %{rows: [[clients]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_clients')::text", [])
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up = probe.(tx)
            Postgrex.rollback(tx, {:round_trip, after_down, clients, after_up})
          end)
        end)

      assert {:error, {:round_trip, after_down, clients, after_up}} = result
      assert after_down == {0, nil, false, true, 0}, "after down: no columns, no table, 000040 policy, no guard function"
      assert clients == "oauth_clients", "down must not drop oauth_clients"
      assert after_up == {length(@session_cols), "oauth_signing_keys", true, true, 1}
    end
  end
end
