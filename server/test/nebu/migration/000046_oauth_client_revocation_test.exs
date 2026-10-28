defmodule Nebu.Migration.Migration000046OauthClientRevocationTest do
  @moduledoc """
  Acceptance tests for story `oauth-client-revocation` (P4), AC1 + AC2 (decisions CR1-CR3): migration
  `000046_oauth_client_revocation` (000044 = P2, 000045 = P3 are taken; renumbering is NOT needed any more).

  Pinned names (the migration uses exactly these; changing one means changing this test):

    * `oauth_clients` gains `revoked_by TEXT`, `revoked_at TIMESTAMPTZ`, `revoked_reason TEXT` (all NULL-able).
    * `oauth_clients_status_check` (same name) admits `revoked`; `oauth_clients_decision_check` (same name) is
      re-created: pending = EVERY decision column incl. `revoked_*` NULL; approved = `approved_*` set and
      `rejected_*` / `revoked_*` NULL; rejected = the 000040 shape and `revoked_*` NULL; revoked = `approved_*` set
      (attribution kept), `revoked_by` / `revoked_at` set, `rejected_*` NULL. A separate
      `oauth_clients_revoked_reason_check`: `revoked_reason` is NULL unless the row is revoked and at most 500 chars.
    * `oauth_clients_guard_status()` is replaced (same name, same trigger): approved -> revoked is the ONLY new
      transition (approved_* / rejected_* unchanged, OLD.revoked_* NULL, NEW.revoked_by / revoked_at set); every
      other change of a decided row stays `check_violation`; `pending -> revoked` is refused too (a registration
      can never skip the admin approval); identity / metadata immutability unchanged.
    * RLS stays FORCEd: DELETE policy stays `status = 'pending'` (a revoked row is never deleted), the INSERT policy
      is re-created with `revoked_by IS NULL AND revoked_at IS NULL`. `config_update_mutable` is NOT touched.
    * `.down.sql` restores 000040's CHECKs, insert policy and trigger function verbatim, drops the columns, and
      RAISES (message contains `revoked`) when a revoked row exists: it never turns revoked into approved.

  Mirrors `000045_*_test.exs`: static SQL analysis plus `:integration` behaviour as the RUNTIME role (`nebu_app`)
  and the privileged role (`with_privileged_conn/1`, everything inside a rolled-back transaction). After adding the
  migration reset the throwaway DB (`docker rm -f nebu-oauth-pg`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000046_oauth_client_revocation.up.sql"
  @down "000046_oauth_client_revocation.down.sql"
  @m40 "000040_oauth_clients_and_auth_metadata"
  @earlier ~w(000040_oauth_clients_and_auth_metadata 000041_oauth_authz_requests_and_codes
              000042_oauth_sessions_and_signing_keys 000043_oauth_account_management 000044_oauth_abuse_hardening
              000045_oauth_consent_and_refresh_leases)

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp squash(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()

  defp guard_function(sql) do
    case Regex.run(~r/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+oauth_clients_guard_status\(\).*?\$\$\s+LANGUAGE\s+plpgsql\s*;/is, sql) do
      [fun] -> fun
      _ -> flunk("CREATE OR REPLACE FUNCTION oauth_clients_guard_status() ... missing")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # static
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — migration files (static)" do
    test "up and down exist as the next free number after 000045; exactly one 000046; earlier files still there" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000046_*.up.sql")) == [Path.join(@dir, @up)]
      assert Path.wildcard(Path.join(@dir, "000046_*.down.sql")) == [Path.join(@dir, @down)]
      for m <- @earlier, ext <- ~w(up down), do: assert(File.exists?(Path.join(@dir, "#{m}.#{ext}.sql")))
    end

    test "000040-000045 are untouched: none mentions the revocation columns" do
      for m <- @earlier, ext <- ~w(up down) do
        f = "#{m}.#{ext}.sql"
        refute read!(f) =~ ~r/revoked_by|revoked_at|revoked_reason/, "#{f} must not be edited (new migration instead)"
      end
    end

    test "up adds the three nullable columns idempotently" do
      sql = code_sql(@up)
      for c <- ~w(revoked_by revoked_at revoked_reason), do: assert(sql =~ ~r/ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+#{c}\b/i, "#{c}: ADD COLUMN IF NOT EXISTS")
      assert sql =~ ~r/revoked_by\s+TEXT/i and sql =~ ~r/revoked_at\s+TIMESTAMPTZ/i and sql =~ ~r/revoked_reason\s+TEXT/i
      refute sql =~ ~r/revoked_(by|at|reason)\s+(TEXT|TIMESTAMPTZ)\s+NOT\s+NULL/i
    end

    test "up re-creates the status and decision CHECKs under their old names and adds the reason CHECK (idempotent drops)" do
      sql = code_sql(@up)
      for name <- ~w(oauth_clients_status_check oauth_clients_decision_check),
          do: assert(sql =~ ~r/DROP\s+CONSTRAINT\s+IF\s+EXISTS\s+#{name}\b/i and sql =~ ~r/ADD\s+CONSTRAINT\s+#{name}\b/i, "#{name} dropped and re-added")

      assert sql =~ ~r/oauth_clients_revoked_reason_check/
      assert sql =~ ~r/'revoked'/
      assert sql =~ ~r/char_length\s*\(\s*revoked_reason\s*\)\s*<=\s*500|length\s*\(\s*revoked_reason\s*\)\s*<=\s*500/i
    end

    test "the trigger function is replaced (CREATE OR REPLACE, same name), not SECURITY DEFINER, reads no other table" do
      fun = guard_function(code_sql(@up))
      refute fun =~ ~r/SECURITY\s+DEFINER/i
      refute fun =~ ~r/\bSELECT\b/i, "the guard reads no other table"
      assert fun =~ ~r/OLD\.status\s*=\s*'approved'\s+AND\s+NEW\.status\s*=\s*'revoked'/i
      for col <- ~w(revoked_by revoked_at revoked_reason), do: assert(fun =~ ~r/OLD\.#{col}\b/i or fun =~ ~r/NEW\.#{col}\b/i)
      # every 000040 identity / metadata pin stays
      for col <- ~w(client_id metadata metadata_hash application_type token_endpoint_auth_method client_host),
          do: assert(fun =~ ~r/NEW\.#{col}\s+IS\s+DISTINCT\s+FROM\s+OLD\.#{col}/i, "guard must still pin #{col}")

      refute code_sql(@up) =~ ~r/CREATE\s+TRIGGER/i, "the trigger itself (000040) is not re-created, only its function"
    end

    test "RLS: FORCE stays, the DELETE policy is NOT re-created (pending only), the INSERT policy gains revoked_* IS NULL" do
      sql = code_sql(@up)
      refute sql =~ ~r/CREATE\s+POLICY\s+\w+\s+ON\s+oauth_clients\s+FOR\s+DELETE/i, "a revoked row is never deletable: leave the pending-only DELETE policy alone"
      refute sql =~ ~r/DISABLE\s+ROW\s+LEVEL\s+SECURITY|NO\s+FORCE/i
      [_, policy] = String.split(sql, ~r/CREATE\s+POLICY\s+oauth_clients_insert\s+ON\s+oauth_clients/i, parts: 2)
      policy = policy |> String.split(";", parts: 2) |> hd()
      for col <- ~w(approved_by approved_at rejected_by rejected_at revoked_by revoked_at),
          do: assert(policy =~ ~r/#{col}\s+IS\s+NULL/i, "INSERT policy must require #{col} IS NULL")

      assert policy =~ ~r/status\s*=\s*'pending'/i
    end

    test "no server_config / config_update_mutable change (parallel migrations may re-create it), no transaction management" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/server_config|config_update_mutable/i, "#{f}: CR3"
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
        refute sql =~ ~r/CONCURRENTLY/i
      end
    end

    test "down: refuses while a revoked row exists (BEFORE changing anything), then restores 000040 and drops the columns" do
      down = code_sql(@down)
      assert down =~ ~r/IF\s+EXISTS\s*\(\s*SELECT\s+1\s+FROM\s+oauth_clients\s+WHERE\s+status\s*=\s*'revoked'\s*\)\s+THEN\s+RAISE\s+EXCEPTION[^;]*revoked/is

      {guard_at, _} = :binary.match(down, "RAISE")
      for needle <- ["DROP COLUMN", "CREATE OR REPLACE FUNCTION", "ADD CONSTRAINT"] do
        {at, _} = :binary.match(String.upcase(down), needle)
        assert guard_at < at, "the refusal must come before #{needle}"
      end

      for c <- ~w(revoked_by revoked_at revoked_reason), do: assert(down =~ ~r/DROP\s+COLUMN\s+IF\s+EXISTS\s+#{c}\b/i)
      refute down =~ ~r/UPDATE\s+oauth_clients|DELETE\s+FROM\s+oauth_clients/i, "down never rewrites or deletes registrations"
    end

    test "down restores the 000040 trigger function VERBATIM (whitespace-insensitive) and the 000040 insert policy" do
      m40 = code_sql(@m40 <> ".up.sql")
      down = code_sql(@down)
      assert squash(guard_function(down)) == squash(guard_function(m40)), "down must restore 000040's guard function verbatim"

      [_, p40] = String.split(m40, ~r/CREATE\s+POLICY\s+oauth_clients_insert\s+ON\s+oauth_clients/i, parts: 2)
      [_, pdown] = String.split(down, ~r/CREATE\s+POLICY\s+oauth_clients_insert\s+ON\s+oauth_clients/i, parts: 2)
      assert squash(hd(String.split(pdown, ";", parts: 2))) == squash(hd(String.split(p40, ";", parts: 2)))
    end

    test "header comment names CR1-CR3 and the guard transition" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      for a <- ~w(CR1 CR2 CR3), do: assert(header =~ ~r/\b#{a}\b/, "header must reference #{a}")
      assert header =~ ~r/approved\s*->\s*revoked/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # integration
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/AC2 — migrated schema, runtime role (integration)" do
    @describetag :integration

    setup do
      {:ok, ids} = Agent.start(fn -> [] end)
      on_exit(fn -> T.cleanup_clients(Agent.get(ids, & &1)) && Agent.stop(ids) end)
      {:ok, ids: ids}
    end

    defp client!(ids, status) do
      id = "atdd-m46-" <> T.rand(8)
      Agent.update(ids, &[id | &1])
      meta = Jason.encode!(%{"client_name" => "M46", "client_uri" => "https://m46.example.com", "redirect_uris" => ["https://m46.example.com/cb"], "application_type" => "web"})
      :ok = T.insert_row!(id, meta, "hash-" <> id, status)
      id
    end

    test "columns exist, are nullable and typed", _ctx do
      %{rows: rows} =
        T.sql!("SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = 'oauth_clients' AND column_name LIKE 'revoked\\_%'")

      assert Enum.sort(rows) == [["revoked_at", "timestamp with time zone", "YES"], ["revoked_by", "text", "YES"], ["revoked_reason", "text", "YES"]]
    end

    test "the decision CHECK: every status x wrong column shape is refused, the right shapes pass (privileged, rolled back)" do
      at = "now()"

      cases = [
        # {label, status, column assignments, ok?}
        {"pending clean", "pending", [], true},
        {"pending with revoked_by", "pending", [revoked_by: "'@a:x'"], false},
        {"pending with revoked_at", "pending", [revoked_at: at], false},
        {"approved clean", "approved", [approved_by: "'@a:x'", approved_at: at], true},
        {"approved with revoked_by", "approved", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@a:x'"], false},
        {"approved with revoked_at", "approved", [approved_by: "'@a:x'", approved_at: at, revoked_at: at], false},
        {"approved with a reason", "approved", [approved_by: "'@a:x'", approved_at: at, revoked_reason: "'r'"], false},
        {"rejected clean", "rejected", [rejected_by: "'@a:x'", rejected_at: at], true},
        {"rejected with revoked_by", "rejected", [rejected_by: "'@a:x'", rejected_at: at, revoked_by: "'@a:x'"], false},
        {"revoked complete", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@r:x'", revoked_at: at], true},
        {"revoked with reason", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@r:x'", revoked_at: at, revoked_reason: "'dropped'"], true},
        {"revoked, no approved_by (attribution lost)", "revoked", [approved_at: at, revoked_by: "'@r:x'", revoked_at: at], false},
        {"revoked, no approved_at", "revoked", [approved_by: "'@a:x'", revoked_by: "'@r:x'", revoked_at: at], false},
        {"revoked, no revoked_by", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_at: at], false},
        {"revoked, no revoked_at", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@r:x'"], false},
        {"revoked with rejected_by", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@r:x'", revoked_at: at, rejected_by: "'@x:x'", rejected_at: at], false},
        {"reason of exactly 500 chars", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@r:x'", revoked_at: at, revoked_reason: "repeat('x', 500)"], true},
        {"reason of 501 chars", "revoked", [approved_by: "'@a:x'", approved_at: at, revoked_by: "'@r:x'", revoked_at: at, revoked_reason: "repeat('x', 501)"], false},
        {"status outside the closed set", "bogus", [], false}
      ]

      T.with_privileged_conn(fn conn ->
        for {label, status, cols, ok?} <- cases do
          {:error, outcome} =
            Postgrex.transaction(conn, fn tx ->
              id = "atdd-m46c-" <> T.rand(6)
              names = Enum.map_join(cols, "", fn {k, _} -> ", #{k}" end)
              vals = Enum.map_join(cols, "", fn {_, v} -> ", #{v}" end)

              outcome =
                try do
                  Postgrex.query!(
                    tx,
                    "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status#{names}) VALUES ('#{id}', '{}'::jsonb, 'h-#{id}', '#{status}'#{vals})",
                    []
                  )

                  :accepted
                rescue
                  e in Postgrex.Error -> {:refused, e.postgres.code}
                end

              Postgrex.rollback(tx, outcome)
            end)

          if ok?,
            do: assert(outcome == :accepted, "#{label}: must be accepted, got #{inspect(outcome)}"),
            else: assert(outcome == {:refused, :check_violation}, "#{label}: must be refused with check_violation, got #{inspect(outcome)}")
        end
      end)
    end

    test "AC1.3 — the runtime role cannot INSERT a revoked row nor any revoked_* value (RLS / CHECK)" do
      for {label, cols, vals} <- [
            {"status revoked", "status, approved_by, approved_at, revoked_by, revoked_at", "'revoked', '@a:x', now(), '@r:x', now()"},
            {"pending with revoked_by", "revoked_by", "'@r:x'"},
            {"pending with revoked_at", "revoked_at", "now()"},
            {"pending with a reason", "revoked_reason", "'x'"}
          ] do
        id = "atdd-m46i-" <> T.rand(6)

        assert_raise Postgrex.Error, ~r/row-level security|check constraint/i, fn ->
          T.sql!("INSERT INTO oauth_clients (client_id, metadata, metadata_hash, #{cols}) VALUES ('#{id}', '{}'::jsonb, 'h-#{id}', #{vals})")
        end

        assert T.client_row(id) == nil, "#{label}: no row may remain"
      end
    end

    test "AC2.1 — approved -> revoked with revoked_by/revoked_at (+ reason) succeeds; last_used_at stays writable", %{ids: ids} do
      id = client!(ids, "approved")
      before = T.client_row(id)

      assert %{num_rows: 1} =
               T.sql!("UPDATE oauth_clients SET status = 'revoked', revoked_by = '@root:test.local', revoked_at = now(), revoked_reason = 'lost the signing key' WHERE client_id = $1", [id])

      row = T.client_row(id)
      assert row["status"] == "revoked" and row["revoked_by"] == "@root:test.local" and row["revoked_at"] != nil
      assert row["revoked_reason"] == "lost the signing key"
      assert {row["approved_by"], row["approved_at"]} == {before["approved_by"], before["approved_at"]}, "attribution is kept"

      assert %{num_rows: 1} = T.sql!("UPDATE oauth_clients SET last_used_at = now() WHERE client_id = $1", [id])
    end

    test "AC2.2 — every other transition / edit of a decided row is check_violation", %{ids: ids} do
      revoked = fn -> client!(ids, "approved") |> tap(&T.mark_revoked!(&1, "@root:test.local", "r")) end

      attempts = [
        {"revoked -> approved", revoked, "SET status = 'approved', revoked_by = NULL, revoked_at = NULL, revoked_reason = NULL"},
        {"revoked -> approved (only status)", revoked, "SET status = 'approved'"},
        {"revoked -> pending", revoked, "SET status = 'pending', approved_by = NULL, approved_at = NULL, revoked_by = NULL, revoked_at = NULL, revoked_reason = NULL"},
        {"revoked -> rejected", revoked, "SET status = 'rejected', approved_by = NULL, approved_at = NULL, rejected_by = '@a:x', rejected_at = now(), revoked_by = NULL, revoked_at = NULL, revoked_reason = NULL"},
        {"re-attributed revoked_by", revoked, "SET revoked_by = '@other:test.local'"},
        {"changed revoked_at", revoked, "SET revoked_at = now() + interval '1 day'"},
        {"edited revoked_reason", revoked, "SET revoked_reason = 'rewritten history'"},
        {"cleared revoked_reason", revoked, "SET revoked_reason = NULL"},
        {"revoked, approved_by changed", revoked, "SET approved_by = '@forged:test.local'"},
        {"revoked, metadata rewritten", revoked, "SET metadata = '{\"x\":1}'::jsonb"},
        {"approved -> revoked, revoked_by NULL", fn -> client!(ids, "approved") end, "SET status = 'revoked', revoked_at = now()"},
        {"approved -> revoked, revoked_at NULL", fn -> client!(ids, "approved") end, "SET status = 'revoked', revoked_by = '@r:x'"},
        {"approved -> revoked, approved_by changed", fn -> client!(ids, "approved") end, "SET status = 'revoked', revoked_by = '@r:x', revoked_at = now(), approved_by = '@forged:x'"},
        {"approved -> revoked, approved_at changed", fn -> client!(ids, "approved") end, "SET status = 'revoked', revoked_by = '@r:x', revoked_at = now(), approved_at = now() + interval '1 day'"},
        {"approved -> rejected", fn -> client!(ids, "approved") end, "SET status = 'rejected', approved_by = NULL, approved_at = NULL, rejected_by = '@a:x', rejected_at = now()"},
        {"approved: revoked_by without status change", fn -> client!(ids, "approved") end, "SET revoked_by = '@r:x'"},
        {"pending -> revoked (skips the approval)", fn -> client!(ids, "pending") end, "SET status = 'revoked', approved_by = '@a:x', approved_at = now(), revoked_by = '@r:x', revoked_at = now()"},
        {"rejected -> revoked", fn -> client!(ids, "rejected") end, "SET status = 'revoked', rejected_by = NULL, rejected_at = NULL, approved_by = '@a:x', approved_at = now(), revoked_by = '@r:x', revoked_at = now()"},
        {"rejected -> revoked (rejection kept)", fn -> client!(ids, "rejected") end, "SET status = 'revoked', revoked_by = '@r:x', revoked_at = now()"}
      ]

      for {label, mk, set} <- attempts do
        id = mk.()
        before = T.client_row(id)

        try do
          T.sql!("UPDATE oauth_clients #{set} WHERE client_id = $1", [id])
          flunk("#{label}: the update must be refused")
        rescue
          e in Postgrex.Error ->
            assert e.postgres.code == :check_violation, "#{label}: expected check_violation, got #{inspect(e.postgres)}"
        end

        assert T.client_row(id) == before, "#{label}: nothing may change"
      end
    end

    test "AC2.3 — DELETE of a revoked row matches 0 rows (FORCE RLS: only pending rows are deletable)", %{ids: ids} do
      id = client!(ids, "approved")
      :ok = T.mark_revoked!(id)
      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_clients WHERE client_id = $1", [id])
      assert T.client_row(id)["status"] == "revoked"
    end

    test "RLS: FORCE still on, DELETE policy still pending-only, INSERT policy carries the revoked_* clauses" do
      assert %{rows: [[true, true]]} = T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'oauth_clients'")

      %{rows: delete} = T.sql!("SELECT policyname, qual FROM pg_policies WHERE tablename = 'oauth_clients' AND cmd = 'DELETE'")
      assert [[_name, qual]] = delete
      assert qual =~ ~r/status\s*=\s*'pending'/

      %{rows: [[with_check]]} = T.sql!("SELECT with_check FROM pg_policies WHERE tablename = 'oauth_clients' AND policyname = 'oauth_clients_insert'")
      assert with_check =~ ~r/revoked_by IS NULL/ and with_check =~ ~r/revoked_at IS NULL/
    end
  end

  describe "AC1.4 — down / up (privileged role, every scenario in a rolled-back transaction)" do
    @describetag :integration

    defp run_script(tx, file), do: Postgrex.query!(tx, read!(file), [], query_type: :text)

    defp insert_revoked!(tx) do
      id = "atdd-m46d-" <> T.rand(6)

      Postgrex.query!(
        tx,
        "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status, approved_by, approved_at, revoked_by, revoked_at) " <>
          "VALUES ('#{id}', '{}'::jsonb, 'h-#{id}', 'revoked', '@a:x', now(), '@r:x', now())",
        []
      )

      id
    end

    test "up -> down -> up round trip without revoked rows: down restores 000040 shape, up restores 000046, up is idempotent" do
      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            cols = "SELECT count(*) FROM information_schema.columns WHERE table_name = 'oauth_clients' AND column_name LIKE 'revoked\\_%'"
            def_of = fn name -> Postgrex.query!(tx, "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [name]).rows |> List.flatten() |> hd() end

            run_script(tx, @down)
            %{rows: [[0]]} = Postgrex.query!(tx, cols, [])
            refute def_of.("oauth_clients_status_check") =~ "revoked"
            refute def_of.("oauth_clients_decision_check") =~ "revoked"
            %{rows: [[fun]]} = Postgrex.query!(tx, "SELECT pg_get_functiondef('oauth_clients_guard_status'::regproc)", [])
            refute fun =~ "revoked", "000040's guard function is back"
            %{rows: [[wc]]} = Postgrex.query!(tx, "SELECT with_check FROM pg_policies WHERE tablename = 'oauth_clients' AND policyname = 'oauth_clients_insert'", [])
            refute wc =~ "revoked"
            %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_trigger WHERE tgname = 'oauth_clients_guard_status' AND NOT tgisinternal", [])
            %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_policies WHERE tablename = 'oauth_clients' AND cmd = 'DELETE'", [])

            run_script(tx, @up)
            %{rows: [[3]]} = Postgrex.query!(tx, cols, [])
            assert def_of.("oauth_clients_status_check") =~ "revoked"
            assert def_of.("oauth_clients_decision_check") =~ "revoked"
            assert def_of.("oauth_clients_revoked_reason_check") =~ "500"
            %{rows: [[fun2]]} = Postgrex.query!(tx, "SELECT pg_get_functiondef('oauth_clients_guard_status'::regproc)", [])
            assert fun2 =~ "revoked"

            # idempotent: applying up on an already migrated schema is a no-op
            run_script(tx, @up)
            %{rows: [[3]]} = Postgrex.query!(tx, cols, [])
            # a revoked row is valid again after the round trip
            insert_revoked!(tx)
            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end

    test "down RAISES while a revoked row exists and changes nothing (never turns revoked into approved)" do
      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            id = insert_revoked!(tx)
            err = catch_error(run_script(tx, @down))
            assert %Postgrex.Error{postgres: %{message: message}} = err
            assert message =~ ~r/revoked/i
            Postgrex.rollback(tx, {:refused, id})
          end)
        end)

      assert {:error, {:refused, _id}} = result

      # the failed script left the real schema alone (it ran in a rolled-back transaction, and the columns are still there)
      assert %{rows: [[3]]} = T.sql!("SELECT count(*) FROM information_schema.columns WHERE table_name = 'oauth_clients' AND column_name LIKE 'revoked\\_%'")
    end

    test "after the refusal path, down WORKS once no revoked row is left (approved rows keep their attribution)" do
      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            id = "atdd-m46e-" <> T.rand(6)

            Postgrex.query!(
              tx,
              "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status, approved_by, approved_at) VALUES ('#{id}', '{}'::jsonb, 'h-#{id}', 'approved', '@a:x', now())",
              []
            )

            run_script(tx, @down)
            %{rows: [["approved", "@a:x"]]} = Postgrex.query!(tx, "SELECT status, approved_by FROM oauth_clients WHERE client_id = '#{id}'", [])
            Postgrex.rollback(tx, :ok_down)
          end)
        end)

      assert result == {:error, :ok_down}
    end
  end
end
