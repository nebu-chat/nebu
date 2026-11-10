defmodule Nebu.Migration.Migration000063EventsRoomPosCoveringIdxTest do
  @moduledoc """
  Tests for the migration `000063_events_room_pos_covering_idx` of the bugfix `sync-rejoin-floor-window-point-lookups` (found by NAME, `*_events_room_pos_covering_idx.{up,down}.sql`):

      CREATE INDEX IF NOT EXISTS events_room_pos_ts_idx ON events (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL
      -- down: DROP INDEX IF EXISTS events_room_pos_ts_idx

  The floor of the gated rejoin `/sync` range read reads `origin_server_ts` of at most 64 events at positions of ONE room; the covering index makes that an index-only scan of the window,
  cheaper than any room-only path whatever the statistics (see the header of the up file and `SyncRejoinFloorBoundDbTest`). The index is NOT unique, partial like `events_room_pos_idx`
  (which stays: no existing index is dropped or changed), and the migration touches nothing else.

  Static analysis of the SQL files (no DB, runs in the unit job), a catalog part as the RUNTIME role (`:integration`) and a down / up round trip on the privileged role inside a rolled-back
  transaction. After adding the migration re-create the throwaway database (or run the migration).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @index "events_room_pos_ts_idx"

  defp files(kind), do: Path.wildcard(Path.join(@dir, "*_events_room_pos_covering_idx.#{kind}.sql"))
  defp up_file, do: files("up") |> List.first() || flunk("no *_events_room_pos_covering_idx.up.sql in server/priv/migrations")
  defp down_file, do: files("down") |> List.first() || flunk("no *_events_room_pos_covering_idx.down.sql in server/priv/migrations")
  defp read!(path), do: File.read!(path)
  defp code_sql(path), do: path |> read!() |> String.replace(~r/--[^\n]*/, "")
  defp norm(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.downcase() |> String.trim()
  defp number(path), do: path |> Path.basename() |> String.slice(0, 6) |> String.to_integer()

  describe "migration 000063 files (static)" do
    @tag ac: "the-migration-adds-only-the-covering-index"
    test "up and down exist exactly once, with the same number 000063, and no other migration has that number" do
      assert [up] = files("up")
      assert [down] = files("down")
      assert number(up) == 63 and number(down) == 63, "000062 is oauth_codes_device_display_name: this migration is 000063"
      assert Path.wildcard(Path.join(@dir, "000063_*.up.sql")) == [up]
      assert Path.basename(up) == "000063_events_room_pos_covering_idx.up.sql"
      assert Path.basename(down) == "000063_events_room_pos_covering_idx.down.sql"
      assert up |> read!() |> String.split("\n") |> hd() =~ "000063_events_room_pos_covering_idx.up.sql"
      assert down |> read!() |> String.split("\n") |> hd() =~ "000063_events_room_pos_covering_idx.down.sql"
    end

    @tag ac: "the-migration-adds-only-the-covering-index"
    test "up is ONE idempotent CREATE INDEX: (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL, not unique, no other statement" do
      sql = norm(code_sql(up_file()))

      assert sql == "create index if not exists #{@index} on events (room_id, room_pos) include (origin_server_ts) where room_pos is not null;",
             "the up file is exactly one statement, got: #{sql}"
    end

    @tag ac: "the-migration-adds-only-the-covering-index"
    test "down drops that index and nothing else" do
      assert norm(code_sql(down_file())) == "drop index if exists #{@index};"
    end

    test "up documents the rationale and the operator note (lock, manual CONCURRENTLY pre-create)" do
      text = read!(up_file())
      assert text =~ ~r/COVERING/i and text =~ "index-only"
      assert text =~ "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}"
      assert text =~ "SHARE lock"
    end

    test "the earlier migrations are untouched: none of them mentions the new index" do
      for f <- Path.wildcard(Path.join(@dir, "0000[0-5]*.sql")) ++ Path.wildcard(Path.join(@dir, "00006[0-2]_*.sql")) do
        refute File.read!(f) =~ @index, "#{Path.basename(f)} must not mention #{@index}"
      end
    end
  end

  describe "catalog (integration, runtime role)" do
    @describetag :integration

    @tag ac: "the-migration-adds-only-the-covering-index"
    test "the index exists, is valid, partial, NOT unique, keyed by (room_id, room_pos) and covers origin_server_ts; events_room_pos_idx is untouched" do
      %{rows: [[index_def, valid?, unique?]]} =
        T.sql!(
          "SELECT pg_get_indexdef(i.indexrelid), i.indisvalid, i.indisunique FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1 AND i.indrelid = 'events'::regclass",
          [@index]
        )

      assert valid?
      refute unique?
      assert index_def =~ "(room_id, room_pos) INCLUDE (origin_server_ts)"
      assert index_def =~ "WHERE (room_pos IS NOT NULL)"

      %{rows: [[unique_def, unique_idx?]]} =
        T.sql!(
          "SELECT pg_get_indexdef(i.indexrelid), i.indisunique FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 'events_room_pos_idx' AND i.indrelid = 'events'::regclass",
          []
        )

      assert unique_idx?
      assert unique_def =~ "(room_id, room_pos) WHERE (room_pos IS NOT NULL)"
      refute unique_def =~ "INCLUDE"
    end
  end

  describe "down / up round trip (integration, privileged role, rolled back)" do
    @describetag :integration

    defp index?(tx, name), do: Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'events' AND indexname = $1", [name]).rows == [[1]]
    defp index_names(tx), do: Postgrex.query!(tx, "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'events' ORDER BY 1", []).rows
    defp run!(tx, sql), do: Postgrex.query!(tx, sql, [], query_type: :text)

    @tag ac: "the-migration-adds-only-the-covering-index"
    test "down removes exactly the covering index, up restores it, a second up is a no-op, every other index of events stays" do
      up = read!(up_file())
      down = read!(down_file())

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            assert index?(tx, @index), "precondition: the migrated database has the index"
            before = index_names(tx)

            run!(tx, down)
            refute index?(tx, @index)
            assert index_names(tx) == before -- [[@index]], "down removes only #{@index}"

            run!(tx, up)
            assert index?(tx, @index)
            assert index_names(tx) == before

            run!(tx, up)
            assert index_names(tx) == before, "a second up is harmless (the documented manual pre-create path)"

            Postgrex.rollback(tx, :round_trip_ok)
          end)
        end)

      assert result == {:error, :round_trip_ok}
    end
  end
end
