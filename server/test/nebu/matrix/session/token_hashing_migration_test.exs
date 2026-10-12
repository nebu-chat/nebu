defmodule Nebu.Matrix.Session.TokenHashingMigrationTest do
  @moduledoc """
  ATDD tests for story `token-hashing-matrix-sessions` (AC4 — migration that DELETES ALL
  sessions (TRUNCATE, no backfill); AC1 shape; AC6 grants/atomicity).
  Story: docs/stories/matrix-session-refresh-fixes/token-hashing-matrix-sessions.md

  The tests build a THROWAWAY database per test (own name `nebu_hashmig_<unix>_<n>_<rand>`, dropped
  afterwards; the migration role has CREATEDB), apply every real migration up to and
  including `000037` (= the predecessor schema: plaintext `access_token`/`refresh_token`
  columns), seed plaintext sessions, then apply the token-hashing migration and assert:

    * the table is EMPTY afterwards and physically rewritten (new relfilenode): every
      session is invalidated, everybody logs in again once (no backfill, no plaintext residue)
    * plaintext columns gone, PK / UNIQUE NOT NULL / indexes now on the hash columns
    * grants for `nebu_app` intact, no table drop/re-create, no explicit COMMIT
    * `.down.sql` empties the table and restores the old plaintext shape; up -> down -> up

  The migration is located WITHOUT hard-coding its number: it is the up-migration with a
  version > 37 whose SQL mentions `access_token_hash`. While it does not exist the tests
  fail with an explicit "no migration found" assertion (not a compile error).

  Needs `NEBU_DB_URL_MIGRATE` (or `NEBU_DB_URL`) for a role with CREATEDB (like
  `Nebu.Release.migrate/0`). Tagged `:integration`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000
  # Needs a DB role with CREATEDB (NEBU_DB_URL_MIGRATE, like Nebu.Release.migrate/0): skipped,
  # not failed, when no database URL is configured at all.
  @moduletag skip: (if System.get_env("NEBU_DB_URL_MIGRATE") || System.get_env("NEBU_DB_URL"),
                      do: false,
                      else: "NEBU_DB_URL_MIGRATE / NEBU_DB_URL not set - cannot create throwaway databases"
                    )

  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  @migrations_dir Path.expand("../../../../priv/migrations", __DIR__)
  @predecessor_version 37
  @server_name "test.local"

  # ── migration discovery ────────────────────────────────────────────────────

  defp up_files do
    @migrations_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".up.sql"))
    |> Enum.map(fn name -> {name |> String.split("_", parts: 2) |> hd() |> String.to_integer(), name} end)
    |> Enum.sort()
  end

  # {version, up_name, down_name} of the token-hashing migration, or flunk.
  defp hash_migration! do
    found =
      Enum.find(up_files(), fn {v, name} ->
        v > @predecessor_version and
          File.read!(Path.join(@migrations_dir, name)) =~ "access_token_hash"
      end)

    case found do
      {v, up} ->
        down = String.replace_suffix(up, ".up.sql", ".down.sql")
        {v, up, down}

      nil ->
        flunk(
          "AC4: no migration with version > 0000#{@predecessor_version} mentioning " <>
            "`access_token_hash` exists in server/priv/migrations yet"
        )
    end
  end

  defp read_migration(name), do: File.read!(Path.join(@migrations_dir, name))

  # ── throwaway database ─────────────────────────────────────────────────────

  defp conn_opts(database) do
    uri = URI.parse(db_url())
    [user, pass] = (String.split(uri.userinfo || "", ":", parts: 2) ++ [nil]) |> Enum.take(2)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: user && URI.decode_www_form(user),
      password: pass && URI.decode_www_form(pass),
      database: database || String.trim_leading(uri.path || "/nebu", "/")
    ] ++ Nebu.Release.postgres_ssl_opts(uri.host)
  end

  defp db_url, do: System.get_env("NEBU_DB_URL_MIGRATE") || System.get_env("NEBU_DB_URL")

  defp run_sql!(conn, sql) do
    case Postgrex.transaction(conn, fn tx -> Postgrex.query!(tx, sql, [], query_type: :text) end) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("SQL failed: #{inspect(reason)}\n#{String.slice(sql, 0, 400)}")
    end
  end

  defp q!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params).rows

  setup_all do
    # drop stale throwaway databases left behind by crashed earlier runs
    {:ok, a} = Postgrex.start_link(conn_opts(nil))

    case Postgrex.query(a, "SELECT datname FROM pg_database WHERE datname LIKE 'nebu\\_hashmig\\_%'", []) do
      {:ok, %{rows: rows}} ->
        # Name = nebu_hashmig_<unix-seconds>_<n>_<rand>. Only databases older than 30 minutes
        # are stale; younger ones may belong to a parallel run and must not be touched.
        cutoff = System.os_time(:second) - 30 * 60

        for [name] <- rows,
            ["nebu", "hashmig", ts | _] <- [String.split(name, "_")],
            {ts, ""} <- [Integer.parse(ts)],
            ts < cutoff,
            do: Postgrex.query(a, "DROP DATABASE IF EXISTS #{name} WITH (FORCE)", [])

      _ ->
        :ok
    end

    GenServer.stop(a)
    :ok
  end

  setup do
    do_setup()
  end

  defp do_setup do
    {:ok, admin} = Postgrex.start_link(conn_opts(nil))
    dbname = "nebu_hashmig_#{System.os_time(:second)}_#{System.unique_integer([:positive])}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    Postgrex.query!(admin, "CREATE DATABASE #{dbname}", [])

    {:ok, conn} = Postgrex.start_link(conn_opts(dbname))

    on_exit(fn ->
      # conn is linked to the test process: if setup/test already crashed it may be shutting down
      try do
        if Process.alive?(conn), do: GenServer.stop(conn)
      catch
        :exit, _ -> :ok
      end

      {:ok, a2} = Postgrex.start_link(conn_opts(nil))
      Postgrex.query(a2, "DROP DATABASE IF EXISTS #{dbname} WITH (FORCE)", [])
      GenServer.stop(a2)
    end)

    GenServer.stop(admin)

    # Predecessor schema = every real migration up to and including 000037.
    for {v, name} <- up_files(), v <= @predecessor_version do
      run_sql!(conn, read_migration(name))
    end

    assert ~w(access_token refresh_token) -- columns(conn) == [],
           "precondition: the predecessor schema must have the plaintext columns"

    {:ok, conn: conn}
  end

  defp columns(conn) do
    conn
    |> q!(
      "SELECT column_name FROM information_schema.columns WHERE table_name = 'matrix_sessions' AND table_schema = 'public'"
    )
    |> List.flatten()
  end

  defp sha256_hex(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
  defp tok, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  # Legacy (plaintext) seed: returns a map of named sessions with their plaintext tokens.
  defp seed_legacy!(conn, uid) do
    s = fn -> %{at: tok(), rt: tok()} end

    sessions = %{
      active: s.(),
      pending_old: s.(),
      pending_new: s.(),
      consumed_old: s.(),
      consumed_new: s.(),
      expired: s.()
    }

    ins = fn key, dev, opts ->
      %{at: at, rt: rt} = sessions[key]

      Postgrex.query!(
        conn,
        """
        INSERT INTO matrix_sessions
          (access_token, refresh_token, oidc_refresh_token, user_id, device_id,
           expires_at, revoked_at, grace_until, auth_time, created_at)
        VALUES ($1, $2, $3, $4, $5,
                NOW() + ($6 * INTERVAL '1 second'),
                CASE WHEN $7::text = 'none' THEN NULL ELSE NOW() - INTERVAL '5 seconds' END,
                CASE WHEN $7::text = 'consumed' THEN NOW() - INTERVAL '2 seconds' ELSE NULL END,
                1700000000, NOW() - INTERVAL '10 seconds')
        """,
        [at, rt, Keyword.get(opts, :oidc), uid, dev, Keyword.get(opts, :ttl, 3600), Keyword.get(opts, :state, "none")]
      )
    end

    ins.(:active, "MIGA", oidc: "enc-A")
    ins.(:pending_old, "MIGB", state: "pending", oidc: "enc-B")
    ins.(:pending_new, "MIGB", oidc: "enc-B")
    ins.(:consumed_old, "MIGC", state: "consumed", oidc: "enc-C")
    ins.(:consumed_new, "MIGC", oidc: "enc-C")
    ins.(:expired, "MIGD", ttl: -60, oidc: "enc-D")
    sessions
  end

  defp insert_hashed!(conn) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, user_id, device_id, expires_at)
      VALUES ($1, $2, '@ins:test.local', 'INS', NOW() + INTERVAL '1 hour')
      """,
      [sha256_hex(tok()), sha256_hex(tok())]
    )
  end

  defp apply_up!(conn) do
    {_v, up, _down} = hash_migration!()
    run_sql!(conn, read_migration(up))
  end

  defp apply_down!(conn) do
    {_v, _up, down} = hash_migration!()
    run_sql!(conn, read_migration(down))
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — migration files: existence, header docs, structure
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: migration files" do
    test "an up AND a down migration for token hashing exist after 000037" do
      {v, up, down} = hash_migration!()
      assert v > @predecessor_version
      assert File.exists?(Path.join(@migrations_dir, down)), "AC4: #{up} needs a matching #{down}"
    end

    test "up migration drops the plaintext columns, never drops the table, has no explicit COMMIT" do
      {_v, up, _down} = hash_migration!()
      sql = read_migration(up)

      # Column drops are pinned on the SQL text; there is no backfill (the table is truncated).
      assert sql =~ ~r/DROP\s+COLUMN\s+(IF\s+EXISTS\s+)?access_token\b/i
      assert sql =~ ~r/DROP\s+COLUMN\s+(IF\s+EXISTS\s+)?refresh_token\b/i

      refute sql =~ ~r/DROP\s+TABLE\s+(IF\s+EXISTS\s+)?matrix_sessions/i,
             "AC4/AC6: the table (and with it its GRANTs) must be altered in place, not re-created"

      refute sql =~ ~r/^\s*COMMIT\s*;/im,
             "AC4: the migration runs inside the runner's single transaction - no explicit COMMIT"
    end

    test "down migration header documents that plaintext cannot be restored and sessions are deleted" do
      {_v, _up, down} = hash_migration!()
      sql = read_migration(down)
      comments = sql |> String.split("\n") |> Enum.filter(&String.match?(&1, ~r/^\s*--/)) |> Enum.join("\n")

      assert comments =~ ~r/plaintext/i, "AC4: down migration must document that plaintext cannot be restored"
      assert comments =~ ~r/re-?login|log\s*in again|forc/i, "AC4: down migration must document the forced re-login"
      assert sql =~ ~r/DELETE\s+FROM\s+matrix_sessions/i, "AC4: down must delete all matrix_sessions rows"
    end

    test "up migration truncates matrix_sessions (no backfill) and documents the stop-the-world release" do
      {_v, up, _down} = hash_migration!()
      sql = read_migration(up)
      comments = sql |> String.split("\n") |> Enum.filter(&String.match?(&1, ~r/^\s*--/)) |> Enum.join("\n")

      assert sql =~ ~r/^\s*TRUNCATE\s+(TABLE\s+)?matrix_sessions/im, "AC4: up must TRUNCATE matrix_sessions"
      refute sql =~ ~r/^\s*UPDATE\s+matrix_sessions/im, "AC4: no backfill UPDATE (old row versions would keep plaintext)"
      assert comments =~ ~r/stop-the-world/i, "F-2: header must state the release is stop-the-world"
      assert comments =~ ~r/re-?login|log\s*in again/i, "AC4: header must document the forced re-login"
    end

    test "the migration runner lists the new migration (release_test version list consumer)" do
      {v, _up, _down} = hash_migration!()
      versions = Nebu.Release.list_up_migrations(@migrations_dir) |> Enum.map(&elem(&1, 0))
      assert v in versions
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — up: ALL sessions are deleted (TRUNCATE), no backfill; new shape
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: up migration on a DB with plaintext sessions" do
    test "up deletes ALL sessions: table empty, physically rewritten, plaintext columns gone", %{conn: conn} do
      sessions = seed_legacy!(conn, "@mig-shape:#{@server_name}")
      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[map_size(sessions)]]
      before_node = q!(conn, "SELECT pg_relation_filenode('matrix_sessions')")

      apply_up!(conn)

      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[0]],
             "AC4: the migration must delete every session (forced re-login, no backfill)"

      refute q!(conn, "SELECT pg_relation_filenode('matrix_sessions')") == before_node,
             "AC4/F-1: TRUNCATE must give the table a NEW relfilenode so the old plaintext heap pages are discarded"

      cols = columns(conn)
      assert "access_token_hash" in cols
      assert "refresh_token_hash" in cols
      refute "access_token" in cols, "AC1/AC4: plaintext access_token column must be dropped"
      refute "refresh_token" in cols, "AC1/AC4: plaintext refresh_token column must be dropped"

      for keep <- ~w(oidc_refresh_token user_id device_id expires_at revoked_at grace_until created_at auth_time) do
        assert keep in cols, "AC4: column #{keep} must survive"
      end
    end

    test "no pre-migration token or its hash resolves to a session after up", %{conn: conn} do
      sessions = seed_legacy!(conn, "@mig-gone:#{@server_name}")
      apply_up!(conn)

      for {key, %{at: at, rt: rt}} <- sessions do
        assert q!(conn, "SELECT 1 FROM matrix_sessions WHERE access_token_hash = $1", [sha256_hex(at)]) == [],
               "AC4: session #{key} must not survive the migration"

        assert q!(conn, "SELECT 1 FROM matrix_sessions WHERE refresh_token_hash = $1", [sha256_hex(rt)]) == []
      end
    end

    test "Store.hash_token/1 equals SQL encode(sha256(convert_to(token,'UTF8')),'hex')", %{conn: conn} do
      t = tok()
      assert [[sql_hash]] = q!(conn, "SELECT encode(sha256(convert_to($1::text, 'UTF8')), 'hex')", [t])
      assert Store.hash_token(t) == sql_hash
      assert Store.hash_token(t) == sha256_hex(t)
    end


    test "access_token_hash is the PRIMARY KEY; refresh_token_hash is UNIQUE NOT NULL and indexed", %{conn: conn} do
      seed_legacy!(conn, "@mig-constraints:#{@server_name}")
      apply_up!(conn)

      pk_cols =
        q!(
          conn,
          """
          SELECT a.attname FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
           WHERE i.indrelid = 'matrix_sessions'::regclass AND i.indisprimary
          """
        )
        |> List.flatten()

      assert pk_cols == ["access_token_hash"], "AC1: PRIMARY KEY must be access_token_hash, got #{inspect(pk_cols)}"

      assert [[true]] =
               q!(
                 conn,
                 """
                 SELECT EXISTS (
                   SELECT 1 FROM pg_index i
                     JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                    WHERE i.indrelid = 'matrix_sessions'::regclass AND i.indisunique AND NOT i.indisprimary
                      AND i.indnatts = 1 AND a.attname = 'refresh_token_hash')
                 """
               ),
             "AC1: refresh_token_hash must carry a UNIQUE constraint/index"

      nullable =
        q!(
          conn,
          """
          SELECT column_name, is_nullable FROM information_schema.columns
           WHERE table_name = 'matrix_sessions' AND table_schema = 'public'
             AND column_name IN ('access_token_hash', 'refresh_token_hash')
          """
        )
        |> Map.new(fn [c, n] -> {c, n} end)

      assert nullable == %{"access_token_hash" => "NO", "refresh_token_hash" => "NO"}

      indexed_cols =
        q!(
          conn,
          """
          SELECT DISTINCT a.attname FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
           WHERE i.indrelid = 'matrix_sessions'::regclass
          """
        )
        |> List.flatten()

      for c <- ~w(access_token_hash refresh_token_hash user_id expires_at) do
        assert c in indexed_cols, "AC1/AC4: column #{c} must stay indexed (same indexes as before), got #{inspect(indexed_cols)}"
      end

      refute Enum.any?(indexed_cols, &(&1 in ~w(access_token refresh_token)))
    end

    test "duplicate hash values are rejected after migration (PK / UNIQUE enforced)", %{conn: conn} do
      apply_up!(conn)
      at_h = sha256_hex(tok())
      rt_h = sha256_hex(tok())

      insert = fn ah, rh ->
        Postgrex.query(
          conn,
          """
          INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, user_id, device_id, expires_at)
          VALUES ($1, $2, '@dup:test.local', 'DUP', NOW() + INTERVAL '1 hour')
          """,
          [ah, rh]
        )
      end

      assert {:ok, _} = insert.(at_h, rt_h)

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               insert.(at_h, sha256_hex(tok()))

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               insert.(sha256_hex(tok()), rt_h)

      assert {:ok, _} = insert.(sha256_hex(tok()), sha256_hex(tok()))
    end

    test "nebu_app keeps DML privileges on matrix_sessions (RLS/grants intact)", %{conn: conn} do
      seed_legacy!(conn, "@mig-grants:#{@server_name}")
      apply_up!(conn)

      assert [[true]] =
               q!(
                 conn,
                 "SELECT has_table_privilege('nebu_app', 'matrix_sessions', 'SELECT, INSERT, UPDATE, DELETE')"
               )
    end

    test "up migration on an EMPTY table works", %{conn: conn} do
      apply_up!(conn)
      assert "access_token_hash" in columns(conn)
      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[0]]
    end

    test "a migration that fails midway rolls back completely (single transaction, no half-migrated table)",
         %{conn: conn} do
      sessions = seed_legacy!(conn, "@mig-atomic:#{@server_name}")

      # Booby-trap: TRUNCATE raises. The migration truncates AFTER adding the hash columns,
      # so it blows up midway and must roll back the structural change as well.
      run_sql!(conn, """
      CREATE FUNCTION hashmig_boom() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'boom'; END $$;
      CREATE TRIGGER hashmig_boom BEFORE TRUNCATE ON matrix_sessions FOR EACH STATEMENT EXECUTE FUNCTION hashmig_boom();
      """)

      {_v, up, _down} = hash_migration!()

      assert {:error, _} =
               Postgrex.transaction(conn, fn tx ->
                 case Postgrex.query(tx, read_migration(up), [], query_type: :text) do
                   {:ok, res} -> res
                   {:error, err} -> Postgrex.rollback(tx, err)
                 end
               end),
             "AC4: with a failing TRUNCATE the migration must fail"

      cols = columns(conn)
      assert "access_token" in cols and "refresh_token" in cols, "AC4: rolled back — plaintext columns intact"
      refute "access_token_hash" in cols, "AC4: rolled back — no half-added hash column"
      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[map_size(sessions)]]
    end
  end


  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — down + up -> down -> up
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4: down migration and up -> down -> up" do
    test "down deletes all sessions (forces re-login) and restores the plaintext shape", %{conn: conn} do
      seed_legacy!(conn, "@mig-down:#{@server_name}")
      apply_up!(conn)
      insert_hashed!(conn)
      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[1]]

      apply_down!(conn)

      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[0]], "AC4: down must empty the table"

      cols = columns(conn)
      assert "access_token" in cols and "refresh_token" in cols
      refute "access_token_hash" in cols
      refute "refresh_token_hash" in cols

      pk =
        q!(
          conn,
          """
          SELECT a.attname FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
           WHERE i.indrelid = 'matrix_sessions'::regclass AND i.indisprimary
          """
        )
        |> List.flatten()

      assert pk == ["access_token"], "AC4: down must restore PRIMARY KEY (access_token)"

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               (fn ->
                  t = tok()
                  ins = "INSERT INTO matrix_sessions (access_token, refresh_token, user_id, device_id, expires_at) VALUES ($1, $2, 'u', 'd', NOW() + INTERVAL '1 hour')"
                  {:ok, _} = Postgrex.query(conn, ins, [tok(), t])
                  Postgrex.query(conn, ins, [tok(), t])
                end).(),
             "AC4: down must restore UNIQUE (refresh_token)"
    end

    test "up -> down -> up round trip ends in the hashed shape with an empty table", %{conn: conn} do
      seed_legacy!(conn, "@mig-roundtrip:#{@server_name}")
      apply_up!(conn)
      apply_down!(conn)

      # After down the table is empty and plaintext again: seed, then up again.
      sessions = seed_legacy!(conn, "@mig-roundtrip2:#{@server_name}")
      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[map_size(sessions)]]
      apply_up!(conn)

      cols = columns(conn)
      assert "access_token_hash" in cols
      refute "access_token" in cols
      assert q!(conn, "SELECT count(*) FROM matrix_sessions") == [[0]], "AC4: second up deletes all sessions again"
      insert_hashed!(conn)
    end
  end
end
