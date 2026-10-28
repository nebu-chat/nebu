defmodule Nebu.Matrix.SyncTokenPerDeviceDispatcherTest do
  @moduledoc """
  Acceptance tests for story `sync-token-per-device` (epic oauth-broker, follow-up `fd`), core half, D1 / D3 / D4 and the proto field:
  which `sync_tokens` key every statement of the core uses, and WHAT it writes. The core runs for real (`Nebu.Matrix.EventDispatcher.Server`,
  real rooms through HTTP, real `Nebu.Repo`); only the `:event_dispatcher, :pg_store_module` seam is wrapped by a SPY that delegates every call to
  `Nebu.Matrix.Session.PgStore.Postgres` and records it. So the tests see the calls (which function, which key, the anchor) AND the rows.

    * D1: `get_initial_sync/2` takes `device_id` from the request (new proto field 2 of `GetInitialSyncRequest`); the route passes the authenticated
      device (never a request parameter); a device-less request (`""`) keeps the per-user 3-arity functions and the `''` row (D2).
    * D4: the initial sync persists `(user, device, token, REAL anchor)` once; `fallback_to_initial_sync/2` no longer writes a second row with
      `last_event_id = nil` (which `resolve_since_ts(nil)` reads as timestamp 0: replay of every room's last events and every old invitation as new).
    * D3: a token that sits under `''` is NOT read by a device-bound request (no second lookup, no migration): one fallback.
    * The proto parity doc: `server/lib/pb/core.pb.ex` and `proto/core.proto` carry `device_id` (field 2) on `GetInitialSyncRequest`.

  Written without `@behaviour` on the spy (the behaviour gains callbacks in this story; the spy needs only the six token functions).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @proto Path.expand("../../../../proto/core.proto", __DIR__)
  @table :fd_pg_spy

  defmodule Spy do
    @moduledoc false
    alias Nebu.Matrix.Session.PgStore.Postgres
    @table :fd_pg_spy

    # the table is owned by the setup_all process (lives for the whole module); a late call from a background process after the module is
    # done must not raise (the Spy stays installed until on_exit restores the seam)
    defp log(call) do
      :ets.insert(@table, {System.unique_integer([:monotonic]), call})
    rescue
      ArgumentError -> :ok
    end

    def calls, do: @table |> :ets.tab2list() |> Enum.sort() |> Enum.map(&elem(&1, 1))
    def reset, do: :ets.delete_all_objects(@table)

    # DELIBERATE amendment by story sync-stream-position (D7), old -> new: the spy used to name the six token functions one by one. The ONE write of a /sync response is
    # now the guarded persist transaction of the new story (its function name is the implementer's), so the spy delegates EVERY function of the Postgres store and records
    # `{kind, arity, args}`: `kind` is :persist for every function whose name starts with "persist", :get for `get_since_token`, :invalidate for `invalidate_session`,
    # and the function name for anything else (the positions, ...). The assertions below never name a persist function.
    for {name, arity} <- Postgres.__info__(:functions), name != :__info__ do
      args = Macro.generate_arguments(arity, __MODULE__)
      kind = Atom.to_string(name)

      kind =
        cond do
          String.starts_with?(kind, "persist") -> :persist
          name == :get_since_token -> :get
          name == :invalidate_session -> :invalidate
          true -> name
        end

      def unquote(name)(unquote_splicing(args)) do
        log({unquote(kind), unquote(arity), unquote(args)})
        apply(Postgres, unquote(name), unquote(args))
      end
    end
  end

  setup_all do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  # ═══ proto field (no database) ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "GetInitialSyncRequest.device_id (pb struct and proto parity doc)" do
    test "the struct carries device_id with the proto3 default \"\" next to user_id" do
      request = struct(Core.GetInitialSyncRequest)
      assert Map.has_key?(request, :device_id), "Core.GetInitialSyncRequest has no device_id field"
      assert request.device_id == ""
      assert request.user_id == ""
      assert struct(Core.GetInitialSyncRequest, user_id: "@u:t", device_id: "DEV").device_id == "DEV"
    end

    test "proto/core.proto documents `string device_id = 2;` in message GetInitialSyncRequest next to user_id = 1" do
      assert [_, rest] = String.split(File.read!(@proto), "message GetInitialSyncRequest {", parts: 2)
      block = rest |> String.split("}", parts: 2) |> hd()

      assert block =~ ~r/string\s+user_id\s*=\s*1\s*;/
      assert block =~ ~r/string\s+device_id\s*=\s*2\s*;/, "the parity doc names the new field 2 (ADR-021: hand-maintained structs, documented in the .proto)"
    end

    test "GetSyncDeltaRequest keeps its device_id = 4 (Story 9-22): the delta already carried it, the route did not use it" do
      assert [_, rest] = String.split(File.read!(@proto), "message GetSyncDeltaRequest {", parts: 2)
      assert (rest |> String.split("}", parts: 2) |> hd()) =~ ~r/string\s+device_id\s*=\s*4\s*;/
    end
  end

  # ═══ the key and the anchor (database + spy) ═════════════════════════════════════════════════════════════════════════════════

  describe "which key, which write (spy over the real PgStore)" do
    @describetag :integration

    setup do
      Nebu.Test.ServerName.pin!(T.server_name())

      Spy.reset()

      previous = Application.fetch_env(:event_dispatcher, :pg_store_module)
      Application.put_env(:event_dispatcher, :pg_store_module, Spy)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:event_dispatcher, :pg_store_module, v)
          :error -> Application.delete_env(:event_dispatcher, :pg_store_module)
        end
      end)

      uid = T.provision_user!()
      dev = "FDD" <> String.upcase(T.rand(3))
      at = T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at
      me = %{uid: uid, at: at, dev: dev}
      o = S.user!("FDO")
      room = S.invite_room(o, [me])
      S.tick()
      S.say!(o, room, S.marker("seed"))
      S.tick()
      Spy.reset()

      {:ok, me: me, o: o, room: room}
    end

    defp initial(uid, device_id), do: Server.get_initial_sync(struct(Core.GetInitialSyncRequest, user_id: uid, device_id: device_id), Nebu.Matrix.Http.stream(uid))

    defp delta(uid, device_id, since),
      do: Server.get_sync_delta(%Core.GetSyncDeltaRequest{user_id: uid, device_id: device_id, since_token: since, timeout_ms: 0}, Nebu.Matrix.Http.stream(uid))

    defp persists(calls), do: for({:persist, _, _} = c <- calls, do: c)
    defp gets(calls), do: for({:get, _, _} = c <- calls, do: c)

    # DELIBERATE amendment by story sync-stream-position, old -> new: "exactly one token write of the request, under the request's key" is asserted without naming the
    # persist function (arity 3 / 4 used to tell the per-user key from the device key): exactly ONE `:persist` call, for this user, and the ROWS show the key.
    defp assert_one_persist_for(calls, uid) do
      assert [{:persist, _arity, [^uid | _]}] = persists(calls), "exactly one token write of the request, for the user: #{inspect(persists(calls))}"
    end

    defp token_state(uid, dev), do: T.sql!("SELECT since_token, stream_version, generation FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows
    defp cursor_rows(uid, dev), do: T.sql!("SELECT room_id, pos, class FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows

    # D1 / D2 / D3: every token LOOKUP of the request is under the given key (how many lookups there are is free), none under the other key
    defp assert_lookups_only_under(calls, {:device, uid, dev}) do
      assert Enum.all?(gets(calls), &(&1 == {:get, 2, [uid, dev]})), "lookups: #{inspect(gets(calls))}"
      refute Enum.any?(calls, &match?({:get, 1, _}, &1)), "no per-user ('') lookup: #{inspect(calls)}"
      # (the persist arities no longer tell the keys apart, story sync-stream-position: the rows do, see the tests)
    end

    defp assert_lookups_only_under(calls, {:user, uid}) do
      assert Enum.all?(gets(calls), &(&1 == {:get, 1, [uid]})), "lookups: #{inspect(gets(calls))}"
      refute Enum.any?(calls, &match?({:get, 2, _}, &1)), "no device lookup: #{inspect(calls)}"
    end
    defp device_ids(uid), do: T.sql!("SELECT device_id FROM sync_tokens WHERE user_id = $1 ORDER BY device_id", [uid]).rows |> List.flatten()
    defp row(uid, dev), do: T.sql!("SELECT since_token, last_event_id FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows

    # old -> new (story sync-stream-position, D12): "the real anchor, never an empty one" became "the token row has stream_version 1 and the device has its cursor rows"
    test "D4: the initial sync of a device persists ONE token row (stream_version 1) with its cursor rows under (user, device), nothing under ''", %{me: me, room: room} do
      resp = initial(me.uid, me.dev)
      calls = Spy.calls()

      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 1]] = token_state(me.uid, me.dev)
      assert token == resp.since_token
      assert [^room | _] = cursor_rows(me.uid, me.dev) |> Enum.map(&hd/1) |> Enum.filter(&(&1 == room)), "the device has a cursor row for its room"
      assert row(me.uid, "") == [], "no '' row for a device-bound request"
    end

    test "D2: an initial sync WITHOUT a device id (\"\") keeps the per-user key: one token write, the '' row (stream_version 1) with its cursor rows, no device row", %{me: me} do
      resp = initial(me.uid, "")
      calls = Spy.calls()

      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 1]] = token_state(me.uid, "")
      assert token == resp.since_token
      assert cursor_rows(me.uid, "") != []
      assert device_ids(me.uid) == [""]
    end

    test "D4: a fallback of a device persists ONE token row under (user, device): no second write, nothing under ''", %{me: me} do
      _ = initial(me.uid, me.dev)
      Spy.reset()

      resp = delta(me.uid, me.dev, "not-the-stored-token")
      calls = Spy.calls()

      assert resp.fallback_to_initial == true
      assert_lookups_only_under(calls, {:device, me.uid, me.dev})
      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 1]] = token_state(me.uid, me.dev)
      assert token == resp.since_token
      assert row(me.uid, "") == []
      assert device_ids(me.uid) == [me.dev]
    end

    test "D4: a device without any row (not_found) falls back with the same single token write", %{me: me} do
      resp = delta(me.uid, me.dev, "never-issued")
      calls = Spy.calls()

      assert resp.fallback_to_initial
      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 1]] = token_state(me.uid, me.dev)
      assert token == resp.since_token
    end

    # old -> new (story sync-stream-position, D6, premise "f moot"): "a matching token whose ANCHOR EVENT no longer exists falls back" is gone with the anchor: the token
    # carries no event id, so a missing `last_event_id` event changes nothing. The row of the OLD era (stream_version 0, written by persist_since_token/4) is the
    # remaining case of "a token the core cannot continue from": ONE fallback with the same single write.
    test "D4: a matching token of the timestamp era (stream_version 0, an anchor event that does not exist) falls back with the same single token write under the device key", %{me: me} do
      :ok = Nebu.Matrix.Session.PgStore.Postgres.persist_since_token(me.uid, me.dev, "tok-gone-anchor", "$does-not-exist")
      Spy.reset()

      resp = delta(me.uid, me.dev, "tok-gone-anchor")
      calls = Spy.calls()

      assert resp.fallback_to_initial
      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 1]] = token_state(me.uid, me.dev)
      assert token == resp.since_token
    end

    test "D4 behaviour: after a fallback the device's NEXT delta replays nothing (the cursors were written at the heads)", %{me: me, o: o, room: room} do
      fallback = delta(me.uid, me.dev, "stale")
      assert fallback.fallback_to_initial
      assert [[_, 1, 1]] = token_state(me.uid, me.dev), "the fallback wrote a stream_version 1 row"

      again = delta(me.uid, me.dev, fallback.since_token)
      refute again.fallback_to_initial
      assert Enum.flat_map(again.rooms, & &1.timeline_events) == [], "no replay of the room's earlier events"

      S.tick()
      marker = S.marker("after")
      S.say!(o, room, marker)
      third = delta(me.uid, me.dev, again.since_token)
      assert [%{content: content}] = Enum.flat_map(third.rooms, & &1.timeline_events)
      assert content =~ marker
    end

    test "D1: a matching device token is looked up and persisted under (user, device) once; the '' row is neither read nor written", %{me: me, o: o, room: room} do
      first = initial(me.uid, me.dev)
      S.tick()
      S.say!(o, room, S.marker("new"))
      Spy.reset()

      resp = delta(me.uid, me.dev, first.since_token)
      calls = Spy.calls()

      refute resp.fallback_to_initial
      assert_lookups_only_under(calls, {:device, me.uid, me.dev})
      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 2]] = token_state(me.uid, me.dev), "the delta is the second generation of the row"
      assert token == resp.since_token
      assert row(me.uid, "") == []
    end

    test "D3: a token stored under '' is NOT read by a device-bound request: one fallback, no '' lookup, the '' row is left alone", %{me: me} do
      legacy = initial(me.uid, "")
      legacy_row = row(me.uid, "")
      Spy.reset()

      resp = delta(me.uid, me.dev, legacy.since_token)
      calls = Spy.calls()

      assert resp.fallback_to_initial, "the pre-change token does not match the device's (absent) row: one initial-shaped answer"
      assert_lookups_only_under(calls, {:device, me.uid, me.dev})
      assert row(me.uid, "") == legacy_row
      assert [_] = row(me.uid, me.dev)

      refute delta(me.uid, me.dev, resp.since_token).fallback_to_initial, "from then on incremental from its own row"
    end

    test "D2: a device-less delta uses only the per-user key (get_since_token/1); its fallback writes ONE '' row (stream_version 1)", %{me: me, o: o, room: room} do
      first = initial(me.uid, "")
      S.tick()
      S.say!(o, room, S.marker("new"))
      Spy.reset()

      resp = delta(me.uid, "", first.since_token)
      calls = Spy.calls()
      refute resp.fallback_to_initial
      assert_lookups_only_under(calls, {:user, me.uid})
      assert_one_persist_for(calls, me.uid)
      assert [[token, 1, 2]] = token_state(me.uid, "")
      assert token == resp.since_token

      Spy.reset()
      fb = delta(me.uid, "", "stale")
      assert fb.fallback_to_initial
      calls = Spy.calls()
      assert_one_persist_for(calls, me.uid)
      assert [[ftoken, 1, 1]] = token_state(me.uid, "")
      assert ftoken == fb.since_token
      assert device_ids(me.uid) == [""]
    end

    test "two devices of one user hold independent rows through the core: each device's token is valid only for its own row", %{me: me} do
      other = "FDE" <> String.upcase(T.rand(3))
      a = initial(me.uid, me.dev)
      b = initial(me.uid, other)

      assert device_ids(me.uid) == Enum.sort([me.dev, other])
      refute delta(me.uid, me.dev, a.since_token).fallback_to_initial
      refute delta(me.uid, other, b.since_token).fallback_to_initial
      assert delta(me.uid, me.dev, b.since_token).fallback_to_initial, "B's token is not valid for A's row"
    end
  end

  # ═══ the route passes the AUTHENTICATED device (HTTP + spy) ══════════════════════════════════════════════════════════════════

  describe "D1 at the route: the key is the authenticated device, never request input" do
    @describetag :integration

    setup do
      T.reset_rate_limits()
      Nebu.Test.ServerName.pin!(T.server_name())

      Spy.reset()
      previous = Application.fetch_env(:event_dispatcher, :pg_store_module)
      Application.put_env(:event_dispatcher, :pg_store_module, Spy)

      on_exit(fn ->
        T.restore_rate_limits()

        case previous do
          {:ok, v} -> Application.put_env(:event_dispatcher, :pg_store_module, v)
          :error -> Application.delete_env(:event_dispatcher, :pg_store_module)
        end
      end)

      :ok
    end

    test "a device-bound session uses the device key for initial and delta; a device_id request parameter changes nothing" do
      uid = T.provision_user!()
      dev = "FDR" <> String.upcase(T.rand(3))
      me = %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}

      first = S.sync(me, nil, device_id: "FOREIGN")
      assert_one_persist_for(Spy.calls(), uid)
      assert [[_, 1, 1]] = token_state(uid, dev), "the device's own row (key = the authenticated device)"
      assert token_state(uid, "FOREIGN") == []
      Spy.reset()

      _ = S.sync(me, first["next_batch"], device_id: "FOREIGN")
      calls = Spy.calls()
      assert gets(calls) != [], "control: the delta looked the token up"
      assert_lookups_only_under(calls, {:device, uid, dev})
      assert_one_persist_for(calls, uid)
      assert [[_, 1, 2]] = token_state(uid, dev)
      assert token_state(uid, "FOREIGN") == [], "a device_id request parameter changes nothing"
      refute Enum.any?(calls, &match?({_, _, [_, "FOREIGN" | _]}, &1))
    end

    test "an unbound raw IdP JWT uses the per-user key (3-arity functions); a BOUND JWT uses its device" do
      priv = T.setup_idp!()
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      jwt = %{uid: uid, at: T.unbound_jwt!(priv, sub)}
      bound_dev = "FDJ" <> String.upcase(T.rand(3))
      bound = %{uid: uid, at: T.bound_jwt!(priv, sub, bound_dev)}

      first = S.sync(jwt)
      assert_one_persist_for(Spy.calls(), uid)
      assert [[_, 1, 1]] = token_state(uid, ""), "an unbound JWT writes the per-user '' row"
      Spy.reset()
      _ = S.sync(jwt, first["next_batch"])
      calls = Spy.calls()
      assert gets(calls) != [], "control: the delta looked the token up"
      assert_lookups_only_under(calls, {:user, uid})
      assert_one_persist_for(calls, uid)
      assert [[_, 1, 2]] = token_state(uid, "")

      Spy.reset()
      _ = S.sync(bound)
      assert_one_persist_for(Spy.calls(), uid)
      assert [[_, 1, 1]] = token_state(uid, bound_dev), "a bound JWT writes its device's row"
    end
  end
end
