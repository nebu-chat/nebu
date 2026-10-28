defmodule Nebu.Migration.Migration000054SyncRoomCursorsTest do
  @moduledoc """
  Acceptance tests for story `sync-stream-position` (epic oauth-broker, follow-up `fc`, story 2 of 2), Scenario "migration" / D3 / D6 / D8 / D19: migration
  `000054_sync_room_cursors` (the number is confirmed by the implementer at commit time: the tests find the file by its NAME, `*_sync_room_cursors.{up,down}.sql`, and
  require a number above 000053):

      CREATE TABLE sync_room_cursors (user_id, device_id, room_id, gen BIGINT, pos BIGINT, class TEXT, invite_marker BIGINT, prev_pos BIGINT, prev_class TEXT,
                                      prev_invite_marker BIGINT, PRIMARY KEY (user_id, device_id, room_id),
                                      FOREIGN KEY (user_id, device_id) REFERENCES sync_tokens ON DELETE CASCADE)
      ALTER TABLE sync_tokens ADD COLUMN stream_version SMALLINT NOT NULL DEFAULT 0, generation BIGINT NOT NULL DEFAULT 0, prev_since_token TEXT,
                                         prev_account_data_pos BIGINT, prev_cross_signing_pos BIGINT
      GRANT ... ON sync_room_cursors TO nebu_app
      -- down: the table, then the five columns

  Mirrors `000053_events_room_position_test.exs`: static SQL-file analysis (no DB, runs in the unit job) and an `:integration` part as the RUNTIME role plus a down / up round trip on
  the privileged role inside a rolled-back transaction, on the migrated (fresh) schema AND on a POPULATED schema (existing `sync_tokens` rows keep their data, start at
  `stream_version` 0 / `generation` 0, the cursor table starts empty, a down loses only the new objects). The exact types, nullability and defaults are pinned on the migrated database
  by introspection (not by regexes over the file). After adding the migration reset the throwaway database (`docker rm -f nebu-oauth-pg`, `.oauth-ci/cleanup.sh`) so that it runs.

  Pinned since fix cycle 2 (code review delta cycle 1, MINOR-1): the CHECK constraints on `class` and `prev_class` (the three partition classes, NULL allowed for
  `prev_class`). Not pinned (the story names no name and no bound): the constraint names, secondary indexes, the exact GRANT list beyond what the runtime needs (SELECT, INSERT, UPDATE,
  DELETE on the table, tested by using them as `nebu_app`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_sync_room_cursors.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_sync_room_cursors.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_sync_room_cursors.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()
  defp header(path), do: path |> read!() |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.map_join("\n", &String.replace(&1, ~r/\A--\s?/, ""))

  @new_token_columns ~w(stream_version generation prev_since_token prev_account_data_pos prev_cross_signing_pos)

  describe "migration 000054 files (static)" do
    test "up and down exist exactly once, with the same number, above 000053" do
      assert [up] = files("up"), "exactly one *_sync_room_cursors.up.sql"
      assert [down] = files("down"), "exactly one *_sync_room_cursors.down.sql"
      assert number(up) == number(down), "up and down carry the same number"
      assert number(up) >= 54, "the next free number after 000053 (events_room_position)"
      assert Path.wildcard(Path.join(@dir, "#{String.pad_leading(Integer.to_string(number(up)), 6, "0")}_*.up.sql")) == [up], "no second migration with that number"
    end

    test "the earlier migrations are untouched: none of them mentions the new table or the new sync_tokens columns" do
      for f <- Path.wildcard(Path.join(@dir, "0000[0-4]*.sql")) ++ Path.wildcard(Path.join(@dir, "00005[0-3]_*.sql")) do
        content = File.read!(f)

        for word <- ["sync_room_cursors", "stream_version", "prev_since_token", "prev_account_data_pos", "prev_cross_signing_pos"],
            do: refute(content =~ Regex.compile!("(?<![A-Za-z0-9_])#{word}(?![A-Za-z0-9_])"), "#{Path.basename(f)} must not be edited (a new migration instead): #{word}")
      end
    end

    test "up creates sync_room_cursors with the ten columns of D3" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/create table (if not exists )?(public\.)?sync_room_cursors\s*\(/

      for col <- ~w(user_id device_id room_id gen pos class invite_marker prev_pos prev_class prev_invite_marker),
          do: assert(sql =~ Regex.compile!("(?<![a-z_])#{col}\\s+(text|bigint)"), "the table has the column #{col}")
    end

    test "up keys the table by (user_id, device_id, room_id) and cascades from sync_tokens by (user_id, device_id)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/primary key\s*\(\s*user_id\s*,\s*device_id\s*,\s*room_id\s*\)/
      assert sql =~ ~r/foreign key\s*\(\s*user_id\s*,\s*device_id\s*\)\s*references (public\.)?sync_tokens\s*(\(\s*user_id\s*,\s*device_id\s*\))?\s*on delete cascade/
    end

    test "up adds the five sync_tokens columns of D6 / D8 / D19 (catalog-only: constant defaults)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/alter table (public\.)?sync_tokens/

      assert sql =~ ~r/add column (if not exists )?stream_version smallint not null default 0/
      assert sql =~ ~r/add column (if not exists )?generation bigint not null default 0/
      assert sql =~ ~r/add column (if not exists )?prev_since_token text(?! not null)/
      assert sql =~ ~r/add column (if not exists )?prev_account_data_pos bigint(?! not null)/
      assert sql =~ ~r/add column (if not exists )?prev_cross_signing_pos bigint(?! not null)/
      refute sql =~ ~r/default (nextval|now|random|gen_random|clock_timestamp|current_)/, "a volatile default would rewrite sync_tokens (catalog-only is the contract)"
    end

    test "up grants the runtime role the table (nebu_app) as 000039 / 000052 do" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/grant [a-z, ]*select[a-z, ]* on (table )?(public\.)?sync_room_cursors to nebu_app/
      assert sql =~ ~r/grant [a-z, ]*insert[a-z, ]* on (table )?(public\.)?sync_room_cursors to nebu_app/
      assert sql =~ ~r/grant [a-z, ]*update[a-z, ]* on (table )?(public\.)?sync_room_cursors to nebu_app/
      assert sql =~ ~r/grant [a-z, ]*delete[a-z, ]* on (table )?(public\.)?sync_room_cursors to nebu_app/
    end

    test "up is DDL only and transaction-safe: no data statement, no BEGIN / COMMIT / CONCURRENTLY, and no lock on events (D19)" do
      sql = code_sql(up_file())
      refute sql =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
      refute sql =~ ~r/LOCK\s+TABLE/i
      refute norm(sql) =~ ~r/(alter table|lock table|create (unique )?index [^;]* on) (public\.)?events\b/, "no statement touches events (no lock, no index, no rewrite)"
    end

    test "down drops the table first, then the five sync_tokens columns; no CASCADE, no CONCURRENTLY" do
      sql = norm(code_sql(down_file()))
      assert sql =~ ~r/drop table (if exists )?(public\.)?sync_room_cursors\s*;/
      for col <- @new_token_columns, do: assert(sql =~ Regex.compile!("drop column (if exists )?#{col}\\b"), "down drops sync_tokens.#{col}")
      refute sql =~ "cascade", "every object is dropped explicitly"
      refute sql =~ "concurrently"
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m

      at = fn regex -> regex |> Regex.run(sql, return: :index) |> hd() |> elem(0) end
      assert at.(~r/drop table/) < at.(~r/drop column/), "the table (which references sync_tokens) before the columns"
    end

    test "the header names the story, the table and the columns, and says that every client falls back once more after a down" do
      h = header(up_file())
      for word <- ["sync-stream-position", "sync_room_cursors", "stream_version", "generation"], do: assert(h =~ word, "the up header mentions #{word}")
      assert header(down_file()) =~ ~r/fall back|fallback|initial sync/i
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  # integration
  # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  defp columns(table) do
    T.sql!(
      "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY column_name",
      [table]
    ).rows
    |> Map.new(fn [name, type, nullable, default_sql] -> {name, {type, nullable, default_sql}} end)
  end

  describe "migrated schema (integration, runtime role)" do
    @describetag :integration

    test "sync_room_cursors has exactly the ten columns of D3 with their types, all NOT NULL except invite_marker and the three prev_* columns" do
      assert columns("sync_room_cursors") == %{
               "user_id" => {"text", "NO", nil},
               "device_id" => {"text", "NO", nil},
               "room_id" => {"text", "NO", nil},
               "gen" => {"bigint", "NO", nil},
               "pos" => {"bigint", "NO", nil},
               "class" => {"text", "NO", nil},
               "invite_marker" => {"bigint", "YES", nil},
               "prev_pos" => {"bigint", "YES", nil},
               "prev_class" => {"text", "YES", nil},
               "prev_invite_marker" => {"bigint", "YES", nil}
             }
    end

    test "sync_tokens gained stream_version SMALLINT NOT NULL DEFAULT 0, generation BIGINT NOT NULL DEFAULT 0 and three nullable prev_* columns" do
      cols = columns("sync_tokens")
      assert cols["stream_version"] == {"smallint", "NO", "0"}
      assert cols["generation"] == {"bigint", "NO", "0"}
      assert cols["prev_since_token"] == {"text", "YES", nil}
      assert cols["prev_account_data_pos"] == {"bigint", "YES", nil}
      assert cols["prev_cross_signing_pos"] == {"bigint", "YES", nil}
      # nothing else changed: the older columns are still there
      for old <- ~w(user_id device_id since_token last_event_id updated_at account_data_pos cross_signing_pos), do: assert(Map.has_key?(cols, old), "sync_tokens.#{old} is untouched")
    end

    test "the primary key is (user_id, device_id, room_id) in that order" do
      assert %{rows: [[cols]]} =
               T.sql!(
                 "SELECT array_agg(a.attname ORDER BY k.ord) FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum WHERE i.indrelid = 'sync_room_cursors'::regclass AND i.indisprimary"
               )

      assert cols == ["user_id", "device_id", "room_id"]
    end

    test "one foreign key: (user_id, device_id) -> sync_tokens (user_id, device_id) ON DELETE CASCADE" do
      assert %{rows: [[1, "sync_tokens", "c", ["user_id", "device_id"], ["user_id", "device_id"]]]} =
               T.sql!("""
               SELECT count(*) OVER (), c.confrelid::regclass::text, c.confdeltype,
                      (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum),
                      (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.confkey) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum)
               FROM pg_constraint c WHERE c.conrelid = 'sync_room_cursors'::regclass AND c.contype = 'f'
               """)
    end

    test "the runtime role uses the table: insert, select, update, delete; a cursor without a token row is refused; the token row's delete cascades" do
      uid = T.provision_user!()
      now = System.system_time(:millisecond)
      ins = "INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class) VALUES ($1, $2, $3, 1, 5, 'join')"

      assert_raise Postgrex.Error, ~r/foreign key|violates/i, fn -> T.sql!(ins, [uid, "NOPE", "!r1:test.local"]) end

      T.sql!("INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at) VALUES ($1, 'D1', 's2_x', NULL, $2), ($1, 'D2', 's2_y', NULL, $2)", [uid, now])
      T.sql!(ins, [uid, "D1", "!r1:test.local"])
      T.sql!(ins, [uid, "D1", "!r2:test.local"])
      T.sql!(ins, [uid, "D2", "!r1:test.local"])
      assert_raise Postgrex.Error, ~r/duplicate key|unique/i, fn -> T.sql!(ins, [uid, "D1", "!r1:test.local"]) end

      T.sql!("UPDATE sync_room_cursors SET pos = 9, prev_pos = 5, prev_class = 'join', invite_marker = 3, prev_invite_marker = 2 WHERE user_id = $1 AND device_id = 'D1' AND room_id = '!r1:test.local'", [uid])
      assert %{rows: [[9, 5, "join", 3, 2]]} = T.sql!("SELECT pos, prev_pos, prev_class, invite_marker, prev_invite_marker FROM sync_room_cursors WHERE user_id = $1 AND device_id = 'D1' AND room_id = '!r1:test.local'", [uid])

      T.sql!("DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = 'D1'", [uid])
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1 AND device_id = 'D1'", [uid]), "the cursors of the deleted device are gone (cascade)"
      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1 AND device_id = 'D2'", [uid]), "another device's cursors stay"

      T.sql!("DELETE FROM sync_tokens WHERE user_id = $1", [uid])
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [uid])
    end

    # dev step, fix cycle 2 (code review delta cycle 1, MINOR-1): the CHECK constraints of security review INFO-3 (migration 000054 was never released, so every
    # database runs the CHECK version of the file: the throwaway DB was re-created for it)
    test "class and prev_class accept only the three partition classes (a check violation otherwise); prev_class NULL is allowed" do
      uid = T.provision_user!()
      T.sql!("INSERT INTO sync_tokens (user_id, device_id, since_token, updated_at) VALUES ($1, 'D1', 's2_c', $2)", [uid, System.system_time(:millisecond)])
      ins = "INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class, prev_class) VALUES ($1, 'D1', $2, 1, 5, $3, $4)"

      for {class, prev, n} <- [{"join", nil, 1}, {"invite", "leave", 2}, {"leave", "invite", 3}, {"join", "join", 4}],
          do: T.sql!(ins, [uid, "!ok#{n}:test.local", class, prev])

      for {class, prev, n} <- [{"bogus", nil, 1}, {"none", nil, 2}, {"join", "bogus", 3}, {"JOIN", nil, 4}] do
        err = assert_raise Postgrex.Error, fn -> T.sql!(ins, [uid, "!bad#{n}:test.local", class, prev]) end
        assert err.postgres.code == :check_violation, "class #{inspect(class)} / prev_class #{inspect(prev)} is a check violation, got #{inspect(err.postgres.code)}"
      end

      assert %{rows: [[4]]} = T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [uid])
      T.sql!("DELETE FROM sync_tokens WHERE user_id = $1", [uid])
    end

    test "a token row upsert (what /sync does) does NOT delete the cursors: only a DELETE of the row cascades" do
      uid = T.provision_user!()
      now = System.system_time(:millisecond)
      T.sql!("INSERT INTO sync_tokens (user_id, device_id, since_token, updated_at) VALUES ($1, 'D1', 's2_a', $2)", [uid, now])
      T.sql!("INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class) VALUES ($1, 'D1', '!r1:test.local', 1, 5, 'join')", [uid])

      T.sql!(
        "INSERT INTO sync_tokens (user_id, device_id, since_token, updated_at) VALUES ($1, 'D1', 's2_b', $2) ON CONFLICT (user_id, device_id) DO UPDATE SET since_token = EXCLUDED.since_token",
        [uid, now]
      )

      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [uid])
      T.sql!("DELETE FROM sync_tokens WHERE user_id = $1", [uid])
    end
  end

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp table?(tx), do: Postgrex.query!(tx, "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = 'sync_room_cursors'", []).rows == [[1]]

    defp token_columns(tx) do
      Postgrex.query!(tx, "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'sync_tokens' AND column_name = ANY($1) ORDER BY column_name", [@new_token_columns]).rows
      |> List.flatten()
    end

    defp present?(tx), do: table?(tx) and token_columns(tx) == Enum.sort(@new_token_columns)
    defp absent?(tx), do: not table?(tx) and token_columns(tx) == []
    defp run!(tx, sql), do: Postgrex.query!(tx, sql, [], query_type: :text)

    test "fresh schema: down removes the table and the five columns, up restores them, a second up is a no-op" do
      up = read!(up_file())
      down = read!(down_file())

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert present?(tx), "precondition: the migrated database has the table and the columns"

            run!(tx, down)
            assert absent?(tx), "down must remove the table and the five columns"

            run!(tx, up)
            assert present?(tx), "up must restore all of it"

            run!(tx, up)
            assert present?(tx), "a second up is harmless (IF NOT EXISTS)"

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end

    test "populated schema: token rows keep their data (stream_version 0, generation 0), the table starts empty, down keeps the rows" do
      up = read!(up_file())
      down = read!(down_file())
      uid = T.provision_user!()
      now = System.system_time(:millisecond)

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            run!(tx, down)
            assert absent?(tx)

            # the populated "before" world: a device-less row, two devices, with positions and anchors
            Postgrex.query!(
              tx,
              "INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at, account_data_pos, cross_signing_pos) VALUES ($1, '', 'old-empty', NULL, $2, 0, 0), ($1, 'DEVA', 'old-a', '$ev', $2, 7, 3), ($1, 'DEVB', 'old-b', '$ev2', $2, 9, 4)",
              [uid, now]
            )

            run!(tx, up)
            assert present?(tx)

            assert %{rows: [["", "old-empty", 0, 0, nil, nil, nil], ["DEVA", "old-a", 0, 0, nil, nil, nil], ["DEVB", "old-b", 0, 0, nil, nil, nil]]} =
                     Postgrex.query!(
                       tx,
                       "SELECT device_id, since_token, stream_version, generation, prev_since_token, prev_account_data_pos, prev_cross_signing_pos FROM sync_tokens WHERE user_id = $1 ORDER BY device_id",
                       [uid]
                     ),
                   "every existing row is a timestamp-era row (stream_version 0): each client falls back once (D6)"

            assert %{rows: [[7, 3], [9, 4]]} = Postgrex.query!(tx, "SELECT account_data_pos, cross_signing_pos FROM sync_tokens WHERE user_id = $1 AND device_id <> '' ORDER BY device_id", [uid]), "the D9 positions are untouched"
            assert %{rows: [[0]]} = Postgrex.query!(tx, "SELECT count(*) FROM sync_room_cursors", []), "no backfill: the table starts empty"

            # the new objects work on the populated rows
            Postgrex.query!(tx, "INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class) VALUES ($1, 'DEVA', '!r:test.local', 1, 4, 'join')", [uid])
            Postgrex.query!(tx, "DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = 'DEVA'", [uid])
            assert %{rows: [[0]]} = Postgrex.query!(tx, "SELECT count(*) FROM sync_room_cursors", []), "the cascade works on a migrated row"

            # the runtime role can use the table inside the same transaction
            assert %{rows: [[true, true, true, true]]} =
                     Postgrex.query!(
                       tx,
                       "SELECT has_table_privilege('nebu_app', 'sync_room_cursors', 'SELECT'), has_table_privilege('nebu_app', 'sync_room_cursors', 'INSERT'), has_table_privilege('nebu_app', 'sync_room_cursors', 'UPDATE'), has_table_privilege('nebu_app', 'sync_room_cursors', 'DELETE')",
                       []
                     )

            # a down on the populated schema loses only the new objects: the remaining token rows stay
            Postgrex.query!(tx, "INSERT INTO sync_tokens (user_id, device_id, since_token, updated_at) VALUES ($1, 'DEVA', 's2_new', $2)", [uid, now])
            run!(tx, down)
            assert absent?(tx)
            assert %{rows: [[3]]} = Postgrex.query!(tx, "SELECT count(*) FROM sync_tokens WHERE user_id = $1", [uid])
            assert %{rows: [["old-empty"]]} = Postgrex.query!(tx, "SELECT since_token FROM sync_tokens WHERE user_id = $1 AND device_id = ''", [uid])

            run!(tx, up)
            assert present?(tx)
            Postgrex.rollback(tx, :populated_ok)
          end)
        end)

      assert result == {:error, :populated_ok}
    end
  end
end
