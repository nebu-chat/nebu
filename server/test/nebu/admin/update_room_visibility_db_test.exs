defmodule Nebu.Admin.UpdateRoomVisibilityDBTest do
  use ExUnit.Case, async: false

  # ─── Story rm1-room-visibility (AC2) — Nebu.Admin.DB.update_room_visibility/2 ──
  #
  # INTEGRATION test — requires a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo started).
  # Excluded from the unit run; runs via make test-integration / on the redeployed stack.
  #
  # ATDD — written FIRST (RED before update_room_visibility/2 existed).
  # Verifies:
  #   - update_room_visibility(room_id, "public") flips the rooms.visibility column.
  #   - The write is a no-op when the value is already set (AND visibility != $2),
  #     so re-applying the same value still returns :ok.

  @moduletag :integration

  alias Nebu.Admin.DB

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    room_id = "!#{@run_id}_vis:test.local"

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO rooms (room_id, visibility, created_at, status)
      VALUES ($1, 'private', $2, 'active')
      ON CONFLICT (room_id) DO UPDATE SET visibility = 'private'
      """,
      [room_id, System.system_time(:millisecond)]
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [room_id])
    end)

    {:ok, room_id: room_id}
  end

  defp current_visibility(room_id) do
    %{rows: [[v]]} =
      Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT visibility FROM rooms WHERE room_id = $1", [room_id])

    v
  end

  test "update_room_visibility flips visibility private → public", ctx do
    assert current_visibility(ctx.room_id) == "private"

    assert :ok = DB.update_room_visibility(ctx.room_id, "public")

    assert current_visibility(ctx.room_id) == "public"
  end

  test "update_room_visibility is idempotent for the already-set value", ctx do
    assert :ok = DB.update_room_visibility(ctx.room_id, "public")
    assert current_visibility(ctx.room_id) == "public"

    # Re-applying the same value is a no-op (AND visibility != $2 → 0 rows) but still :ok.
    assert :ok = DB.update_room_visibility(ctx.room_id, "public")
    assert current_visibility(ctx.room_id) == "public"
  end
end
