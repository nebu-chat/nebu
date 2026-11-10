defmodule Nebu.Matrix.ModerationTickTest do
  @moduledoc """
  Regression test of bugfix `integration-test-flakes-fix` (C): `ModerationTestSupport.tick/0` waits until the wall clock is past the newest
  event of the last seconds (`Room.Server` stamps member events `max(now, not_before, latest + 1)`, so bursts run the stamp AHEAD of the clock).

  The old wait was 300 rounds of a 1 ms sleep (about 0.3 to 0.6 s, longer under load) and returned `:timeout`, which every caller matched as
  `:ok = tick()` -> `MatchError` in about a dozen suites under full-run load. `tick/0` now waits on a wall-clock budget (default 10 s) and
  flunks with the gap in milliseconds.

  The test writes an event stamped 1.2 s ahead of the clock (a burst of a concurrent writer), which the old wait could never outlast.
  Real database; the fixture event is deleted again (privileged role: the runtime role cannot DELETE events).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Matrix.ModerationTestSupport, as: M
  alias Nebu.OAuth.TestSupport, as: T

  # an event `ahead_ms` in the future in a room of its own
  defp future_event!(ahead_ms) do
    room = "!tick-#{T.rand(8)}:#{T.server_name()}"
    {:ok, _} = Nebu.Matrix.Room.DB.insert_room(room)
    ts = System.system_time(:millisecond) + ahead_ms

    T.privileged_sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, '@tick:test.local', 'm.room.message', '{}'::jsonb, $3, NULL)",
      ["$tick" <> T.rand(10), room, ts]
    )

    on_exit(fn -> T.privileged_sql!("DELETE FROM events WHERE room_id = $1", [room]) end)
    ts
  end

  test "tick/0 outlasts an event stamped 1.2 s ahead of the clock and returns :ok only once the clock is past it" do
    ts = future_event!(1_200)

    assert M.tick() == :ok
    assert System.system_time(:millisecond) > ts, "tick/0 must not return before the wall clock is past the newest event"
  end

  test "tick/0 gives up after its budget with a failure that names the gap, never with :timeout" do
    future_event!(30_000)

    error = assert_raise ExUnit.AssertionError, fn -> M.tick(200) end
    assert error.message =~ ~r/still \d+ ms behind the newest event after 200 ms/
  end
end
