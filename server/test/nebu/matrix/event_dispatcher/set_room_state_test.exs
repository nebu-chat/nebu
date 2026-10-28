defmodule Nebu.Matrix.EventDispatcher.SetRoomStateTest do
  use ExUnit.Case, async: false

  # ─── Spaces S2 — generic state-event write (set_room_state/2) ─────────────────
  #
  # Story: spaces-elixir / s2-space-state-events.
  #
  # Backend unit tests for the generic Matrix state PUT handler. They drive
  # Server.set_room_state/2 directly, injecting a FakeRoomRegistry (room state +
  # power levels) and a FakeDB (captures emitted events + name writes) so NO live
  # PostgreSQL / Horde is needed.
  #
  # Covers (Acceptance Tests 2,3,4,5,6):
  #   - allowlist: m.space.child/parent + the room-state allowlist accepted;
  #     m.room.member / m.room.create → 403 (SECURITY). m.room.power_levels left the
  #     forbidden list with story power-levels-enforcement: it is written by the
  #     room-process power-level writer (power_levels_http_test.exs pins that route).
  #   - power-level check: sender PL >= state_default; non-member / under-PL → 403.
  #   - m.space.parent: parent must exist (404) and sender must be a member of it (403).
  #   - m.room.name via generic PUT also persists rooms.name (update_room_name).
  #   - empty content (unlink) is accepted.
  #   - server-authoritative top-level fields (sender/type/room_id) built server-side.
  #
  # async: false — Application.put_env, :pg and :persistent_term are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @signing_key_seed :crypto.strong_rand_bytes(32)

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # FakeRoomRegistry: get_state/1 returns the room's in-memory state from ETS.
  # Rooms registered via register_room/3 in the tests; unknown rooms raise :noproc
  # (mirrors a not-started Room GenServer so the parent-space "non-existent" path
  # can be exercised through the DB existence check, not the registry).
  defmodule FakeRoomRegistry do
    def get_state(room_id) do
      case :ets.lookup(:set_room_state_reg, {:room, room_id}) do
        [{_, state}] -> state
        [] -> exit({:noproc, {GenServer, :call, [room_id]}})
      end
    end

    # story state-writer-redaction (D8, AC12 (e)): the room-process writer behind the registry seam. The fake takes the decision of the dispatcher's snapshot
    # pre-check as given and models what the room process writes in ONE transaction: the event and, for m.room.name with the empty state key, rooms.name
    # (a failing name write fails the write, it is no longer non-fatal).
    def write_state(room_id, sender, {type, state_key}, content, _opts) do
      alias Nebu.Matrix.EventDispatcher.SetRoomStateTest.FakeDB

      event = %{
        "event_id" => "$fake" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "room_id" => room_id,
        "type" => type,
        "state_key" => state_key,
        "sender" => sender,
        "content" => content,
        "origin_server_ts" => System.system_time(:millisecond)
      }

      with :ok <- FakeDB.insert_event(event),
           :ok <- if(type == "m.room.name" and state_key == "", do: FakeDB.update_room_name(room_id, if(is_binary(content["name"]), do: content["name"], else: "")), else: :ok) do
        {:ok, event["event_id"]}
      else
        # ONE transaction: a failing write leaves neither the event nor rooms.name behind
        {:error, _reason} ->
          :ets.delete(:set_room_state_db, {:event, event["event_id"]})
          {:error, :write_failed}
      end
    end
  end

  # FakeDB: captures insert_event payloads + update_room_name calls, and answers
  # get_room_create_event/1 for parent-space existence checks.
  defmodule FakeDB do
    def insert_event(event) do
      :ets.insert(:set_room_state_db, {{:event, event["event_id"]}, event})
      :ok
    end

    def update_room_name(room_id, name) do
      case :ets.lookup(:set_room_state_db, :fail_update_room_name) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.insert(:set_room_state_db, {{:room_name, room_id}, name})
          :ok
      end
    end

    # Story create-room-input-validation (D4): the PUT path reads the CURRENT m.room.canonical_alias state
    # (the real Room.DB.get_generic_state_events/1 shape: content_json is the jsonb as text, possibly double-encoded).
    # Seeded via seed_current_state/3; `{:state_read, room}` = {:error, _} makes the read fail.
    def get_generic_state_events(room_id) do
      case :ets.lookup(:set_room_state_db, {:state_read, room_id}) do
        [{_, {:error, _} = err}] -> err
        [{_, events}] -> {:ok, events}
        [] -> {:ok, []}
      end
    end

    # story state-writer-redaction (D10 (a)): the unknown-room check of PUT state; a room of the fake registry is a known, active room
    def get_room_status(room_id) do
      case :ets.lookup(:set_room_state_reg, {:room, room_id}) do
        [{_, _state}] -> {:ok, "active"}
        [] -> {:error, :not_found}
      end
    end

    # Parent-space existence: a room "exists" iff a create event was registered.
    def get_room_create_event(room_id) do
      case :ets.lookup(:set_room_state_db, {:create, room_id}) do
        [{_, content}] -> {:ok, content}
        [] -> {:error, :not_found}
      end
    end
  end

  # Story create-room-input-validation (D4): the room_aliases store as the PUT path sees it. lookup_alias/1 is the ONLY call
  # (spied: the alias store must not be consulted for a sender that is refused, nor for "", null or aliases that are already present).
  defmodule FakeAliasDB do
    def lookup_alias(alias_str) do
      :ets.insert(:set_room_state_db, {{:alias_lookup, make_ref()}, alias_str})

      case :ets.lookup(:set_room_state_db, :alias_lookup_override) do
        [{_, result}] ->
          result

        [] ->
          case :ets.lookup(:set_room_state_db, {:alias, alias_str}) do
            [{_, room_id}] -> {:ok, room_id}
            [] -> {:error, :not_found}
          end
      end
    end

    def insert_room_alias(_alias, _room_id, _created_at), do: {:error, :not_used_by_the_put_path}
  end

  setup do
    for tab <- [:set_room_state_reg, :set_room_state_db] do
      if :ets.info(tab) != :undefined, do: :ets.delete(tab)
      :ets.new(tab, [:named_table, :public, :set])
    end

    # Signing key for emit_state_event/5.
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519, @signing_key_seed)
    :persistent_term.put(:nebu_signing_key, {pub, priv})

    # snapshot the env keys this suite overrides (some are set by config/runtime.exs: server_name, audit_writer) and restore them
    env_keys = [
      {:event_dispatcher, :room_registry_module},
      {:event_dispatcher, :messages_db_module},
      {:event_dispatcher, :rooms_db_module},
      {:event_dispatcher, :alias_db_module},
      {:event_dispatcher, :server_name},
      {:compliance, :audit_writer}
    ]

    snapshot = for {app, key} <- env_keys, do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:event_dispatcher, :room_registry_module, FakeRoomRegistry)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :alias_db_module, FakeAliasDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      for {app, key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      for tab <- [:set_room_state_reg, :set_room_state_db] do
        if :ets.info(tab) != :undefined, do: :ets.delete(tab)
      end
    end)

    :ok
  end

  # Register a room into the fake registry with the given members + power_levels.
  defp register_room(room_id, members, power_levels) do
    state = %{members: MapSet.new(members), power_levels: power_levels}
    :ets.insert(:set_room_state_reg, {{:room, room_id}, state})
  end

  # Mark a room as existing for the parent-space existence check.
  defp register_create(room_id) do
    :ets.insert(:set_room_state_db, {{:create, room_id}, %{"creator" => "@x:test.local"}})
  end

  defp pl_with(user_levels) do
    Nebu.Matrix.Room.PowerLevels.default_levels()
    |> Map.put("users", user_levels)
  end

  defp stream, do: %{http_request_headers: %{}}

  defp emitted_event(room_id, type, state_key) do
    :ets.match(:set_room_state_db, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.find(fn ev ->
      ev["room_id"] == room_id and ev["type"] == type and ev["state_key"] == state_key
    end)
  end

  defp req(room_id, sender, type, state_key, content) do
    %Core.SetRoomStateRequest{
      room_id: room_id,
      sender_id: sender,
      event_type: type,
      state_key: state_key,
      content_json: Jason.encode!(content)
    }
  end

  # ─── AC2/AC3 — allowlist accepts m.space.child; event built server-side ──────
  describe "set_room_state/2 — m.space.child (allowlisted)" do
    test "authorized member sets m.space.child → returns event_id; server-built fields" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      resp =
        Server.set_room_state(
          req(room, "@admin:test.local", "m.space.child", "!child:test.local", %{
            "via" => ["nebu.local"],
            "suggested" => false
          }),
          stream()
        )

      assert %Core.SetRoomStateResponse{event_id: eid} = resp
      assert is_binary(eid) and eid != ""

      ev = emitted_event(room, "m.space.child", "!child:test.local")
      assert ev != nil, "m.space.child event must be emitted"
      # Server-authoritative top-level fields.
      assert ev["sender"] == "@admin:test.local"
      assert ev["type"] == "m.space.child"
      assert ev["room_id"] == room
      assert is_integer(ev["origin_server_ts"])
      assert ev["content"]["via"] == ["nebu.local"]
    end

    test "empty content (unlink) is accepted → 200 with event_id" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      resp =
        Server.set_room_state(
          req(room, "@admin:test.local", "m.space.child", "!child:test.local", %{}),
          stream()
        )

      assert %Core.SetRoomStateResponse{event_id: eid} = resp
      assert eid != ""
      assert emitted_event(room, "m.space.child", "!child:test.local") != nil
    end
  end

  # ─── AC1 — power-level / membership check ────────────────────────────────────
  describe "set_room_state/2 — authorization" do
    test "non-member → permission_denied" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(room, "@stranger:test.local", "m.space.child", "!c:test.local", %{}),
          stream()
        )
      end
    end

    test "member with insufficient PL (< state_default) → permission_denied" do
      room = "!space:test.local"
      # @bob is a member but only has users_default (0) < state_default (50).
      register_room(room, ["@admin:test.local", "@bob:test.local"], pl_with(%{"@admin:test.local" => 100}))

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(room, "@bob:test.local", "m.space.child", "!c:test.local", %{}),
          stream()
        )
      end
    end
  end

  # ─── AC2 — allowlist rejects server-authoritative state types (SECURITY) ─────
  describe "set_room_state/2 — allowlist (security boundary)" do
    # story power-levels-enforcement (AC16 re-pin): m.room.power_levels is no longer on this list (it has its own route
    # through the room-process writer, pinned by power_levels_http_test.exs); the two server-authoritative types stay 403
    for forbidden <- ["m.room.member", "m.room.create"] do
      test "rejects #{forbidden} → permission_denied even for a PL-100 member" do
        room = "!space:test.local"
        register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

        assert_raise Nebu.Matrix.Error, fn ->
          Server.set_room_state(
            req(room, "@admin:test.local", unquote(forbidden), "", %{"x" => 1}),
            stream()
          )
        end

        # And nothing was emitted.
        assert emitted_event(room, unquote(forbidden), "") == nil
      end
    end

    test "rejects an arbitrary non-allowlisted type → permission_denied" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(room, "@admin:test.local", "com.evil.custom", "", %{}),
          stream()
        )
      end
    end
  end

  # ─── AC4 — m.space.parent requires membership of the (existing) parent space ──
  describe "set_room_state/2 — m.space.parent (security check)" do
    test "sender member of parent space → 200 stored" do
      child = "!child:test.local"
      parent = "!parent:test.local"
      register_room(child, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      register_room(parent, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      register_create(parent)

      resp =
        Server.set_room_state(
          req(child, "@admin:test.local", "m.space.parent", parent, %{"via" => ["nebu.local"]}),
          stream()
        )

      assert %Core.SetRoomStateResponse{event_id: eid} = resp
      assert eid != ""
      assert emitted_event(child, "m.space.parent", parent) != nil
    end

    test "sender NOT a member of the parent space → permission_denied" do
      child = "!child:test.local"
      parent = "!parent:test.local"
      register_room(child, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      # parent exists but @admin is not a member of it.
      register_room(parent, ["@owner:test.local"], pl_with(%{"@owner:test.local" => 100}))
      register_create(parent)

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(child, "@admin:test.local", "m.space.parent", parent, %{}),
          stream()
        )
      end

      assert emitted_event(child, "m.space.parent", parent) == nil
    end

    test "parentSpaceId references a non-existent room → not_found" do
      child = "!child:test.local"
      register_room(child, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      # parent NOT registered (no create event, not in registry) → 404.

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(child, "@admin:test.local", "m.space.parent", "!ghost:test.local", %{}),
          stream()
        )
      end
    end
  end

  # ─── AC5 — m.room.name via generic PUT denormalises rooms.name ───────────────
  describe "set_room_state/2 — m.room.name denormalisation" do
    test "writing m.room.name updates rooms.name via update_room_name/2" do
      room = "!room:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      resp =
        Server.set_room_state(
          req(room, "@admin:test.local", "m.room.name", "", %{"name" => "Renamed"}),
          stream()
        )

      assert %Core.SetRoomStateResponse{} = resp
      assert :ets.lookup(:set_room_state_db, {:room_name, room}) == [{{:room_name, room}, "Renamed"}]
    end

    test "m.space.child does NOT touch rooms.name" do
      room = "!room:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      Server.set_room_state(
        req(room, "@admin:test.local", "m.space.child", "!c:test.local", %{}),
        stream()
      )

      assert :ets.lookup(:set_room_state_db, {:room_name, room}) == []
    end
  end

  # ═══ Story create-room-input-validation (epic oauth-broker, follow-ups eg, ei) ══════════════════════════════════
  #
  # PUT /rooms/{id}/state/m.room.canonical_alias validates NEW aliases (D4, AC9) and PUT m.room.name validates its content (D5c,
  # AC11); the failure logs are value-free (D5e, AC12). Errors are asserted through Nebu.Matrix.Http.call_core/1 (the public D6
  # mapping `{:error, {http_status, errcode, message}}`), so the test does not depend on how the core carries the errcode.

  @room "!room:test.local"
  @admin "@admin:test.local"
  @own_alias "#own:test.local"
  @other_room "!elsewhere:test.local"

  defp setup_alias_room do
    register_room(@room, [@admin, "@bob:test.local"], pl_with(%{@admin => 100}))
    # the room's own alias is registered to the room (createRoom writes room_aliases; there is no other writer)
    register_alias(@own_alias, @room)
  end

  defp register_alias(alias_str, room_id), do: :ets.insert(:set_room_state_db, {{:alias, alias_str}, room_id})

  # the CURRENT m.room.canonical_alias state of the room as get_generic_state_events/1 returns it
  defp seed_current_state(room_id, content, opts \\ []) do
    json = Jason.encode!(content)
    json = if Keyword.get(opts, :double_encoded, false), do: Jason.encode!(json), else: json

    event = %{type: "m.room.canonical_alias", state_key: "", content_json: json, sender: @admin, event_id: "$cur:test.local", origin_server_ts: 1}
    :ets.insert(:set_room_state_db, {{:state_read, room_id}, [event]})
  end

  defp lookups, do: :ets.match(:set_room_state_db, {{:alias_lookup, :_}, :"$1"}) |> List.flatten()

  # several current events as get_generic_state_events/1 could return them: {type, state_key, content, origin_server_ts}
  defp seed_events(room_id, specs) do
    events =
      for {type, key, content, ts} <- specs do
        %{type: type, state_key: key, content_json: Jason.encode!(content), sender: @admin, event_id: "$seed#{ts}#{key}:test.local", origin_server_ts: ts}
      end

    :ets.insert(:set_room_state_db, {{:state_read, room_id}, events})
  end

  defp put_state(room, sender, type, content, state_key \\ ""),
    do: Nebu.Matrix.Http.call_core(fn -> Server.set_room_state(req(room, sender, type, state_key, content), stream()) end)

  defp put_alias(content, sender \\ @admin), do: put_state(@room, sender, "m.room.canonical_alias", content)

  # All persisted events of a type in the room (the FakeDB table is a :set, so the result has no order: never pick "the" event from it,
  # count them or look one up by the event id the call returned).
  defp events_of(room_id, type) do
    :ets.match(:set_room_state_db, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.filter(&(&1["room_id"] == room_id and &1["type"] == type))
  end

  defp event_by_id(eid), do: :ets.lookup(:set_room_state_db, {:event, eid}) |> Enum.map(&elem(&1, 1)) |> List.first()

  defp assert_alias_rejected(content, errcode, label) do
    before = length(events_of(@room, "m.room.canonical_alias"))

    case put_alias(content) do
      {:error, {400, ^errcode, message}} ->
        assert is_binary(message) and message != ""
        assert length(events_of(@room, "m.room.canonical_alias")) == before, "#{label}: nothing is persisted on a 4xx"
        message

      other ->
        flunk("#{label}: expected 400 #{errcode}, got #{inspect(other)}")
    end
  end

  defp assert_alias_accepted(content, label) do
    assert {:ok, %Core.SetRoomStateResponse{event_id: eid}} = put_alias(content), "#{label}: expected 200"
    assert eid != ""
    assert event_by_id(eid)["content"] == content, "#{label}: the emitted event carries the content as sent"
    eid
  end

  describe "AC9 - PUT canonical_alias validates new aliases" do
    test "the room's own registered alias is accepted and looked up" do
      setup_alias_room()
      assert_alias_accepted(%{"alias" => @own_alias}, "own alias")
      assert @own_alias in lookups()
    end

    test "alias of another room, unregistered or foreign server is M_BAD_ALIAS" do
      setup_alias_room()
      register_alias("#theirs:test.local", @other_room)

      for {label, content} <- [
            registered_to_another_room: %{"alias" => "#theirs:test.local"},
            unregistered: %{"alias" => "#nobody:test.local"},
            other_server: %{"alias" => "#x:other.example"},
            alt_alias_of_another_room: %{"alt_aliases" => ["#theirs:test.local"]}
          ] do
        assert_alias_rejected(content, "M_BAD_ALIAS", label)
      end
    end

    test "bad syntax or wrong types are M_INVALID_PARAM" do
      setup_alias_room()

      for {label, content} <- [
            not_an_alias: %{"alias" => "not-an-alias"},
            no_local: %{"alias" => "#nolocal"},
            empty_local: %{"alias" => "#:server"},
            empty_domain: %{"alias" => "#a:"},
            alias_number: %{"alias" => 5},
            alt_not_a_list: %{"alt_aliases" => "x"},
            alt_number_entry: %{"alt_aliases" => [5]},
            nul: %{"alias" => "#a\u0000b:test.local"},
            over_255_bytes: %{"alias" => "#" <> String.duplicate("a", 256) <> ":test.local"}
          ] do
        assert_alias_rejected(content, "M_INVALID_PARAM", label)
      end
    end

    test "one invalid new alt alias fails the whole request" do
      setup_alias_room()
      assert_alias_rejected(%{"alias" => @own_alias, "alt_aliases" => [@own_alias, "#nobody:test.local"]}, "M_BAD_ALIAS", "mapping")
      assert_alias_rejected(%{"alias" => @own_alias, "alt_aliases" => [@own_alias, "not-an-alias"]}, "M_INVALID_PARAM", "syntax")
    end

    test "the error message never echoes the alias" do
      setup_alias_room()
      marker = "zzput" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      message = assert_alias_rejected(%{"alias" => "#" <> marker <> ":test.local"}, "M_BAD_ALIAS", "marker mapping")
      refute message =~ marker
      message = assert_alias_rejected(%{"alias" => marker}, "M_INVALID_PARAM", "marker syntax")
      refute message =~ marker
    end

    test "aliases already in the current state are not validated (re-save of an upgraded room)" do
      setup_alias_room()
      register_alias("#moved:test.local", @other_room)
      content = %{"alias" => "#moved:test.local", "alt_aliases" => ["#gone:test.local"]}
      seed_current_state(@room, content)

      assert_alias_accepted(content, "re-save")
      assert lookups() == [], "nothing is new: nothing is looked up"
    end

    test "the CURRENT state is the latest m.room.canonical_alias of the requested state_key: older events and other types / keys do not count" do
      setup_alias_room()

      seed_events(@room, [
        {"m.room.canonical_alias", "", %{"alias" => "#older:test.local"}, 1},
        {"m.room.canonical_alias", "", %{"alias" => "#latest:test.local"}, 5},
        {"m.room.canonical_alias", "k", %{"alias" => "#otherkey:test.local"}, 9},
        {"m.room.topic", "", %{"alias" => "#topic:test.local"}, 9}
      ])

      # present in the latest current event of state_key "": not new, not looked up (it maps nowhere)
      assert_alias_accepted(%{"alias" => "#latest:test.local"}, "latest current alias")
      assert lookups() == []

      # only in an OLDER event, in another state_key's event or in another type: new, looked up, unregistered
      for stale <- ["#older:test.local", "#otherkey:test.local", "#topic:test.local"] do
        assert_alias_rejected(%{"alias" => stale}, "M_BAD_ALIAS", "stale #{stale}")
      end
    end

    test "with a non-empty state_key the current state of THAT key is compared" do
      setup_alias_room()
      seed_events(@room, [{"m.room.canonical_alias", "", %{"alias" => "#emptykey:test.local"}, 5}, {"m.room.canonical_alias", "k", %{"alias" => "#keyk:test.local"}, 1}])

      assert {:ok, _} = put_state(@room, @admin, "m.room.canonical_alias", %{"alias" => "#keyk:test.local"}, "k")
      assert lookups() == [], "present in the current event of state_key k"

      assert {:error, {400, "M_BAD_ALIAS", _}} = put_state(@room, @admin, "m.room.canonical_alias", %{"alias" => "#emptykey:test.local"}, "k")
    end

    test "the current state may be a double-encoded jsonb string" do
      setup_alias_room()
      content = %{"alias" => "#moved:test.local"}
      seed_current_state(@room, content, double_encoded: true)

      assert_alias_accepted(content, "re-save of a double-encoded current state")
      assert lookups() == []
    end

    test "removing aliases is accepted without validation" do
      setup_alias_room()
      seed_current_state(@room, %{"alias" => "#a:test.local", "alt_aliases" => ["#b:test.local", "#c:test.local"]})

      assert_alias_accepted(%{}, "remove all")
      assert_alias_accepted(%{"alias" => "#a:test.local", "alt_aliases" => ["#b:test.local"]}, "remove one")
      assert lookups() == []
    end

    test "empty alias and null alias are accepted and never looked up" do
      setup_alias_room()

      assert_alias_accepted(%{"alias" => ""}, "empty alias")
      assert_alias_accepted(%{"alias" => nil}, "null alias")
      assert lookups() == []

      assert_alias_accepted(%{"alias" => "", "alt_aliases" => [@own_alias]}, "empty alias with an own alt alias")
      assert lookups() == [@own_alias]
    end

    test "an empty alias does not legitimise a foreign alt alias" do
      setup_alias_room()
      assert_alias_rejected(%{"alias" => "", "alt_aliases" => ["#nobody:test.local"]}, "M_BAD_ALIAS", "empty alias, foreign alt")
    end

    test "moving an alias between alias and alt_aliases is not new" do
      setup_alias_room()
      register_alias("#moved:test.local", @other_room)

      seed_current_state(@room, %{"alt_aliases" => ["#moved:test.local"]})
      assert_alias_accepted(%{"alias" => "#moved:test.local"}, "alt -> alias")

      seed_current_state(@room, %{"alias" => "#moved:test.local"})
      assert_alias_accepted(%{"alt_aliases" => ["#moved:test.local"]}, "alias -> alt")

      assert lookups() == []
    end

    test "a duplicate across alias and alt_aliases counts once" do
      setup_alias_room()

      assert_alias_accepted(%{"alias" => @own_alias, "alt_aliases" => [@own_alias, @own_alias]}, "own duplicate")
      assert lookups() == [@own_alias]

      :ets.match_delete(:set_room_state_db, {{:alias_lookup, :_}, :_})
      register_alias("#theirs:test.local", @other_room)
      assert_alias_rejected(%{"alias" => "#theirs:test.local", "alt_aliases" => ["#theirs:test.local"]}, "M_BAD_ALIAS", "foreign duplicate")
      assert lookups() == ["#theirs:test.local"]
    end

    test "authorisation first: 403 whatever the alias, the alias store is not consulted" do
      setup_alias_room()

      for sender <- ["@stranger:test.local", "@bob:test.local"],
          content <- [%{"alias" => @own_alias}, %{"alias" => "#nobody:test.local"}, %{"alias" => "not-an-alias"}, %{"alias" => 5}] do
        assert {:error, {403, "M_FORBIDDEN", _}} = put_alias(content, sender), "#{sender} #{inspect(content)}"
      end

      assert lookups() == [], "no alias-mapping oracle for a refused sender"
      assert events_of(@room, "m.room.canonical_alias") == []
    end

    test "a failing current-state read is a 500, nothing emitted" do
      setup_alias_room()
      :ets.insert(:set_room_state_db, {{:state_read, @room}, {:error, :db_down}})

      assert {:error, {500, _errcode, _}} = put_alias(%{"alias" => @own_alias})
      assert events_of(@room, "m.room.canonical_alias") == []
    end

    test "a failing alias lookup is a 500, nothing emitted" do
      setup_alias_room()
      :ets.insert(:set_room_state_db, {:alias_lookup_override, {:error, :db_down}})

      assert {:error, {500, _errcode, _}} = put_alias(%{"alias" => @own_alias})
      assert events_of(@room, "m.room.canonical_alias") == []
    end
  end

  describe "AC11 - PUT m.room.name content rules" do
    setup do
      register_room(@room, [@admin], pl_with(%{@admin => 100}))
      :ets.insert(:set_room_state_db, {{:room_name, @room}, "Old name"})
      :ok
    end

    defp assert_name_rejected(content, errcode, label) do
      before = length(events_of(@room, "m.room.name"))

      case put_state(@room, @admin, "m.room.name", content) do
        {:error, {400, ^errcode, _}} -> :ok
        other -> flunk("#{label}: expected 400 #{errcode}, got #{inspect(other)}")
      end

      assert length(events_of(@room, "m.room.name")) == before, "#{label}: no new state event"
      assert :ets.lookup(:set_room_state_db, {:room_name, @room}) == [{{:room_name, @room}, "Old name"}], "#{label}: rooms.name unchanged"
    end

    test "256 code points are M_INVALID_PARAM, nothing persisted" do
      assert_name_rejected(%{"name" => String.duplicate("a", 256)}, "M_INVALID_PARAM", "256 ASCII")
      assert_name_rejected(%{"name" => String.duplicate("ä", 256)}, "M_INVALID_PARAM", "256 multibyte")
    end

    test "255 code points are accepted (code points, not bytes)" do
      for name <- [String.duplicate("a", 255), String.duplicate("ä", 255)] do
        assert {:ok, _} = put_state(@room, @admin, "m.room.name", %{"name" => name})
        assert :ets.lookup(:set_room_state_db, {:room_name, @room}) == [{{:room_name, @room}, name}]
      end
    end

    test "a non-string, non-null name is M_BAD_JSON, nothing persisted" do
      for {label, value} <- [number: 42, boolean: true, object: %{}, list: ["x"]] do
        assert_name_rejected(%{"name" => value}, "M_BAD_JSON", "name #{label}")
      end
    end

    test "empty name, {} and null name are 200 and set rooms.name to empty" do
      for content <- [%{"name" => ""}, %{}, %{"name" => nil}] do
        :ets.insert(:set_room_state_db, {{:room_name, @room}, "Old name"})
        assert {:ok, %Core.SetRoomStateResponse{}} = put_state(@room, @admin, "m.room.name", content)
        assert :ets.lookup(:set_room_state_db, {:room_name, @room}) == [{{:room_name, @room}, ""}], inspect(content)
      end
    end
  end

  describe "AC12 - the PUT rooms.name failure log is value-free" do
    test "a failing rooms.name write logs room id and error class only" do
      register_room(@room, [@admin], pl_with(%{@admin => 100}))
      marker = "mkput" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      reason = %Postgrex.Error{
        message: "simulated #{marker}",
        postgres: %{code: :untranslatable_character, pg_code: "22P05", severity: "ERROR", message: "unsupported Unicode escape sequence", where: "JSON data, line 1: {\"name\": \"#{marker}\"}"}
      }

      :ets.insert(:set_room_state_db, {:fail_update_room_name, reason})

      ref = make_ref()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {ref, put_state(@room, @admin, "m.room.name", %{"name" => marker})})
        end)

      # story state-writer-redaction (D8, AC15 (d) re-pin; old -> new): rooms.name is written in the SAME transaction as the event, so a failing name write
      # fails the write (500, nothing persisted) instead of being a non-fatal denormalisation failure; the value-free log is the room process' (real-database suites)
      assert_received {^ref, {:error, {500, _errcode, _message}}}
      assert :ets.match_object(:set_room_state_db, {{:event, :_}, %{"type" => "m.room.name"}}) == [], "no event persisted"
      assert :ets.lookup(:set_room_state_db, {:room_name, @room}) == [], "rooms.name unchanged"
      refute String.downcase(log) =~ marker
    end
  end

  describe "cycle 1 - M3: the alias set of a PUT canonical_alias is capped at 64 (Nebu policy)" do
    test "65 distinct aliases are M_INVALID_PARAM before any alias is looked up; 64 mapped aliases are 200; duplicates count once" do
      setup_alias_room()
      aliases = for i <- 1..65, do: "#cap#{i}:test.local"
      for a <- aliases, do: register_alias(a, @room)

      assert_alias_rejected(%{"alias" => List.first(aliases), "alt_aliases" => aliases}, "M_INVALID_PARAM", "65 distinct aliases")
      assert lookups() == [], "the cap is checked before the alias store is consulted"

      content = %{"alt_aliases" => Enum.take(aliases, 64)}
      assert_alias_accepted(content, "64 distinct aliases")

      assert_alias_accepted(%{"alias" => @own_alias, "alt_aliases" => List.duplicate(@own_alias, 100)}, "100 copies of one alias")
    end
  end

  # ═══ Story create-room-presets-power-levels-topic (epic oauth-broker, follow-up `ea`), AC8 / D5 ═════════════════════════
  #
  # `PUT .../state/m.room.topic` follows the same content rule as the top-level createRoom topic and the initial_state entries (and, through
  # Nebu.Matrix.set_space_state/5, the Admin Space form): `topic` absent / null / "" valid, a non-string `topic` is 400 M_BAD_JSON, more than
  # 1024 code points 400 M_INVALID_PARAM; `m.topic` absent / null or an object whose `m.text` is absent or a list of objects with a string
  # `body` (at most 4096 code points) and an optional string `mimetype`, else 400 M_BAD_JSON / M_INVALID_PARAM. The rule runs AFTER the
  # authorisation (no content oracle for a refused sender) and BEFORE anything is persisted. Nebu policy caps, not spec text.

  describe "AC8 - PUT m.room.topic content rules" do
    setup do
      register_room(@room, [@admin, "@bob:test.local"], pl_with(%{@admin => 100}))
      :ok
    end

    defp put_topic(content, sender \\ @admin), do: put_state(@room, sender, "m.room.topic", content)

    defp assert_topic_rejected(content, errcode, label) do
      before = length(events_of(@room, "m.room.topic"))

      case put_topic(content) do
        {:error, {400, ^errcode, message}} ->
          assert is_binary(message) and message != ""
          assert length(events_of(@room, "m.room.topic")) == before, "#{label}: nothing is persisted on a 4xx"
          message

        other ->
          flunk("#{label}: expected 400 #{errcode}, got #{inspect(other)}")
      end
    end

    defp assert_topic_accepted(content, label) do
      assert {:ok, %Core.SetRoomStateResponse{event_id: eid}} = put_topic(content), "#{label}: expected 200"
      assert event_by_id(eid)["content"] == content, "#{label}: stored as sent"
      eid
    end

    test "{\"topic\": \"\"}, {} and {\"topic\": null} are accepted (an empty topic is no topic)" do
      for content <- [%{"topic" => ""}, %{}, %{"topic" => nil}], do: assert_topic_accepted(content, inspect(content))
    end

    test "a non-string topic is M_BAD_JSON, nothing persisted" do
      for {label, value} <- [number: 42, boolean: true, object: %{}, list: ["x"], float: 1.5] do
        assert_topic_rejected(%{"topic" => value}, "M_BAD_JSON", "topic #{label}")
      end
    end

    test "1025 code points are M_INVALID_PARAM (ASCII and multibyte), 1024 are accepted (code points, not bytes)" do
      assert_topic_rejected(%{"topic" => String.duplicate("t", 1025)}, "M_INVALID_PARAM", "1025 ASCII")
      assert_topic_rejected(%{"topic" => String.duplicate("ä", 1025)}, "M_INVALID_PARAM", "1025 multibyte")

      for topic <- [String.duplicate("t", 1024), String.duplicate("ä", 1024)] do
        assert_topic_accepted(%{"topic" => topic}, "1024 code points")
      end
    end

    test "a malformed m.topic is M_BAD_JSON: \"x\", {\"m.text\": \"x\"}, {\"m.text\": [5]}, {\"m.text\": [{\"body\": 5}]}, a non-string mimetype" do
      for {label, m_topic} <- [
            string: "x",
            number: 5,
            list: [],
            m_text_string: %{"m.text" => "x"},
            m_text_object: %{"m.text" => %{"body" => "x"}},
            m_text_number_entry: %{"m.text" => [5]},
            m_text_string_entry: %{"m.text" => ["x"]},
            body_number: %{"m.text" => [%{"body" => 5}]},
            body_missing: %{"m.text" => [%{"mimetype" => "text/plain"}]},
            body_null: %{"m.text" => [%{"body" => nil}]},
            mimetype_number: %{"m.text" => [%{"body" => "a", "mimetype" => 5}]},
            second_entry_bad: %{"m.text" => [%{"body" => "ok"}, %{"body" => 7}]}
          ] do
        assert_topic_rejected(%{"topic" => "t", "m.topic" => m_topic}, "M_BAD_JSON", "m.topic #{label}")
      end
    end

    test "an m.text body of 4097 code points is M_INVALID_PARAM, 4096 are accepted" do
      body = fn n -> %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => String.duplicate("b", n)}]}} end
      assert_topic_rejected(body.(4097), "M_INVALID_PARAM", "4097 code points")
      assert_topic_accepted(body.(4096), "4096 code points")
    end

    test "the m.text list is capped at 8 entries (Nebu policy): 9 is M_INVALID_PARAM, nothing persisted; 8 are accepted" do
      texts = fn n -> for i <- 1..n, do: %{"body" => "t#{i}", "mimetype" => "text/plain"} end
      assert_topic_rejected(%{"topic" => "t", "m.topic" => %{"m.text" => texts.(9)}}, "M_INVALID_PARAM", "9 texts")
      assert_topic_accepted(%{"topic" => "t", "m.topic" => %{"m.text" => texts.(8)}}, "8 texts")
    end

    test "{\"m.text\": []}, an absent / null m.topic and an m.topic that differs from topic are accepted and stored as sent (not cross-checked)" do
      for content <- [
            %{"topic" => "t", "m.topic" => %{"m.text" => []}},
            %{"topic" => "t", "m.topic" => nil},
            %{"topic" => "t", "m.topic" => %{}},
            %{"topic" => "plain", "m.topic" => %{"m.text" => [%{"body" => "something else", "mimetype" => "text/plain"}]}},
            %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => "<b>x</b>", "mimetype" => "text/html"}, %{"body" => "x"}]}}
          ] do
        assert_topic_accepted(content, inspect(content))
      end
    end

    test "authorisation first: a non-member and a member without state power get 403 M_FORBIDDEN whatever the content, nothing persisted" do
      for sender <- ["@stranger:test.local", "@bob:test.local"],
          content <- [%{"topic" => "fine"}, %{"topic" => 42}, %{"topic" => String.duplicate("t", 1025)}, %{"topic" => "t", "m.topic" => "x"}] do
        assert {:error, {403, "M_FORBIDDEN", _}} = put_topic(content, sender), "#{sender} #{inspect(content)}"
      end

      assert events_of(@room, "m.room.topic") == []
    end

    test "the messages are fixed text: the topic is never echoed" do
      marker = "zzputtopic" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      refute assert_topic_rejected(%{"topic" => marker <> String.duplicate("t", 1025)}, "M_INVALID_PARAM", "marker too long") =~ marker
      refute assert_topic_rejected(%{"topic" => 42, "m.topic" => marker}, "M_BAD_JSON", "marker m.topic") =~ marker
      refute assert_topic_rejected(%{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => marker, "mimetype" => 5}]}}, "M_BAD_JSON", "marker mimetype") =~ marker
    end

    test "the rule is for the topic only: other event types keep their content (m.room.avatar with a number is not touched by it)" do
      assert {:ok, _} = put_state(@room, @admin, "m.room.avatar", %{"url" => 42})
    end
  end
end
