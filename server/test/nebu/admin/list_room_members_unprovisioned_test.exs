defmodule Nebu.Admin.ListRoomMembersUnprovisionedTest do
  use ExUnit.Case, async: false

  # ─── Bug regression (merge room-management-elixir → full-elixir-stack) ───────
  #
  # Nebu.Admin.DB.list_room_members/1 used an INNER JOIN to `users`, so any room
  # member without a provisioned `users` row (e.g. an admin-added user who has not
  # yet logged in via OIDC) was silently dropped from the admin member list. This
  # surfaced as e2e admin/member_management.feature AC2/AC4: a freshly added member
  # never appeared, so the member row (and its Remove control) never rendered.
  #
  # Fix: LEFT JOIN users — the member is returned with nil display_name_*.
  #
  # INTEGRATION test — requires a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo
  # started). Excluded from the unit run; runs via make test-integration / on the
  # redeployed stack.
  #
  # ATDD: RED against the previous INNER JOIN (member with no users row → 0 rows
  # returned), GREEN after the LEFT JOIN change.

  @moduletag :integration

  alias Nebu.Admin.DB

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    room_id = "!#{@run_id}_members:test.local"
    # A member with NO corresponding `users` row — the regression case.
    unprovisioned_user = "@#{@run_id}_ghost:test.local"
    now_ms = System.system_time(:millisecond)

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO rooms (room_id, visibility, created_at, status)
      VALUES ($1, 'private', $2, 'active')
      ON CONFLICT (room_id) DO NOTHING
      """,
      [room_id, now_ms]
    )

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO room_members (room_id, user_id, joined_at, left_at)
      VALUES ($1, $2, $3, NULL)
      ON CONFLICT (room_id, user_id) DO UPDATE SET left_at = NULL, joined_at = $3
      """,
      [room_id, unprovisioned_user, now_ms]
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM room_members WHERE room_id = $1", [room_id])
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [room_id])
    end)

    {:ok, room_id: room_id, unprovisioned_user: unprovisioned_user}
  end

  test "list_room_members returns a member that has no users row (LEFT JOIN)", %{
    room_id: room_id,
    unprovisioned_user: ghost
  } do
    assert {:ok, rows} = DB.list_room_members(room_id)

    member = Enum.find(rows, &(&1.user_id == ghost))

    assert member,
           "expected the unprovisioned member #{ghost} to appear in the admin member list " <>
             "(INNER JOIN dropped members without a users row — must be LEFT JOIN)"

    # No users row → display name fields are nil; decrypt_display_name/1 maps these to "".
    assert member.display_name_encrypted == nil
    assert member.display_name_nonce == nil
  end
end
