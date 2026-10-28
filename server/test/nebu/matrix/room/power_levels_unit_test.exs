defmodule Nebu.Matrix.Room.PowerLevelsUnitTest do
  @moduledoc """
  Story `power-levels-enforcement`, UNIT half (no PostgreSQL; the real `Room.Server` / Horde / `:pg` run on a fake db module through the existing
  `:room_manager, :db_module` seam): the pure `PowerLevels` functions (AC5 (a), AC13 unit part, the table of `check_change/3` over every S4 rule (5) - (7)),
  AC4 (d) (unit: a stale snapshot), AC6 (b) and the source pins of AC14. Everything the real SQL decides is in the real-database suites
  (`power_levels_writer_db_test.exs`, `power_levels_http_test.exs`, `power_levels_concurrency_test.exs`).

  The fake models the real transaction (lesson of the earlier stories): `apply_power_levels_change/3` sets the column AND inserts the event, records every call
  and has a failure switch; `set_power_levels/2` and `insert_event/1` are counted, so "never the two-statement path" is an assertion.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The functions of the story that do not exist yet (`PowerLevels.normalize/1`, `validate_content/1`, `check_change/3`, `required_level/2`,
      `Room.Server.change_power_levels/4`) are reached through `call/3` with a variable name: the file compiles without warnings before the dev step.
    * `check_change(current, new, sender_id)`: the story names only the arity; the pinned order is (current stored content, new content, the sender's user id)
      and the answer `:ok | {:error, :above_own_level | :grant_above_own_level | :target_not_lower}` (the atoms of D2 (5)). `validate_content/1` answers
      `:ok | {:error, text}` with a binary fixed text (the three texts of the override rule are pinned, the others are only required to be binaries).
    * `change_power_levels/4` refusals are `{:error, atom}` / `{:error, {:invalid, _}}` (D2); the SUCCESS shape is not pinned by the story: a success is
      recognised by `{:ok, event_id}` or `{:ok, event_id, _outcome}` (the id is asserted against the fake's recorded write).
    * D2 (4) (no previous levels event: allow) is not pinned here: the story says it is unreachable through the route and does not name the db read that
      decides "no event" (a fake cannot tell what a dev reads).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport, only: [kill_and_restart!: 1]
  import Nebu.Matrix.PowerLevelsTestSupport, only: [call: 3]

  alias Nebu.Matrix.Room.PowerLevels
  alias Nebu.Matrix.Room.Server

  @table :power_levels_unit_test_db
  @lib Path.expand("../../../../lib", __DIR__)
  @test_dir Path.expand("../../..", __DIR__)
  @pl "m.room.power_levels"

  # ─── the fake ────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @moduledoc false
    @table :power_levels_unit_test_db

    # the 5-tuple form with the identity map of the real db module (members: %{}, power_levels: {event_id, ts, sender} | nil)
    def load_members(room_id) do
      case :ets.lookup(@table, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(@table, {{:member, room_id, :"$1"}, :active})

          json =
            case :ets.lookup(@table, {:power_levels, room_id}) do
              [{_, stored}] -> stored
              [] -> "{}"
            end

          identity =
            case :ets.lookup(@table, {:identity, room_id}) do
              [{_, tuple}] -> tuple
              [] -> nil
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, json, %{members: %{}, power_levels: identity}}
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
      count(:insert_event)
      :ets.insert(@table, {{:event, event["event_id"]}, event})
      :ok
    end

    # the TWO-statement path: counted, it must never be used for a power-level change
    def set_power_levels(room_id, json) do
      count(:set_power_levels)
      :ets.insert(@table, {{:power_levels, room_id}, json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    # the status read of the archived check; a test switches a room to "archived" in the table
    def check_room_status_for_update(room_id) do
      case :ets.lookup(@table, {:status, room_id}) do
        [{_, status}] -> {:ok, status}
        [] -> {:ok, "active"}
      end
    end

    # what the real transaction does: the column AND the event, recorded, with a failure switch
    def apply_power_levels_change(room_id, json, event) do
      count(:apply_power_levels_change)
      :ets.insert(@table, {{:apply, make_ref()}, {room_id, json, event}})

      case :ets.lookup(@table, :apply_fail) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.insert(@table, {{:power_levels, room_id}, json})
          :ets.insert(@table, {{:event, event["event_id"]}, event})
          :ets.insert(@table, {{:identity, room_id}, {event["event_id"], event["origin_server_ts"], event["sender"]}})
          :ok
      end
    end

    defp count(name), do: :ets.update_counter(@table, {:calls, name}, 1, {{:calls, name}, 0})
  end

  # the db module of a suite that predates this story: everything but apply_power_levels_change/3
  defmodule OldDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name != :apply_power_levels_change do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), unquote(args))
    end
  end

  # ─── setup / helpers ─────────────────────────────────────────────────────────

  setup do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])

    prior_db = Application.fetch_env(:room_manager, :db_module)
    prior_server = Application.fetch_env(:event_dispatcher, :server_name)
    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      restore(:room_manager, :db_module, prior_db)
      restore(:event_dispatcher, :server_name, prior_server)
      if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    end)

    :ok
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp user(label), do: "@#{label}#{rand()}:test.local"

  defp start_room do
    room = "!plu#{rand()}:test.local"
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
          {:ok, pid} ->
            if Process.alive?(pid), do: :sys.resume(pid)
            Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

          _ ->
            :ok
        end
      end
    end)

    room
  end

  # the strictly valid content with the spec defaults (the levels event needs 50)
  defp levels(users, extra \\ %{}) do
    Map.merge(
      %{
        "ban" => 50,
        "kick" => 50,
        "invite" => 0,
        "redact" => 50,
        "state_default" => 50,
        "events_default" => 0,
        "users_default" => 0,
        "users" => users,
        "events" => %{@pl => 50}
      },
      extra
    )
  end

  # a room with `admin` at 100 and the joined `members`; `content` is seeded through the internal writer (the bootstrap branch)
  defp room_with(admin, members, content) do
    room = start_room()
    assert :ok = Server.join(room, admin)
    for m <- members, do: assert(:ok = Server.join(room, m))
    assert :ok = Server.set_power_levels(room, admin, Map.update!(content, "users", &Map.put_new(&1, admin, 100)))
    reset_calls()
    room
  end

  defp reset_calls do
    :ets.match_delete(@table, {{:calls, :_}, :_})
    :ets.match_delete(@table, {{:apply, :_}, :_})
  end

  defp calls(name), do: :ets.lookup(@table, {:calls, name}) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  defp applies(room), do: :ets.match_object(@table, {{:apply, :_}, :_}) |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(elem(&1, 0) == room))
  defp change(room, sender, content, opts \\ []), do: call(Server, :change_power_levels, [room, sender, content, Keyword.put_new(opts, :mode, :client)])

  # a success is {:ok, event_id} or {:ok, event_id, outcome} (the story pins no shape): the event id
  defp committed_id({:ok, id}) when is_binary(id), do: id
  defp committed_id({:ok, id, _outcome}) when is_binary(id), do: id

  # ═══ the pure functions: D12 defaults ══════════════════════════════════════════

  describe "AC13 (unit) - PowerLevels.default_levels/0 (D12, NON-SPEC, Synapse-derived)" do
    test "has the spec defaults and exactly the eight D12 entries in `events`" do
      defaults = PowerLevels.default_levels()

      assert defaults["events"] == %{
               "m.room.power_levels" => 100,
               "m.room.history_visibility" => 100,
               "m.room.tombstone" => 100,
               "m.room.server_acl" => 100,
               "m.room.encryption" => 100,
               "m.room.name" => 50,
               "m.room.avatar" => 50,
               "m.room.canonical_alias" => 50
             }

      assert Map.take(defaults, ~w(ban kick invite redact state_default events_default users_default users)) ==
               %{"ban" => 50, "kick" => 50, "invite" => 0, "redact" => 50, "state_default" => 50, "events_default" => 0, "users_default" => 0, "users" => %{}}
    end

    test "Room.Server.default_power_levels/0 is the same map" do
      assert Server.default_power_levels() == PowerLevels.default_levels()
    end
  end

  # ═══ AC5 (a): the normalised view ═══════════════════════════════════════════════

  describe "AC5 (a) - normalize/1 and the checks on the tolerant read" do
    @legacy %{
      "ban" => "0",
      "users" => %{"@a:s" => "100", "@b:s" => 50.0, "@c:s" => 70},
      "users_default" => "5",
      "events" => %{"m.room.name" => "0"}
    }

    test "a string threshold reads as its spec default, odd users values read as absent (users_default 0), a valid level stays, odd events values read as absent" do
      normalised = call(PowerLevels, :normalize, [@legacy])

      assert normalised["ban"] == 50
      assert normalised["users_default"] == 0
      assert call(PowerLevels, :get_user_level, [normalised, "@a:s"]) == 0
      assert call(PowerLevels, :get_user_level, [normalised, "@b:s"]) == 0
      assert call(PowerLevels, :get_user_level, [normalised, "@c:s"]) == 70
      refute Map.has_key?(normalised["events"], "m.room.name")
    end

    test "can?/3 is false for kick, ban and state for the user whose stored level is the string \"100\" (raw and normalised input)" do
      normalised = call(PowerLevels, :normalize, [@legacy])

      for levels <- [@legacy, normalised], action <- [:kick, :ban, :change_state] do
        refute PowerLevels.can?(levels, "@a:s", action), "@a with a string level passed #{action}"
      end

      assert PowerLevels.can?(@legacy, "@c:s", :kick), "a valid level 70 reaches the default kick level"
    end

    test "normalize/1 is idempotent and never leaves a non-integer level anywhere" do
      once = call(PowerLevels, :normalize, [@legacy])
      assert call(PowerLevels, :normalize, [once]) == once

      levels = [once["ban"], once["users_default"]] ++ Map.values(once["users"]) ++ Map.values(once["events"])
      assert Enum.all?(levels, &is_integer/1)
    end

    test "get_user_level/2 never returns a string (the Erlang term order made a string pass every comparison)" do
      for stored <- ["100", "0", "x", 50.0, nil, true] do
        level = call(PowerLevels, :get_user_level, [%{"users" => %{"@u:s" => stored}, "users_default" => stored}, "@u:s"])
        assert is_integer(level), "#{inspect(stored)} read as #{inspect(level)}"
      end
    end
  end

  describe "required_level/2 (D5)" do
    test "events[type] when present, else events_default for a message and state_default for a state event" do
      levels = %{"events" => %{"m.custom" => 25, "m.room.topic" => 75}, "events_default" => 10, "state_default" => 60}

      assert call(PowerLevels, :required_level, [levels, {:message, "m.custom"}]) == 25
      assert call(PowerLevels, :required_level, [levels, {:message, "m.room.message"}]) == 10
      assert call(PowerLevels, :required_level, [levels, {:state, "m.room.topic"}]) == 75
      assert call(PowerLevels, :required_level, [levels, {:state, "m.room.avatar"}]) == 60
      assert call(PowerLevels, :required_level, [%{}, {:state, "m.room.topic"}]) == 50, "the spec default"
      assert call(PowerLevels, :required_level, [%{}, {:message, "m.room.message"}]) == 0
    end

    test "a string threshold is never reached: an events value or events_default that is a string reads as absent" do
      levels = %{"events" => %{"m.custom" => "100"}, "events_default" => "100", "state_default" => "100"}
      assert call(PowerLevels, :required_level, [levels, {:message, "m.custom"}]) == 0
      assert call(PowerLevels, :required_level, [levels, {:state, "m.room.topic"}]) == 50
    end
  end

  # ═══ validate_content/1 (D3) ════════════════════════════════════════════════════

  describe "D3 - validate_content/1 (pure, one validator for every path)" do
    test "accepts the strictly valid content, an empty content, unknown top-level keys and absent users / events / notifications" do
      assert call(PowerLevels, :validate_content, [levels(%{"@a:s" => 100})]) == :ok
      assert call(PowerLevels, :validate_content, [%{}]) == :ok
      assert call(PowerLevels, :validate_content, [%{"x_custom" => %{"anything" => [1, "two"]}}]) == :ok
      assert call(PowerLevels, :validate_content, [%{"notifications" => %{"room" => 50, "x" => 5}}]) == :ok
      assert call(PowerLevels, :validate_content, [%{"users" => %{"@ghost:other.example" => -5}}]) == :ok
    end

    test "the integer texts: a string, a float, a boolean, 2^53 and -(2^53) are refused with the override text" do
      for bad <- ["50", 50.0, true, 9_007_199_254_740_992, -9_007_199_254_740_992] do
        assert {:error, "power level values must be integers within +-(2^53 - 1)"} = call(PowerLevels, :validate_content, [%{"ban" => bad}])
      end

      assert call(PowerLevels, :validate_content, [%{"ban" => 9_007_199_254_740_991, "kick" => -9_007_199_254_740_991}]) == :ok
    end

    test "the structure texts: users keys must be valid user ids, events keys non-empty and at most 255 bytes" do
      assert {:error, "users keys must be valid user ids"} = call(PowerLevels, :validate_content, [%{"users" => %{"alice" => 1}}])
      assert {:error, "events keys must be non-empty event types of at most 255 bytes"} = call(PowerLevels, :validate_content, [%{"events" => %{"" => 1}}])
      assert {:error, text} = call(PowerLevels, :validate_content, [%{"events" => "x"}])
      assert is_binary(text)
    end

    test "null anywhere at the top level, a non-object users / events / notifications and a non-map content are refused" do
      for content <- [%{"x_custom" => nil}, %{"ban" => nil}, %{"users" => []}, %{"users" => nil}, %{"events" => nil}, %{"notifications" => []}, "text", [1], nil] do
        assert {:error, text} = call(PowerLevels, :validate_content, [content])
        assert is_binary(text), "#{inspect(content)}"
      end
    end
  end

  # ═══ check_change/3: the table over every rule (5) - (7) ═══════════════════════

  describe "check_change/3 table (sender s at 50 unless stated)" do
    @s "@s:test.local"
    @u "@u:test.local"
    @w "@w:test.local"

    # {label, current content, new content, sender, expected}
    cases = [
      {"identical content changes nothing", %{"ban" => 50, "users" => %{"@s:test.local" => 50}}, %{"ban" => 50, "users" => %{"@s:test.local" => 50}}, @s, :ok},
      {"(5) raising a key to the sender's level is allowed (equal)", %{"kick" => 40, "users" => %{@s => 50}}, %{"kick" => 50, "users" => %{@s => 50}}, @s, :ok},
      {"(5) raising a key above the sender's level grants too much", %{"ban" => 50, "users" => %{@s => 50}}, %{"ban" => 51, "users" => %{@s => 50}}, @s, {:error, :grant_above_own_level}},
      {"(5) lowering a key is allowed", %{"kick" => 50, "users" => %{@s => 50}}, %{"kick" => 0, "users" => %{@s => 50}}, @s, :ok},
      {"(5) changing a key whose current value is above the sender's level", %{"state_default" => 75, "users" => %{@s => 50}}, %{"state_default" => 60, "users" => %{@s => 50}}, @s, {:error, :above_own_level}},
      {"(5) removing a key whose current value is above the sender's level", %{"kick" => 75, "users" => %{@s => 50}}, %{"users" => %{@s => 50}}, @s, {:error, :above_own_level}},
      {"(5) adding an absent key with a value within the level", %{"users" => %{@s => 50}}, %{"redact" => 50, "users" => %{@s => 50}}, @s, :ok},
      {"(5) adding an absent key above the level", %{"users" => %{@s => 50}}, %{"redact" => 51, "users" => %{@s => 50}}, @s, {:error, :grant_above_own_level}},
      {"(5) a key present with its default value vs. absent IS an alteration: removing a key at 75 is refused although 50 is the default", %{"redact" => 75, "users" => %{@s => 50}}, %{"users" => %{@s => 50}}, @s, {:error, :above_own_level}},
      {"(5) removing a key whose current value is within the level is allowed", %{"redact" => 50, "users" => %{@s => 50}}, %{"users" => %{@s => 50}}, @s, :ok},
      {"(6) events: adding an entry at the sender's level", %{"events" => %{}, "users" => %{@s => 50}}, %{"events" => %{"m.room.topic" => 50}, "users" => %{@s => 50}}, @s, :ok},
      {"(6) events: adding an entry above the sender's level", %{"events" => %{}, "users" => %{@s => 50}}, %{"events" => %{"m.room.topic" => 51}, "users" => %{@s => 50}}, @s, {:error, :grant_above_own_level}},
      {"(6) events: changing an entry whose current value is 100", %{"events" => %{"m.room.topic" => 100}, "users" => %{@s => 50}}, %{"events" => %{"m.room.topic" => 50}, "users" => %{@s => 50}}, @s, {:error, :above_own_level}},
      {"(6) events: removing an entry whose current value is 100", %{"events" => %{"m.room.topic" => 100}, "users" => %{@s => 50}}, %{"events" => %{}, "users" => %{@s => 50}}, @s, {:error, :above_own_level}},
      {"(6) events: an entry whose current value equals the sender's level may change to 0 (strictly greater rejects)", %{"events" => %{"m.room.topic" => 50}, "users" => %{@s => 50}}, %{"events" => %{"m.room.topic" => 0}, "users" => %{@s => 50}}, @s, :ok},
      {"(6) notifications are treated like events (add above)", %{"users" => %{@s => 50}}, %{"notifications" => %{"room" => 51}, "users" => %{@s => 50}}, @s, {:error, :grant_above_own_level}},
      {"(6) notifications: a current value above the sender's level", %{"notifications" => %{"room" => 100}, "users" => %{@s => 50}}, %{"notifications" => %{"room" => 50}, "users" => %{@s => 50}}, @s, {:error, :above_own_level}},
      {"(7) users: adding a user at the sender's level", %{"users" => %{@s => 50}}, %{"users" => %{@s => 50, @u => 50}}, @s, :ok},
      {"(7) users: adding a user above the sender's level", %{"users" => %{@s => 50}}, %{"users" => %{@s => 50, @u => 51}}, @s, {:error, :grant_above_own_level}},
      {"(7) users: changing a user at the sender's level (equal rejects)", %{"users" => %{@s => 50, @u => 50}}, %{"users" => %{@s => 50, @u => 10}}, @s, {:error, :target_not_lower}},
      {"(7) users: removing a user at the sender's level (equal rejects)", %{"users" => %{@s => 50, @u => 50}}, %{"users" => %{@s => 50}}, @s, {:error, :target_not_lower}},
      {"(7) users: changing a user below the sender's level", %{"users" => %{@s => 50, @u => 49}}, %{"users" => %{@s => 50, @u => 10}}, @s, :ok},
      {"(7) users: removing a user below the sender's level", %{"users" => %{@s => 50, @u => 49}}, %{"users" => %{@s => 50}}, @s, :ok},
      {"(7) users: a user above the sender's level cannot be changed", %{"users" => %{@s => 50, @u => 80}}, %{"users" => %{@s => 50, @u => 10}}, @s, {:error, :target_not_lower}},
      {"(7) self: lowering his own entry", %{"users" => %{@s => 50}}, %{"users" => %{@s => 10}}, @s, :ok},
      {"(7) self: removing his own entry", %{"users" => %{@s => 50}}, %{"users" => %{}}, @s, :ok},
      {"(7) self: raising his own entry above his level", %{"users" => %{@s => 50}}, %{"users" => %{@s => 51}}, @s, {:error, :grant_above_own_level}},
      {"(7) self at an equal level: lowering his own entry while another user is at his level", %{"users" => %{@s => 100, @u => 100}}, %{"users" => %{@s => 50, @u => 100}}, @s, :ok},
      {"(7) self at an equal level: removing the other user's entry", %{"users" => %{@s => 100, @u => 100}}, %{"users" => %{@s => 100}}, @s, {:error, :target_not_lower}},
      {"(7) an entry that is unchanged is not looked at (a user above the sender stays)", %{"users" => %{@s => 50, @u => 80}, "ban" => 50}, %{"users" => %{@s => 50, @u => 80}, "ban" => 40}, @s, :ok},
      {"the order of the rules: (5) before (7)", %{"ban" => 50, "users" => %{@s => 50, @u => 50}}, %{"ban" => 51, "users" => %{@s => 50, @u => 10}}, @s, {:error, :grant_above_own_level}},
      {"an unknown top-level key is not subject to the rules", %{"users" => %{@s => 50}}, %{"x_custom" => 999, "users" => %{@s => 50}}, @s, :ok},
      {"a sender above the others may change everything below him", %{"kick" => 90, "users" => %{@s => 100, @u => 99}}, %{"kick" => 100, "users" => %{@s => 100, @u => 0, @w => 100}}, @s, :ok},
      {"negative levels: a sender at 0 changes a user at -5", %{"users" => %{@s => 0, @u => -5}, "users_default" => -10}, %{"users" => %{@s => 0, @u => -7}, "users_default" => -10}, @s, :ok},
      {"negative levels: a sender at -1 cannot grant 0", %{"users" => %{@s => -1}, "users_default" => -10}, %{"users" => %{@s => -1, @u => 0}, "users_default" => -10}, @s, {:error, :grant_above_own_level}},
      {"a sender with no entry reads users_default as his level", %{"users_default" => 50, "kick" => 50}, %{"users_default" => 50, "kick" => 60}, @w, {:error, :grant_above_own_level}}
    ]

    for {{label, current, new, sender, expected}, index} <- Enum.with_index(cases) do
      test "case #{index}: #{label}" do
        assert call(PowerLevels, :check_change, [unquote(Macro.escape(current)), unquote(Macro.escape(new)), unquote(sender)]) == unquote(Macro.escape(expected))
      end
    end
  end

  # ═══ AC4 (d) (unit): the membership re-check in the room process ════════════════

  describe "AC4 (d) (unit) - send_event/6 refuses a sender that is no longer a member" do
    test "a stale snapshot: the sender left after the caller's check: {:error, :sender_not_joined}, nothing written; a member's send works (control)" do
      admin = user("adm")
      leaver = user("lvr")
      room = room_with(admin, [leaver], levels(%{admin => 100}))

      assert {:ok, _event_id} = Server.send_event(room, leaver, "m.room.message", %{"body" => "x"}, "t1")
      assert :ok = Server.leave(room, leaver)
      reset_calls()

      assert {:error, :sender_not_joined} = Server.send_event(room, leaver, "m.room.message", %{"body" => "y"}, "t2")
      assert calls(:insert_event) == 0, "nothing is written"
    end

    test "a user who never joined is refused the same way, a state event too" do
      admin = user("adm")
      stranger = user("str")
      room = room_with(admin, [], levels(%{admin => 100, stranger => 100}))
      assert {:error, :sender_not_joined} = Server.send_event(room, stranger, "m.room.message", %{}, "t1")
      assert {:error, :sender_not_joined} = Server.send_event(room, stranger, "m.room.topic", %{}, "t2", "")
    end
  end

  describe "D5 (d) order (unit) - membership, level, idempotency, archived check" do
    setup do
      admin = user("adm")
      member = user("mem")
      low = user("low")
      stranger = user("str")
      room = room_with(admin, [member, low], levels(%{admin => 100, member => 10}, %{"events_default" => 10, "events" => %{@pl => 50, "m.custom" => 10}}))
      on_exit(fn -> :ets.match_delete(:NebuTxnDedup, {{room, :_, :_}, :_}) end)
      {:ok, admin: admin, member: member, low: low, stranger: stranger, room: room}
    end

    defp archive!(room), do: :ets.insert(@table, {{:status, room}, "archived"})
    # story state-writer-redaction (DELIBERATE re-pin, Kassandra #5; old -> new): the /send txn key is {room, user, {:send, event_type, txn}} (a txn id is scoped to its path incl. the event type); was {room, user, txn}
    defp cache_txn!(room, user, type, txn), do: :ets.insert(:NebuTxnDedup, {{room, user, {:send, type, txn}}, "$cached" <> rand()})

    test "a non-member into an ARCHIVED room is :sender_not_joined (membership first); a member gets :room_archived (control)", %{member: member, stranger: stranger, room: room} do
      archive!(room)
      assert {:error, :sender_not_joined} = Server.send_event(room, stranger, "m.custom", %{}, "t1")
      assert {:error, :room_archived} = Server.send_event(room, member, "m.custom", %{}, "t2")
    end

    test "a non-member with an existing txn id is :sender_not_joined, never the cached event id; a member gets the cached id (control)", %{member: member, stranger: stranger, room: room} do
      cache_txn!(room, stranger, "m.custom", "t1")
      cache_txn!(room, member, "m.custom", "t2")
      assert {:error, :sender_not_joined} = Server.send_event(room, stranger, "m.custom", %{}, "t1")
      assert {:ok, "$cached" <> _} = Server.send_event(room, member, "m.custom", %{}, "t2")
    end

    test "a member below the required level with an existing txn id is :forbidden, never the cached event id", %{low: low, room: room} do
      cache_txn!(room, low, "m.room.message", "t1")
      cache_txn!(room, low, "m.room.topic", "t1")
      assert {:error, :forbidden} = Server.send_event(room, low, "m.room.message", %{}, "t1")
      assert {:error, :forbidden} = Server.send_event(room, low, "m.room.topic", %{}, "t1", "")
    end

    test "a member below the level in an ARCHIVED room is :forbidden (level before the status read)", %{low: low, room: room} do
      archive!(room)
      assert {:error, :forbidden} = Server.send_event(room, low, "m.room.topic", %{}, "t1", "")
    end
  end

  describe "D5 (unit) - Room.Server.send_event/6 enforces events[type] in the process" do
    test "a message type with an entry needs it, one without needs events_default; a state event needs events[type] else state_default" do
      admin = user("adm")
      low = user("low")
      mid = user("mid")
      room = room_with(admin, [low, mid], levels(%{admin => 100, mid => 50}, %{"events_default" => 10, "events" => %{@pl => 50, "m.custom" => 0, "m.room.topic" => 100}}))

      assert {:ok, _} = Server.send_event(room, low, "m.custom", %{}, "t1")
      assert {:error, :forbidden} = Server.send_event(room, low, "m.room.message", %{}, "t2")
      assert {:ok, _} = Server.send_event(room, admin, "m.room.message", %{}, "t3")
      assert {:error, :forbidden} = Server.send_event(room, mid, "m.room.topic", %{}, "t4", "")
      assert {:ok, _} = Server.send_event(room, admin, "m.room.topic", %{}, "t5", "")
      assert {:error, :forbidden} = Server.send_event(room, low, "m.room.avatar", %{}, "t6", "")
      assert {:ok, _} = Server.send_event(room, mid, "m.room.avatar", %{}, "t7", "")
    end
  end

  # ═══ change_power_levels/4 on the fake ═════════════════════════════════════════

  describe "change_power_levels/4 (mode: :client) - the decision of D2, first failure wins" do
    setup do
      admin = user("adm")
      mod = user("mod")
      low = user("low")
      outsider = user("out")
      room = room_with(admin, [mod, low], levels(%{admin => 100, mod => 50}))
      {:ok, admin: admin, mod: mod, low: low, outsider: outsider, room: room}
    end

    defp nothing_written!(room, before_levels) do
      assert applies(room) == [], "no transaction ran"
      assert calls(:insert_event) == 0 and calls(:set_power_levels) == 0
      assert Server.get_state(room).power_levels == before_levels, "the in-memory levels are unchanged"
    end

    test "a sender who is not a member is {:error, :sender_not_joined}", %{outsider: outsider, room: room} do
      before = Server.get_state(room).power_levels
      assert {:error, :sender_not_joined} = change(room, outsider, levels(%{outsider => 100}))
      nothing_written!(room, before)
    end

    test "a member below the required level is {:error, :insufficient_level}", %{low: low, room: room} do
      before = Server.get_state(room).power_levels
      assert {:error, :insufficient_level} = change(room, low, Map.put(before, "events_default", 5))
      nothing_written!(room, before)
    end

    test "the order: membership, then level, then shape (a bad shape does not change the first refusal)", %{outsider: outsider, low: low, room: room} do
      assert {:error, :sender_not_joined} = change(room, outsider, %{"ban" => "x"})
      assert {:error, :insufficient_level} = change(room, low, %{"ban" => "x"})
    end

    test "a shape violation is {:error, {:invalid, _}} (a string level, a float, a bad users key) and nothing is written", %{mod: mod, room: room} do
      before = Server.get_state(room).power_levels

      for bad <- [%{"ban" => "50"}, %{"kick" => 50.0}, %{"users" => %{"alice" => 1}}, %{"events" => %{"" => 1}}, %{"x_custom" => nil}] do
        assert {:error, {:invalid, _}} = change(room, mod, Map.merge(before, bad))
      end

      nothing_written!(room, before)
    end

    test "the three change rules: :above_own_level, :grant_above_own_level, :target_not_lower", %{admin: admin, mod: mod, room: room} do
      before = Server.get_state(room).power_levels

      assert {:error, :grant_above_own_level} = change(room, mod, Map.put(before, "ban", 51))
      assert {:error, :target_not_lower} = change(room, mod, put_in(before, ["users", admin], 10))
      seeded = Map.put(before, "state_default", 75)
      assert :ok = Server.set_power_levels(room, admin, seeded)
      reset_calls()
      assert {:error, :above_own_level} = change(room, mod, Map.put(seeded, "state_default", 60))
      nothing_written!(room, seeded)
    end

    test "an event above 65 536 canonical bytes is {:error, :event_too_large} and nothing is written", %{admin: admin, room: room} do
      before = Server.get_state(room).power_levels
      assert {:error, :event_too_large} = change(room, admin, Map.put(before, "x_big", String.duplicate("z", 70_000)))
      nothing_written!(room, before)
    end

    test "{} content: nobody reaches state_default 50 (D4 (c)), every change is {:error, :insufficient_level}", %{admin: admin, mod: mod, room: room} do
      committed_id(change(room, admin, %{}))
      assert Server.get_state(room).power_levels == %{}
      reset_calls()

      for sender <- [admin, mod], content <- [%{}, levels(%{admin => 100})] do
        assert {:error, :insufficient_level} = change(room, sender, content)
      end

      assert applies(room) == []
    end
  end

  describe "change_power_levels/4 (mode: :client) - the write" do
    setup do
      admin = user("adm")
      room = room_with(admin, [], levels(%{admin => 100}))
      {:ok, admin: admin, room: room}
    end

    test "ONE apply_power_levels_change/3 call with the content JSON and the signed event; the state follows the commit; the two-statement path is never used", %{admin: admin, room: room} do
      new = levels(%{admin => 100}, %{"events_default" => 7})
      result = change(room, admin, new)

      id = committed_id(result)
      assert [{^room, json, event}] = applies(room)
      assert Jason.decode!(json) == new
      assert event["event_id"] == id and event["type"] == @pl and event["state_key"] == "" and event["sender"] == admin
      assert event["content"] == new and is_binary(get_in(event, ["signatures", "nebu"]))
      assert calls(:set_power_levels) == 0 and calls(:insert_event) == 0, "never separate statements"

      state = Server.get_state(room)
      assert state.power_levels == new
      assert {^id, ts, ^admin} = state.power_levels_event
      assert ts == event["origin_server_ts"]
    end

    test "the stamp is max(now, not_before, latest levels ts + 1): a latest event 60 s ahead gives exactly latest + 1, not_before lifts it further", %{admin: admin, room: room} do
      far = System.system_time(:millisecond) + 60_000
      :ets.insert(@table, {{:identity, room}, {"$prev", far, admin}})
      # a fresh process loads the identity of the fake
      kill_and_restart!(room)

      committed_id(change(room, admin, levels(%{admin => 100}, %{"events_default" => 1})))
      assert [{^room, _json, event}] = applies(room)
      assert event["origin_server_ts"] == far + 1

      later = far + 5_000
      committed_id(change(room, admin, levels(%{admin => 100}, %{"events_default" => 2}), not_before: later))
      assert [_, {^room, _json2, event2}] = applies(room) |> Enum.sort_by(fn {_room, _json, event} -> event["origin_server_ts"] end)
      assert event2["origin_server_ts"] == later
    end

    test "identical content is an idempotent success with the CURRENT event id: no write, no new identity", %{admin: admin, room: room} do
      new = levels(%{admin => 100}, %{"events_default" => 7})
      first = committed_id(change(room, admin, new))
      before = applies(room)

      assert committed_id(change(room, admin, new)) == first
      assert applies(room) == before, "no second transaction"
      assert {^first, _ts, ^admin} = Server.get_state(room).power_levels_event
    end

    test "a failing transaction is {:error, :write_failed}: the levels, the identity and the db are unchanged, no broadcast; a retry works", %{admin: admin, room: room} do
      :ok = :pg.join("room:#{room}", self())
      before = Server.get_state(room)
      :ets.insert(@table, {:apply_fail, :boom})

      assert {:error, :write_failed} = change(room, admin, levels(%{admin => 100}, %{"events_default" => 9}))

      after_state = Server.get_state(room)
      assert after_state.power_levels == before.power_levels and after_state.power_levels_event == before.power_levels_event
      assert calls(:set_power_levels) == 0
      refute_receive {:new_event, _}, 100

      :ets.delete(@table, :apply_fail)
      committed_id(change(room, admin, levels(%{admin => 100}, %{"events_default" => 9})))
      assert_receive {:new_event, %{"type" => @pl}}, 2_000
    end
  end

  describe "change_power_levels/4 (mode: :internal) and set_power_levels/3" do
    test "the bootstrap: levels {} accept ANY caller, the shape is strict, then events[levels event] / state_default decides, NO change rules" do
      first = user("one")
      second = user("two")
      room = start_room()
      assert :ok = Server.join(room, first)

      assert {:error, {:invalid, _}} = call(Server, :change_power_levels, [room, first, %{"ban" => "x"}, [mode: :internal]])
      assert :ok = Server.set_power_levels(room, second, levels(%{first => 100}))
      assert [_one] = applies(room)

      # now the authorisation is the levels' own: `second` is no admin
      assert {:error, :forbidden} = Server.set_power_levels(room, second, levels(%{first => 100, second => 100}))
      # the creator passes without the change rules: he may even lower himself and grant 200 to somebody else
      assert :ok = Server.set_power_levels(room, first, levels(%{first => 10, second => 200}))
    end

    test "set_power_levels/3 keeps {:error, :event_too_large} and writes nothing for an oversized content" do
      admin = user("adm")
      room = room_with(admin, [], levels(%{admin => 100}))
      assert {:error, :event_too_large} = Server.set_power_levels(room, admin, Map.put(levels(%{admin => 100}), "x_big", String.duplicate("z", 70_000)))
      assert applies(room) == []
    end
  end

  # ═══ AC6 (b): a db module without apply_power_levels_change/3, a room that does not answer ═══

  describe "AC6 (b) - a db module without apply_power_levels_change/3" do
    test "change_power_levels/4 answers {:error, :unsupported_db_module}, writes nothing and NEVER falls back to separate statements" do
      admin = user("adm")
      room = room_with(admin, [], levels(%{admin => 100}))
      Application.put_env(:room_manager, :db_module, OldDB)
      before = Server.get_state(room).power_levels

      assert {:error, :unsupported_db_module} = change(room, admin, levels(%{admin => 100}, %{"events_default" => 4}))
      assert {:error, :unsupported_db_module} = Server.set_power_levels(room, admin, levels(%{admin => 100}, %{"events_default" => 4}))

      assert calls(:set_power_levels) == 0 and calls(:insert_event) == 0, "no sequential fallback"
      assert Server.get_state(room).power_levels == before, "the in-memory state is unchanged"
    end

    test "the route answers 500 for it (never a success), the room unchanged" do
      admin = user("adm")
      room = room_with(admin, [], levels(%{admin => 100}))
      Application.put_env(:room_manager, :db_module, OldDB)
      before = Server.get_state(room).power_levels
      req = %Core.SetRoomStateRequest{room_id: room, sender_id: admin, event_type: @pl, state_key: "", content_json: Jason.encode!(levels(%{admin => 100}, %{"events_default" => 4}))}

      assert {:error, {500, "M_UNKNOWN", _text}} = Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_room_state(req, Nebu.Matrix.Http.stream(admin)) end)

      assert calls(:set_power_levels) == 0 and calls(:insert_event) == 0
      assert Server.get_state(room).power_levels == before
    end
  end

  describe "AC6 (b) - a room process that does not answer" do
    # The suspended process also blocks any snapshot read, so this test pins the dispatcher's answer for an unanswering room; the call-exit
    # mapping of the WRITER itself (a process killed inside the call) is pinned on the real database by AC8 in power_levels_writer_db_test.exs.
    test "the route answers 503 M_UNAVAILABLE after the call timeout; the queued call, once the process runs again, leaves a consistent room" do
      admin = user("adm")
      room = room_with(admin, [], levels(%{admin => 100}))
      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      new = levels(%{admin => 100}, %{"events_default" => 4})
      req = %Core.SetRoomStateRequest{room_id: room, sender_id: admin, event_type: @pl, state_key: "", content_json: Jason.encode!(new)}

      :sys.suspend(pid)
      result = Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_room_state(req, Nebu.Matrix.Http.stream(admin)) end)

      assert {:error, {503, "M_UNAVAILABLE", "The room did not answer, the change may or may not have been applied"}} = result
      assert applies(room) == [], "nothing was written while the process did not answer"

      # "may or may not have been applied": the queued call is processed once the process runs again; the room must be consistent either way
      :sys.resume(pid)
      state = Server.get_state(room)

      case applies(room) do
        [] -> assert state.power_levels == levels(%{admin => 100})
        [{^room, json, _event}] -> assert Jason.decode!(json) == new and state.power_levels == new
      end
    end
  end

  # ═══ AC14: source pins and seams ═══════════════════════════════════════════════

  # ─── source pins: the AST of a lib file WITHOUT comments and @moduledoc / @doc heredocs (a comment or a doc can never satisfy or break a pin) ───

  defp code_ast(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :typedoc] -> nil
      node -> node
    end)
  end

  defp nodes(ast), do: ast |> Macro.prewalk([], fn node, acc -> {node, [node | acc]} end) |> elem(1)

  # remote calls `Target.fun(...)`: the target as alias segments (`[:Nebu, :Matrix, ...]`) or the name of a zero-arity call (`:db_module`)
  defp remote_calls(ast, fun), do: for({{:., _, [target, ^fun]}, _, _args} <- nodes(ast), do: target_name(target))

  defp target_name({:__aliases__, _, segments}), do: segments
  defp target_name({name, _, args}) when is_atom(name) and is_list(args), do: name
  defp target_name(other), do: other

  defp defined_functions(ast), do: for({kind, _, [head | _]} <- nodes(ast), kind in [:def, :defp], name = head_name(head), do: name)

  defp head_name({:when, _, [head | _]}), do: head_name(head)
  defp head_name({name, _, args}) when is_atom(name) and is_list(args), do: name
  defp head_name(_other), do: nil

  # maps `%{"type" => "m.room.power_levels", ...}` (a levels event being built)
  defp levels_event_maps(ast),
    do: for({:%{}, _, pairs} <- nodes(ast), {"type", "m.room.power_levels"} in pairs, Enum.any?(pairs, &match?({"sender", _}, &1)), do: pairs)

  defp lib_path(relative), do: Path.join(@lib, relative)

  defp column_sql?(node), do: is_binary(node) and Regex.match?(~r/SET power_levels_json\s*=/, node)

  describe "AC14 (a) - the levels event and the column are written by the room process only" do
    test "Room.Server has no apply_power_levels/4 and no emit_power_levels_event/3 any more and never calls the two-statement db set_power_levels" do
      ast = code_ast(lib_path("nebu/matrix/room/server.ex"))
      functions = defined_functions(ast)
      refute :apply_power_levels in functions, "apply_power_levels/4 is still there"
      refute :emit_power_levels_event in functions, "emit_power_levels_event/3 is still there"
      assert :db_module not in remote_calls(ast, :set_power_levels), "the room process still writes the column with its own statement"
      assert :apply_power_levels_change in nodes(ast), "the room process writes through Room.DB.apply_power_levels_change/3"
    end

    test "the dispatcher builds at most ONE levels event map (create_personal_room, a brand-new room) and writes the column in one place at most" do
      ast = code_ast(lib_path("nebu/matrix/event_dispatcher/server.ex"))
      assert length(levels_event_maps(ast)) <= 1, "levels event maps in the dispatcher: #{length(levels_event_maps(ast))}"
      columns = Enum.filter(remote_calls(ast, :set_power_levels), &(&1 == :messages_db_module))
      assert length(columns) <= 1, "column writes of the dispatcher outside create_personal_room: #{length(columns)}"
    end

    test "no other file of server/lib (outside Room.Server, the dispatcher and Room.DB) builds the levels event or writes the column" do
      allowed = Enum.map(["nebu/matrix/room/server.ex", "nebu/matrix/event_dispatcher/server.ex", "nebu/matrix/room/db.ex"], &lib_path/1)

      offenders =
        for f <- Path.wildcard(lib_path("**/*.ex")), f not in allowed, ast = code_ast(f), levels_event_maps(ast) != [] or Enum.any?(nodes(ast), &column_sql?/1), do: Path.relative_to(f, @lib)

      assert offenders == []
    end

    test "Room.DB writes the column only in apply_power_levels_change/3 and, at most, the legacy set_power_levels/2 (create_personal_room)" do
      ast = code_ast(lib_path("nebu/matrix/room/db.ex"))
      assert length(Enum.filter(nodes(ast), &column_sql?/1)) in 1..2, "the column is written by apply_power_levels_change/3 and, at most, the legacy set_power_levels/2"
      assert :apply_power_levels_change in defined_functions(ast)
    end

    test "Room.Server.set_power_levels/3 has no caller in lib/nebu/web and exactly two in the dispatcher (createRoom step 3, upgrade initial levels)" do
      web =
        for f <- Path.wildcard(lib_path("nebu/web/**/*.ex")),
            ast = code_ast(f),
            remote_calls(ast, :set_power_levels) ++ remote_calls(ast, :change_power_levels) != [],
            do: f

      assert web == [], "the web layer reaches the power levels only through set_room_state"

      dispatcher = code_ast(lib_path("nebu/matrix/event_dispatcher/server.ex"))
      room_server_calls = Enum.filter(remote_calls(dispatcher, :set_power_levels), &(is_list(&1) and Enum.take(&1, -2) == [:Room, :Server]))
      assert length(room_server_calls) == 2
    end

    test "the route reaches only change_power_levels/4 in mode: :client (the dispatcher never passes mode: :internal)" do
      ast = code_ast(lib_path("nebu/matrix/event_dispatcher/server.ex"))
      assert Enum.any?(remote_calls(ast, :change_power_levels), &(is_list(&1) and Enum.take(&1, -2) == [:Room, :Server]))
      assert {:mode, :client} in nodes(ast)
      refute {:mode, :internal} in nodes(ast), "the internal writer is not reachable from a client request"
    end
  end

  # The suites whose fake db module reaches `Room.Server.set_power_levels/3` (createRoom step 3, the upgrade's initial levels, the test seeds) or the dispatcher's
  # levels writer and therefore MUST implement `apply_power_levels_change/3` like the real transaction (set the column AND insert the event; a failure switch where the suite
  # already has one) - NOT an `:ok` stub. The list is what the unit run against the reference implementation of this story found (every suite that failed with
  # `:unsupported_db_module`); the dev greps `def set_power_levels` in `server/test`, records the full list of fakes in the Completion Notes and adds any further suite
  # that its own run shows (the integration run uses the real database, no fake).
  @fake_suites ~w(
    admin/admin_create_room_test admin/admin_member_management_test
    matrix/event_dispatcher/admin_force_add_member_test matrix/event_dispatcher/audit_member_ops_test matrix/event_dispatcher/audit_room_ops_test
    matrix/event_dispatcher/create_room_canonical_alias_test matrix/event_dispatcher/create_room_creator_provisioning_test
    matrix/event_dispatcher/create_room_initial_state_test matrix/event_dispatcher/create_room_input_validation_test
    matrix/event_dispatcher/create_room_invites_test matrix/event_dispatcher/create_room_presets_test matrix/event_dispatcher/create_room_test
    matrix/event_dispatcher/handler_test matrix/event_dispatcher/invite_caps_test matrix/event_dispatcher/invite_user_test matrix/event_dispatcher/join_room_test
    matrix/event_dispatcher/spaces_create_room_test matrix/event_dispatcher/upgrade_room_error_handling_test matrix/event_dispatcher/upgrade_room_test
    matrix/room/moderation_fix_cycle1_unit_test matrix/room/moderation_unit_test matrix/room/nebu_room_test matrix/room/power_level_enforcement_test
    matrix/room/send_event_archived_room_test
  )

  describe "AC14 (b) - fakes that write levels implement apply_power_levels_change/3" do
    for suite <- @fake_suites do
      test "#{suite}: the fake defines apply_power_levels_change/3 writing the column AND the event (no stub)" do
        path = Path.join(@test_dir, "nebu/#{unquote(suite)}.exs")
        ast = path |> File.read!() |> Code.string_to_quoted!()

        bodies =
          for {:def, _, [head, [do: body]]} <- nodes(ast), {:apply_power_levels_change, _, [_, _, _]} <- [head], do: Macro.to_string(body)

        assert bodies != [], "#{unquote(suite)}.exs has no apply_power_levels_change/3 in its fake"

        for body <- bodies do
          assert body =~ "power_levels", "a fake's apply_power_levels_change/3 must write the column (the levels JSON): #{body}"
          assert body =~ ~r/insert_event|\bevent\b/, "a fake's apply_power_levels_change/3 must write the event: #{body}"
        end
      end
    end
  end

  describe "AC12 (unit) - the audit action" do
    test "room_power_levels_changed is one of the known actions of AuditWriter (the real writer would answer :audit_unknown_action otherwise)" do
      source = File.read!(Path.join(@lib, "nebu/compliance/audit_writer.ex"))
      [_, known] = Regex.run(~r/@known_actions ~w\((.*?)\)/s, source)
      assert "room_power_levels_changed" in String.split(known), "room_power_levels_changed is missing from @known_actions"
      assert "room_member_banned" in String.split(known), "positive control: the list was parsed"
    end
  end

  describe "AC14 (c) - PowerLevels is pure and can?/3 keeps its signature" do
    test "no DB, no process, no application env in power_level.ex (code only: comments and docs are not scanned)" do
      ast = code_ast(lib_path("nebu/matrix/room/power_level.ex"))
      segments = for {:__aliases__, _, segs} <- nodes(ast), do: segs
      assert segments != [], "positive control: the module references aliases"

      for forbidden <- [[:Nebu, :Repo], [:Ecto], [:GenServer], [:Application], [:Horde], [:Logger]] do
        refute Enum.any?(segments, &(Enum.take(&1, length(forbidden)) == forbidden)), "power_level.ex references #{Enum.join(forbidden, ".")}"
      end

      refute :pg in nodes(ast), "power_level.ex uses :pg"
    end

    test "can?/3, get_user_level/2 and default_levels/0 are exported with their arities; the new pure functions exist" do
      Code.ensure_loaded!(PowerLevels)
      assert function_exported?(PowerLevels, :can?, 3)
      assert function_exported?(PowerLevels, :get_user_level, 2)
      assert function_exported?(PowerLevels, :default_levels, 0)

      for {fun, arity} <- [normalize: 1, required_level: 2, validate_content: 1, check_change: 3] do
        assert function_exported?(PowerLevels, fun, arity), "PowerLevels.#{fun}/#{arity} is missing"
      end

      assert function_exported?(Server, :change_power_levels, 4)
      assert function_exported?(Server, :set_power_levels, 3)
    end
  end
end
