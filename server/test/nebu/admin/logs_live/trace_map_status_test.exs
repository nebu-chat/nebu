defmodule Nebu.Admin.LogsLive.TraceMapStatusTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-leitstand`, AC3
  (status model — 60-second sliding window, worst-child propagation,
  auto-heal).

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §2

  ## Why this MUST FAIL right now

  `Nebu.Admin.LogsLive.TraceMapStatus` does not exist yet — none of AC3's
  window/propagation/auto-heal logic has been written. Every call below
  fails with `** (UndefinedFunctionError)`, NOT a compile error in this file.

  ## Module contract this file pins down (proposed plain module — the dev
  agent's own Dev Notes, "Known Challenges" item 1, name this exact
  Option A design: "a rolling buffer of `{timestamp, level}` tuples per
  node" — this file concretizes that into a testable API. The dev agent may
  restructure the internal representation (e.g. a single tagged list
  instead of three separate lists) as long as `counts/2`/`status/2`/
  `worst/1`'s OBSERVABLE behavior below holds; `Nebu.Admin.LogsLive.TraceMap`
  is expected to keep one of these states per map node (nebu, each domain,
  each satellite) in a socket assign, e.g. `%{node_key => state}`):

    * `new/0 :: state` — an empty node state (no events recorded yet).

    * `record(state, kind, timestamp_ms) :: state` where `kind` is one of
      `:request | :warning | :error` — appends one event of that kind at
      `timestamp_ms` (a plain integer millisecond timestamp — NOT a
      `DateTime`, so tests can drive the window boundary with exact,
      deterministic integers instead of fighting `DateTime` arithmetic/
      flakiness; `Nebu.Admin.LogsLive.TraceMap` converts real timestamps to
      `System.system_time(:millisecond)` or equivalent before calling this).

    * `counts(state, now_ms) :: %{requests: non_neg_integer(), warnings:
      non_neg_integer(), errors: non_neg_integer()}` — counts of events of
      each kind still inside the 60-SECOND (60_000 ms) window ending at
      `now_ms`, i.e. events with `now_ms - timestamp_ms < 60_000`. This
      function is PURE (does not mutate/return a pruned `state` — every
      call independently filters by `now_ms`, so there is no risk of
      "forgot to prune before reading" bugs).

      **Deliberate departure from the sibling `admin-logs-monitoring-view`
      page's Trace Map bubbles**: THOSE bubble counts (`@endpoint_counts`
      etc. in `Nebu.Admin.LogsLive`) are cumulative SINCE PAGE LOAD, never
      windowed. AC3 is explicit that the Leitstand's counts — INCLUDING the
      request count, not just warnings/errors — are a rolling 60-second
      window: "Each node tracks request count, warning count, error count
      from entries in `LogStore` where `inserted_at > now() - 60 seconds`".
      A dev tempted to reuse the sibling page's cumulative-counter pattern
      for `Nebu.Admin.LogsLive.TraceMap` would silently violate AC3 — see
      the "requests are ALSO windowed" test below, which exists
      specifically to catch that mistake.

    * `status(state, now_ms) :: :ok | :warn | :error` — derived from
      `counts/2` at `now_ms`: `errors > 0` → `:error`; else `warnings > 0`
      → `:warn`; else `:ok` (spec §2's literal rule).

    * `worst(statuses :: [:ok | :warn | :error]) :: :ok | :warn | :error` —
      worst-child propagation (spec §2: "a parent's status is the worst of
      its children"): precedence `:error` > `:warn` > `:ok`. An empty list
      (a domain with no satellites, or nebu with no domains — degenerate,
      but must not crash) is `:ok`.

  ## Auto-heal (spec §2: "Nodes heal automatically when the window passes —
  no manual acknowledge")

  There is deliberately NO `heal/1`, `ack/1`, or any other explicit
  "clear this node's alarm" function in this contract. Auto-heal is not a
  distinct operation — it falls directly out of `counts/2`/`status/2` being
  pure functions of `(state, now_ms)`: the SAME state, queried at a LATER
  `now_ms` once every event has aged out of the 60-second window, is `:ok`
  with zero counts, with no code path that "forgets" to re-evaluate it.
  """

  use ExUnit.Case, async: true

  alias Nebu.Admin.LogsLive.TraceMapStatus, as: Status

  @window_ms 60_000

  # dev-story note: these wrappers used `apply/3` during the RED phase (see
  # `trace_map_geometry_test.exs`'s identical comment — the module did not
  # exist yet, so direct calls would have failed the xref-backed
  # undefined-remote-function compile check). Converted to DIRECT calls per
  # the test-review recommendation now that the module exists.
  defp new_status, do: Status.new()
  defp record(state, kind, ts), do: Status.record(state, kind, ts)
  defp counts(state, now), do: Status.counts(state, now)
  defp status(state, now), do: Status.status(state, now)
  defp worst(statuses), do: Status.worst(statuses)

  # ══════════════════════════════════════════════════════════════════════
  # new/0 + record/3 + counts/2 — basic bookkeeping
  # ══════════════════════════════════════════════════════════════════════

  describe "new/0 — an empty node has zero counts and :ok status" do
    test "counts/2 are all zero" do
      state = new_status()
      assert counts(state, 0) == %{requests: 0, warnings: 0, errors: 0}
    end

    test "status/2 is :ok" do
      assert status(new_status(), 0) == :ok
    end
  end

  describe "record/3 — appends one event of the given kind" do
    test "a :request increments the requests count, leaving warnings/errors at zero" do
      state = new_status() |> record(:request, 0)
      assert counts(state, 0) == %{requests: 1, warnings: 0, errors: 0}
    end

    test "recording 3 requests, 2 warnings, 1 error at the same timestamp counts each independently" do
      state =
        new_status()
        |> record(:request, 1_000)
        |> record(:request, 1_000)
        |> record(:request, 1_000)
        |> record(:warning, 1_000)
        |> record(:warning, 1_000)
        |> record(:error, 1_000)

      assert counts(state, 1_000) == %{requests: 3, warnings: 2, errors: 1}
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # status/2 — error > 0 -> :error, else warn > 0 -> :warn, else :ok
  # ══════════════════════════════════════════════════════════════════════

  describe "status/2 — precedence rule (spec §2)" do
    test "any error present -> :error, even alongside warnings" do
      state = new_status() |> record(:warning, 0) |> record(:error, 0)
      assert status(state, 0) == :error
    end

    test "warnings but no errors -> :warn" do
      state = new_status() |> record(:warning, 0)
      assert status(state, 0) == :warn
    end

    test "only requests, no warnings/errors -> :ok" do
      state = new_status() |> record(:request, 0) |> record(:request, 0)
      assert status(state, 0) == :ok
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # 60-second sliding window + auto-heal
  # ══════════════════════════════════════════════════════════════════════

  describe "60-second sliding window (spec §2) — auto-heal with no explicit acknowledge" do
    test "a warning is still counted 1ms before the window closes" do
      state = new_status() |> record(:warning, 0)
      assert status(state, @window_ms - 1) == :warn
      assert counts(state, @window_ms - 1).warnings == 1
    end

    test "a warning ages out exactly at the 60s boundary and the node auto-heals to :ok" do
      state = new_status() |> record(:warning, 0)

      assert status(state, @window_ms) == :ok
      assert counts(state, @window_ms) == %{requests: 0, warnings: 0, errors: 0}
    end

    test "an error ages out the same way, with no manual acknowledge call anywhere in this test" do
      state = new_status() |> record(:error, 0)

      assert status(state, 30_000) == :error
      assert status(state, @window_ms + 1) == :ok
    end

    test "requests are ALSO windowed — NOT cumulative like the sibling page's bubble counts (AC3, see moduledoc)" do
      state =
        new_status()
        |> record(:request, 0)
        |> record(:request, 0)
        |> record(:request, 0)

      assert counts(state, 0).requests == 3
      assert counts(state, @window_ms + 1).requests == 0
    end

    test "independent aging: an earlier warning heals while a later error in the same node stays active" do
      state =
        new_status()
        |> record(:warning, 0)
        |> record(:error, 30_000)

      # At t=61_000: warning (recorded at 0) is 61_000ms old -> aged out.
      #              error (recorded at 30_000) is 31_000ms old -> still active.
      status_at_61s = status(state, 61_000)
      counts_at_61s = counts(state, 61_000)

      assert status_at_61s == :error
      assert counts_at_61s.warnings == 0
      assert counts_at_61s.errors == 1

      # At t=95_000: the error (recorded at 30_000) is now 65_000ms old -> heals too.
      assert status(state, 95_000) == :ok
    end

    test "a fresh event after healing re-activates the node (the window is a rolling function of `now`, not a one-shot latch)" do
      state = new_status() |> record(:error, 0)

      assert status(state, @window_ms + 1) == :ok

      state = record(state, :error, @window_ms + 1)
      assert status(state, @window_ms + 1) == :error
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # worst/1 — worst-child propagation (satellite -> domain -> nebu)
  # ══════════════════════════════════════════════════════════════════════

  describe "worst/1 — worst-child propagation (spec §2)" do
    test "an empty list of children (a domain with no satellites) is :ok, never crashes" do
      assert worst([]) == :ok
    end

    test "all-:ok children -> :ok" do
      assert worst([:ok, :ok, :ok]) == :ok
    end

    test "one :warn among :ok children -> :warn" do
      assert worst([:ok, :warn, :ok]) == :warn
    end

    test "one :error among :ok and :warn children -> :error (error beats warn)" do
      assert worst([:ok, :warn, :error, :ok]) == :error
    end

    test "propagation composes: a domain's worst-of-satellites feeds into nebu's worst-of-domains" do
      domain_a_status = worst([:ok, :ok])
      domain_b_status = worst([:warn, :ok])
      domain_c_status = worst([:error, :warn])

      assert domain_a_status == :ok
      assert domain_b_status == :warn
      assert domain_c_status == :error

      nebu_status = worst([domain_a_status, domain_b_status, domain_c_status])
      assert nebu_status == :error
    end
  end
end
