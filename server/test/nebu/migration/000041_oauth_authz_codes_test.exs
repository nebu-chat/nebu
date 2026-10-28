defmodule Nebu.Migration.Migration000041OauthAuthzCodesTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC10: migration
  `000041_oauth_authz_requests_and_codes` (`oauth_authz_requests`, `oauth_codes`).

  Mirrors `000040_oauth_clients_test.exs`:
    * static SQL-file analysis (no DB): columns, PK/FK, CHECKs, indexes, grants, RLS + policies,
      guard trigger, down migration
    * `:integration` introspection + behaviour as the RUNTIME role (`nebu_app`): CHECKs, RLS
      (authz rows not updatable, unexpired codes not deletable, used codes can never be unused),
      FK cascade, and a down/up round trip on the privileged role inside a rolled-back transaction.

  Red today: the files do not exist (000040 is committed and must stay untouched).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000041_oauth_authz_requests_and_codes.up.sql"
  @down "000041_oauth_authz_requests_and_codes.down.sql"

  @authz_cols ~w(state_hash client_id redirect_uri code_challenge device_id scope scope_prefix response_mode
                 client_state client_nonce openid_requested idp_code_verifier_enc idp_nonce browser_binding_hash
                 created_at expires_at)
  @code_cols ~w(code_hash client_id redirect_uri code_challenge device_id user_id scope scope_prefix response_mode
                client_nonce openid_requested idp_rt_enc auth_time created_at expires_at used_at)

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp table_sql(sql, table) do
    [_, rest] = Regex.split(~r/CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?#{table}\s*\(/i, sql, parts: 2)
    rest |> String.split(~r/\n\);/, parts: 2) |> hd()
  end

  describe "AC10 — migration files (static)" do
    test "up and down exist as the next free number after 000040; 000040 is still there" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert File.exists?(Path.join(@dir, "000040_oauth_clients_and_auth_metadata.up.sql"))
      assert Path.wildcard(Path.join(@dir, "000041_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000041 migration"
    end

    test "oauth_authz_requests has every column; state_hash PK; client_id FK ON DELETE CASCADE" do
      t = table_sql(code_sql(@up), "oauth_authz_requests")
      for c <- @authz_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/state_hash\s+TEXT\s+PRIMARY\s+KEY/i
      assert t =~ ~r/client_id\s+TEXT\s+NOT\s+NULL\s+REFERENCES\s+oauth_clients\s*\(\s*client_id\s*\)\s+ON\s+DELETE\s+CASCADE/i
      assert t =~ ~r/openid_requested\s+BOOLEAN\s+NOT\s+NULL\s+DEFAULT\s+false/i
      assert t =~ ~r/client_nonce\s+TEXT\s*,/i, "client_nonce nullable TEXT (D23)"
      assert t =~ ~r/client_state\s+TEXT\s*,/i
      assert t =~ ~r/expires_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      refute t =~ ~r/\bused_at\b/, "authz rows are consumed by DELETE, not marked"
    end

    test "oauth_codes has every column; code_hash PK; client_id FK ON DELETE CASCADE; nullable idp_rt_enc/auth_time/used_at" do
      t = table_sql(code_sql(@up), "oauth_codes")
      for c <- @code_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/code_hash\s+TEXT\s+PRIMARY\s+KEY/i
      assert t =~ ~r/client_id\s+TEXT\s+NOT\s+NULL\s+REFERENCES\s+oauth_clients\s*\(\s*client_id\s*\)\s+ON\s+DELETE\s+CASCADE/i
      assert t =~ ~r/openid_requested\s+BOOLEAN\s+NOT\s+NULL\s+DEFAULT\s+false/i
      for c <- ~w(idp_rt_enc client_nonce), do: assert(t =~ ~r/#{c}\s+TEXT\s*,/i, "#{c} nullable TEXT")
      assert t =~ ~r/auth_time\s+TIMESTAMPTZ\s*,/i
      assert t =~ ~r/used_at\s+TIMESTAMPTZ\s*(,|\z)/i
      refute t =~ ~r/\bcode\s+TEXT/i, "no plaintext code column (only code_hash)"
    end

    test "named CHECKs: scope_prefix and response_mode closed sets on both tables, TTL bounds" do
      sql = code_sql(@up)
      # inline in CREATE TABLE or via ALTER TABLE ... ADD CONSTRAINT: both are fine, but NAMED
      prefix =
        ~r/CONSTRAINT\s+\w+\s+CHECK\s*\(\s*scope_prefix\s+IN\s*\(\s*'urn:matrix:client:'\s*,\s*'urn:matrix:org\.matrix\.msc2967\.client:'\s*\)\s*\)/i

      mode = ~r/CONSTRAINT\s+\w+\s+CHECK\s*\(\s*response_mode\s+IN\s*\(\s*'query'\s*,\s*'fragment'\s*\)\s*\)/i
      assert length(Regex.scan(prefix, sql)) == 2, "one named scope_prefix CHECK per table"
      assert length(Regex.scan(mode, sql)) == 2, "one named response_mode CHECK per table"
      assert sql =~ ~r/CONSTRAINT\s+\w+\s+CHECK\s*\(\s*expires_at\s*<=\s*created_at\s*\+\s*interval\s+'10 minutes'\s*\)/i
      assert sql =~ ~r/CONSTRAINT\s+\w+\s+CHECK\s*\(\s*expires_at\s*<=\s*created_at\s*\+\s*interval\s+'60 seconds'\s*\)/i
    end

    test "indexes on expires_at of both tables" do
      sql = code_sql(@up)
      assert sql =~ ~r/CREATE\s+INDEX[^;]*ON\s+oauth_authz_requests\s*\(\s*expires_at\s*\)/is
      assert sql =~ ~r/CREATE\s+INDEX[^;]*ON\s+oauth_codes\s*\(\s*expires_at\s*\)/is
    end

    test "grants: authz SELECT/INSERT/DELETE only (no UPDATE); codes SELECT/INSERT/UPDATE/DELETE" do
      sql = code_sql(@up)
      authz_grant =
        (Regex.run(~r/GRANT\s+[^;]*ON\s+(TABLE\s+)?oauth_authz_requests\s+TO\s+nebu_app/is, sql) || [nil]) |> hd() ||
          flunk("GRANT ... ON oauth_authz_requests TO nebu_app missing")

      for p <- ~w(SELECT INSERT DELETE), do: assert(authz_grant =~ p)
      refute authz_grant =~ ~r/UPDATE|ALL/i, "oauth_authz_requests must not be updatable (consumed by DELETE)"

      code_grant =
        (Regex.run(~r/GRANT\s+[^;]*ON\s+(TABLE\s+)?oauth_codes\s+TO\s+nebu_app/is, sql) || [nil]) |> hd() ||
          flunk("GRANT ... ON oauth_codes TO nebu_app missing")

      for p <- ~w(SELECT INSERT UPDATE DELETE), do: assert(code_grant =~ p)
    end

    test "RLS enabled AND forced on both tables" do
      sql = code_sql(@up)

      for t <- ~w(oauth_authz_requests oauth_codes) do
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i
      end
    end

    test "policies: authz SELECT/INSERT/DELETE true, NO UPDATE policy; codes INSERT only unused, DELETE only 24 h after expiry" do
      sql = code_sql(@up)
      on = fn t, cmd -> Regex.scan(~r/CREATE\s+POLICY\s+\w+\s+ON\s+#{t}\s+FOR\s+#{cmd}\b[^;]*/i, sql) |> Enum.map(&hd/1) end

      for cmd <- ~w(SELECT INSERT DELETE), do: assert([_] = on.("oauth_authz_requests", cmd), "authz #{cmd} policy")
      assert on.("oauth_authz_requests", "UPDATE") == [], "no UPDATE policy on oauth_authz_requests"
      assert on.("oauth_authz_requests", "ALL") == []

      assert [ins] = on.("oauth_codes", "INSERT")
      assert ins =~ ~r/WITH\s+CHECK\s*\(\s*used_at\s+IS\s+NULL\s*\)/i
      assert [_] = on.("oauth_codes", "UPDATE")
      assert [_] = on.("oauth_codes", "SELECT")
      assert [del] = on.("oauth_codes", "DELETE")
      assert del =~ ~r/USING\s*\(\s*expires_at\s*<\s*now\(\)\s*-\s*interval\s+'24 hours'\s*\)/i
      assert on.("oauth_codes", "ALL") == []
    end

    test "guard trigger oauth_codes_guard BEFORE UPDATE; used_at only NULL -> NOT NULL (behaviour: integration block)" do
      sql = code_sql(@up)
      assert sql =~ ~r/CREATE\s+TRIGGER\s+oauth_codes_guard\s+BEFORE\s+UPDATE\s+ON\s+oauth_codes/i
      assert [_, fun] = Regex.split(~r/CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+\w*oauth_codes_guard\w*/i, sql, parts: 2)
      fun = fun |> String.split(~r/\$\$\s+LANGUAGE/i, parts: 2) |> hd()
      assert fun =~ ~r/OLD\.used_at\s+IS\s+NULL/i
      assert fun =~ ~r/NEW\.used_at\s+IS\s+NOT\s+NULL/i
    end

    test "header comment documents D2/D3/D16/D17 and the FK cascade only ever firing for purged PENDING clients" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      for d <- ~w(D2 D3 D16 D17), do: assert(header =~ d, "header must reference #{d}")
      assert header =~ ~r/cascade/i
      assert header =~ ~r/pending/i
    end

    test "down drops both tables and the trigger function, no GRANT" do
      down = code_sql(@down)
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_codes/i
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_authz_requests/i
      assert down =~ ~r/DROP\s+FUNCTION\s+(IF\s+EXISTS\s+)?\w*oauth_codes_guard/i
      refute down =~ ~r/GRANT/i
      refute down =~ ~r/oauth_clients/i, "down must not touch oauth_clients (000040)"
    end

    test "000040 is unchanged by this story (no oauth_codes/authz mention)" do
      refute read!("000040_oauth_clients_and_auth_metadata.up.sql") =~ ~r/oauth_codes|oauth_authz_requests/
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # integration: migrated schema + runtime-role behaviour
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10 — migrated schema (integration, runtime role)" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!(["https://app.example.com/cb"])}
    end

    defp authz_insert(cid, key, extra_cols \\ "", extra_vals \\ "") do
      "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
        "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, expires_at#{extra_cols}) " <>
        "VALUES ('#{key}', '#{cid}', 'u', 'c', 'D', 's', 'urn:matrix:client:', 'fragment', 'e', 'n', 'b', now() + interval '10 minutes'#{extra_vals})"
    end

    defp code_insert(cid, hash, opts \\ []) do
      prefix = Keyword.get(opts, :prefix, "urn:matrix:client:")
      mode = Keyword.get(opts, :mode, "query")
      created = Keyword.get(opts, :created, "now()")
      expires = Keyword.get(opts, :expires, "now() + interval '60 seconds'")
      used = Keyword.get(opts, :used, "NULL")

      "INSERT INTO oauth_codes (code_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
        "response_mode, created_at, expires_at, used_at) VALUES ('#{hash}', '#{cid}', 'u', 'c', 'D', '@u:t', 's', '#{prefix}', " <>
        "'#{mode}', #{created}, #{expires}, #{used})"
    end

    test "columns and types exist on both tables" do
      for {table, cols} <- [{"oauth_authz_requests", @authz_cols}, {"oauth_codes", @code_cols}] do
        %{rows: rows} =
          T.sql!("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = $1", [table])

        got = Map.new(rows, fn [n, t, nul] -> {n, {t, nul}} end)
        for c <- cols, do: assert(Map.has_key?(got, c), "#{table}.#{c} missing")
        assert got["openid_requested"] == {"boolean", "NO"}
        assert got["client_nonce"] == {"text", "YES"}
        assert {"timestamp with time zone", "NO"} = got["expires_at"]
      end
    end

    test "defaults: openid_requested false, created_at now()", %{cid: cid} do
      key = "atdd-def-" <> T.rand()
      T.sql!(authz_insert(cid, key))
      assert %{rows: [[false, true]]} =
               T.sql!("SELECT openid_requested, created_at <= now() FROM oauth_authz_requests WHERE state_hash = $1", [key])
    end

    test "CHECK violations: scope_prefix, response_mode, TTL bounds", %{cid: cid} do
      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!(code_insert(cid, "h1-" <> T.rand(), prefix: "urn:matrix:other:"))
      end

      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> T.sql!(code_insert(cid, "h2-" <> T.rand(), mode: "form_post")) end

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!(code_insert(cid, "h3-" <> T.rand(), expires: "now() + interval '61 seconds'"))
      end

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!(
          "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
            "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, expires_at) VALUES ($1, $2, 'u', 'c', 'D', 's', " <>
            "'urn:matrix:client:', 'fragment', 'e', 'n', 'b', now() + interval '11 minutes')",
          ["a-" <> T.rand(), cid]
        )
      end

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!(String.replace(authz_insert(cid, "a2-" <> T.rand()), "'fragment'", "'form_post'"))
      end
    end

    test "FK: a code / request for an unknown client is refused; deleting the client cascades", %{cid: cid} do
      assert_raise Postgrex.Error, ~r/foreign key/i, fn -> T.sql!(code_insert("no-such-client-" <> T.rand(), "h-" <> T.rand())) end

      other = T.oauth_client!(["https://app.example.com/cb"])
      key = "atdd-fk-" <> T.rand()
      T.sql!(authz_insert(other, key))
      T.sql!(code_insert(other, "fk-" <> key))
      T.cleanup_clients([other])
      assert T.count_for("oauth_authz_requests", other) == 0
      assert T.count_for("oauth_codes", other) == 0
      _ = cid
    end

    test "authz rows cannot be UPDATEd by the runtime role (no grant / no policy), DELETE works", %{cid: cid} do
      key = "atdd-upd-" <> T.rand()
      T.sql!(authz_insert(cid, key))

      result =
        try do
          T.sql!("UPDATE oauth_authz_requests SET redirect_uri = 'https://evil.example.com/cb' WHERE state_hash = $1", [key])
        rescue
          e in Postgrex.Error -> {:raised, e}
        end

      case result do
        {:raised, e} -> assert Exception.message(e) =~ ~r/permission denied|policy/i
        %{num_rows: n} -> assert n == 0, "no UPDATE policy => an update matches no row"
      end

      assert %{rows: [["u"]]} = T.sql!("SELECT redirect_uri FROM oauth_authz_requests WHERE state_hash = $1", [key])
      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_authz_requests WHERE state_hash = $1", [key])
    end

    test "codes: INSERT of an already used code is refused (RLS WITH CHECK)", %{cid: cid} do
      assert_raise Postgrex.Error, ~r/row-level security|policy/i, fn ->
        T.sql!(code_insert(cid, "used-" <> T.rand(), used: "now()"))
      end
    end

    test "codes: used_at NULL -> NOT NULL allowed once; un-using and every other column change refused (guard)", %{cid: cid} do
      hash = "guard-" <> T.rand()
      T.sql!(code_insert(cid, hash))

      for set <- ["scope = 'other'", "redirect_uri = 'https://evil.example.com'", "user_id = '@evil:t'", "expires_at = now() + interval '1 day'",
                  "code_challenge = 'x'", "device_id = 'X'", "client_nonce = 'n'", "openid_requested = true", "idp_rt_enc = 'x'"] do
        assert_raise Postgrex.Error, fn -> T.sql!("UPDATE oauth_codes SET #{set} WHERE code_hash = $1", [hash]) end
      end

      assert %{num_rows: 1} = T.sql!("UPDATE oauth_codes SET used_at = now() WHERE code_hash = $1 AND used_at IS NULL", [hash])

      assert_raise Postgrex.Error, fn -> T.sql!("UPDATE oauth_codes SET used_at = NULL WHERE code_hash = $1", [hash]) end
      assert_raise Postgrex.Error, fn -> T.sql!("UPDATE oauth_codes SET used_at = now() + interval '1 hour' WHERE code_hash = $1", [hash]) end

      assert %{rows: [[true]]} = T.sql!("SELECT used_at IS NOT NULL FROM oauth_codes WHERE code_hash = $1", [hash])
    end

    test "codes: the runtime role cannot DELETE an unexpired or recently expired code, only one expired > 24 h", %{cid: cid} do
      live = "del-live-" <> T.rand()
      recent = "del-recent-" <> T.rand()
      old = "del-old-" <> T.rand()
      T.sql!(code_insert(cid, live))
      T.sql!(code_insert(cid, recent, created: "now() - interval '23 hours'", expires: "now() - interval '23 hours' + interval '60 seconds'"))
      T.sql!(code_insert(cid, old, created: "now() - interval '25 hours'", expires: "now() - interval '25 hours' + interval '60 seconds'"))

      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_codes WHERE code_hash = $1", [live])
      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_codes WHERE code_hash = $1", [recent])
      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_codes WHERE code_hash = $1", [old])
    end

    test "RLS enabled + forced; policy inventory as specified" do
      for t <- ~w(oauth_authz_requests oauth_codes) do
        assert %{rows: [[true, true]]} =
                 T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1", [t])
      end

      %{rows: authz} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = 'oauth_authz_requests'")
      assert authz |> List.flatten() |> Enum.sort() == ~w(DELETE INSERT SELECT)

      %{rows: codes} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = 'oauth_codes'")
      assert codes |> List.flatten() |> Enum.sort() == ~w(DELETE INSERT SELECT UPDATE)
    end

    test "indexes on expires_at exist" do
      for t <- ~w(oauth_authz_requests oauth_codes) do
        %{rows: rows} = T.sql!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [t])
        assert Enum.any?(rows, fn [d] -> d =~ ~r/\(expires_at\)/ end), "#{t} indexes: #{inspect(rows)}"
      end
    end

    test "down/up round trip (privileged role, rolled back): down removes both tables, up restores them" do
      down = read!(@down)
      up = read!(@up)

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, down, [], query_type: :text)

            %{rows: [[nil, nil]]} =
              Postgrex.query!(tx, "SELECT to_regclass('oauth_authz_requests')::text, to_regclass('oauth_codes')::text", [])

            %{rows: [[0]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_proc WHERE proname LIKE '%oauth_codes_guard%'", [])

            Postgrex.query!(tx, up, [], query_type: :text)

            %{rows: [[a, c]]} =
              Postgrex.query!(tx, "SELECT to_regclass('oauth_authz_requests')::text, to_regclass('oauth_codes')::text", [])

            %{rows: [[true]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_clients') IS NOT NULL", [])
            Postgrex.rollback(tx, {:round_trip_ok, a, c})
          end)
        end)

      assert result == {:error, {:round_trip_ok, "oauth_authz_requests", "oauth_codes"}}
    end
  end
end
