defmodule Nebu.Web.LogStore.WarRoomTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-mode` (AC4/AC5/AC9 —
  the `Nebu.Web.LogStore.WarRoom` GenServer's scope/filter matching, budget
  enforcement, and duration-timer auto-termination).

  Story: docs/stories/enhanced-logging/war-room-mode.md
  Design decisions (read FIRST — resolves every naming/architecture mismatch
  between the story's own literal text and the real, already-shipped
  operational-log-store/admin-logs-monitoring-view code this story integrates
  with):
  _bmad-output/nebu/epics/enhanced-logging/step-results/war-room-mode/design-decisions.md

  ## Why these MUST FAIL right now

  Neither `Nebu.Web.LogStore.WarRoom` (server/lib/nebu/web/log_store/war_room.ex)
  nor the `war_room_sessions` table exist yet. Every test below fails either
  with `UndefinedFunctionError` (the module — and therefore
  `start_supervised!/1` — has nothing to resolve) or a Postgres
  `relation "war_room_sessions" does not exist` error once/if a partial
  implementation adds the module but not the migration.

  ## Why every test here is tagged `:integration`, despite AT2/AT10's literal
  "ExUnit :unit" framing in the story's own Acceptance Tests section

  Per design-decisions.md #4, `WarRoom` owns its own inline SQL for the
  load/increment/timeout paths directly against `war_room_sessions` — there
  is no in-memory-only code path to unit-test in isolation from a live
  Postgres; even the "check/1 is cheap when inactive" perf-shape assertion
  below needs a live `Nebu.Repo` connection to start the GenServer's `init/1`
  (which calls `load_active/0`, a DB read). This mirrors
  `writer_test.exs`'s/`handler_test.exs`'s own precedent of tagging every
  DB-touching GenServer test `:integration` regardless of what the story's
  own Acceptance Tests section originally labeled them (the sibling stories'
  design-decisions.md files made the same kind of literal-AC-framing
  adjustment).

  ## Entry shape fed to `check/1`

  Mirrors `Nebu.Web.LogStore.Handler.parse_log_event/1`'s output exactly:
  atom keys `:level`, `:source`, `:route_template`, `:request_id`,
  `:message`, `:metadata` — where `:metadata` is a map with STRING keys
  (`"user_id"`/`"device_id"`), matching `Handler.safe_metadata/1`'s
  string-key coercion (see design-decisions.md #5 for why `user_id`/
  `device_id` land there via `Logger.metadata/1` in `RequestLogger`, and the
  Oracle gate note that `device_id` matching MUST be opaque/case-sensitive —
  never lowercased).

  ## JSONB `filter` param convention

  Per `Nebu.Matrix.Room.Db.insert_event/1`'s own documented convention ("Pass
  maps directly to Postgrex — Ecto+Postgrex encodes Elixir maps as JSONB
  objects. Pre-encoding to a JSON string then passing to Postgrex causes
  double-encoding"), this file passes the `filter` map DIRECTLY as a raw
  Elixir map query parameter — never `Jason.encode!/1`-ed first.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    pid =
      case Process.whereis(Nebu.Web.LogStore.WarRoom) do
        nil -> start_supervised!(Nebu.Web.LogStore.WarRoom)
        existing -> existing
      end

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-war-room-test-%'",
          []
        )
      end
    end)

    {:ok, war_room: pid}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp run_id, do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"

  defp insert_session(overrides) do
    defaults = %{
      started_by: "distinctive-war-room-test-#{run_id()}",
      reason: "test reason",
      scope: nil,
      filter: nil,
      max_entries: 1000,
      max_duration_s: 300,
      started_at: DateTime.utc_now(),
      entries_collected: 0
    }

    attrs = Map.merge(defaults, Map.new(overrides))

    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO war_room_sessions
          (started_by, reason, scope, filter, max_entries, max_duration_s, started_at, entries_collected)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id
        """,
        [
          attrs.started_by,
          attrs.reason,
          attrs.scope,
          attrs.filter,
          attrs.max_entries,
          attrs.max_duration_s,
          attrs.started_at,
          attrs.entries_collected
        ]
      )

    [[id]] = result.rows
    id
  end

  defp session_row(id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "SELECT ended_at, ended_reason, entries_collected FROM war_room_sessions WHERE id = $1",
        [id]
      )

    [[ended_at, ended_reason, entries_collected]] = result.rows
    %{ended_at: ended_at, ended_reason: ended_reason, entries_collected: entries_collected}
  end

  defp log_entry(overrides) do
    Map.merge(
      %{
        level: "debug",
        source: "http",
        route_template: "/_matrix/client/v3/sync",
        request_id: "req-#{System.unique_integer([:positive])}",
        message: "distinctive-war-room-test-entry",
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  # Forces the GenServer to (re)load the single active session from the DB —
  # exactly what `Nebu.Admin.WarRoomManager.start_session/1`/`stop_session/1`
  # are designed to trigger after every write (design-decisions.md #4), and
  # what `init/1` does once at boot. Using it directly here decouples these
  # low-level WarRoom tests from `WarRoomManager` (covered separately in
  # `test/nebu/admin/war_room_manager_test.exs`).
  defp load!(war_room) do
    :ok = Nebu.Web.LogStore.WarRoom.load_active()
    :sys.get_state(war_room)
    :ok
  end

  # Ends every currently-active session (AC2 guarantees at most one such row
  # exists at all) so a test's "nothing active yet" precondition holds
  # regardless of test execution order — mirrors the identical defensive
  # reset already used by the "check/1 is cheap" describe block below and by
  # war_room_manager_test.exs's `end_all_active!/0`.
  defp end_all_active! do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
      []
    )
  end

  # Polls `Process.whereis/1` until it returns a pid different from
  # `old_pid` (the supervisor has finished restarting the child), or fails.
  # Copied verbatim from writer_test.exs's own "AC6: writer crash/restart via
  # supervisor" helper — same mechanism, same registered-name-based restart
  # contract (design-decisions.md #4: WarRoom is supervised alongside
  # Writer/PolicyCache in `Nebu.Application.repo_children/0`).
  defp wait_until_registered(name, old_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_registered(name, old_pid, deadline)
  end

  defp do_wait_until_registered(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{inspect(name)} to be restarted under a new pid")
        else
          Process.sleep(100)
          do_wait_until_registered(name, old_pid, deadline)
        end
    end
  end

  # Polls `war_room_sessions` until `id`'s row has `ended_at` set, or fails.
  # Deliberately does NOT call `load_active/0`/`load!/1` itself — the whole
  # point of the crash/restart test below is to prove the RESTARTED
  # process's own `init/1` reaches this state on its own.
  defp wait_until_ended(id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_ended(id, deadline)
  end

  defp do_wait_until_ended(id, deadline) do
    row = session_row(id)

    cond do
      not is_nil(row.ended_at) ->
        row

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for war_room_sessions #{id} to be ended")

      true ->
        Process.sleep(100)
        do_wait_until_ended(id, deadline)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Scope matching (AC3/AC4/AC8-AC9)
  # ══════════════════════════════════════════════════════════════════════════

  describe "scope matching" do
    test "scope=nil matches any route_template", %{war_room: wr} do
      id = insert_session(scope: nil)
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/rooms/:room_id/messages")
             ) == id

      assert session_row(id).entries_collected == 1
    end

    test "scope=\"all\" matches any route_template", %{war_room: wr} do
      id = insert_session(scope: "all")
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(log_entry(route_template: "/anything/at/all")) == id
    end

    test "scope set to an exact route_template matches only that exact route", %{war_room: wr} do
      id = insert_session(scope: "/_matrix/client/v3/sync")
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/sync")
             ) == id
    end

    test "scope set to a specific route does NOT match a different route", %{war_room: wr} do
      id = insert_session(scope: "/_matrix/client/v3/sync")
      load!(wr)

      refute Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/profile/:user_id")
             )

      assert session_row(id).entries_collected == 0,
             "a non-matching entry must never increment entries_collected"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Filter matching — AC9's AND semantics across user_id + device_id
  # ══════════════════════════════════════════════════════════════════════════

  describe "filter matching (AC9) — AND semantics" do
    test "an entry matching both user_id and device_id is tagged", %{war_room: wr} do
      id = insert_session(filter: %{"user_id" => "@alice:localhost", "device_id" => "DEVICE1"})
      load!(wr)

      entry = log_entry(metadata: %{"user_id" => "@alice:localhost", "device_id" => "DEVICE1"})
      assert Nebu.Web.LogStore.WarRoom.check(entry) == id
    end

    test "an entry with matching user_id but a DIFFERENT device_id is NOT tagged (AND, not OR)",
         %{war_room: wr} do
      id = insert_session(filter: %{"user_id" => "@alice:localhost", "device_id" => "DEVICE1"})
      load!(wr)

      entry = log_entry(metadata: %{"user_id" => "@alice:localhost", "device_id" => "DEVICE2"})
      refute Nebu.Web.LogStore.WarRoom.check(entry)
      assert session_row(id).entries_collected == 0
    end

    test "an entry missing device_id entirely is NOT tagged when the filter requires it",
         %{war_room: wr} do
      insert_session(filter: %{"user_id" => "@alice:localhost", "device_id" => "DEVICE1"})
      load!(wr)

      entry = log_entry(metadata: %{"user_id" => "@alice:localhost"})
      refute Nebu.Web.LogStore.WarRoom.check(entry),
             "a filter is only satisfied when ALL its fields are present AND equal — never by a" <>
               " nil vs. a required value"
    end

    test "device_id filter matching is opaque and case-sensitive (Oracle gate) — never lowercased",
         %{war_room: wr} do
      id = insert_session(filter: %{"device_id" => "GHTYAJSQZD"})
      load!(wr)

      refute Nebu.Web.LogStore.WarRoom.check(log_entry(metadata: %{"device_id" => "ghtyajsqzd"})),
             "device_id matching must be an exact, case-sensitive match — never case-folded"

      assert Nebu.Web.LogStore.WarRoom.check(log_entry(metadata: %{"device_id" => "GHTYAJSQZD"})) ==
               id
    end

    test "filter=nil matches every entry regardless of metadata (no additional filtering)",
         %{war_room: wr} do
      id = insert_session(filter: nil, scope: "all")
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(log_entry(metadata: %{})) == id
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Budget enforcement (AC4, AT9) — auto-terminate at max_entries
  # ══════════════════════════════════════════════════════════════════════════

  describe "budget enforcement — auto-terminate when entries_collected reaches max_entries" do
    test "the entry reaching max_entries is tagged and ends the session; the next entry is not tagged",
         %{war_room: wr} do
      id = insert_session(max_entries: 5, scope: "all")
      load!(wr)

      for _ <- 1..4 do
        assert Nebu.Web.LogStore.WarRoom.check(log_entry([])) == id
      end

      row = session_row(id)
      assert row.entries_collected == 4
      assert is_nil(row.ended_at)

      # The 5th matching entry reaches max_entries: it is STILL tagged, and
      # the session ends in the SAME atomic step (AT9's literal wording).
      assert Nebu.Web.LogStore.WarRoom.check(log_entry([])) == id

      row = session_row(id)
      assert row.entries_collected == 5
      refute is_nil(row.ended_at)
      assert row.ended_reason == "budget_exhausted"

      # The 6th matching entry, sent after the session has ended, is NOT
      # tagged — the session is no longer active.
      refute Nebu.Web.LogStore.WarRoom.check(log_entry([]))
      assert session_row(id).entries_collected == 5,
             "entries_collected must not increment once the session has ended"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Duration timer (AC5) — auto-terminate when max_duration_s elapses
  # ══════════════════════════════════════════════════════════════════════════

  describe "duration timer — auto-terminate via the scheduled Process.send_after timer" do
    test "a short max_duration_s auto-terminates via the timer; subsequent entries are not tagged",
         %{war_room: wr} do
      id = insert_session(max_duration_s: 1, scope: "all")
      load!(wr)

      assert Nebu.Web.LogStore.WarRoom.check(log_entry([])) == id

      # Give the scheduled `Process.send_after(self(), {:check_timeout, id}, ...)`
      # message time to arrive and be handled.
      Process.sleep(1_500)

      row = session_row(id)
      refute is_nil(row.ended_at),
             "expected the session to be ended once max_duration_s has elapsed"

      assert row.ended_reason == "duration_exceeded"

      refute Nebu.Web.LogStore.WarRoom.check(log_entry([])),
             "a matching entry sent after the duration timer fired must no longer be tagged"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Boot-time load of an already-expired session (AC5, cross-restart)
  # ══════════════════════════════════════════════════════════════════════════

  describe "load_active/0 immediately ends an already-expired session (boot-time equivalent)" do
    test "an already-elapsed session is ended as duration_exceeded immediately on load, not after a fresh timer",
         %{war_room: wr} do
      id =
        insert_session(
          max_duration_s: 1,
          started_at: DateTime.add(DateTime.utc_now(), -10, :second)
        )

      load!(wr)

      row = session_row(id)

      refute is_nil(row.ended_at),
             "an already-expired session must be ended IMMEDIATELY on load (e.g. after this " <>
               "process was down past max_duration_s and just restarted) — not left dangling " <>
               "until some future timer fires"

      assert row.ended_reason == "duration_exceeded"

      refute Nebu.Web.LogStore.WarRoom.check(log_entry([])),
             "the expired session must not still be treated as active immediately after load"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Crash/restart via supervisor (AC5 + design-decisions.md #4) — test-review
  # finding (MAJOR): this GenServer-state story previously had no crash/
  # restart coverage at all, unlike its sibling `Writer` GenServer's own
  # established "AC6: writer crash/restart via supervisor" test
  # (writer_test.exs). Design-decisions.md #4 explicitly specifies
  # `Nebu.Web.LogStore.WarRoom` is added to `Nebu.Application.repo_children/0`
  # "alongside Writer/PolicyCache" with the SAME supervision/restart
  # contract — this test proves that contract holds, mirroring
  # writer_test.exs's test nearly verbatim, AND closes a second, more subtle
  # gap: every OTHER "boot-time load" test in this file (see the describe
  # block just above) calls `load!/1`, which EXPLICITLY invokes
  # `load_active/0` — none of them prove that a freshly-(re)started
  # process's OWN `init/1` calls `load_active/0` on its own, with no test
  # code forcing it. This test never calls `load_active/0`/`load!/1` for the
  # session under test — only polls the DB row — so a pass here is genuine
  # proof of the real "process was down past max_duration_s and just
  # restarted" scenario design-decisions.md #4 describes for AC5.
  # ══════════════════════════════════════════════════════════════════════════

  describe "crash/restart via supervisor (AC5 boot-time load, no explicit load_active/0 call)" do
    test "a killed WarRoom is restarted under the same name; its own init/1 ends an already-expired session, and check/1 resumes working afterward",
         %{war_room: wr} do
      end_all_active!()

      # Already past its deadline BEFORE the crash — exactly the "process
      # was down past max_duration_s and just restarted" scenario.
      expired_id =
        insert_session(
          max_duration_s: 1,
          started_at: DateTime.add(DateTime.utc_now(), -10, :second)
        )

      ref = Process.monitor(wr)
      Process.exit(wr, :kill)

      assert_receive {:DOWN, ^ref, :process, ^wr, :killed}, 1_000,
        "expected WarRoom to actually die from the :kill signal"

      # Poll for the supervisor to restart it under the same registered name
      # with a fresh pid (rather than assuming a fixed restart delay) —
      # identical mechanism to writer_test.exs's own crash/restart test.
      new_pid = wait_until_registered(Nebu.Web.LogStore.WarRoom, wr, 5_000)

      assert new_pid != wr,
             "the restarted WarRoom must be a NEW process, not the killed one"

      assert Process.alive?(new_pid), "the restarted WarRoom must be alive"

      # No `load_active/0`/`load!/1` call here — this proves the restarted
      # process's own `init/1` reaches "already-expired session ended" on
      # its own, exactly like a real boot after downtime (AC5, cross-restart).
      row = wait_until_ended(expired_id, 5_000)

      assert row.ended_reason == "duration_exceeded",
             "expected the restarted process's own init/1 to end the already-expired " <>
               "session it loaded at boot, got ended_reason: #{inspect(row.ended_reason)}"

      # And it must actually work again — not just be alive-but-broken.
      # `expired_id` is now ended, so a fresh session may be started
      # (AC2's "exactly one active" invariant).
      fresh_id = insert_session(max_entries: 1000, scope: "all")
      :ok = Nebu.Web.LogStore.WarRoom.load_active()
      :sys.get_state(new_pid)

      assert Nebu.Web.LogStore.WarRoom.check(log_entry([])) == fresh_id,
             "expected the restarted WarRoom to resume accepting/tagging entries for a " <>
               "freshly-created session after the crash"
    end

    # test-review finding 5 (enhanced-logging/war-room-dedicated-page,
    # 2026-07-08) — extends THIS describe block rather than duplicating it in
    # the new story's own test files, per the coordinator's explicit
    # instruction. `exclusive_scope` (war-room-dedicated-page, AC9/AC10) must
    # survive the exact same crash+restart cycle the test above already
    # proves for `ended_reason`/budget state: a raw INSERT (not the shared
    # `insert_session/1` helper above, which does not know about this
    # story's new column — keeping that helper's existing 8-column INSERT
    # untouched so every OTHER, already-green test in this file is
    # unaffected) seeds a session with a non-empty `exclusive_scope`. Like
    # the test above, this NEVER calls `load_active/0`/`load!/1` for the
    # session under test — only the RESTARTED process's own `init/1` may
    # explain a pass here.
    #
    # Why this MUST FAIL right now: the `exclusive_scope` column does not
    # exist yet (see `war_room_exclusive_scope_test.exs`'s own schema-contract
    # test) — this raw INSERT fails with a Postgres
    # `column "exclusive_scope" does not exist` error.
    test "exclusive_scope survives a WarRoom GenServer crash+restart (reloaded from DB by the restarted process's own init/1)",
         %{war_room: wr} do
      end_all_active!()

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO war_room_sessions
            (started_by, reason, scope, exclusive_scope, max_entries, max_duration_s,
             started_at, entries_collected)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          RETURNING id
          """,
          [
            "distinctive-war-room-test-#{run_id()}",
            "exclusive_scope crash/restart survival probe",
            "all",
            ["/_matrix/client/v3/sync"],
            1000,
            300,
            DateTime.utc_now(),
            0
          ]
        )

      [[id]] = result.rows

      ref = Process.monitor(wr)
      Process.exit(wr, :kill)

      assert_receive {:DOWN, ^ref, :process, ^wr, :killed}, 1_000,
        "expected WarRoom to actually die from the :kill signal"

      new_pid = wait_until_registered(Nebu.Web.LogStore.WarRoom, wr, 5_000)
      assert Process.alive?(new_pid), "the restarted WarRoom must be alive"

      # No `load_active/0`/`load!/1` call — proves the FRESHLY RESTARTED
      # process's own `init/1` loaded `exclusive_scope` from the DB on its
      # own, not merely a manually-forced cache reload.
      refute Nebu.Web.LogStore.WarRoom.check(
               log_entry(route_template: "/_matrix/client/v3/sync")
             ),
             "AC9/AC10 + crash/restart: exclusive_scope must survive a crash+restart cycle — " <>
               "the excluded route must still be skipped by the restarted process's own " <>
               "init/1-loaded session state, exactly like ended_reason/budget survives it above"

      assert Nebu.Web.LogStore.WarRoom.check(log_entry(route_template: "/admin/rooms")) == id,
             "a non-excluded route must still be tagged normally after the restart"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # check/1 cheap/non-blocking when inactive (Oracle gate — MUST NOT delay a
  # /sync response). A loose perf-shape assertion, not a strict timing
  # guarantee — per the task brief's own framing.
  # ══════════════════════════════════════════════════════════════════════════

  describe "check/1 is cheap and non-blocking when no war room is active" do
    test "1000 calls to check/1 with no active session complete fast, on average, and all return nil",
         %{war_room: wr} do
      # Defensive reset: end whatever might currently be "active" (AC2
      # guarantees at most one such row exists at all) so this test's
      # precondition ("nothing is active") holds regardless of test order.
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
        []
      )

      load!(wr)

      {elapsed_us, results} =
        :timer.tc(fn ->
          for _ <- 1..1_000, do: Nebu.Web.LogStore.WarRoom.check(log_entry([]))
        end)

      assert Enum.all?(results, &is_nil/1),
             "check/1 must return nil for every call when no war room session is active"

      avg_us = elapsed_us / 1_000

      assert avg_us < 1_000,
             "expected check/1 to be a cheap, non-blocking no-op when inactive " <>
               "(avg #{avg_us}us over 1000 calls) — this is a loose perf-shape assertion " <>
               "(the Oracle gate's requirement is that war-room checks must never delay a " <>
               "/sync response), not a strict timing guarantee"
    end
  end
end
