defmodule Nebu.Migration.Migration000044OauthAbuseHardeningTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-dcr-abuse-hardening`, AC4: migration
  `000044_oauth_abuse_hardening` (additive: `oauth_clients.client_domain` / `.source_key`,
  `oauth_authz_requests.source_key`, `oauth_account_login_requests.source_key`, CHECKs, indexes; NO
  grant / policy / trigger / `server_config` change).

  Mirrors `000041_oauth_authz_codes_test.exs`:
    * static SQL-file analysis (no DB)
    * `:integration` behaviour as the RUNTIME role (`nebu_app`): columns, CHECK violations (malformed
      key, decided row with a key), RLS unchanged (decided row not deletable, pending row deletable),
      indexes, and a down/up round trip on the privileged role inside a rolled-back transaction.

  After changing the migration reset the throwaway DB (`docker rm -f nebu-oauth-pg`); 000040-000043 are
  committed and must stay untouched.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000044_oauth_abuse_hardening.up.sql"
  @down "000044_oauth_abuse_hardening.down.sql"

  @key "a" |> String.duplicate(64)

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  describe "AC4 — migration files (static)" do
    test "up and down exist as the next free number after 000043; exactly one 000044" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000044_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000044 up migration"
      assert Path.wildcard(Path.join(@dir, "000044_*.down.sql")) == [Path.join(@dir, @down)], "exactly one 000044 down migration"
      assert File.exists?(Path.join(@dir, "000043_oauth_account_management.up.sql"))
    end

    test "up adds the nullable columns with IF NOT EXISTS" do
      sql = code_sql(@up)
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_clients\b/i
      assert sql =~ ~r/ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+client_domain\s+TEXT\s*(,|;)/i
      assert sql =~ ~r/ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+source_key\s+TEXT\s*(,|;)/i
      for t <- ~w(oauth_authz_requests oauth_account_login_requests) do
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\b[^;]*ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+source_key\s+TEXT/is, "#{t}.source_key missing"
      end

      refute sql =~ ~r/source_key\s+TEXT\s+NOT\s+NULL/i, "columns are nullable (rolling deploy, AH17)"
      refute sql =~ ~r/client_domain\s+TEXT\s+NOT\s+NULL/i
    end

    test "named CHECKs: source_key format on all three tables, decided rows carry no key" do
      sql = code_sql(@up)
      assert sql =~ "oauth_clients_source_key_format_check"
      assert sql =~ "oauth_clients_source_key_pending_check"
      assert length(Regex.scan(~r/source_key\s+IS\s+NULL\s+OR\s+source_key\s+~\s+'\^\[0-9a-f\]\{64\}\$'/i, sql)) >= 3,
             "one format CHECK per table: (source_key IS NULL OR source_key ~ '^[0-9a-f]{64}$')"
      assert sql =~ ~r/CHECK\s*\(\s*status\s*=\s*'pending'\s+OR\s+source_key\s+IS\s+NULL\s*\)/i
    end

    test "partial and composite indexes" do
      sql = code_sql(@up)

      assert sql =~
               ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_clients_pending_domain_source_idx\s+ON\s+oauth_clients\s*\(\s*client_domain\s*,\s*source_key\s*\)\s+WHERE\s+status\s*=\s*'pending'/i

      assert sql =~
               ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_clients_pending_source_idx\s+ON\s+oauth_clients\s*\(\s*source_key\s*\)\s+WHERE\s+status\s*=\s*'pending'/i

      for t <- ~w(oauth_authz_requests oauth_account_login_requests) do
        assert sql =~ ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?\w+\s+ON\s+#{t}\s*\(\s*source_key\s*,\s*expires_at\s*\)/i,
               "#{t}: index (source_key, expires_at)"
      end
    end

    test "no GRANT, policy, trigger, function or server_config change (AC4.2)" do
      sql = code_sql(@up)
      refute sql =~ ~r/\bGRANT\b|\bREVOKE\b/i
      refute sql =~ ~r/CREATE\s+POLICY|DROP\s+POLICY|ALTER\s+POLICY/i
      refute sql =~ ~r/CREATE\s+(OR\s+REPLACE\s+)?(TRIGGER|FUNCTION)/i
      refute sql =~ ~r/server_config|config_update_mutable/i
      refute sql =~ ~r/ROW\s+LEVEL\s+SECURITY/i
    end

    test "down drops indexes, CHECKs and columns only" do
      down = code_sql(@down)
      assert down =~ ~r/DROP\s+INDEX\s+(IF\s+EXISTS\s+)?oauth_clients_pending_domain_source_idx/i
      assert down =~ ~r/DROP\s+INDEX\s+(IF\s+EXISTS\s+)?oauth_clients_pending_source_idx/i
      assert down =~ ~r/DROP\s+CONSTRAINT\s+(IF\s+EXISTS\s+)?oauth_clients_source_key_format_check/i
      assert down =~ ~r/DROP\s+CONSTRAINT\s+(IF\s+EXISTS\s+)?oauth_clients_source_key_pending_check/i
      for t <- ~w(oauth_clients oauth_authz_requests oauth_account_login_requests) do
        assert down =~ ~r/ALTER\s+TABLE\s+#{t}\b[^;]*DROP\s+COLUMN\s+(IF\s+EXISTS\s+)?source_key/is, "#{t}.source_key must be dropped"
      end

      assert down =~ ~r/DROP\s+COLUMN\s+(IF\s+EXISTS\s+)?client_domain/i
      refute down =~ ~r/DROP\s+TABLE/i
      refute down =~ ~r/\bGRANT\b/i
    end

    test "000040-000043 are untouched: they do not mention source_key / client_domain" do
      for f <- Path.wildcard(Path.join(@dir, "00004[0-3]_*.sql")) do
        refute File.read!(f) =~ ~r/source_key|client_domain/, "#{Path.basename(f)} must not be edited by this story"
      end
    end

    test "no committed migration of an earlier story is edited: the P1 'no client_ip in migrations' pin still holds" do
      refute read!(@up) =~ ~r/trusted_proxy|client_ip/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # integration: migrated schema + runtime-role behaviour
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — migrated schema (integration, runtime role)" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!(["https://app.example.com/cb"])}
    end

    defp client_insert(id, extra_cols \\ "", extra_vals \\ "") do
      T.sql!(
        "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, created_at#{extra_cols}) " <>
          "VALUES ($1, '{}'::jsonb, $2, 'web', now()#{extra_vals})",
        [id, "atdd-044-hash-" <> id]
      )
    end

    defp new_id, do: "atdd-044-" <> T.rand(8)
    defp hex64, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    test "columns exist: nullable text on the four places" do
      for {table, col} <- [
            {"oauth_clients", "client_domain"},
            {"oauth_clients", "source_key"},
            {"oauth_authz_requests", "source_key"},
            {"oauth_account_login_requests", "source_key"}
          ] do
        assert %{rows: [[type, nullable]]} =
                 T.sql!(
                   "SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
                   [table, col]
                 ),
               "#{table}.#{col} missing"

        assert {type, nullable} == {"text", "YES"}
      end
    end

    test "defaults to NULL on existing-style inserts (old nodes insert NULL sources, AH17)" do
      id = new_id()
      client_insert(id)
      on_exit(fn -> T.cleanup_clients([id]) end)
      assert %{rows: [[nil, nil]]} = T.sql!("SELECT client_domain, source_key FROM oauth_clients WHERE client_id = $1", [id])
    end

    test "oauth_clients: a malformed source_key is refused by the format CHECK; a 64-hex key is accepted" do
      bad = new_id()

      for key <- ["not-hex", String.duplicate("A", 64), String.duplicate("a", 63), String.duplicate("a", 65), ""] do
        assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
          T.sql!(
            "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, source_key) VALUES ($1, '{}'::jsonb, $2, 'web', $3)",
            [bad, "atdd-044-bad-" <> T.rand(), key]
          )
        end
      end

      ok = new_id()
      on_exit(fn -> T.cleanup_clients([ok]) end)
      client_insert(ok, ", client_domain, source_key", ", 'example.com', '#{@key}'")
      assert %{rows: [["example.com", @key]]} = T.sql!("SELECT client_domain, source_key FROM oauth_clients WHERE client_id = $1", [ok])
    end

    test "oauth_clients: a DECIDED row cannot keep a source_key (pending-only CHECK, AH7); nulling it in the same UPDATE works" do
      id = new_id()
      on_exit(fn -> T.cleanup_clients([id]) end)
      client_insert(id, ", source_key", ", '#{@key}'")

      assert_raise Postgrex.Error, ~r/oauth_clients_source_key_pending_check|check constraint/i, fn ->
        T.sql!("UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = now() WHERE client_id = $1", [id])
      end

      assert %{num_rows: 1} =
               T.sql!(
                 "UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = now(), source_key = NULL WHERE client_id = $1",
                 [id]
               )

      assert %{rows: [["approved", nil]]} = T.sql!("SELECT status, source_key FROM oauth_clients WHERE client_id = $1", [id])

      rej = new_id()
      on_exit(fn -> T.cleanup_clients([rej]) end)
      client_insert(rej, ", source_key", ", '#{@key}'")

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!("UPDATE oauth_clients SET status = 'rejected', rejected_by = '@admin:test.local', rejected_at = now() WHERE client_id = $1", [rej])
      end
    end

    test "oauth_clients: the guard trigger is not extended (000040 semantics): client_domain/source_key can be changed while pending" do
      id = new_id()
      on_exit(fn -> T.cleanup_clients([id]) end)
      client_insert(id, ", client_domain", ", 'a.example'")
      assert %{num_rows: 1} = T.sql!("UPDATE oauth_clients SET client_domain = 'b.example' WHERE client_id = $1", [id])
    end

    test "RLS unchanged: a pending row is deletable by the runtime role, a decided row is not" do
      pending = new_id()
      decided = new_id()
      on_exit(fn -> T.cleanup_clients([pending, decided]) end)
      client_insert(pending, ", client_domain, source_key", ", 'del.example', '#{@key}'")
      client_insert(decided, ", client_domain", ", 'del.example'")
      T.sql!("UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = now() WHERE client_id = $1", [decided])

      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [pending])
      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [decided])
      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE client_id = $1", [decided])
    end

    test "RLS and policy inventory of the three tables is unchanged by 000044" do
      for t <- ~w(oauth_clients oauth_authz_requests oauth_account_login_requests) do
        assert %{rows: [[true, true]]} = T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1", [t])
      end

      %{rows: authz} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = 'oauth_authz_requests'")
      assert authz |> List.flatten() |> Enum.sort() == ~w(DELETE INSERT SELECT)
    end

    test "oauth_authz_requests.source_key: format CHECK, 64-hex accepted", %{cid: cid} do
      insert = fn key ->
        T.sql!(
          "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
            "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, expires_at, source_key) " <>
            "VALUES ($1, $2, 'u', 'c', 'D', 's', 'urn:matrix:client:', 'fragment', 'e', 'n', 'b', now() + interval '10 minutes', $3)",
          ["atdd-044-" <> T.rand(), cid, key]
        )
      end

      assert_raise Postgrex.Error, ~r/oauth_authz_requests_source_key_format_check/, fn -> insert.("XYZ") end
      assert %{num_rows: 1} = insert.(@key)
      assert %{num_rows: 1} = insert.(nil)
    end

    test "oauth_account_login_requests.source_key: format CHECK, 64-hex accepted" do
      insert = fn key ->
        T.sql!(
          "INSERT INTO oauth_account_login_requests (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, created_at, expires_at, source_key) " <>
            "VALUES ($1, 'atdd-044-enc', 'atdd-044-n', $2, NULL, now(), now() + interval '9 minutes', $3)",
          [hex64(), hex64(), key]
        )
      end

      on_exit(fn -> T.privileged_sql!("DELETE FROM oauth_account_login_requests WHERE idp_verifier_enc = 'atdd-044-enc'") end)

      # state_hash / binding_hash must satisfy the 000043 CHECKs (64 hex), so the ONLY violation is the key
      assert_raise Postgrex.Error, ~r/oauth_account_login_requests_source_key_format_check/, fn -> insert.("XYZ") end
      assert %{num_rows: 1} = insert.(@key)
    end

    test "indexes exist (partial on pending / composite with expires_at)" do
      %{rows: clients} = T.sql!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'oauth_clients'")
      defs = Map.new(clients, fn [n, d] -> {n, d} end)

      assert defs["oauth_clients_pending_domain_source_idx"] =~ ~r/\(client_domain, source_key\)/
      assert defs["oauth_clients_pending_domain_source_idx"] =~ ~r/WHERE.*status.*pending/i
      assert defs["oauth_clients_pending_source_idx"] =~ ~r/\(source_key\)/
      assert defs["oauth_clients_pending_source_idx"] =~ ~r/WHERE.*status.*pending/i

      for t <- ~w(oauth_authz_requests oauth_account_login_requests) do
        %{rows: rows} = T.sql!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [t])
        assert Enum.any?(rows, fn [d] -> d =~ ~r/\(source_key, expires_at\)/ end), "#{t} indexes: #{inspect(rows)}"
      end
    end

    test "down/up round trip (privileged role, rolled back): down removes the columns, up restores them" do
      down = read!(@down)
      up = read!(@up)

      cols = fn tx ->
        %{rows: rows} =
          Postgrex.query!(
            tx,
            "SELECT table_name || '.' || column_name FROM information_schema.columns " <>
              "WHERE (table_name = 'oauth_clients' AND column_name IN ('client_domain', 'source_key')) " <>
              "OR (table_name IN ('oauth_authz_requests', 'oauth_account_login_requests') AND column_name = 'source_key') ORDER BY 1",
            []
          )

        List.flatten(rows)
      end

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert length(cols.(tx)) == 4

            Postgrex.query!(tx, down, [], query_type: :text)
            assert cols.(tx) == [], "down must remove every column it added"

            %{rows: [[0]]} =
              Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE indexname LIKE 'oauth_clients_pending_%source%'", [])

            # 000040-000043 objects are still there
            %{rows: [[true, true, true]]} =
              Postgrex.query!(
                tx,
                "SELECT to_regclass('oauth_clients') IS NOT NULL, to_regclass('oauth_authz_requests') IS NOT NULL, to_regclass('oauth_account_login_requests') IS NOT NULL",
                []
              )

            Postgrex.query!(tx, up, [], query_type: :text)
            assert length(cols.(tx)) == 4, "up must restore the columns"
            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end
  end
end
