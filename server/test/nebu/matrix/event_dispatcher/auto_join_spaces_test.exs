defmodule Nebu.Matrix.EventDispatcher.AutoJoinSpacesTest do
  use ExUnit.Case, async: false

  # ─── Spaces S5 (AC6): ensure_auto_join_space_memberships/1 unit tests ────────
  #
  # ATDD — written FIRST (RED before implementation).
  # FAIL until:
  #   1. ensure_auto_join_space_memberships/1 exists in EventDispatcher.Server
  #   2. messages_db_module gains list_auto_join_spaces/0
  #   3. validate_token/2 calls ensure_auto_join_space_memberships/1 for new users
  #
  # async: false — Application.put_env/3 is process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @charlie_user_id "@charlie:nebu.local"

  defmodule FakeTokenValidator do
    def validate(_user_id, _system_role, _display_name, _email) do
      {:ok,
       %{
         user_id: "@charlie:nebu.local",
         system_role: "user",
         display_name: "Charlie",
         is_active: true,
         is_new: true
       }}
    end
  end

  defmodule FakeProfileDB do
    def upsert_profile(_user_id, _display_name, _avatar_url), do: :ok
  end

  # list_auto_join_spaces returns one space; insert_member notifies the listener so
  # we can prove the space (not just rooms) was processed. Used as the messages_db_module.
  defmodule FakeMessagesDB_SpaceJoin do
    def list_auto_join_rooms(), do: {:ok, []}
    def list_auto_join_spaces(), do: {:ok, ["!engineering:nebu.local"]}

    def get_personal_room_id(_user_id), do: {:ok, "!charlie_self:nebu.local"}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # Full DBBehaviour fake the started Room GenServer uses (:room_manager, :db_module).
  # insert_member notifies the listener — proving the auto-join SPACE was joined via the
  # real Room.Server path. Mirrors AutoJoinRoomsTest.FakeRoomDB_AutoJoinTracked.
  defmodule FakeRoomDB_SpaceJoinTracked do
    @behaviour Nebu.Matrix.Room.DBBehaviour

    def get_room_status(_room_id), do: {:ok, "active"}
    def load_members(_room_id), do: {:error, :not_found}
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def load_room_settings(_room_id), do: {:error, :not_found}
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def delete_member(_room_id, _user_id), do: :ok

    def insert_member(_room_id, _user_id) do
      send(:auto_join_spaces_listener, {:insert_member_called})
      :ok
    end

    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _last_event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: true
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def get_room_heroes(_room_id, _exclude_user_id), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
    def list_auto_join_rooms(), do: {:ok, []}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  # list_auto_join_spaces fails — must be non-fatal.
  defmodule FakeMessagesDB_SpacesFail do
    def list_auto_join_rooms(), do: {:ok, []}
    def list_auto_join_spaces(), do: {:error, :db_down}

    def get_personal_room_id(_user_id), do: {:ok, "!charlie_self:nebu.local"}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  defmodule FakeMessagesDB_NoSpaces do
    def list_auto_join_rooms(), do: {:ok, []}
    def list_auto_join_spaces(), do: {:ok, []}
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  defp fake_stream(user_id), do: %{http_request_headers: %{"x-user-id" => user_id}}
  defp make_validate_token_request, do: %Core.ValidateTokenRequest{display_name: "Charlie", email: "c@e.com"}

  setup do
    Application.put_env(:event_dispatcher, :profile_db_module, FakeProfileDB)
    Application.put_env(:event_dispatcher, :token_validator_module, FakeTokenValidator)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_NoSpaces)

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :profile_db_module)
      Application.delete_env(:event_dispatcher, :token_validator_module)
    end)

    Process.register(self(), :auto_join_spaces_listener)

    on_exit(fn ->
      if Process.whereis(:auto_join_spaces_listener) == self() do
        Process.unregister(:auto_join_spaces_listener)
      end
    end)

    :ok
  end

  test "ensure_auto_join_space_memberships returns :ok when no auto-join spaces exist" do
    assert Server.ensure_auto_join_space_memberships(@charlie_user_id) == :ok
  end

  test "ensure_auto_join_space_memberships is non-fatal when list_auto_join_spaces fails (AC6)" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_SpacesFail)
    assert Server.ensure_auto_join_space_memberships(@charlie_user_id) == :ok
  end

  test "ensure_auto_join_space_memberships is non-fatal when room join fails with :noproc (AC6)" do
    # Room.Server not started in unit tests → join exits with :noproc, must be caught.
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_SpaceJoin)
    assert Server.ensure_auto_join_space_memberships(@charlie_user_id) == :ok
  end

  test "validate_token triggers ensure_auto_join_space_memberships for a new user (AC6)" do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_SpaceJoin)
    Application.put_env(:room_manager, :db_module, FakeRoomDB_SpaceJoinTracked)
    on_exit(fn -> Application.delete_env(:room_manager, :db_module) end)

    resp = Server.validate_token(make_validate_token_request(), fake_stream(@charlie_user_id))
    assert %Core.ValidateTokenResponse{} = resp

    Process.sleep(300)
    assert_received {:insert_member_called},
      "validate_token must trigger ensure_auto_join_space_memberships for the new user"
  end
end
