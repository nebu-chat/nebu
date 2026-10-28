defmodule Nebu.Migration.Migration000045OauthConsentAndRefreshLeasesTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3), FR19 / AC11.3: migration
  `000045_oauth_consent_and_refresh_leases`.

  Pinned names (the dev MUST use exactly these; changing one means changing this test):

    * `oauth_consent_requests` (FR6): `binding_hash` TEXT PRIMARY KEY (64 lowercase hex = sha256 of the
      256-bit consent cookie), `client_id` TEXT NOT NULL REFERENCES `oauth_clients` ON DELETE CASCADE,
      `redirect_uri`, `code_challenge`, `device_id`, `user_id`, `scope`, `scope_prefix`, `response_mode`
      (TEXT NOT NULL), `client_state`, `client_nonce` (TEXT NULL), `openid_requested` BOOLEAN NOT NULL,
      `idp_rt_enc` TEXT NULL (SecretBox), `auth_time` TIMESTAMPTZ NULL (the RAW claim or NULL, FR4),
      `login_fresh` BOOLEAN NOT NULL, `created_at` TIMESTAMPTZ NOT NULL DEFAULT now(), `expires_at`
      TIMESTAMPTZ NOT NULL. CHECKs: binding_hash 64 hex, scope_prefix IN (the two prefixes),
      response_mode IN ('query','fragment'), `expires_at <= created_at + interval '5 minutes'`. Index
      `oauth_consent_requests_expires_idx (expires_at)`. Grants to `nebu_app`: `SELECT, INSERT, DELETE`
      (NO UPDATE). RLS ENABLE + FORCE, policies `oauth_consent_requests_{select,insert,delete}` only.
    * `oauth_idp_refresh_leases` (FR15): `user_id` TEXT, `device_id` TEXT, `holder` TEXT NOT NULL,
      `acquired_at` TIMESTAMPTZ NOT NULL, `lease_until` TIMESTAMPTZ NOT NULL; PRIMARY KEY `(user_id,
      device_id)`; FK `(user_id, device_id)` REFERENCES `devices` ON DELETE CASCADE; CHECK
      `lease_until <= acquired_at + interval '120 seconds'`. Grants `SELECT, INSERT, UPDATE, DELETE`;
      RLS ENABLE + FORCE with the four open policies `oauth_idp_refresh_leases_{select,insert,update,delete}`.
    * `oauth_account_sessions.auth_time` loses NOT NULL (FR14). Down: drop both new tables, DELETE the
      sessions with a NULL `auth_time`, then `SET NOT NULL` again.
    * No `server_config` / `config_update_mutable` change; no transaction management; 000040-000044 are
      not edited.

  Mirrors `000043_oauth_account_management_test.exs`: static SQL analysis plus `:integration`
  behaviour as the RUNTIME role (`nebu_app`) and a down/up round trip on the privileged role inside a
  rolled-back transaction. After adding the migration reset the throwaway DB (`docker rm -f nebu-oauth-pg`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000045_oauth_consent_and_refresh_leases.up.sql"
  @down "000045_oauth_consent_and_refresh_leases.down.sql"

  @consent "oauth_consent_requests"
  @lease "oauth_idp_refresh_leases"
  @consent_cols ~w(binding_hash client_id redirect_uri code_challenge device_id user_id scope scope_prefix
                   response_mode client_state client_nonce openid_requested idp_rt_enc auth_time login_fresh
                   created_at expires_at)
  @lease_cols ~w(user_id device_id holder acquired_at lease_until)
  @earlier ~w(000040_oauth_clients_and_auth_metadata 000041_oauth_authz_requests_and_codes
              000042_oauth_sessions_and_signing_keys 000043_oauth_account_management 000044_oauth_abuse_hardening)

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

  describe "FR19 — migration files (static)" do
    test "up and down exist as the next free number after 000044; exactly one 000045" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000045_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000045 up migration"
      assert Path.wildcard(Path.join(@dir, "000045_*.down.sql")) == [Path.join(@dir, @down)], "exactly one 000045 down migration"
      for m <- @earlier, ext <- ~w(up down), do: assert(File.exists?(Path.join(@dir, "#{m}.#{ext}.sql")))
    end

    test "000040-000044 are untouched: none mentions the new tables" do
      for m <- @earlier, ext <- ~w(up down) do
        f = "#{m}.#{ext}.sql"
        refute read!(f) =~ ~r/oauth_consent_requests|oauth_idp_refresh_leases/, "#{f} must not be edited (new migration instead)"
      end
    end

    test "oauth_consent_requests: columns, PK, NOT NULLs, FK cascade, the four CHECKs, 5-minute TTL" do
      t = table_sql(code_sql(@up), @consent)
      for c <- @consent_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/binding_hash\s+TEXT\s+PRIMARY\s+KEY/i
      assert t =~ ~r/client_id\s+TEXT\s+NOT\s+NULL\s+REFERENCES\s+oauth_clients\s*\(\s*client_id\s*\)\s+ON\s+DELETE\s+CASCADE/i

      for c <- ~w(redirect_uri code_challenge device_id user_id scope scope_prefix response_mode),
          do: assert(t =~ ~r/\b#{c}\s+TEXT\s+NOT\s+NULL/i, "#{c} TEXT NOT NULL")

      assert t =~ ~r/openid_requested\s+BOOLEAN\s+NOT\s+NULL/i
      assert t =~ ~r/login_fresh\s+BOOLEAN\s+NOT\s+NULL/i
      assert t =~ ~r/auth_time\s+TIMESTAMPTZ\s*(,|\n)/i, "auth_time is NULL-able TIMESTAMPTZ (raw claim or NULL, FR4)"
      refute t =~ ~r/auth_time\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/idp_rt_enc\s+TEXT\s*(,|\n)/i
      refute t =~ ~r/idp_rt_enc\s+TEXT\s+NOT\s+NULL/i
      assert t =~ ~r/created_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/expires_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/expires_at\s*<=\s*created_at\s*\+\s*interval\s+'5 minutes'/i
      assert t =~ ~r/response_mode\s+IN\s*\(\s*'query'\s*,\s*'fragment'\s*\)/i
      assert t =~ "urn:matrix:client:" and t =~ "urn:matrix:org.matrix.msc2967.client:"
      assert t =~ ~r/binding_hash\s*~\s*'\^\[0-9a-f\]\{64\}\$'/i
      refute t =~ ~r/\b(cookie|csrf)\b\s+TEXT/i, "no plaintext cookie / CSRF column"
    end

    test "oauth_idp_refresh_leases: columns, composite PK, FK to devices ON DELETE CASCADE, 120 s CHECK" do
      t = table_sql(code_sql(@up), @lease)
      for c <- @lease_cols, do: assert(t =~ ~r/\b#{c}\b/, "column #{c} missing")
      assert t =~ ~r/PRIMARY\s+KEY\s*\(\s*user_id\s*,\s*device_id\s*\)/i
      assert t =~ ~r/FOREIGN\s+KEY\s*\(\s*user_id\s*,\s*device_id\s*\)\s+REFERENCES\s+devices\s*\(\s*user_id\s*,\s*device_id\s*\)\s+ON\s+DELETE\s+CASCADE/i
      assert t =~ ~r/holder\s+TEXT\s+NOT\s+NULL/i
      assert t =~ ~r/acquired_at\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/lease_until\s+TIMESTAMPTZ\s+NOT\s+NULL/i
      assert t =~ ~r/lease_until\s*<=\s*acquired_at\s*\+\s*interval\s+'120\s+seconds'/i
    end

    test "oauth_account_sessions.auth_time becomes nullable (FR14); no other change to that table" do
      sql = code_sql(@up)
      assert sql =~ ~r/ALTER\s+TABLE\s+oauth_account_sessions\s+ALTER\s+COLUMN\s+auth_time\s+DROP\s+NOT\s+NULL/i
      refute sql =~ ~r/ALTER\s+TABLE\s+oauth_account_sessions\s+(ADD|DROP\s+COLUMN|RENAME)/i
    end

    test "review cycle 1: consent source_key (+ cap indexes) and the oauth_codes holder columns; the down migration drops them" do
      up = code_sql(@up)
      t = table_sql(up, @consent)
      assert t =~ ~r/source_key\s+TEXT\s*(,|\n)/i
      assert t =~ ~r/source_key\s*~\s*'\^\[0-9a-f\]\{64\}\$'/i
      assert up =~ ~r/CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+oauth_consent_requests_user_idx\s+ON\s+oauth_consent_requests\s*\(\s*user_id\s*,\s*expires_at\s*\)/i
      assert up =~ ~r/CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+oauth_consent_requests_source_idx\s+ON\s+oauth_consent_requests\s*\(\s*source_key\s*,\s*expires_at\s*\)/i
      assert up =~ ~r/ALTER\s+TABLE\s+oauth_codes[^;]*device_holder_checked\s+BOOLEAN\s+NOT\s+NULL\s+DEFAULT\s+false/is
      assert up =~ ~r/ALTER\s+TABLE\s+oauth_codes[^;]*device_holder_client_id\s+TEXT/is

      down = code_sql(@down)
      assert down =~ ~r/DROP\s+COLUMN\s+IF\s+EXISTS\s+device_holder_checked/i
      assert down =~ ~r/DROP\s+COLUMN\s+IF\s+EXISTS\s+device_holder_client_id/i
    end

    test "index on oauth_consent_requests (expires_at) for the purge" do
      assert code_sql(@up) =~
               ~r/CREATE\s+INDEX\s+(IF\s+NOT\s+EXISTS\s+)?oauth_consent_requests_expires_idx\s+ON\s+oauth_consent_requests\s*\(\s*expires_at\s*\)/i
    end

    test "grants: consent SELECT/INSERT/DELETE (no UPDATE, no ALL; UPDATE explicitly revoked); leases all four" do
      sql = code_sql(@up)
      g = grant_of(sql, @consent)
      for p <- ~w(SELECT INSERT DELETE), do: assert(g =~ p)
      refute g =~ ~r/UPDATE|\bALL\b/i, "a consent row is never updated (single DELETE ... RETURNING consume)"
      assert sql =~ ~r/REVOKE\s+UPDATE\s+ON\s+(TABLE\s+)?#{@consent}\s+FROM\s+nebu_app/i, "dev ALTER DEFAULT PRIVILEGES must not leave UPDATE behind (000043 pattern)"

      l = grant_of(sql, @lease)
      for p <- ~w(SELECT INSERT UPDATE DELETE), do: assert(l =~ p)
      refute l =~ ~r/\bALL\b/i
    end

    test "RLS enabled AND forced on both tables; one open policy per granted command, nothing else" do
      sql = code_sql(@up)

      for t <- [@consent, @lease] do
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
        assert sql =~ ~r/ALTER\s+TABLE\s+#{t}\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i
      end

      for cmd <- ~w(SELECT INSERT DELETE), do: assert(policies(sql, @consent, cmd) == ["#{@consent}_#{String.downcase(cmd)}"])
      assert policies(sql, @consent, "UPDATE") == [], "no UPDATE policy on consent rows"
      assert policies(sql, @consent, "ALL") == []

      for cmd <- ~w(SELECT INSERT UPDATE DELETE), do: assert(policies(sql, @lease, cmd) == ["#{@lease}_#{String.downcase(cmd)}"])
      assert policies(sql, @lease, "ALL") == []
    end

    test "no server_config change, no transaction management, no CONCURRENTLY" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/server_config|config_update_mutable/i, "#{f}: no server_config key (ADR-022)"
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
        refute sql =~ ~r/CONCURRENTLY/i
      end
    end

    test "down: drops both tables, deletes the NULL-auth_time sessions BEFORE restoring NOT NULL" do
      down = code_sql(@down)
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_consent_requests/i
      assert down =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?oauth_idp_refresh_leases/i
      assert down =~ ~r/DELETE\s+FROM\s+oauth_account_sessions\s+WHERE\s+auth_time\s+IS\s+NULL/i

      {del, _} = :binary.match(down, "DELETE")
      {setnn, _} = :binary.match(String.upcase(down), "SET NOT NULL")
      assert del < setnn, "the NULL rows must be removed before NOT NULL is restored"
      assert down =~ ~r/ALTER\s+TABLE\s+oauth_account_sessions\s+ALTER\s+COLUMN\s+auth_time\s+SET\s+NOT\s+NULL/i
      refute down =~ ~r/matrix_sessions|oauth_clients|devices/i
    end

    test "header comment names FR6, FR15, FR19 and the rolling-deploy safety" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      for a <- ~w(FR6 FR15 FR19), do: assert(header =~ ~r/\b#{a}\b/, "header must reference #{a}")
      assert header =~ ~r/rolling/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # integration: migrated schema + runtime-role behaviour
  # ════════════════════════════════════════════════════════════════════════════

  describe "FR19 — migrated schema (integration, runtime role nebu_app)" do
    @describetag :integration

    setup do
      cid = T.oauth_client!(["https://app.example.com/cb"])
      uid = "@atdd-m45-#{T.rand()}:test.local"
      dev = "M45" <> String.upcase(T.rand(3))
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, last_seen_ts: System.system_time(:millisecond))

      on_exit(fn ->
        T.privileged_sql!("DELETE FROM oauth_account_sessions WHERE user_id = $1", [uid])
        T.privileged_sql!("DELETE FROM devices WHERE user_id = $1", [uid])
      end)

      {:ok, cid: cid, uid: uid, dev: dev}
    end

    defp hex, do: T.rand(32)

    defp insert_consent(cid, opts \\ []) do
      T.sql!(
        "INSERT INTO oauth_consent_requests (binding_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
          "response_mode, openid_requested, login_fresh, created_at, expires_at) VALUES " <>
          "($1, $2, 'https://app.example.com/cb', 'c', 'D', '@u:test.local', 's', $3, $4, false, true, now(), #{Keyword.get(opts, :expires_sql, "now() + interval '300 seconds'")})",
        [
          Keyword.get(opts, :hash, hex()),
          cid,
          Keyword.get(opts, :prefix, "urn:matrix:client:"),
          Keyword.get(opts, :mode, "query")
        ]
      )
    end

    defp insert_lease(uid, dev, opts \\ []) do
      T.sql!(
        "INSERT INTO oauth_idp_refresh_leases (user_id, device_id, holder, acquired_at, lease_until) VALUES " <>
          "($1, $2, $3, now(), #{Keyword.get(opts, :until_sql, "now() + interval '30 seconds'")})",
        [uid, dev, Keyword.get(opts, :holder, "holder-" <> T.rand())]
      )
    end

    test "columns and types as pinned" do
      for {table, cols} <- [{@consent, @consent_cols}, {@lease, @lease_cols}] do
        %{rows: rows} = T.sql!("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = $1", [table])
        got = Map.new(rows, fn [n, t] -> {n, t} end)
        assert got != %{}, "table #{table} missing"
        for c <- cols, do: assert(Map.has_key?(got, c), "#{table}.#{c} missing")
      end

      %{rows: [[t, nullable]]} =
        T.sql!("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name = $1 AND column_name = 'auth_time'", [@consent])

      assert {t, nullable} == {"timestamp with time zone", "YES"}
    end

    test "consent: insert, atomic consume (DELETE ... RETURNING with the live flag) as nebu_app", %{cid: cid} do
      h = hex()
      assert %{num_rows: 1} = insert_consent(cid, hash: h)

      assert %{rows: [[true]]} =
               T.sql!("DELETE FROM oauth_consent_requests WHERE binding_hash = $1 RETURNING (expires_at > now()) AS live", [h])

      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_consent_requests WHERE binding_hash = $1 RETURNING 1", [h]), "single consume"
    end

    test "consent: UPDATE is refused for the runtime role (no grant)", %{cid: cid} do
      h = hex()
      insert_consent(cid, hash: h)
      on_exit(fn -> T.sql!("DELETE FROM oauth_consent_requests WHERE binding_hash = $1", [h]) end)

      assert_raise Postgrex.Error, ~r/permission denied/i, fn ->
        T.sql!("UPDATE oauth_consent_requests SET login_fresh = false WHERE binding_hash = $1", [h])
      end
    end

    test "consent: CHECKs refuse > 5 minutes, a non-hex key, a bad prefix and a bad response_mode", %{cid: cid} do
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_consent(cid, expires_sql: "now() + interval '6 minutes'") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_consent(cid, hash: "not-hex") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_consent(cid, hash: String.upcase(hex())) end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_consent(cid, prefix: "urn:other:") end
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_consent(cid, mode: "form_post") end

      h = hex()
      assert %{num_rows: 1} = insert_consent(cid, hash: h, mode: "fragment", expires_sql: "now() + interval '5 minutes'")
      T.sql!("DELETE FROM oauth_consent_requests WHERE binding_hash = $1", [h])
    end

    test "consent: the client FK cascades (deleting the client removes its consent rows)", %{cid: cid} do
      h = hex()
      insert_consent(cid, hash: h)
      T.cleanup_clients([cid])
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM oauth_consent_requests WHERE binding_hash = $1", [h])
    end

    test "consent: an unknown client_id is refused by the FK" do
      assert_raise Postgrex.Error, ~r/foreign key|violates/i, fn -> insert_consent("no-such-client-" <> T.rand()) end
    end

    test "leases: insert / claim-style upsert / delete work; the PK admits one row per device", %{uid: uid, dev: dev} do
      assert %{num_rows: 1} = insert_lease(uid, dev, holder: "a")
      assert_raise Postgrex.Error, ~r/duplicate key|unique/i, fn -> insert_lease(uid, dev, holder: "b") end

      # the claim of FR15: only an EXPIRED lease can be taken over
      claim = fn holder ->
        T.sql!(
          "INSERT INTO oauth_idp_refresh_leases (user_id, device_id, holder, acquired_at, lease_until) " <>
            "VALUES ($1, $2, $3, now(), now() + interval '30 seconds') " <>
            "ON CONFLICT (user_id, device_id) DO UPDATE SET holder = EXCLUDED.holder, acquired_at = EXCLUDED.acquired_at, " <>
            "lease_until = EXCLUDED.lease_until WHERE oauth_idp_refresh_leases.lease_until <= now() RETURNING holder",
          [uid, dev, holder]
        )
      end

      assert %{num_rows: 0} = claim.("intruder"), "a live lease cannot be taken over"
      T.sql!("UPDATE oauth_idp_refresh_leases SET lease_until = now() - interval '1 second' WHERE user_id = $1 AND device_id = $2", [uid, dev])
      assert %{rows: [["intruder"]]} = claim.("intruder")

      assert %{num_rows: 0} = T.sql!("DELETE FROM oauth_idp_refresh_leases WHERE user_id = $1 AND device_id = $2 AND holder = $3", [uid, dev, "someone-else"])
      assert %{num_rows: 1} = T.sql!("DELETE FROM oauth_idp_refresh_leases WHERE user_id = $1 AND device_id = $2 AND holder = $3", [uid, dev, "intruder"])
    end

    test "leases: CHECK refuses a lease longer than 120 s", %{uid: uid, dev: dev} do
      assert_raise Postgrex.Error, ~r/check constraint/i, fn -> insert_lease(uid, dev, until_sql: "now() + interval '121 seconds'") end
      assert %{num_rows: 1} = insert_lease(uid, dev, until_sql: "now() + interval '120 seconds'")
    end

    test "leases: the device FK is enforced and CASCADEs on a device delete", %{uid: uid, dev: dev} do
      assert_raise Postgrex.Error, ~r/foreign key|violates/i, fn -> insert_lease(uid, "NOSUCHDEV") end

      insert_lease(uid, dev)
      T.privileged_sql!("DELETE FROM devices WHERE user_id = $1 AND device_id = $2", [uid, dev])
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM oauth_idp_refresh_leases WHERE user_id = $1", [uid])
    end

    test "oauth_account_sessions.auth_time accepts NULL (FR14), other CHECKs still hold", %{uid: uid} do
      h = hex()

      assert %{num_rows: 1} =
               T.sql!(
                 "INSERT INTO oauth_account_sessions (session_hash, user_id, auth_time, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at) " <>
                   "VALUES ($1, $2, NULL, $3, now(), now(), now() + interval '900 seconds', now() + interval '3600 seconds')",
                 [h, uid, hex()]
               )

      assert %{rows: [["YES"]]} =
               T.sql!("SELECT is_nullable FROM information_schema.columns WHERE table_name = 'oauth_account_sessions' AND column_name = 'auth_time'")

      assert_raise Postgrex.Error, ~r/check constraint/i, fn ->
        T.sql!(
          "INSERT INTO oauth_account_sessions (session_hash, user_id, auth_time, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at) " <>
            "VALUES ($1, $2, NULL, $3, now(), now(), now(), now() + interval '61 minutes')",
          [hex(), uid, hex()]
        )
      end
    end

    test "RLS enabled + forced; policies per granted command" do
      for {t, cmds} <- [{@consent, ~w(DELETE INSERT SELECT)}, {@lease, ~w(DELETE INSERT SELECT UPDATE)}] do
        assert %{rows: [[true, true]]} = T.sql!("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = $1", [t])
        %{rows: rows} = T.sql!("SELECT cmd FROM pg_policies WHERE tablename = $1", [t])
        assert rows |> List.flatten() |> Enum.sort() == cmds, "#{t} policies"
      end
    end

    test "index on consent.expires_at exists" do
      %{rows: rows} = T.sql!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = $1", [@consent])
      assert Enum.any?(rows, fn [n, d] -> n == "oauth_consent_requests_expires_idx" and d =~ ~r/\(expires_at\)/ end), inspect(rows)
    end

    test "down/up round trip (privileged role, rolled back): down removes both tables and restores NOT NULL (NULL sessions deleted); up restores", %{uid: uid} do
      down = read!(@down)
      up = read!(@up)

      probe = fn tx ->
        %{rows: [[c]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_consent_requests')::text", [])
        %{rows: [[l]]} = Postgrex.query!(tx, "SELECT to_regclass('oauth_idp_refresh_leases')::text", [])

        %{rows: [[nullable]]} =
          Postgrex.query!(tx, "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'oauth_account_sessions' AND column_name = 'auth_time'", [])

        {c, l, nullable}
      end

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            # a NULL-auth_time session must not make the down migration fail: it is deleted
            Postgrex.query!(
              tx,
              "INSERT INTO oauth_account_sessions (session_hash, user_id, auth_time, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at) " <>
                "VALUES ($1, $2, NULL, $3, now(), now(), now() + interval '900 seconds', now() + interval '3600 seconds')",
              [hex(), uid, hex()]
            )

            Postgrex.query!(tx, down, [], query_type: :text)
            after_down = probe.(tx)
            %{rows: [[left]]} = Postgrex.query!(tx, "SELECT count(*) FROM oauth_account_sessions WHERE user_id = $1", [uid])
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up = probe.(tx)
            Postgrex.rollback(tx, {:round_trip, after_down, left, after_up})
          end)
        end)

      assert {:error, {:round_trip, after_down, left, after_up}} = result
      assert after_down == {nil, nil, "NO"}, "after down: no new tables, auth_time NOT NULL again"
      assert left == 0, "the NULL-auth_time session was deleted by the down migration"
      assert after_up == {@consent, @lease, "YES"}
    end
  end
end
