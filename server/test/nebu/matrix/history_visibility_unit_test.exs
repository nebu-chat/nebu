defmodule Nebu.Matrix.HistoryVisibilityUnitTest do
  @moduledoc """
  Story `history-visibility-enforcement`, the unit half (NO database for the pins and the fake-module tests; runs in the unit job): AC11 (the source / AST pins over `server/lib`: comments, `@doc`
  texts and strings never count) and AC16 (b) (the seam rule of the viewer-aware reads with test doubles: a TEST db module without them falls back to its unfiltered function, a module WITH
  them is read through them with the CALLER as the viewer; the real modules never fall back: a source pin). One test with the real database (`:integration`) shows the same seam through the
  HTTP stack.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The names are the story's: `fetch_visible_events/5`, `fetch_visible_events_since/4` (`room_id, viewer, last_event_id, limit`), `fetch_visible_event/3` (`event_id, room_id, viewer`),
      `fetch_visible_events_by_relation/6` (`room_id, viewer, event_id, rel_type, limit, opts`), `fetch_state_predecessors(slots, viewer: user_id)`. The helper that decides "viewer-aware or
      fallback" has no binding name: the pins identify it by what it does (a function that names the viewer-aware read AND calls the unfiltered one is the fallback helper).
    * "no client-serving function calls an unfiltered read except through the fallback helper" is pinned as: every function of the dispatcher that calls one of the four unfiltered reads also
      names a viewer-aware read (the helper pairs them), and no function of the client-serving list calls an unfiltered read directly.
    * `/search` has no new function (the first argument of `Search.DB.search_messages/5` IS the viewer): the pin is that the dispatcher passes the TRUSTED session user as the first argument and
      never `request.user_id`.
    * `/relations`: the parent check of a test double without `fetch_visible_event/3` goes through its old `event_in_room?/2`.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nebu.Matrix.EventDispatcher.Server

  @lib Path.expand("../../../lib", __DIR__)
  @server Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex")
  @db Path.join(@lib, "nebu/matrix/room/db.ex")
  @search Path.join(@lib, "nebu/matrix/search/db.ex")
  @behaviour_file Path.join(@lib, "nebu/matrix/room/db_behaviour.ex")

  @unfiltered [:fetch_events, :fetch_events_since, :fetch_event, :fetch_events_by_relation]
  # story sync-stream-position (DELIBERATE amendment, old -> new): the incremental /sync reads through `fetch_visible_events_in_range` (by position)
  @viewer_aware [:fetch_visible_events, :fetch_visible_events_since, :fetch_visible_events_in_range, :fetch_visible_event, :fetch_visible_events_by_relation]
  @client_serving [:get_messages, :initial_join_rooms, :fetch_delta_rooms, :thread_root_updates, :get_event, :get_relations, :attach_thread_aggregations]

  # ─── AST helpers (as membership_state_unit_test.exs: the AST of a file never sees comments, @doc texts count as stripped) ───────────────

  defp ast_of(path), do: path |> File.read!() |> Code.string_to_quoted!() |> strip_docs()

  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, meta, [{doc, _, _}]} when doc in [:doc, :moduledoc, :typedoc] -> {:@, meta, [nil]}
      node -> node
    end)
  end

  defp definitions(path), do: path |> ast_of() |> definitions_of()

  defp definitions_of(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [{:when, _, [{name, _, args} | _]} | _]} = node, acc when kind in [:def, :defp] and is_atom(name) ->
          {node, [%{name: name, arity: length(args || []), kind: kind, body: node} | acc]}

        {kind, _meta, [{name, _, args} | _]} = node, acc when kind in [:def, :defp] and is_atom(name) ->
          {node, [%{name: name, arity: length(args || []), kind: kind, body: node} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # the argument lists of the calls (local `f(..)` and remote `m.f(..)`) with the name `fun`
  defp calls(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {^fun, _meta, args} = node, acc when is_list(args) -> {node, [args | acc]}
        {{:., _, [_mod, ^fun]}, _meta, args} = node, acc when is_list(args) -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp calls_any?(ast, funs), do: Enum.any?(funs, &(calls(ast, &1) != []))

  defp mentions_atom?(ast, atom) do
    {_ast, found} = Macro.prewalk(ast, false, fn node, acc -> if node == atom, do: {node, true}, else: {node, acc} end)
    found
  end

  defp mentions_any?(ast, atoms), do: Enum.any?(atoms, &mentions_atom?(ast, &1))

  defp aliases?(ast, parts) do
    {_ast, found} = Macro.prewalk(ast, false, fn node, acc -> if match?({:__aliases__, _, ^parts}, node), do: {node, true}, else: {node, acc} end)
    found
  end

  defp string_literals(ast) do
    {_ast, acc} = Macro.prewalk(ast, [], fn node, acc -> if is_binary(node), do: {node, [node | acc]}, else: {node, acc} end)
    acc
  end

  defp def_named(path, name), do: path |> definitions() |> Enum.filter(&(&1.name == name))

  # the closure of a function: its own bodies plus the bodies of the local functions it calls (two levels)
  defp closure(defs, names) do
    by_name = Enum.group_by(defs, & &1.name)
    first = for n <- names, d <- Map.get(by_name, n, []), do: d.body
    {_ast, level1} = Macro.prewalk(first, [], fn {name, _, args} = node, acc when is_atom(name) and is_list(args) -> {node, [name | acc]}; node, acc -> {node, acc} end)
    second = for n <- Enum.uniq(level1), n not in names, d <- Map.get(by_name, n, []), do: d.body
    {_ast, level2} = Macro.prewalk(second, [], fn {name, _, args} = node, acc when is_atom(name) and is_list(args) -> {node, [name | acc]}; node, acc -> {node, acc} end)
    third = for n <- Enum.uniq(level2), n not in names, n not in level1, d <- Map.get(by_name, n, []), do: d.body
    first ++ second ++ third
  end

  # ═══ AC11 (a): the client-serving functions read through the viewer-aware reads ═══════════════════

  describe "AC11 (a) - the dispatcher's event reads" do
    test "no client-serving function calls an unfiltered read directly; a function that does also names a viewer-aware read" do
      defs = definitions(@server)

      for name <- @client_serving, d <- Enum.filter(defs, &(&1.name == name)) do
        refute calls_any?(d.body, @unfiltered), "#{name}/#{d.arity} calls an unfiltered read directly"
      end

      helpers = for d <- defs, calls_any?(d.body, @unfiltered), do: d
      assert helpers != [], "control: the test-module fallback exists"
      assert length(helpers) <= 8, "a handful of fallback helpers, not a scatter of unfiltered calls: #{inspect(Enum.map(helpers, & &1.name))}"

      for h <- helpers do
        assert mentions_any?(h.body, @viewer_aware), "#{h.name}/#{h.arity} calls an unfiltered read without naming the viewer-aware one it replaces"
      end
    end

    test "the seven client-serving functions reach a viewer-aware read (initial_join_rooms on both code paths)" do
      defs = definitions(@server)

      expected = %{
        get_messages: [:fetch_visible_events],
        initial_join_rooms: [:fetch_visible_events],
        fetch_delta_rooms: [:fetch_visible_events_in_range],
        thread_root_updates: [:fetch_visible_event],
        get_event: [:fetch_visible_event],
        get_relations: [:fetch_visible_event, :fetch_visible_events_by_relation],
        attach_thread_aggregations: [:fetch_visible_events_by_relation]
      }

      for {name, wanted} <- expected do
        bodies = closure(defs, [name])
        assert bodies != [], "#{name} exists"

        for read <- wanted do
          assert Enum.any?(bodies, &mentions_atom?(&1, read)) or Enum.any?(bodies, &(calls(&1, read) != [])), "#{name} does not reach #{read}"
        end
      end

      # initial_join_rooms has TWO code paths (the normal one and the room-process restart): both read the visible page, through a viewer-aware read or a local helper that names one
      readers = for d <- defs, d.name not in @client_serving, mentions_any?(d.body, @viewer_aware), uniq: true, do: d.name
      assert [initial] = def_named(@server, :initial_join_rooms)
      paths = Enum.sum(for name <- readers ++ @viewer_aware, do: length(calls(initial.body, name)))
      assert paths >= 2, "both code paths of initial_join_rooms read the visible page (found #{paths})"
    end

    test "the dispatcher never filters in the BEAM: no `invited` / `joined` / `world_readable` literal in the read paths and no `allow` function" do
      defs = definitions(@server)
      literals = defs |> closure(@client_serving) |> Enum.flat_map(&string_literals/1)
      refute Enum.any?(literals, &(&1 in ["invited", "joined", "world_readable"])), "the rule lives in ONE SQL fragment"
      refute Enum.any?(defs, &(&1.name in [:allow, :allow?, :visible?, :history_visible?])), "no Elixir re-implementation of the rule"
    end
  end

  describe "AC11 (b) - the predecessor lookups" do
    test "every call of fetch_state_predecessors passes viewer: (the old-double twin sits in the function that also passes it)" do
      defs = definitions(@server)
      calling = for d <- defs, calls(d.body, :fetch_state_predecessors) != [], do: d
      assert calling != []

      for d <- calling do
        args_lists = calls(d.body, :fetch_state_predecessors)
        with_viewer = Enum.filter(args_lists, fn args -> Enum.any?(args, &keyword_with_viewer?/1) end)
        assert with_viewer != [], "#{d.name}/#{d.arity} calls fetch_state_predecessors without viewer:"
      end

      # the callers named by the story: the timeline reads, the leave windows, the state events
      for name <- [:event_maps_to_core_events, :attach_leave_predecessors, :attach_predecessors_to_state_events] do
        bodies = closure(defs, [name])
        assert Enum.any?(bodies, &(calls(&1, :fetch_state_predecessors) != [])), "#{name} reaches fetch_state_predecessors"
      end
    end
  end

  describe "AC11 (b) - never a nil viewer" do
    test "no dispatcher call passes `viewer: nil` or `viewer: \"\"` (a nil viewer serves no predecessor keys: STORY-5)" do
      {_ast, found} =
        Macro.prewalk(ast_of(@server), [], fn
          {:viewer, v} = node, acc when is_nil(v) or v == "" -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      assert found == []
    end
  end

  defp keyword_with_viewer?(arg) when is_list(arg), do: Enum.any?(arg, &match?({:viewer, _}, &1))
  defp keyword_with_viewer?(_), do: false

  # ═══ AC11 (c): the fallback helper never falls back for the real module ═════════════════════════

  describe "AC11 (c) - the real modules never fall back" do
    test "a dispatcher function pairs the viewer-aware read with the unfiltered one and compares the real Nebu.Matrix.Room.DB" do
      defs = definitions(@server)

      guard =
        Enum.find(defs, fn d ->
          aliases?(d.body, [:Nebu, :Matrix, :Room, :DB]) and
            (calls(d.body, :!=) != [] or calls(d.body, :==) != [] or calls(d.body, :!==) != []) and
            (calls(d.body, :ensure_loaded?) != [] and calls(d.body, :function_exported?) != [])
        end)

      assert guard, "a function names Nebu.Matrix.Room.DB, compares it and decides on the existence of the viewer-aware read"
    end

    test "the search path passes the TRUSTED session user as the first argument of search_messages, never request.user_id" do
      assert [search] = Enum.filter(definitions(@server), &(&1.name == :search_messages and &1.arity == 2))
      assert [args | _] = Enum.filter(calls(search.body, :search_messages), &(length(&1) == 5))
      assert match?({name, _, ctx} when is_atom(name) and is_atom(ctx) and name != :request, hd(args)), "the first argument is a variable bound from the trusted identity, not from the request"
      assert calls(search.body, :trusted_identity) != [], "the viewer comes from the request metadata"

      {_ast, request_user_reads} =
        Macro.prewalk(search.body, 0, fn
          {{:., _, [{:request, _, _}, :user_id]}, _, _} = node, acc -> {node, acc + 1}
          node, acc -> {node, acc}
        end)

      assert request_user_reads == 0, "request.user_id is never read (IDOR): the body's user is not the viewer"
    end
  end

  # ═══ AC11 (d): Search.DB ════════════════════════════════════════════════════════════════════════

  describe "AC11 (d) - Search.DB" do
    test "it interpolates Nebu.Matrix.Room.DB.history_visibility_sql() and both statements keep the membership subquery `left_at IS NULL`" do
      ast = ast_of(@search)
      {_ast, found} = Macro.prewalk(ast, 0, fn {{:., _, [{:__aliases__, _, [:Nebu, :Matrix, :Room, :DB]}, :history_visibility_sql]}, _, []} = node, acc -> {node, acc + 1}; node, acc -> {node, acc} end)
      assert found >= 1, "Search.DB reuses the ONE fragment through Room.DB.history_visibility_sql/0"

      # both statements (with and without the room filter) are module attributes that carry the membership subquery
      {_ast, statements} =
        Macro.prewalk(ast, [], fn
          {:@, _, [{name, _, [value]}]} = node, acc when name in [:sql_search_messages, :sql_search_messages_with_room_filter] -> {node, [{name, value} | acc]}
          node, acc -> {node, acc}
        end)

      assert length(statements) == 2
      source = File.read!(@search)
      assert length(Regex.scan(~r/left_at IS NULL/, source)) >= 2, "the membership gate stays in both statements"
      assert Nebu.Matrix.Search.DB.sql_search_messages() =~ "left_at IS NULL"
    end

    test "the statement of the search carries the marker; Room.DB exports the fragment and the four reads with the story's arities" do
      assert Code.ensure_loaded?(Nebu.Matrix.Room.DB)
      assert function_exported?(Nebu.Matrix.Room.DB, :history_visibility_sql, 0)
      assert function_exported?(Nebu.Matrix.Room.DB, :fetch_visible_events, 5)
      assert function_exported?(Nebu.Matrix.Room.DB, :fetch_visible_events_since, 4)
      assert function_exported?(Nebu.Matrix.Room.DB, :fetch_visible_event, 3)
      assert function_exported?(Nebu.Matrix.Room.DB, :fetch_visible_events_by_relation, 6)
      assert function_exported?(Nebu.Matrix.Room.DB, :fetch_state_predecessors, 2)
      assert Nebu.Matrix.Search.DB.sql_search_messages() =~ "/* history_visibility */"
      # the unfiltered reads stay for the internal callers (the redaction writer, the tests)
      for {name, arity} <- [fetch_events: 4, fetch_events_since: 3, fetch_event: 2, fetch_events_by_relation: 5], do: assert(function_exported?(Nebu.Matrix.Room.DB, name, arity))
    end

    test "the behaviour declares the four viewer-aware callbacks as OPTIONAL (the 20 old fakes stay valid)" do
      ast = ast_of(@behaviour_file)

      {_ast, optional} =
        Macro.prewalk(ast, [], fn
          {:@, _, [{:optional_callbacks, _, [list]}]} = node, acc -> {node, list ++ acc}
          node, acc -> {node, acc}
        end)

      for {name, arity} <- [fetch_visible_events: 5, fetch_visible_events_since: 4, fetch_visible_event: 3, fetch_visible_events_by_relation: 6] do
        assert {name, arity} in optional, "#{name}/#{arity} is an @optional_callbacks entry"
      end
    end
  end

  # ═══ AC11 (e): no inspect( in the touched error paths ═══════════════════════════════════════════

  describe "AC11 (e) - value-free error paths" do
    test "no inspect( in get_event, get_relations, search_messages, the dispatcher helpers of the viewer-aware reads and the new Room.DB reads" do
      defs = definitions(@server)

      touched =
        for d <- defs, d.name in [:get_event, :get_relations, :search_messages] or mentions_any?(d.body, @viewer_aware) or calls_any?(d.body, @viewer_aware), do: d

      assert touched != []

      for d <- touched do
        assert calls(d.body, :inspect) == [], "#{d.name}/#{d.arity} calls inspect( in an error path (a Postgrex error can echo the statement)"
      end

      for d <- definitions(@db), d.name in @viewer_aware do
        assert calls(d.body, :inspect) == [], "Room.DB.#{d.name} calls inspect("
      end
    end
  end

  # ═══ AC16 (b): the seam, with test doubles ══════════════════════════════════════════════════════

  defmodule Registry do
    @moduledoc false
    def get_state(_room), do: Application.fetch_env!(:nebu, :atdd_hv_unit_state)
  end

  # an OLD double: only the unfiltered functions the old code called
  defmodule OldDB do
    @moduledoc false
    def event_in_room?(_event_id, _room), do: true
    def fetch_events_by_relation(_room, _event_id, _rel_type, _limit, _opts), do: {:ok, [row("$old_visible", 10), row("$old_hidden", 20)]}

    def row(id, ts),
      do: %{"event_id" => id, "room_id" => "!unit:test.local", "sender" => "@a:test.local", "event_type" => "m.room.message", "content" => %{"body" => id}, "origin_server_ts" => ts, "state_key" => nil}
  end

  # a double WITH the viewer-aware reads: it must be preferred, with the CALLER as the viewer, and the unfiltered functions must never be called
  defmodule ViewerDB do
    @moduledoc false
    def event_in_room?(_event_id, _room), do: raise("the unfiltered parent check must not be used")
    def fetch_events_by_relation(_room, _event_id, _rel_type, _limit, _opts), do: raise("the unfiltered relation read must not be used")

    def fetch_visible_event(event_id, room, viewer) do
      send(self(), {:visible_event, event_id, room, viewer})
      {:ok, %{"event_id" => event_id}}
    end

    def fetch_visible_events_by_relation(room, viewer, event_id, rel_type, limit, opts) do
      send(self(), {:visible_relations, room, viewer, event_id, rel_type, limit, opts})
      {:ok, [OldDB.row("$new_visible", 10)]}
    end
  end

  defmodule NoParentDB do
    @moduledoc false
    def event_in_room?(_event_id, _room), do: false
    def fetch_events_by_relation(_room, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
  end

  @room "!unit:test.local"
  @caller "@caller:test.local"

  setup do
    Application.put_env(:nebu, :atdd_hv_unit_state, %{room_id: @room, members: MapSet.new([@caller]), power_levels: %{"users" => %{}}})
    prior = for key <- [:room_registry_module, :messages_db_module], do: {key, Application.fetch_env(:event_dispatcher, key)}
    Application.put_env(:event_dispatcher, :room_registry_module, Registry)

    on_exit(fn ->
      Application.delete_env(:nebu, :atdd_hv_unit_state)

      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:event_dispatcher, key, v)
          :error -> Application.delete_env(:event_dispatcher, key)
        end
      end
    end)

    :ok
  end

  defp relations(user), do: %Core.GetRelationsRequest{user_id: user, room_id: @room, event_id: "$parent", rel_type: "", event_type: "", dir: "b", from: "", limit: 10}
  defp stream(user), do: Nebu.Matrix.Http.stream(user)

  describe "AC16 (b) - the seam with test doubles" do
    test "the viewer is the TRUSTED stream user, never request.user_id (a spoofed body user is not the viewer)" do
      Application.put_env(:event_dispatcher, :messages_db_module, ViewerDB)
      resp = Server.get_relations(%{relations(@caller) | user_id: "@spoof:test.local"}, stream(@caller))

      assert Enum.map(resp.events, & &1.event_id) == ["$new_visible"]
      assert_received {:visible_event, "$parent", @room, @caller}
      assert_received {:visible_relations, @room, @caller, "$parent", "", 10, _opts}
      refute_received {:visible_event, _, _, "@spoof:test.local"}
    end

    test "an OLD double (event_in_room?/2, fetch_events_by_relation/5 only): /relations is served from them, unchanged" do
      Application.put_env(:event_dispatcher, :messages_db_module, OldDB)
      resp = Server.get_relations(relations(@caller), stream(@caller))
      assert Enum.map(resp.events, & &1.event_id) == ["$old_visible", "$old_hidden"]
    end

    test "the unknown parent of an old double is the fixed `Event not found` 404 (M_NOT_FOUND), not `Room not found`" do
      Application.put_env(:event_dispatcher, :messages_db_module, NoParentDB)
      error = assert_raise Nebu.Matrix.Error, fn -> Server.get_relations(relations(@caller), stream(@caller)) end
      assert error.status == Nebu.Matrix.Status.not_found()
      assert error.errcode == "M_NOT_FOUND" and error.message == "Event not found"
    end

    test "a double WITH the viewer-aware reads is read through them with the CALLER as the viewer, never its unfiltered reads" do
      Application.put_env(:event_dispatcher, :messages_db_module, ViewerDB)
      resp = Server.get_relations(relations(@caller), stream(@caller))

      assert Enum.map(resp.events, & &1.event_id) == ["$new_visible"]
      assert_received {:visible_event, "$parent", @room, @caller}
      assert_received {:visible_relations, @room, @caller, "$parent", "", 10, %{dir: "b", event_type: ""}}
    end
  end

  # a delegate of the real Room.DB that exports NOTHING viewer-aware
  defmodule UnfilteredDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions),
        name not in [:fetch_visible_events, :fetch_visible_events_since, :fetch_visible_events_in_range, :fetch_visible_event, :fetch_visible_events_by_relation] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end
  end
end

defmodule Nebu.Matrix.HistoryVisibilityUnitTest.SeamHttpTest do
  @moduledoc """
  AC16 (b) through the real HTTP stack (`@moduletag :integration`; a module of its own because the unit module above replaces the room registry with a fake): a test double that exports no
  viewer-aware read serves the UNFILTERED page (the old fakes keep working), the real module the filtered one.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.HistoryVisibilityTestSupport

  @moduletag :integration

  test "AC16 (b) over HTTP: a double without the viewer-aware reads serves the unfiltered page, the real module the filtered one" do
    Nebu.Matrix.MembershipStateTestSupport.setup_env!()
    s = scenario!("joined")

    {real, _, real_raw} = msgs!(s.b, s.room)
    refute s.m1.id in ids(real)
    refute_leak!(real_raw, s.m1)

    prior = Application.fetch_env(:event_dispatcher, :messages_db_module)
    Application.put_env(:event_dispatcher, :messages_db_module, Nebu.Matrix.HistoryVisibilityUnitTest.UnfilteredDB)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:event_dispatcher, :messages_db_module, v)
        :error -> Application.delete_env(:event_dispatcher, :messages_db_module)
      end
    end)

    {fallback, _, fallback_raw} = msgs!(s.b, s.room)
    assert s.m1.id in ids(fallback), "control of the seam: the double has no viewer-aware read, so the unfiltered page is served"
    assert fallback_raw =~ s.m1.marker
  end
end
