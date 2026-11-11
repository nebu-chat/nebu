defmodule Nebu.Media.DownloadStall do
  @moduledoc """
  `?timeout_ms=N` download/thumbnail-stall consumer
  (`media-security-admin-control/2d-download-stall-mechanism`, AC2-AC6;
  `bugfix/media-download-451-scan-race`: also applied, with the spec default
  window, when the client sends no `timeout_ms`).

  Story 1c made the download handler an immediate state → response mapping:
  `:quarantined`/`:scanning` deny with `451 M_NOT_YET_UPLOADED` right away.
  For a client that uploads and immediately downloads, that is pessimistic —
  the ClamAV scan (Story 3/4b) normally finishes within a couple of seconds.
  This module lets the handler hold the request open, event-driven via
  `Phoenix.PubSub`, until the media reaches a terminal state (`:released` or a
  permanent-deny state) or a bounded timeout elapses — at which point
  `Nebu.Media.with_authorised_media/5` (download AND thumbnail) re-reads the
  row and applies the SAME 1c mapping.

  ## Consumer-only

  This module ONLY subscribes/reacts. It never broadcasts. The producer is
  `Nebu.Media.MediaScanWorker.broadcast/2`, which publishes
  `{:media_state_transition, media_id, new_state}` on `"media:\#{media_id}"`
  (the app's main `Nebu.PubSub`) once a scan outcome is persisted. The payload
  shape is the contract this consumer matches.

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
    * **Task-bound, never a crash** — the `receive` runs inside a `Task`. The
      deadline is fixed BEFORE the task starts (so a slow `recheck_fun` eats
      into the window instead of extending it) and the caller bounds the task
      with `Task.yield/2` + `Task.shutdown/2` using the window plus a buffer.
      A raising/exiting `recheck_fun`, or one that outlives the buffer,
      degrades to `:timeout` — the caller then applies the immediate 1c
      mapping, so a stall problem never turns into a 500. When the `Task`
      exits, `Phoenix.PubSub` auto-unsubscribes it (Registry monitor), so no
      subscription leaks.
    * **Crash-safe concurrency ceiling** — a single global `:atomics` counter
      (stored in `:persistent_term`) is incremented on stall-entry. Each slot is
      owned by a tiny unlinked keeper process that monitors the requesting
      process: the slot is released exactly once, either explicitly in an
      `after` block (normal/timeout/raise) or by the keeper on `:DOWN` when the
      requester is killed from outside (e.g. Bandit HTTP/2 client disconnect,
      where `after` never runs). When the ceiling is
      already reached, `await/4` returns `:no_slot` and the caller degrades
      to the immediate 1c response (AC6).
  """

  require Logger

  # States still "worth waiting on": a scan is pending or running, so a
  # terminal `:media_state_transition` broadcast may still arrive. Every other
  # state (`:released`, the permanent-deny states, `nil`/not-found) is terminal
  # for stall purposes — resolve and let the caller's fresh 1c mapping decide.
  @stallable [:quarantined, :scanning]

  @pt_key {__MODULE__, :active_stalls}

  # Slack on top of the stall window before the caller gives up on the wait
  # task (covers the DB-reading recheck + scheduling; see run_wait/3).
  @await_buffer_ms 250

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
    * `:timeout` — the window elapsed with the media still stallable, or the
      wait failed (`recheck_fun` raised/exited/hung past the buffer).
    * `:no_slot` — the concurrency ceiling was already reached; no wait was
      performed (caller must degrade to the immediate 1c response).

  The return value is advisory: the caller re-reads the row and re-applies the
  1c mapping regardless, so `:resolved` vs `:timeout` only
  affects how long it waited, not which mapping runs.
  """
  @spec await(String.t(), pos_integer(), pos_integer(), (-> atom() | nil)) ::
          :resolved | :timeout | :no_slot
  def await(media_id, clamped_timeout_ms, max_concurrent, recheck_fun)
      when is_binary(media_id) and is_integer(clamped_timeout_ms) and clamped_timeout_ms > 0 and
             is_function(recheck_fun, 0) do
    case acquire_slot(max_concurrent) do
      {:ok, slot} ->
        try do
          run_wait(media_id, clamped_timeout_ms, recheck_fun)
        after
          release_slot(slot)
        end

      :full ->
        :no_slot
    end
  end

  defp run_wait(media_id, clamped_timeout_ms, recheck_fun) do
    # Deadline fixed BEFORE the (DB-reading) recheck so Task.yield's timer and
    # the inner `receive ... after` run off the same clock.
    deadline = System.monotonic_time(:millisecond) + clamped_timeout_ms

    task =
      Task.async(fn ->
        try do
          # Subscribe FIRST, then recheck — a transition landing between the
          # handler's first read and this subscribe is caught by the recheck,
          # not silently missed until the window elapses.
          Phoenix.PubSub.subscribe(Nebu.PubSub, topic(media_id))

          if stallable?(recheck_fun.()) do
            receive_loop(media_id, deadline)
          else
            :resolved
          end
        rescue
          e ->
            Logger.warning("download stall wait failed: #{inspect(e.__struct__)}")
            :timeout
        catch
          kind, _reason ->
            Logger.warning("download stall wait failed: #{kind}")
            :timeout
        end
      end)

    # The buffer keeps Task.yield from firing before the inner deadline-bound
    # `after`; it only trips when recheck_fun itself hangs. Never `Task.await`:
    # its exit would take the request down (500) instead of degrading to 1c.
    case Task.yield(task, clamped_timeout_ms + @await_buffer_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
    end
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

  # ── slot accounting: crash-safe by construction (exactly-once) ──
  #
  # A `try/after` in the request process is NOT enough: Bandit runs each HTTP/2
  # request in a process linked to the connection process, and a client
  # disconnect kills it with an exit signal — `after` never runs and the slot
  # leaks for the node's lifetime (security review F-1). So every slot is tied
  # to the requesting process's lifetime by a tiny unlinked "slot keeper"
  # process that monitors the requester:
  #
  #   * the keeper itself performs the (ceiling-checked) increment, so there is
  #     no window between "slot taken" and "monitor established";
  #   * the slot is released EXACTLY ONCE by whoever wins a compare-exchange on
  #     the per-slot `claim` atomic (1 -> 0): the requester on the normal /
  #     timeout / raise / no-wait paths (synchronously, so the counter is
  #     already correct when `await/4` returns), or the keeper on `:DOWN` of the
  #     requester. The loser sees the claim already taken and does nothing, so
  #     the counter can never be decremented twice (never negative).
  #   * on the normal path the requester then stops the keeper (no leaked
  #     processes; the keeper also exits on its own after `:DOWN`).
  #
  # Per-node state only (`:atomics`), consistent with the per-node ceiling.
  #
  # A non-integer or non-positive ceiling (config `"500"`, nil, 0, negative)
  # fails CLOSED: with `n <= max` Erlang term order would make any non-number
  # `max` admit everyone, silently disabling the ceiling. Immediate 1c, no slot.
  defp acquire_slot(max) when not is_integer(max) or max <= 0, do: :full

  defp acquire_slot(max) do
    caller = self()
    tag = make_ref()
    claim = :atomics.new(1, signed: false)
    counter = counter_ref()

    {keeper, mref} =
      spawn_monitor(fn -> keeper_loop(caller, tag, claim, counter, max) end)

    receive do
      {^tag, :ok} ->
        Process.demonitor(mref, [:flush])
        {:ok, {keeper, tag, claim, counter}}

      {^tag, :full} ->
        Process.demonitor(mref, [:flush])
        :full

      {:DOWN, ^mref, :process, _pid, _reason} ->
        # Keeper died before answering. It may already hold a slot (claim=1
        # is set after the increment, before the :ok reply) or sit between
        # add_get and sub on the over-ceiling path. release_claim/2 is
        # idempotent (CAS-guarded) and frees a held slot; degrade to 1c.
        release_claim(claim, counter)
        :full
    end
  end

  defp keeper_loop(caller, tag, claim, counter, max) do
    caller_ref = Process.monitor(caller)
    n = :atomics.add_get(counter, 1, 1)

    if n <= max do
      # Slot owned: publish ownership BEFORE replying, so whoever releases
      # (requester or this keeper) can claim it.
      :atomics.put(claim, 1, 1)
      send(caller, {tag, :ok})

      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} -> release_claim(claim, counter)
        {:release, ^tag} -> :ok
      end
    else
      # Over the ceiling — undo our increment and refuse the slot.
      :atomics.sub(counter, 1, 1)
      send(caller, {tag, :full})
    end
  end

  defp release_slot({keeper, tag, claim, counter}) do
    release_claim(claim, counter)
    send(keeper, {:release, tag})
    :ok
  end

  # Exactly-once decrement: only the winner of the 1 -> 0 compare-exchange
  # touches the counter.
  defp release_claim(claim, counter) do
    case :atomics.compare_exchange(claim, 1, 1, 0) do
      :ok -> :atomics.sub(counter, 1, 1)
      _already_released -> :ok
    end
  end

  @doc false
  # Test/diagnostic accessor: number of currently held stall slots on this node.
  @spec active_stalls() :: integer()
  def active_stalls, do: :atomics.get(counter_ref(), 1)

  # Returns the single shared, signed `:atomics` counter created eagerly at boot
  # by `init_counter/0` (called from `Nebu.Application.start/2`). A pure,
  # race-free read — no lazy check-then-put on the hot path. Signed so an
  # accounting edge never wraps to a huge unsigned value that would wedge the
  # ceiling closed.
  defp counter_ref, do: :persistent_term.get(@pt_key)
end
