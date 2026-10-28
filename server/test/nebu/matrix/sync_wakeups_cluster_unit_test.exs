defmodule Nebu.Matrix.SyncWakeupsClusterUnitTest do
  @moduledoc """
  Story `sync-wakeups-cluster-wide` (follow-up `fe`), D1 / D2 (a) / Scenario 3: the SOURCE guard (AST walks over `server/lib`, comments and
  strings never count; NO database, runs in the unit job).

  The long-poll `/sync` (`wait_loop/2` of `Nebu.Matrix.EventDispatcher.Server`) wakes on `{:new_event, _}`, `{:new_invite, _}`, `{:new_join, _}`,
  `{:new_leave, _}` and `{:account_data_changed, _}` only. Every `:pg` send of one of these messages goes through `:pg.get_members/1`
  (cluster-wide), never `:pg.get_local_members/1` (the cluster-safety skill): a sync task on another node is otherwise woken only by its timeout.

  What is pinned (the pin is the gate when the two-node test, `sync_wakeups_cluster_test.exs`, cannot run):

    1. no function of `Room.Server` / `EventDispatcher.Server` that mentions one of the five messages calls `:pg.get_local_members/1`;
    2. the scan of ALL of `server/lib`: the only `get_local_members` left are the two typing broadcasts of `Room.Server` (`set_typing` handle_call,
       `typing_expire` handle_info; they send `{:typing_update, _, _}`, which no process consumes: D1 exception);
    3. the exception stays valid: nobody in `server/lib` consumes `:typing_update`;
    4. positive control + self-test: the scan finds the existing `:pg.get_members/1` callers, and the guard FAILS on a node-local sender (code
       string and a mutation of the real source), so a green run is not vacuous.

  Limit of 1 (the function mentions the message): a helper that gets the message as a variable escapes it. That is why 2 counts EVERY mention of the
  atom `:get_local_members` in `server/lib`, helper or not.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @room_server "nebu/matrix/room/server.ex"
  @dispatcher "nebu/matrix/event_dispatcher/server.ex"
  @account_data "nebu/matrix/room_account_data_store.ex"

  @sync_messages [:new_event, :new_join, :new_leave, :new_invite, :account_data_changed]
  @typing_clause_markers [:set_typing, :typing_expire]

  # ─── AST helpers (same idiom as membership_state_unit_test.exs and state_writer_redaction_unit_test.exs) ────────────────────

  # parsed once per module (setup_all): ~240 files
  setup_all do
    %{asts: for(path <- Path.wildcard(Path.join(@lib, "**/*.ex")), do: {Path.relative_to(path, @lib), path |> File.read!() |> Code.string_to_quoted!()})}
  end

  defp ast_of(relative), do: @lib |> Path.join(relative) |> File.read!() |> Code.string_to_quoted!()

  # every `def` / `defp` clause: %{name, arity, head, body} (the body is the whole `do` / `rescue` keyword list)
  defp definitions(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] and is_list(body) ->
          {node, [%{kind: kind, name: fun_name(head), arity: fun_arity(head), head: head, body: body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}), do: name

  defp fun_arity({:when, _, [head | _]}), do: fun_arity(head)
  defp fun_arity({_name, _, args}) when is_list(args), do: length(args)
  defp fun_arity(_head), do: 0

  # the remote calls `:pg.<fun>(...)` of an AST
  # (also the LOCAL call `get_local_members(..)` that an `import :pg` would allow; the scan forbids the import anyway)
  defp pg_calls(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [:pg, ^fun]}, _, args} = node, acc -> {node, [args | acc]}
        {^fun, _, args} = node, acc when is_list(args) -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  # how often an atom appears anywhere: a remote call, a capture `&:pg.get_local_members/1`, an `apply(:pg, :get_local_members, ..)`, and a LOCAL
  # call node `{atom, meta, args}` (a prewalk does not visit the name of a 3-tuple call node)
  defp atom_count(ast, atom) do
    {_ast, n} =
      Macro.prewalk(ast, 0, fn
        ^atom = node, n -> {node, n + 1}
        {^atom, _meta, args} = node, n when is_list(args) -> {node, n + 1}
        node, n -> {node, n}
      end)

    n
  end

  defp mentions_atom?(ast, atom), do: atom_count(ast, atom) > 0

  # a literal tuple `{:new_event, _}` ... (the shape of every sync wake-up message: 2-tuples are literals, larger tuples are `{:{}, _, elements}`)
  defp sends_sync_message?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {tag, _payload} = node, _found when tag in @sync_messages -> {node, true}
        {:{}, _meta, [tag | _]} = node, _found when tag in @sync_messages -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  # `import :pg` / `alias :pg` anywhere in an AST: the way to call `get_local_members` without the `:pg.` the scan looks for
  defp imports_pg?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {kind, _meta, [:pg | _]} = node, _found when kind in [:import, :alias, :require] -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  defp typing_clause?(%{head: head}), do: Enum.any?(@typing_clause_markers, &mentions_atom?(head, &1))

  # ─── the guard (D2 (a)); both functions take an AST so the self-test can feed code strings and mutated sources ─────────────────

  # names of the functions that mention a sync wake-up message AND call :pg.get_local_members/1
  defp sender_violations(ast) do
    for d <- definitions(ast), sends_sync_message?(d.body), pg_calls(d.body, :get_local_members) != [], uniq: true, do: d.name
  end

  # names (and typing flag) of the functions that call :pg.get_local_members/1, whatever they send
  defp local_callers(ast) do
    for d <- definitions(ast), pg_calls(d.body, :get_local_members) != [], do: {d.name, typing_clause?(d)}
  end

  defp callers_of(ast, fun), do: for(d <- definitions(ast), pg_calls(d.body, fun) != [], uniq: true, do: d.name)

  # ─── D2 (a): no node-local sender on the sync wake-up path ──────────────────────────────────────────────────────────────────

  describe "D2 (a) - no node-local :pg sender" do
    test "Room.Server: no function that sends a sync wake-up message (the five wait_loop/2 messages) calls :pg.get_local_members/1" do
      assert sender_violations(ast_of(@room_server)) == [],
             "node-local wake-up (use :pg.get_members/1, cluster-safety): #{inspect(sender_violations(ast_of(@room_server)))}"
    end

    test "EventDispatcher.Server: no function that sends a sync wake-up message (the five wait_loop/2 messages) calls :pg.get_local_members/1" do
      assert sender_violations(ast_of(@dispatcher)) == [],
             "node-local wake-up (use :pg.get_members/1, cluster-safety): #{inspect(sender_violations(ast_of(@dispatcher)))}"
    end

    test "scan of server/lib: only the two typing functions of Room.Server still use :get_local_members (a helper with a variable message cannot hide)", %{asts: asts} do
      callers = for {file, ast} <- asts, {name, typing?} <- local_callers(ast), do: {file, name, typing?}

      assert Enum.sort(callers) == [{@room_server, :handle_call, true}, {@room_server, :handle_info, true}],
             "get_local_members outside the two typing broadcasts of Room.Server: #{inspect(callers)}"

      # not only calls in def / defp: ANY mention of the atom (a capture, apply/3, a macro) counts
      mentions = for {file, ast} <- asts, n = atom_count(ast, :get_local_members), n > 0, do: {file, n}
      assert mentions == [{@room_server, 2}], "every mention of :get_local_members in server/lib: #{inspect(mentions)}"
    end

    test "no module of server/lib imports, aliases or requires :pg (a bare get_local_members(..) call would escape the scan for :pg.get_local_members)", %{asts: asts} do
      assert for({file, ast} <- asts, imports_pg?(ast), do: file) == []
    end

    test "the two typing functions send {:typing_update, _, _} and no message that wait_loop/2 waits for (the reason of the exception, D1)" do
      typing = for d <- definitions(ast_of(@room_server)), typing_clause?(d), pg_calls(d.body, :get_local_members) != [], do: d

      assert length(typing) == 2, "the set_typing handle_call and the typing_expire handle_info"

      for d <- typing do
        assert mentions_atom?(d.body, :typing_update), "#{d.name}: sends :typing_update"
        refute sends_sync_message?(d.body), "#{d.name}: must not send a message of wait_loop/2"
      end
    end

    test "the exception stays valid: no process in server/lib consumes :typing_update (a consumer would make the typing broadcast cluster-wide too)", %{asts: asts} do
      users = for {file, ast} <- asts, mentions_atom?(ast, :typing_update), do: file
      assert users == [@room_server]

      # inside Room.Server only the two typing functions mention it (a `receive` / handle_info clause that matches it would be a consumer)
      mentioning = for d <- definitions(ast_of(@room_server)), mentions_atom?(d.body, :typing_update) or mentions_atom?(d.head, :typing_update), do: {d.name, typing_clause?(d)}
      assert Enum.sort(mentioning) == [{:handle_call, true}, {:handle_info, true}]
    end
  end

  # ─── positive control + self-test: the guard sees cluster-wide senders and fails on a node-local one ──────────────────────────

  describe "D2 (a) - guard self-test" do
    test "positive control: the scan finds the :pg.get_members/1 callers (broadcast_room, wake_user, wake_invitee, notify_sync)" do
      room = ast_of(@room_server)
      assert :broadcast_room in callers_of(room, :get_members)
      assert :wake_user in callers_of(room, :get_members)
      assert :wake_invitee in callers_of(ast_of(@dispatcher), :get_members)
      assert :notify_sync in callers_of(ast_of(@account_data), :get_members)

      # the senders of the sync messages are seen by the guard's own predicate (it is not looking at an empty set)
      assert Enum.any?(definitions(room), &(sends_sync_message?(&1.body) and pg_calls(&1.body, :get_members) != []))
      assert Enum.any?(definitions(ast_of(@dispatcher)), &(sends_sync_message?(&1.body) and pg_calls(&1.body, :get_members) != []))
    end

    test "self-test: the guard flags a node-local sender of each message and accepts the same code with :pg.get_members/1" do
      for message <- @sync_messages do
        bad = "defmodule M do\n  def wake(group, x), do: Enum.each(:pg.get_local_members(group), &send(&1, {#{inspect(message)}, x}))\nend\n"
        good = String.replace(bad, "get_local_members", "get_members")

        assert sender_violations(Code.string_to_quoted!(bad)) == [:wake], "#{message}: the guard must fail on a node-local sender"
        assert sender_violations(Code.string_to_quoted!(good)) == [], "#{message}: the cluster-wide sender is accepted"
      end
    end

    test "self-test: the scan flags a node-local helper with a variable message (the per-function guard cannot see it) and tells the typing shape" do
      helper = ~S"""
      defmodule M do
        defp wake_user(user_id, message), do: Enum.each(:pg.get_local_members("user:#{user_id}"), &send(&1, message))
        def leave(user_id), do: wake_user(user_id, {:new_leave, "!r"})
        def handle_call({:set_typing, u, t}, _from, state) do
          Enum.each(:pg.get_local_members("room:r"), &send(&1, {:typing_update, u, t}))
          {:reply, :ok, state}
        end
      end
      """

      ast = Code.string_to_quoted!(helper)
      assert sender_violations(ast) == [], "the per-function guard misses the variable message (the limit named in the moduledoc)"
      assert Enum.sort(local_callers(ast)) == [{:handle_call, true}, {:wake_user, false}], "the scan sees both, and tells the typing shape from the helper"
    end

    test "self-test: an imported local call get_local_members(..) with a 3-tuple message is flagged by the guard, the scan count and the import check" do
      imported = ~S"""
      defmodule M do
        import :pg
        def leave(user_id), do: Enum.each(get_local_members("user:#{user_id}"), &send(&1, {:new_leave, "!r", user_id}))
      end
      """

      ast = Code.string_to_quoted!(imported)
      assert imports_pg?(ast)
      assert sender_violations(ast) == [:leave]
      assert atom_count(ast, :get_local_members) == 1
      refute imports_pg?(Code.string_to_quoted!("defmodule M do\n  alias Nebu.Foo\n  require Logger\nend\n"))
    end

    test "self-test (mutated real source): broadcast_room/2 and wake_invitee/2 reverted fail the guard, wake_user/2 reverted fails the scan" do
      source = File.read!(Path.join(@lib, @room_server))

      # the mutation is aimed at the one-line helper by name (an edit that renames the helper fails the `refute`s below, loudly)
      reverted = Regex.replace(~r/(defp broadcast_room\([^\n]*?:pg\.)get_members/, source, "\\1get_local_members", global: false)
      refute reverted == source, "the mutation applied (the helper broadcast_room/2 reads :pg.get_members)"
      assert :broadcast_room in sender_violations(Code.string_to_quoted!(reverted))

      reverted = Regex.replace(~r/(defp wake_user\([^\n]*?:pg\.)get_members/, source, "\\1get_local_members", global: false)
      refute reverted == source, "the mutation applied (the helper wake_user/2 reads :pg.get_members)"
      assert {:wake_user, false} in local_callers(Code.string_to_quoted!(reverted))
      assert length(local_callers(Code.string_to_quoted!(reverted))) == length(local_callers(Code.string_to_quoted!(source))) + 1, "the scan finds exactly the one new node-local caller"

      dispatcher = File.read!(Path.join(@lib, @dispatcher))
      reverted = Regex.replace(~r/(defp wake_invitee\([^\n]*\n[^\n]*?:pg\.)get_members/, dispatcher, "\\1get_local_members", global: false)
      refute reverted == dispatcher, "the mutation applied (the helper wake_invitee/2 reads :pg.get_members)"
      assert :wake_invitee in sender_violations(Code.string_to_quoted!(reverted))
    end
  end
end
