defmodule Nebu.Matrix.Room.PowerLevelsFixCycle1UnitTest do
  @moduledoc """
  Story `power-levels-enforcement`, fix cycle 1 (code review cycle 0 and Kassandra cycle 0), UNIT half (no PostgreSQL; the real `Room.Server`
  under Horde on a fake db module):

    * review M1 / Kassandra L-2: v10 rule 4 ("no previous levels event: allow") only for EMPTY levels; a room with stored levels but no
      levels event row keeps the change rules;
    * review M5: the current value of a `notifications` entry is the STORED one (no phantom `room: 50` of the normalised view);
    * review M4: the internal writer accepts the user-id grammar without the 255-byte bound and with a server-name port; the client
      writer stays strict; `valid_subset/1` drops such ids silently (pinned, documented in the scope doc);
    * review I2 / Kassandra I-4: `Http.map_error/1` passes ONLY the fixed text of a failed power-level write; one raiser in `server/lib`;
    * review M2 / Kassandra M-1: the audit metadata names only the ten v10 keys and counts the others (1000 unknown keys).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.PowerLevels
  alias Nebu.Matrix.Room.Server

  @table :power_levels_fix_cycle1_unit_db
  @lib Path.expand("../../../../lib", __DIR__)
  @pl "m.room.power_levels"

  defmodule FakeDB do
    @moduledoc false
    @table :power_levels_fix_cycle1_unit_db

    # the identity map of the real db module; a room whose column is pre-seeded starts WITHOUT a levels event identity
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

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, json, %{members: %{}, power_levels: nil}}
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

    def set_power_levels(room_id, json) do
      :ets.insert(@table, {{:power_levels, room_id}, json})
      :ok
    end

    # the real transaction: the column AND the event
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    # the read of the latest levels event: NONE (the event row is missing although the column holds levels)
    def latest_power_levels_identity(_room_id), do: {:ok, nil}

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  defmodule CapturingAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome) do
      send(Application.get_env(:nebu, :pl_fix_cycle1_audit_test), {:audit, actor, action, target_type, target_id, metadata, outcome})
      :ok
    end
  end

  setup do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])

    priors = for {app, key} <- [{:room_manager, :db_module}, {:event_dispatcher, :server_name}, {:compliance, :audit_writer}], do: {app, key, Application.fetch_env(app, key)}
    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      for {app, key, prior} <- priors do
        case prior do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      Application.delete_env(:nebu, :pl_fix_cycle1_audit_test)
      if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    end)

    :ok
  end

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp user(label), do: "@#{label}#{rand()}:test.local"

  # a running room whose column holds `content` from the start (no levels event identity), with `members` joined
  defp room_with_column(content, members) do
    room = "!plf#{rand()}:test.local"
    :ets.insert(@table, {{:room, room}, System.system_time(:millisecond)})
    :ets.insert(@table, {{:power_levels, room}, Jason.encode!(content)})
    for m <- members, do: :ets.insert(@table, {{:member, room, m}, :active})
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

  defp levels(users, extra \\ %{}) do
    Map.merge(
      %{"ban" => 50, "kick" => 50, "invite" => 0, "redact" => 50, "state_default" => 50, "events_default" => 0, "users_default" => 0, "users" => users, "events" => %{@pl => 50}},
      extra
    )
  end

  defp change(room, sender, content), do: Server.change_power_levels(room, sender, content, mode: :client)
  defp column(room), do: :ets.lookup(@table, {:power_levels, room}) |> hd() |> elem(1) |> Jason.decode!()

  # ═══ review M1 / Kassandra L-2: rule 4 only for empty levels ═══════════════════

  describe "review M1 / Kassandra L-2 - stored levels without a levels event row keep the v10 change rules" do
    test "a moderator at the gate level cannot grant above himself nor change the admin; nothing is written; a valid change passes" do
      admin = user("adm")
      mod = user("mod")
      content = levels(%{admin => 100, mod => 50})
      room = room_with_column(content, [admin, mod])

      assert Server.get_state(room).power_levels_event == nil, "precondition: no levels event identity"
      assert {:error, :grant_above_own_level} = change(room, mod, Map.put(content, "ban", 51))
      assert {:error, :grant_above_own_level} = change(room, mod, put_in(content, ["users", mod], 9_007_199_254_740_991))
      assert {:error, :target_not_lower} = change(room, mod, put_in(content, ["users", admin], 0))
      assert column(room) == content, "nothing was written"

      assert {:ok, _id, %{changed: true}} = change(room, mod, Map.put(content, "kick", 0))
      assert column(room)["kick"] == 0
    end
  end

  # ═══ review M5: notifications from the stored content ══════════════════════════

  describe "review M5 - the current notifications value is the stored one" do
    test "check_change/3: an absent notifications.room is no current value (room 0 by a sender at 10 is allowed), a stored value above him is refused" do
      s = "@s:test.local"
      current = %{"users" => %{s => 10}}

      assert PowerLevels.check_change(current, Map.put(current, "notifications", %{"room" => 0}), s) == :ok
      assert PowerLevels.check_change(current, Map.put(current, "notifications", %{"room" => 11}), s) == {:error, :grant_above_own_level}

      stored = Map.put(current, "notifications", %{"room" => 50})
      assert PowerLevels.check_change(stored, Map.put(stored, "notifications", %{"room" => 0}), s) == {:error, :above_own_level}
    end

    test "through the writer: a sender at the gate level 10 adds notifications.room 0 (written), notifications.room 50 is refused" do
      admin = user("adm")
      low = user("low")
      content = levels(%{admin => 100, low => 10}, %{"events" => %{@pl => 10}})
      room = room_with_column(content, [admin, low])
      :ok = Server.set_power_levels(room, admin, content)

      assert {:error, :grant_above_own_level} = change(room, low, Map.put(content, "notifications", %{"room" => 50}))
      assert {:ok, _id, %{changed: true}} = change(room, low, Map.put(content, "notifications", %{"room" => 0}))
      assert column(room)["notifications"] == %{"room" => 0}
    end
  end

  # ═══ review M4: the internal writer and the user-id grammar ════════════════════

  describe "review M4 - the internal writer accepts server-chosen ids without the 255-byte bound or with a port" do
    @port_id "@carol:test.local:8448"
    @long_id "@" <> String.duplicate("c", 260) <> ":test.local"

    # fix cycle 2 (Kassandra D-L1, re-pin of this cycle-1 test; was: the client writer refused the content even with both entries
    # UNCHANGED): an unchanged stored relaxed-grammar entry is accepted, an added or changed one is still refused (400 text);
    # valid_subset/1 drops such ids unless kept (the upgrader's own)
    test "both ids are written; client: unchanged kept, changed or added refused (400); valid_subset/2 keeps only kept ids" do
      admin = user("adm")
      room = room_with_column(%{}, [admin])
      content = levels(%{admin => 100, @port_id => 100, @long_id => 50})

      assert :ok = Server.set_power_levels(room, admin, content)
      assert column(room)["users"][@port_id] == 100
      assert column(room)["users"][@long_id] == 50

      assert {:error, {:invalid, "users keys must be valid user ids"}} = change(room, admin, put_in(content, ["users", @long_id], 40))
      assert {:error, {:invalid, "users keys must be valid user ids"}} = change(room, admin, put_in(content, ["users", "@new:test.local:8448"], 1))
      assert {:ok, _id, %{changed: true}} = change(room, admin, Map.put(content, "kick", 10))
      assert column(room)["users"][@port_id] == 100 and column(room)["kick"] == 10

      assert PowerLevels.valid_subset(content)["users"] == %{admin => 100}
      assert PowerLevels.valid_subset(content, [@port_id])["users"] == %{admin => 100, @port_id => 100}
    end

    test "the grammar stays a grammar: a key without @ or with a space is refused by the internal writer too" do
      admin = user("adm")
      room = room_with_column(%{}, [admin])

      for bad <- ["carol:test.local", "@ca rol:test.local", "@carol:test.local:port"] do
        assert {:error, {:invalid, _}} = Server.set_power_levels(room, admin, levels(%{admin => 100, bad => 1})), bad
      end
    end
  end

  # ═══ review I2 / Kassandra I-4: the M_UNKNOWN pass-through ═════════════════════

  describe "review I2 - Http.map_error/1 passes only the fixed text of a failed power-level write" do
    test "an internal error with errcode M_UNKNOWN and another message is the generic 500; the fixed text passes" do
      other = Nebu.Matrix.Http.call_core(fn -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), errcode: "M_UNKNOWN", message: "db detail @x:y" end)
      assert other == {:error, {500, "M_UNKNOWN", "Internal server error"}}

      text = Nebu.Matrix.Http.power_levels_not_changed_text()
      fixed = Nebu.Matrix.Http.call_core(fn -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), errcode: "M_UNKNOWN", message: text end)
      assert fixed == {:error, {500, "M_UNKNOWN", "The power levels could not be changed"}}
    end

    test "server/lib raises errcode M_UNKNOWN in exactly one place: the power-level helper of the dispatcher, with the constant" do
      hits =
        for f <- Path.wildcard(Path.join(@lib, "**/*.ex")), {line, n} <- f |> File.read!() |> String.split("\n") |> Enum.with_index(1), line =~ ~s(errcode: "M_UNKNOWN"),
            do: {Path.relative_to(f, @lib), n, line}

      assert [{"nebu/matrix/event_dispatcher/server.ex", _n, line}] = hits
      assert line =~ "Nebu.Matrix.Http.power_levels_not_changed_text()"
    end
  end

  # ═══ review M2 / Kassandra M-1: bounded audit metadata ═════════════════════════

  describe "review M2 / Kassandra M-1 - the audit row names only the ten v10 keys" do
    test "1000 altered unknown top-level keys are counted, never named: exactly changed_keys / users_* / other_keys_changed_count, a small row" do
      admin = user("adm")
      room = room_with_column(%{}, [admin])
      content = levels(%{admin => 100})
      :ok = Server.set_power_levels(room, admin, content)
      Application.put_env(:compliance, :audit_writer, CapturingAudit)
      Application.put_env(:nebu, :pl_fix_cycle1_audit_test, self())

      unknown = for n <- 1..1000, into: %{}, do: {"x.client.key#{n}", n}
      new = content |> Map.merge(unknown) |> Map.put("events_default", 5)
      req = %Core.SetRoomStateRequest{room_id: room, sender_id: admin, event_type: @pl, state_key: "", content_json: Jason.encode!(new)}

      assert {:ok, %Core.SetRoomStateResponse{}} = Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_room_state(req, Nebu.Matrix.Http.stream(admin)) end)

      assert_receive {:audit, ^admin, "room_power_levels_changed", "room", ^room, metadata, "success"}
      assert metadata == %{"changed_keys" => ["events_default"], "users_changed" => [], "users_changed_count" => 0, "other_keys_changed_count" => 1000}
      assert byte_size(Jason.encode!(metadata)) < 200
      refute Jason.encode!(metadata) =~ "x.client.key"
    end

    test "without unknown keys the metadata keeps its three keys (no other_keys_changed_count)" do
      admin = user("adm")
      room = room_with_column(%{}, [admin])
      content = levels(%{admin => 100})
      :ok = Server.set_power_levels(room, admin, content)
      Application.put_env(:compliance, :audit_writer, CapturingAudit)
      Application.put_env(:nebu, :pl_fix_cycle1_audit_test, self())
      req = %Core.SetRoomStateRequest{room_id: room, sender_id: admin, event_type: @pl, state_key: "", content_json: Jason.encode!(Map.put(content, "kick", 10))}

      assert {:ok, _} = Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_room_state(req, Nebu.Matrix.Http.stream(admin)) end)
      assert_receive {:audit, ^admin, "room_power_levels_changed", "room", ^room, %{"changed_keys" => ["kick"]} = metadata, "success"}
      assert Map.keys(metadata) |> Enum.sort() == ["changed_keys", "users_changed", "users_changed_count"]
    end
  end

  # ═══ fix cycle 3, Kassandra C2-L1: strict comparisons (100.0 is not 100) ═══════

  describe "fix cycle 3 (Kassandra C2-L1) - a stored legacy float is not the integer of the same value" do
    test "same_json?/2 is strict at every depth; identical values of the same types are equal" do
      assert PowerLevels.same_json?(%{"a" => %{"b" => [1, "x", nil]}}, %{"a" => %{"b" => [1, "x", nil]}})
      refute PowerLevels.same_json?(100.0, 100)
      refute PowerLevels.same_json?(%{"users" => %{"@a:s" => 100.0}}, %{"users" => %{"@a:s" => 100}})
      refute PowerLevels.same_json?(%{"x" => [1.0]}, %{"x" => [1]})
      refute PowerLevels.same_json?(%{"a" => 1}, %{"a" => 1, "b" => 2})
    end

    test "check_change/3: replacing a stored float by the integer is an alteration (a relaxed key, a strict key, a threshold key)" do
      s = "@s:test.local"

      for {current, new} <- [
            {%{"users" => %{s => 50, "@x:test.local:8448" => 100.0}}, %{"users" => %{s => 50, "@x:test.local:8448" => 100}}},
            {%{"users" => %{s => 50, "@u:test.local" => 100.0}}, %{"users" => %{s => 50, "@u:test.local" => 100}}},
            {%{"ban" => 75.0, "users" => %{s => 50}}, %{"ban" => 75, "users" => %{s => 50}}}
          ] do
        assert PowerLevels.check_change(current, new, s) == {:error, :grant_above_own_level}, inspect(current)
      end
    end

    test "through the writer: a moderator at 50 cannot raise a stored float 100.0 to the integer 100, with or without an extra key" do
      admin = user("adm")
      mod = user("mod")
      strict_id = "@u#{rand()}:test.local"
      stored = levels(%{admin => 100, mod => 50, @port_id => 100.0, strict_id => 100.0})
      room = room_with_column(stored, [admin, mod])
      integer = fn content, id -> put_in(content, ["users", id], 100) end

      # the relaxed-grammar id: 100.0 -> 100 is a CHANGED entry, refused by the strict key rule before the change rules
      for extra <- [%{}, %{"x_extra" => 1}] do
        assert {:error, {:invalid, "users keys must be valid user ids"}} = change(room, mod, stored |> integer.(@port_id) |> Map.merge(extra))
      end

      # a strict id: the change rules see the alteration (rule 7: the new 100 is above the moderator's 50)
      assert column(room) == stored, "nothing was written"
      without_port = update_in(stored, ["users"], &Map.delete(&1, @port_id))
      room2 = room_with_column(without_port, [admin, mod])

      for extra <- [%{}, %{"x_extra" => 1}] do
        assert {:error, :grant_above_own_level} = change(room2, mod, without_port |> integer.(strict_id) |> Map.merge(extra))
      end

      assert column(room2) == without_port, "nothing was written"
    end

    test "removing a stored relaxed-grammar entry is allowed (only added or changed ones are strict)" do
      admin = user("adm")
      room = room_with_column(%{}, [admin])
      content = levels(%{admin => 100, @port_id => 10})
      :ok = Server.set_power_levels(room, admin, content)

      assert {:ok, _id, %{changed: true}} = change(room, admin, update_in(content, ["users"], &Map.delete(&1, @port_id)))
      refute Map.has_key?(column(room)["users"], @port_id)
    end

    test "an identical content of the same types is still the idempotent no-op" do
      admin = user("adm")
      room = room_with_column(%{}, [admin])
      content = levels(%{admin => 100}, %{"x_custom" => %{"n" => [1, 2.5]}})
      :ok = Server.set_power_levels(room, admin, content)

      assert {:ok, id, %{changed: false}} = change(room, admin, content)
      assert {^id, _ts, ^admin} = Server.get_state(room).power_levels_event
    end
  end
end
