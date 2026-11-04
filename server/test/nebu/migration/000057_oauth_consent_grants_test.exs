defmodule Nebu.Migration.Migration000057OauthConsentGrantsTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003): migration `000057_oauth_consent_grants` (000056 is used by session-lifetime-setting).

  Pinned names (the dev MUST use exactly these; changing one means changing this test):

    * `oauth_consent_grants`: `user_id` TEXT NOT NULL, `client_id` TEXT NOT NULL REFERENCES `oauth_clients (client_id)` ON DELETE CASCADE (a deleted
      client takes its grants with it: the privileged cleanup of every OAuth test, and the owner override of a registration), `scope` TEXT NOT NULL
      (the normalised remembered scope, no device token), `redirect_uri` TEXT NOT NULL, `client_approved_at` TIMESTAMPTZ NOT NULL (the identity
      binding: the `approved_at` of the client row the user allowed; a client that is approved again later has a NEW `approved_at`, so it does not
      inherit the grant), `created_at` TIMESTAMPTZ NOT NULL DEFAULT now() (first Allow, never rewritten), `granted_at` TIMESTAMPTZ NOT NULL DEFAULT
      now() (latest Allow). PRIMARY KEY `(user_id, client_id)` (one grant per user and client: concurrent Allows are one row through
      `ON CONFLICT`). CHECKs: scope and redirect_uri not empty and at most 2048 bytes. Index `oauth_consent_grants_client_idx (client_id)`.
    * `oauth_authz_requests.force_consent BOOLEAN NOT NULL DEFAULT false`: `prompt=consent` has to travel from `/oauth2/authorize` to the IdP callback,
      where the user is known and the decision is taken. Defaulted, so a node that still runs the previous release keeps inserting valid rows.
    * Grants to `nebu_app`: `SELECT, INSERT, DELETE` on the table plus a COLUMN level `UPDATE (scope, redirect_uri, client_approved_at, granted_at)`;
      the table level UPDATE is revoked first (a development database may carry ALTER DEFAULT PRIVILEGES). `user_id`, `client_id` and `created_at`
      can never be rewritten by the runtime role. RLS ENABLE + FORCE, one open policy per command (`oauth_consent_grants_{select,insert,update,delete}`):
      the erasure (`DELETE ... WHERE user_id`), the withdrawal and the revocation delete without a condition on the row.
    * No `server_config` change (ADR-022), no transaction management, no CONCURRENTLY; 000040-000056 are not edited. The down migration drops the
      table and the column.

  Mirrors `000045_oauth_consent_and_refresh_leases_test.exs`: static SQL analysis plus `:integration` behaviour as the RUNTIME role and a down/up round
  trip on the privileged role inside a rolled-back transaction. After adding the migration run `.session-ci/quick.sh --migrate`.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000057_oauth_consent_grants.up.sql"
  @down "000057_oauth_consent_grants.down.sql"
  @table "oauth_consent_grants"
  @cols ~w(user_id client_id scope redirect_uri client_approved_at created_at granted_at)

  defp read!(f) do
    path = Path.join(@dir, f)
    assert File.exists?(path), "#{f} is missing (server/priv/migrations)"
    File.read!(path)
  end
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp table_sql(sql) do
    case Regex.split(~r/CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?#{@table}\s*\(/i, sql, parts: 2) do
      [_, rest] -> rest |> String.split(~r/\n\);/, parts: 2) |> hd()
      _ -> flunk("CREATE TABLE #{@table} missing")
    end
  end

  defp policies(sql, cmd),
    do: Regex.scan(~r/CREATE\s+POLICY\s+(\w+)\s+ON\s+#{@table}\s+FOR\s+#{cmd}\b[^;]*/i, sql) |> Enum.map(&Enum.at(&1, 1))

  describe "migration files (static)" do
    # {number, path} of every migration file with the given suffix
    defp numbered(suffix) do
      Path.wildcard(Path.join(@dir, "*.#{suffix}.sql"))
      |> Enum.map(fn p -> {p |> Path.basename() |> String.slice(0, 6) |> String.to_integer(), p} end)
    end

    test "up and down exist as the number right after the highest earlier migration; exactly one 000057" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000057_*.up.sql")) == [Path.join(@dir, @up)]
      assert Path.wildcard(Path.join(@dir, "000057_*.down.sql")) == [Path.join(@dir, @down)]

      highest_before = for({n, _} <- numbered("up"), n < 57, do: n) |> Enum.max()
      assert highest_before == 56, "000057 must be the next free number (the highest earlier migration is #{highest_before})"
    end

    test "earlier migrations (numbers below 000057) are untouched: none mentions the new table or column" do
      for {n, f} <- numbered("up") ++ numbered("down"), n < 57 do
        refute File.read!(f) =~ ~r/oauth_consent_grants|force_consent/, "#{Path.basename(f)} must not be edited (new migration instead)"
      end
    end

    test "columns, composite PK, NOT NULLs, FK cascade, the size CHECKs" do
      t = table_sql(code_sql(@up))
      for c <- @cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/PRIMARY\s+KEY\s*\(\s*user_id\s*,\s*client_id\s*\)/i
      assert t =~ ~r/client_id\s+TEXT\s+NOT\s+NULL\s+REFERENCES\s+oauth_clients\s*\(\s*client_id\s*\)\s+ON\s+DELETE\s+CASCADE/i

      for c <- ~w(user_id scope redirect_uri), do: assert(t =~ ~r/\b#{c}\s+TEXT\s+NOT\s+NULL/i, "#{c} TEXT NOT NULL")
      assert t =~ ~r/client_approved_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/created_at\s+TIMESTAMPTZ\s+NOT\s+NULL\s+DEFAULT\s+now\(\)/i
      assert t =~ ~r/granted_at\s+TIMESTAMPTZ\s+NOT\s+NULL\s+DEFAULT\s+now\(\)/i
      assert t =~ ~r/octet_length\s*\(\s*scope\s*\)\s*BETWEEN\s+1\s+AND\s+2048/i
      assert t =~ ~r/octet_length\s*\(\s*redirect_uri\s*\)\s*BETWEEN\s+1\s+AND\s+2048/i
      refute t =~ ~r/\b(token|cookie|code|device_id|nonce|state|idp_rt)\b\s+\w+/i, "no secret, token or per-login value is stored with a grant"
    end

    test "index on client_id (the cascade / revoke path)" do
      assert code_sql(@up) =~ ~r/CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+oauth_consent_grants_client_idx\s+ON\s+#{@table}\s*\(\s*client_id\s*\)/i
    end

    test "oauth_authz_requests gains force_consent BOOLEAN NOT NULL DEFAULT false, nothing else of that table changes" do
      sql = code_sql(@up)
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_authz_requests\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+force_consent\s+BOOLEAN\s+NOT\s+NULL\s+DEFAULT\s+false/i
      refute sql =~ ~r/ALTER\s+TABLE\s+oauth_authz_requests\s+(DROP|RENAME|ALTER\s+COLUMN)/i
    end

    test "cycle 1: the account login request may return to the apps page: the action CHECK of 000043 gains 'apps', the down migration restores it" do
      up = code_sql(@up)
      assert up =~ ~r/ALTER\s+TABLE\s+oauth_account_login_requests\s+DROP\s+CONSTRAINT\s+IF\s+EXISTS\s+oauth_account_login_requests_action_check/i
      assert [_, list] = Regex.run(~r/ADD\s+CONSTRAINT\s+oauth_account_login_requests_action_check\s+CHECK\s*\(\s*return_action\s+IS\s+NULL\s+OR\s+return_action\s+IN\s*\(([^)]*)\)/i, up)
      values = Regex.scan(~r/'([^']+)'/, list) |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort()

      assert values ==
               Enum.sort(~w(org.matrix.profile org.matrix.devices_list org.matrix.device_view org.matrix.device_delete org.matrix.cross_signing_reset apps)),
             "the five advertised actions of 000043 plus 'apps', got #{inspect(values)}"

      down = code_sql(@down)
      assert down =~ ~r/DELETE\s+FROM\s+oauth_account_login_requests\s+WHERE\s+return_action\s*=\s*'apps'/i, "rows that use the new value go BEFORE the CHECK is restored"
      assert [_, restored] = Regex.run(~r/ADD\s+CONSTRAINT\s+oauth_account_login_requests_action_check\s+CHECK\s*\(\s*return_action\s+IS\s+NULL\s+OR\s+return_action\s+IN\s*\(([^)]*)\)/i, down)
      refute restored =~ "'apps'"
      {del, _} = :binary.match(String.downcase(down), "delete from oauth_account_login_requests")
      {add, _} = :binary.match(String.downcase(down), "add constraint oauth_account_login_requests_action_check")
      assert del < add
    end

    test "grants: SELECT / INSERT / DELETE on the table, UPDATE only per column, the table level UPDATE revoked BEFORE the column grant" do
      sql = code_sql(@up)
      [grant | _] = Regex.run(~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*DELETE\s+ON\s+(TABLE\s+)?#{@table}\s+TO\s+nebu_app/i, sql) || flunk("table GRANT missing")
      refute grant =~ ~r/UPDATE|\bALL\b/i

      assert [col_grant] = Regex.run(~r/GRANT\s+UPDATE\s*\(([^)]*)\)\s+ON\s+(?:TABLE\s+)?#{@table}\s+TO\s+nebu_app/i, sql, capture: :all_but_first) || flunk("column level GRANT UPDATE missing")
      cols = col_grant |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.sort()
      assert cols == Enum.sort(~w(scope redirect_uri client_approved_at granted_at)), "UPDATE columns: #{inspect(cols)}"

      revoke_match = Regex.run(~r/REVOKE\s+UPDATE\s+ON\s+(?:TABLE\s+)?#{@table}\s+FROM\s+nebu_app/i, sql, return: :index) || flunk("REVOKE UPDATE ON #{@table} FROM nebu_app missing")
      {revoke, _} = hd(revoke_match)
      {column_grant, _} = hd(Regex.run(~r/GRANT\s+UPDATE\s*\(/i, sql, return: :index))
      assert revoke < column_grant, "REVOKE UPDATE (table level) must come before the column GRANT"
      refute sql =~ ~r/GRANT\s+ALL/i
    end

    test "RLS enabled AND forced; exactly one policy per command, nothing else" do
      sql = code_sql(@up)
      assert sql =~ ~r/ALTER\s+TABLE\s+#{@table}\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
      assert sql =~ ~r/ALTER\s+TABLE\s+#{@table}\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i

      for cmd <- ~w(SELECT INSERT UPDATE DELETE), do: assert(policies(sql, cmd) == ["#{@table}_#{String.downcase(cmd)}"])
      assert policies(sql, "ALL") == []
    end

    test "no server_config change, no transaction management, no CONCURRENTLY" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/server_config|config_update_mutable/i, "#{f}: no server_config key (ADR-022)"
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
        refute sql =~ ~r/CONCURRENTLY/i
      end
    end

    test "down: drops the table and the column" do
      down = code_sql(@down)
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?#{@table}/i
      assert down =~ ~r/ALTER\s+TABLE\s+oauth_authz_requests\s+DROP\s+COLUMN\s+(IF\s+EXISTS\s+)?force_consent/i
    end

    test "header comment names the story, the rolling deploy safety and the identity binding" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      assert header =~ "persistent-consent-grants"
      assert header =~ ~r/REQ-2026-003/
      assert header =~ ~r/rolling/i
      assert header =~ ~r/approved_at|binding/i
    end
  end

  describe "migrated schema (integration, runtime role nebu_app)" do
    @describetag :integration

    setup do
      cid = T.oauth_client!([G.https()])
      uid = "@atdd-m57-#{T.rand()}:test.local"
      on_exit(fn -> G.cleanup_grants([uid]) end)
      {:ok, cid: cid, uid: uid}
    end

    defp insert(uid, cid, opts \\ []) do
      T.sql!(
        "INSERT INTO oauth_consent_grants (user_id, client_id, scope, redirect_uri, client_approved_at) VALUES ($1, $2, $3, $4, now())",
        [uid, cid, Keyword.get(opts, :scope, "openid"), Keyword.get(opts, :redirect_uri, G.https())]
      )
    end

    test "columns and types as pinned" do
      %{rows: rows} = T.sql!("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = $1", [@table])
      got = Map.new(rows, fn [n, t, nl] -> {n, {t, nl}} end)
      assert got != %{}, "table #{@table} missing (migration 000057 not applied: run .session-ci/quick.sh --migrate)"
      for c <- @cols, do: assert(Map.has_key?(got, c), "#{@table}.#{c} missing")
      assert got["client_approved_at"] == {"timestamp with time zone", "NO"}
      assert got["created_at"] == {"timestamp with time zone", "NO"}
      assert got["scope"] == {"text", "NO"}

      assert %{rows: [["boolean", "NO", d]]} =
               T.sql!("SELECT data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = 'oauth_authz_requests' AND column_name = 'force_consent'")

      assert d =~ "false"
    end

    test "insert, the PK admits one row per (user, client), ON CONFLICT DO UPDATE works for the runtime role", %{cid: cid, uid: uid} do
      assert %{num_rows: 1} = insert(uid, cid)
      assert_raise Postgrex.Error, ~r/duplicate key|unique/i, fn -> insert(uid, cid) end

      assert %{num_rows: 1} =
               T.sql!(
                 "INSERT INTO oauth_consent_grants (user_id, client_id, scope, redirect_uri, client_approved_at) VALUES ($1, $2, $3, $4, now()) " <>
                   "ON CONFLICT (user_id, client_id) DO UPDATE SET scope = EXCLUDED.scope, redirect_uri = EXCLUDED.redirect_uri, " <>
                   "client_approved_at = EXCLUDED.client_approved_at, granted_at = now()",
                 [uid, cid, "openid broader", "https://other.example.com/cb"]
               )

      assert %{rows: [["openid broader", "https://other.example.com/cb"]]} =
               T.sql!("SELECT scope, redirect_uri FROM oauth_consent_grants WHERE user_id = $1 AND client_id = $2", [uid, cid])
    end

    test "the runtime role can UPDATE scope, redirect_uri, client_approved_at and granted_at, never user_id, client_id or created_at", %{cid: cid, uid: uid} do
      insert(uid, cid)

      for set <- ["scope = 'openid x'", "redirect_uri = 'https://x.example.com/cb'", "client_approved_at = now()", "granted_at = now()"] do
        assert %{num_rows: 1} = T.sql!("UPDATE oauth_consent_grants SET #{set} WHERE user_id = $1 AND client_id = $2", [uid, cid]), set
      end

      for set <- ["user_id = '@someone-else:test.local'", "client_id = 'other'", "created_at = now() - interval '1 year'"] do
        assert_raise Postgrex.Error, ~r/permission denied/i, fn ->
          T.sql!("UPDATE oauth_consent_grants SET #{set} WHERE user_id = $1 AND client_id = $2", [uid, cid])
        end
      end
    end

    test "the runtime role can DELETE a grant of any user (erasure, withdrawal, revocation)", %{cid: cid, uid: uid} do
      insert(uid, cid)
      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_consent_grants WHERE user_id = $1", [uid])
      insert(uid, cid)
      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_consent_grants WHERE client_id = $1 AND user_id = $2", [cid, uid])
    end

    test "CHECKs refuse an empty or oversized scope and redirect URI", %{cid: cid, uid: uid} do
      for opts <- [[scope: ""], [redirect_uri: ""], [scope: String.duplicate("a", 2049)], [redirect_uri: "https://x.example.com/" <> String.duplicate("a", 2030)]] do
        assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert(uid, cid, opts) end
      end

      assert %{num_rows: 1} = insert(uid, cid, scope: String.duplicate("a", 2048))
    end

    test "the client FK is enforced and CASCADEs when the client is deleted (the privileged cleanup of every OAuth test)", %{cid: cid, uid: uid} do
      assert_raise Postgrex.Error, ~r/foreign key|violates/i, fn -> insert(uid, "no-such-client-" <> T.rand()) end

      insert(uid, cid)
      assert G.grant_count(uid) == 1
      T.cleanup_clients([cid])
      assert G.grant_count(uid) == 0, "the grant went with the client"
    end

    test "cycle 1: a login request with return_action 'apps' is accepted, an unknown action still refused (runtime role)" do
      hex = fn -> T.rand(32) end

      insert = fn action ->
        T.sql!(
          "INSERT INTO oauth_account_login_requests (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, expires_at) " <>
            "VALUES ($1, 'enc', 'nonce', $2, $3, now() + interval '5 minutes')",
          [hex.(), hex.(), action]
        )
      end

      assert %{num_rows: 1} = insert.("apps")
      assert %{num_rows: 1} = insert.("org.matrix.devices_list")
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert.("not-an-action") end
      T.sql!("DELETE FROM oauth_account_login_requests WHERE return_action IN ('apps', 'org.matrix.devices_list') AND idp_nonce = 'nonce'")
    end

    test "RLS enabled + forced; one policy per command" do
      assert %{rows: [[true, true]]} = T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1", [@table])
      %{rows: rows} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = $1", [@table])
      assert rows |> List.flatten() |> Enum.sort() == ~w(DELETE INSERT SELECT UPDATE)
    end

    test "oauth_authz_requests.force_consent defaults to false for a row inserted without it (a node of the previous release)" do
      %{rows: [[d]]} =
        T.sql!("SELECT column_default FROM information_schema.columns WHERE table_name = 'oauth_authz_requests' AND column_name = 'force_consent'")

      assert d =~ "false"
    end

    test "down/up round trip (privileged role, rolled back): down removes the table and the column; up restores both", %{cid: cid, uid: uid} do
      down = read!(@down)
      up = read!(@up)

      probe = fn tx ->
        %{rows: [[t]]} = Postgrex.query!(tx, "SELECT to_regclass('#{@table}')::text", [])

        %{rows: [[n]]} =
          Postgrex.query!(tx, "SELECT count(*) FROM information_schema.columns WHERE table_name = 'oauth_authz_requests' AND column_name = 'force_consent'", [])

        {t, n}
      end

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "INSERT INTO oauth_consent_grants (user_id, client_id, scope, redirect_uri, client_approved_at) VALUES ($1, $2, 'openid', 'https://app.example.com/cb', now())", [uid, cid])
            Postgrex.query!(tx, down, [], query_type: :text)
            after_down = probe.(tx)
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up = probe.(tx)
            Postgrex.rollback(tx, {:round_trip, after_down, after_up})
          end)
        end)

      assert {:error, {:round_trip, after_down, after_up}} = result
      assert after_down == {nil, 0}
      assert after_up == {@table, 1}
    end
  end
end
