defmodule Nebu.Admin.ListRoomMembersWithoutPiiTest do
  use ExUnit.Case, async: false

  # ─── Bug regression (merge room-management-elixir → full-elixir-stack) ───────
  #
  # Nebu.Admin.DB.list_room_members/1 used an INNER JOIN to `users`, so any room
  # member whose `users` row carried no PII display name (e.g. an admin-added user
  # provisioned before their first OIDC login, so display_name_encrypted/_nonce are
  # still NULL) was at risk of being dropped from the admin member list. This
  # surfaced as e2e admin/member_management.feature AC2/AC4: a freshly added member
  # never appeared, so the member row (and its Remove control) never rendered.
  #
  # Fix: LEFT JOIN users — the member is returned with nil display_name_*.
  #
  # NOTE on the original premise: this test used to seed a room_member with NO
  # `users` row at all. That is now impossible — room_members.user_id FKs to
  # users.user_id (room_members_user_id_fkey, the CORRECT constraint). The
  # equivalent, FK-respecting regression case is a PROVISIONED user WITHOUT a PII
  # display name (display_name_encrypted/_nonce NULL): the LEFT JOIN must still
  # return the member with nil display-name fields.
  #
  # INTEGRATION test — requires a live PostgreSQL (NEBU_DB_URL set, Nebu.Repo
  # started). Excluded from the unit run; runs via make test-integration / on the
  # redeployed stack.
  #
  # ATDD: RED against the previous INNER JOIN, GREEN after the LEFT JOIN change.

  @moduletag :integration

  alias Nebu.Admin.DB

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
    end

    room_id = "!#{@run_id}_members:test.local"
    # A provisioned user WITHOUT a PII display name (display_name_* NULL) — the
    # FK-respecting equivalent of the original "no PII" regression case.
    no_pii_user = "@#{@run_id}_nopii:test.local"
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

    # Seed the users row with NO PII (display_name_encrypted/_nonce left NULL).
    # Only user_id + created_at are NOT NULL.
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO users (user_id, created_at) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING",
      [no_pii_user, now_ms]
    )

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO room_members (room_id, user_id, joined_at, left_at)
      VALUES ($1, $2, $3, NULL)
      ON CONFLICT (room_id, user_id) DO UPDATE SET left_at = NULL, joined_at = $3
      """,
      [room_id, no_pii_user, now_ms]
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM room_members WHERE room_id = $1", [room_id])
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM rooms WHERE room_id = $1", [room_id])
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [no_pii_user])
    end)

    {:ok, room_id: room_id, no_pii_user: no_pii_user}
  end

  test "list_room_members returns a provisioned member with no PII display name (LEFT JOIN)", %{
    room_id: room_id,
    no_pii_user: user
  } do
    assert {:ok, rows} = DB.list_room_members(room_id)

    member = Enum.find(rows, &(&1.user_id == user))

    assert member,
           "expected the no-PII member #{user} to appear in the admin member list " <>
             "(INNER JOIN risked dropping members without PII — must be LEFT JOIN)"

    # No PII display name → display name fields are nil; decrypt_display_name/1 maps these to "".
    assert member.display_name_encrypted == nil
    assert member.display_name_nonce == nil
  end
end
