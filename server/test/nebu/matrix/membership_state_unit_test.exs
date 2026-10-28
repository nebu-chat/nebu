defmodule Nebu.Matrix.MembershipStateUnitTest do
  @moduledoc """
  Story `membership-state-model`, the unit half (NO database, no Repo; runs in the unit job): AC5 (f) (the seam rule of the slice read, with test doubles), the pure
  state-event renderer of `Nebu.Matrix.Http` (D10), and the source pins of AC9 (a) - (e) (AST walks over `server/lib`, comments and strings never count).

  ## Decisions of the ATDD step (ambiguities of the story, recorded for the dev)

    * The seam of the slice read is `messages_db_module()` (the module `build_state_events/3` already reads create / name / generic state / predecessors through);
      `Room.DB.direct_invitees/1` is read through `rooms_db_module()` (next to `banned_members/1`).
    * `build_state_events/4` takes the keyword option `member_slice: :events | :joined` (default `:joined`) as its LAST argument (after `fetch_predecessors?`):
      the pins accept any call of `build_state_events` whose arguments contain the pair `member_slice: :events`.
    * The public renderer is `Nebu.Matrix.Http.state_event_json/3` (`state_event`, `now_ms`, `room_id | nil`): with a `room_id` the event is a ClientEvent
      (`/members`, `/initialSync`), without one it is the ClientEventWithoutRoomID of `/sync`.
    * `GET /members` is served by `EventDispatcher.Server.get_room_members/2` (the story's name), which never calls `build_state_events`.
    * `get_room_state/2` (the `/initialSync` backend) reads the slice (`member_slice: :events`) and the predecessors.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Http

  @lib Path.expand("../../../lib", __DIR__)
  @server Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex")
  @protected Path.join(@lib, "nebu/web/router/protected.ex")
  @http Path.join(@lib, "nebu/matrix/http.ex")
  @db Path.join(@lib, "nebu/matrix/room/db.ex")
  @room "!unit:test.local"
  @caller "@caller:test.local"

  # ─── doubles ─────────────────────────────────────────────────────────────────

  defmodule Registry do
    @moduledoc false
    # the room process stand-in: a fixed state map
    def get_state(_room), do: Application.fetch_env!(:nebu, :atdd_ms_unit_state)
  end

  defmodule BaseDB do
    @moduledoc false
    defmacro __using__(_opts) do
      quote do
        def get_room_creator(_room), do: {:ok, "@creator:test.local"}
        def get_room_create_event(_room), do: {:error, :not_found}
        def get_room_name(_room), do: {:error, :not_found}
        def get_generic_state_events(_room), do: {:ok, []}
      end
    end
  end

  defmodule NoSliceDB do
    @moduledoc false
    use Nebu.Matrix.MembershipStateUnitTest.BaseDB
  end

  defmodule SliceDB do
    @moduledoc false
    use Nebu.Matrix.MembershipStateUnitTest.BaseDB

    def member_state_slice(_room, opts) do
      send(self(), {:slice_opts, opts})

      {:ok,
       [
         %{event_id: "$j", state_key: "@caller:test.local", sender: "@caller:test.local", content: %{"membership" => "join"}, origin_server_ts: 10, membership: "join"},
         %{event_id: "$i", state_key: "@invited:test.local", sender: "@caller:test.local", content: %{"membership" => "invite", "is_direct" => true}, origin_server_ts: 20, membership: "invite"},
         %{event_id: "$b", state_key: "@banned:test.local", sender: "@caller:test.local", content: %{"membership" => "ban", "reason" => "r"}, origin_server_ts: 30, membership: "ban"}
       ]}
    end
  end

  defmodule FailingSliceDB do
    @moduledoc false
    use Nebu.Matrix.MembershipStateUnitTest.BaseDB
    def member_state_slice(_room, _opts), do: {:error, :atdd_boom}
  end

  defmodule RaisingSliceDB do
    @moduledoc false
    use Nebu.Matrix.MembershipStateUnitTest.BaseDB
    def member_state_slice(_room, _opts), do: raise("atdd: the read raised")
  end

  # security cycle 1 (MINOR-1 / L-1): a registry whose room process is not running (the first call exits :noproc) and, once "started", does not answer (the second
  # call exits with a timeout); the calls are counted: a second call means the room was started
  defmodule StoppedRegistry do
    @moduledoc false
    def get_state(_room) do
      ref = Application.fetch_env!(:nebu, :atdd_ms_unit_calls)
      :counters.add(ref, 1, 1)

      case :counters.get(ref, 1) do
        1 -> exit({:noproc, {GenServer, :call, [:the_room, :get_state, 5000]}})
        _ -> exit({:timeout, {GenServer, :call, [:the_room, :get_state, 5000]}})
      end
    end
  end

  defmodule StatusDB do
    @moduledoc false
    def get_room_status(_room), do: {:ok, "active"}
    def get_member_membership(_room, "@member:test.local"), do: {:ok, "join"}
    def get_member_membership(_room, _user), do: {:ok, nil}
  end

  setup do
    members = MapSet.new([@caller, "@legacy:test.local"])
    Application.put_env(:nebu, :atdd_ms_unit_state, %{room_id: @room, members: members, power_levels: %{"users" => %{}}})
    prior = for key <- [:room_registry_module, :messages_db_module], do: {key, Application.fetch_env(:event_dispatcher, key)}
    Application.put_env(:event_dispatcher, :room_registry_module, Registry)

    on_exit(fn ->
      Application.delete_env(:nebu, :atdd_ms_unit_state)
      Application.delete_env(:nebu, :atdd_ms_unit_calls)

      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:event_dispatcher, key, v)
          :error -> Application.delete_env(:event_dispatcher, key)
        end
      end
    end)

    :ok
  end

  defp use_db(mod), do: Application.put_env(:event_dispatcher, :messages_db_module, mod)

  defp state_events do
    resp = Server.get_room_state(%Core.GetRoomStateRequest{room_id: @room, event_type: "", state_key: ""}, Http.stream(@caller))
    resp.state_events
  end

  defp members_of(events), do: events |> Enum.filter(&(&1.type == "m.room.member")) |> Map.new(&{&1.state_key, &1})

  # ═══ AC5 (f): the seam rule ═════════════════════════════════════════════════════════════════════

  describe "AC5 (f) - the slice read through a test db module" do
    test "a TEST db module WITHOUT member_state_slice/2: the joined slice of the member set is served (one synthesized join per member)" do
      use_db(NoSliceDB)

      members = members_of(state_events())

      assert Map.keys(members) |> Enum.sort() == Enum.sort([@caller, "@legacy:test.local"])
      for {uid, ev} <- members, do: assert(Jason.decode!(ev.content) == %{"membership" => "join"} and ev.sender == uid)
    end

    test "a db module WITH the read: the slots are the stored events (ids, senders, content as stored); a member without an event is added as the synthesized join (D8 (a))" do
      use_db(SliceDB)

      members = members_of(state_events())

      assert Map.keys(members) |> Enum.sort() == Enum.sort([@caller, "@invited:test.local", "@banned:test.local", "@legacy:test.local"])
      assert %{event_id: "$j", origin_server_ts: 10} = members[@caller]
      assert %{event_id: "$i", sender: @caller, origin_server_ts: 20} = members["@invited:test.local"]
      assert Jason.decode!(members["@invited:test.local"].content) == %{"membership" => "invite", "is_direct" => true}
      assert %{event_id: "$b", origin_server_ts: 30} = members["@banned:test.local"]
      assert Jason.decode!(members["@banned:test.local"].content) == %{"membership" => "ban", "reason" => "r"}
      assert %{event_id: "", sender: "@legacy:test.local"} = members["@legacy:test.local"], "the legacy member has no identity"
      assert Jason.decode!(members["@legacy:test.local"].content) == %{"membership" => "join"}
    end

    test "a failing slice read is a handled 500, never a joined-only answer (fail closed): an {:error, _} answer and a raise alike" do
      for db <- [FailingSliceDB, RaisingSliceDB] do
        use_db(db)

        error = assert_raise Nebu.Matrix.Error, fn -> state_events() end

        assert error.status == Nebu.Matrix.Status.internal(), "#{inspect(db)}: an internal error"
        refute Exception.message(error) =~ "atdd", "#{inspect(db)}: the message carries no error term"
      end
    end

    test "get_room_members/2 with a db module without the read: the joined slice, filtered by membership / not_membership; a non-member is refused with the fixed 403" do
      use_db(NoSliceDB)
      request = %{room_id: @room, membership: nil, not_membership: nil}

      all = Server.get_room_members(request, Http.stream(@caller))
      assert all.state_events |> Enum.map(& &1.state_key) |> Enum.sort() == Enum.sort([@caller, "@legacy:test.local"])
      assert [] == Server.get_room_members(%{request | membership: "ban"}, Http.stream(@caller)).state_events
      assert [] == Server.get_room_members(%{request | not_membership: "join"}, Http.stream(@caller)).state_events
      assert length(Server.get_room_members(%{request | membership: "join", not_membership: "leave"}, Http.stream(@caller)).state_events) == 2

      error = assert_raise Nebu.Matrix.Error, fn -> Server.get_room_members(request, Http.stream("@stranger:test.local")) end
      assert error.status == Nebu.Matrix.Status.permission_denied() and error.errcode == "M_FORBIDDEN"
      assert Exception.message(error) == "You are not a member of this room", "the fixed text: no caller, no room id"
    end

    test "get_room_members/2 passes the filters to the read (membership / not_membership) and serves only the slice (no create / name / generic state)" do
      use_db(SliceDB)

      resp = Server.get_room_members(%{room_id: @room, membership: "invite", not_membership: "join"}, Http.stream(@caller))

      assert_received {:slice_opts, opts}
      assert Keyword.get(opts, :membership) == "invite" and Keyword.get(opts, :not_membership) == "join"
      assert Enum.all?(resp.state_events, &(&1.type == "m.room.member")), "the member slots only"
    end

    # MINOR-1: the lazy start of a stopped room is followed by a get_state that does not answer: the same handled 503 as a timeout of the first call
    test "a get_state that times out AFTER the lazy start is a handled 503 (unavailable), not an escaping exit" do
      Application.put_env(:nebu, :atdd_ms_unit_calls, :counters.new(1, []))
      Application.put_env(:event_dispatcher, :room_registry_module, StoppedRegistry)
      Application.put_env(:event_dispatcher, :rooms_db_module, StatusDB)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :rooms_db_module) end)
      use_db(NoSliceDB)
      request = %Core.GetRoomStateRequest{room_id: @room, event_type: "", state_key: ""}

      for stream <- [Http.stream("", "system"), Http.stream("@member:test.local")] do
        :counters.put(Application.fetch_env!(:nebu, :atdd_ms_unit_calls), 1, 0)
        error = assert_raise Nebu.Matrix.Error, fn -> Server.get_room_state(request, stream) end
        assert error.status == Nebu.Matrix.Status.unavailable(), "unavailable, not internal"
      end
    end

    # L-1: the caller's latest member event is read BEFORE the room is started: a non-member never causes the second get_state (the start)
    test "a caller whose latest member event is not join gets the fixed 403 and the stopped room is NOT started (the registry is asked once); the system role is not gated" do
      Application.put_env(:nebu, :atdd_ms_unit_calls, :counters.new(1, []))
      Application.put_env(:event_dispatcher, :room_registry_module, StoppedRegistry)
      Application.put_env(:event_dispatcher, :rooms_db_module, StatusDB)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :rooms_db_module) end)
      use_db(NoSliceDB)
      calls = Application.fetch_env!(:nebu, :atdd_ms_unit_calls)
      request = %Core.GetRoomStateRequest{room_id: @room, event_type: "", state_key: ""}

      error = assert_raise Nebu.Matrix.Error, fn -> Server.get_room_state(request, Http.stream("@stranger:test.local")) end
      assert error.status == Nebu.Matrix.Status.permission_denied() and error.errcode == "M_FORBIDDEN"
      assert Exception.message(error) == "You are not a member of this room"
      assert :counters.get(calls, 1) == 1, "no start: get_state was asked once"

      :counters.put(calls, 1, 0)
      assert_raise Nebu.Matrix.Error, fn -> Server.get_room_state(request, Http.stream("", "system")) end
      assert :counters.get(calls, 1) == 2, "control: the system role proceeds to the start (and then meets the timeout)"
    end

    test "a system-role caller (the internal fanout) is served without a membership check" do
      use_db(NoSliceDB)

      resp = Server.get_room_state(%Core.GetRoomStateRequest{room_id: @room, event_type: "", state_key: ""}, Http.stream("", "system"))

      assert Enum.any?(resp.state_events, &(&1.type == "m.room.member"))
    end

    test "the refusal of a non-member reader is an explicit M_FORBIDDEN with the FIXED text (no caller id, no room id)" do
      use_db(NoSliceDB)

      error = assert_raise Nebu.Matrix.Error, fn -> Server.get_room_state(%Core.GetRoomStateRequest{room_id: @room, event_type: "", state_key: ""}, Http.stream("@stranger:test.local")) end

      assert error.status == Nebu.Matrix.Status.permission_denied() and error.errcode == "M_FORBIDDEN"
      assert Exception.message(error) == "You are not a member of this room"
    end
  end

  # ═══ D10: the public renderer ═══════════════════════════════════════════════════════════════════

  describe "D10 - the ONE public state-event renderer of Nebu.Matrix.Http" do
    defp render(se, now, room \\ nil), do: apply(Http, :state_event_json, [se, now, room])

    defp se(overrides \\ []) do
      struct(
        Core.SyncRoomStateEvent,
        Keyword.merge([type: "m.room.member", state_key: "@u:test.local", content: Jason.encode!(%{"membership" => "ban", "reason" => "r"}), sender: "@a:test.local", event_id: "$e", origin_server_ts: 1_000], overrides)
      )
    end

    test "a /sync state event (no room_id): event_id, type, state_key, content, sender, origin_server_ts and unsigned.age; NO room_id" do
      assert ev = render(se(), 1_500)

      assert Enum.sort(Map.keys(ev)) == ["content", "event_id", "origin_server_ts", "sender", "state_key", "type", "unsigned"]
      assert ev["unsigned"] == %{"age" => 500} and ev["content"] == %{"membership" => "ban", "reason" => "r"}
    end

    test "a /members or /initialSync state event (room_id given): the same plus room_id" do
      assert ev = render(se(), 1_500, @room)

      assert Enum.sort(Map.keys(ev)) == ["content", "event_id", "origin_server_ts", "room_id", "sender", "state_key", "type", "unsigned"]
      assert ev["room_id"] == @room and ev["event_id"] == "$e" and ev["origin_server_ts"] == 1_000
    end

    test "age is at least 1 (an event of the future or of now)" do
      assert render(se(), 1_000)["unsigned"] == %{"age" => 1}
      assert render(se(), 10)["unsigned"] == %{"age" => 1}
    end

    test "the predecessor keys come together with the age or not at all (never a null)" do
      with_pred = se(replaces_state: "$old", prev_content: Jason.encode!(%{"membership" => "join"}), prev_sender: "@u:test.local")

      assert render(with_pred, 2_000)["unsigned"] == %{
               "age" => 1_000,
               "replaces_state" => "$old",
               "prev_content" => %{"membership" => "join"},
               "prev_sender" => "@u:test.local"
             }

      assert Map.keys(render(se(), 2_000)["unsigned"]) == ["age"]
    end

    test "an entry without a real event id (D8 (a)): no unsigned; with a room_id the deterministic $synth_ id and now, without a room_id the empty id as today" do
      legacy = se(event_id: "", origin_server_ts: 0, state_key: "@legacy:test.local", content: Jason.encode!(%{"membership" => "join"}))

      sync = render(legacy, 5_000)
      assert sync["event_id"] == "" and sync["origin_server_ts"] == 0 and not Map.has_key?(sync, "unsigned") and not Map.has_key?(sync, "room_id")

      members = render(legacy, 5_000, @room)
      assert members["event_id"] == "$synth_" <> Base.url_encode64("m.room.member|@legacy:test.local", padding: false)
      assert members["origin_server_ts"] == 5_000 and members["room_id"] == @room and not Map.has_key?(members, "unsigned")
      assert render(legacy, 9_000, @room)["event_id"] == members["event_id"], "deterministic"
    end
  end

  # ═══ AC9: source pins ═══════════════════════════════════════════════════════════════════════════

  # every def / defp of a source file: `%{name, arity, kind, body (the AST of the whole definition)}`
  defp definitions(path), do: path |> File.read!() |> Code.string_to_quoted!() |> definitions_of()

  defp definitions_of(ast) do
    {_ast, acc} =
      ast
      |> Macro.prewalk([], fn
        {kind, _meta, [{:when, _, [{name, _, args} | _]} | _]} = node, acc when kind in [:def, :defp] and is_atom(name) ->
          {node, [%{name: name, arity: length(args || []), kind: kind, body: node} | acc]}

        {kind, _meta, [{name, _, args} | _]} = node, acc when kind in [:def, :defp] and is_atom(name) ->
          {node, [%{name: name, arity: length(args || []), kind: kind, body: node} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # the function calls (local `f(..)` and remote `m.f(..)`) with the name `fun` inside `ast`: their argument lists
  defp calls(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {^fun, _meta, args} = node, acc when is_list(args) -> {node, [args | acc]}
        {{:., _, [_mod, ^fun]}, _meta, args} = node, acc when is_list(args) -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp contains_pair?(args, pair) do
    {_ast, found} =
      Macro.prewalk(args, false, fn
        {key, val} = node, _acc when {key, val} == pair -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp mentions_atom?(ast, atom) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        ^atom = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # T-1 (test review): source pins walk the AST, so comments (dropped by the parser) and @doc / @moduledoc / @typedoc texts never count
  defp ast_of(path), do: path |> File.read!() |> Code.string_to_quoted!() |> strip_docs()

  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, meta, [{doc, _, _}]} when doc in [:doc, :moduledoc, :typedoc] -> {:@, meta, [nil]}
      node -> node
    end)
  end

  defp string_literals(ast) do
    {_ast, acc} = Macro.prewalk(ast, [], fn node, acc -> if is_binary(node), do: {node, [node | acc]}, else: {node, acc} end)
    acc
  end

  # remote calls `Room.DB.fun(..)` / `Nebu.Matrix.Room.DB.fun(..)` (an alias path that ends in Room.DB) of any of `funs`
  defp room_db_calls(ast, funs) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mod}, fun]}, _, _args} = node, acc ->
          if fun in funs and Enum.take(mod, -2) == [:Room, :DB], do: {node, [fun | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # the body of the `get "<path>" do ... end` route macro of protected.ex
  defp route_body(ast, path) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:get, _, [^path, [do: body]]} = node, _acc -> {node, body}
        node, acc -> {node, acc}
      end)

    found
  end

  # `@name` read inside the AST (an interpolated module attribute)
  defp reads_attr?(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{^name, _, ctx}]} = node, _acc when is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # the route body plus the bodies of the local functions it calls (one level: the route may hand over to a private function after the rate-limit charge)
  defp route_closure(ast, path) do
    case route_body(ast, path) do
      nil ->
        nil

      body ->
        defs = Map.new(definitions_of(ast), &{&1.name, &1.body})
        {_ast, names} = Macro.prewalk(body, [], fn {name, _, args} = node, acc when is_atom(name) and is_list(args) -> {node, [name | acc]}; node, acc -> {node, acc} end)
        {body, for(name <- Enum.uniq(names), Map.has_key?(defs, name), do: Map.fetch!(defs, name))}
    end
  end

  defp aliases?(ast, parts) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:__aliases__, _, ^parts} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  describe "AC9 (a) - member_slice: :events call sites" do
    test "build_state_events gets member_slice: :events in initial_join_rooms, full_state_room and get_room_state, nowhere else" do
      sites =
        for %{name: name, body: body} <- definitions(@server),
            args <- calls(body, :build_state_events),
            contains_pair?(args, {:member_slice, :events}),
            do: name

      # T-13: the SET of call sites (a refactor of the two initial_join_rooms code paths into one helper call stays valid)
      assert sites |> Enum.uniq() |> Enum.sort() == [:full_state_room, :get_room_state, :initial_join_rooms]
    end

    test "the summary / hierarchy callers and fetch_delta_rooms/3 keep :joined (they never pass member_slice: :events)" do
      callers = for %{name: name, body: body} <- definitions(@server), calls(body, :build_state_events) != [], uniq: true, do: name

      for name <- [:get_room_summary, :visible_summary_or_forbid!, :room_visibility_summary, :fetch_delta_rooms] do
        assert name in callers, "#{name} still builds the joined state"
        %{body: body} = Enum.find(definitions(@server), &(&1.name == name))
        for args <- calls(body, :build_state_events), do: refute(contains_pair?(args, {:member_slice, :events}), "#{name} keeps :joined")
      end

    end

    test "/members reads the slice through its own get_room_members/2 (no build_state_events); the route calls it and not get_room_state" do
      defs = definitions(@server)
      assert members = Enum.find(defs, &(&1.name == :get_room_members and &1.arity == 2 and &1.kind == :def)), "def get_room_members/2"
      assert calls(members.body, :build_state_events) == [], "no create / name / generic state read for /members"

      protected = ast_of(@protected)
      assert route = route_closure(protected, "/client/v3/rooms/:room_id/members"), "the /members route exists"
      assert calls(route, :get_room_members) != []
      assert calls(route, :get_room_state) == [], "the /members route never goes through get_room_state"
      assert initial = route_closure(protected, "/client/v3/rooms/:room_id/initialSync")
      assert calls(initial, :get_room_state) != [], "control: /initialSync still does"
    end
  end

  describe "AC9 (b), (c) - $synth_ and the renderer" do
    test "(b) the literal $synth_ appears in ONE file of server/lib (the D8 (a) fallback), never in protected.ex" do
      # string literals of the code, never comments or @doc texts (the story and the moduledocs may name the placeholder)
      files = Path.wildcard(Path.join(@lib, "**/*.ex")) |> Enum.filter(fn path -> path |> ast_of() |> string_literals() |> Enum.any?(&String.contains?(&1, "$synth_")) end)

      assert length(files) == 1, "only the legacy fallback synthesizes ids: #{inspect(files)}"
      refute @protected in files
      assert List.first(files) in [@http, @server]
    end

    test "(c) initial_sync_state_event/3 is gone; /sync state, /members and /initialSync render through Nebu.Matrix.Http.state_event_json/3" do
      protected = ast_of(@protected)
      refute Enum.any?(definitions(@protected), &(&1.name == :initial_sync_state_event)), "the flattener is gone"
      assert calls(protected, :initial_sync_state_event) == [], "and nobody calls it"
      assert Code.ensure_loaded?(Http) and function_exported?(Http, :state_event_json, 3)

      # the /members and /initialSync routes are `get` macros, not defs: count the calls over the whole file
      all_calls = @protected |> ast_of() |> calls(:state_event_json)
      assert length(all_calls) >= 2, "/members and /initialSync both call the renderer (found #{length(all_calls)})"

      http_calls = @http |> ast_of() |> calls(:state_event_json)
      assert http_calls != [], "build_joined_rooms/2 renders the /sync state through the same function"
    end
  end

  describe "AC9 (d) - the upgrade's invitations" do
    test "no function writes an invitation row without the following write_invite_event/5 call (the Admin force-add and the capped-insert helper are the only row-only writers)" do
      row_writers = for %{name: name, body: body} <- definitions(@server), calls(body, :insert_invitation) != [], uniq: true, do: {name, body}

      assert row_writers != []

      for {name, body} <- row_writers, name not in [:admin_add_room_member, :insert_invitation_row] do
        assert calls(body, :write_invite_event) != [], "#{name} writes an invitation row and must write the invite event"
      end
    end

    test "the invitation step has no :pg.get_local_members/1 and no inspect( in its warnings (the wake is cluster-wide, the log value-free)" do
      steps = for %{name: name, body: body} <- definitions(@server), calls(body, :insert_invitation) != [], calls(body, :write_invite_event) != [], name not in [:admin_add_room_member, :insert_invitation_row], do: {name, body}

      assert steps != [], "the invitation step exists"

      for {name, body} <- steps do
        assert calls(body, :get_local_members) == [], "#{name}: no node-local wake"
        for args <- calls(body, :warning), do: refute(calls(args, :inspect) != [], "#{name}: no inspect( in a warning")
      end
    end

    test "a wake after the invite event goes through wake_invitee/2 (:pg.get_members/1)" do
      assert wake = Enum.find(definitions(@server), &(&1.name == :wake_invitee))
      assert calls(wake.body, :get_members) != [] and calls(wake.body, :get_local_members) == []
    end
  end

  describe "AC9 (e) - the reads live in Room.DB, reached through the db seam" do
    test "member_state_slice/2 and direct_invitees/1 are public functions of Room.DB (SQL inline); the slice statement carries its marker comment" do
      defs = definitions(@db)
      assert Enum.any?(defs, &(&1.name == :member_state_slice and &1.kind == :def)), "def member_state_slice in Room.DB"
      assert Enum.any?(defs, &(&1.name == :direct_invitees and &1.arity == 1 and &1.kind == :def)), "def direct_invitees/1 in Room.DB"
      # the module attribute (the inline SQL) that carries the marker comment, and that reuses the ONE tie rule of the sync partition
      {_ast, attrs} =
        Macro.prewalk(ast_of(@db), [], fn
          {:@, _, [{_name, _, [value]}]} = node, acc -> if Enum.any?(string_literals(value), &String.contains?(&1, "/* member_state_slice */")), do: {node, [value | acc]}, else: {node, acc}
          node, acc -> {node, acc}
        end)

      assert [sql_attr] = attrs, "exactly one statement carries the marker the statement-count tests look for"
      assert reads_attr?(sql_attr, :sql_member_rank), "the slice reuses @sql_member_rank"
      assert Enum.any?(string_literals(sql_attr), &String.contains?(&1, "m.room.member"))
    end

    # AC18 (d): the slice runs behind `SET LOCAL statement_timeout = '2s'` in ONE transaction
    test "member_state_slice/2 sets SET LOCAL statement_timeout = '2s' and runs the slice statement in ONE Repo.transaction" do
      assert slice_def = Enum.find(definitions(@db), &(&1.name == :member_state_slice and &1.kind == :def)), "def member_state_slice in Room.DB"

      # the function itself plus the private helpers of Room.DB it calls locally (a `with_statement_timeout/1` helper is as good as the inline form)
      helpers = for d <- definitions(@db), d.kind == :defp, d.name != :member_state_slice, calls(slice_def.body, d.name) != [], do: d.body
      scope = Enum.map([slice_def.body | helpers], &strip_docs/1)
      literals = Enum.flat_map(scope, &string_literals/1)

      assert Enum.any?(literals, &(&1 =~ ~r/\ASET LOCAL statement_timeout\s*=\s*'2s'\z/)), "SET LOCAL statement_timeout = '2s' inside the function"
      assert Enum.any?(scope, &(calls(&1, :transaction) != [])), "inside a transaction (SET LOCAL lasts until its end)"
      assert Enum.sum(Enum.map(scope, &length(calls(&1, :query)))) >= 2, "the SET LOCAL and the slice statement are two statements of that transaction"
    end

    test "the dispatcher reaches both reads through its db seam (never Room.DB.member_state_slice directly) and never falls back for the real module" do
      assert room_db_calls(ast_of(@server), [:member_state_slice, :direct_invitees]) == [], "never a direct Room.DB call: the seam is the db module in a variable"

      defs = definitions(@server)
      assert Enum.any?(defs, fn %{body: body} -> calls(body, :member_state_slice) != [] end), "the dispatcher calls member_state_slice"

      # the decision "a test double without the read -> the joined slice, the real Room.DB -> never": the function that tests for the read names both
      assert Enum.any?(defs, fn %{body: body} -> mentions_atom?(body, :member_state_slice) and aliases?(body, [:Nebu, :Matrix, :Room, :DB]) and aliases?(body, [:Nebu, :Matrix, :Error]) end),
             "a function that checks for member_state_slice names the real Room.DB (no fallback for it) and raises Nebu.Matrix.Error"

      assert Enum.any?(defs, fn %{body: body} -> calls(body, :direct_invitees) != [] end), "the upgrade reads direct_invitees"
    end

    test "Room.DB exports the two reads with the story's arities" do
      assert Code.ensure_loaded?(Nebu.Matrix.Room.DB)
      assert function_exported?(Nebu.Matrix.Room.DB, :member_state_slice, 2)
      assert function_exported?(Nebu.Matrix.Room.DB, :direct_invitees, 1)
    end
  end
end
