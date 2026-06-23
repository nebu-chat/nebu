defmodule Nebu.Matrix.HttpStateKeyTest do
  @moduledoc """
  RETROACTIVE regression test for the membership-visibility fix.

  `Nebu.Matrix.Http.message_event/1` serialises a `Core.Event` into the Matrix
  timeline-event JSON shape used by `/messages`, `/sync` and `/initialSync`.

  A STATE event (m.room.member, m.room.create, m.room.name, …) MUST carry its
  `state_key` — Matrix clients key state off the `(type, state_key)` pair. For
  m.room.member the state_key is the target user; without it Element cannot tell
  that a user joined and stays stuck on the "Joining…" spinner.

  A non-state (message) event has no state_key (empty string in the proto), and
  the serialised map MUST NOT contain a `state_key` key at all — emitting an
  empty `state_key` would make a plain message look like a state event.

  Pure unit test: `message_event/1` is a public, side-effect-free mapper, so this
  runs in the DB-less container under `--warnings-as-errors`.
  """

  use ExUnit.Case, async: true

  alias Nebu.Matrix.Http

  test "a state event (m.room.member) serialises WITH its state_key" do
    event = %Core.Event{
      event_id: "$evt:test.local",
      room_id: "!room:test.local",
      sender_id: "@kai:test.local",
      event_type: "m.room.member",
      state_key: "@x:localhost",
      content: Jason.encode!(%{"membership" => "join"}),
      origin_ts: 1_700_000_000_000
    }

    map = Http.message_event(event)

    assert map["state_key"] == "@x:localhost"
    assert map["type"] == "m.room.member"
    assert map["event_id"] == "$evt:test.local"
  end

  test "a non-state (message) event with empty state_key serialises WITHOUT a state_key key" do
    event = %Core.Event{
      event_id: "$msg:test.local",
      room_id: "!room:test.local",
      sender_id: "@kai:test.local",
      event_type: "m.room.message",
      state_key: "",
      content: Jason.encode!(%{"msgtype" => "m.text", "body" => "hello"}),
      origin_ts: 1_700_000_000_000
    }

    map = Http.message_event(event)

    refute Map.has_key?(map, "state_key"),
           "a message event must not carry a (empty) state_key — that would make it look like state"
  end
end
