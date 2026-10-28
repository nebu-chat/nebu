defmodule Nebu.Matrix.SyncWakeupsClusterSupport do
  @moduledoc false
  # The fixtures of the two test modules below (one file: the support module must exist when only this file is loaded, e.g. `mix test <this file>`).
  # The repo's shared-support pattern (`*_test_support.exs`, `Code.require_file` in test_helper.exs) needs an entry in `test_ignore_filters` of mix.exs,
  # which is outside server/test: the fake database is kept here, in the same shape as create_room_test.exs / leave_room_test.exs /
  # moderation_fix_cycle1_unit_test.exs, instead of a new support file.
  import ExUnit.Assertions

  @table :sync_wakeups_cluster_db

  defmodule FakeDB do
    @moduledoc false
    @table :sync_wakeups_cluster_db

    def load_members(room_id) do
      case :ets.lookup(@table, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(@table, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(@table, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(@table, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(@table, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(@table, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(@table, {{:event, event["event_id"]}, event})
      :ok
    end

    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(@table, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def update_room_name(_room_id, _name), do: :ok
    def update_room_type(_room_id, _room_type), do: :ok
    def load_room_settings(_room_id), do: {:ok, 0}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    # `{:archived, room}` archives the room: its process cannot start, the decline of a pending invitation is written out of process (site 8)
    def get_room_status(room_id), do: if(:ets.lookup(@table, {:archived, room_id}) != [], do: {:ok, "archived"}, else: {:ok, "active"})

    # `{:latest, room, user}`: the latest member event of the user (the decline reads the pending invitation through it)
    def latest_member_event(room_id, user_id) do
      case :ets.lookup(@table, {:latest, room_id, user_id}) do
        [{_, latest}] -> {:ok, latest}
        [] -> {:ok, nil}
      end
    end

    def get_member_membership(room_id, user_id) do
      with {:ok, latest} <- latest_member_event(room_id, user_id), do: {:ok, latest && latest.membership}
    end

    def apply_member_change(room_id, user_id, event, opts) do
      if Keyword.get(opts, :remove_member, false), do: delete_member(room_id, user_id)
      if is_map(event), do: insert_event(event)
      :ok
    end

    # the join decision reads the join rule state (Room.DB shape: `content_json` is the jsonb as text); seeded with `seed_join_rule/2`
    def get_generic_state_events(room_id) do
      case :ets.lookup(@table, {:state_read, room_id}) do
        [{_, events}] -> {:ok, events}
        [] -> {:ok, []}
      end
    end

    # the personal room: none yet; the claim is recorded (the test waits for it: ensure_personal_room/1 runs in a Task)
    def get_personal_room_id(_user_id), do: {:ok, nil}

    def set_personal_room_id(user_id, room_id) do
      :ets.insert(@table, {{:personal_set, user_id}, room_id})
      :ok
    end

    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: false
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}
  end

  defmodule FakeInviteDB do
    @moduledoc false
    @table :sync_wakeups_cluster_db

    def get_pending_invite_rooms_for_user(user_id), do: {:ok, :ets.match(@table, {{:pending, :"$1", user_id}, true}) |> List.flatten()}

    def reject_invitation(room_id, user_id) do
      :ets.insert(@table, {{:rejected, room_id, user_id}, true})
      :ok
    end

    def insert_invitation(_room_id, _inviter_id, _invitee_id), do: :ok
    def accept_invitation(_room_id, _invitee_id), do: :ok
    def get_declined_invite_rooms_for_user(_user_id), do: {:ok, []}
  end

  defmodule NoOpAuditWriter do
    @moduledoc false
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  @doc "ETS table, injected seams, cleared :NebuTxnDedup; everything is undone by on_exit callbacks of the calling test."
  def install do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])

    for {app, key, value} <- [
          {:room_manager, :db_module, FakeDB},
          {:event_dispatcher, :rooms_db_module, FakeDB},
          {:event_dispatcher, :messages_db_module, FakeDB},
          {:event_dispatcher, :invite_db_module, FakeInviteDB},
          {:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore},
          {:event_dispatcher, :server_name, "test.local"},
          {:compliance, :audit_writer, NoOpAuditWriter}
        ] do
      prior = Application.fetch_env(app, key)
      Application.put_env(app, key, value)

      ExUnit.Callbacks.on_exit(fn ->
        case prior do
          {:ok, old} -> Application.put_env(app, key, old)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    # :NebuTxnDedup is created at application boot and cannot be recreated: clear it between tests
    if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)

    ExUnit.Callbacks.on_exit(fn ->
      if :ets.info(@table) != :undefined, do: :ets.delete(@table)
      if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)
    end)

    :ok
  end

  def unique(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"
  def user, do: "@#{unique("u")}:test.local"
  def stream, do: %{http_request_headers: %{}}

  @doc "Polls `fun` (10 ms steps, at most `timeout` ms): the Horde registry and the :pg scope sync are asynchronous."
  def wait_until(fun, timeout \\ 2_000), do: do_wait(fun, System.monotonic_time(:millisecond) + timeout)

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  @doc "Stops a room process by monitor: `GenServer.stop/3` on the pid returned at start (never a late registry lookup), waits for its DOWN."
  def track_room(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :ok
      end
    end)
  end

  @doc "A running room process (Horde) whose members are already in the fake database; returns `room_id`."
  def start_room(members) do
    room_id = "!#{unique("wake")}:test.local"
    {:ok, _created_at} = FakeDB.insert_room(room_id)
    for member <- members, do: :ok = FakeDB.insert_member(room_id, member)

    {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
    assert wait_until(fn -> match?({:ok, _}, Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id)) end) == :ok, "the room process is registered"
    track_room(pid)
    room_id
  end

  @doc "A room created through create_room/2 is tracked right after the call (the pid is read once, not at teardown)."
  def track_created(room_id) do
    {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id)
    track_room(pid)
  end

  @doc "A LOCAL subscriber: the test process in the group, the way a sync task of the same node subscribes."
  def subscribe_local(group) do
    pid = self()
    :ok = :pg.join(group, pid)
    ExUnit.Callbacks.on_exit(fn -> :pg.leave(group, pid) end)
  end

  @doc "The join rule of a room, in the shape of Room.DB.get_generic_state_events/1."
  def seed_join_rule(room_id, rule) do
    event = %{type: "m.room.join_rules", state_key: "", content_json: Jason.encode!(%{"join_rule" => rule}), sender: "@creator:test.local", event_id: "$jr:test.local", origin_server_ts: 1}
    :ets.insert(@table, {{:state_read, room_id}, [event]})
  end

  @doc "The fixture of an archived-room decline (moderation_fix_cycle1_unit_test.exs, review M1): a pending invitation to a room whose process cannot start."
  def seed_archived_invitation(room_id, invitee) do
    :ets.insert(@table, {{:room, room_id}, 0})
    :ets.insert(@table, {{:pending, room_id, invitee}, true})
    :ets.insert(@table, {{:latest, room_id, invitee}, %{membership: "invite", origin_server_ts: 1_000, sender: "@x:test.local", event_id: "$inv"}})
    :ets.insert(@table, {{:archived, room_id}, true})
  end

  def stored_event_types, do: :ets.match(@table, {{:event, :_}, :"$1"}) |> Enum.map(fn [event] -> event["type"] end)
  def personal_claimed?(user_id), do: :ets.lookup(@table, {:personal_set, user_id}) != []
end

defmodule Nebu.Matrix.SyncWakeupsClusterTest do
  @moduledoc """
  Story `sync-wakeups-cluster-wide` (follow-up `fe`), Scenarios 2 and 4, the DEFAULT-suite half (one node, no distribution, no database).

  ## D2 (c): the dynamic trace proof (with the AST guard of `sync_wakeups_cluster_unit_test.exs` the gate for all 9 sites without distribution)

  `:erlang.trace_pattern({:pg, :get_local_members, 1}, true, [:local])` plus `:erlang.trace(:all, true, [:call, {:tracer, test_process}])`: every call of
  `:pg.get_local_members/1` of ANY process (the Horde-started room processes and the spawned Task of the personal room included) arrives in the
  test process as a trace message. While the writers run, no call for a `user:` / `room:` group may happen. `:all` is the robust variant: no race
  between a process starting and the trace flag being set (`set_on_spawn` would miss Horde children started before the flag, and the pids of
  Horde-started processes are not known beforehand). The trace pattern matches the one function only, so the cost is nil. The flush uses
  `:erlang.trace_delivered/1` (no `sleep`). Positive control: a traced Task and the test process itself call `:pg.get_local_members/1` and the trace sees both.

  Sites driven (premise-check numbering): 1 `Room.Server.join/leave` (`emit_membership_event/4`), 2 `Room.Server.send_event/6`, 3 + 4 + 9 `create_room/2`
  with a name and a topic (create event, creator wake, `emit_state_event_at/6`), 5 `join_room/2`, 6 `leave_room/2`, 7 `run_post_login_provisioning/2`
  (`ensure_personal_room/1` -> `create_personal_room/2`), 8 the archived-room decline (`emit_decline_event/2`, the fixture of
  `moderation_fix_cycle1_unit_test.exs`). Every drive also asserts its observable effect, so a drive that did nothing cannot pass.

  ## Scenario 4: local delivery is unchanged

  A subscriber on the SAME node still receives each wake-up exactly once. Cases with no existing black-box assertion: `leave_room/2`,
  `Room.Server.join/2`, `send_event` (the existing assertions sit behind HTTP fixtures), the creator wake of `create_room/2` and the decline of site 8.
  The `{:new_join}` of `join_room/2` is asserted by the trace drive above and by `join_room_test.exs`.

  ## Which sites a black-box subscriber can observe (the cluster half, `Nebu.Matrix.SyncWakeupsClusterPeerTest` below)

  Sites 1, 2, 4, 5, 6, 8 write to a group whose id the test knows before the call (`user:<id>` of the actor, `room:<id>` of an existing room). Sites 3, 7
  and 9 write to `room:<id>` of a room whose id is generated INSIDE the call (`create_room/2`, the personal room): no sync task can be subscribed to it
  beforehand, so only the guard and the trace see them.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Room.Server, as: RoomServer
  alias Nebu.Matrix.SyncWakeupsClusterSupport, as: S

  setup do
    S.install()
  end

  # ─── the trace helper ──────────────────────────────────────────────────────────────────────────────────────────────────────

  # runs `fun` with call tracing of :pg.get_local_members/1 on EVERY process; returns `{result_of_fun, [{pid, group}]}`, the calls in order
  # The tracer is a SEPARATE process: a process that is its own tracer is not traced, and the dispatcher functions (`leave_room/2`, `create_room/2`, ...)
  # run in the test process itself.
  defp traced(fun) do
    tracer = spawn_link(__MODULE__, :collect_calls, [[]])
    :erlang.trace_pattern({:pg, :get_local_members, 1}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(:all, false, [:call])
        :erlang.trace_pattern({:pg, :get_local_members, 1}, false, [:local])
      end

    # every trace message has reached the tracer when this message arrives; the request below is sent after it
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> flunk("the trace messages were not delivered")
    end

    send(tracer, {:collect, self()})

    calls =
      receive do
        {:calls, ^tracer, calls} -> calls
      after
        5_000 -> flunk("the tracer did not answer")
      end

    {result, calls}
  end

  @doc false
  def collect_calls(acc) do
    receive do
      {:trace, pid, :call, {:pg, :get_local_members, [group]}} -> collect_calls([{pid, group} | acc])
      {:collect, from} -> send(from, {:calls, self(), Enum.reverse(acc)})
    end
  end

  # the groups the sync wake-ups use
  defp wake_calls(calls), do: for({pid, group} <- calls, is_binary(group) and String.starts_with?(group, ["user:", "room:"]), do: {pid, group})

  defp assert_no_node_local_wake(calls) do
    assert wake_calls(calls) == [], "a wake-up sender called :pg.get_local_members/1 (use :pg.get_members/1): #{inspect(wake_calls(calls))}"
  end

  # ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  # D2 (c): dynamic trace proof
  # ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D2 (c) - trace proof: no :pg.get_local_members/1" do
    test "positive control: the trace sees the call of a spawned process and of the test process" do
      group = "room:#{S.unique("control")}"

      {_result, calls} =
        traced(fn ->
          assert [] = Task.async(fn -> :pg.get_local_members(group) end) |> Task.await()
          assert [] = :pg.get_local_members(group)
        end)

      assert length(wake_calls(calls)) == 2, "the trace sees the Task and the test process: #{inspect(calls)}"
      assert calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 2, "two different processes"
    end

    test "sites 1, 2: Room.Server join, send_event and leave (emit_membership_event/4, the /send path) never call it" do
      alice = S.user()
      bob = S.user()
      room_id = S.start_room([alice])
      S.subscribe_local("room:#{room_id}")

      {_result, calls} =
        traced(fn ->
          assert :ok = RoomServer.join(room_id, bob)
          assert {:ok, _event_id} = RoomServer.send_event(room_id, alice, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"}, S.unique("txn"))
          assert :ok = RoomServer.leave(room_id, bob)
        end)

      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^bob, "content" => %{"membership" => "join"}}}, 2_000
      assert_receive {:new_event, %{"type" => "m.room.message"}}, 2_000
      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^bob, "content" => %{"membership" => "leave"}}}, 2_000
      assert_no_node_local_wake(calls)
    end

    test "sites 3, 4, 9: create_room with a name and a topic (create event, creator wake, state events) never calls it" do
      alice = S.user()
      S.subscribe_local("user:#{alice}")

      {response, calls} = traced(fn -> Server.create_room(%Core.CreateRoomRequest{creator_id: alice, name: "a name", topic: "a topic"}, S.stream()) end)

      S.track_created(response.room_id)
      room_id = response.room_id

      assert_receive {:new_join, ^room_id}, 2_000
      types = S.stored_event_types()
      for type <- ["m.room.create", "m.room.name", "m.room.topic"], do: assert(type in types, "the drive wrote #{type} (stored: #{inspect(types)})")
      assert_no_node_local_wake(calls)
    end

    test "site 5: join_room (do_join_room) never calls it" do
      alice = S.user()
      room_id = S.start_room([])
      S.seed_join_rule(room_id, "public")
      S.subscribe_local("user:#{alice}")

      {response, calls} = traced(fn -> Server.join_room(%Core.JoinRoomRequest{user_id: alice, room_id_or_alias: room_id}, S.stream()) end)

      assert %Core.JoinRoomResponse{room_id: ^room_id} = response
      assert_receive {:new_join, ^room_id}, 2_000
      assert_no_node_local_wake(calls)
    end

    test "sites 6, 1: leave_room (a running room process) never calls it" do
      alice = S.user()
      room_id = S.start_room([alice])
      S.subscribe_local("user:#{alice}")

      {response, calls} = traced(fn -> Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: alice}, S.stream()) end)

      assert %Core.LeaveRoomResponse{room_id: ^room_id} = response
      assert_receive {:new_leave, ^room_id}, 2_000
      assert_no_node_local_wake(calls)
    end

    test "site 7: the personal room (run_post_login_provisioning -> ensure_personal_room -> create_personal_room, in a Task) never calls it" do
      alice = S.user()

      {claimed, calls} =
        traced(fn ->
          assert :ok = Server.run_post_login_provisioning(alice, false)
          # the Task ends with the claim of the personal room: every event of create_personal_room/2 was written before it
          S.wait_until(fn -> S.personal_claimed?(alice) end, 5_000)
        end)

      assert claimed == :ok, "the personal room was created"
      assert "m.room.create" in S.stored_event_types()
      assert_no_node_local_wake(calls)
    end

    test "site 8: the decline of an invitation to an archived room (emit_decline_event/2) never calls it" do
      invitee = S.user()
      room_id = "!#{S.unique("arch")}:test.local"
      S.seed_archived_invitation(room_id, invitee)
      S.subscribe_local("room:#{room_id}")

      {result, calls} =
        traced(fn ->
          Nebu.Matrix.Http.call_core(fn -> Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: invitee}, S.stream()) end)
        end)

      assert {:ok, %Core.LeaveRoomResponse{}} = result
      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^invitee, "content" => %{"membership" => "leave"}}}, 2_000
      assert_no_node_local_wake(calls)
    end
  end

  # ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  # Scenario 4: local delivery is unchanged (one node)
  # ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 4 - same-node wake-up, once, as before" do
    test "leave_room/2 wakes the user:<id> subscriber ({:new_leave}) and the room:<id> subscriber (leave member event), once each" do
      alice = S.user()
      room_id = S.start_room([alice])
      S.subscribe_local("user:#{alice}")
      S.subscribe_local("room:#{room_id}")

      assert %Core.LeaveRoomResponse{room_id: ^room_id} = Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: alice}, S.stream())

      assert_receive {:new_leave, ^room_id}, 2_000
      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^alice, "content" => %{"membership" => "leave"}}}, 2_000
      refute_receive {:new_leave, _}, 100
      refute_receive {:new_event, _}, 50
    end

    test "Room.Server.join/2 wakes the room:<id> subscriber with the join member event, once (emit_membership_event/4)" do
      alice = S.user()
      room_id = S.start_room([])
      S.subscribe_local("room:#{room_id}")

      assert :ok = RoomServer.join(room_id, alice)

      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^alice, "content" => %{"membership" => "join"}}}, 2_000
      refute_receive {:new_event, _}, 100
    end

    test "Room.Server.send_event/6 wakes the room:<id> subscriber with the signed message, once (the /send path)" do
      alice = S.user()
      room_id = S.start_room([alice])
      S.subscribe_local("room:#{room_id}")

      assert {:ok, event_id} = RoomServer.send_event(room_id, alice, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"}, S.unique("txn"))

      assert_receive {:new_event, %{"event_id" => ^event_id, "type" => "m.room.message"}}, 2_000
      refute_receive {:new_event, _}, 100
    end

    test "create_room/2 wakes the creator's user:<id> subscriber with {:new_join, new_room}, once" do
      alice = S.user()
      S.subscribe_local("user:#{alice}")

      response = Server.create_room(%Core.CreateRoomRequest{creator_id: alice, name: "wake"}, S.stream())
      S.track_created(response.room_id)

      room_id = response.room_id
      assert_receive {:new_join, ^room_id}, 2_000
      refute_receive {:new_join, _}, 100
    end

    test "the decline of an invitation to an archived room wakes the room:<id> subscriber with the leave member event, once (emit_decline_event/2)" do
      invitee = S.user()
      room_id = "!#{S.unique("arch")}:test.local"
      S.seed_archived_invitation(room_id, invitee)
      S.subscribe_local("room:#{room_id}")

      assert {:ok, %Core.LeaveRoomResponse{}} =
               Nebu.Matrix.Http.call_core(fn -> Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: invitee}, S.stream()) end)

      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^invitee, "content" => %{"membership" => "leave"}}}, 2_000
      refute_receive {:new_event, _}, 100
    end
  end
end

defmodule Nebu.Matrix.SyncWakeupsClusterPeerTest do
  @moduledoc """
  Story `sync-wakeups-cluster-wide`, D2 (b): the OPT-IN second proof, two nodes (OTP `:peer`, no new dependency). Tag `:cluster`: excluded by
  `test_helper.exs`, NOT part of the default suite, and a MANUAL proof that CI does not run. Run it from `server/` inside a container (nothing on the host)
  with epmd and the distribution port bound to 127.0.0.1 (`ERL_EPMD_ADDRESS=127.0.0.1`):

      epmd -daemon
      elixir --name nebu_test@127.0.0.1 --cookie <random per run> --erl '-kernel inet_dist_use_interface {127,0,0,1}' \\
        -S mix test --only cluster test/nebu/matrix/sync_wakeups_cluster_test.exs

  The test node must be distributed BEFORE the application boots (a node that becomes distributed later renames `node()` under running Horde / `:pg` /
  ETS), which is why the default suite cannot run it.

  `setup_all` asserts `Node.alive?/0`: `--include cluster` on a plain node FAILS here, it never skips or passes silently.

  One peer for the module (started in `setup_all`, stopped in `on_exit`) with the cookie of the test node and its distribution port on 127.0.0.1; it runs the
  default `:pg` scope. Per test, ONE process on the peer, a forwarder, joins the group(s) and relays everything to the test process as
  `{:remote, peer_node, message}`: it plays the long-poll sync task of a user whose request landed on the other node. The writers run on the TEST node:
  `leave_room/2` (site 6 and, through `Room.Server.leave/2`, site 1), `Room.Server.send_event/6` (site 2), `Room.Server.join/2` (site 1), `create_room/2`
  (site 4), `join_room/2` (site 5) and the archived-room decline (site 8). Each test has a local control subscriber in the same group (the writer ran and
  delivered) and waits until `:pg.get_members/1` of the test node sees the remote forwarder (the scope sync is asynchronous).

  Sites 3, 7 and 9 write to `room:<id>` of a room whose id is generated inside the call: nothing can be subscribed beforehand (guard and trace only).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :cluster

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Room.Server, as: RoomServer
  alias Nebu.Matrix.SyncWakeupsClusterSupport, as: S

  # evaluated ON THE PEER (Code.eval_string/2 over :erpc: the peer needs Elixir on its code path, not this test module): everything the process receives goes
  # back to the test process as {:remote, node_of_the_forwarder, message}
  @forwarder_code """
  spawn(fn ->
    loop = fn loop ->
      receive do
        message ->
          send(parent, {:remote, node(), message})
          loop.(loop)
      end
    end

    loop.(loop)
  end)
  """

  setup_all do
    assert Node.alive?(),
           "the :cluster tests need a distributed test node that exists before the application boots: start mix as `elixir --name <node>@127.0.0.1 --cookie <random> -S mix test --only cluster` in a container (see the moduledoc); do not --include cluster on a plain node"

    name = ~c"nebu_wake_peer_#{System.unique_integer([:positive])}"
    elixir_ebin = :code.lib_dir(:elixir) ++ ~c"/ebin"
    cookie = Atom.to_charlist(Node.get_cookie())

    # loopback only: the peer's distribution port listens on 127.0.0.1 (the test node's is bound the same way by its command line)
    args = [~c"-pa", elixir_ebin, ~c"-setcookie", cookie, ~c"-kernel", ~c"inet_dist_use_interface", ~c"{127,0,0,1}"]
    {:ok, peer, peer_node} = :peer.start_link(%{name: name, host: ~c"127.0.0.1", args: args})
    on_exit(fn -> :peer.stop(peer) end)

    # the default scope on the peer: it discovers the test node's scope on start (and the other way round)
    case :erpc.call(peer_node, :pg, :start, [:pg]) do
      {:ok, _scope} -> :ok
      {:error, {:already_started, _scope}} -> :ok
    end

    %{peer: peer_node}
  end

  setup %{peer: peer} do
    S.install()

    {pid, _binding} = :erpc.call(peer, Code, :eval_string, [@forwarder_code, [parent: self()]])
    on_exit(fn -> :erpc.call(peer, :erlang, :exit, [pid, :kill]) end)

    %{fwd: pid}
  end

  test "leave_room/2 reaches a user:<id> subscriber ({:new_leave}) and a room:<id> subscriber (leave member event) on the peer", %{peer: peer, fwd: fwd} do
    alice = S.user()
    room_id = S.start_room([alice])
    S.subscribe_local("user:#{alice}")
    S.subscribe_local("room:#{room_id}")
    join_remote(peer, fwd, "user:#{alice}")
    join_remote(peer, fwd, "room:#{room_id}")

    assert %Core.LeaveRoomResponse{room_id: ^room_id} = Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: alice}, S.stream())

    # control: the writer ran and woke the local subscriber
    assert_receive {:new_leave, ^room_id}, 2_000
    assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^alice}}, 2_000

    # sites 6 (leave_room/2) and 1 (emit_membership_event/4)
    assert_receive {:remote, ^peer, {:new_leave, ^room_id}}, 2_000, "no {:new_leave} on the peer: leave_room/2 uses :pg.get_local_members/1"

    assert_receive {:remote, ^peer, {:new_event, %{"type" => "m.room.member", "state_key" => ^alice, "content" => %{"membership" => "leave"}}}}, 2_000,
                   "no leave member event on the peer: emit_membership_event/4 uses :pg.get_local_members/1"

    refute_receive {:remote, ^peer, _}, 100
  end

  test "Room.Server.send_event/6 reaches a room:<id> subscriber on the peer (the /send path)", %{peer: peer, fwd: fwd} do
    alice = S.user()
    room_id = S.start_room([alice])
    S.subscribe_local("room:#{room_id}")
    join_remote(peer, fwd, "room:#{room_id}")

    assert {:ok, event_id} = RoomServer.send_event(room_id, alice, "m.room.message", %{"msgtype" => "m.text", "body" => "hello node B"}, S.unique("txn"))

    assert_receive {:new_event, %{"event_id" => ^event_id}}, 2_000

    assert_receive {:remote, ^peer, {:new_event, %{"event_id" => ^event_id, "type" => "m.room.message"}}}, 2_000,
                   "no {:new_event} on the peer: sign_and_persist_event/6 uses :pg.get_local_members/1"

    refute_receive {:remote, ^peer, _}, 100
  end

  test "Room.Server.join/2 reaches a room:<id> subscriber on the peer (the join member event, emit_membership_event/4)", %{peer: peer, fwd: fwd} do
    alice = S.user()
    room_id = S.start_room([])
    S.subscribe_local("room:#{room_id}")
    join_remote(peer, fwd, "room:#{room_id}")

    assert :ok = RoomServer.join(room_id, alice)

    assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^alice}}, 2_000

    assert_receive {:remote, ^peer, {:new_event, %{"type" => "m.room.member", "state_key" => ^alice, "content" => %{"membership" => "join"}}}}, 2_000,
                   "no join member event on the peer: emit_membership_event/4 uses :pg.get_local_members/1"

    refute_receive {:remote, ^peer, _}, 100
  end

  test "create_room/2 reaches the creator's user:<id> subscriber on the peer with {:new_join, new_room} (site 4)", %{peer: peer, fwd: fwd} do
    alice = S.user()
    S.subscribe_local("user:#{alice}")
    join_remote(peer, fwd, "user:#{alice}")

    response = Server.create_room(%Core.CreateRoomRequest{creator_id: alice, name: "wake node B"}, S.stream())
    S.track_created(response.room_id)
    room_id = response.room_id

    assert_receive {:new_join, ^room_id}, 2_000

    assert_receive {:remote, ^peer, {:new_join, ^room_id}}, 2_000,
                   "no {:new_join} on the peer: create_room/2 wakes the creator with :pg.get_local_members/1"

    refute_receive {:remote, ^peer, _}, 100
  end

  test "join_room/2 reaches the joining user's user:<id> subscriber on the peer with {:new_join, room} (site 5)", %{peer: peer, fwd: fwd} do
    alice = S.user()
    room_id = S.start_room([])
    S.seed_join_rule(room_id, "public")
    S.subscribe_local("user:#{alice}")
    join_remote(peer, fwd, "user:#{alice}")

    assert %Core.JoinRoomResponse{room_id: ^room_id} = Server.join_room(%Core.JoinRoomRequest{user_id: alice, room_id_or_alias: room_id}, S.stream())

    assert_receive {:new_join, ^room_id}, 2_000

    assert_receive {:remote, ^peer, {:new_join, ^room_id}}, 2_000,
                   "no {:new_join} on the peer: do_join_room/3 wakes the user with :pg.get_local_members/1"

    refute_receive {:remote, ^peer, _}, 100
  end

  test "the decline of an invitation to an archived room reaches a room:<id> subscriber on the peer (site 8, emit_decline_event/2)", %{peer: peer, fwd: fwd} do
    invitee = S.user()
    room_id = "!#{S.unique("arch")}:test.local"
    S.seed_archived_invitation(room_id, invitee)
    S.subscribe_local("room:#{room_id}")
    join_remote(peer, fwd, "room:#{room_id}")

    assert {:ok, %Core.LeaveRoomResponse{}} =
             Nebu.Matrix.Http.call_core(fn -> Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: invitee}, S.stream()) end)

    assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => ^invitee}}, 2_000

    assert_receive {:remote, ^peer, {:new_event, %{"type" => "m.room.member", "state_key" => ^invitee, "content" => %{"membership" => "leave"}}}}, 2_000,
                   "no leave member event on the peer: emit_decline_event/2 uses :pg.get_local_members/1"

    refute_receive {:remote, ^peer, _}, 100
  end

  # the forwarder (a pid ON the peer) joins the group in the peer's :pg scope; then this node must SEE it (:pg.get_members/1, the cluster-wide read the
  # writers must use), while :pg.get_local_members/1 does not list it (control: the subscriber really is remote)
  defp join_remote(peer_node, forwarder, group) do
    :ok = :erpc.call(peer_node, :pg, :join, [group, forwarder])

    assert S.wait_until(fn -> forwarder in :pg.get_members(group) end) == :ok,
           "precondition: the :pg scope of #{node()} never learned that the forwarder on #{peer_node} joined #{group}"

    refute forwarder in :pg.get_local_members(group), "precondition: the forwarder is remote"
  end
end
