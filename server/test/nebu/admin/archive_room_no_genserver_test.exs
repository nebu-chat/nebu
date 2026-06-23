defmodule Nebu.Admin.ArchiveRoomNoGenserverTest do
  use ExUnit.Case, async: false

  # ─── Story rm3-admin-create-archive (AC6/AC8) ────────────────────────────────
  #
  # INTEGRATION test — requires a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo started).
  # Excluded from the unit run; runs via make test-integration / on the redeployed stack.
  #
  # Verifies the admin archive path through `Nebu.Matrix.archive_room/2`:
  #   - AC6: a room row in the DB with NO running Room GenServer is still archived
  #     (status='archived') — the dispatcher path is GenServer-independent. Returns :ok.
  #   - AC8: archiving a non-existent room returns {:error, :not_found} (no crash/500),
  #     so the Admin UI can render a "Room not found" flash.
  #
  # ATDD — written FIRST (RED before Nebu.Matrix.archive_room/2 existed).

  @moduletag :integration

  alias Nebu.Matrix

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  @actor "@admin:test.local"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    room_id = "!#{@run_id}_archive:test.local"

    # A stale room row: active, zero members, NO Room GenServer started.
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO rooms (room_id, visibility, created_at, status)
      VALUES ($1, 'private', $2, 'active')
      ON CONFLICT (room_id) DO UPDATE SET status = 'active'
      """,
      [room_id, System.system_time(:millisecond)]
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [room_id])
    end)

    {:ok, room_id: room_id}
  end

  defp status(room_id) do
    %{rows: [[s]]} =
      Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT status FROM rooms WHERE room_id = $1", [room_id])

    s
  end

  test "AC6: archives a room with no running GenServer → status='archived', returns :ok", ctx do
    # No GenServer running for this room.
    assert {:error, :not_found} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(ctx.room_id)

    assert :ok = Matrix.archive_room(@actor, ctx.room_id)

    assert status(ctx.room_id) == "archived"
  end

  test "AC8: archiving a non-existent room returns {:error, :not_found}, no crash" do
    assert {:error, :not_found} =
             Matrix.archive_room(@actor, "!#{@run_id}_does_not_exist:test.local")
  end
end
