defmodule Nebu.Admin.LogsLive.TraceMapStatus do
  @moduledoc """
  Per-node status model for the Trace Map "Leitstand"
  (enhanced-logging/trace-map-leitstand, AC3): a 60-second sliding window
  over a node's log events, with worst-child propagation and automatic
  healing.

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §2

  A plain, pure module (ADR-018/021): `Nebu.Admin.LogsLive.TraceMap` keeps
  one state per map node (nebu, each domain, each satellite) in a socket
  assign and drives every timestamp with plain integer milliseconds
  (`System.system_time(:millisecond)` at ingest; `inserted_at`-derived for
  mount-time history) — deterministic and directly unit-testable with exact
  integers, no `DateTime` arithmetic.

  ## The window is a pure function of `(state, now_ms)` — auto-heal falls out

  `counts/2`/`status/2` never mutate state: every call independently filters
  the recorded events by `now_ms - timestamp_ms < 60_000`. There is
  deliberately NO `heal/1`/`ack/1` operation (spec §2: "Nodes heal
  automatically when the window passes — no manual acknowledge") — the SAME
  state, queried at a later `now_ms` once every event has aged out, is `:ok`
  with zero counts, with no code path that could "forget" to re-evaluate it.

  Note the deliberate departure from the sibling `/admin/logs` page's Trace
  Map bubbles: THOSE counts are cumulative since page load; here ALL three
  counts — including requests — are windowed (AC3's literal text).

  ## Memory bound

  `record/3` prunes events that had already aged out of the window ending at
  the newly recorded timestamp, so a long-lived LiveView holding many node
  states stays bounded by 60 seconds of traffic per node, with no separate
  cleanup timer needed.
  """

  @window_ms 60_000

  @type kind :: :request | :warning | :error
  @type t :: %{requests: [integer()], warnings: [integer()], errors: [integer()]}

  @rank %{ok: 0, warn: 1, error: 2}

  @doc "An empty node state (no events recorded yet)."
  @spec new() :: t()
  def new, do: %{requests: [], warnings: [], errors: []}

  @doc """
  Appends one event of `kind` at `timestamp_ms`, pruning events that have
  already aged out of the window ending at `timestamp_ms` (see moduledoc).
  """
  @spec record(t(), kind(), integer()) :: t()
  def record(state, kind, timestamp_ms) do
    key = key_for(kind)
    Map.update!(state, key, fn events -> [timestamp_ms | prune(events, timestamp_ms)] end)
  end

  @doc """
  Counts of events of each kind still inside the 60-second window ending at
  `now_ms` (`now_ms - timestamp_ms < 60_000`). Pure — never mutates state.
  """
  @spec counts(t(), integer()) :: %{
          requests: non_neg_integer(),
          warnings: non_neg_integer(),
          errors: non_neg_integer()
        }
  def counts(state, now_ms) do
    %{
      requests: count_in_window(state.requests, now_ms),
      warnings: count_in_window(state.warnings, now_ms),
      errors: count_in_window(state.errors, now_ms)
    }
  end

  @doc """
  Spec §2's literal precedence rule at `now_ms`: `errors > 0` -> `:error`,
  else `warnings > 0` -> `:warn`, else `:ok`.
  """
  @spec status(t(), integer()) :: :ok | :warn | :error
  def status(state, now_ms) do
    cond do
      count_in_window(state.errors, now_ms) > 0 -> :error
      count_in_window(state.warnings, now_ms) > 0 -> :warn
      true -> :ok
    end
  end

  @doc """
  Worst-child propagation (spec §2: a parent's status is the worst of its
  children): `:error` > `:warn` > `:ok`. An empty list is `:ok`.
  """
  @spec worst([:ok | :warn | :error]) :: :ok | :warn | :error
  def worst([]), do: :ok
  def worst(statuses), do: Enum.max_by(statuses, &Map.fetch!(@rank, &1))

  defp key_for(:request), do: :requests
  defp key_for(:warning), do: :warnings
  defp key_for(:error), do: :errors

  defp count_in_window(events, now_ms), do: Enum.count(events, &(now_ms - &1 < @window_ms))

  defp prune(events, now_ms), do: Enum.filter(events, &(now_ms - &1 < @window_ms))
end
