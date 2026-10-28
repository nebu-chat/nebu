defmodule Nebu.Matrix.SyncStreamPositionHttpTest do
  @moduledoc """
  Acceptance tests for story `sync-stream-position` (epic oauth-broker, follow-up `fc`, story 2 of 2), HTTP half: `GET /_matrix/client/v3/sync` over the real stack (`Nebu.Web.Router` +
  `Plug.Test`, real `Nebu.Repo`, real Room.Server / Horde / :pg; users and sessions through `Nebu.OAuth.TestSupport` and `Nebu.Matrix.ModerationTestSupport` (`S`), random localparts,
  `:server_name` pinned). The scenarios of the story that need no held transaction or fake module are here; the real-concurrency ones (a late commit, two writers and a reader, the guarded
  persist) live in `sync_stream_position_concurrency_test.exs`, the dispatcher-level ones (the proto field, the base selection, a room that cannot be resolved, statement shapes) in
  `sync_stream_position_dispatcher_test.exs`, the cursor / token store in `sync_stream_position_store_test.exs`, the migration in `migration/000054_sync_room_cursors_test.exs`, the DB reads
  in `room/sync_positions_db_test.exs`, the docs in `sync_stream_position_docs_test.exs`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * "Incremental" is told from "initial-shaped" by the room's timeline: a snapshot repeats the room from `m.room.create` on, a delta carries only what is newer than the device's
      cursor (the detector has a POSITIVE control in the ONE-device baseline test, green before and after the story).
    * The cursor table is read with SQL strings (`sync_room_cursors`, `sync_tokens.stream_version` ...), so a missing migration 000054 is a runtime failure of the test, never a compile error.
    * Scenario (a) pins the delivered timeline literally (the NEWEST 20 messages, oldest first, `limited` true) and the gap through the REAL `/messages` read with the `prev_batch`
      (`dir=b`): its first chunk entries are the ten older messages newest first, none of the delivered twenty is in it, the union is the 30. The messages of this scenario are sent
      2 ms apart (the `/messages` order is `(origin_server_ts, event_id)`: residual `cq` (b) of the story is a DIFFERENT, a timestamp-inversion, case).
    * "Exactly 20 new events: not limited and no `prev_batch`; 21: limited with the newest 20" is the Oracle's boundary case; `rooms.join[].timeline.prev_batch` is `""` when not limited
      (the renderer's shape today), a leave window carries the key only when limited.
    * The token tests read the stored row: `since_token` (core), `stream_version`, `generation`, `prev_since_token`. A client token is `<core>.<room account data position>`; the core
      is `s2_` + 22 base64url characters (16 random bytes, no padding), never containing the user id, an event id, a position or a `.`.
    * "byte-identical other rows" = the whole `sync_tokens` and `sync_room_cursors` rows of every OTHER (user, device) before and after the request.
    * Scenario "a room that cannot be resolved keeps its cursor" (D13) and the leave-window clock-skew row (`left_at` earlier than the event) are driven with SQL on `room_members`.
    * The clock skew scenario of the story ("stamping through a writer with a shifted clock (the injectable now_ms)") has no injectable `now_ms` in `Room.Server` today (the stamp is
      `Nebu.DB.Helpers.now_ms()`): the writer of node 2 is `Room.DB.insert_event/1` with `origin_server_ts = now - 5_000` (what any room process on a node with a clock 5 s behind writes).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp device!(uid, prefix) do
    dev = prefix <> String.upcase(T.rand(3))
    %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
  end

  # a user with devices A and B, joined (through A) to two rooms owned by O, an own anchor room, and a first token per device
  defp shared! do
    uid = T.provision_user!()
    a = device!(uid, "SPA")
    b = device!(uid, "SPB")
    o = S.user!("SPO")
    room = S.invite_room(o, [a])
    room2 = S.invite_room(o, [a])
    anchor = S.anchor_room!(a)
    ta = S.snapshot!(a, anchor)
    tb = S.snapshot!(b, anchor)
    %{uid: uid, a: a, b: b, o: o, room: room, room2: room2, anchor: anchor, ta: ta, tb: tb}
  end

  # ─── database probes ─────────────────────────────────────────────────────────

  defp token_row(uid, dev) do
    case T.sql!("SELECT since_token, stream_version, generation, prev_since_token FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows do
      [[since, version, generation, prev]] -> %{since_token: since, stream_version: version, generation: generation, prev_since_token: prev}
      [] -> nil
    end
  end

  defp cursors(uid, dev) do
    T.sql!("SELECT room_id, gen, pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 ORDER BY room_id", [uid, dev]).rows
    |> Map.new(fn [room, gen, pos, class, marker, prev_pos, prev_class, prev_marker] ->
      {room, %{gen: gen, pos: pos, class: class, invite_marker: marker, prev_pos: prev_pos, prev_class: prev_class, prev_invite_marker: prev_marker}}
    end)
  end

  defp head(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # every sync_tokens and sync_room_cursors row of a user, whole (for the byte-identical checks): {%{device => row as JSON text}, %{"device|room" => row as JSON text}}
  defp state_rows(uid) do
    tokens = T.sql!("SELECT device_id, to_jsonb(t)::text FROM sync_tokens t WHERE user_id = $1", [uid]).rows |> Map.new(fn [d, j] -> {d, j} end)
    rows = T.sql!("SELECT device_id || '|' || room_id, to_jsonb(c)::text FROM sync_room_cursors c WHERE user_id = $1", [uid]).rows |> Map.new(fn [k, j] -> {k, j} end)
    {tokens, rows}
  end

  # the rows of ONE device out of `state_rows/1`
  defp device_state({tokens, rows}, dev), do: {Map.get(tokens, dev), rows |> Enum.filter(fn {k, _} -> String.starts_with?(k, dev <> "|") end) |> Map.new()}

  # ─── the sync client ─────────────────────────────────────────────────────────

  defp next(body), do: body["next_batch"]
  defp core(token), do: token |> String.split(".") |> hd()
  defp bodies(body, room), do: for(ev <- S.join_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"])
  defp leave_bodies(body, room), do: for(ev <- S.leave_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"])
  defp snapshot?(body, room), do: Enum.any?(S.join_timeline(body, room), &(&1["type"] == "m.room.create"))
  defp limited?(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "limited"]) == true
  defp prev_batch(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "prev_batch"])
  defp changed(body), do: get_in(body, ["device_lists", "changed"]) || []
  defp invites(body), do: body |> S.section("invite") |> Map.keys() |> Enum.sort()

  defp message!(o, room, label) do
    S.tick()
    m = S.marker(label)
    S.say!(o, room, m)
    m
  end

  # n messages, 2 ms apart (distinct origin_server_ts: the /messages order); the markers in send order
  defp send_many!(o, room, n, label) do
    for i <- 1..n do
      Process.sleep(2)
      m = S.marker("#{label}#{i}")
      S.say!(o, room, m)
      m
    end
  end

  defp messages_from(user, room, from, limit) do
    conn = T.matrix_request(:get, S.path(room, "messages") <> "?" <> URI.encode_query(%{"dir" => "b", "from" => from, "limit" => limit}), user.at)
    assert conn.status == 200, "messages: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["chunk"] || []
  end

  defp chunk_bodies(chunk), do: for(ev <- chunk, ev["type"] == "m.room.message", do: ev["content"]["body"])

  defp assert_incremental(body, room, new_marker, old_markers \\ []) do
    assert new_marker in bodies(body, room), "the new event is in the delta: #{inspect(bodies(body, room))}"
    refute snapshot?(body, room), "a delta does not repeat the room from its creation (this was an initial-shaped answer)"
    for old <- old_markers, do: refute(old in bodies(body, room), "an earlier message is not repeated: #{old}")
    body
  end

  defp assert_fallback(body, room) do
    assert snapshot?(body, room), "an initial-shaped answer repeats the room from its creation"
    body
  end

  # ═══ (a) newest-N truncation, limited and a real /messages prev_batch ═══════════════════════════════════════════════════════

  describe "(a) newest 20 and prev_batch" do
    test "30 messages in A then 1 in B: A has its NEWEST 20, limited, a v1_ prev_batch that pages back over the older 10; B its message; no repeat" do
      f = shared!()
      ms = send_many!(f.o, f.room, 30, "a")
      mb = message!(f.o, f.room2, "b")

      body = S.sync(f.a, f.ta)
      assert bodies(body, f.room) == Enum.drop(ms, 10), "the NEWEST 20, oldest first (the tail is not lost)"
      assert limited?(body, f.room)
      refute snapshot?(body, f.room)
      assert [mb] == bodies(body, f.room2)
      refute limited?(body, f.room2)
      assert prev_batch(body, f.room2) in [nil, ""], "a room that is not limited has no prev_batch"

      prev = prev_batch(body, f.room)
      assert prev =~ ~r/\Av1_/, "prev_batch is a real /messages token, not an event id (the pre-existing defect of fc)"
      refute prev in (for ev <- S.join_timeline(body, f.room), do: ev["event_id"]), "never the id of an event"

      older = f.a |> messages_from(f.room, prev, 100) |> chunk_bodies()
      assert Enum.take(older, 10) == ms |> Enum.take(10) |> Enum.reverse(), "the gap: the ten older messages, newest first, without a hole"
      assert Enum.all?(Enum.drop(ms, 10), &(&1 not in older)), "no delivered message comes back through prev_batch (no duplicate)"

      s2 = S.sync(f.a, next(body))
      assert bodies(s2, f.room) == [] and bodies(s2, f.room2) == [], "the following sync repeats none of them"
      m31 = message!(f.o, f.room, "a31")
      s3 = S.sync(f.a, next(s2)) |> assert_incremental(f.room, m31, ms)
      assert bodies(s3, f.room) == [m31]
    end

    test "exactly 20 new events: not limited, no prev_batch; 21 new events: limited with the newest 20 and a prev_batch whose gap is the oldest one" do
      f = shared!()
      ms20 = send_many!(f.o, f.room, 20, "e")
      b20 = S.sync(f.a, f.ta)
      assert bodies(b20, f.room) == ms20
      refute limited?(b20, f.room), "20 events is the filter limit, not above it"
      assert prev_batch(b20, f.room) in [nil, ""]

      ms21 = send_many!(f.o, f.room, 21, "f")
      b21 = S.sync(f.a, next(b20))
      assert bodies(b21, f.room) == Enum.drop(ms21, 1)
      assert limited?(b21, f.room)
      assert prev_batch(b21, f.room) =~ ~r/\Av1_/
      assert f.a |> messages_from(f.room, prev_batch(b21, f.room), 100) |> chunk_bodies() |> hd() == hd(ms21)
    end

    test "the cursor reaches the head after a truncated delivery: rooms.event_pos == the device's pos, the tail is never delivered twice, a late message is delivered" do
      f = shared!()
      ms = send_many!(f.o, f.room, 25, "t")
      body = S.sync(f.a, f.ta)
      assert limited?(body, f.room)
      assert cursors(f.uid, f.a.dev)[f.room].pos == head(f.room), "the cursor moved to the head of the room, not to the last delivered event"

      quiet1 = S.sync(f.a, next(body))
      quiet2 = S.sync(f.a, next(quiet1))

      for again <- [quiet1, quiet2] do
        assert bodies(again, f.room) == []
        refute S.in_section?(again, "join", f.room), "a quiet room is not in rooms.join at all"
      end

      late = message!(f.o, f.room, "late")
      assert_incremental(S.sync(f.a, next(quiet2)), f.room, late, ms)
    end

    test "device B's own cursor: A's syncs never move B's, B still gets its own newest 20 and the same prev_batch gap" do
      f = shared!()
      ms = send_many!(f.o, f.room, 30, "d")
      ba = S.sync(f.a, f.ta)
      assert cursors(f.uid, f.b.dev)[f.room].pos < head(f.room), "B has not synced: its cursor stays where its last sync left it"
      bb = S.sync(f.b, f.tb)
      assert bodies(bb, f.room) == bodies(ba, f.room) and bodies(bb, f.room) == Enum.drop(ms, 10)
      assert prev_batch(bb, f.room) == prev_batch(ba, f.room)
    end
  end

  # ═══ the token (D6) and the fallbacks ═════════════════════════════════════════════════════════════════════════════════════════

  describe "the since token (D6)" do
    test "next_batch is <core>.<pos>, the core s2_ + 22 url-safe characters (16 random bytes), new on every sync, the row holds stream_version 1" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      b1 = S.sync(f.a, f.ta)
      b2 = S.sync(f.a, next(b1))

      for token <- [f.ta, next(b1), next(b2)] do
        assert token =~ ~r/\As2_[A-Za-z0-9_-]{22}\.\d+\z/, "#{inspect(token)}"
        assert {:ok, nonce} = token |> core() |> String.replace_prefix("s2_", "") |> Base.url_decode64(padding: false)
        assert byte_size(nonce) == 16, "16 random bytes: no user id, no event id, no position in the core"
      end

      assert length(Enum.uniq([core(f.ta), core(next(b1)), core(next(b2))])) == 3
      row = token_row(f.uid, f.a.dev)
      assert row.since_token == core(next(b2)) and row.stream_version == 1
      assert m1 in bodies(b1, f.room)
    end

    test "the token size does not grow with the number of rooms, the user id or the history" do
      small = shared!()
      big = shared!()
      for _ <- 1..6, do: S.invite_room(big.o, [big.a])
      s_small = S.sync(small.a, small.ta)
      s_big = S.sync(big.a, big.ta)
      assert String.length(core(next(s_small))) == String.length(core(next(s_big)))
      assert String.length(core(next(s_big))) == 25
    end

    test "positive control: ONE device syncs incrementally (the detector helpers: true before and after the story)" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      body = S.sync(f.a, f.ta) |> assert_incremental(f.room, m1)
      assert is_binary(next(body))
      assert_fallback(S.sync(f.a, "stale"), f.room)
    end

    test "a stream_version 0 row with a timestamp-era token is ONE fallback with the own user in device_lists.changed, then incremental" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      old_token = Base.encode64("#{f.uid}:$someevent:#{System.monotonic_time()}", padding: false)

      T.sql!("UPDATE sync_tokens SET stream_version = 0, since_token = $3, prev_since_token = NULL, generation = 0 WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev, old_token])

      fb = S.sync(f.a, old_token <> ".0")
      assert_fallback(fb, f.room)
      assert m1 in bodies(fb, f.room), "the snapshot carries the room"
      assert f.uid in changed(fb), "D10 of sync-token-per-device: a fallback to a request that carried a since lists the own user"
      assert next(fb) =~ ~r/\As2_/
      assert %{stream_version: 1} = token_row(f.uid, f.a.dev)
      assert map_size(cursors(f.uid, f.a.dev)) >= 3, "the fallback wrote the cursors of the partition rooms (D12)"

      m2 = message!(f.o, f.room, "m2")
      assert_incremental(S.sync(f.a, next(fb)), f.room, m2, [m1])
    end

    test "the legacy anchor of a timestamp-era row is never read as a position: a room whose newest event id is the old token's anchor is neither skipped nor invented" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      anchor_event = T.sql!("SELECT event_id FROM events WHERE room_id = $1 ORDER BY room_pos DESC LIMIT 1", [f.room]).rows |> hd() |> hd()
      old_token = Base.encode64("#{f.uid}:#{anchor_event}:#{System.monotonic_time()}", padding: false)
      T.sql!("UPDATE sync_tokens SET stream_version = 0, since_token = $3, last_event_id = $4 WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev, old_token, anchor_event])

      fb = S.sync(f.a, old_token)
      assert_fallback(fb, f.room)
      assert m1 in bodies(fb, f.room), "the anchor event is part of the snapshot (a timestamp anchor would have hidden everything up to it)"
    end

    test "an s2_ token on a stream_version 0 row and an old-format token on a stream_version 1 row (mixed versions) are fallbacks" do
      for variant <- [:version_zero_row, :old_token_on_new_row] do
        f = shared!()
        m1 = message!(f.o, f.room, "m1")

        presented =
          case variant do
            :version_zero_row ->
              T.sql!("UPDATE sync_tokens SET stream_version = 0 WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev])
              f.ta

            :old_token_on_new_row ->
              # an OLD node wrote the row after a new node had set stream_version 1: the stored token is in the old format
              old = Base.encode64("#{f.uid}:$ev:#{System.monotonic_time()}", padding: false)
              T.sql!("UPDATE sync_tokens SET stream_version = 1, since_token = $3 WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev, old])
              old <> ".0"
          end

        fb = S.sync(f.a, presented)
        assert_fallback(fb, f.room)
        assert m1 in bodies(fb, f.room), "#{variant}: initial-shaped, never read as positions"
        assert f.uid in changed(fb)
        assert next(fb) =~ ~r/\As2_/
        m2 = message!(f.o, f.room, "m2")
        assert_incremental(S.sync(f.a, next(fb)), f.room, m2, [m1])
      end
    end

    test "a core token WITHOUT the s2_ prefix is a fallback even when it is the stored token of a stream_version 1 row" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      weird = "ts-anchor-" <> T.rand(8)
      T.sql!("UPDATE sync_tokens SET stream_version = 1, since_token = $3, prev_since_token = NULL WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev, weird])

      fb = S.sync(f.a, weird)
      assert_fallback(fb, f.room)
      assert m1 in bodies(fb, f.room)
      assert next(fb) =~ ~r/\As2_/
    end

    test "the old positions of a previous life do not survive a fallback: the cursor rows are replaced, one per partition room, at the head" do
      f = shared!()
      T.sql!("UPDATE sync_room_cursors SET pos = 0 WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev])
      T.sql!("INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class) VALUES ($1, $2, '!ghost:test.local', 9, 77, 'join')", [f.uid, f.a.dev])
      m1 = message!(f.o, f.room, "m1")
      fb = S.sync(f.a, "garbage")
      assert_fallback(fb, f.room)
      rows = cursors(f.uid, f.a.dev)
      refute Map.has_key?(rows, "!ghost:test.local"), "the initial-shaped answer REPLACES the device's rows: a room that is no partition room has none"
      assert rows[f.room].pos == head(f.room) and rows[f.room].class == "join"
      assert Enum.all?(rows, fn {_room, row} -> row.gen == 1 and row.prev_pos == nil end), "a fresh generation 1, no previous values"
      m2 = message!(f.o, f.room, "m2")
      assert_incremental(S.sync(f.a, next(fb)), f.room, m2, [m1])
    end
  end

  # ═══ D12: the initial sync writes the cursors ═════════════════════════════════════════════════════════════════════════════════

  describe "D12 - cursors of the initial sync" do
    test "after an initial sync: one row per join room at its head (class join, gen 1), the token row has stream_version 1, generation 1" do
      uid = T.provision_user!()
      a = device!(uid, "SPA")
      o = S.user!("SPO")
      r1 = S.invite_room(o, [a])
      r2 = S.invite_room(o, [a])
      for _ <- 1..3, do: S.say!(o, r1, S.marker("x"))

      body = S.sync(a)
      assert S.in_section?(body, "join", r1) and S.in_section?(body, "join", r2)
      rows = cursors(uid, a.dev)
      assert Map.keys(rows) |> Enum.sort() == Enum.sort([r1, r2])
      assert rows[r1] == %{gen: 1, pos: head(r1), class: "join", invite_marker: nil, prev_pos: nil, prev_class: nil, prev_invite_marker: nil}
      assert rows[r2].pos == head(r2)
      assert %{stream_version: 1, generation: 1, prev_since_token: nil, since_token: since} = token_row(uid, a.dev)
      assert since == core(next(body))
    end

    test "invite rooms have class invite, left rooms class leave; a leave of the past is not delivered again" do
      uid = T.provision_user!()
      a = device!(uid, "SPA")
      o = S.user!("SPO")
      invited = S.make_room(o, %{"preset" => "private_chat"})
      S.invite!(o, invited, a)
      left = S.invite_room(o, [a])
      S.leave!(a, left)

      body = S.sync(a)
      assert invites(body) == [invited]
      refute S.in_section?(body, "leave", left), "an initial sync never delivers a leave"
      rows = cursors(uid, a.dev)
      assert rows[invited].class == "invite" and rows[invited].pos == head(invited)
      assert rows[left].class == "leave" and rows[left].pos == head(left)

      again = S.sync(a, next(body))
      refute S.in_section?(again, "leave", left), "the leave of the past is still not new"
      assert invites(again) == [], "the pending invitation is not repeated"
    end

    test "a delta after an initial sync delivers exactly what the snapshot did not contain (no loss, no duplicate)" do
      f = shared!()
      before = message!(f.o, f.room, "before")
      snap = S.sync(f.b)
      assert before in bodies(snap, f.room)
      cur = cursors(f.uid, f.b.dev)[f.room]
      assert cur.pos == head(f.room)
      post = message!(f.o, f.room, "post")
      delta = S.sync(f.b, next(snap)) |> assert_incremental(f.room, post, [before])
      assert bodies(delta, f.room) == [post]
    end
  end

  # ═══ previous generation: retry (cj (b)) ════════════════════════════════════════════════════════════════════════════════════

  describe "previous next_batch (D8, cj (b))" do
    test "a retry with T1 after the response T2 was lost is incremental: kicked room in rooms.leave, the lost response's events and the new one, T3 works" do
      f = shared!()
      t1 = f.ta
      m0 = message!(f.o, f.room2, "lost-delivery")

      lost = S.sync(f.a, t1)
      t2 = next(lost)
      assert m0 in bodies(lost, f.room2), "fixture: the response T2 carried m0, and is now lost"

      assert S.kick(f.o, f.room, f.uid).status == 200
      m1 = message!(f.o, f.room2, "after-kick")

      retry = S.sync(f.a, t1)
      refute snapshot?(retry, f.room2), "a retry with the previous next_batch is incremental, not a fallback"
      assert S.in_section?(retry, "leave", f.room), "the kick that happened in between is delivered in rooms.leave"
      assert S.member_ev(S.leave_timeline(retry, f.room), f.uid, "leave")
      assert m0 in bodies(retry, f.room2) and m1 in bodies(retry, f.room2), "what the lost response carried comes again, with what is new"

      t3 = next(retry)
      assert core(t3) != core(t1) and core(t3) != core(t2)
      m2 = message!(f.o, f.room2, "next")
      s3 = S.sync(f.a, t3)
      assert_incremental(s3, f.room2, m2, [m0, m1])
      refute S.in_section?(s3, "leave", f.room), "the leave is delivered once"
    end

    test "a SECOND retry with the same T1 (the first retry's response lost too) is incremental and loses nothing: changed rows were re-based (D8)" do
      f = shared!()
      t1 = f.ta
      t1_pos = cursors(f.uid, f.a.dev)[f.room2].pos
      # room2 receives events ONLY before the lost response (its row changed in the generation that the retry replaces and stays unchanged in the retry: the case that needs the
      # re-base); the anchor room receives the event after it, the kick is the change of the retry itself
      m0 = message!(f.o, f.room2, "lost-1")
      lost = S.sync(f.a, t1)
      assert m0 in bodies(lost, f.room2), "fixture: the response T2 carried m0 and is lost"

      assert S.kick(f.o, f.room, f.uid).status == 200
      m1 = S.marker("anchor-after")
      S.say!(f.a, f.anchor, m1)
      r1 = S.sync(f.a, t1)
      assert m0 in bodies(r1, f.room2) and m1 in bodies(r1, f.anchor), "the first retry (its response T3 is lost too)"
      assert S.in_section?(r1, "leave", f.room)
      assert cursors(f.uid, f.a.dev)[f.room2].prev_pos == t1_pos, "after the retry the previous values of the unchanged room are T1's position (re-based), not T2's"

      m2 = message!(f.o, f.room2, "new")
      r2 = S.sync(f.a, t1)
      refute snapshot?(r2, f.room2), "T1 is valid a second time: incremental, not a fallback"
      assert m0 in bodies(r2, f.room2) and m2 in bodies(r2, f.room2), "the second retry still carries the lost response's event and the new one"
      assert m1 in bodies(r2, f.anchor)
      assert S.in_section?(r2, "leave", f.room), "and the kick again"

      m3 = message!(f.o, f.room2, "after")
      r3 = S.sync(f.a, next(r2))
      assert bodies(r3, f.room2) == [m3], "the new next_batch works and repeats nothing"
      refute S.in_section?(r3, "leave", f.room)
      assert_fallback(S.sync(f.a, next(lost)), f.room2)
    end

    test "after the retry the lost response's own token T2 is dead (a fallback)" do
      f = shared!()
      lost = S.sync(f.a, f.ta)
      m1 = message!(f.o, f.room, "m1")
      retry = S.sync(f.a, f.ta)
      assert m1 in bodies(retry, f.room)
      refute snapshot?(retry, f.room)

      assert_fallback(S.sync(f.a, next(lost)), f.room)
    end

    test "two generations old, a foreign device's, a foreign user's and a forged s2_ token are fallbacks; every other row stays byte-identical" do
      f = shared!()
      other = shared!()
      t1 = f.ta
      t2 = next(S.sync(f.a, t1))
      t3 = next(S.sync(f.a, t2))
      before_b = device_state(state_rows(f.uid), f.b.dev)
      assert elem(before_b, 0) != nil and map_size(elem(before_b, 1)) > 0
      before_other = state_rows(other.uid)
      m1 = message!(f.o, f.room, "m1")

      forged = "s2_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false) <> ".0"

      for {label, token} <- [two_old: t1, foreign_device: f.tb, foreign_user: other.ta, forged: forged] do
        body = S.sync(f.a, token)
        assert_fallback(body, f.room)
        assert m1 in bodies(body, f.room), "#{label}: the caller's own partition, as an initial sync"
        refute Enum.any?(S.join_timeline(body, other.room), fn _ -> true end), "#{label}: nothing of the other user"
        assert S.join_state(body, other.room) == [] and not S.in_section?(body, "join", other.room)
        assert f.uid in changed(body)
      end

      assert state_rows(other.uid) == before_other, "the other user's rows are byte-identical"
      assert device_state(state_rows(f.uid), f.b.dev) == before_b, "device B's token row and cursor rows are byte-identical"
      # control: the token that was current before the four fallbacks is gone after them (the device is on the fallback's token now)
      assert_fallback(S.sync(f.a, t3), f.room)
    end

    test "device B presenting A's current and previous next_batch is a fallback (D18); A's rows stay byte-identical and A's retry still works" do
      f = shared!()
      t1 = f.ta
      t2 = next(S.sync(f.a, t1))
      m1 = message!(f.o, f.room, "m1")
      a_before = device_state(state_rows(f.uid), f.a.dev)

      for {label, token} <- [a_previous: t1, a_current: t2] do
        body = S.sync(f.b, token)
        assert_fallback(body, f.room)
        assert m1 in bodies(body, f.room), "#{label}: B gets its OWN partition as an initial sync"
        assert core(next(body)) != core(t1) and core(next(body)) != core(t2)
      end

      assert device_state(state_rows(f.uid), f.a.dev) == a_before, "A's token row and cursor rows are byte-identical after B's requests"
      # A's own previous token still works
      assert_incremental(S.sync(f.a, t1), f.room, m1)
    end

    test "the global account data of the lost response comes again with the retry (previous generation's position), not again with the new token" do
      f = shared!()
      put = fn type, content -> assert T.matrix_request(:put, "/_matrix/client/v3/user/#{S.enc(f.uid)}/account_data/#{type}", f.a.at, body: content).status == 200 end
      put.("org.sp.one", %{"v" => 1})
      m1 = message!(f.o, f.room, "m1")

      lost = S.sync(f.a, f.ta)
      assert Enum.any?(get_in(lost, ["account_data", "events"]) || [], &(&1["type"] == "org.sp.one")), "fixture: the lost response carried the account data"

      retry = S.sync(f.a, f.ta)
      assert_incremental(retry, f.room, m1)
      types = for ev <- get_in(retry, ["account_data", "events"]) || [], do: ev["type"]
      assert "org.sp.one" in types, "a retry delivers what the lost response carried (positions of the base generation), not only what is newer"

      again = S.sync(f.a, next(retry))
      assert (get_in(again, ["account_data", "events"]) || []) == [], "the retry's own next_batch does not repeat it"
    end

    test "a retry with the previous next_batch after an EMPTY response is incremental" do
      f = shared!()
      empty = S.sync(f.a, f.ta)
      assert bodies(empty, f.room) == []
      m1 = message!(f.o, f.room, "m1")
      retry = S.sync(f.a, f.ta)
      assert_incremental(retry, f.room, m1)
    end
  end

  # ═══ invitations exactly once (D9) ═══════════════════════════════════════════════════════════════════════════════════════════

  describe "invitations once (D9)" do
    test "event-backed R and row-only S: both in the first sync, neither in the second; a decline plus re-invite delivers R again, never S" do
      f = shared!()
      inviter = S.user!("SPI")
      r = S.make_room(inviter, %{"preset" => "private_chat"})
      sroom = S.make_room(inviter, %{"preset" => "private_chat"})
      S.invite!(inviter, r, f.a)
      S.row_only_invitation!(sroom, inviter, f.a)

      first = S.sync(f.a, f.ta)
      assert invites(first) == Enum.sort([r, sroom]), "both invitations are new"
      second = S.sync(f.a, next(first))
      assert invites(second) == [], "exactly once: the former `repeats until the anchor passes invited_at` is over"

      assert S.leave(f.a, r).status == 200, "decline"
      S.tick()
      S.invite!(inviter, r, f.a)
      third = S.sync(f.a, next(second))
      assert invites(third) == [r], "the re-invitation to R is new (its invite event is above the cursor); S is not repeated"
      fourth = S.sync(f.a, next(third))
      assert invites(fourth) == []
    end

    test "a row-only invitation whose invited_at changed (a new invitation) is delivered again; an unchanged one never; the marker is stored on the cursor row" do
      f = shared!()
      inviter = S.user!("SPI")
      sroom = S.make_room(inviter, %{"preset" => "private_chat"})
      S.row_only_invitation!(sroom, inviter, f.a)

      first = S.sync(f.a, f.ta)
      assert invites(first) == [sroom]
      row = cursors(f.uid, f.a.dev)[sroom]
      invited_at = T.sql!("SELECT invited_at FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [sroom, f.uid]).rows |> hd() |> hd()
      assert row.class == "invite" and row.invite_marker == invited_at

      second = S.sync(f.a, next(first))
      assert invites(second) == []

      T.sql!("UPDATE room_invitations SET invited_at = invited_at + 7 WHERE room_id = $1 AND invitee_id = $2", [sroom, f.uid])
      third = S.sync(f.a, next(second))
      assert invites(third) == [sroom], "an exact inequality of the row's own value: no clock comparison"
      assert cursors(f.uid, f.a.dev)[sroom].invite_marker == invited_at + 7
    end

    test "the two devices of a user each get the invitation once (the cursor is per device)" do
      f = shared!()
      inviter = S.user!("SPI")
      r = S.make_room(inviter, %{"preset" => "private_chat"})
      S.invite!(inviter, r, f.a)
      a1 = S.sync(f.a, f.ta)
      b1 = S.sync(f.b, f.tb)
      assert invites(a1) == [r] and invites(b1) == [r]
      assert invites(S.sync(f.a, next(a1))) == [] and invites(S.sync(f.b, next(b1))) == []
    end
  end

  # ═══ the leave window (D10) ═════════════════════════════════════════════════════════════════════════════════════════════════

  defp end_membership!(:leave, f), do: S.leave!(f.a, f.room)
  defp end_membership!(:kick, f), do: assert(S.kick(f.o, f.room, f.uid).status == 200)
  defp end_membership!(:ban, f), do: assert(S.ban(f.o, f.room, f.uid).status == 200)

  describe "the leave window (D10)" do
    for {cause, membership} <- [leave: "leave", kick: "leave", ban: "ban"] do
      test "#{cause}: rooms.leave carries the messages strictly between device B's cursor and the #{cause} event, then the #{cause} event, and no event at or after it; once" do
        f = shared!()
        membership = unquote(membership)
        # B syncs while joined (its cursor), then later messages, then the cause, then more messages
        seen = message!(f.o, f.room, "seen")
        b0 = S.sync(f.b, f.tb)
        assert seen in bodies(b0, f.room)
        w1 = message!(f.o, f.room, "w1")
        w2 = message!(f.o, f.room, "w2")
        S.tick()
        end_membership!(unquote(cause), f)
        after1 = message!(f.o, f.room, "after1")
        after2 = message!(f.o, f.room, "after2")

        body = S.sync(f.b, next(b0))
        timeline = S.leave_timeline(body, f.room)
        assert S.in_section?(body, "leave", f.room) and not S.in_section?(body, "join", f.room)
        assert leave_bodies(body, f.room) == [w1, w2], "exactly the messages between the cursor and the cause, oldest first"
        assert seen not in leave_bodies(body, f.room), "what B was sent before is not repeated"
        last = List.last(timeline)
        assert last["type"] == "m.room.member" and last["state_key"] == f.uid and get_in(last, ["content", "membership"]) == membership, "the window ENDS at the #{membership} event"
        refute Enum.any?(timeline, &(&1["content"]["body"] in [after1, after2])), "nothing at or after the cause"

        refute S.member_ev(timeline, f.uid, "join"), "the join event lies below the device's cursor: it is not prepended again (D10: P only when newer than the cursor)"
        assert S.in_section?(S.sync(f.b, next(body)), "leave", f.room) == false, "once"
        # device A, which never synced since the fixture, gets the same window from ITS cursor
        a_body = S.sync(f.a, f.ta)
        assert leave_bodies(a_body, f.room) == [seen, w1, w2]
      end

      test "#{cause}: with the member row's left_at set EARLIER than the event (a skewed node clock) the window ends at left_at instead, never later" do
        f = shared!()
        m1 = message!(f.o, f.room, "m1")
        S.tick()
        m2 = message!(f.o, f.room, "m2")
        S.tick()
        end_membership!(unquote(cause), f)

        ts_of = fn marker -> T.sql!("SELECT origin_server_ts FROM events WHERE room_id = $1 AND content->>'body' = $2", [f.room, marker]).rows |> hd() |> hd() end
        # left_at = the timestamp of m2: strict, so m2 (and everything later) is outside, m1 inside
        T.sql!("UPDATE room_members SET left_at = $3 WHERE room_id = $1 AND user_id = $2", [f.room, f.uid, ts_of.(m2)])

        body = S.sync(f.a, f.ta)
        assert S.in_section?(body, "leave", f.room)
        assert leave_bodies(body, f.room) == [m1], "the window ends at left_at (strict): never later than the row says"
        assert m2 not in leave_bodies(body, f.room)
      end
    end

    test "an event committed AFTER the kick whose timestamp lies inside the row's clock window is NOT in the window: the position bound ends it, not the clock (D10)" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      S.tick()
      end_membership!(:kick, f)

      [[left_at, joined_at]] = T.sql!("SELECT left_at, joined_at FROM room_members WHERE room_id = $1 AND user_id = $2", [f.room, f.uid]).rows
      assert is_integer(left_at) and is_integer(joined_at) and joined_at < left_at - 1, "fixture: the member row carries both clocks"
      skewed = left_at - 1

      assert :ok =
               DB.insert_event(%{
                 "event_id" => "$skew" <> T.rand(12),
                 "room_id" => f.room,
                 "sender" => f.o.uid,
                 "type" => "m.room.message",
                 "state_key" => nil,
                 "content" => %{"msgtype" => "m.text", "body" => "after-the-kick-skewed"},
                 "origin_server_ts" => skewed
               })

      body = S.sync(f.a, f.ta)
      assert leave_bodies(body, f.room) == [m1], "a node whose clock is behind wrote an event AFTER the kick with a timestamp before left_at: only the position keeps it out"
      assert List.last(S.leave_timeline(body, f.room))["type"] == "m.room.member"
    end

    test "a leave of a room the device never saw starts at the JOIN event (prepended), then the messages, then the leave event" do
      f = shared!()
      room = S.invite_room(f.o, [f.a])
      m = message!(f.o, room, "inside")
      S.tick()
      S.leave!(f.a, room)

      body = S.sync(f.b, f.tb)
      timeline = S.leave_timeline(body, room)
      assert S.in_section?(body, "leave", room)
      assert [first | _] = timeline
      assert first["type"] == "m.room.member" and first["state_key"] == f.uid and get_in(first, ["content", "membership"]) == "join", "the join event P comes first: the device has no cursor for the room"
      assert leave_bodies(body, room) == [m]
      assert List.last(timeline)["type"] == "m.room.member" and get_in(List.last(timeline), ["content", "membership"]) == "leave"
    end

    test "a leave window of more than 20 messages: the newest 20 and the leave event, limited, a real v1_ prev_batch that pages back over the older ones" do
      f = shared!()
      ms = send_many!(f.o, f.room, 25, "w")
      S.tick()
      end_membership!(:kick, f)
      after1 = message!(f.o, f.room, "after")

      body = S.sync(f.a, f.ta)
      timeline = S.leave_timeline(body, f.room)
      assert leave_bodies(body, f.room) == Enum.drop(ms, 5), "the NEWEST 20 of the window, oldest first"
      assert get_in(body, ["rooms", "leave", f.room, "timeline", "limited"]) == true
      prev = get_in(body, ["rooms", "leave", f.room, "timeline", "prev_batch"])
      assert is_binary(prev) and prev =~ ~r/\Av1_/, "prev_batch of a limited leave window is a /messages token (it was the oldest event id)"
      assert List.last(timeline)["type"] == "m.room.member"
      refute after1 in leave_bodies(body, f.room)
    end

    test "a window with exactly 20 messages is not limited and carries no prev_batch key" do
      f = shared!()
      ms = send_many!(f.o, f.room, 20, "w")
      S.tick()
      end_membership!(:kick, f)
      body = S.sync(f.a, f.ta)
      assert leave_bodies(body, f.room) == ms
      assert get_in(body, ["rooms", "leave", f.room, "timeline", "limited"]) in [false, nil]
      refute Map.has_key?(get_in(body, ["rooms", "leave", f.room, "timeline"]), "prev_batch")
    end

    test "a user who was invited and DECLINED gets the decline event only (no window: there was no join), once, after a quiet sync" do
      f = shared!()
      inviter = S.user!("SPI")
      r = S.make_room(inviter, %{"preset" => "private_chat"})
      S.invite!(inviter, r, f.a)
      first = S.sync(f.a, f.ta)
      assert invites(first) == [r]
      assert S.leave(f.a, r).status == 200
      body = S.sync(f.a, next(first))
      assert S.in_section?(body, "leave", r)
      assert [%{"type" => "m.room.member"}] = S.leave_timeline(body, r)
      assert S.in_section?(S.sync(f.a, next(body)), "leave", r) == false
    end
  end

  # ═══ a newly joined room (D11) ═════════════════════════════════════════════════════════════════════════════════════════════

  describe "newly joined room (D11)" do
    test "joined after the sync, 25 messages: the newest 20, limited, a valid prev_batch and ALL room account data (also the row below the position)" do
      f = shared!()
      o = f.o
      room = S.make_room(o, %{"preset" => "private_chat"})
      # a room account data row for a room the user is not in yet: it sits BELOW the position the next token carries
      assert :ok = Nebu.Matrix.RoomAccountDataStore.put(f.uid, room, "org.sp.old", ~s({"v":1}))
      sync_before = S.sync(f.a, f.ta)
      refute S.in_section?(sync_before, "join", room)

      S.invite!(o, room, f.a)
      S.join!(f.a, room)
      ms = send_many!(o, room, 25, "n")
      conn = T.matrix_request(:put, "/_matrix/client/v3/user/#{S.enc(f.uid)}/rooms/#{S.enc(room)}/account_data/org.sp.new", f.a.at, body: %{"v" => 2})
      assert conn.status == 200

      body = S.sync(f.a, next(sync_before))
      assert S.in_section?(body, "join", room)
      assert bodies(body, room) == Enum.drop(ms, 5)
      assert limited?(body, room)
      assert prev_batch(body, room) =~ ~r/\Av1_/
      types = for ev <- get_in(body, ["rooms", "join", room, "account_data", "events"]) || [], do: ev["type"]
      assert Enum.sort(types) == ["org.sp.new", "org.sp.old"], "ALL the room's account data, including the row the device's position had already passed"
      assert Enum.sort(Map.keys(cursors(f.uid, f.a.dev))) |> Enum.member?(room)
      assert cursors(f.uid, f.a.dev)[room].class == "join"

      # not newly joined any more: the next sync carries only what changed
      again = S.sync(f.a, next(body))
      assert (get_in(again, ["rooms", "join", room, "account_data", "events"]) || []) == []
    end
  end

  # ═══ history visibility ═════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "history visibility still filters the position window" do
    test "events sent while the user was out of a hv=joined room are not delivered, do not count towards 20, the cursor reaches the head" do
      f = shared!()
      assert S.put_state(f.o, f.room, "m.room.history_visibility", %{"history_visibility" => "joined"}).status == 200
      first = S.sync(f.a, f.ta)
      S.tick()
      S.leave!(f.a, f.room)
      left_window = S.sync(f.a, next(first))
      assert S.in_section?(left_window, "leave", f.room)

      hidden = send_many!(f.o, f.room, 25, "hid")
      S.tick()
      S.invite!(f.o, f.room, f.a)
      S.join!(f.a, f.room)
      S.tick()
      visible = send_many!(f.o, f.room, 3, "vis")

      body = S.sync(f.a, next(left_window))
      assert bodies(body, f.room) == visible, "only the three messages from after the re-join: the 25 hidden ones are not delivered"
      refute limited?(body, f.room), "hidden events do not count towards the 20 (28 events in the range, 3 visible)"
      assert Enum.all?(hidden, &(&1 not in bodies(body, f.room)))
      assert cursors(f.uid, f.a.dev)[f.room].pos == head(f.room), "the cursor reaches the head"
      assert bodies(S.sync(f.a, next(body)), f.room) == []
    end
  end

  # ═══ full_state=true is unchanged ═══════════════════════════════════════════════════════════════════════════════════════════

  describe "full_state=true stays what it was (D16)" do
    test "rooms with news keep their delta timeline, the others are full-state rooms with an empty timeline, and the sync is still incremental afterwards" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      body = S.sync(f.a, f.ta, full_state: "true")
      assert m1 in bodies(body, f.room), "a room with news keeps its timeline"
      refute snapshot?(body, f.room)
      assert S.in_section?(body, "join", f.room2), "a room without news is a full-state room"
      assert S.join_timeline(body, f.room2) == [] and S.join_state(body, f.room2) != []
      refute limited?(body, f.room2)

      m2 = message!(f.o, f.room, "m2")
      assert_incremental(S.sync(f.a, next(body)), f.room, m2, [m1])
    end
  end

  # ═══ (c), (d), skew: the same-millisecond, the createRoom lead and the node clock, through the real writers ═══════════════════

  describe "delivery does not depend on any clock" do
    test "(c) two events of one room in the same millisecond on either side of a sync: the second is delivered, the first is not repeated" do
      f = shared!()
      ts = System.system_time(:millisecond) + 50
      on_exit(fn -> T.sql!("DELETE FROM events WHERE room_id = $1 AND origin_server_ts = $2", [f.room, ts]) end)

      put_msg = fn body -> assert :ok = DB.insert_event(%{"event_id" => "$sm" <> T.rand(12), "room_id" => f.room, "sender" => f.o.uid, "type" => "m.room.message", "state_key" => nil, "content" => %{"msgtype" => "m.text", "body" => body}, "origin_server_ts" => ts}) end

      put_msg.("same-ms-1")
      s1 = S.sync(f.a, f.ta)
      assert "same-ms-1" in bodies(s1, f.room)
      put_msg.("same-ms-2")
      s2 = S.sync(f.a, next(s1))
      assert bodies(s2, f.room) == ["same-ms-2"], "the second event of the millisecond is delivered, the first is not repeated"
      assert bodies(S.sync(f.a, next(s2)), f.room) == []
    end

    test "(d) a createRoom invite stamped ahead of the clock is the last delivered event: a message sent in another room inside the lead is still delivered" do
      f = shared!()
      inviter = S.user!("SPI")
      # the real chain: createRoom with an invite (stamped up to ~70 ms ahead of the clock)
      created = S.make_room(inviter, %{"preset" => "private_chat", "invite" => [f.uid], "name" => "lead"})
      s1 = S.sync(f.a, f.ta)
      assert invites(s1) == [created]
      m = S.marker("inside-the-lead")
      S.say!(f.o, f.room, m)
      assert m in bodies(S.sync(f.a, next(s1)), f.room), "the message is delivered although the invite event's timestamp may be ahead of it"
    end

    test "(d) the same with a lead far beyond any real one: an invite event stamped 3 s ahead, a message sent right after the sync that delivered it" do
      f = shared!()
      inviter = S.user!("SPI")
      room = S.make_room(inviter, %{"preset" => "private_chat"})
      ahead = System.system_time(:millisecond) + 3_000
      on_exit(fn -> T.sql!("DELETE FROM events WHERE room_id = $1", [room]) end)
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, inviter.uid, f.uid)
      S.insert_member_event!(room, f.uid, "invite", inviter, ahead)

      s1 = S.sync(f.a, f.ta)
      assert invites(s1) == [room]
      # no tick/0 here: it would wait for the clock to pass the 3 s lead
      m = S.marker("behind-the-lead")
      S.say!(f.o, f.room, m)
      s2 = S.sync(f.a, next(s1))
      assert m in bodies(s2, f.room), "a timestamp anchor on the invite event would hide every message of the next 3 s"
      assert invites(s2) == []
    end

    test "clock skew: a message written by a node whose clock is 5 s behind, after the device received a newer event, is delivered" do
      f = shared!()
      newer = message!(f.o, f.room, "node1")
      s1 = S.sync(f.a, f.ta)
      assert newer in bodies(s1, f.room)

      skewed_ts = System.system_time(:millisecond) - 5_000
      id = "$skew" <> T.rand(12)
      assert :ok = DB.insert_event(%{"event_id" => id, "room_id" => f.room, "sender" => f.o.uid, "type" => "m.room.message", "state_key" => nil, "content" => %{"msgtype" => "m.text", "body" => "node2"}, "origin_server_ts" => skewed_ts})

      s2 = S.sync(f.a, next(s1))
      assert bodies(s2, f.room) == ["node2"], "delivery is by position: the older timestamp does not hide it"
      assert bodies(S.sync(f.a, next(s2)), f.room) == [], "exactly once"
    end

    test "a later event with an OLDER timestamp in another room than the newest delivered one is delivered (the global maximum anchor is gone)" do
      f = shared!()
      newer = message!(f.o, f.room2, "newer")
      s1 = S.sync(f.a, f.ta)
      assert newer in bodies(s1, f.room2)
      old = System.system_time(:millisecond) - 10_000

      assert :ok = DB.insert_event(%{"event_id" => "$old" <> T.rand(12), "room_id" => f.room, "sender" => f.o.uid, "type" => "m.room.message", "state_key" => nil, "content" => %{"msgtype" => "m.text", "body" => "older-ts"}, "origin_server_ts" => old})
      s2 = S.sync(f.a, next(s1))
      assert bodies(s2, f.room) == ["older-ts"]
    end
  end

  # ═══ cost: quiet rooms cost nothing ═════════════════════════════════════════════════════════════════════════════════════════

  describe "per-sync cost (D14)" do
    test "a user joined to 20 rooms of which one received an event costs the same number of statements as a user joined to 3: one head statement, one room read" do
      counts =
        for n <- [3, 20] do
          uid = T.provision_user!()
          a = device!(uid, "SPA")
          o = S.user!("SPO")
          rooms = for _ <- 1..n, do: S.invite_room(o, [a])
          ta = S.snapshot!(a, S.anchor_room!(a))
          m = message!(o, hd(rooms), "only")

          {body, statements} = Nebu.Matrix.MembershipStateTestSupport.count_statements(fn -> S.sync(a, ta) end, rooms)
          assert m in bodies(body, hd(rooms))
          {n, length(statements), statements}
        end

      [{3, small, small_statements}, {20, big, big_statements}] = counts
      assert small == big, "17 more quiet rooms cost #{big - small} more statements\n--- 3 rooms ---\n#{Nebu.Matrix.MembershipStateTestSupport.listing(small_statements)}\n--- 20 rooms ---\n#{Nebu.Matrix.MembershipStateTestSupport.listing(big_statements)}"
    end
  end

  describe "per-sync cost (D14), design-independent" do
    defp cursor_statements(statements), do: Enum.filter(statements, &String.contains?(&1, "sync_room_cursors"))
    defp position_statements(statements), do: Enum.filter(statements, &String.contains?(&1, "room_pos"))

    # B-3 (test review): the constants of the re-pinned suites are measurements of the reference design; THESE tests hold for any design that keeps D12 / D14 ("ONE bulk statement
    # regardless of the room count", one head statement, one range read per MOVED room): a per-room cursor INSERT / upsert loop fails them
    test "the statements that touch the cursor table are the same for an initial sync of 3 and of 20 rooms (one head read, one delete, one bulk write)" do
      counts =
        for n <- [3, 20] do
          uid = T.provision_user!()
          a = device!(uid, "SPA")
          o = S.user!("SPO")
          rooms = for _ <- 1..n, do: S.invite_room(o, [a])
          {_body, statements} = Nebu.Matrix.MembershipStateTestSupport.count_statements(fn -> S.sync(a) end, rooms)
          {n, length(cursor_statements(statements)), cursor_statements(statements)}
        end

      [{3, small, small_statements}, {20, big, _}] = counts
      assert small >= 1, "fixture: the initial sync touches the cursor table"
      assert small == big, "17 more rooms cost #{big - small} more cursor statements (a per-room loop?):\n#{Enum.join(small_statements, "\n")}"
    end

    test "an incremental sync with 5 moved rooms runs the same cursor statements as with 1 and exactly 4 more position reads (one range read per room)" do
      measured =
        for moved <- [1, 5] do
          uid = T.provision_user!()
          a = device!(uid, "SPA")
          o = S.user!("SPO")
          rooms = for _ <- 1..6, do: S.invite_room(o, [a])
          ta = S.snapshot!(a, S.anchor_room!(a))
          for room <- Enum.take(rooms, moved), do: message!(o, room, "m")
          {body, statements} = Nebu.Matrix.MembershipStateTestSupport.count_statements(fn -> S.sync(a, ta) end, rooms)
          assert Enum.count(rooms, &(bodies(body, &1) != [])) == moved
          {length(cursor_statements(statements)), length(position_statements(statements))}
        end

      [{cursor_one, positions_one}, {cursor_five, positions_five}] = measured
      assert cursor_one == cursor_five, "the cursor statements do not grow with the moved rooms (one upsert): #{cursor_one} vs #{cursor_five}"
      assert positions_five - positions_one == 4, "one range read per moved room: #{positions_one} vs #{positions_five}"
    end
  end

  # ═══ the cursor rows die with the device ════════════════════════════════════════════════════════════════════════════════════

  describe "cascade of the cursor rows" do
    test "POST /logout removes the device's cursors, another device's cursors stay" do
      f = shared!()
      assert map_size(cursors(f.uid, f.a.dev)) > 0 and map_size(cursors(f.uid, f.b.dev)) > 0
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", f.a.at).status == 200
      assert cursors(f.uid, f.a.dev) == %{}
      assert token_row(f.uid, f.a.dev) == nil
      assert map_size(cursors(f.uid, f.b.dev)) > 0
    end

    test "POST /logout/all removes the cursors of every device of the user" do
      f = shared!()
      assert T.matrix_request(:post, "/_matrix/client/v3/logout/all", f.a.at).status == 200
      assert cursors(f.uid, f.a.dev) == %{} and cursors(f.uid, f.b.dev) == %{}
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [f.uid]).rows == [[0]]
    end

    test "a hard delete of the sync_tokens row (device teardown, deactivation, GDPR erasure delete it) leaves no cursor behind, and other users' cursors stay" do
      f = shared!()
      other = shared!()
      T.sql!("DELETE FROM sync_tokens WHERE user_id = $1", [f.uid])
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [f.uid]).rows == [[0]]
      assert map_size(cursors(other.uid, other.a.dev)) > 0
    end
  end

  # ═══ no tokens, cursors or content in logs ════════════════════════════════════════════════════════════════════════════════

  describe "logs" do
    test "incremental syncs, a fallback and a retry with the previous token, captured at debug level, never log a core token, a body or a position pair" do
      f = shared!()
      marker = S.marker("secret-body")

      log =
        capture_log([level: :debug], fn ->
          S.say!(f.o, f.room, marker)
          b1 = S.sync(f.a, f.ta)
          assert marker in bodies(b1, f.room)
          retry = S.sync(f.a, f.ta)
          S.sync(f.a, next(retry))
          S.sync(f.a, "s2_forgedforgedforgedforged.0")
          Process.sleep(50)
        end)

      for token <- [f.ta, "s2_forgedforgedforgedforged"], do: refute(log =~ core(token), "a since token was logged")
      refute log =~ marker, "message content was logged"
      refute log =~ ~r/sync_room_cursors|prev_pos|invite_marker/, "cursor internals were logged"
    end
  end
end
