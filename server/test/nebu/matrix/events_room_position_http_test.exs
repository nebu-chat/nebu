defmodule Nebu.Matrix.EventsRoomPositionHttpTest do
  @moduledoc """
  Story `events-room-position` (epic oauth-broker, follow-up `fc`, story 1 of 2), Scenario 1 (every writer path stamps consecutive positions) through the REAL stack: `Nebu.Web.Router`
  through `Plug.Test`, the real `Nebu.Repo`, real `Room.Server` under Horde, users and legacy sessions as in the moderation suites. `async: false`, tagged `:integration`.

  The positions are read with SQL strings (`events.room_pos`, `rooms.event_pos`), so a missing migration 000053 is a runtime failure of the test, never a compile error. After adding the
  migration reset the throwaway database (`.oauth-ci/cleanup.sh`).

  ## Decisions of the ATDD step (ambiguities of the story)

    * "In room_pos order, 1, 2, 3 ... without gaps or duplicates" is checked as: the positions of ALL events of the room, read ordered by `room_pos`, are exactly `1..n`, `rooms.event_pos == n`, and
      the events of every STEP (one writer path) come strictly after those of the earlier steps (the earlier rows keep their positions and stay the first ones). Within createRoom, the first event
      (position 1) is the `m.room.create` event (written outside the room process); the order inside one createRoom is not pinned further.
    * The writer paths driven: createRoom with a preset, name, topic, `invite` and `initial_state` (`m.room.create` and the state events written outside the room process by
      `emit_state_event_at/6`, the invite through the room process), `/send` (room process, autocommit), `PUT state`, `PUT m.room.power_levels`, `/invite`, own `/join` (`emit_membership_event/4`), `/kick`,
      the decline of a pending invitation (`POST /leave`, `apply_member_change/4`), the redaction, the decline of an invitation to an ARCHIVED room (`emit_decline_event/2`, written outside the room
      process), and the personal room (`ensure_personal_room/1` -> `create_personal_room/2`, started by `run_post_login_provisioning/2`).
    * The concurrent test mixes six HTTP writers of three kinds with one direct `Room.DB.insert_event/1` (a writer outside the room process, like the four direct writers and a Horde handover): after the
      race every request answered 200 and the positions are exactly `1..n` (each successful request wrote exactly one event).
    * D7 / D8: no response shows a position (`/messages`, `/event`, `/sync`).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport, only: [levels: 1, put_pl: 3, ok_event_id!: 2]
  import Nebu.Matrix.RedactionTestSupport, only: [redact_id!: 3]

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    on_exit(fn -> T.restore_rate_limits() end)

    {:ok, a: user!("EPA"), b: user!("EPB"), c: user!("EPC")}
  end

  # ─── the database, as the tests see it ───────────────────────────────────────

  # every event of the room ordered by room_pos (unstamped rows last)
  defp rows(room) do
    T.sql!("SELECT event_id, event_type, state_key, content, room_pos FROM events WHERE room_id = $1 ORDER BY room_pos NULLS LAST, event_id", [room]).rows
    |> Enum.map(fn [id, type, key, content, pos] -> %{id: id, type: type, key: key, content: content_of(content), pos: pos} end)
  end

  defp counter(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # the positions of the room are exactly 1..n and rooms.event_pos is n; returns the rows
  defp assert_stamped!(room, label) do
    rs = rows(room)
    positions = Enum.map(rs, & &1.pos)
    n = length(rs)
    assert positions == Enum.to_list(1..n//1), "#{label}: the positions of the room are #{inspect(positions)}, expected 1..#{n} without gaps, duplicates or NULLs"
    assert counter(room) == n, "#{label}: rooms.event_pos is #{counter(room)}, expected the highest position #{n}"
    rs
  end

  # runs one writer path; asserts it wrote events, all stamped AFTER the earlier ones (the earlier rows stay the first ones, with their positions); returns the new rows
  defp step!(room, label, fun) do
    before = assert_stamped!(room, "before #{label}")
    fun.()
    after_rows = assert_stamped!(room, "after #{label}")
    assert length(after_rows) > length(before), "#{label} wrote no event"
    assert Enum.take(after_rows, length(before)) == before, "#{label}: an earlier event changed its position or a new event took an earlier one"
    Enum.drop(after_rows, length(before))
  end

  defp member_of(new_rows, uid, membership),
    do: Enum.find(new_rows, &(&1.type == "m.room.member" and &1.key == uid and &1.content["membership"] == membership))

  defp await_personal_room!(uid, attempts \\ 400) do
    case T.sql!("SELECT personal_room_id FROM users WHERE user_id = $1", [uid]).rows do
      [[room]] when is_binary(room) ->
        room

      _ when attempts > 0 ->
        Process.sleep(25)
        await_personal_room!(uid, attempts - 1)

      _ ->
        flunk("the personal room of #{uid} was not created within 10 s")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # Scenario 1: every writer path stamps consecutive positions
  # ═══════════════════════════════════════════════════════════════════════════════

  describe "Scenario 1 - every writer path stamps consecutive positions" do
    test "createRoom, decline, send, state PUT, power levels, invite, join, kick, redaction: positions 1..n in order", %{a: a, b: b, c: c} do
      room =
        make_room(a, %{
          "preset" => "private_chat",
          "name" => "epos #{T.rand(3)}",
          "topic" => "epos topic",
          "invite" => [b.uid],
          "initial_state" => [
            %{"type" => "m.room.guest_access", "state_key" => "", "content" => %{"guest_access" => "forbidden"}},
            %{"type" => "org.example.epos", "state_key" => "k", "content" => %{"x" => 1}}
          ]
        })

      created = assert_stamped!(room, "createRoom")
      assert hd(created).type == "m.room.create" and hd(created).pos == 1, "the m.room.create event is the first event of the room, position 1"
      types = Enum.map(created, & &1.type)
      for t <- ["m.room.member", "m.room.power_levels", "m.room.join_rules", "m.room.name", "m.room.topic", "m.room.guest_access", "org.example.epos"], do: assert(t in types, "createRoom wrote #{t}")
      assert member_of(created, b.uid, "invite"), "the invite of createRoom is stamped"

      declined = step!(room, "the decline of a pending invitation", fn -> leave!(b, room) end)
      assert member_of(declined, b.uid, "leave")

      sent = step!(room, "a message", fn -> say!(a, room, "one") end)
      assert [%{type: "m.room.message", id: message_id}] = sent

      assert [%{type: "m.room.topic"}] = step!(room, "a state PUT", fn -> ok_event_id!(put_state(a, room, "m.room.topic", %{"topic" => "t2"}), "state PUT") end)
      assert [%{type: "m.room.power_levels"}] = step!(room, "a power-level change", fn -> ok_event_id!(put_pl(a, room, levels(%{a.uid => 100})), "power levels") end)

      invited = step!(room, "an invite", fn -> invite!(a, room, c) end)
      assert member_of(invited, c.uid, "invite")
      joined = step!(room, "an own join", fn -> join!(c, room) end)
      assert member_of(joined, c.uid, "join")
      kicked = step!(room, "a kick", fn -> ok!(kick(a, room, c), "kick") end)
      assert member_of(kicked, c.uid, "leave")

      redaction = step!(room, "a redaction", fn -> redact_id!(a, room, message_id) end)
      assert [%{type: "m.room.redaction"}] = redaction

      final = assert_stamped!(room, "the end")
      assert length(final) == length(Enum.uniq_by(final, & &1.id)), "no event twice"
    end

    test "the decline of an invitation to an ARCHIVED room is stamped; every room counts from 1", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      other = make_room(a, %{"preset" => "public_chat"})
      assert hd(assert_stamped!(other, "the other room")).pos == 1

      before = assert_stamped!(room, "before the archive")
      T.sql!("UPDATE rooms SET status = 'archived' WHERE room_id = $1", [room])

      declined =
        step!(room, "the archived-room decline", fn ->
          conn = leave(b, room)
          assert conn.status == 200, "decline of an invitation to an archived room: #{conn.status} #{String.slice(conn.resp_body, 0, 160)}"
        end)

      assert member_of(declined, b.uid, "leave")
      assert hd(declined).pos == length(before) + 1
      assert counter(other) == length(rows(other)), "the other room was not touched"
    end

    test "the personal room (created at the first login, outside the room process) is stamped the same way" do
      uid = T.provision_user!()
      assert :ok = Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning(uid, false)

      room = await_personal_room!(uid)
      stamped = assert_stamped!(room, "the personal room")
      assert hd(stamped).type == "m.room.create" and hd(stamped).pos == 1
      assert length(stamped) >= 3, "create, member, power levels at least"
    end

  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # concurrent writers of one room
  # ═══════════════════════════════════════════════════════════════════════════════

  describe "concurrent writers of one room" do
    test "sends, a state PUT, a kick, a leave and a direct insert race: all 200, positions exactly 1..n", %{a: a, b: b, c: c} do
      for round <- 1..5 do
        room = public_room(a)
        join_now!(b, room)
        join_now!(c, room)
        before = length(assert_stamped!(room, "round #{round} before"))

        direct = %{
          "event_id" => "$epos" <> T.rand(12),
          "room_id" => room,
          "sender" => a.uid,
          "type" => "m.room.message",
          "state_key" => nil,
          "content" => %{"msgtype" => "m.text", "body" => "direct"},
          "origin_server_ts" => System.system_time(:millisecond),
          "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(32))}
        }

        results =
          race([
            fn -> {:conn, T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), a.at, body: %{"msgtype" => "m.text", "body" => "a1"})} end,
            fn -> {:conn, T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), a.at, body: %{"msgtype" => "m.text", "body" => "a2"})} end,
            fn -> {:conn, T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), a.at, body: %{"msgtype" => "m.text", "body" => "a3"})} end,
            fn -> {:conn, put_state(a, room, "m.room.topic", %{"topic" => "t#{round}"})} end,
            fn -> {:conn, kick(a, room, c)} end,
            fn -> {:conn, leave(b, room)} end,
            fn -> {:direct, DB.insert_event(direct)} end
          ])

        for result <- results do
          case result do
            {:conn, conn} -> assert conn.status == 200, "round #{round}: #{conn.status} #{String.slice(conn.resp_body, 0, 160)}"
            {:direct, answer} -> assert answer == :ok
          end
        end

        stamped = assert_stamped!(room, "round #{round} after")
        assert length(stamped) == before + 7, "round #{round}: each of the 7 writers wrote exactly one event"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # D7 / D8: no read, no response shows a position
  # ═══════════════════════════════════════════════════════════════════════════════

  describe "no response shows a position (D7, D8)" do
    test "/messages, /event and the initial /sync of a room with stamped events never contain room_pos or event_pos", %{a: a} do
      room = public_room(a)
      id = say!(a, room, "visible")
      assert_stamped!(room, "the room")

      bodies = [
        T.matrix_request(:get, path(room, "messages") <> "?dir=b&limit=50", a.at).resp_body,
        T.matrix_request(:get, path(room, "event/#{enc(id)}"), a.at).resp_body,
        sync_conn(a, since: nil, timeout: 0).resp_body
      ]

      for body <- bodies do
        assert body =~ id or body =~ room, "the read answered something real"
        refute body =~ "room_pos"
        refute body =~ "event_pos"
      end
    end
  end
end
