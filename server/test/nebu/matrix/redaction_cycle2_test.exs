defmodule Nebu.Matrix.RedactionCycle2UpgradeTest do
  @moduledoc """
  Story state-writer-redaction, security cycle 2 (dev additions, review INFO 6): every DEFINITE refusal of the upgrade tombstone write
  (`:write_failed`, `:event_too_large`, `:unsupported_db_module`, answered by the room-process writer) still cleans up the started new
  room (row and process); only `:room_unavailable` keeps it (pinned by `state_writer_http_test.exs`, AC10 (d')). Real database, through
  `Nebu.Web.Router`; the registry seam delegates everything to `Nebu.Matrix.Room.Server` except the tombstone write.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport
  import Nebu.Matrix.RedactionTestSupport

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 120_000

  defmodule RefusingTombstoneWriter do
    @moduledoc false
    alias Nebu.Matrix.Room.Server

    for {name, arity} <- Server.__info__(:functions), name not in [:write_state, :child_spec] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Server, unquote(name), unquote(args))
    end

    # the tombstone write answers the configured refusal; every other state write is the real one
    def write_state(room, sender, slot, content, opts) do
      if Keyword.get(opts, :mode) == :tombstone,
        do: {:error, Application.fetch_env!(:nebu, :cycle2_tombstone_refusal)},
        else: Server.write_state(room, sender, slot, content, opts)
    end
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    on_exit(fn ->
      T.restore_rate_limits()
      Application.delete_env(:nebu, :cycle2_tombstone_refusal)
    end)

    {:ok, a: user!("C2A")}
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  for {refusal, status} <- [write_failed: 500, event_too_large: 413, unsupported_db_module: 500] do
    @refusal refusal
    @status status
    test "a tombstone write refused with :#{refusal} answers #{status} and cleans up the new room (row and process); the old room stays active", %{a: a} do
      room = public_room(a)
      install_env!(:event_dispatcher, :room_registry_module, RefusingTombstoneWriter)
      Application.put_env(:nebu, :cycle2_tombstone_refusal, @refusal)
      before = {room_count(), running_rooms()}

      conn = upgrade(a, room)

      assert conn.status == @status, "#{conn.status} #{conn.resp_body}"
      assert {room_count(), running_rooms()} == before, "the new room's row and process were cleaned up"
      assert room_status(room) == "active", "the old room was not frozen"
      assert slot_events(room, "m.room.tombstone") == [], "nothing was tombstoned"
    end
  end
end

defmodule Nebu.Matrix.RedactionCycle2UnitTest do
  @moduledoc """
  Story state-writer-redaction, security cycle 2 (dev addition, AC18 (h), D15 (b)): the stopped-room path of the generic PUT state
  reads the room state ONCE (`ensure_room_without_lazy_create!/2` hands its fetched state back as the request's snapshot). Unit: a
  counting registry fake and a rooms db fake that knows the room; no database.
  """
  use ExUnit.Case, async: false

  @sender "@alice:test.local"

  defmodule CountingRegistry do
    @moduledoc false
    def get_state(room_id) do
      :counters.add(Application.fetch_env!(:nebu, :cycle2_get_state_count), 1, 1)
      %{room_id: room_id, members: MapSet.new(["@alice:test.local"]), power_levels: %{"users" => %{"@alice:test.local" => 100}}}
    end

    def write_state(_room_id, _sender, {"m.room.topic", ""}, %{"topic" => "once"}, mode: :client), do: {:ok, "$cycle2-written"}
  end

  defmodule KnownRoomDB do
    @moduledoc false
    def get_room_status(_room_id), do: {:ok, "active"}
  end

  setup do
    keys = [{:event_dispatcher, :room_registry_module}, {:event_dispatcher, :rooms_db_module}]
    prior = for {app, key} <- keys, do: {app, key, Application.fetch_env(app, key)}
    Application.put_env(:event_dispatcher, :room_registry_module, CountingRegistry)
    Application.put_env(:event_dispatcher, :rooms_db_module, KnownRoomDB)
    Application.put_env(:nebu, :cycle2_get_state_count, :counters.new(1, []))

    on_exit(fn ->
      Application.delete_env(:nebu, :cycle2_get_state_count)

      for {app, key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(app, key, v)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    :ok
  end

  test "a known room whose process is not running: one get_state/1 for the start and the snapshot, then the write" do
    room_id = "!cycle2" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ":test.local"
    assert {:error, :not_found} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id)

    req = %Core.SetRoomStateRequest{room_id: room_id, sender_id: @sender, event_type: "m.room.topic", state_key: "", content_json: ~s({"topic":"once"})}

    assert %Core.SetRoomStateResponse{event_id: "$cycle2-written"} = Nebu.Matrix.EventDispatcher.Server.set_room_state(req, nil)
    assert :counters.get(Application.fetch_env!(:nebu, :cycle2_get_state_count), 1) == 1, "the stopped-room path reads the state once"
  end
end
