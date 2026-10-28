defmodule Nebu.Migration.Migration000053EventsRoomPositionTest do
  @moduledoc """
  Acceptance tests for story `events-room-position` (epic oauth-broker, follow-up `fc`, story 1 of 2), Scenario 5 / D1 - D5, D7: migration
  `000053_events_room_position` (the number is confirmed by the implementer at commit time: the tests find the file by its NAME,
  `*_events_room_position.{up,down}.sql`, and require a number above 000052):

      ALTER TABLE rooms  ADD COLUMN event_pos BIGINT NOT NULL DEFAULT 0
      ALTER TABLE events ADD COLUMN room_pos  BIGINT                       -- nullable, no default, no backfill
      CREATE UNIQUE INDEX events_room_pos_idx ON events (room_id, room_pos) WHERE room_pos IS NOT NULL
      CREATE FUNCTION <name>() RETURNS trigger ... UPDATE rooms SET event_pos = event_pos + 1 WHERE room_id = NEW.room_id RETURNING event_pos INTO NEW.room_pos
      CREATE TRIGGER <name> BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION <name>()
      -- down: the trigger, the function, the index, both columns

  Mirrors `000052_sync_device_positions_test.exs`: static SQL-file analysis (no DB, runs in the unit job) and an `:integration` part as the RUNTIME role plus a down / up round trip
  on the privileged role inside a rolled-back transaction, on the migrated (fresh) schema AND on a POPULATED schema (existing events keep `room_pos` NULL, a new event in an existing room
  gets 1, an INSERT that supplies `room_pos` is overwritten, nothing is lost by a down), plus the documented MANUAL pre-create path of D5 (columns and index created by hand, then the file
  must still apply). The names of the function and of the trigger are NOT pinned (the story does not name them): they are found by introspection. After adding the migration reset the
  throwaway database (`docker rm -f nebu-oauth-pg`, `.oauth-ci/cleanup.sh`) so that it runs.

  Story gap recorded here: the story calls the trigger "the first trigger of the schema" (OQ1 answer), but `events_search_vector_trigger` (000001 / 000002, `BEFORE INSERT OR UPDATE OF content ON
  events`) already exists. The tests pin that the new trigger is a SEPARATE BEFORE INSERT-only trigger and that the old one is untouched.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_events_room_position.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_events_room_position.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_events_room_position.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()

  # the SQL without the bodies of dollar-quoted blocks (the function body is not DDL of the migration itself)
  defp without_bodies(sql), do: String.replace(sql, ~r/\$(\w*)\$.*?\$\1\$/s, "$$ body $$")

  defp function_body(path) do
    case Regex.run(~r/\$(\w*)\$(.*?)\$\1\$/s, code_sql(path)) do
      [_, _tag, body] -> String.replace(body, ~r{/\*.*?\*/}s, "")
      _ -> flunk("the up migration has no dollar-quoted function body")
    end
  end

  defp header(path), do: path |> read!() |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.map_join("\n", &String.replace(&1, ~r/\A--\s?/, ""))

  describe "migration 000053 files (static)" do
    test "up and down exist exactly once, with the same number, above 000052" do
      assert [up] = files("up"), "exactly one *_events_room_position.up.sql"
      assert [down] = files("down"), "exactly one *_events_room_position.down.sql"
      assert number(up) == number(down), "up and down carry the same number"
      assert number(up) >= 53, "the next free number after 000052 (sync_device_positions)"
      assert Path.wildcard(Path.join(@dir, "#{String.pad_leading(Integer.to_string(number(up)), 6, "0")}_*.up.sql")) == [up], "no second migration with that number"
    end

    test "the earlier migrations are untouched: none of them mentions the new columns or the index" do
      for f <- Path.wildcard(Path.join(@dir, "0000[0-4]*.sql")) ++ Path.wildcard(Path.join(@dir, "00005[0-2]_*.sql")) do
        content = File.read!(f)

        for word <- ["room_pos", "event_pos", "events_room_pos_idx"],
            do: refute(content =~ Regex.compile!("(?<![A-Za-z0-9_])#{word}(?![A-Za-z0-9_])"), "#{Path.basename(f)} must not be edited (a new migration instead): #{word}")
      end
    end

    test "up adds rooms.event_pos BIGINT NOT NULL DEFAULT 0 (the per-room counter)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/alter table (public\.)?rooms\s+add column (if not exists )?event_pos bigint not null default 0\s*;/
    end

    test "up adds events.room_pos as a plain nullable BIGINT: no NOT NULL, no DEFAULT (D3)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/alter table (public\.)?events\s+add column (if not exists )?room_pos bigint\s*;/
    end

    test "up creates the UNIQUE partial index events_room_pos_idx (room_id, room_pos), plain (D4)" do
      sql = norm(code_sql(up_file()))
      assert sql =~ ~r/create unique index (if not exists )?events_room_pos_idx\s+on (public\.)?events\s*(using btree\s*)?\(\s*room_id\s*,\s*room_pos\s*\)\s*where room_pos is not null\s*;/
      refute sql =~ "concurrently"
    end

    test "up creates a BEFORE INSERT FOR EACH ROW trigger on events (not AFTER, not on UPDATE)" do
      sql = norm(without_bodies(code_sql(up_file())))
      assert sql =~ ~r/create (or replace )?trigger \w+\s+before insert on (public\.)?events\s+for each row\s+execute (function|procedure) (public\.)?\w+\(\)/
      refute sql =~ ~r/create (or replace )?trigger \w+\s+before insert or/
      refute sql =~ ~r/create (or replace )?trigger \w+\s+after /
    end

    test "up creates the trigger function: UPDATE rooms ... RETURNING event_pos INTO NEW.room_pos (D1)" do
      sql = norm(without_bodies(code_sql(up_file())))
      assert sql =~ ~r/create (or replace )?function (public\.)?\w+\(\)\s*returns trigger/

      # the shape of the statement is free (alias, qualified names, a variable, a CTE): what must be there is the update of the room row's counter
      body = norm(function_body(up_file()))
      for needle <- ["update", "rooms", "event_pos", "new.room_id", "new.room_pos", "return new"], do: assert(body =~ needle, "the function body mentions #{needle}")
      refute body =~ ~r/nextval|sequence|pg_advisory/, "the position is drawn from the room row (its lock is the serialisation), not from a sequence or an advisory lock"
    end

    test "up is DDL only and transaction-safe: no backfill, no BEGIN / COMMIT / CONCURRENTLY" do
      sql = code_sql(up_file())
      outside = without_bodies(sql)
      refute outside =~ ~r/\b(INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/i
      refute norm(sql) =~ ~r/update (public\.)?events\b/, "no backfill (D3)"
      refute outside =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/CONCURRENTLY/i
    end

    test "down drops the trigger, its function, the index and both columns, trigger first" do
      sql = norm(code_sql(down_file()))
      assert sql =~ ~r/drop trigger (if exists )?\w+ on (public\.)?events/
      assert sql =~ ~r/drop function (if exists )?(public\.)?\w+\(\)/
      assert sql =~ ~r/drop index (if exists )?(public\.)?events_room_pos_idx/
      assert sql =~ ~r/alter table (public\.)?events\s+drop column (if exists )?room_pos\b/
      assert sql =~ ~r/alter table (public\.)?rooms\s+drop column (if exists )?event_pos\b/
      refute sql =~ "cascade", "every object is dropped explicitly"
      refute sql =~ "concurrently"
      refute sql =~ ~r/^\s*(begin|commit)\s*;/m

      at = fn regex -> regex |> Regex.run(sql, return: :index) |> hd() |> elem(0) end
      assert at.(~r/drop trigger/) < at.(~r/drop function/), "the trigger before its function"
      assert at.(~r/drop trigger/) < at.(~r/drop column/), "the trigger before the columns"
      assert at.(~r/drop index/) < at.(~r/alter table (public\.)?events\s+drop column/), "the index before the column it indexes"
    end

    test "the header names the story, the columns, the index and ADR-018 (the trigger exception)" do
      h = header(up_file())
      for word <- ["events-room-position", "room_pos", "event_pos", "events_room_pos_idx", "ADR-018", "trigger"], do: assert(h =~ word, "the header mentions #{word}")
    end

    test "the header carries the OPERATOR NOTE (D5): window, lock, manual pre-create statements, rollback order" do
      h = header(up_file()) |> String.replace(~r/\s+/, " ")
      assert h =~ ~r/OPERATOR NOTE/i
      assert h =~ ~r/maintenance window/i
      assert h =~ "ACCESS EXCLUSIVE"
      assert h =~ "ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos BIGINT"
      assert h =~ "ALTER TABLE rooms ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0"
      assert h =~ ~r/CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS events_room_pos_idx ON events \(room_id, room_pos\) WHERE room_pos IS NOT NULL/
      assert h =~ "sync-stream-position", "the down note: the reader story must be reverted first"
      assert h =~ ~r/indisvalid/i, "the INVALID index hazard of a failed CONCURRENTLY build (D5)"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  # integration
  # ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  # the position trigger found by what it does (the story names neither the function nor the trigger)
  @position_triggers """
  SELECT t.tgname, t.tgtype, t.tgenabled, p.prosecdef, p.oid::regprocedure::text
  FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = 'events'::regclass AND NOT t.tgisinternal AND pg_get_functiondef(p.oid) ILIKE '%event_pos%'
  """

  describe "migrated schema (integration, runtime role)" do
    @describetag :integration

    test "rooms.event_pos is BIGINT NOT NULL DEFAULT 0, events.room_pos a nullable BIGINT" do
      assert %{rows: [[type, nullable, default_sql]]} =
               T.sql!("SELECT data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'rooms' AND column_name = 'event_pos'")

      assert {type, nullable, default_sql} == {"bigint", "NO", "0"}

      assert %{rows: [[type, nullable, default_sql]]} =
               T.sql!("SELECT data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'events' AND column_name = 'room_pos'")

      assert {type, nullable, default_sql} == {"bigint", "YES", nil}
    end

    test "events_room_pos_idx is a UNIQUE partial btree index on (room_id, room_pos)" do
      assert %{rows: [[def_]]} = T.sql!("SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'events' AND indexname = 'events_room_pos_idx'")
      assert def_ =~ ~r/CREATE UNIQUE INDEX events_room_pos_idx ON (public\.)?events USING btree \(room_id, room_pos\) WHERE \(room_pos IS NOT NULL\)/
    end

    test "no index covers rooms.event_pos: the counter UPDATE of every insert stays HOT-eligible (D6)" do
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'rooms' AND indexdef ~* '\\mevent_pos\\M'")
    end

    test "one position trigger: BEFORE INSERT ROW only (tgtype 7), SECURITY INVOKER (D7); search_vector trigger kept" do
      assert %{rows: [[_name, tgtype, enabled, security_definer, _fn]]} = T.sql!(@position_triggers)
      assert tgtype == 7, "tgtype #{tgtype}: ROW (1) + BEFORE (2) + INSERT (4), no UPDATE / DELETE / TRUNCATE"
      assert enabled == "O", "enabled (origin)"
      assert security_definer == false, "the trigger function runs with the rights of the inserting role"

      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM pg_trigger WHERE tgrelid = 'events'::regclass AND tgname = 'events_search_vector_trigger' AND NOT tgisinternal")
    end

    test "nebu_app fires it: inserts are stamped 1, 2, a supplied room_pos is overwritten, another room counts from 1" do
      r1 = "!mig53a#{T.rand(6)}:test.local"
      r2 = "!mig53b#{T.rand(6)}:test.local"
      now = System.system_time(:millisecond)
      for r <- [r1, r2], do: T.sql!("INSERT INTO rooms (room_id, created_at) VALUES ($1, $2)", [r, now])

      on_exit(fn ->
        T.sql!("DELETE FROM events WHERE room_id = ANY($1)", [[r1, r2]])
        T.sql!("DELETE FROM rooms WHERE room_id = ANY($1)", [[r1, r2]])
      end)

      ins = "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, room_pos) VALUES ($1, $2, '@m:test.local', 'm.room.message', '{}', $3, $4)"
      T.sql!(ins, ["$m1" <> T.rand(8), r1, now, nil])
      T.sql!(ins, ["$m2" <> T.rand(8), r1, now, 777])
      T.sql!(ins, ["$m3" <> T.rand(8), r2, now, 5])

      assert %{rows: [[1], [2]]} = T.sql!("SELECT room_pos FROM events WHERE room_id = $1 ORDER BY room_pos", [r1])
      assert %{rows: [[1]]} = T.sql!("SELECT room_pos FROM events WHERE room_id = $1", [r2])
      assert %{rows: [[2, 1]]} = T.sql!("SELECT (SELECT event_pos FROM rooms WHERE room_id = $1), (SELECT event_pos FROM rooms WHERE room_id = $2)", [r1, r2])
    end
  end

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp column?(tx, table, col) do
      %{rows: [[n]]} =
        Postgrex.query!(tx, "SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2", [table, col])

      n == 1
    end

    defp index?(tx), do: Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'events_room_pos_idx'", []).rows == [[1]]
    defp triggers(tx), do: Postgrex.query!(tx, @position_triggers, []).rows

    defp present?(tx), do: column?(tx, "rooms", "event_pos") and column?(tx, "events", "room_pos") and index?(tx) and length(triggers(tx)) == 1

    defp absent?(tx) do
      not column?(tx, "rooms", "event_pos") and not column?(tx, "events", "room_pos") and not index?(tx) and
        triggers(tx) == [] and
        Postgrex.query!(tx, "SELECT count(*) FROM pg_proc WHERE prosrc ILIKE '%event_pos%' AND pronamespace = current_schema()::regnamespace", []).rows == [[0]]
    end

    defp run!(tx, sql), do: Postgrex.query!(tx, sql, [], query_type: :text)

    test "fresh schema: down removes everything, up restores it, a second up is a no-op with one trigger" do
      up = read!(up_file())
      down = read!(down_file())

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert present?(tx), "precondition: the migrated database has the columns, the index and the trigger"

            run!(tx, down)
            assert absent?(tx), "down must remove the two columns, the index, the trigger and its function"

            run!(tx, up)
            assert present?(tx), "up must restore all of it"

            run!(tx, up)
            assert present?(tx), "a second up is harmless: the documented manual pre-create path leaves the file a no-op except the trigger"
            assert length(triggers(tx)) == 1

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end

    test "populated schema: old events stay NULL, a new event gets 1, a supplied value is overwritten; down keeps events" do
      up = read!(up_file())
      down = read!(down_file())
      now = System.system_time(:millisecond)
      {r1, r2, r3} = {"!mig53p1#{T.rand(6)}:test.local", "!mig53p2#{T.rand(6)}:test.local", "!mig53p3#{T.rand(6)}:test.local"}

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            run!(tx, down)
            assert absent?(tx)

            # the populated "before" world: three rooms, 40 + 25 events, no position columns yet
            for r <- [r1, r2, r3], do: Postgrex.query!(tx, "INSERT INTO rooms (room_id, created_at) VALUES ($1, $2)", [r, now])

            for {r, n} <- [{r1, 40}, {r2, 25}] do
              Postgrex.query!(
                tx,
                "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts) SELECT '$old' || $1::text || g, $1::text, '@m:test.local', 'm.room.message', ('{\"g\":' || g || '}')::jsonb, $2::bigint + g FROM generate_series(1, $3::int) g",
                [r, now, n]
              )
            end

            run!(tx, up)
            assert present?(tx)

            assert %{rows: [[65, 0]]} = Postgrex.query!(tx, "SELECT count(*), count(room_pos) FROM events WHERE room_id = ANY($1)", [[r1, r2]]), "every existing event keeps room_pos NULL (D3)"
            assert %{rows: [[0, 0, 0]]} = Postgrex.query!(tx, "SELECT max(event_pos), min(event_pos), count(*) FILTER (WHERE event_pos <> 0) FROM rooms WHERE room_id = ANY($1)", [[r1, r2, r3]]), "every counter starts at 0"

            ins = "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, room_pos) VALUES ($1, $2, '@m:test.local', 'm.room.message', '{}', $3, $4)"
            Postgrex.query!(tx, ins, ["$new1" <> T.rand(6), r1, now, nil])
            Postgrex.query!(tx, ins, ["$new2" <> T.rand(6), r1, now, 99])
            Postgrex.query!(tx, ins, ["$new3" <> T.rand(6), r2, now, nil])
            Postgrex.query!(tx, ins, ["$new4" <> T.rand(6), r3, now, 5])

            assert %{rows: [[1], [2]]} = Postgrex.query!(tx, "SELECT room_pos FROM events WHERE room_id = $1 AND room_pos IS NOT NULL ORDER BY room_pos", [r1]), "the new events of an existing room get 1 and 2"
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT room_pos FROM events WHERE room_id = $1 AND room_pos IS NOT NULL", [r2])
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT room_pos FROM events WHERE room_id = $1", [r3]), "a room without events yet counts from 1 as well; the supplied 5 was overwritten"
            assert %{rows: [[40]]} = Postgrex.query!(tx, "SELECT count(*) FROM events WHERE room_id = $1 AND room_pos IS NULL", [r1]), "the old events of the room are still unstamped"

            # the grants of the runtime role (the trigger function runs with its rights)
            # (no EXECUTE check on the function: PUBLIC has it by default and PostgreSQL does not check it when a trigger fires)
            assert %{rows: [[true, true, true]]} =
                     Postgrex.query!(
                       tx,
                       "SELECT has_column_privilege('nebu_app', 'rooms', 'event_pos', 'UPDATE'), has_column_privilege('nebu_app', 'events', 'room_pos', 'INSERT'), has_column_privilege('nebu_app', 'rooms', 'event_pos', 'SELECT')",
                       []
                     ),
                   "nebu_app must be able to fire the trigger: UPDATE on rooms.event_pos, INSERT on events.room_pos"

            # a down on the populated schema loses only the new columns, the events stay
            run!(tx, down)
            assert absent?(tx)
            assert %{rows: [[69]]} = Postgrex.query!(tx, "SELECT count(*) FROM events WHERE room_id = ANY($1)", [[r1, r2, r3]])
            assert %{rows: [[3]]} = Postgrex.query!(tx, "SELECT count(*) FROM rooms WHERE room_id = ANY($1)", [[r1, r2, r3]])

            run!(tx, up)
            assert present?(tx)
            Postgrex.rollback(tx, :populated_ok)
          end)
        end)

      assert result == {:error, :populated_ok}
    end

    test "the MANUAL pre-create path (D5): columns and index by hand first, then the file applies and the trigger works" do
      up = read!(up_file())
      down = read!(down_file())
      now = System.system_time(:millisecond)
      room = "!mig53m#{T.rand(6)}:test.local"

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            run!(tx, down)
            assert absent?(tx)

            # D5, outside a transaction in production (the index CONCURRENTLY); a plain CREATE INDEX here, the statements are otherwise the documented ones
            run!(tx, "ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos BIGINT")
            run!(tx, "ALTER TABLE rooms ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0")
            run!(tx, "CREATE UNIQUE INDEX IF NOT EXISTS events_room_pos_idx ON events (room_id, room_pos) WHERE room_pos IS NOT NULL")

            run!(tx, up)
            assert present?(tx)

            Postgrex.query!(tx, "INSERT INTO rooms (room_id, created_at) VALUES ($1, $2)", [room, now])
            Postgrex.query!(tx, "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts) VALUES ($1, $2, '@m:test.local', 'm.room.message', '{}', $3)", ["$man" <> T.rand(6), room, now])
            assert %{rows: [[1]]} = Postgrex.query!(tx, "SELECT room_pos FROM events WHERE room_id = $1", [room])

            Postgrex.rollback(tx, :manual_ok)
          end)
        end)

      assert result == {:error, :manual_ok}
    end
  end
end
