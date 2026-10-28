defmodule Nebu.Matrix.Room.StateWriterRedactionUnitTest do
  @moduledoc """
  Story `state-writer-redaction`, UNIT half (no PostgreSQL; the real `Room.Server` / Horde / `:pg` run on a fake db module through the existing
  `:room_manager, :db_module` seam): the pure `Nebu.Matrix.Redaction` (D5, D6), `PowerLevels` `:redact` (AC12 (c)), the room-version guard of D5, AC4 (e), AC6 (b), AC7
  (f), the decision order of D2 and D8 on the room process, the rendering of the new `Core.Event` fields and the source pins of AC12. Everything the real SQL decides is
  in the real-database suites.

  The fake models the real transactions (lesson of the earlier stories): `apply_redaction/2` and `apply_state_change/3` store the event, record every call and have
  a failure switch; `insert_event/1` is COUNTED, so "never a fallback to `insert_event/1`" is an assertion.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The pure API pinned here: `Nebu.Matrix.Redaction.prune(event_map, redaction_row | nil)` (the event map and the redaction row have the string keys of the
      database rows; the answer is the event map with `"content" => %{}` and `"redacted_because" => served(row)`) and `Nebu.Matrix.Redaction.served(row)` (the redaction
      event as a client receives it: exactly the keys `event_id`, `type`, `room_id`, `sender`, `origin_server_ts`, `content` incl. `redacts` and the top-level `redacts`
      for a writer-made row (column set); a legacy row (column NULL) is served without both). The story names `prune/2` and "the render helper for `redacts`".
    * `Room.Server.redaction_event(room_version, room_id, sender, target, content, ts)` is the ONE function that builds the stored redaction (D5: "keyed by the room
      version"); `{:ok, event_map} | {:error, :unsupported_room_version}`.
    * The source pins read `server/lib` through the AST (comments, docs and aliases are no hit). Pin (b) is stated by function: the dispatcher functions that may call
      `emit_state_event/5` / `emit_state_event_at/6` are exactly today's createRoom writers and the upgrade (its `m.room.create` of the NEW room); `set_room_state/2` is
      not one of them and no such call passes the tombstone type.
    * The `PowerLevels` `:redact` action is reached through `call/3`: the file compiles before the dev step.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport, only: [kill_and_restart!: 1]
  import Nebu.Matrix.PowerLevelsTestSupport, only: [call: 3]

  alias Nebu.Matrix.Room.PowerLevels
  alias Nebu.Matrix.Room.Server

  @table :state_writer_redaction_unit_test_db
  @lib Path.expand("../../../../lib", __DIR__)
  @redaction "m.room.redaction"

  # ─── the fake ────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @moduledoc false
    @table :state_writer_redaction_unit_test_db

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

    # counted: a redaction or a state change must NEVER fall back to it
    def insert_event(event) do
      count(:insert_event)
      :ets.insert(@table, {{:event, event["event_id"]}, event})
      :ok
    end

    def set_power_levels(room_id, json) do
      count(:set_power_levels)
      :ets.insert(@table, {{:power_levels, room_id}, json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    def apply_power_levels_change(room_id, json, event) do
      :ets.insert(@table, {{:power_levels, room_id}, json})
      :ets.insert(@table, {{:event, event["event_id"]}, event})
      :ets.insert(@table, {{:identity, room_id}, {event["event_id"], event["origin_server_ts"], event["sender"]}})
      :ok
    end

    # the target read of the redaction writer: the string-keyed map of the `events` columns; a failure switch
    def fetch_event(event_id, room_id) do
      count(:fetch_event)

      case {:ets.lookup(@table, :fetch_fail), :ets.lookup(@table, {:event, event_id})} do
        {[{_, reason}], _} ->
          {:error, reason}

        {[], [{_, %{"room_id" => ^room_id} = e}]} ->
          {:ok,
           %{
             "event_id" => e["event_id"],
             "room_id" => room_id,
             "sender" => e["sender"],
             "event_type" => e["type"],
             "content" => e["content"],
             "origin_server_ts" => e["origin_server_ts"],
             "state_key" => e["state_key"]
           }}

        {[], _} ->
          {:error, :not_found}
      end
    end

    # what the real transactions do: store the event, record the call, a failure switch, an archived switch
    def apply_redaction(room_id, event) do
      count(:apply_redaction)
      :ets.insert(@table, {{:apply_redaction, make_ref()}, {room_id, event}})

      with :ok <- apply_result(room_id, event) do
        :ets.insert_new(@table, {{:redaction_of, event["redacts"]}, event})
        :ok
      end
    end

    # the lookup of the EXISTING writer-made redaction of a target (Kassandra #1): a failure switch; a legacy row (no `redacts`) is never stored here
    def redactions_for(event_ids) do
      count(:redactions_for)

      case :ets.lookup(@table, :redactions_fail) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          rows =
            for id <- event_ids, [{_, e}] <- [:ets.lookup(@table, {:redaction_of, id})] do
              Map.take(e, ["event_id", "room_id", "sender", "origin_server_ts", "content", "redacts"])
            end

          {:ok, rows}
      end
    end

    def apply_state_change(room_id, event, opts) do
      count(:apply_state_change)
      :ets.insert(@table, {{:apply_state, make_ref()}, {room_id, event, opts}})

      with :ok <- apply_result(room_id, event) do
        :ets.insert(@table, {{:slot, room_id, event["type"], event["state_key"]}, {event["event_id"], event["origin_server_ts"], event["sender"]}})
        :ok
      end
    end

    defp apply_result(room_id, event) do
      case {:ets.lookup(@table, {:status, room_id}), :ets.lookup(@table, :apply_fail)} do
        {[{_, "archived"}], _} ->
          {:error, :room_archived}

        {_, [{_, reason}]} ->
          {:error, reason}

        _ ->
          :ets.insert(@table, {{:event, event["event_id"]}, event})
          :ok
      end
    end

    def latest_state_identity(room_id, type, state_key) do
      count(:latest_state_identity)

      case {:ets.lookup(@table, :latest_fail), :ets.lookup(@table, {:slot, room_id, type, state_key})} do
        {[{_, reason}], _} -> {:error, reason}
        {[], [{_, identity}]} -> {:ok, identity}
        {[], []} -> {:ok, nil}
      end
    end

    defp count(name), do: :ets.update_counter(@table, {:calls, name}, 1, {{:calls, name}, 0})
  end

  # the db module of a suite that predates this story: no atomic writer, no slot read
  defmodule OldDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name not in [:apply_redaction, :apply_state_change, :latest_state_identity, :redactions_for] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), unquote(args))
    end
  end

  defmodule NoLookupDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name != :redactions_for do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), unquote(args))
    end
  end

  defmodule NoRedactionDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name != :apply_redaction do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), unquote(args))
    end
  end

  defmodule NoStateChangeDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name != :apply_state_change do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), unquote(args))
    end
  end

  defmodule NoSlotReadDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name != :latest_state_identity do
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

  defp use_db(mod), do: Application.put_env(:room_manager, :db_module, mod)

  defp start_room do
    room = "!swr#{rand()}:test.local"
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
          {:ok, pid} -> Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
          _ -> :ok
        end
      end
    end)

    room
  end

  # the strictly valid content with the spec defaults
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
        "events" => %{"m.room.power_levels" => 50}
      },
      extra
    )
  end

  # a room with `admin` at 100 and the joined `members`; the levels are seeded through the internal writer (the bootstrap branch)
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
    :ets.match_delete(@table, {{:apply_redaction, :_}, :_})
    :ets.match_delete(@table, {{:apply_state, :_}, :_})
  end

  defp calls(name), do: :ets.lookup(@table, {:calls, name}) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  defp redaction_applies, do: :ets.match_object(@table, {{:apply_redaction, :_}, :_}) |> Enum.map(&elem(&1, 1))
  defp state_applies, do: :ets.match_object(@table, {{:apply_state, :_}, :_}) |> Enum.map(&elem(&1, 1))

  # a stored event of the fake: a message by `sender` (`state_key` nil) or a state event
  defp put_event(room, sender, type \\ "m.room.message", state_key \\ nil) do
    id = "$" <> rand() <> rand()

    :ets.insert(
      @table,
      {{:event, id},
       %{"event_id" => id, "room_id" => room, "sender" => sender, "type" => type, "content" => %{"body" => "x"}, "origin_server_ts" => 1, "state_key" => state_key}}
    )

    id
  end

  defp redact(room, sender, target, content \\ %{}, key \\ nil), do: call(Server, :redact, [room, sender, target, content, key || {room, sender, rand()}])
  defp write_state(room, sender, slot, content, opts \\ []), do: call(Server, :write_state, [room, sender, slot, content, opts])

  defp slot_identity(room, type, state_key, ts), do: :ets.insert(@table, {{:slot, room, type, state_key}, {"$old" <> rand(), ts, "@old:test.local"}})

  # ═══ the pure module: Redaction (D5, D6) ═════════════════════════════════════════════

  describe "Nebu.Matrix.Redaction.served/1 (the redaction event as a client receives it)" do
    @writer %{
      "event_id" => "$r1",
      "room_id" => "!r:s",
      "sender" => "@mod:s",
      "origin_server_ts" => 1_700_000_000_000,
      "content" => %{"reason" => "spam"},
      "redacts" => "$target"
    }

    test "a writer-made row: exactly the seven keys, content.redacts AND the top-level redacts, no unsigned, no state_key" do
      assert call(Nebu.Matrix.Redaction, :served, [@writer]) == %{
               "event_id" => "$r1",
               "type" => "m.room.redaction",
               "room_id" => "!r:s",
               "sender" => "@mod:s",
               "origin_server_ts" => 1_700_000_000_000,
               "content" => %{"reason" => "spam", "redacts" => "$target"},
               "redacts" => "$target"
             }
    end

    test "the COLUMN wins over a client key in the content (the stored content has none, a hostile one is overwritten)" do
      served = call(Nebu.Matrix.Redaction, :served, [put_in(@writer, ["content"], %{"redacts" => "$evil", "reason" => "x"})])
      assert served["content"] == %{"reason" => "x", "redacts" => "$target"}
      assert served["redacts"] == "$target"
    end

    test "a LEGACY row (column NULL) is served without the top-level redacts and without content.redacts; its other keys stay" do
      legacy = %{@writer | "redacts" => nil, "content" => %{"redacts" => "$victim", "reason" => "legacy", "x_other" => 1}}

      served = call(Nebu.Matrix.Redaction, :served, [legacy])

      assert served == %{
               "event_id" => "$r1",
               "type" => "m.room.redaction",
               "room_id" => "!r:s",
               "sender" => "@mod:s",
               "origin_server_ts" => 1_700_000_000_000,
               "content" => %{"reason" => "legacy", "x_other" => 1}
             }
    end

    test "a content that arrives as the JSON text of an object (the double encoded legacy form) is decoded; anything that is no object is {}" do
      assert call(Nebu.Matrix.Redaction, :served, [%{@writer | "content" => ~s({"reason":"text"})}])["content"] == %{"reason" => "text", "redacts" => "$target"}
      assert call(Nebu.Matrix.Redaction, :served, [%{@writer | "content" => "not json"}])["content"] == %{"redacts" => "$target"}
      assert call(Nebu.Matrix.Redaction, :served, [%{@writer | "content" => nil}])["content"] == %{"redacts" => "$target"}
    end
  end

  describe "Nebu.Matrix.Redaction.prune/2 (D6: content {}, the served redaction attached, everything else unchanged)" do
    @target %{
      "event_id" => "$target",
      "room_id" => "!r:s",
      "sender" => "@bob:s",
      "event_type" => "m.room.message",
      "content" => %{"msgtype" => "m.text", "body" => "secret"},
      "origin_server_ts" => 1_699_999_999_000,
      "state_key" => nil
    }

    test "the target gets content %{} and redacted_because = served(row); every other key is unchanged" do
      pruned = call(Nebu.Matrix.Redaction, :prune, [@target, @writer])

      assert pruned == Map.merge(@target, %{"content" => %{}, "redacted_because" => call(Nebu.Matrix.Redaction, :served, [@writer])})
      refute inspect(pruned) =~ "secret", "the original content is nowhere in the pruned event"
    end

    test "without a redaction the event is returned as it is (never a redacted_because: null)" do
      assert call(Nebu.Matrix.Redaction, :prune, [@target, nil]) == @target
    end

    test "redacted_because carries no unsigned and none of the target's content" do
      because = call(Nebu.Matrix.Redaction, :prune, [@target, @writer])["redacted_because"]
      refute Map.has_key?(because, "unsigned")
      refute inspect(because) =~ "secret"
    end
  end

  describe "the new fields of Core.Event and their rendering (D5, D6)" do
    test "Core.Event has redacts and redacted_because, both empty by default" do
      event = struct(Core.Event)
      assert Map.fetch!(event, :redacts) == ""
      assert Map.fetch!(event, :redacted_because) == ""
    end

    test "message_event/1 of a redacted event: unsigned.redacted_because is the decoded redaction, content {}" do
      because = %{"event_id" => "$r1", "type" => "m.room.redaction", "content" => %{"redacts" => "$t"}, "redacts" => "$t"}

      rendered =
        Nebu.Matrix.Http.message_event(
          struct(Core.Event, %{event_id: "$t", room_id: "!r:s", sender_id: "@bob:s", event_type: "m.room.message", content: "{}", origin_ts: 5, redacted_because: Jason.encode!(because)})
        )

      assert rendered == %{
               "event_id" => "$t",
               "room_id" => "!r:s",
               "sender" => "@bob:s",
               "type" => "m.room.message",
               "content" => %{},
               "origin_server_ts" => 5,
               "unsigned" => %{"redacted_because" => because}
             }
    end

    test "message_event/1 of a redaction event carries the top-level redacts; an ordinary event has neither key (never null)" do
      redaction =
        Nebu.Matrix.Http.message_event(
          struct(Core.Event, %{event_id: "$r1", room_id: "!r:s", sender_id: "@mod:s", event_type: @redaction, content: ~s({"redacts":"$t"}), origin_ts: 6, redacts: "$t"})
        )

      assert redaction["redacts"] == "$t" and redaction["content"] == %{"redacts" => "$t"}

      plain = Nebu.Matrix.Http.message_event(struct(Core.Event, %{event_id: "$m", room_id: "!r:s", sender_id: "@bob:s", event_type: "m.room.message", content: ~s({"body":"x"}), origin_ts: 7}))
      refute Map.has_key?(plain, "redacts")
      refute Map.has_key?(plain, "unsigned")
    end
  end

  # ═══ PowerLevels :redact (AC12 (c)) ═════════════════════════════════════════════════

  describe "AC12 (c) - PowerLevels knows the redact action" do
    test "required_level/2 reads the redact threshold of the normalised view (default 50), can?/3 compares the user's level with it" do
      assert call(PowerLevels, :required_level, [%{}, :redact]) == 50
      assert call(PowerLevels, :required_level, [%{"redact" => 75}, :redact]) == 75
      assert call(PowerLevels, :required_level, [%{"redact" => "5"}, :redact]) == 50, "a string threshold reads as the spec default"

      levels = %{"redact" => 60, "users" => %{"@mod:s" => 60, "@low:s" => 59}}
      assert call(PowerLevels, :can?, [levels, "@mod:s", :redact])
      refute call(PowerLevels, :can?, [levels, "@low:s", :redact])
      refute call(PowerLevels, :can?, [levels, "@nobody:s", :redact])
    end

    test "the moduledoc no longer says that redact is not evaluated anywhere" do
      source = File.read!(Path.join(@lib, "nebu/matrix/room/power_level.ex"))
      refute source =~ "Not evaluated anywhere"
      refute source =~ "no redaction route"
    end
  end

  # ═══ D5: the room-version guard ═════════════════════════════════════════════════════

  describe "D5 - Room.Server.redaction_event/6 is keyed by the room version" do
    test "version \"10\": the v10 PDU, a top-level redacts, the client content without a redacts key, a message event (state_key nil)" do
      assert {:ok, event} = call(Server, :redaction_event, ["10", "!r:s", "@mod:s", "$target", %{"reason" => "r", "redacts" => "$evil"}, 1_700_000_000_000])

      assert event == %{
               "room_id" => "!r:s",
               "type" => @redaction,
               "state_key" => nil,
               "sender" => "@mod:s",
               "content" => %{"reason" => "r"},
               "redacts" => "$target",
               "origin_server_ts" => 1_700_000_000_000
             }
    end

    for version <- ["11", "12", "9", "", "10.0"] do
      test "version #{inspect(version)} is refused: {:error, :unsupported_room_version} (until a v11 story stores content.redacts)" do
        assert {:error, :unsupported_room_version} = call(Server, :redaction_event, [unquote(version), "!r:s", "@mod:s", "$t", %{}, 1])
      end
    end
  end

  # ═══ the redaction writer on a fake db (D1, D2, D7, D9) ═══════════════════════════════

  describe "Room.Server.redact/5 - the decision order of D2" do
    test "a non-member with a cached txn key is :sender_not_joined (never the cached event id)" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      key = {room, user("n"), "t1"}
      :ets.insert(:NebuTxnDedup, {key, "$cached"})
      on_exit(fn -> :ets.delete(:NebuTxnDedup, key) end)

      assert {:error, :sender_not_joined} = redact(room, elem(key, 1), put_event(room, admin), %{}, key)
    end

    test "a member below events[m.room.redaction] with a cached txn key is :forbidden (never the cached event id)" do
      admin = user("a")
      low = user("l")
      room = room_with(admin, [low], levels(%{low => 5}, %{"events" => %{"m.room.power_levels" => 50, @redaction => 10}}))
      key = {room, low, "t1"}
      :ets.insert(:NebuTxnDedup, {key, "$cached"})
      on_exit(fn -> :ets.delete(:NebuTxnDedup, key) end)

      assert {:error, :forbidden} = redact(room, low, put_event(room, admin), %{}, key)
    end

    test "idempotency comes BEFORE the target: a cached txn key is answered with its id although the target is unknown, the target is not even read" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      key = {room, admin, "t1"}
      :ets.insert(:NebuTxnDedup, {key, "$cached"})
      on_exit(fn -> :ets.delete(:NebuTxnDedup, key) end)

      assert {:ok, "$cached", %{replayed: true}} = redact(room, admin, "$ghost", %{}, key)

      assert calls(:fetch_event) == 0
      assert redaction_applies() == []
    end

    test "the target comes before the redact level: an unknown target is :target_not_found even for a user below redact" do
      admin = user("a")
      member = user("m")
      room = room_with(admin, [member], levels(%{}))
      assert {:error, :target_not_found} = redact(room, member, "$ghost")
      assert redaction_applies() == []
    end

    test "a state event and a redaction event as the target: :not_redactable" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))

      assert {:error, :not_redactable} = redact(room, admin, put_event(room, admin, "m.room.topic", ""))
      assert {:error, :not_redactable} = redact(room, admin, put_event(room, admin, @redaction, nil))
      assert redaction_applies() == []
    end

    test "another sender's event needs the redact level (:insufficient_redact_level); the OWN event needs only the redaction level" do
      admin = user("a")
      bob = user("b")
      room = room_with(admin, [bob], levels(%{bob => 10}, %{"redact" => 50, "events" => %{"m.room.power_levels" => 50, @redaction => 10}}))

      assert {:error, :insufficient_redact_level} = redact(room, bob, put_event(room, admin))
      assert {:ok, _id, %{replayed: false}} = redact(room, bob, put_event(room, bob))
      assert length(redaction_applies()) == 1
    end

    test "a failing target read fails closed: {:error, :write_failed}, nothing applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)
      :ets.insert(@table, {:fetch_fail, :atdd_injected})

      assert {:error, :write_failed} = redact(room, admin, target)

      assert redaction_applies() == []
    end
  end

  describe "Room.Server.redact/5 - an already redacted target is idempotent (Kassandra #1)" do
    test "a second redaction (other key and sender) answers the EXISTING redaction's id, replayed: true; nothing applied or remembered" do
      admin = user("a")
      bob = user("b")
      room = room_with(admin, [bob], levels(%{}))
      target = put_event(room, bob)
      assert {:ok, first, %{replayed: false}} = redact(room, bob, target)
      assert length(redaction_applies()) == 1
      key = {room, admin, "other-key"}

      assert {:ok, ^first, %{replayed: true}} = redact(room, admin, target, %{"reason" => "again"}, key)

      assert length(redaction_applies()) == 1, "no second write"
      assert :ets.lookup(:NebuTxnDedup, key) == []
    end

    test "the level checks stay FIRST: a user below redact re-redacting another user's already redacted event is :insufficient_redact_level (no id leaks)" do
      admin = user("a")
      bob = user("b")
      low = user("l")
      room = room_with(admin, [bob, low], levels(%{}))
      target = put_event(room, bob)
      assert {:ok, _first, _} = redact(room, admin, target)

      assert {:error, :insufficient_redact_level} = redact(room, low, target)
    end

    test "a failing lookup is {:error, :write_failed}; a db module without redactions_for/1 is :unsupported_db_module; nothing applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)
      :ets.insert(@table, {:redactions_fail, :atdd_injected})

      assert {:error, :write_failed} = redact(room, admin, target)
      assert redaction_applies() == []

      :ets.delete(@table, :redactions_fail)
      use_db(NoLookupDB)
      assert {:error, :unsupported_db_module} = redact(room, admin, target)
      assert redaction_applies() == []
    end
  end

  describe "Room.Server.redact/5 - the write (D1, D9)" do
    test "success: {:ok, id, %{replayed: false, target_sender: author}}; ONE apply_redaction/2 with the v10 PDU; never insert_event/1; the ETS entry and the broadcast follow the commit" do
      admin = user("a")
      bob = user("b")
      room = room_with(admin, [bob], levels(%{}))
      target = put_event(room, bob)
      key = {room, admin, "k1"}
      on_exit(fn -> :ets.delete(:NebuTxnDedup, key) end)
      :ok = :pg.join("room:#{room}", self())

      assert {:ok, id, %{replayed: false, target_sender: author}} = redact(room, admin, target, %{"reason" => "r"}, key)

      assert author == bob
      assert [{^room, event}] = redaction_applies()
      assert event["event_id"] == id and event["type"] == @redaction and event["sender"] == admin and event["room_id"] == room
      assert event["redacts"] == target, "the target is the top-level key of the stored event"
      assert event["content"] == %{"reason" => "r"}
      assert event["state_key"] == nil, "a redaction is a message event"
      assert is_binary(get_in(event, ["signatures", "nebu"]))
      assert calls(:insert_event) == 0, "never a fallback to insert_event/1"
      assert :ets.lookup(:NebuTxnDedup, key) == [{key, id}]
      assert_receive {:new_event, %{"event_id" => ^id, "type" => @redaction}}, 1_000
    end

    test "a failing apply: {:error, :write_failed}; no ETS entry, no broadcast; the retry with a healthy db succeeds and IS broadcast (positive control)" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)
      key = {room, admin, "k1"}
      on_exit(fn -> :ets.delete(:NebuTxnDedup, key) end)
      :ok = :pg.join("room:#{room}", self())
      :ets.insert(@table, {:apply_fail, :atdd_injected})

      assert {:error, :write_failed} = redact(room, admin, target, %{}, key)

      assert :ets.lookup(:NebuTxnDedup, key) == []
      refute_receive {:new_event, _}, 100
      :ets.delete(@table, :apply_fail)
      assert {:ok, id, %{replayed: false}} = redact(room, admin, target, %{}, key)
      assert_receive {:new_event, %{"event_id" => ^id}}, 1_000
    end

    test "an archived room: the db answer {:error, :room_archived} is passed on, nothing remembered" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)
      :ets.insert(@table, {{:status, room}, "archived"})
      key = {room, admin, "k1"}

      assert {:error, :room_archived} = redact(room, admin, target, %{}, key)

      assert :ets.lookup(:NebuTxnDedup, key) == []
    end

    test "AC6 (b): a db module without apply_redaction/2 is refused (:unsupported_db_module), insert_event/1 is never used" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)
      use_db(NoRedactionDB)

      assert {:error, :unsupported_db_module} = redact(room, admin, target)

      assert calls(:insert_event) == 0
      assert redaction_applies() == []
    end

    test "a content that makes the signed event exceed 65 536 bytes: {:error, :event_too_large}, nothing applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)

      assert {:error, :event_too_large} = redact(room, admin, target, %{"x" => String.duplicate("a", 70_000)})

      assert redaction_applies() == []
    end
  end

  describe "AC4 (e) - Room.Server.send_event/6 refuses m.room.redaction (no second writer)" do
    test "a joined member sending the type directly: {:error, :forbidden}, nothing written, nothing remembered" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)

      assert {:error, :forbidden} = Server.send_event(room, admin, @redaction, %{"redacts" => target}, "t1")

      assert calls(:insert_event) == 0
      assert redaction_applies() == []
      assert :ets.lookup(:NebuTxnDedup, {room, admin, {:send, @redaction, "t1"}}) == []
    end

    test "positive control: an ordinary message of the same member is written; its txn key includes the event type (Kassandra #5)" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      assert {:ok, id} = Server.send_event(room, admin, "m.room.message", %{"body" => "x"}, "t2")
      assert calls(:insert_event) == 1
      key = {room, admin, {:send, "m.room.message", "t2"}}
      assert :ets.lookup(:NebuTxnDedup, key) == [{key, id}]
      assert Server.send_event(room, admin, "m.custom", %{"body" => "y"}, "t2") != {:ok, id}, "the same txn id of ANOTHER type is a new event"
    end
  end

  # ═══ the state writer on a fake db (D8, D11) ═══════════════════════════════════════════

  describe "Room.Server.write_state/5 - the decision order of D8" do
    test "a non-member: :sender_not_joined; below the level: :insufficient_level; another user's @ key: :foreign_user_key; nothing applied" do
      admin = user("a")
      low = user("l")
      room = room_with(admin, [low], levels(%{}))

      assert {:error, :sender_not_joined} = write_state(room, user("n"), {"m.room.topic", ""}, %{"topic" => "x"})
      assert {:error, :insufficient_level} = write_state(room, low, {"m.room.topic", ""}, %{"topic" => "x"})
      assert {:error, :foreign_user_key} = write_state(room, admin, {"m.room.topic", low}, %{"topic" => "x"})

      assert state_applies() == []
      assert calls(:insert_event) == 0
    end

    test "the sender's OWN @ key is allowed" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      assert {:ok, _id} = write_state(room, admin, {"m.room.topic", admin}, %{"topic" => "x"})
    end

    test "a user whose events[type] is raised above his level is refused although state_default would allow him" do
      admin = user("a")
      mid = user("m")
      room = room_with(admin, [mid], levels(%{mid => 50}, %{"events" => %{"m.room.power_levels" => 50, "m.room.topic" => 100}}))
      assert {:error, :insufficient_level} = write_state(room, mid, {"m.room.topic", ""}, %{"topic" => "x"})
    end
  end

  describe "Room.Server.write_state/5 - the write, the stamp (AC7 (f))" do
    test "success: {:ok, id}; ONE apply_state_change/3 with the signed event; never insert_event/1; the broadcast follows the commit" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      :ok = :pg.join("room:#{room}", self())

      assert {:ok, id} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "hello"})

      assert [{^room, event, opts}] = state_applies()
      assert event["event_id"] == id and event["type"] == "m.room.topic" and event["state_key"] == "" and event["sender"] == admin
      assert event["content"] == %{"topic" => "hello"}
      assert is_binary(get_in(event, ["signatures", "nebu"]))
      assert opts[:room_name] == nil, "only m.room.name with the empty state key carries rooms.name"
      assert calls(:insert_event) == 0
      assert_receive {:new_event, %{"event_id" => ^id, "type" => "m.room.topic"}}, 1_000
    end

    test "the stamp is the latest slot event's ts + 1 (60 s ahead of the clock, exact), read through the db module on EVERY call" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      ahead = System.system_time(:millisecond) + 60_000
      slot_identity(room, "m.room.topic", "", ahead)

      assert {:ok, first} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "one"})
      assert {:ok, second} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "two"})

      stamps = for {_room, e, _opts} <- state_applies(), do: {e["event_id"], e["origin_server_ts"]}
      assert Enum.sort_by(stamps, &elem(&1, 1)) == [{first, ahead + 1}, {second, ahead + 2}], "each write follows the slot (the fake moved it), no cached stamp"
      assert calls(:latest_state_identity) == 2
    end

    test "not_before lifts the stamp above the clock and the slot; an empty slot is stamped now" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      before = System.system_time(:millisecond)

      assert {:ok, _} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "now"})
      [{_, e, _}] = state_applies()
      assert e["origin_server_ts"] >= before and e["origin_server_ts"] <= System.system_time(:millisecond)

      floor = System.system_time(:millisecond) + 120_000
      assert {:ok, id} = write_state(room, admin, {"m.room.name", ""}, %{"name" => "x"}, not_before: floor)
      assert [ts] = for({_, ev, _} <- state_applies(), ev["event_id"] == id, do: ev["origin_server_ts"])
      assert ts == floor
    end

    test "m.room.name with the empty state key hands rooms.name to the transaction (room_name:), also for a content without a name (\"\"); another state key does not" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))

      assert {:ok, _} = write_state(room, admin, {"m.room.name", ""}, %{"name" => "Renamed"})
      assert {:ok, _} = write_state(room, admin, {"m.room.name", ""}, %{})
      assert {:ok, _} = write_state(room, admin, {"m.room.name", "x"}, %{"name" => "Other slot"})

      opts_of = fn key, content -> for({_, e, opts} <- state_applies(), e["state_key"] == key and e["content"] == content, do: opts) end
      assert [renamed] = opts_of.("", %{"name" => "Renamed"})
      assert Keyword.get(renamed, :room_name) == "Renamed"
      assert [nameless] = opts_of.("", %{})
      assert Keyword.get(nameless, :room_name) == ""
      assert [other_slot] = opts_of.("x", %{"name" => "Other slot"})
      refute Keyword.has_key?(other_slot, :room_name)
    end

    test "a failing apply: {:error, :write_failed}; no broadcast; the retry succeeds and is broadcast (positive control)" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      :ok = :pg.join("room:#{room}", self())
      :ets.insert(@table, {:apply_fail, :atdd_injected})

      assert {:error, :write_failed} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})

      refute_receive {:new_event, _}, 100
      :ets.delete(@table, :apply_fail)
      assert {:ok, id} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})
      assert_receive {:new_event, %{"event_id" => ^id}}, 1_000
    end

    test "a failing slot read fails closed: {:error, :write_failed}, nothing applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      :ets.insert(@table, {:latest_fail, :atdd_injected})

      assert {:error, :write_failed} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})

      assert state_applies() == []
      assert calls(:insert_event) == 0
    end

    test "an archived room: {:error, :room_archived}" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      :ets.insert(@table, {{:status, room}, "archived"})
      assert {:error, :room_archived} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})
    end

    test "a content that makes the signed event exceed 65 536 bytes: {:error, :event_too_large}, nothing applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      assert {:error, :event_too_large} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => String.duplicate("a", 70_000)})
      assert state_applies() == []
    end

    test "the process keeps no stamp cache: after a kill and restart the next write follows the slot of the database again" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      ahead = System.system_time(:millisecond) + 60_000
      slot_identity(room, "m.room.topic", "", ahead)
      assert {:ok, _} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "one"})

      kill_and_restart!(room)

      assert {:ok, id} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "two"})
      assert Enum.find(state_applies(), fn {_, e, _} -> e["event_id"] == id end) |> elem(1) |> Map.fetch!("origin_server_ts") == ahead + 2
    end
  end

  describe "AC7 (f) - a db module without the new functions is refused, never served by the caller-side insert" do
    test "without apply_state_change/3: {:error, :unsupported_db_module}, insert_event/1 is not used, nothing is applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      use_db(NoStateChangeDB)

      assert {:error, :unsupported_db_module} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})

      assert calls(:insert_event) == 0
      assert state_applies() == []
    end

    test "without latest_state_identity/3: {:error, :unsupported_db_module}, insert_event/1 is not used, nothing is applied" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      use_db(NoSlotReadDB)

      assert {:error, :unsupported_db_module} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})

      assert calls(:insert_event) == 0
      assert state_applies() == []
    end

    test "a suite that predates the story (no atomic writer, no slot read) is refused on both writers" do
      admin = user("a")
      room = room_with(admin, [], levels(%{}))
      target = put_event(room, admin)
      use_db(OldDB)

      assert {:error, :unsupported_db_module} = write_state(room, admin, {"m.room.topic", ""}, %{"topic" => "x"})
      assert {:error, :unsupported_db_module} = redact(room, admin, target)
    end
  end

  describe "D11 - the tombstone mode: the level is max(events[m.room.tombstone] else state_default, 100)" do
    @tombstone {"m.room.tombstone", ""}
    @tombstone_content %{"body" => "This room has been replaced", "replacement_room" => "!new:test.local"}

    test "at 100 with the tombstone level 50: allowed; at 60 with the tombstone level 50: refused (the floor of 100)" do
      admin = user("a")
      sixty = user("s")
      room = room_with(admin, [sixty], levels(%{sixty => 60}, %{"events" => %{"m.room.power_levels" => 50, "m.room.tombstone" => 50}}))

      assert {:error, :insufficient_level} = write_state(room, sixty, @tombstone, @tombstone_content, mode: :tombstone)
      assert {:ok, _id} = write_state(room, admin, @tombstone, @tombstone_content, mode: :tombstone)
      assert length(state_applies()) == 1
    end

    test "at 100 with the tombstone level 150: refused; at 150: allowed" do
      admin = user("a")
      top = user("t")
      room = room_with(admin, [top], levels(%{top => 150}, %{"events" => %{"m.room.power_levels" => 50, "m.room.tombstone" => 150}}))

      assert {:error, :insufficient_level} = write_state(room, admin, @tombstone, @tombstone_content, mode: :tombstone)
      assert {:ok, _id} = write_state(room, top, @tombstone, @tombstone_content, mode: :tombstone)
    end

    test "the client mode needs only the tombstone level of the room (no floor): a user at 60 with the tombstone level 50 may" do
      admin = user("a")
      sixty = user("s")
      room = room_with(admin, [sixty], levels(%{sixty => 60}, %{"events" => %{"m.room.power_levels" => 50, "m.room.tombstone" => 50}}))
      assert {:ok, _id} = write_state(room, sixty, @tombstone, @tombstone_content)
    end

    test "membership first: a non-member at 100 is :sender_not_joined" do
      admin = user("a")
      ghost = user("g")
      room = room_with(admin, [], levels(%{ghost => 100}))
      assert {:error, :sender_not_joined} = write_state(room, ghost, @tombstone, @tombstone_content, mode: :tombstone)
    end
  end

  # ═══ AC12: the source pins ═════════════════════════════════════════════════════════════

  # every lib file as {relative path, AST}; the AST has no comments, docs are strings
  defp lib_asts do
    for file <- Path.wildcard(Path.join(@lib, "**/*.ex")), do: {Path.relative_to(file, @lib), file |> File.read!() |> Code.string_to_quoted!()}
  end

  # every map literal of an AST as its list of `{key, value_ast}` pairs
  defp map_literals(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:%{}, _meta, pairs} = node, acc when is_list(pairs) -> {node, [pairs | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp has_pair?(pairs, key, value), do: Enum.any?(pairs, &(&1 == {key, value}))
  defp has_key?(pairs, key), do: Enum.any?(pairs, &match?({^key, _}, &1))

  # the names of the functions (def / defp) whose body contains a local call of one of `names`
  defp functions_calling(ast, names) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          name = head |> function_name()
          called? = body |> Macro.prewalk(false, fn {n, _m, args} = sub, found when is_atom(n) and is_list(args) -> {sub, found or n in names}; sub, found -> {sub, found} end) |> elem(1)
          {node, if(called?, do: [name | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.uniq() |> Enum.sort()
  end

  # a remote call `mod.name(..)` / `Mod.name(..)` or the atom literal (`commit_atomic(room, :name, ..)`, `apply(mod, :name, ..)`); a LOCAL function of the same name is no hit
  defp mentions_remote?(ast, name) do
    ast
    |> Macro.prewalk(false, fn
      {{:., _, [_mod, ^name]}, _meta, _args} = node, _found -> {node, true}
      ^name = node, _found -> {node, true}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  defp mentions_remote_call?(ast, name) do
    ast |> Macro.prewalk(false, fn {{:., _, [_mod, ^name]}, _meta, _args} = n, _found -> {n, true}; n, found -> {n, found} end) |> elem(1)
  end

  defp mentions_atom?(ast, atom), do: ast |> Macro.prewalk(false, fn ^atom = n, _ -> {n, true}; {^atom, _, _} = n, _ -> {n, true}; n, f -> {n, f} end) |> elem(1)

  defp mentions_alias?(ast, parts), do: ast |> Macro.prewalk(false, fn {:__aliases__, _, ^parts} = n, _ -> {n, true}; n, f -> {n, f} end) |> elem(1)

  # a PUBLIC `def name(...)` of the file
  defp defines_public?(ast, name) do
    ast
    |> Macro.prewalk(false, fn
      {:def, _meta, [head | _]} = node, found -> {node, found or function_name(head) == name}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  defp function_name({:when, _, [head | _]}), do: function_name(head)
  defp function_name({name, _, _}), do: name

  describe "AC12 (a) - one redaction writer" do
    test "no map literal outside Room.Server builds a stored redaction (type m.room.redaction or a top-level redacts together with a state_key)" do
      offenders =
        for {file, ast} <- lib_asts(),
            file != "nebu/matrix/room/server.ex",
            pairs <- map_literals(ast),
            has_key?(pairs, "state_key") and (has_pair?(pairs, "type", @redaction) or has_key?(pairs, "redacts")),
            do: file

      assert offenders == []
    end

    test "Room.Server builds it (positive control: the pin sees the builder)" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == "nebu/matrix/room/server.ex" end)
      assert Enum.any?(map_literals(ast), &(has_key?(&1, "state_key") and has_pair?(&1, "type", @redaction) and has_key?(&1, "redacts")))
    end

    test "the public apply_redaction/2 is defined in Room.DB only and called (remote call or atom) only by Room.Server" do
      defining = for {file, ast} <- lib_asts(), defines_public?(ast, :apply_redaction), do: file
      referencing = for {file, ast} <- lib_asts(), mentions_remote?(ast, :apply_redaction), do: file

      assert defining == ["nebu/matrix/room/db.ex"]
      assert referencing == ["nebu/matrix/room/server.ex"]
      db = lib_asts() |> Enum.find(fn {file, _} -> file == "nebu/matrix/room/db.ex" end) |> elem(1)
      assert :apply_redaction in functions_calling(db, [:insert_event])
    end
  end

  describe "AC12 (b) - who may call the caller-side emit_state_event/5 / emit_state_event_at/6" do
    @dispatcher "nebu/matrix/event_dispatcher/server.ex"
    # today's createRoom writers (preset, name, topic, derived alias, explicit alias, initial_state), the wrapper itself, the upgrade (the NEW room's m.room.create)
    # and the state copy into the NEW room
    @emitters ~w(emit_preset_events emit_name_event emit_topic_event try_register_alias register_explicit_alias apply_initial_state emit_state_event upgrade_room copy_state_events)a

    test "exactly the createRoom writers and the upgrade's NEW-room writers call them; set_room_state/2 does not" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == @dispatcher end)
      callers = functions_calling(ast, [:emit_state_event, :emit_state_event_at])

      assert callers -- @emitters == [], "a new caller of the caller-side writer: #{inspect(callers -- @emitters)}"
      refute :set_room_state in callers, "PUT state is decided and written by Room.Server.write_state/5"
    end

    test "no caller-side emit passes the tombstone type (the tombstone is the room process' write)" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == @dispatcher end)

      emits_tombstone? =
        ast
        |> Macro.prewalk(false, fn
          {name, _meta, args} = node, found when name in [:emit_state_event, :emit_state_event_at] and is_list(args) -> {node, found or "m.room.tombstone" in args}
          node, found -> {node, found}
        end)
        |> elem(1)

      refute emits_tombstone?
    end

    test "the dispatcher calls Room.Server.write_state/5 in the client mode (PUT state) and in the tombstone mode (the upgrade)" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == @dispatcher end)

      modes =
        ast
        |> Macro.prewalk([], fn
          {{:., _, [receiver, :write_state]}, _meta, args} = node, acc -> {node, if(writer_receiver?(receiver), do: [mode_of(args) | acc], else: acc)}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      # the client mode is the default of write_state/5: an explicit `mode: :client` and a call without a mode are both fine; the tombstone mode must be explicit
      assert (:client in modes or nil in modes) and :tombstone in modes, "write_state/5 modes in the dispatcher: #{inspect(modes)}"
      refute :internal in modes
    end
  end

  # the receiver of a writer call: `Nebu.Matrix.Room.Server` or the registry seam `room_registry_module()` (AC12 (e): its default IS Room.Server)
  defp writer_receiver?({:__aliases__, _, aliases}), do: List.last(aliases) == :Server
  defp writer_receiver?({:room_registry_module, _, _}), do: true
  defp writer_receiver?(_other), do: false

  defp mode_of(args), do: args |> List.last() |> then(fn kw when is_list(kw) -> Keyword.get(kw, :mode); _other -> nil end)

  describe "AC12 (e) - the fakes of every suite that reaches the new writers" do
    # (test review M-15) the fake-suite regexes over other test files were dropped as brittle: the seam below is the mandatory part (STORY-11), the fakes of the
    # fake-registry and fake-db suites are proven by those suites themselves (they fail without `write_state/5`, `apply_state_change/3`, `latest_state_identity/3`)
    test "the dispatcher reaches write_state/5 and redact/5 ONLY through the seam room_registry_module/0 (default Nebu.Matrix.Room.Server)" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == "nebu/matrix/event_dispatcher/server.ex" end)

      aliased_calls =
        ast
        |> Macro.prewalk([], fn
          {{:., _, [{:__aliases__, _, aliases}, fun]}, _meta, _args} = node, acc when fun in [:write_state, :redact] -> {node, if(List.last(aliases) == :Server, do: [fun | acc], else: acc)}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      assert aliased_calls == [], "a writer call that names Nebu.Matrix.Room.Server directly bypasses the seam: #{inspect(aliased_calls)}"

      seam_calls =
        ast
        |> Macro.prewalk([], fn
          {{:., _, [{:room_registry_module, _, []}, fun]}, _meta, _args} = node, acc when fun in [:write_state, :redact] -> {node, [fun | acc]}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      assert :write_state in seam_calls and :redact in seam_calls

      source = File.read!(Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex"))
      assert source =~ ~r/defp room_registry_module do\s+Application\.get_env\(:event_dispatcher, :room_registry_module, Nebu\.Matrix\.Room\.Server\)/
    end
  end

  describe "AC12 (f) - callers of write_state/5 and the fail-closed prune lookup (code review I1, M1)" do
    test "write_state/5 is called (remote call) ONLY by the dispatcher; Room.Server defines it, nobody else in lib calls it" do
      callers = for {file, ast} <- lib_asts(), mentions_remote_call?(ast, :write_state), do: file
      assert callers == ["nebu/matrix/event_dispatcher/server.ex"]
    end

    test "the dispatcher's prune lookup compares with Nebu.Matrix.Room.DB and raises for it: the real module is never served unpruned" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == "nebu/matrix/event_dispatcher/server.ex" end)

      strict_lookup? =
        ast
        |> Macro.prewalk(false, fn
          {kind, _meta, [_head, body]} = node, found when kind in [:def, :defp] ->
            {node, found or (mentions_atom?(body, :redactions_for) and mentions_alias?(body, [:Nebu, :Matrix, :Room, :DB]) and mentions_atom?(body, :raise))}

          node, found ->
            {node, found}
        end)
        |> elem(1)

      assert strict_lookup?, "a function that reads redactions_for/1 must compare the module with Nebu.Matrix.Room.DB and raise for it (fail closed)"
    end
  end

  describe "cluster safety (D8, fe) - the writers broadcast through :pg.get_members/1" do
    test "in Room.Server no redaction / state-writer function broadcasts through :pg.get_local_members/1, and :pg.get_members/1 is used", _ctx do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == "nebu/matrix/room/server.ex" end)

      callers = fn fun ->
        {_ast, found} =
          Macro.prewalk(ast, [], fn
            {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
              hit? = body |> Macro.prewalk(false, fn {{:., _, [:pg, ^fun]}, _, _} = n, _ -> {n, true}; n, f -> {n, f} end) |> elem(1)
              {node, if(hit?, do: [function_name(head) | acc], else: acc)}

            node, acc ->
              {node, acc}
          end)

        Enum.uniq(found)
      end

      local = Enum.map(callers.(:get_local_members), &to_string/1)
      assert Enum.filter(local, &(&1 =~ ~r/redact|write_state|state_write|redaction/)) == [], "node-local broadcast in a writer function: #{inspect(local)}"
      assert callers.(:get_members) != [], "the cluster-wide broadcast exists (positive control)"
    end
  end

  describe "AC12 (d) - Nebu.Matrix.Redaction is pure" do
    @forbidden_modules ~w(Ecto Postgrex GenServer Horde Logger Application Process Task Agent Registry Repo DB Server RoomSupervisor)a

    test "it references no database, process, logger or application module and no :ets / :pg" do
      {_file, ast} = Enum.find(lib_asts(), fn {file, _} -> file == "nebu/matrix/redaction.ex" end)

      {_ast, used} =
        Macro.prewalk(ast, [], fn
          {:__aliases__, _, parts} = node, acc -> {node, parts ++ acc}
          {{:., _, [mod, _fun]}, _, _args} = node, acc when is_atom(mod) -> {node, [mod | acc]}
          node, acc -> {node, acc}
        end)

      assert Enum.filter(used, &(&1 in @forbidden_modules or &1 in [:ets, :pg, :persistent_term])) == []
    end
  end
end
