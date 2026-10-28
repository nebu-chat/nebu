defmodule Nebu.Migration.Migration000043OauthAccountManagementTest do
  @moduledoc """
  Acceptance tests for story `oauth-account-management` (story 6 of epic oauth-broker),
  AC11 / A24 / Must #36: migration `000043_oauth_account_management` (`oauth_account_login_requests`,
  `oauth_account_sessions`, the pending-reset index on `uia_sessions`). Mirrors the 000041/000042
  tests: static SQL analysis (no DB) plus `:integration` introspection, runtime-role (`nebu_app`)
  behaviour and a down/up round trip on the privileged role inside a rolled-back transaction.

  Pinned names (the dev MUST use exactly these; changing one means changing this test):

    * `oauth_account_login_requests`: `state_hash` TEXT PRIMARY KEY (64 lowercase hex),
      `idp_verifier_enc` TEXT NOT NULL (SecretBox ciphertext), `idp_nonce` TEXT NOT NULL,
      `binding_hash` TEXT NOT NULL (64 hex), `return_action` TEXT NULL (NULL = default page; else one
      of the five actions), `return_device_id` TEXT NULL (review cycle 1: no `return_session_id`, it was never used),
      `replaces_session_hash` TEXT NULL (64 hex when set), `created_at` TIMESTAMPTZ NOT NULL DEFAULT
      now(), `expires_at` TIMESTAMPTZ NOT NULL; CHECK `expires_at <= created_at + interval '10 minutes'`.
    * `oauth_account_sessions`: `session_hash` TEXT PRIMARY KEY (64 hex), `user_id` TEXT NOT NULL,
      `auth_time` BIGINT NOT NULL (unix seconds), `csrf_hash` TEXT NOT NULL (64 hex), `created_at`,
      `last_seen_at`, `idle_expires_at`, `expires_at` TIMESTAMPTZ NOT NULL; CHECKs `expires_at <=
      created_at + interval '1 hour'` and `idle_expires_at <= expires_at`.
    * Indexes: `uia_sessions_user_op_pending_idx ON uia_sessions (user_id, op) WHERE consumed = FALSE`;
      `oauth_account_login_requests_expires_idx (expires_at)`, `oauth_account_sessions_expires_idx
      (expires_at)`, `oauth_account_sessions_user_idx (user_id, ...)` (per-user cap, A19).
    * Grants to `nebu_app`: login requests `SELECT, INSERT, DELETE` (NO UPDATE); sessions `SELECT,
      INSERT, UPDATE, DELETE`.
    * RLS ENABLE + FORCE on both tables; open policies per granted command:
      `oauth_account_login_requests_{select,insert,delete}`,
      `oauth_account_sessions_{select,insert,update,delete}`; no other policies.
    * No `server_config` change (`config_update_mutable` untouched); `.down.sql` drops exactly what
      `.up.sql` created; 000040-000042 are not edited.

  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000043_oauth_account_management.up.sql"
  @down "000043_oauth_account_management.down.sql"

  @lr "oauth_account_login_requests"
  @sess "oauth_account_sessions"
  @lr_cols ~w(state_hash idp_verifier_enc idp_nonce binding_hash return_action return_device_id
              replaces_session_hash created_at expires_at)
  @sess_cols ~w(session_hash user_id auth_time csrf_hash created_at last_seen_at idle_expires_at expires_at)
  @actions ~w(org.matrix.profile org.matrix.devices_list org.matrix.device_view org.matrix.device_delete
              org.matrix.cross_signing_reset)
  @earlier ~w(000040_oauth_clients_and_auth_metadata 000041_oauth_authz_requests_and_codes 000042_oauth_sessions_and_signing_keys)

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp table_sql(sql, table) do
    case Regex.split(~r/CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?#{table}\s*\(/i, sql, parts: 2) do
      [_, rest] -> rest |> String.split(~r/\n\);/, parts: 2) |> hd()
      _ -> flunk("CREATE TABLE #{table} missing")
    end
  end

  defp grant_of(sql, table) do
    (Regex.run(~r/GRANT\s+[^;]*ON\s+(TABLE\s+)?#{table}\s+TO\s+nebu_app/is, sql) || [nil]) |> hd() ||
      flunk("GRANT ... ON #{table} TO nebu_app missing")
  end

  defp policies(sql, table, cmd),
    do: Regex.scan(~r/CREATE\s+POLICY\s+(\w+)\s+ON\s+#{table}\s+FOR\s+#{cmd}\b[^;]*/i, sql) |> Enum.map(&Enum.at(&1, 1))

  # ════════════════════════════════════════════════════════════════════════════
  # static
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11/A24 — migration files (static)" do
    test "up and down exist as the next free number; exactly one 000043; 000040-000042 still there" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000043_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000043 migration"
      for m <- @earlier, ext <- ~w(up down), do: assert(File.exists?(Path.join(@dir, "#{m}.#{ext}.sql")))
    end

    test "000040-000042 are untouched (git: no diff against HEAD; no story-6 names in them)" do
      for m <- @earlier, ext <- ~w(up down) do
        f = "#{m}.#{ext}.sql"
        refute read!(f) =~ ~r/oauth_account_|uia_sessions_user_op_pending_idx/, "#{f} must not be edited (new migration instead)"
      end

      # git is not available in every test container: the check runs where it is (dev / CI checkout)
      if System.find_executable("git") do
        files = Enum.flat_map(@earlier, &["priv/migrations/#{&1}.up.sql", "priv/migrations/#{&1}.down.sql"])
        {out, status} = System.cmd("git", ["diff", "--name-only", "HEAD", "--"] ++ files, cd: Path.expand("../../..", __DIR__), stderr_to_stdout: true)
        if status == 0, do: assert(String.trim(out) == "", "earlier migrations changed: #{out}")
      end
    end

    test "oauth_account_login_requests: columns, PK, NOT NULLs, 10-minute CHECK, return_action CHECK over the five actions" do
      t = table_sql(code_sql(@up), @lr)
      for c <- @lr_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/state_hash\s+TEXT\s+PRIMARY\s+KEY/i
      for c <- ~w(idp_verifier_enc idp_nonce binding_hash), do: assert(t =~ ~r/#{c}\s+TEXT\s+NOT\s+NULL/i, "#{c} TEXT NOT NULL")
      assert t =~ ~r/created_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/expires_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/expires_at\s*<=\s*created_at\s*\+\s*interval\s+'10 minutes'/i
      for a <- @actions, do: assert(t =~ "'#{a}'", "return_action CHECK must allow #{a}")
      refute t =~ "org.matrix.account_deactivate", "account_deactivate is not supported (A5)"
      refute t =~ ~r/\b(verifier|nonce|state|cookie|binding)\s+TEXT/i, "no plaintext state / verifier / binding column"
    end

    test "oauth_account_sessions: columns, PK, NOT NULLs, 1-hour CHECK, idle <= absolute CHECK" do
      t = table_sql(code_sql(@up), @sess)
      for c <- @sess_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/session_hash\s+TEXT\s+PRIMARY\s+KEY/i
      assert t =~ ~r/user_id\s+TEXT\s+NOT\s+NULL/i
      assert t =~ ~r/auth_time\s+BIGINT\s+NOT\s+NULL/i
      assert t =~ ~r/csrf_hash\s+TEXT\s+NOT\s+NULL/i
      for c <- ~w(created_at last_seen_at idle_expires_at expires_at), do: assert(t =~ ~r/#{c}\s+TIMESTAMPTZ\s+NOT\s+NULL/i, "#{c}")
      assert t =~ ~r/expires_at\s*<=\s*created_at\s*\+\s*interval\s+'1 hour'/i
      assert t =~ ~r/idle_expires_at\s*<=\s*expires_at/i
      refute t =~ ~r/\b(session_id|cookie|csrf_token)\b/i, "no plaintext cookie / CSRF column"
    end

    test "indexes: pending-reset index on uia_sessions, expiry indexes, per-user session index" do
      sql = code_sql(@up)

      assert sql =~
               ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?uia_sessions_user_op_pending_idx\s+ON\s+uia_sessions\s*\(\s*user_id\s*,\s*op\s*\)\s+WHERE\s+consumed\s*=\s*FALSE/i

      assert sql =~ ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_account_login_requests_expires_idx\s+ON\s+oauth_account_login_requests\s*\(\s*expires_at\s*\)/i
      assert sql =~ ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_account_sessions_expires_idx\s+ON\s+oauth_account_sessions\s*\(\s*expires_at\s*\)/i
      assert sql =~ ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_account_sessions_user_idx\s+ON\s+oauth_account_sessions\s*\(\s*user_id/i
    end

    test "grants: login requests SELECT/INSERT/DELETE (no UPDATE, no ALL); sessions SELECT/INSERT/UPDATE/DELETE" do
      sql = code_sql(@up)
      g = grant_of(sql, @lr)
      for p <- ~w(SELECT INSERT DELETE), do: assert(g =~ p)
      refute g =~ ~r/UPDATE|\bALL\b/i, "login requests are never updated (A24)"

      s = grant_of(sql, @sess)
      for p <- ~w(SELECT INSERT UPDATE DELETE), do: assert(s =~ p)
      refute s =~ ~r/\bALL\b/i
    end

    test "RLS enabled AND forced on both tables; one open policy per granted command, nothing else" do
      sql = code_sql(@up)

      for t <- [@lr, @sess] do
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i
      end

      assert policies(sql, @lr, "SELECT") == ["#{@lr}_select"]
      assert policies(sql, @lr, "INSERT") == ["#{@lr}_insert"]
      assert policies(sql, @lr, "DELETE") == ["#{@lr}_delete"]
      assert policies(sql, @lr, "UPDATE") == [], "no UPDATE policy on login requests"
      assert policies(sql, @lr, "ALL") == []

      for cmd <- ~w(SELECT INSERT UPDATE DELETE),
          do: assert(policies(sql, @sess, cmd) == ["#{@sess}_#{String.downcase(cmd)}"], "#{@sess} #{cmd} policy")

      assert policies(sql, @sess, "ALL") == []
    end

    test "no server_config change and no transaction management / CONCURRENTLY" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/server_config|config_update_mutable/i, "#{f}: no server_config key (ADR-022)"
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
        refute sql =~ ~r/CONCURRENTLY/i
      end
    end

    test "down drops exactly what up created (both tables, the uia index) and never touches uia_sessions rows" do
      down = code_sql(@down)
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_account_sessions/i
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_account_login_requests/i
      assert down =~ ~r/DROP\s+INDEX\s+(IF\s+EXISTS\s+)?uia_sessions_user_op_pending_idx/i
      refute down =~ ~r/(DELETE\s+FROM|UPDATE|DROP\s+TABLE\s+(IF\s+EXISTS\s+)?)\s*uia_sessions\b/i
      refute down =~ ~r/GRANT|matrix_sessions|oauth_clients/i
    end

    test "header comment references A6/A8/A15/A24 and the rolling-deploy safety" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      for a <- ~w(A6 A8 A15 A24), do: assert(header =~ ~r/\b#{a}\b/, "header must reference #{a}")
      assert header =~ ~r/rolling/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # integration: migrated schema + runtime-role behaviour
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11 — migrated schema (integration, runtime role nebu_app)" do
    @describetag :integration

    setup do
      uid = "@atdd-m43-#{T.rand()}:test.local"

      on_exit(fn ->
        # guarded: in the red phase the tables do not exist yet
        if T.sql!("SELECT to_regclass('oauth_account_sessions') IS NOT NULL").rows == [[true]] do
          T.privileged_sql!("DELETE FROM oauth_account_sessions WHERE user_id = $1", [uid])
          T.privileged_sql!("DELETE FROM oauth_account_login_requests WHERE return_device_id = $1", [uid])
        end
      end)

      {:ok, uid: uid}
    end

    defp hex, do: T.rand(32)

    defp insert_lr(tag, opts) do
      T.sql!(
        "INSERT INTO oauth_account_login_requests (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, " <>
          "return_device_id, replaces_session_hash, created_at, expires_at) VALUES " <>
          "($1, 'enc', 'nonce', $2, $3, $4, NULL, now(), #{Keyword.get(opts, :expires_sql, "now() + interval '600 seconds'")})",
        [Keyword.get(opts, :state_hash, hex()), Keyword.get(opts, :binding_hash, hex()), Keyword.get(opts, :action, "org.matrix.devices_list"), tag]
      )
    end

    defp insert_sess(uid, opts) do
      T.sql!(
        "INSERT INTO oauth_account_sessions (session_hash, user_id, auth_time, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at) " <>
          "VALUES ($1, $2, $3, $4, now(), now(), #{Keyword.get(opts, :idle_sql, "now() + interval '900 seconds'")}, " <>
          "#{Keyword.get(opts, :expires_sql, "now() + interval '3600 seconds'")})",
        [Keyword.get(opts, :session_hash, hex()), uid, System.system_time(:second), Keyword.get(opts, :csrf_hash, hex())]
      )
    end

    test "columns and types as pinned" do
      for {table, cols} <- [{@lr, @lr_cols}, {@sess, @sess_cols}] do
        %{rows: rows} = T.sql!("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = $1", [table])
        got = Map.new(rows, fn [n, t] -> {n, t} end)
        assert got != %{}, "table #{table} missing"
        for c <- cols, do: assert(Map.has_key?(got, c), "#{table}.#{c} missing")
      end

      %{rows: [[t]]} = T.sql!("SELECT data_type FROM information_schema.columns WHERE table_name = $1 AND column_name = 'auth_time'", [@sess])
      assert t == "bigint"
    end

    test "login requests: insert, atomic consume (DELETE ... RETURNING) and delete work as nebu_app", %{uid: uid} do
      h = hex()
      assert %{num_rows: 1} = insert_lr(uid, state_hash: h)

      assert %{rows: [[true]]} =
               T.sql!("DELETE FROM oauth_account_login_requests WHERE state_hash = $1 RETURNING (expires_at > now())", [h])

      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_account_login_requests WHERE state_hash = $1 RETURNING 1", [h]), "single consume"
    end

    test "login requests: UPDATE is refused for the runtime role (no grant)", %{uid: uid} do
      h = hex()
      insert_lr(uid, state_hash: h)

      assert_raise Postgrex.Error, ~r/permission denied/i, fn ->
        T.sql!("UPDATE oauth_account_login_requests SET return_action = NULL WHERE state_hash = $1", [h])
      end
    end

    test "login requests: CHECKs refuse > 10 minutes, an unknown return_action, account_deactivate and non-hex hashes", %{uid: uid} do
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_lr(uid, expires_sql: "now() + interval '11 minutes'") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_lr(uid, action: "org.matrix.account_deactivate") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_lr(uid, action: "junk") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_lr(uid, state_hash: "not-hex") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_lr(uid, binding_hash: String.upcase(hex())) end
    end

    test "login requests: each of the five actions and NULL (default page) are accepted", %{uid: uid} do
      for a <- @actions ++ [nil], do: assert(%{num_rows: 1} = insert_lr(uid, action: a))
    end

    test "sessions: insert, sliding UPDATE, delete work as nebu_app", %{uid: uid} do
      h = hex()
      assert %{num_rows: 1} = insert_sess(uid, session_hash: h)

      assert %{num_rows: 1} =
               T.sql!(
                 "UPDATE oauth_account_sessions SET last_seen_at = now(), idle_expires_at = LEAST(now() + interval '900 seconds', expires_at) " <>
                   "WHERE session_hash = $1 AND idle_expires_at > now() AND expires_at > now() RETURNING user_id",
                 [h]
               )

      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_account_sessions WHERE session_hash = $1", [h])
    end

    test "sessions: CHECKs refuse > 1 hour, idle beyond absolute and non-hex hashes", %{uid: uid} do
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_sess(uid, expires_sql: "now() + interval '61 minutes'", idle_sql: "now()") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_sess(uid, idle_sql: "now() + interval '50 minutes'", expires_sql: "now() + interval '40 minutes'") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_sess(uid, session_hash: "short") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_sess(uid, csrf_hash: "zz" <> String.slice(hex(), 2, 62)) end
    end

    test "RLS enabled + forced; policies per granted command" do
      for {t, cmds} <- [{@lr, ~w(DELETE INSERT SELECT)}, {@sess, ~w(DELETE INSERT SELECT UPDATE)}] do
        assert %{rows: [[true, true]]} = T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1", [t])
        %{rows: rows} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = $1", [t])
        assert rows |> List.flatten() |> Enum.sort() == cmds, "#{t} policies"
      end
    end

    test "indexes exist (uia pending index is partial on consumed = false)" do
      %{rows: rows} = T.sql!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'uia_sessions'")
      assert Enum.any?(rows, fn [n, d] -> n == "uia_sessions_user_op_pending_idx" and d =~ ~r/WHERE/i and d =~ ~r/consumed/ end)

      %{rows: names} = T.sql!("SELECT indexname FROM pg_indexes WHERE tablename = ANY($1)", [[@lr, @sess]])
      names = List.flatten(names)
      for i <- ~w(oauth_account_login_requests_expires_idx oauth_account_sessions_expires_idx oauth_account_sessions_user_idx), do: assert(i in names, "#{i} missing")
    end

    test "down/up round trip (privileged role, rolled back): down removes both tables and the uia index; up restores them" do
      down = read!(@down)
      up = read!(@up)

      probe = fn tx ->
        %{rows: [[lr]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_account_login_requests')::text", [])
        %{rows: [[s]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_account_sessions')::text", [])
        %{rows: [[idx]]} = Postgrex.query!(tx, "SELECT to_regclass('uia_sessions_user_op_pending_idx')::text", [])
        %{rows: [[uia]]} = Postgrex.query!(tx, "SELECT to_regclass('uia_sessions')::text", [])
        {lr, s, idx, uia}
      end

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, down, [], query_type: :text)
            after_down = probe.(tx)
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up = probe.(tx)
            Postgrex.rollback(tx, {:round_trip, after_down, after_up})
          end)
        end)

      assert {:error, {:round_trip, after_down, after_up}} = result
      assert after_down == {nil, nil, nil, "uia_sessions"}, "after down: no tables, no index; uia_sessions kept"
      assert after_up == {@lr, @sess, "uia_sessions_user_op_pending_idx", "uia_sessions"}
    end
  end
end
