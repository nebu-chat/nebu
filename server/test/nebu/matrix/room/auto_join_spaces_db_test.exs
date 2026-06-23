defmodule Nebu.Matrix.Room.AutoJoinSpacesDBTest do
  use ExUnit.Case, async: false

  # ─── Spaces S5 (AC6): list_auto_join_spaces / list_auto_join_rooms scoping ────
  #
  # INTEGRATION tests — require a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo started).
  # Excluded from the unit run; run via make test-integration / on the redeployed stack.
  #
  # ATDD — written FIRST (RED before the room/db.ex scoping change).
  # Verifies:
  #   - list_auto_join_spaces/0 returns ONLY auto-join active Spaces (room_type='m.space')
  #   - list_auto_join_rooms/0 EXCLUDES spaces (room_type IS NULL OR != 'm.space')
  #   - the two lists are disjoint (no double-processing of a flagged row)

  @moduletag :integration

  alias Nebu.Matrix.Room.DB

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    space_id = "!#{@run_id}_space:test.local"
    room_id = "!#{@run_id}_room:test.local"
    plain_id = "!#{@run_id}_plain:test.local"
    inactive_space_id = "!#{@run_id}_inactive_space:test.local"

    # Auto-join Space (active)
    insert_room(space_id, "m.space", true, "active")
    # Auto-join plain room with explicit non-space type
    insert_room(room_id, "chat", true, "active")
    # Auto-join plain room with NULL room_type (legacy)
    insert_room(plain_id, nil, true, "active")
    # Auto-join Space but archived → excluded from both
    insert_room(inactive_space_id, "m.space", true, "archived")

    on_exit(fn ->
      Enum.each([space_id, room_id, plain_id, inactive_space_id], fn rid ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [rid])
      end)
    end)

    {:ok, space_id: space_id, room_id: room_id, plain_id: plain_id, inactive_space_id: inactive_space_id}
  end

  defp insert_room(room_id, room_type, is_auto_join, status) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO rooms (room_id, visibility, created_at, room_type, is_auto_join, status)
      VALUES ($1, 'private', $2, $3, $4, $5)
      ON CONFLICT (room_id) DO UPDATE
        SET room_type = EXCLUDED.room_type,
            is_auto_join = EXCLUDED.is_auto_join,
            status = EXCLUDED.status
      """,
      [room_id, System.system_time(:millisecond), room_type, is_auto_join, status]
    )
  end

  test "list_auto_join_spaces returns only active auto-join spaces", ctx do
    {:ok, ids} = DB.list_auto_join_spaces()

    assert ctx.space_id in ids
    refute ctx.room_id in ids
    refute ctx.plain_id in ids
    refute ctx.inactive_space_id in ids, "archived space must be excluded"
  end

  test "list_auto_join_rooms excludes spaces", ctx do
    {:ok, ids} = DB.list_auto_join_rooms()

    assert ctx.room_id in ids, "non-space auto-join room must be present"
    assert ctx.plain_id in ids, "NULL-room_type auto-join room must be present"
    refute ctx.space_id in ids, "a space must NOT appear in list_auto_join_rooms"
    refute ctx.inactive_space_id in ids
  end

  test "the two auto-join lists are disjoint", _ctx do
    {:ok, rooms} = DB.list_auto_join_rooms()
    {:ok, spaces} = DB.list_auto_join_spaces()

    assert MapSet.disjoint?(MapSet.new(rooms), MapSet.new(spaces)),
           "a flagged row must be processed by exactly one of the two paths"
  end
end
