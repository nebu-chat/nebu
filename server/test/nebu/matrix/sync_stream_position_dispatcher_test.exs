defmodule Nebu.Matrix.SyncStreamPositionDispatcherTest do
  @moduledoc """
  Dispatcher-level acceptance tests for story `sync-stream-position` (epic oauth-broker, follow-up `fc`, story 2 of 2): `Nebu.Matrix.EventDispatcher.Server.get_initial_sync/2` and
  `get_sync_delta/2` called DIRECTLY (the gRPC-shaped requests the router builds), on the real stack: real `Nebu.Repo`, real Room.Server / Horde, users and rooms through the HTTP helpers
  (membership is a fact of the database), the since token and the cursors in the real tables. `async: false`.

  Covered: D11 (the proto field `newly_joined_room_ids = 7` and its content), D6 / D8 (the base selection: current, previous, two generations old, foreign, forged: asked of the core
  itself, below the HTTP layer), D3 (cursor rows are written only when their value changes, deleted when the room leaves the partition), D4 / D14 (no timestamp anchor read, one head
  statement, one room read, quiet rooms cost nothing: counted with a spy over `Room.DB`), D13 (an unresolved joined room keeps ITS cursor, the other rooms advance and are not repeated).

  ## Decisions of the ATDD step (ambiguities of the story)

    * "the dispatcher unit tests with the fake modules" of the story's test list: the dispatcher is driven with the REAL modules here (a fake that implements `room_heads/3`, cursors
      and a guarded persist would be a second implementation of the story); the fake-based suites that already exist are amended instead (see the ATDD report).
    * The spy (`SpyDB`) is installed as BOTH `:event_dispatcher, :messages_db_module` and `:rooms_db_module` and delegates every function of `Room.DB`; it records `{name, arity}`. Which of
      the two seams the dev reads the new position reads through is therefore not pinned.
    * `newly_joined_room_ids` is read with `Map.get/3` (the field does not exist in the red state: a struct key would be a compile error under `--warnings-as-errors`).
    * "a row is written only when its value changes" is observed with the row's `xmin` (a rewritten row gets a new one): an incremental sync with news in ONE room rewrites that room's
      cursor row and no other (D3). The D8 re-base of rows changed in the generation that a RETRY replaces is a different, rarer, case (see the ATDD report, story gap 2).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  # every describe but the static proto one needs the database (@describetag :integration); the static one runs in the unit job
  @proto Path.expand("../../../../proto/core.proto", __DIR__)
  @stream %{http_request_headers: %{}}

  # ─── the spy over Room.DB ────────────────────────────────────────────────────

  defmodule SpyDB do
    @moduledoc false
    @table :ssp_spy_calls

    for {name, arity} <- Nebu.Matrix.Room.DB.__info__(:functions) do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)) do
        if :ets.whereis(@table) != :undefined, do: :ets.update_counter(@table, {unquote(name), unquote(arity)}, 1, {{unquote(name), unquote(arity)}, 0})
        apply(Nebu.Matrix.Room.DB, unquote(name), unquote(args))
      end
    end

    def reset, do: :ets.delete_all_objects(@table)
    def calls(name), do: :ets.match_object(@table, {{name, :_}, :_}) |> Enum.map(fn {{_n, _a}, c} -> c end) |> Enum.sum()
    def table, do: @table
  end

  # a db module that commits ONE event into a room right AFTER a `room_heads/3` call answered (once, when armed): "an event committed after the head was read" (D4, D12),
  # deterministically; everything else is the real `Room.DB`
  defmodule RaceDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :room_heads do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def room_heads(room_ids, user_id, device_id) do
      result = apply(DB, :room_heads, [room_ids, user_id, device_id])

      with %{room: room, sender: sender, body: body} <- Application.get_env(:nebu, :ssp_race) do
        Application.delete_env(:nebu, :ssp_race)

        :ok =
          DB.insert_event(%{
            "event_id" => "$race" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
            "room_id" => room,
            "sender" => sender,
            "type" => "m.room.message",
            "state_key" => nil,
            "content" => %{"msgtype" => "m.text", "body" => body},
            "origin_server_ts" => System.system_time(:millisecond)
          })
      end

      result
    end
  end

  # an exiting registry: `get_state/1` of ONE room exits `:noproc` (what a Horde registry that has not converged answers), everything else is the real room process
  defmodule UnresolvableRegistry do
    @moduledoc false
    def get_state(room_id) do
      if room_id in Application.get_env(:nebu, :ssp_unresolvable, []),
        do: exit({:noproc, {GenServer, :call, [{:via, Horde.Registry, {Nebu.Matrix.Room.Registry, room_id}}, :get_state, 5_000]}}),
        else: Nebu.Matrix.Room.Server.get_state(room_id)
    end
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  defp install_env!(key, value) do
    prior = Application.fetch_env(:event_dispatcher, key)
    Application.put_env(:event_dispatcher, key, value)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:event_dispatcher, key, v)
        :error -> Application.delete_env(:event_dispatcher, key)
      end
    end)
  end

  defp install_spy! do
    if :ets.whereis(SpyDB.table()) == :undefined, do: :ets.new(SpyDB.table(), [:named_table, :public, :set])
    SpyDB.reset()
    install_env!(:messages_db_module, SpyDB)
    install_env!(:rooms_db_module, SpyDB)
  end

  # ─── fixtures and requests ───────────────────────────────────────────────────

  defp initial(uid, dev), do: Server.get_initial_sync(%Core.GetInitialSyncRequest{user_id: uid, device_id: dev}, @stream)

  defp delta(uid, dev, token, full_state \\ false),
    do: Server.get_sync_delta(%Core.GetSyncDeltaRequest{user_id: uid, device_id: dev, since_token: token, timeout_ms: 0, full_state: full_state}, @stream)

  # a user that is joined to `n` rooms of an owner
  defp world!(n \\ 2) do
    a = S.user!("SDA")
    o = S.user!("SDO")
    rooms = for _ <- 1..n, do: S.invite_room(o, [a])
    %{a: a, o: o, rooms: rooms, dev: "DISP" <> T.rand(3)}
  end

  defp room_of(resp, room), do: Enum.find(resp.rooms, &(&1.room_id == room))
  defp bodies(resp, room), do: if(r = room_of(resp, room), do: for(ev <- r.timeline_events, ev.event_type == "m.room.message", do: Jason.decode!(ev.content)["body"]), else: [])
  defp newly(resp), do: Map.get(resp, :newly_joined_room_ids)

  defp cursor(uid, dev, room) do
    case T.sql!("SELECT pos, class, gen, prev_pos FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 AND room_id = $3", [uid, dev, room]).rows do
      [[pos, class, gen, prev_pos]] -> %{pos: pos, class: class, gen: gen, prev_pos: prev_pos}
      [] -> nil
    end
  end

  defp xmins(uid, dev), do: T.sql!("SELECT room_id, xmin::text FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows |> Map.new(fn [r, x] -> {r, x} end)
  defp head(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp say!(o, room, label), do: (m = S.marker(label); S.say!(o, room, m); m)

  # ═══ D11: the proto field ═══════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D11 - newly_joined_room_ids = 7 (static)" do
    test "proto/core.proto declares `repeated string newly_joined_room_ids = 7` inside GetSyncDeltaResponse and keeps the fields 1 - 6" do
      proto = File.read!(@proto)
      [_, body] = Regex.run(~r/message GetSyncDeltaResponse \{(.*?)\n\}/s, proto)
      assert body =~ ~r/repeated\s+string\s+newly_joined_room_ids\s*=\s*7\s*;/
      assert body =~ ~r/string\s+since_token\s*=\s*1\s*;/
      assert body =~ ~r/repeated\s+SyncRoom\s+rooms\s*=\s*2\s*;/
      assert body =~ ~r/bool\s+fallback_to_initial\s*=\s*3\s*;/
      assert body =~ ~r/repeated\s+string\s+join_room_ids\s*=\s*4\s*;/
      assert body =~ ~r/repeated\s+SyncInviteRoom\s+invite_rooms\s*=\s*5\s*;/
      assert body =~ ~r/repeated\s+SyncRoom\s+leave_rooms\s*=\s*6\s*;/
      refute proto =~ ~r/newly_joined_room_ids\s*=\s*(?!7)\d+/
    end

    test "the generated Core.GetSyncDeltaResponse has the field newly_joined_room_ids with the default []" do
      assert {:ok, []} == Map.fetch(Map.from_struct(struct(Core.GetSyncDeltaResponse)), :newly_joined_room_ids)
    end
  end

  # ═══ D11: its content ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D11 - newly joined rooms" do
    @describetag :integration
    test "a room joined after the device's last sync is listed (newest 20, limited), unchanged joined rooms are not, the next delta lists none" do
      w = world!()
      t0 = initial(w.a.uid, w.dev).since_token
      room = S.make_room(w.o, %{"preset" => "private_chat"})
      S.invite!(w.o, room, w.a)
      S.join!(w.a, room)
      ms = for i <- 1..25, do: say!(w.o, room, "n#{i}")
      say!(w.o, hd(w.rooms), "other")

      resp = delta(w.a.uid, w.dev, t0)
      assert resp.fallback_to_initial == false
      assert newly(resp) == [room], "only the room that was not a joined room of the device before"
      assert bodies(resp, room) == Enum.drop(ms, 5), "its newest 20 (the join event may be outside the timeline: that is why the core reports it)"
      assert room_of(resp, room).limited == true
      assert room in resp.join_room_ids and hd(w.rooms) in resp.join_room_ids

      assert newly(delta(w.a.uid, w.dev, resp.since_token)) == []
    end

    test "an invited room that the user then joins, and a room the user left and joined again, are newly joined (their cursor class was not join)" do
      w = world!()
      inviter = S.user!("SDI")
      invited = S.make_room(inviter, %{"preset" => "private_chat"})
      S.invite!(inviter, invited, w.a)
      [left | _] = w.rooms
      t0 = initial(w.a.uid, w.dev).since_token
      assert cursor(w.a.uid, w.dev, invited).class == "invite"

      S.join!(w.a, invited)
      S.leave!(w.a, left)
      d1 = delta(w.a.uid, w.dev, t0)
      assert invited in newly(d1), "invite -> join"
      assert cursor(w.a.uid, w.dev, left).class == "leave"
      S.invite!(w.o, left, w.a)
      S.join!(w.a, left)

      resp = delta(w.a.uid, w.dev, d1.since_token)
      assert Enum.sort(newly(resp)) == Enum.sort([left]), "re-joined: class leave -> join (the room that was already joined for this device is not listed)"
      assert cursor(w.a.uid, w.dev, left).class == "join"
    end
  end

  # ═══ the base selection of the core (D6, D8) ════════════════════════════════════════════════════════════════════════════════

  describe "base selection in the core (D6, D8)" do
    @describetag :integration
    test "the current token and the previous generation are incremental (the retry's own token replaces the lost one, which is dead afterwards)" do
      w = world!()
      t1 = initial(w.a.uid, w.dev).since_token
      assert t1 =~ ~r/\As2_[A-Za-z0-9_-]{22}\z/, "the core token of the core: s2_ + 22 url-safe characters (the HTTP layer appends .<pos>)"
      m1 = say!(w.o, hd(w.rooms), "m1")
      r2 = delta(w.a.uid, w.dev, t1)
      assert m1 in bodies(r2, hd(w.rooms)) and r2.fallback_to_initial == false
      r3 = delta(w.a.uid, w.dev, r2.since_token)
      assert r3.fallback_to_initial == false

      # r3's response is lost: the retry carries r2's token, the previous generation
      retry = delta(w.a.uid, w.dev, r2.since_token)
      assert retry.fallback_to_initial == false, "the previous generation stays valid"
      assert delta(w.a.uid, w.dev, retry.since_token).fallback_to_initial == false, "and the retry's own token is the new current one"
      assert delta(w.a.uid, w.dev, r3.since_token).fallback_to_initial, "the lost response's token is dead once the retry committed"
    end

    test "a token two generations old, another user's, a forged s2_ token, an empty and a garbage one are fallbacks of the caller's own partition" do
      w = world!()
      other = world!()
      t1 = initial(w.a.uid, w.dev).since_token
      t2 = delta(w.a.uid, w.dev, t1).since_token
      _t3 = delta(w.a.uid, w.dev, t2).since_token
      assert delta(w.a.uid, w.dev, t1).fallback_to_initial, "two generations old: a fallback"

      other_t = initial(other.a.uid, other.dev).since_token
      forged = "s2_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      for {label, token} <- [foreign_user: other_t, forged: forged, empty: "", garbage: "AAAA"] do
        resp = delta(w.a.uid, w.dev, token)
        assert resp.fallback_to_initial, "#{label}: a fallback"
        assert Enum.sort(resp.join_room_ids) == Enum.sort(w.rooms), "#{label}: the caller's own partition"
        refute Enum.any?(resp.join_room_ids, &(&1 in other.rooms))
      end
    end

    test "a second retry with the same previous token is incremental again and its changed rows were re-based to the first token's values (D8)" do
      w = world!(3)
      [r1, r2, r3] = w.rooms
      t1 = initial(w.a.uid, w.dev).since_token
      t1_pos = cursor(w.a.uid, w.dev, r2).pos
      # r2: events only BEFORE the lost response (its row changed in the replaced generation and stays unchanged in the retry: the case that needs the re-base)
      m0 = say!(w.o, r2, "lost-1")
      lost = delta(w.a.uid, w.dev, t1)
      S.leave!(w.a, r1)
      m1 = say!(w.o, r3, "lost-2")

      first = delta(w.a.uid, w.dev, t1)
      assert first.fallback_to_initial == false and bodies(first, r2) == [m0] and bodies(first, r3) == [m1]
      assert cursor(w.a.uid, w.dev, r2).prev_pos == t1_pos

      m2 = say!(w.o, r2, "new")
      second = delta(w.a.uid, w.dev, t1)
      assert second.fallback_to_initial == false
      assert Enum.sort(bodies(second, r2)) == Enum.sort([m0, m2]) and bodies(second, r3) == [m1], "the events of the lost responses come again, with the new one"
      assert r1 in Enum.map(second.leave_rooms, & &1.room_id), "and the leave"

      assert delta(w.a.uid, w.dev, lost.since_token).fallback_to_initial, "T2 is dead"
      assert delta(w.a.uid, w.dev, first.since_token).fallback_to_initial, "T3 is dead (replaced by the second retry's token)"
    end

    test "a token row with stream_version 0, or a client token without the s2_ prefix, is a fallback whatever it equals" do
      w = world!()
      t1 = initial(w.a.uid, w.dev).since_token
      T.sql!("UPDATE sync_tokens SET stream_version = 0 WHERE user_id = $1 AND device_id = $2", [w.a.uid, w.dev])
      assert delta(w.a.uid, w.dev, t1).fallback_to_initial, "stream_version 0"

      # the fallback wrote a fresh stream_version 1 row; now a legacy-looking token that the client echoes exactly
      T.sql!("UPDATE sync_tokens SET since_token = 'legacy-ts-token', prev_since_token = NULL WHERE user_id = $1 AND device_id = $2", [w.a.uid, w.dev])
      assert delta(w.a.uid, w.dev, "legacy-ts-token").fallback_to_initial, "no s2_ prefix"
    end

    test "the device-less key '' uses the same cursor table with device_id = '' and the same token rules" do
      w = world!()
      t1 = initial(w.a.uid, "").since_token
      assert t1 =~ ~r/\As2_/
      assert cursor(w.a.uid, "", hd(w.rooms)).class == "join"
      m = say!(w.o, hd(w.rooms), "m")
      r = delta(w.a.uid, "", t1)
      assert r.fallback_to_initial == false and m in bodies(r, hd(w.rooms))
      assert delta(w.a.uid, "", "garbage").fallback_to_initial
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1 AND device_id <> ''", [w.a.uid]).rows == [[0]]
    end
  end

  # ═══ D3: which rows are written ═════════════════════════════════════════════════════════════════════════════════════════════

  describe "D3 - the cursor rows of a device" do
    @describetag :integration
    test "an incremental sync rewrites ONLY the rows whose value changed: news in one room rewrites that room's row, nothing new rewrites none" do
      w = world!(3)
      [r1, r2, r3] = w.rooms
      t0 = initial(w.a.uid, w.dev).since_token
      # one delta to move on from the initial rows (D8: rows of the generation being replaced may be re-based once)
      t1 = delta(w.a.uid, w.dev, t0).since_token
      before = xmins(w.a.uid, w.dev)
      assert map_size(before) >= 3

      m = say!(w.o, r1, "news")
      resp = delta(w.a.uid, w.dev, t1)
      assert m in bodies(resp, r1)
      after_news = xmins(w.a.uid, w.dev)
      assert after_news[r1] != before[r1], "the room with news got a new cursor row version"
      assert after_news[r2] == before[r2] and after_news[r3] == before[r3], "the quiet rooms' rows are not rewritten"
      assert cursor(w.a.uid, w.dev, r1).pos == head(r1)

      quiet = delta(w.a.uid, w.dev, resp.since_token)
      assert quiet.rooms == []
      assert xmins(w.a.uid, w.dev) == after_news, "nothing new: no cursor row is written at all"
    end

    test "a room that leaves the partition (forgotten after a leave) loses its cursor row; a left room that is still in the partition keeps it with class leave" do
      w = world!(2)
      [r1, r2] = w.rooms
      t0 = initial(w.a.uid, w.dev).since_token
      S.leave!(w.a, r1)
      S.leave!(w.a, r2)
      t1 = delta(w.a.uid, w.dev, t0).since_token
      assert cursor(w.a.uid, w.dev, r1).class == "leave" and cursor(w.a.uid, w.dev, r2).class == "leave"

      assert T.matrix_request(:post, S.path(r1, "forget"), w.a.at).status == 200
      delta(w.a.uid, w.dev, t1)
      assert cursor(w.a.uid, w.dev, r1) == nil, "forgotten: not a partition room any more, no cursor"
      assert cursor(w.a.uid, w.dev, r2).class == "leave"
    end

    test "the cursor of one device is never touched by another device's syncs, and the cursor never passes the room's head" do
      w = world!(1)
      [room] = w.rooms
      ta = initial(w.a.uid, "DEVA").since_token
      tb = initial(w.a.uid, "DEVB").since_token
      for i <- 1..3, do: say!(w.o, room, "m#{i}")
      resp = delta(w.a.uid, "DEVA", ta)
      assert cursor(w.a.uid, "DEVA", room).pos == head(room)
      assert cursor(w.a.uid, "DEVB", room).pos < head(room), "B did not sync"
      assert length(bodies(delta(w.a.uid, "DEVB", tb), room)) == 3
      assert bodies(resp, room) |> length() == 3
      assert cursor(w.a.uid, "DEVB", room).pos <= head(room)
    end
  end

  # ═══ D4 / D14: reads ═══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D4 / D14 - reads" do
    @describetag :integration
    test "a user joined to 50 rooms of which ONE received an event: exactly one room timeline read, one head read, get_event_timestamp / the timestamp readers are never called" do
      w = world!(50)
      t0 = initial(w.a.uid, w.dev).since_token
      m = say!(w.o, Enum.at(w.rooms, 37), "only")
      install_spy!()

      resp = delta(w.a.uid, w.dev, t0)
      assert m in bodies(resp, Enum.at(w.rooms, 37))
      assert SpyDB.calls(:fetch_visible_events_in_range) == 1, "one room moved: one timeline read, the 49 quiet rooms cost no statement"
      assert SpyDB.calls(:room_heads) == 1, "ONE statement for the heads and cursors of all rooms"
      for fun <- [:get_event_timestamp, :fetch_visible_events_since, :fetch_events_since], do: assert(SpyDB.calls(fun) == 0, "#{fun} is no longer called by /sync")
    end

    test "nothing new anywhere: no room timeline read at all, and still no timestamp read (also with a user without rooms)" do
      w = world!(5)
      t0 = initial(w.a.uid, w.dev).since_token
      install_spy!()
      resp = delta(w.a.uid, w.dev, t0)
      assert resp.rooms == []
      assert SpyDB.calls(:fetch_visible_events_in_range) == 0
      assert SpyDB.calls(:get_event_timestamp) == 0

      lonely = S.user!("SDL")
      tl = initial(lonely.uid, "LONE").since_token
      SpyDB.reset()
      assert delta(lonely.uid, "LONE", tl).rooms == []
      assert SpyDB.calls(:get_event_timestamp) == 0
    end

    test "the initial sync: one head statement for all partition rooms (not one per room), and no timestamp read" do
      w = world!(6)
      install_spy!()
      resp = initial(w.a.uid, w.dev)
      assert length(resp.rooms) == 6
      assert SpyDB.calls(:room_heads) == 1
      assert SpyDB.calls(:get_event_timestamp) == 0
    end

    test "a room with 30 new events costs ONE timeline read (not one per page) and one more event costs one again" do
      w = world!(1)
      [room] = w.rooms
      t0 = initial(w.a.uid, w.dev).since_token
      for i <- 1..30, do: say!(w.o, room, "b#{i}")
      install_spy!()
      resp = delta(w.a.uid, w.dev, t0)
      assert length(bodies(resp, room)) == 20 and room_of(resp, room).limited
      assert SpyDB.calls(:fetch_visible_events_in_range) == 1
    end
  end

  # ═══ D9: events stored before story events-room-position have no position ════════════════════════════════════════════════════

  describe "D9 - legacy member events (room_pos NULL)" do
    @describetag :integration

    defp unstamp_member_events!(room, uid, membership),
      do: T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 AND content->>'membership' = $3", [room, uid, membership])

    test "a leave stored without a position and no cursor row for the device is not delivered as a leave" do
      w = world!(1)
      [room] = w.rooms
      S.leave!(w.a, room)
      unstamp_member_events!(room, w.a.uid, "leave")
      t0 = initial(w.a.uid, w.dev).since_token
      T.sql!("DELETE FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 AND room_id = $3", [w.a.uid, w.dev, room])

      resp = delta(w.a.uid, w.dev, t0)
      assert resp.fallback_to_initial == false
      assert Enum.map(resp.leave_rooms, & &1.room_id) == [], "a legacy leave predates every cursor: never new (D9)"
    end

    test "an invite event stored without a position is not repeated while the device holds its invitation cursor" do
      w = world!(1)
      inviter = S.user!("SDI")
      room = S.make_room(inviter, %{"preset" => "private_chat"})
      S.invite!(inviter, room, w.a)
      unstamp_member_events!(room, w.a.uid, "invite")
      t0 = initial(w.a.uid, w.dev).since_token
      assert cursor(w.a.uid, w.dev, room).class == "invite"

      resp = delta(w.a.uid, w.dev, t0)
      assert Enum.map(resp.invite_rooms, & &1.room_id) == [], "the position-less invite event is not above the cursor: not repeated"
      assert delta(w.a.uid, w.dev, resp.since_token).invite_rooms == []
    end
  end

  # ═══ D4 / D12: the exact range ════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D4 / D12 - the exact range" do
    @describetag :integration
    test "delta: an event committed after the head read is NOT delivered now (the range ends at the head read) and is delivered exactly once by the next sync" do
      w = world!(1)
      [room] = w.rooms
      t0 = initial(w.a.uid, w.dev).since_token
      before_head = say!(w.o, room, "before-head")
      install_env!(:messages_db_module, RaceDB)
      install_env!(:rooms_db_module, RaceDB)
      Application.put_env(:nebu, :ssp_race, %{room: room, sender: w.o.uid, body: "after-head"})
      on_exit(fn -> Application.delete_env(:nebu, :ssp_race) end)

      resp = delta(w.a.uid, w.dev, t0)
      assert Application.get_env(:nebu, :ssp_race) == nil, "fixture: the event was committed right after the head read"
      assert bodies(resp, room) == [before_head], "the event committed after the head read is not part of this response"
      assert cursor(w.a.uid, w.dev, room).pos == head(room) - 1, "the cursor is the head that was READ, not the room's head now"

      second = delta(w.a.uid, w.dev, resp.since_token)
      assert bodies(second, room) == ["after-head"], "delivered exactly once by the next sync"
      assert bodies(delta(w.a.uid, w.dev, second.since_token), room) == []
    end

    test "initial sync: an event committed after the head read is not in the snapshot and is delivered exactly once by the next delta" do
      w = world!(1)
      [room] = w.rooms
      m1 = say!(w.o, room, "in-snapshot")
      install_env!(:messages_db_module, RaceDB)
      install_env!(:rooms_db_module, RaceDB)
      Application.put_env(:nebu, :ssp_race, %{room: room, sender: w.o.uid, body: "after-head"})
      on_exit(fn -> Application.delete_env(:nebu, :ssp_race) end)

      snap = initial(w.a.uid, w.dev)
      assert Application.get_env(:nebu, :ssp_race) == nil, "fixture: the event was committed right after the head read"
      assert m1 in bodies(snap, room)
      refute "after-head" in bodies(snap, room), "the page is bounded by the head that was read"
      assert cursor(w.a.uid, w.dev, room).pos == head(room) - 1

      delta1 = delta(w.a.uid, w.dev, snap.since_token)
      assert bodies(delta1, room) == ["after-head"]
      assert bodies(delta(w.a.uid, w.dev, delta1.since_token), room) == []
    end
  end

  # ═══ D13: an unresolved joined room keeps ITS cursor ══════════════════════════════════════════════════════════════════════

  describe "D13 - unresolved room" do
    @describetag :integration
    test "X is unresolvable: X is not delivered and keeps its cursor, Y advances; the next sync delivers X and does NOT repeat Y" do
      w = world!(2)
      [x, y] = w.rooms
      t0 = initial(w.a.uid, w.dev).since_token
      x_cursor = cursor(w.a.uid, w.dev, x)
      mx = say!(w.o, x, "x-news")
      my = say!(w.o, y, "y-news")

      Application.put_env(:nebu, :ssp_unresolvable, [x])
      on_exit(fn -> Application.delete_env(:nebu, :ssp_unresolvable) end)
      install_env!(:room_registry_module, UnresolvableRegistry)

      started = System.monotonic_time(:millisecond)
      first = delta(w.a.uid, w.dev, t0)
      assert System.monotonic_time(:millisecond) - started < 6_000, "bounded: one resolve deadline per build"
      assert first.fallback_to_initial == false
      assert my in bodies(first, y)
      assert room_of(first, x) == nil, "the unresolvable room is not delivered"
      assert cursor(w.a.uid, w.dev, x) == x_cursor, "its cursor is not advanced (and not re-based)"
      assert cursor(w.a.uid, w.dev, y).pos == head(y), "every other room advances"

      Application.delete_env(:nebu, :ssp_unresolvable)
      second = delta(w.a.uid, w.dev, first.since_token)
      assert mx in bodies(second, x), "the next sync delivers the room's events"
      assert bodies(second, y) == [], "the bp symptom is gone: the other room's events are NOT delivered again"
      assert second.fallback_to_initial == false
      assert cursor(w.a.uid, w.dev, x).pos == head(x)
    end
  end
end
