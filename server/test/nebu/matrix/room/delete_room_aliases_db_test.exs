defmodule Nebu.Matrix.Room.DeleteRoomAliasesDBTest do
  use ExUnit.Case, async: false

  # ─── Story room-canonical-alias-from-name (code-review MAJOR fix) ─────────────
  #
  # INTEGRATION tests — require a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo started).
  # Excluded from the unit run; run via make test-integration / on the redeployed stack.
  #
  # Regression for the cross-story interaction MAJOR:
  #   room_aliases.room_id is `TEXT NOT NULL REFERENCES rooms(room_id)` with NO
  #   ON DELETE CASCADE. The failed-create orphan cleanup calls
  #   Nebu.Matrix.Room.DB.delete_room/1, which deletes child rows then `rooms`. If it
  #   does NOT also delete room_aliases first, the `DELETE FROM rooms` violates the FK,
  #   the cleanup transaction rolls back, and the orphan room (the exact bug story 1
  #   fixed) survives.
  #
  # These tests exercise the REAL Repo so the actual FK constraint is in play — a
  # FakeDB cannot reproduce an FK violation.

  @moduletag :integration

  alias Nebu.Matrix.Room.DB

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    room_id = "!#{@run_id}_alias_del:test.local"
    alias_str = "##{@run_id}-del:test.local"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM room_aliases WHERE room_id = $1", [room_id])
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [room_id])
    end)

    {:ok, room_id: room_id, alias_str: alias_str}
  end

  defp insert_room(room_id) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO rooms (room_id, visibility, created_at) VALUES ($1, 'private', $2) ON CONFLICT (room_id) DO NOTHING",
      [room_id, System.system_time(:millisecond)]
    )
  end

  defp alias_count(alias_str) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT COUNT(*) FROM room_aliases WHERE alias = $1", [alias_str])

    n
  end

  defp room_count(room_id) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT COUNT(*) FROM rooms WHERE room_id = $1", [room_id])

    n
  end

  test "delete_room removes the room's room_aliases rows", ctx do
    insert_room(ctx.room_id)
    assert :ok = DB.insert_room_alias(ctx.alias_str, ctx.room_id, System.system_time(:millisecond))
    assert alias_count(ctx.alias_str) == 1

    assert :ok = DB.delete_room(ctx.room_id)

    assert alias_count(ctx.alias_str) == 0, "delete_room must remove the room's alias rows"
    assert room_count(ctx.room_id) == 0
  end

  test "delete_room succeeds (no FK violation) when an alias is registered — orphan cleanup leaves NO rooms row AND NO room_aliases row", ctx do
    # Reproduce the create_room orphan-cleanup scenario: a room exists, an alias was
    # registered, then a later step fails and create_room calls delete_room/1 to clean up.
    insert_room(ctx.room_id)
    assert :ok = DB.insert_room_alias(ctx.alias_str, ctx.room_id, System.system_time(:millisecond))

    # The fix: delete_room must NOT FK-fail; it returns :ok and removes both rows.
    assert :ok = DB.delete_room(ctx.room_id)

    assert room_count(ctx.room_id) == 0, "the orphan room must be fully removed"
    assert alias_count(ctx.alias_str) == 0, "the orphan alias must be fully removed"
  end

  test "delete_room is idempotent and a no-op when no alias exists", ctx do
    insert_room(ctx.room_id)

    assert :ok = DB.delete_room(ctx.room_id)
    assert room_count(ctx.room_id) == 0
    # Second delete of an absent room is still :ok.
    assert :ok = DB.delete_room(ctx.room_id)
  end
end
