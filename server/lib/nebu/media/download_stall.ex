defmodule Nebu.Media.DownloadStall do
  @moduledoc """
  Opt-in `?timeout_ms=N` download-stall consumer
  (`media-security-admin-control/2d-download-stall-mechanism`, AC2-AC6).

  Story 1c made the download handler an immediate state → response mapping:
  `:quarantined`/`:scanning` deny with `451 M_NOT_YET_UPLOADED` right away.
  For a client that uploads and immediately downloads, that is pessimistic —
  the ClamAV scan (Story 3/4b) normally finishes within a couple of seconds.
  This module lets the handler hold the request open, event-driven via
  `Phoenix.PubSub`, until the media reaches a terminal state (`:released` or a
  permanent-deny state) or a bounded timeout elapses — at which point
  `Nebu.Media.download/4` re-reads the row and applies the SAME 1c mapping.

  ## Consumer-only (Story 4b coordination)

  This module ONLY subscribes/reacts. It never broadcasts. The producer that
  publishes `{:media_state_transition, media_id, new_state}` on
  `"media:\#{media_id}"` (the app's main `Nebu.PubSub`) is a future story
  (4b/1b); `Nebu.Media.StateMachine.transition/4` does not broadcast today.
  The payload shape here is the agreed contract that producer must match.

  ## Design (Technical Requirements)

    * **Subscribe-then-recheck** — the waiting `Task` subscribes to the topic
      FIRST, then re-reads the current state via `recheck_fun`. If the state
      already reached a terminal value in the narrow window between the
      handler's first read and the subscribe call, it resolves immediately
      instead of entering the `receive` block (closes the lost-wakeup race).
    * **`receive`/`after`, never polling** — the wait is a single blocking
      `receive ... after remaining -> :timeout end` (deadline-bounded so an
      intermediate non-terminal broadcast, e.g. `:quarantined -> :scanning`,
      does not reset the budget). No code path re-queries the DB on an
      interval while waiting (AC5).
    * **Task-bound** — the `receive` runs inside a `Task`; the caller bounds
      it with `Task.await/2` using the clamped timeout plus a small buffer so
      `Task.await` never races the inner `receive`'s own `after`. When the
      `Task` exits, `Phoenix.PubSub` auto-unsubscribes it (Registry monitor),
      so no subscription leaks.
    * **Crash-safe concurrency ceiling** — a single global `:atomics` counter
      (stored in `:persistent_term`) is incremented on stall-entry and
      decremented in an `after` block around the wait, so a normally-exiting
      or exception-raising stall never leaks the count. When the ceiling is
      already reached, `await/4` returns `:no_slot` and the caller degrades
      to the immediate 1c response (AC6).
  """

  # States still "worth waiting on": a scan is pending or running, so a
  # terminal `:media_state_transition` broadcast may still arrive. Every other
  # state (`:released`, the permanent-deny states, `nil`/not-found) is terminal
  # for stall purposes — resolve and let the caller's fresh 1c mapping decide.
  @stallable [:quarantined, :scanning]

  @pt_key {__MODULE__, :active_stalls}

  @doc """
  Blocks the calling process until `media_id` leaves a stallable state
  (`:quarantined`/`:scanning`) via a PubSub broadcast, or `clamped_timeout_ms`
  elapses.

  `recheck_fun` is a 0-arity closure returning the media's freshly-read
  lifecycle state atom (or `nil` if the row is gone). `max_concurrent` is the
  configured concurrency ceiling.

  Returns:
    * `:resolved` — a terminal state was observed (either already present on
      the subscribe-then-recheck, or reported by a broadcast).
    * `:timeout` — the window elapsed with the media still stallable.
    * `:no_slot` — the concurrency ceiling was already reached; no wait was
      performed (caller must degrade to the immediate 1c response).

  The return value is advisory: `Nebu.Media.download/4` re-reads the row and
  re-applies the 1c mapping regardless, so `:resolved` vs `:timeout` only
  affects how long it waited, not which mapping runs.
  """
  @spec await(String.t(), pos_integer(), pos_integer(), (-> atom() | nil)) ::
          :resolved | :timeout | :no_slot
  def await(media_id, clamped_timeout_ms, max_concurrent, recheck_fun)
      when is_binary(media_id) and is_integer(clamped_timeout_ms) and clamped_timeout_ms > 0 and
             is_function(recheck_fun, 0) do
    case acquire_slot(max_concurrent) do
      :ok ->
        try do
          run_wait(media_id, clamped_timeout_ms, recheck_fun)
        after
          release_slot()
        end

      :full ->
        :no_slot
    end
  end

  defp run_wait(media_id, clamped_timeout_ms, recheck_fun) do
    task =
      Task.async(fn ->
        # Subscribe FIRST, then recheck — a transition landing between the
        # handler's first read and this subscribe is caught by the recheck,
        # not silently missed until the window elapses.
        Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

        if stallable?(recheck_fun.()) do
          deadline = System.monotonic_time(:millisecond) + clamped_timeout_ms
          receive_loop(media_id, deadline)
        else
          :resolved
        end
      end)

    # +50ms buffer so Task.await never fires before the inner deadline-bound
    # `after`; the inner block always returns by clamped_timeout_ms.
    Task.await(task, clamped_timeout_ms + 50)
  end

  defp receive_loop(media_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:media_state_transition, ^media_id, new_state} ->
          if stallable?(new_state) do
            # Intermediate non-terminal transition (e.g. :quarantined ->
            # :scanning) — keep waiting on the SAME deadline (no budget reset,
            # no re-query).
            receive_loop(media_id, deadline)
          else
            :resolved
          end
      after
        remaining -> :timeout
      end
    end
  end

  defp stallable?(state), do: state in @stallable

  defp topic(media_id), do: "media:#{media_id}"

  # ── crash-safe global concurrency counter (:atomics via :persistent_term) ──

  @doc """
  Eagerly creates the single shared, signed `:atomics` concurrency counter and
  stashes it in `:persistent_term` for the VM's lifetime.

  Called once at boot from `Nebu.Application.start/2` so `counter_ref/0` is a
  pure, race-free read. Guarded (nil-check) so a same-VM re-entry (hot code
  reload / a test re-invoking `start/2`) does NOT swap the counter out from
  under in-flight stalls. Safe because it only ever runs once, sequentially, at
  boot — never concurrently — so it carries none of the concurrent double-init
  race that a lazy check-then-put on the hot path would.
  """
  @spec init_counter() :: :ok
  def init_counter do
    if :persistent_term.get(@pt_key, nil) == nil do
      :persistent_term.put(@pt_key, :atomics.new(1, signed: true))
    end

    :ok
  end

  defp acquire_slot(max) do
    ref = counter_ref()
    n = :atomics.add_get(ref, 1, 1)

    if n <= max do
      :ok
    else
      # Over the ceiling — undo our increment and refuse the slot.
      :atomics.sub(ref, 1, 1)
      :full
    end
  end

  defp release_slot do
    :atomics.sub(counter_ref(), 1, 1)
  end

  # Returns the single shared, signed `:atomics` counter created eagerly at boot
  # by `init_counter/0` (called from `Nebu.Application.start/2`). A pure,
  # race-free read — no lazy check-then-put on the hot path. Signed so an
  # accounting edge never wraps to a huge unsigned value that would wedge the
  # ceiling closed.
  defp counter_ref, do: :persistent_term.get(@pt_key)
end
