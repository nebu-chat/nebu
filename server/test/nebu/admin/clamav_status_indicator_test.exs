defmodule Nebu.Admin.ClamAVStatusIndicatorTest do
  @moduledoc """
  RED-phase acceptance tests for story
  `media-security-admin-control/10b-clamav-status-freshclam-age`.

  `Nebu.Admin.ClamAVStatusIndicator` does not exist yet — every test below
  fails with `UndefinedFunctionError` until dev-story implements
  `server/lib/nebu/admin/clamav_status_indicator.ex`, plus the accompanying
  extension of `Nebu.Media.ClamAV.health_check/0` (bare boolean ->
  `%{healthy:, changed_at:}`) and the new `Nebu.Media.ClamAV.signature_info/0`
  (see `clamav_test.exs` for the RED-phase tests pinning THAT module's own
  contract in isolation).

  Story: docs/stories/media-security-admin-control/10b-clamav-status-freshclam-age.md

  ## Split with `media_health_live_test.exs` (per the story's own File List)

  This file covers the story's Acceptance Tests **1, 2, 5, 6** at the
  "helper-level" (`Nebu.Admin.ClamAVStatusIndicator`'s own `status/0` and
  `assign_status/2`, not the rendered page). `media_health_live_test.exs`
  covers Acceptance Tests **1–4** end-to-end on `/admin/media/health`. AT1/
  AT2 (connected/disconnected) are intentionally exercised at BOTH layers;
  AT3/AT4 (signature-age copy) only at the LiveView layer (nothing about
  them branches differently at the helper level once AT1/AT2's
  connected/disconnected split is already proven here); AT5/AT6 (staleness
  boundary, malformed-reply degradation) only here, since both are pure
  properties of `assign_status/2`'s own threshold/error-handling logic and
  do not need a real rendered page to pin.

  ## Fake clamd

  Reuses `Nebu.Media.ClamAVFakeServer` (extended by this story for
  `zVERSION\\0` support — see `clamav_fake_server.exs`), exactly like
  `clamav_test.exs`: a real `:gen_tcp` listener, `Nebu.Media.ClamAV` started
  via `start_supervised!/1` pointed at its ephemeral port.

  ## Bare-socket pattern for `assign_status/2` (AT5/AT6)

  Mirrors `media_attention_badge_test.exs`'s own `socket_with_count/1`
  precedent for unit-testing a small `Phoenix.Component.assign/3`-based
  helper without a live LiveView process: a bare
  `%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, ...}}` struct is
  enough for `assign/3` to operate on.
  """

  use ExUnit.Case, async: false

  alias Nebu.Media.ClamAVFakeServer, as: FakeClamd
  alias Nebu.Admin.ClamAVStatusIndicator

  setup do
    on_exit(fn ->
      if pid = Process.whereis(Nebu.Media.ClamAV) do
        Process.exit(pid, :kill)
      end

      Application.delete_env(:nebu, Nebu.Media.ClamAV)
    end)

    :ok
  end

  defp start_clamav!(overrides) do
    base = [
      address: {:tcp, "127.0.0.1", 0},
      max_file_size_bytes: 100 * 1024 * 1024,
      signature_max_age_hours: 48
    ]

    config = Keyword.merge(base, overrides)
    Application.put_env(:nebu, Nebu.Media.ClamAV, config)

    start_supervised!(Nebu.Media.ClamAV)
  end

  defp closed_port! do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    :ok = :gen_tcp.close(listen_socket)
    port
  end

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  # ══════════════════════════════════════════════════════════════════════
  # AT1: connected state
  # ══════════════════════════════════════════════════════════════════════

  test "AT1: status/0 reports healthy: true and a fresh signature_age when ClamAV is connected" do
    fresh_build = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

    {:ok, fake} =
      FakeClamd.start(
        script: [fn socket -> :gen_tcp.send(socket, "stream: OK\0") end],
        version_reply: FakeClamd.format_version_reply(fresh_build)
      )

    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    # Establish the healthy transition before reading status/0 (mirrors
    # clamav_test.exs's own "successful round trip -> health_check reports
    # healthy" precedent).
    assert %{healthy: true} = Nebu.Media.ClamAV.health_check()

    status = ClamAVStatusIndicator.status()

    assert %{healthy: true, changed_at: %DateTime{}, signature_age: {:ok, signature_built_at}} =
             status

    # Tightened beyond type-shape: pins the VALUE to the fake's configured
    # build date, so a status/0 that hardcoded DateTime.utc_now() instead of
    # actually calling signature_info/0 would fail this test in isolation.
    assert DateTime.compare(signature_built_at, fresh_build) == :eq
  end

  # ══════════════════════════════════════════════════════════════════════
  # AT2: disconnected state
  # ══════════════════════════════════════════════════════════════════════

  test "AT2: status/0 reports healthy: false plus a down-since changed_at when ClamAV is unreachable" do
    port = closed_port!()

    start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

    status = ClamAVStatusIndicator.status()

    assert %{healthy: false, changed_at: %DateTime{} = changed_at, signature_age: {:error, _}} =
             status

    assert DateTime.compare(changed_at, DateTime.utc_now()) in [:eq, :lt]
  end

  test "status/0 degrades to a safe unhealthy default when the ClamAV client isn't running at all (mirrors WarRoomIndicator.status/0's Process.whereis guard)" do
    refute Process.whereis(Nebu.Media.ClamAV)

    status = ClamAVStatusIndicator.status()
    assert %{healthy: false} = status

    # Piped end-to-end through assign_status/2: proves the not-running guard
    # returns a status map with whatever changed_at/signature_age shape
    # assign_status/2 expects, so the guard->assign pipeline never raises
    # (e.g. if the not-running branch omitted either key, this pattern match
    # inside assign_status/2 would blow up here, not silently at runtime).
    socket = ClamAVStatusIndicator.assign_status(socket_with(%{}), status)
    assert socket.assigns.clamav_healthy == false
  end

  # ══════════════════════════════════════════════════════════════════════
  # assign_status/2 — all 4 documented assigns from one representative
  # status map. Only the signature-age assigns were otherwise pinned
  # directly at the helper level (AT5/AT6 below); :clamav_healthy and
  # :clamav_down_since were only exercised indirectly via LiveView-rendered
  # HTML in media_health_live_test.exs's AT1/AT2. This closes that gap.
  # ══════════════════════════════════════════════════════════════════════

  test "assign_status/2 sets all 4 documented assigns from a representative status map" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    changed_at = DateTime.add(now, -300, :second)
    built_at = DateTime.add(now, -1, :hour)

    status = %{healthy: false, changed_at: changed_at, signature_age: {:ok, built_at}}

    socket = ClamAVStatusIndicator.assign_status(socket_with(%{}), status)

    assert socket.assigns.clamav_healthy == false
    assert socket.assigns.clamav_down_since == changed_at
    assert socket.assigns.clamav_signature_age == {:ok, built_at}
    assert socket.assigns.clamav_signature_stale? == false
  end

  # ══════════════════════════════════════════════════════════════════════
  # AT5: signature-age staleness boundary — exactly at the default threshold
  # does not yet warn, one unit past it does. Pins `>`, not `>=`.
  # ══════════════════════════════════════════════════════════════════════

  describe "AT5: assign_status/2 signature staleness boundary" do
    setup do
      Application.put_env(:nebu, Nebu.Media.ClamAV,
        address: {:tcp, "127.0.0.1", 0},
        max_file_size_bytes: 100 * 1024 * 1024,
        signature_max_age_hours: 48
      )

      on_exit(fn -> Application.delete_env(:nebu, Nebu.Media.ClamAV) end)

      :ok
    end

    # NOTE (flagged deviation, see step report): the story's own "Threshold
    # comparison" pseudocode —
    #   DateTime.diff(DateTime.utc_now(), signature_built_at, :hour) > signature_max_age_hours
    # — uses integer HOUR-truncated diff, which CANNOT distinguish "48h-1s"
    # from "48h+1s": both truncate to a whole-hour count of 47/48
    # (172_799s -> 47h, 172_801s -> 48h), and 48 > 48 is false either way —
    # the "+1s past the threshold" case would silently fail to warn under
    # that literal formula. This test pins Acceptance Test 5's own prose
    # contract literally (48h-1s -> neutral, 48h+1s -> warning), which
    # dev-story's threshold check MUST satisfy at second-level precision
    # (e.g. diff in `:second` compared against `signature_max_age_hours * 3600`)
    # rather than the coarser hour-truncated pseudocode the story also
    # states — the AT5 prose is the authoritative behavior pin here.
    test "table: 48h-1s does not warn, 48h+1s warns" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      cases = [
        {DateTime.add(now, -(48 * 3600 - 1), :second), false},
        {DateTime.add(now, -(48 * 3600 + 1), :second), true}
      ]

      for {built_at, expected_stale?} <- cases do
        status = %{healthy: true, changed_at: now, signature_age: {:ok, built_at}}
        socket = ClamAVStatusIndicator.assign_status(socket_with(%{}), status)

        assert socket.assigns.clamav_signature_stale? == expected_stale?,
               "built_at #{inspect(built_at)} (#{DateTime.diff(now, built_at, :second)}s old) " <>
                 "expected stale?=#{expected_stale?}, got #{inspect(socket.assigns[:clamav_signature_stale?])}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AT6: malformed VERSION reply degrades gracefully (never a crash)
  # ══════════════════════════════════════════════════════════════════════

  test "AT6: a malformed/unparseable VERSION reply degrades assign_status to an unknown-age state, not a crash" do
    status = %{
      healthy: true,
      changed_at: DateTime.utc_now(),
      signature_age: {:error, {:clamd_error, "garbage"}}
    }

    socket = ClamAVStatusIndicator.assign_status(socket_with(%{}), status)

    # Design choice pinned here (not literally specified by the story): an
    # unparseable reply surfaces as :unknown, never as a raised exception
    # and never misclassified as "stale" (which would render the WRONG
    # warning copy instead of "Alter unbekannt") — mirrors Story 3 AC6's
    # "every failure mode is a tagged result, never a raised exception"
    # discipline extended to this new query path.
    assert socket.assigns.clamav_signature_age == :unknown
    assert socket.assigns.clamav_signature_stale? == false
  end
end
