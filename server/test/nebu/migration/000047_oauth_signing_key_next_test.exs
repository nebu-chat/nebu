defmodule Nebu.Migration.Migration000047OauthSigningKeyNextTest do
  @moduledoc """
  Acceptance tests for story `oauth-hardening-hygiene`, AC10 (decision HY11): migration
  `000047_oauth_signing_key_next` (the highest committed migration at ATDD time is 000046; the story text
  may say 000048 in places, 000047 is the next free number).

  Pinned names (the migration uses exactly these; changing one means changing this test):

    * `oauth_signing_keys.status` admits `next` (constraint `oauth_signing_keys_status_check`, re-created under
      its auto-generated 000042 name); `oauth_signing_keys_retired_check` (same name) becomes
      `(status IN ('active','next') AND retired_at IS NULL) OR (status = 'retired' AND retired_at IS NOT NULL)`.
    * partial UNIQUE index `oauth_signing_keys_one_next ON oauth_signing_keys (status) WHERE status = 'next'`.
    * policy `oauth_signing_keys_insert` (same name) admits `status IN ('active','next') AND retired_at IS NULL AND
      not_after IS NULL`. FORCE RLS stays; no DELETE policy; no new grants.
    * `oauth_signing_keys_guard()` is replaced (same name, same trigger) and keeps EVERY 000042 rule (immutable key
      material, `retired -> active` forbidden, retiring needs `retired_at`, `not_after` only raised) plus:
      `active -> next` forbidden, `retired -> next` forbidden, `next -> active` only when
      `OLD.created_at <= now() - interval '900 seconds'` (JWKS max-age 600 s + id_token lifetime 300 s),
      `next -> retired` needs `retired_at`.
    * `.down.sql`: deletes `next` rows (FORCE RLS binds the table owner and there is NO DELETE policy: wrap the
      DELETE in `ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` / `FORCE ROW LEVEL SECURITY` unless the migrator is a
      superuser; the integration test runs it as the CI migrator role and checks FORCE is back), restores the 000042
      CHECKs, policy and guard function body verbatim, drops the index. up -> down -> up is green and the up is
      idempotent (`DROP ... IF EXISTS` / `CREATE OR REPLACE`).

  Static SQL analysis plus `:integration` behaviour as the RUNTIME role (`nebu_app`, through `Nebu.Repo`) and the
  privileged migrate role (`with_privileged_conn/1`, inside rolled-back transactions). After adding the migration
  reset the throwaway DB (`docker rm -f nebu-oauth-pg`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000047_oauth_signing_key_next.up.sql"
  @down "000047_oauth_signing_key_next.down.sql"
  @m42 "000042_oauth_sessions_and_signing_keys.up.sql"
  @earlier ~w(000040_oauth_clients_and_auth_metadata 000041_oauth_authz_requests_and_codes
              000042_oauth_sessions_and_signing_keys 000043_oauth_account_management 000044_oauth_abuse_hardening
              000045_oauth_consent_and_refresh_leases 000046_oauth_client_revocation)

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp squash(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()

  defp guard_function(sql) do
    case Regex.run(~r/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+oauth_signing_keys_guard\(\).*?\$\$\s+LANGUAGE\s+plpgsql\s*;/is, sql) do
      [fun] -> fun
      _ -> flunk("CREATE OR REPLACE FUNCTION oauth_signing_keys_guard() ... missing")
    end
  end

  defp insert_policy(sql) do
    [_, rest] = String.split(sql, ~r/CREATE\s+POLICY\s+oauth_signing_keys_insert\s+ON\s+oauth_signing_keys/i, parts: 2)
    rest |> String.split(";", parts: 2) |> hd()
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.1 — static
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10.1 — migration files (static)" do
    test "up and down exist as 000047, the first number after 000046; exactly one 000047; earlier files still there" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000047_*.up.sql")) == [Path.join(@dir, @up)]
      assert Path.wildcard(Path.join(@dir, "000047_*.down.sql")) == [Path.join(@dir, @down)]
      # (no refutation of 000048: the next story's migration must not turn this test red)
      for m <- @earlier, ext <- ~w(up down), do: assert(File.exists?(Path.join(@dir, "#{m}.#{ext}.sql")))
    end

    test "000040-000046 are untouched: none mentions the `next` status or its index" do
      for m <- @earlier, ext <- ~w(up down) do
        f = "#{m}.#{ext}.sql"
        refute read!(f) =~ ~r/oauth_signing_keys_one_next/, "#{f} must not be edited (new migration instead)"
      end

      refute code_sql(@m42) =~ ~r/'next'/, "000042 must not be edited"
    end

    test "up: idempotent statements only (DROP ... IF EXISTS / IF NOT EXISTS / CREATE OR REPLACE), no grants, FORCE RLS untouched" do
      sql = code_sql(@up)

      for name <- ~w(oauth_signing_keys_status_check oauth_signing_keys_retired_check),
          do: assert(sql =~ ~r/DROP\s+CONSTRAINT\s+IF\s+EXISTS\s+#{name}\b/i, "#{name}: DROP CONSTRAINT IF EXISTS before the re-add")

      assert sql =~ ~r/CREATE\s+UNIQUE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+oauth_signing_keys_one_next\b/i
      assert sql =~ ~r/DROP\s+POLICY\s+IF\s+EXISTS\s+oauth_signing_keys_insert\b/i
      assert sql =~ ~r/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+oauth_signing_keys_guard\(\)/i
      refute sql =~ ~r/NO\s+FORCE|DISABLE\s+ROW\s+LEVEL\s+SECURITY|\bGRANT\b/i
      refute sql =~ ~r/SECURITY\s+DEFINER/i
      # (the CHECKs, the index, the policy and the 900 s guard are pinned by the behaviour tests below)
    end

    test "header comment names HY11 and the 900 s rule; no transaction management; idempotent function replace" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      assert header =~ ~r/\bHY11\b/
      assert header =~ ~r/900/
      sql = code_sql(@up)
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
      refute sql =~ ~r/server_config|config_update_mutable/i, "this migration does not touch the config allowlist"
    end

    test "down: deletes next rows, restores 000042's CHECKs / policy / guard function VERBATIM, drops the index, FORCE RLS ends up on" do
      down = code_sql(@down)
      m42 = code_sql(@m42)

      assert down =~ ~r/DELETE\s+FROM\s+oauth_signing_keys\s+WHERE\s+status\s*=\s*'next'/i
      assert down =~ ~r/DROP\s+INDEX\s+IF\s+EXISTS\s+oauth_signing_keys_one_next/i

      assert squash(guard_function(down)) == squash(guard_function(m42)), "down must restore 000042's guard function verbatim"

      [_, p42] = String.split(m42, ~r/CREATE\s+POLICY\s+oauth_signing_keys_insert\s+ON\s+oauth_signing_keys/i, parts: 2)
      assert squash(hd(String.split(insert_policy(down), ";", parts: 2))) == squash(hd(String.split(p42, ";", parts: 2)))

      assert down =~ ~r/status\s+IN\s*\(\s*'active'\s*,\s*'retired'\s*\)/i, "the 000042 status CHECK is back"
      refute down =~ ~r/status\s+IN\s*\(\s*'active'\s*,\s*'next'/i

      # FORCE RLS binds the table owner and there is no DELETE policy: the migration must leave FORCE ON
      [{delete_at, _}] = Regex.run(~r/DELETE\s+FROM\s+oauth_signing_keys/i, down, return: :index)
      forces = Regex.scan(~r/(NO\s+)?FORCE\s+ROW\s+LEVEL\s+SECURITY/i, down, return: :index)
      refute forces == [], "the down migration must handle FORCE RLS around its DELETE (NO FORCE ... FORCE)"
      {last_at, last_len} = forces |> List.last() |> hd()
      refute String.slice(down, last_at, last_len) =~ ~r/NO\s+FORCE/i, "the LAST row-level-security statement must be FORCE (restored)"
      assert last_at > delete_at, "FORCE is restored after the DELETE"
      refute down =~ ~r/DISABLE\s+ROW\s+LEVEL\s+SECURITY/i
    end

    test "the next-key audit / rotation semantic is documented where the operator reads it (header of the down warns about data loss)" do
      header = read!(@down) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      assert header =~ ~r/next/i, "the down header must say that a published next key is discarded"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.2 — behaviour as the runtime role (integration)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10.2 — migrated schema, runtime role nebu_app (integration)" do
    @describetag :integration

    setup do
      T.reset_signing_keys!()
      on_exit(&T.reset_signing_keys!/0)
      :ok
    end

    defp kid, do: "atdd-m47-" <> T.rand(6)

    defp insert_key!(status, opts \\ []) do
      k = Keyword.get(opts, :kid, kid())
      created = Keyword.get(opts, :created_sql, "now()")

      T.sql!(
        "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status, created_at) " <>
          "VALUES ($1, 'ES256', '{\"kty\":\"EC\"}'::jsonb, $2, $3, #{created})",
        [k, "enc-" <> k, status]
      )

      k
    end

    # the runtime role as the application uses it; errors come back as their SQLSTATE atom
    defp attempt(statements, params \\ [])
    defp attempt(sql, params) when is_binary(sql), do: attempt([{sql, params}], [])

    defp attempt(statements, _params) when is_list(statements) do
      Nebu.Repo.transaction(fn ->
        Enum.each(statements, fn {sql, params} -> Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params) end)
      end)

      :ok
    rescue
      e in Postgrex.Error -> {:error, e.postgres.code}
    end

    defp status_of(k), do: T.sql!("SELECT status FROM oauth_signing_keys WHERE kid = $1", [k]).rows

    defp retire_sql, do: "UPDATE oauth_signing_keys SET status = 'retired', retired_at = now(), not_after = now() + interval '900 seconds' WHERE status = 'active'"

    test "a status next row can be inserted by the runtime role" do
      k = insert_key!("next")
      assert status_of(k) == [["next"]]
    end

    test "a second next row fails (partial unique index oauth_signing_keys_one_next)" do
      insert_key!("next")

      assert {:error, :unique_violation} =
               attempt(
                 "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status) VALUES ($1, 'ES256', '{}'::jsonb, 'x', 'next')",
                 [kid()]
               )

      %{rows: [[1]]} = T.sql!("SELECT count(*) FROM oauth_signing_keys WHERE status = 'next'")
    end

    test "active and next coexist (a next row never conflicts with the lazy generator's active row)" do
      insert_key!("active")
      insert_key!("next")
      %{rows: [[2]]} = T.sql!("SELECT count(*) FROM oauth_signing_keys")
    end

    test "the runtime role cannot INSERT a retired row (policy), nor a next row with retired_at / not_after" do
      for {label, cols, vals} <- [
            {"retired", "status, retired_at, not_after", "'retired', now(), now() + interval '1 day'"},
            {"next with retired_at", "status, retired_at", "'next', now()"},
            {"next with not_after", "status, not_after", "'next', now() + interval '1 day'"}
          ] do
        k = kid()

        # the RLS WITH CHECK of the insert policy fires first: SQLSTATE 42501 (insufficient_privilege)
        assert {:error, :insufficient_privilege} =
                 attempt(
                   "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, #{cols}) VALUES ('#{k}', 'ES256', '{}'::jsonb, 'x', #{vals})"
                 ),
               "#{label}: the insert policy must refuse it"

        assert status_of(k) == [], "#{label}: no row may remain"
      end
    end

    test "an unknown status is refused by the CHECK" do
      assert_raise Postgrex.Error, ~r/check constraint|row-level security/i, fn ->
        T.sql!("INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status) VALUES ('#{kid()}', 'ES256', '{}'::jsonb, 'x', 'bogus')")
      end
    end

    test "next -> active younger than 900 s fails (check_violation) even with the old active key retired in the same transaction" do
      old = insert_key!("active")
      nxt = insert_key!("next")

      assert {:error, :check_violation} =
               attempt([{retire_sql(), []}, {"UPDATE oauth_signing_keys SET status = 'active' WHERE kid = $1", [nxt]}])

      assert status_of(old) == [["active"]], "the failed transaction rolled back"
      assert status_of(nxt) == [["next"]]
    end

    test "a next row of 899 s is still too young, 900 s and older (inserted with a backdated created_at) is promotable" do
      young = insert_key!("next", created_sql: "now() - interval '890 seconds'")
      insert_key!("active")

      assert {:error, :check_violation} =
               attempt([{retire_sql(), []}, {"UPDATE oauth_signing_keys SET status = 'active' WHERE kid = $1", [young]}])

      T.reset_signing_keys!()
      old2 = insert_key!("active")
      nxt = insert_key!("next", created_sql: "now() - interval '901 seconds'")

      assert :ok =
               attempt([{retire_sql(), []}, {"UPDATE oauth_signing_keys SET status = 'active' WHERE kid = $1", [nxt]}])

      assert status_of(nxt) == [["active"]]
      assert status_of(old2) == [["retired"]]
    end

    test "promotion while the old key is still active => unique_violation (one active key)" do
      insert_key!("active")
      nxt = insert_key!("next", created_sql: "now() - interval '901 seconds'")
      assert {:error, :unique_violation} = attempt("UPDATE oauth_signing_keys SET status = 'active' WHERE kid = $1", [nxt])
    end

    test "active -> next and retired -> next are forbidden" do
      act = insert_key!("active")
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET status = 'next' WHERE kid = $1", [act])
      assert status_of(act) == [["active"]]

      assert :ok = attempt(retire_sql())
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET status = 'next', retired_at = NULL, not_after = NULL WHERE kid = $1", [act])
      assert status_of(act) == [["retired"]]
    end

    test "next -> retired WITHOUT retired_at fails; with retired_at succeeds" do
      nxt = insert_key!("next")
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET status = 'retired' WHERE kid = $1", [nxt])
      assert status_of(nxt) == [["next"]]

      assert :ok = attempt("UPDATE oauth_signing_keys SET status = 'retired', retired_at = now(), not_after = now() + interval '900 seconds' WHERE kid = $1", [nxt])
      assert status_of(nxt) == [["retired"]]
    end

    test "every 000042 rule still holds: key material immutable, retired -> active forbidden, not_after only raised" do
      act = insert_key!("active")
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET private_jwk_enc = 'forged' WHERE kid = $1", [act])
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET public_jwk = '{}'::jsonb WHERE kid = $1", [act])
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET created_at = now() - interval '1 day' WHERE kid = $1", [act])
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET status = 'retired' WHERE kid = $1", [act])

      assert :ok = attempt(retire_sql())
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET status = 'active', retired_at = NULL, not_after = NULL WHERE kid = $1", [act])
      assert {:error, :check_violation} = attempt("UPDATE oauth_signing_keys SET not_after = now() WHERE kid = $1", [act])
      assert :ok = attempt("UPDATE oauth_signing_keys SET not_after = now() + interval '2 days' WHERE kid = $1", [act])
    end

    test "RLS: FORCE still on and still no DELETE policy (the runtime role deletes nothing)" do
      assert %{rows: [[true, true]]} = T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'oauth_signing_keys'")
      assert %{rows: []} = T.sql!("SELECT 1 FROM pg_policies WHERE tablename = 'oauth_signing_keys' AND cmd = 'DELETE'")
      k = insert_key!("next")
      assert :ok = attempt("DELETE FROM oauth_signing_keys WHERE kid = $1", [k])
      assert status_of(k) == [["next"]], "the runtime role must not be able to delete a key row"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.3 — down / up (privileged role, rolled-back transactions)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10.3 — down / up (privileged role, every scenario in a rolled-back transaction)" do
    @describetag :integration

    defp run_script(tx, file), do: Postgrex.query!(tx, read!(file), [], query_type: :text)

    defp def_of(tx, name),
      do: Postgrex.query!(tx, "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [name]).rows |> List.flatten() |> hd()

    defp insert_next!(tx) do
      k = "atdd-m47d-" <> T.rand(6)

      Postgrex.query!(
        tx,
        "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status) VALUES ('#{k}', 'ES256', '{}'::jsonb, 'enc', 'next')",
        []
      )

      k
    end

    test "down (CI migrator role, FORCE RLS) deletes next rows and restores 000042, FORCE stays on; up -> 000047 again, idempotent" do
      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            # test review M10: the down must not rely on a superuser (a superuser bypasses RLS and would make the
            # NO FORCE / FORCE handling untested); the CI migrator role is a plain (BYPASSRLS) owner role
            assert %{rows: [[false]]} = Postgrex.query!(tx, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user", [])
            nxt = insert_next!(tx)

            run_script(tx, @down)
            assert %{rows: []} = Postgrex.query!(tx, "SELECT 1 FROM oauth_signing_keys WHERE kid = '#{nxt}'", []), "the next row is gone"
            assert %{rows: [[0]]} = Postgrex.query!(tx, "SELECT count(*) FROM oauth_signing_keys WHERE status = 'next'", [])
            refute def_of(tx, "oauth_signing_keys_status_check") =~ "next"
            refute def_of(tx, "oauth_signing_keys_retired_check") =~ "next"
            assert %{rows: [[fun]]} = Postgrex.query!(tx, "SELECT pg_get_functiondef('oauth_signing_keys_guard'::regproc)", [])
            refute fun =~ "next"
            refute fun =~ "900"
            assert %{rows: [[wc]]} = Postgrex.query!(tx, "SELECT with_check FROM pg_policies WHERE tablename = 'oauth_signing_keys' AND policyname = 'oauth_signing_keys_insert'", [])
            refute wc =~ "next"
            assert %{rows: [[0]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE indexname = 'oauth_signing_keys_one_next'", [])
            assert %{rows: [[true, true]]} = Postgrex.query!(tx, "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'oauth_signing_keys'", [])
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_trigger WHERE tgname = 'oauth_signing_keys_guard' AND NOT tgisinternal", [])
            assert %{rows: []} = Postgrex.query!(tx, "SELECT 1 FROM pg_policies WHERE tablename = 'oauth_signing_keys' AND cmd = 'DELETE'", [])

            run_script(tx, @up)
            assert def_of(tx, "oauth_signing_keys_status_check") =~ "next"
            assert def_of(tx, "oauth_signing_keys_retired_check") =~ "next"
            assert %{rows: [[fun2]]} = Postgrex.query!(tx, "SELECT pg_get_functiondef('oauth_signing_keys_guard'::regproc)", [])
            assert fun2 =~ "next" and fun2 =~ "900"
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE indexname = 'oauth_signing_keys_one_next'", [])

            # idempotent: applying up on an already migrated schema is a no-op
            run_script(tx, @up)
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE indexname = 'oauth_signing_keys_one_next'", [])
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_trigger WHERE tgname = 'oauth_signing_keys_guard' AND NOT tgisinternal", [])

            # a next row is valid again after the round trip
            insert_next!(tx)
            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end

    test "down keeps active and retired rows untouched" do
      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "DELETE FROM oauth_signing_keys", [])

            Postgrex.query!(tx, "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status) VALUES ('m47-act', 'ES256', '{}'::jsonb, 'enc-a', 'active')", [])

            Postgrex.query!(
              tx,
              "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status, created_at) VALUES ('m47-nxt', 'ES256', '{}'::jsonb, 'enc-n', 'next', now() - interval '2 hours')",
              []
            )

            run_script(tx, @down)
            assert %{rows: [["m47-act", "active"]]} = Postgrex.query!(tx, "SELECT kid, status FROM oauth_signing_keys ORDER BY kid", [])
            Postgrex.rollback(tx, :kept)
          end)
        end)

      assert result == {:error, :kept}
    end
  end
end
