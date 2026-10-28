defmodule Nebu.Matrix.InviteStateBudgetTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room`, review cycle 1 (Kassandra M-2): the byte budget of the `rooms.invite` section of ONE
  `/sync` response (unit, no DB): `Nebu.Matrix.EventDispatcher.Server.limit_invite_state/3`.

  The count of pending invitations is capped (100 per invitee) but the stripped state of one invitation is attacker-written (name,
  topic, avatar, join rules, alias, encryption; bounded only by the 1 MB request body when this budget was written; since story event-size-limit the
  64 KiB event limit holds for new rows and this budget is defence in depth for rows written before it).
  The budget drops ONLY optional stripped events, NEVER an invitation and never the `m.room.create` or a member event:

    1. an optional event whose content is larger than `max_event_bytes` is dropped;
    2. while the response total exceeds `budget`, the optional events of one type at a time are dropped, largest first, in the order
       topic, avatar, canonical alias, encryption, join rules, name.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server

  defp event(type, bytes, state_key \\ ""),
    do: %Core.StrippedStateEvent{type: type, state_key: state_key, sender: "@a:test.local", content: String.duplicate("x", bytes)}

  defp room(id, events), do: %Core.SyncInviteRoom{room_id: id, invite_state: events}
  defp types(room), do: Enum.map(room.invite_state, & &1.type)

  defp full_room(id, sizes) do
    room(
      id,
      [
        event("m.room.create", sizes[:create] || 10),
        event("m.room.name", sizes[:name] || 10),
        event("m.room.avatar", sizes[:avatar] || 10),
        event("m.room.topic", sizes[:topic] || 10),
        event("m.room.join_rules", sizes[:join_rules] || 10),
        event("m.room.member", 10, "@inviter:test.local"),
        event("m.room.member", 10, "@me:test.local")
      ]
    )
  end

  describe "per event: an optional event above the limit is dropped" do
    test "a topic and an avatar above max_event_bytes are dropped, the rest of the room (and every other room) is untouched" do
      big = full_room("!big:test.local", topic: 101, avatar: 101)
      small = full_room("!small:test.local", topic: 100, avatar: 100)

      log = capture_log(fn -> send(self(), {:out, Server.limit_invite_state([big, small], 100, 1_000_000)}) end)
      assert_received {:out, [limited_big, limited_small]}

      assert types(limited_big) == ~w(m.room.create m.room.name m.room.join_rules m.room.member m.room.member)
      assert limited_small == small, "exactly at the limit is kept"
      assert log =~ "dropped 2 optional"
      refute log =~ "big:test.local", "the log names no room id"
    end

    test "the create event and the member events are NEVER dropped, however large; an invitation is never removed" do
      huge_create = room("!r:test.local", [event("m.room.create", 500), event("m.room.member", 500, "@me:test.local")])
      assert [limited] = Server.limit_invite_state([huge_create], 100, 10)
      assert limited == huge_create
    end

    test "default limits: a 64 KiB topic stays, a 64 KiB + 1 topic goes" do
      stay = room("!a:test.local", [event("m.room.create", 5), event("m.room.topic", 65_536), event("m.room.member", 5, "@me:test.local")])
      go = room("!b:test.local", [event("m.room.create", 5), event("m.room.topic", 65_537), event("m.room.member", 5, "@me:test.local")])

      assert [^stay, limited] = Server.limit_invite_state([stay, go])
      assert types(limited) == ~w(m.room.create m.room.member)
    end
  end

  describe "per response: the total budget" do
    test "under the budget nothing is dropped (positive control: the same rooms with a smaller budget lose events)" do
      rooms = for n <- 1..3, do: full_room("!r#{n}:test.local", topic: 1_000, avatar: 1_000)
      assert Server.limit_invite_state(rooms, 10_000, 100_000) == rooms
      assert Server.limit_invite_state(rooms, 10_000, 1_000) != rooms
    end

    test "over the budget the topics go first (largest first, only as many as needed), then avatars; names and the invitation stay" do
      rooms = [
        full_room("!r1:test.local", topic: 1_000, avatar: 500),
        full_room("!r2:test.local", topic: 3_000, avatar: 500),
        full_room("!r3:test.local", topic: 2_000, avatar: 500)
      ]

      total = rooms |> Enum.flat_map(& &1.invite_state) |> Enum.map(&byte_size(&1.content)) |> Enum.sum()

      # one topic too many: the LARGEST topic (r2) goes, nothing else
      assert [r1, r2, r3] = Server.limit_invite_state(rooms, 10_000, total - 1)
      assert "m.room.topic" in types(r1) and "m.room.topic" in types(r3)
      refute "m.room.topic" in types(r2)
      assert "m.room.avatar" in types(r2)

      # all topics (6 000) are not enough: the avatars (3 x 500) go as well, and not before they are needed
      assert [r1, r2, r3] = Server.limit_invite_state(rooms, 10_000, total - 6_000 - 1_500)

      for r <- [r1, r2, r3] do
        refute "m.room.topic" in types(r)
        refute "m.room.avatar" in types(r)
        assert "m.room.name" in types(r) and "m.room.create" in types(r)
        assert Enum.count(r.invite_state, &(&1.type == "m.room.member")) == 2, "the invitation (both member events) is never dropped"
      end
    end

    test "an impossible budget (smaller than the mandatory events) drops every optional event and still keeps every invitation" do
      rooms = for n <- 1..5, do: full_room("!r#{n}:test.local", topic: 100, avatar: 100, name: 100, join_rules: 100)
      limited = Server.limit_invite_state(rooms, 10_000, 1)

      assert length(limited) == 5
      for r <- limited, do: assert(types(r) == ~w(m.room.create m.room.member m.room.member))
    end
  end

  test "an empty section and rooms without optional events pass through" do
    assert Server.limit_invite_state([]) == []
    bare = room("!r:test.local", [event("m.room.create", 5), event("m.room.member", 5, "@me:test.local")])
    assert Server.limit_invite_state([bare], 1, 1) == [bare]
  end
end
