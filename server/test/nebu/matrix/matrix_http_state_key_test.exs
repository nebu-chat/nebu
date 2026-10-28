defmodule Nebu.Matrix.HttpStateKeyTest do
  @moduledoc """
  RETROACTIVE regression test for the membership-visibility fix, extended by
  the unsigned-replaces-state bugfix (code-review cycle 1, MAJOR-2 + MINOR-8).

  `Nebu.Matrix.Http.message_event/1` serialises a `Core.Event` into the Matrix
  timeline-event JSON shape used by `/messages`, `/sync` and `/initialSync`.

  A STATE event (m.room.member, m.room.create, m.room.name, …) MUST carry its
  `state_key` — Matrix clients key state off the `(type, state_key)` pair. For
  m.room.member the state_key is the target user; without it Element cannot tell
  that a user joined and stays stuck on the "Joining…" spinner.

  This now includes genuine state events whose real `state_key` IS the empty
  string (m.room.name/topic/power_levels/create) — `state_key: ""` MUST still
  be emitted for those (spec-correct, Matrix CS API). Only a TRUE non-state
  event (a plain m.room.message, where `state_key` is absent at the DB layer,
  not merely empty) must have NO `state_key` key at all. `Core.Event.is_state_event`
  is the authoritative signal `put_state_key/2` uses to tell these apart —
  never the `state_key` VALUE alone, which collapses both cases to "".

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
      is_state_event: true,
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
      is_state_event: false,
      content: Jason.encode!(%{"msgtype" => "m.text", "body" => "hello"}),
      origin_ts: 1_700_000_000_000
    }

    map = Http.message_event(event)

    refute Map.has_key?(map, "state_key"),
           "a message event must not carry a (empty) state_key — that would make it look like state"
  end

  # ── Bugfix unsigned-replaces-state, code-review cycle 1 (MAJOR-2 + MINOR-8) ──

  test "a genuine state event with an EMPTY state_key (e.g. m.room.topic) still serialises WITH state_key, plus replaces_state (MAJOR-2)" do
    # story member-event-prev-content (DELIBERATE re-pin; old -> new): `unsigned.replaces_state` is rendered together with `prev_content` and
    # `prev_sender` (one consistent triple, D10: a struct with `replaces_state` alone yields none of the three). `struct!/2` so that the
    # not-yet-existing fields fail THIS test instead of aborting the compile of the whole run.
    event =
      struct!(Core.Event,
        event_id: "$topic2:test.local",
        room_id: "!room:test.local",
        sender_id: "@kai:test.local",
        event_type: "m.room.topic",
        state_key: "",
        is_state_event: true,
        content: Jason.encode!(%{"topic" => "v2"}),
        origin_ts: 1_700_000_000_000,
        replaces_state: "$topic1:test.local",
        prev_content: Jason.encode!(%{"topic" => "v1"}),
        prev_sender: "@kai:test.local"
      )

    map = Http.message_event(event)

    assert map["state_key"] == "",
           "a genuine state event with an empty state_key (m.room.topic/name/power_levels/create) " <>
             "must still carry state_key: \"\" — omitting it would make it indistinguishable from " <>
             "a plain message (bugfix unsigned-replaces-state, MAJOR-2), got: #{inspect(map)}"

    assert map["unsigned"]["replaces_state"] == "$topic1:test.local",
           "must carry unsigned.replaces_state consistently alongside state_key being present " <>
             "(no more self-contradicting output), got: #{inspect(map["unsigned"])}"
  end

  test "a genuine state event (m.room.create) with no predecessor omits unsigned entirely (AC3, pure-unit coverage, MINOR-8)" do
    event = %Core.Event{
      event_id: "$create:test.local",
      room_id: "!room:test.local",
      sender_id: "@kai:test.local",
      event_type: "m.room.create",
      state_key: "",
      is_state_event: true,
      content: Jason.encode!(%{"creator" => "@kai:test.local"}),
      origin_ts: 1_700_000_000_000,
      replaces_state: ""
    }

    map = Http.message_event(event)

    assert map["state_key"] == ""

    refute Map.has_key?(map, "unsigned"),
           "no predecessor exists at this slot — unsigned must be absent entirely (AC3), " <>
             "never an empty map or a sentinel null, got: #{inspect(map)}"
  end

  # ── Code-review cycle 2 (MINOR): put_state_key/2 total-function catch-all ──

  test "an event with an unexpected is_state_event value degrades safely (no state_key), does not raise" do
    # `Core.Event.is_state_event` is typed `bool` by the proto and is always
    # `true`/`false` on every value this struct is actually constructed with
    # in application code — but Elixir does not enforce that at the struct
    # level, so a malformed/unexpected value here (e.g. from a future proto
    # change, or a hand-built fixture elsewhere) is still structurally
    # possible. Before this fix, `put_state_key/2` had exactly two clauses
    # (`%{is_state_event: true, ...}` / `%{is_state_event: false}`) and NO
    # catch-all, so this would raise FunctionClauseError (-> HTTP 500) instead
    # of degrading. The restored final clause (`put_state_key(map, _), do:
    # map`) makes it total again: anything that doesn't match the two known
    # cases just omits state_key, exactly like a non-state event would.
    event = %Core.Event{
      event_id: "$weird:test.local",
      room_id: "!room:test.local",
      sender_id: "@kai:test.local",
      event_type: "m.weird.type",
      state_key: "",
      is_state_event: nil,
      content: Jason.encode!(%{}),
      origin_ts: 1_700_000_000_000
    }

    map = Http.message_event(event)

    refute Map.has_key?(map, "state_key"),
           "an unrecognized is_state_event value must fall through the catch-all clause (no " <>
             "state_key), not raise FunctionClauseError, got: #{inspect(map)}"
  end
end
