defmodule Nebu.Admin.AdminStaleRoomsTest do
  @moduledoc """
  Story rm2-stale-room-filter — Nebu.Admin.DB stale-room filter + effective status.

  Test #1 is an INTEGRATION test (requires a live PostgreSQL, NEBU_DB_URL set,
  Nebu.Repo started) — excluded from the unit run; runs via make test-integration.

  AC3 — `list_rooms(50, "", "stale", "")` returns exactly the rooms where
  `status='active' AND member_count=0`. The filter value maps to a FIXED WHERE
  fragment (never interpolated).

  Test #2 is a pure ExUnit test (no DB) of the row→map effective-status computation
  via the public test seam `Nebu.Admin.DB.room_effective_status/2`.

  ATDD — written FIRST (RED before the stale branch existed).
  """
  use ExUnit.Case, async: false

  alias Nebu.Admin.DB

  describe "row→map effective status (AC2, pure)" do
    test "status active + member_count 0 → effective \"stale\"" do
      assert DB.room_effective_status("active", 0) == "stale"
    end

    test "status active + member_count > 0 → effective \"active\"" do
      assert DB.room_effective_status("active", 1) == "active"
      assert DB.room_effective_status("active", 5) == "active"
    end

    test "status archived stays \"archived\" regardless of members" do
      assert DB.room_effective_status("archived", 0) == "archived"
      assert DB.room_effective_status("archived", 3) == "archived"
    end
  end

  describe "list_rooms stale filter (AC3)" do
    @moduletag :integration

    @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    @active_with_member "!#{@run_id}_active_member:test.local"
    @active_no_member "!#{@run_id}_active_empty:test.local"
    @archived_no_member "!#{@run_id}_archived_empty:test.local"

    setup do
      if Process.whereis(Nebu.Repo) == nil do
        flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
      end

      now = System.system_time(:millisecond)

      insert_room = fn room_id, status ->
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO rooms (room_id, name, status, created_at)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (room_id) DO UPDATE SET status = EXCLUDED.status
          """,
          [room_id, room_id, status, now]
        )
      end

      insert_room.(@active_with_member, "active")
      insert_room.(@active_no_member, "active")
      insert_room.(@archived_no_member, "archived")

      # One active member for the active_with_member room (left_at IS NULL).
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO room_members (room_id, user_id, joined_at, left_at)
        VALUES ($1, $2, $3, NULL)
        ON CONFLICT DO NOTHING
        """,
        [@active_with_member, "@m_#{@run_id}:test.local", now]
      )

      on_exit(fn ->
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "DELETE FROM room_members WHERE room_id = ANY($1)",
          [[@active_with_member, @active_no_member, @archived_no_member]]
        )

        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "DELETE FROM rooms WHERE room_id = ANY($1)",
          [[@active_with_member, @active_no_member, @archived_no_member]]
        )
      end)

      :ok
    end

    test "returns exactly the active + 0-member room" do
      {rooms, _next} = DB.list_rooms(50, "", "stale", "")

      ids = MapSet.new(rooms, & &1.room_id)

      assert MapSet.member?(ids, @active_no_member)
      refute MapSet.member?(ids, @active_with_member)
      refute MapSet.member?(ids, @archived_no_member)

      # The returned stale room carries the effective status "stale".
      stale = Enum.find(rooms, &(&1.room_id == @active_no_member))
      assert stale.status == "stale"
    end
  end
end
