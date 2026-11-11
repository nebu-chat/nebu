defmodule Nebu.Media.DownloadStallSlotsTest do
  @moduledoc """
  Exactly-once stall-slot accounting for `Nebu.Media.DownloadStall`
  (`bugfix/media-download-451-scan-race`, review cycle 2, security F-1): the
  slot is tied to the requesting process's lifetime, so an exit signal that
  skips `try/after` (Bandit HTTP/2 client disconnect) cannot leak it, and the
  counter is never decremented twice.
  """
  use ExUnit.Case, async: false

  alias Nebu.Media.DownloadStall

  setup do
    base = DownloadStall.active_stalls()
    {:ok, base: base}
  end

  defp mid, do: "slots-#{System.unique_integer([:positive])}"

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.reduce_while(nil, fn ok?, _ ->
      cond do
        ok? -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> flunk("condition not reached within #{timeout_ms}ms")
        true -> Process.sleep(5) && {:cont, nil}
      end
    end)
  end

  test "killed requester frees its slot; ceiling of 1 stays usable", %{base: base} do
    parent = self()

    victim =
      spawn(fn ->
        DownloadStall.await(mid(), 5_000, base + 1, fn ->
          send(parent, :in_stall)
          :scanning
        end)
      end)

    assert_receive :in_stall, 1_000
    assert DownloadStall.active_stalls() == base + 1

    # Ceiling reached: a concurrent request is refused without waiting.
    assert DownloadStall.await(mid(), 100, base + 1, fn -> :scanning end) == :no_slot
    assert DownloadStall.active_stalls() == base + 1

    Process.exit(victim, :kill)
    wait_until(fn -> DownloadStall.active_stalls() == base end)

    assert DownloadStall.await(mid(), 50, base + 1, fn -> :scanning end) == :timeout
    assert DownloadStall.active_stalls() == base
  end

  test "linked process dying with {:shutdown, :peer_closed} (Bandit h2) frees the slot", %{base: base} do
    parent = self()

    victim =
      spawn(fn ->
        DownloadStall.await(mid(), 5_000, base + 1, fn ->
          send(parent, :in_stall)
          :scanning
        end)
      end)

    assert_receive :in_stall, 1_000
    Process.exit(victim, {:shutdown, :peer_closed})
    wait_until(fn -> DownloadStall.active_stalls() == base end)
  end

  test "normal completion releases exactly once; counter never goes negative", %{base: base} do
    for _ <- 1..50 do
      assert DownloadStall.await(mid(), 100, base + 5, fn -> :released end) == :resolved
      assert DownloadStall.active_stalls() == base
    end

    # Late keeper shutdown / any stray :DOWN must not double-decrement.
    Process.sleep(50)
    assert DownloadStall.active_stalls() == base
  end

  test "timeout path releases exactly once", %{base: base} do
    assert DownloadStall.await(mid(), 50, base + 1, fn -> :scanning end) == :timeout
    assert DownloadStall.active_stalls() == base
    Process.sleep(30)
    assert DownloadStall.active_stalls() == base
  end

  test "raising recheck releases exactly once", %{base: base} do
    assert DownloadStall.await(mid(), 100, base + 1, fn -> raise "boom" end) == :timeout
    assert DownloadStall.active_stalls() == base
    Process.sleep(30)
    assert DownloadStall.active_stalls() == base
  end

  test "no_slot path leaves the counter untouched", %{base: base} do
    parent = self()

    holder =
      spawn(fn ->
        DownloadStall.await(mid(), 5_000, base + 1, fn ->
          send(parent, :in_stall)
          :scanning
        end)
      end)

    assert_receive :in_stall, 1_000

    for _ <- 1..20 do
      assert DownloadStall.await(mid(), 100, base + 1, fn -> :scanning end) == :no_slot
      assert DownloadStall.active_stalls() == base + 1
    end

    Process.exit(holder, :kill)
    wait_until(fn -> DownloadStall.active_stalls() == base end)
  end

  test "a caller that raises out of await after the slot (exit in own process) frees the slot", %{base: base} do
    parent = self()

    pid =
      spawn(fn ->
        DownloadStall.await(mid(), 5_000, base + 1, fn ->
          send(parent, :in_stall)
          :scanning
        end)
      end)

    assert_receive :in_stall, 1_000
    ref = Process.monitor(pid)
    Process.exit(pid, :boom)
    assert_receive {:DOWN, ^ref, :process, ^pid, :boom}, 1_000
    wait_until(fn -> DownloadStall.active_stalls() == base end)
  end

  # Cycle 3 M-2: a non-integer / non-positive ceiling fails CLOSED (:no_slot,
  # no wait, no counter leak) instead of silently disabling the ceiling.
  for {label, bad} <- [string: "500", nil: nil, zero: 0, negative: -3, float: 5.0] do
    test "invalid max_concurrent (#{label}) => :no_slot, no stall, counter unchanged", %{base: base} do
      parent = self()

      assert DownloadStall.await(mid(), 100, unquote(Macro.escape(bad)), fn ->
               send(parent, :recheck_called)
               :scanning
             end) == :no_slot

      refute_received :recheck_called
      assert DownloadStall.active_stalls() == base
      Process.sleep(20)
      assert DownloadStall.active_stalls() == base
    end
  end

  # Cycle 3 M-1 (keeper killed after claim=1 but before/while replying): the
  # keeper pid is private to acquire_slot/1 and the window is a few
  # instructions wide, so it cannot be hit deterministically without adding a
  # test seam to production code. Not worth it; the fix (release_claim/2 in the
  # :DOWN branch) is idempotent and covered indirectly by the exactly-once tests.
end
