defmodule Nebu.Matrix.HttpPrevContentTest do
  @moduledoc """
  Story `member-event-prev-content` (epic oauth-broker, follow-up `ff`), AC3 (D1, D2, D7, D10): the renderers of `Nebu.Matrix.Http` emit the
  THREE predecessor keys of a state event, `unsigned.replaces_state`, `unsigned.prev_content` and `unsigned.prev_sender`, through ONE rule:

    * they are added only when the event is a state event (`is_state_event: true`; a `Core.SyncRoomStateEvent` always is one) AND
      `replaces_state` is a non-empty binary AND `prev_content` is a non-empty binary that decodes to a JSON OBJECT AND `prev_sender` is a
      non-empty binary; otherwise NONE of the three (an inconsistent struct never produces a partial triple, never `null`);
    * `prev_content` is rendered as the decoded object (`"{}"` is an object: a predecessor with an empty content DOES carry `{}`);
    * the same rule holds for the timeline events of `rooms.join` and of `rooms.leave` (`timeline_event_json/2`), the state block of
      `rooms.join` (`build_joined_rooms/2`) and `Http.message_event/1` (`/messages`, `/event`, `/relations`);
    * `age` is rendered exactly where it is rendered today (timeline events, state entries WITH an identity); `message_event/1` has no `age`
      and no `unsigned` key at all without a predecessor;
    * `rooms.invite` stripped events (D7) stay exactly `type`, `state_key`, `sender`, `content`.

  The wire fields (D10): `Core.Event` and `Core.SyncRoomStateEvent` get `prev_content: ""` (the predecessor's content as JSON text, `""` =
  none) and `prev_sender: ""`. The structs are built with `struct!/2` so that the not-yet-existing fields fail the TESTS (KeyError), never
  the compile of the whole run.

  Ambiguity decided here (D10 lists `replaces_state` and `prev_content` only, D1 says "always together, never one without the others"): an
  EMPTY or `nil` `prev_sender` also yields none of the three keys (never `"prev_sender" => ""`).

  Pure unit, no database, `async: true`.
  """
  use ExUnit.Case, async: true

  alias Nebu.Matrix.Http

  @user_b "@b:test.local"
  @user_a "@a:test.local"
  @room "!r:test.local"
  @invite_json ~s({"membership":"invite","is_direct":true})
  @triple_keys ["prev_content", "prev_sender", "replaces_state"]

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp now_ms, do: System.system_time(:millisecond)

  defp core_event(overrides) do
    struct!(
      Core.Event,
      Keyword.merge(
        [
          event_id: "$join:test.local",
          room_id: @room,
          sender_id: @user_b,
          event_type: "m.room.member",
          content: ~s({"membership":"join"}),
          origin_ts: now_ms() - 5_000,
          state_key: @user_b,
          is_state_event: true,
          replaces_state: "$invite:test.local",
          prev_content: @invite_json,
          prev_sender: @user_a
        ],
        overrides
      )
    )
  end

  defp state_entry(overrides) do
    struct!(
      Core.SyncRoomStateEvent,
      Keyword.merge(
        [
          type: "m.room.member",
          state_key: @user_b,
          content: ~s({"membership":"join"}),
          sender: @user_b,
          event_id: "$join:test.local",
          origin_server_ts: now_ms() - 5_000,
          replaces_state: "$invite:test.local",
          prev_content: @invite_json,
          prev_sender: @user_a
        ],
        overrides
      )
    )
  end

  # the four renderers of an event: the JSON map of ONE event
  defp render(:timeline, overrides) do
    room = %Core.SyncRoom{room_id: @room, timeline_events: [core_event(overrides)]}
    body = Http.sync_response("s1", [room])
    [event] = get_in(body, ["rooms", "join", @room, "timeline", "events"])
    event
  end

  defp render(:leave_timeline, overrides) do
    room = %Core.SyncRoom{room_id: @room, timeline_events: [core_event(overrides)], limited: false, prev_batch: ""}
    body = Http.sync_response("s1", [], %{}, [], [room])
    [event] = get_in(body, ["rooms", "leave", @room, "timeline", "events"])
    event
  end

  defp render(:state, overrides) do
    room = %Core.SyncRoom{room_id: @room, state_events: [state_entry(overrides)]}
    body = Http.sync_response("s1", [room])
    [event] = get_in(body, ["rooms", "join", @room, "state", "events"])
    event
  end

  defp render(:message, overrides), do: Http.message_event(core_event(overrides))

  # where `age` is rendered today: every renderer but message_event/1 (a boolean comparison, not a function of the literal `kind`: the Elixir 1.20
  # type checker flags a clause / conditional that is constant for the `unquote`d kind of one generated test)
  defp age_rendered?(kind), do: kind != :message

  defp triple(event), do: Map.take(event["unsigned"] || %{}, @triple_keys)

  @renderers [:timeline, :leave_timeline, :state, :message]
  # renderers whose input is a Core.Event (is_state_event applies)
  @event_renderers [:timeline, :leave_timeline, :message]

  # ═══ D10: the struct defaults ═══════════════════════════════════════════════════

  describe "D10 - the wire fields default to \"\" (no predecessor)" do
    test "Core.Event and Core.SyncRoomStateEvent have prev_content and prev_sender, both \"\" by default (like replaces_state)" do
      # Map.fetch!/2, not a struct literal with the key: the missing field fails the test, never the compile of the run
      for struct <- [%Core.Event{}, %Core.SyncRoomStateEvent{}], field <- [:replaces_state, :prev_content, :prev_sender] do
        assert Map.fetch!(struct, field) == "", "#{inspect(struct.__struct__)}.#{field} defaults to \"\""
      end
    end
  end

  # ═══ (a) the three keys ═══════════════════════════════════════════════════════

  describe "AC3 (a) - replaces_state + prev_content + prev_sender are rendered together" do
    for kind <- @renderers do
      test "#{kind}: unsigned has the three keys, prev_content a decoded object (and age exactly where it is rendered today)" do
        kind = unquote(kind)
        event = render(kind, [])

        assert triple(event) == %{
                 "replaces_state" => "$invite:test.local",
                 "prev_content" => %{"membership" => "invite", "is_direct" => true},
                 "prev_sender" => @user_a
               }

        expected_keys = if age_rendered?(kind), do: ["age" | @triple_keys], else: @triple_keys
        assert Enum.sort(Map.keys(event["unsigned"])) == Enum.sort(expected_keys), "unsigned has exactly #{inspect(expected_keys)}"

        if age_rendered?(kind), do: assert(is_integer(event["unsigned"]["age"]) and event["unsigned"]["age"] >= 1)
      end
    end

    test "prev_content keeps arbitrary nested content (a topic) as a decoded object, not as JSON text" do
      event = render(:message, event_type: "m.room.topic", state_key: "", prev_content: ~s({"topic":"before","nested":{"a":[1,2]}}))

      assert event["unsigned"]["prev_content"] == %{"topic" => "before", "nested" => %{"a" => [1, 2]}}
    end
  end

  # ═══ (b) no predecessor ═══════════════════════════════════════════════════════

  describe "AC3 (b) - all three empty: none of the three keys" do
    for kind <- @renderers do
      test "#{kind}: replaces_state, prev_content and prev_sender are \"\" -> no predecessor key, unsigned unchanged from today" do
        kind = unquote(kind)
        event = render(kind, replaces_state: "", prev_content: "", prev_sender: "")

        if not age_rendered?(kind) do
          refute Map.has_key?(event, "unsigned"), "message_event/1 without a predecessor has no unsigned key at all"
        else
          assert Map.keys(event["unsigned"]) == ["age"], "unsigned is exactly %{\"age\" => _}, got #{inspect(event["unsigned"])}"
        end
      end
    end
  end

  # ═══ (c) an empty predecessor content ═════════════════════════════════════════

  describe "AC3 (c) - prev_content \"{}\"" do
    for kind <- @renderers do
      test "#{kind}: a predecessor whose content is {} IS rendered as \"prev_content\" => %{} (absent means 'no predecessor', nothing else)" do
        event = render(unquote(kind), prev_content: "{}")

        assert event["unsigned"]["prev_content"] == %{}
        assert Map.has_key?(event["unsigned"], "replaces_state") and Map.has_key?(event["unsigned"], "prev_sender")
      end
    end
  end

  # ═══ (d) inconsistent structs ═════════════════════════════════════════════════

  describe "AC3 (d) - an inconsistent struct never produces a partial triple, never null" do
    inconsistent = [
      {"replaces_state set, prev_content empty", [prev_content: ""]},
      {"replaces_state empty, prev_content and prev_sender set", [replaces_state: ""]},
      {"prev_content is a JSON array", [prev_content: "[1,2]"]},
      {"prev_content is a JSON string", [prev_content: ~s("text")]},
      {"prev_content is JSON null", [prev_content: "null"]},
      {"prev_content is a number", [prev_content: "42"]},
      {"prev_content is not JSON at all", [prev_content: "this is not json {"]},
      {"prev_sender is empty", [prev_sender: ""]},
      {"replaces_state is nil", [replaces_state: nil]},
      {"prev_content is nil", [prev_content: nil]},
      {"prev_sender is nil", [prev_sender: nil]}
    ]

    for kind <- @renderers, {label, overrides} <- inconsistent do
      test "#{kind}: #{label} -> none of the three keys" do
        event = render(unquote(kind), unquote(Macro.escape(overrides)))
        unsigned = event["unsigned"] || %{}

        for key <- @triple_keys, do: refute(Map.has_key?(unsigned, key), "#{key} must be absent, got #{inspect(unsigned)}")
        refute Enum.any?(Map.values(unsigned), &is_nil/1), "never a JSON null in unsigned"
      end
    end
  end

  # ═══ (e) non-state events ═════════════════════════════════════════════════════

  describe "AC3 (e) - a non-state event never carries the keys, even when the fields are set" do
    for kind <- @event_renderers do
      test "#{kind}: is_state_event false with all three fields set -> none of the three keys, no state_key" do
        event = render(unquote(kind), event_type: "m.room.message", state_key: "", is_state_event: false, content: ~s({"msgtype":"m.text","body":"hi"}))
        unsigned = event["unsigned"] || %{}

        for key <- @triple_keys, do: refute(Map.has_key?(unsigned, key), "a message must not carry #{key}")
        refute Map.has_key?(event, "state_key")
      end
    end
  end

  # ═══ state entries without identity ═══════════════════════════════════════════

  describe "D2 - a state entry without a real event identity" do
    test "event_id \"\" (legacy / failed event write): no unsigned at all, even when the three fields are set" do
      event = render(:state, event_id: "", origin_server_ts: 0)

      refute Map.has_key?(event, "unsigned"), "no identity, no age, no predecessor keys"
    end
  end

  # ═══ (f) stripped state ═══════════════════════════════════════════════════════

  describe "AC3 (f) / D7 - rooms.invite stripped events" do
    test "stay exactly type, state_key, sender, content (no unsigned, no event_id), also when the source struct HAS predecessor fields" do
      plain = %Core.StrippedStateEvent{type: "m.room.member", state_key: @user_b, sender: @user_a, content: @invite_json}

      # a struct that carries the fields of a state event on top (a future change of the struct must not leak them into the stripped event)
      with_extras =
        Map.merge(plain, %{prev_content: @invite_json, prev_sender: @user_a, replaces_state: "$x:test.local", event_id: "$y:test.local", unsigned: %{"age" => 1}})

      room = %Core.SyncInviteRoom{room_id: @room, invite_state: [plain, with_extras]}
      body = Http.sync_response("s1", [], %{}, [room], [])

      events = get_in(body, ["rooms", "invite", @room, "invite_state", "events"])
      assert length(events) == 2

      for event <- events do
        assert Enum.sort(Map.keys(event)) == ["content", "sender", "state_key", "type"]
        assert event["content"] == %{"membership" => "invite", "is_direct" => true}
      end
    end
  end
end
