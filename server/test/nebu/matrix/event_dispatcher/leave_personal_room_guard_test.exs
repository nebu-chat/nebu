defmodule Nebu.Matrix.EventDispatcher.LeavePersonalRoomGuardTest do
  use ExUnit.Case, async: false

  # ─── Story rm5-personal-guards-optout — AC1 ─────────────────────────────────
  #
  # ATDD — written FIRST (before the leave-guard implementation).
  #
  # AC1: leave_room/2 for a room_id equal to the requesting user's
  #      personal_room_id raises Nebu.Matrix.Error permission_denied (→ HTTP 403
  #      M_FORBIDDEN), message mentions "personal room", and membership is
  #      UNCHANGED (delete_member is never called).
  #
  # The guard must run BEFORE any DB mutation. We assert that by recording every
  # delete_member/2 call in ETS and proving the table stays empty after the raise.
  #
  # async: false — Application.put_env/3 is process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @user_id "@alice:nebu.local"
  @personal_room_id "!alice_self:nebu.local"
  @normal_room_id "!general:nebu.local"

  # ─── Fake rooms DB: records delete_member calls; reports auto-join=false ─────
  defmodule FakeRoomsDB do
    def delete_member(room_id, user_id) do
      :ets.insert(:leave_guard_test, {{:deleted, room_id, user_id}, true})
      :ok
    end

    def auto_join_room?(_room_id), do: {:ok, false}
    def insert_auto_join_opt_out(_room_id, _user_id, _ts), do: :ok
    def opted_out?(_room_id, _user_id), do: {:ok, false}

    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
  end

  # ─── Fake messages DB: get_personal_room_id is the guard input ──────────────
  # NOTE: nested modules do NOT inherit the outer module's @attributes, so the
  # user id / personal room id are inlined here as literals (must stay in sync
  # with @user_id / @personal_room_id above).
  defmodule FakeMessagesDB do
    def get_personal_room_id("@alice:nebu.local"), do: {:ok, "!alice_self:nebu.local"}
    def get_personal_room_id(_), do: {:ok, nil}
    def insert_event(_event), do: :ok
  end

  defmodule FakeInviteDB do
    def reject_invitation(_room_id, _user_id), do: :ok
  end

  setup do
    if :ets.info(:leave_guard_test) != :undefined, do: :ets.delete(:leave_guard_test)
    :ets.new(:leave_guard_test, [:named_table, :public, :set])

    Application.put_env(:event_dispatcher, :rooms_db_module, FakeRoomsDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :invite_db_module)
      if :ets.info(:leave_guard_test) != :undefined, do: :ets.delete(:leave_guard_test)
    end)

    :ok
  end

  defp leave_req(room_id, user_id),
    do: %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}

  test "AC1: leaving own personal room raises permission_denied" do
    err =
      assert_raise Nebu.Matrix.Error, fn ->
        Server.leave_room(leave_req(@personal_room_id, @user_id), %{http_request_headers: %{}})
      end

    assert err.status == Nebu.Matrix.Status.permission_denied()
    assert err.message =~ "personal room"
  end

  test "AC1: membership is unchanged when the personal-room leave is rejected" do
    assert_raise Nebu.Matrix.Error, fn ->
      Server.leave_room(leave_req(@personal_room_id, @user_id), %{http_request_headers: %{}})
    end

    # delete_member must NEVER have been called — the guard fires before any mutation.
    assert :ets.lookup(:leave_guard_test, {:deleted, @personal_room_id, @user_id}) == []
  end

  test "AC6: leaving a different (non-personal) room is NOT blocked by the guard" do
    # Room GenServer is not running → leave_room takes the {:error, :not_found}
    # fallback path, which DOES call delete_member. The personal-room guard must
    # not interfere because @normal_room_id != the user's personal_room_id.
    resp = Server.leave_room(leave_req(@normal_room_id, @user_id), %{http_request_headers: %{}})
    assert %Core.LeaveRoomResponse{room_id: @normal_room_id} = resp
    assert :ets.lookup(:leave_guard_test, {:deleted, @normal_room_id, @user_id}) != []
  end
end
