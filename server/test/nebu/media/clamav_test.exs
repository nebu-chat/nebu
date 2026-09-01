defmodule Nebu.Media.ClamAVTest do
  @moduledoc """
  RED-phase acceptance tests for story
  `media-security-admin-control/3-clamav-genserver`.

  `Nebu.Media.ClamAV` does not exist yet — these tests are expected to fail
  with `UndefinedFunctionError` (module not available) until the dev-story
  step implements `server/lib/nebu/media/clamav.ex`. See ADR-024 and the
  story's Technical Requirements for the wire protocol this suite locks in.

  ## Fake clamd

  There is no Mox dependency in this project; `Nebu.Media.ClamAV` speaks a
  raw binary TCP protocol directly over `:gen_tcp`, so the fake boundary
  here is a REAL `:gen_tcp.listen/2` listener (`Nebu.Media.ClamAVFakeServer`,
  loaded via `Code.require_file/2` in `test_helper.exs`), not a function
  stub. Each test points `Nebu.Media.ClamAV`'s `address: {:tcp, host, port}`
  config at that fake listener's ephemeral port.

  ## Config surface (dev-story contract)

  AC2 pins `address` / `max_file_size_bytes`. AC6 requires every `:gen_tcp`
  call to have an explicit, "configurable-or-sane-default (e.g. 5000 ms)"
  timeout. This suite fixes `:connect_timeout_ms` / `:recv_timeout_ms` as the
  CANONICAL config keys for those two timeouts (both optional, defaulting to
  5000 ms when omitted) — this is not an open question left for dev-story to
  renegotiate; dev-story MUST implement the config keyword list with these
  exact key names so the recv-timeout test below (which overrides
  `recv_timeout_ms: 200` to avoid waiting 5s) exercises the real
  implementation rather than a test-only stand-in.

  ## Story 10b extension (`media-security-admin-control/10b-clamav-status-freshclam-age`)

  Two further RED-phase sections below extend this same module's contract
  for that story:

    * `health_check/0` grows from a bare boolean to
      `%{healthy: boolean(), changed_at: DateTime.t()}` (AC2) — the two
      PRE-EXISTING Story 3 assertions above were updated in place (not
      duplicated) to pattern-match the new shape, since a bare
      `assert`/`refute` on a map is not a meaningful check in Elixir (only
      `false`/`nil` are falsy) and would silently stop proving anything
      once this shape lands.
    * New `signature_info/0` sends `zVERSION\\0` over the same managed
      connection and parses the trailing build-date, returning
      `{:ok, DateTime.t()} | {:error, term()}`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Media.ClamAVFakeServer, as: FakeClamd

  setup do
    on_exit(fn ->
      # Defense-in-depth: start_supervised!/1 already stops the GenServer
      # after each test, but if a future partial implementation registers
      # the name outside start_supervised (e.g. a raw start_link/1 call),
      # make sure the singleton name is free before the next test claims it.
      if pid = Process.whereis(Nebu.Media.ClamAV) do
        Process.exit(pid, :kill)
      end

      Application.delete_env(:nebu, Nebu.Media.ClamAV)
    end)

    :ok
  end

  # -- AC3 / AC5: clean & infected round trips ---------------------------

  test "scan_binary/1 returns {:ok, :clean} for a clean-scan round trip" do
    handler = fn socket -> :gen_tcp.send(socket, "stream: OK\0") end
    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    # Multi-chunk payload (> 4096 bytes) so this also exercises reassembly
    # across chunk boundaries, not just a single short chunk.
    payload = :crypto.strong_rand_bytes(5_000)

    assert {:ok, :clean} = Nebu.Media.ClamAV.scan_binary(payload)

    raw = FakeClamd.received_bytes(fake, 0)
    assert reassemble_instream_payload(raw) == payload

    # AC7: a successful connect + scan round trip must report a healthy
    # state — a stub hardcoding health_check/0 to always return false would
    # fail this assertion (it currently only gets exercised by the
    # unreachable-at-init test, which only proves the UNHEALTHY branch).
    #
    # 10b (AC2) extends health_check/0's return shape from a bare boolean to
    # `%{healthy: boolean(), changed_at: DateTime.t()}` — a bare
    # `assert health_check()` would now vacuously pass for ANY map
    # (including `%{healthy: false, ...}`, since only `false`/`nil` are
    # falsy in Elixir), so this pattern-matches the new shape instead.
    assert %{healthy: true, changed_at: %DateTime{}} = Nebu.Media.ClamAV.health_check()
  end

  test "scan_binary/1 returns {:ok, {:infected, signature}} when clamd flags a signature" do
    handler = fn socket ->
      :gen_tcp.send(socket, "stream: Eicar-Test-Signature FOUND\0")
    end

    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    eicar_payload = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR"

    assert {:ok, {:infected, "Eicar-Test-Signature"}} =
             Nebu.Media.ClamAV.scan_binary(eicar_payload)

    # Guards against a pathological implementation that special-cases the
    # EICAR string instead of actually sending it over the wire: assert the
    # fake received the real payload, correctly INSTREAM-framed.
    raw = FakeClamd.received_bytes(fake, 0)
    assert reassemble_instream_payload(raw) == eicar_payload
  end

  # -- AC4: file-size ceiling, no connection at all -----------------------

  test "scan_binary/1 returns {:error, :file_too_large} without connecting" do
    {:ok, fake} = FakeClamd.start()
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 10)

    big_payload = :binary.copy(<<0>>, 11)

    assert {:error, :file_too_large} = Nebu.Media.ClamAV.scan_binary(big_payload)
    assert FakeClamd.accept_count(fake) == 0
  end

  # -- AC6: every :gen_tcp failure mode is a tagged error, never a raise --

  test "scan_binary/1 returns {:error, reason} on connect refused" do
    port = closed_port!()

    start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

    assert {:error, _reason} = Nebu.Media.ClamAV.scan_binary("some bytes")
  end

  test "scan_binary/1 returns {:error, reason} on recv timeout" do
    # Fake clamd fully drains the INSTREAM request, then never replies.
    handler = fn _socket -> Process.sleep(:infinity) end
    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(
      address: {:tcp, "127.0.0.1", fake.port},
      max_file_size_bytes: 1_000_000,
      recv_timeout_ms: 200
    )

    {elapsed_us, result} = :timer.tc(fn -> Nebu.Media.ClamAV.scan_binary("payload") end)

    # Exact tagged reason per the story's Technical Requirements
    # ("recv timeout / closed → {:error, :timeout} / {:error, :connection_closed}").
    assert {:error, :timeout} = result
    # Must return promptly on its own internal recv timeout budget, not hang
    # indefinitely (AC6/AC8: the GenServer.call itself has a bigger budget
    # than the internal recv timeout, but that budget is still bounded).
    assert elapsed_us < 2_000_000
  end

  test "scan_binary/1 returns {:error, reason} on malformed clamd response" do
    handler = fn socket ->
      :gen_tcp.send(socket, "this is not a clamd protocol line at all\n")
    end

    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    # Exact tagged reason per the story's Technical Requirements
    # ("unrecognized/malformed response line → {:error, {:clamd_error, message}}").
    assert {:error, {:clamd_error, _message}} = Nebu.Media.ClamAV.scan_binary("payload")
  end

  # -- AC8: auto-reconnect after a connection drop ------------------------

  test "connection drop triggers reconnect on the next scan_binary/1 call" do
    # Real clamd closes the connection after each INSTREAM session; the
    # SECOND call must not reuse the now-dead socket, it must reconnect
    # (a fresh accept on the fake listener) and still succeed.
    drop_after_reply = fn socket ->
      :gen_tcp.send(socket, "stream: OK\0")
      :gen_tcp.close(socket)
    end

    {:ok, fake} = FakeClamd.start(script: [drop_after_reply, drop_after_reply])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    assert {:ok, :clean} = Nebu.Media.ClamAV.scan_binary("first payload")
    assert {:ok, :clean} = Nebu.Media.ClamAV.scan_binary("second payload")

    assert FakeClamd.accept_count(fake) == 2
  end

  # -- AC7: health-check reflects unreachable clamd at init ---------------

  test "health_check/0 reflects unreachable clamd at init" do
    port = closed_port!()

    log =
      capture_log(fn ->
        pid = start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

        # init/1 must still return {:ok, state} — the process is alive, the
        # supervision tree did not crash just because clamd isn't up yet.
        assert Process.alive?(pid)

        # 10b (AC2): health_check/0 returns %{healthy:, changed_at:} now,
        # not a bare boolean — a bare `refute health_check()` would now
        # always PASS regardless of :healthy's value (a map is truthy in
        # Elixir), silently no longer proving the unhealthy branch at all.
        assert %{healthy: false, changed_at: %DateTime{}} = Nebu.Media.ClamAV.health_check()
      end)

    # A Logger.warning/1 about the unreachable clamd connection was emitted
    # (exact wording is a dev-story choice; "clam" matches both "ClamAV" and
    # "clamd").
    assert log =~ ~r/clam/i
  end

  # -- 10b/AC2: health_check/0's changed_at tracks TRANSITIONS only -------
  # (media-security-admin-control/10b-clamav-status-freshclam-age)

  test "health_check/0's changed_at does not move across repeated calls while unhealthy stays unhealthy" do
    port = closed_port!()

    start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

    assert %{healthy: false, changed_at: changed_at_1} = Nebu.Media.ClamAV.health_check()
    Process.sleep(20)
    assert %{healthy: false, changed_at: changed_at_2} = Nebu.Media.ClamAV.health_check()

    # No flip (false -> false) happened between the two calls, so changed_at
    # must be the SAME timestamp both times, not "now" on every read (AC2:
    # a dashboard/GenServer that re-derives "down since" on every poll would
    # undercount true outage duration).
    assert DateTime.compare(changed_at_1, changed_at_2) == :eq
  end

  test "health_check/0's changed_at updates to a fresh timestamp exactly when healthy flips from false to true" do
    handler = fn socket -> :gen_tcp.send(socket, "stream: OK\0") end
    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    before_start = DateTime.utc_now()

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    # First call: init's healthy:false flips to true on this successful
    # connect -> changed_at must be a fresh transition timestamp (at/after
    # the moment this GenServer was started), not carried over from init.
    assert %{healthy: true, changed_at: changed_at_1} = Nebu.Media.ClamAV.health_check()
    assert DateTime.compare(changed_at_1, before_start) in [:eq, :gt]

    Process.sleep(20)

    # Second call: still healthy, no flip -> changed_at must stay put.
    assert %{healthy: true, changed_at: changed_at_2} = Nebu.Media.ClamAV.health_check()
    assert DateTime.compare(changed_at_1, changed_at_2) == :eq
  end

  # -- 10b/Technical Requirements #2: signature_info/0 (new zVERSION query) --
  # (media-security-admin-control/10b-clamav-status-freshclam-age)
  #
  # `Nebu.Media.ClamAV.signature_info/0` does not exist yet — every test in
  # this section fails with `UndefinedFunctionError` until dev-story adds it.

  test "signature_info/0 returns {:ok, %DateTime{}} parsed from a well-formed VERSION reply" do
    build_date = DateTime.new!(~D[2026-07-19], ~T[06:24:00], "Etc/UTC")
    reply = FakeClamd.format_version_reply(build_date)

    {:ok, fake} = FakeClamd.start(version_reply: reply)
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    assert {:ok, parsed} = Nebu.Media.ClamAV.signature_info()
    assert DateTime.compare(parsed, build_date) == :eq
  end

  test "signature_info/0 returns {:error, reason} for a malformed VERSION reply that doesn't match engine/db/date" do
    {:ok, fake} = FakeClamd.start(version_reply: "not a clamd version string at all\0")
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    assert {:error, _reason} = Nebu.Media.ClamAV.signature_info()
  end

  test "signature_info/0 returns {:error, reason} on connect refused, mirroring scan_binary/1's own contract" do
    port = closed_port!()

    start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

    assert {:error, _reason} = Nebu.Media.ClamAV.signature_info()
  end

  # -- AC5: exact INSTREAM wire framing ------------------------------------

  test "INSTREAM chunk framing uses 4-byte big-endian length prefix, 4096-byte chunks, zero-length terminator" do
    handler = fn socket -> :gen_tcp.send(socket, "stream: OK\0") end
    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    # 2 full 4096-byte chunks + a shorter final 100-byte chunk.
    payload = :crypto.strong_rand_bytes(4096 * 2 + 100)

    assert {:ok, :clean} = Nebu.Media.ClamAV.scan_binary(payload)

    raw = FakeClamd.received_bytes(fake, 0)

    assert <<
             "zINSTREAM\0",
             chunk1_len::32-big,
             chunk1::binary-size(4096),
             chunk2_len::32-big,
             chunk2::binary-size(4096),
             chunk3_len::32-big,
             chunk3::binary-size(100),
             terminator::32-big
           >> = raw

    assert chunk1_len == 4096
    assert chunk2_len == 4096
    assert chunk3_len == 100
    assert terminator == 0
    assert chunk1 <> chunk2 <> chunk3 == payload
  end

  # -- AC9: no PII/content in logs ----------------------------------------

  test "scan_binary/1 never logs the scanned binary's content" do
    handler = fn socket -> :gen_tcp.send(socket, "stream: OK\0") end
    {:ok, fake} = FakeClamd.start(script: [handler])
    on_exit(fn -> FakeClamd.stop(fake) end)

    start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

    # A unique, unlikely-to-collide marker embedded in the scanned payload.
    # If any log statement ever includes the raw binary (or a slice/inspect
    # of it), this marker will leak into the captured log output.
    marker = "MARKER-" <> Base.encode16(:crypto.strong_rand_bytes(16))
    payload = "some file content prefix " <> marker <> " some file content suffix"

    log =
      capture_log(fn ->
        assert {:ok, :clean} = Nebu.Media.ClamAV.scan_binary(payload)
      end)

    refute log =~ marker
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10e-trace-map-war-room-integration (AC1):
  # connect/disconnect/health-check-state-transition Logger calls must carry
  # route_template: "/media/clamav" (and no request_id — these are
  # pipeline-wide events, not tied to one file), passed as 2-arity call-site
  # metadata (`Logger.warning/info(message, metadata)`), NEVER via
  # `Logger.metadata/1` (this GenServer's process is long-lived and serves
  # many unrelated calls, so setting process-dictionary metadata once would
  # leak stale route_template onto whatever it logs next for a different
  # reason).
  #
  # Observed the same way `request_logger_test.exs`'s own M2 regression does
  # (see that file's "M2: method/status/duration_ms reach
  # Handler.parse_log_event/1's metadata map" describe block): attach the
  # REAL `Nebu.Web.LogStore.Handler`, subscribe to the "operational_logs"
  # PubSub topic, and inspect the broadcast entry's top-level
  # `:route_template`/`:request_id` fields — `Handler.parse_log_event/1`
  # extracts these OUT of `:metadata` into their own columns (see
  # `@drop_meta_keys` in handler.ex), so a plain `capture_log` text-matching
  # assertion (as every OTHER test in this file uses) cannot observe them.
  #
  # ## Why these MUST FAIL right now
  #
  # `handle_call(:health_check, ...)`'s existing `Logger.warning/1` call
  # (line ~171 in clamav.ex) passes NO metadata at all today, and there is no
  # log call whatsoever on a successful (re)connect / healthy state
  # transition — every assertion below fails until dev-story adds
  # `route_template: "/media/clamav"` metadata to the existing warning AND
  # adds a new log call on the connect/reconnect transition.
  # ══════════════════════════════════════════════════════════════════════════

  describe "10e AC1: ClamAV GenServer events carry Trace-Map metadata" do
    # code-review cycle 2 (MAJOR-2): the healthy-transition log this describe
    # block exercises now fires via Logger.info/2 (not :warning — see MAJOR-1/
    # MAJOR-2's fix in clamav.ex), so this level bump is required for these
    # tests to actually observe it; config/test.exs's primary Logger level
    # (:warning) would otherwise silently drop it before it ever reaches
    # Nebu.Web.LogStore.Handler. Mirrors request_logger_test.exs's own
    # Logger.configure(level: :info)/on_exit restore idiom, scoped narrowly to
    # just this describe block (not the whole file).
    setup do
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    defp ensure_pubsub_started! do
      case Process.whereis(Nebu.PubSub) do
        nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
        _pid -> :ok
      end
    end

    defp attach_log_capture! do
      ensure_pubsub_started!()
      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")
    end

    defp drain_log_entries(acc \\ []) do
      receive do
        msg -> drain_log_entries([msg | acc])
      after
        500 -> Enum.reverse(acc)
      end
    end

    test "health_check/0 against an unreachable clamd logs an operational entry with route_template \"/media/clamav\" and no request_id" do
      attach_log_capture!()

      port = closed_port!()
      start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

      assert %{healthy: false} = Nebu.Media.ClamAV.health_check()

      entries = drain_log_entries()

      entry =
        Enum.find(entries, fn
          %{route_template: "/media/clamav"} -> true
          _ -> false
        end)

      refute is_nil(entry),
             "expected an operational_logs entry with route_template \"/media/clamav\" for the " <>
               "unreachable-clamd health_check warning, got: #{inspect(entries)}"

      assert is_nil(entry.request_id),
             "a pipeline-wide ClamAV event must carry no request_id (not tied to one file), " <>
               "got: #{inspect(entry)}"
    end

    test "a successful connect logs route_template \"/media/clamav\" once on the healthy transition, not again on a second already-healthy poll" do
      # code-review cycle 2 (MAJOR-1): strengthens this test to actually prove
      # the transition-gated fix — two consecutive health_check/0 calls
      # against a reachable fake clamd must produce exactly ONE
      # "/media/clamav" log entry (the first call's false -> true flip), not
      # one per call. No `script:` handler is needed: health_check/0 never
      # sends any protocol bytes (only `scan_binary/1`/`signature_info/0` do)
      # — a bare, accepted TCP connection is sufficient for `connect/1` to
      # succeed and flip `healthy` to true.
      {:ok, fake} = FakeClamd.start()
      on_exit(fn -> FakeClamd.stop(fake) end)

      attach_log_capture!()

      start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

      # First call: socket nil -> connect succeeds -> healthy flips false -> true.
      assert %{healthy: true} = Nebu.Media.ClamAV.health_check()

      entries_after_first = drain_log_entries()

      entry =
        Enum.find(entries_after_first, fn
          %{route_template: "/media/clamav"} -> true
          _ -> false
        end)

      refute is_nil(entry),
             "expected an operational_logs entry with route_template \"/media/clamav\" logged " <>
               "on the healthy transition, got: #{inspect(entries_after_first)}"

      assert is_nil(entry.request_id),
             "a pipeline-wide ClamAV event must carry no request_id, got: #{inspect(entry)}"

      # Second call: socket already open, no transition (still healthy) -> the
      # MAJOR-1 fix must NOT log again.
      assert %{healthy: true} = Nebu.Media.ClamAV.health_check()

      entries_after_second = drain_log_entries()

      refute Enum.any?(entries_after_second, fn
               %{route_template: "/media/clamav"} -> true
               _ -> false
             end),
             "expected NO additional \"/media/clamav\" log entry on a second, already-healthy " <>
               "poll (MAJOR-1: the healthy-transition log must be transition-gated, not " <>
               "logged on every health_check/0 call), got: #{inspect(entries_after_second)}"
    end
  end

  # -- helpers -------------------------------------------------------------

  # Starts Nebu.Media.ClamAV with the given config (merged over sane
  # defaults), registered under its module name as start_supervised!/1
  # requires (AC1). ExUnit tears it down automatically after the test.
  defp start_clamav!(overrides) do
    base = [
      address: {:tcp, "127.0.0.1", 0},
      max_file_size_bytes: 100 * 1024 * 1024
    ]

    config = Keyword.merge(base, overrides)
    Application.put_env(:nebu, Nebu.Media.ClamAV, config)

    start_supervised!(Nebu.Media.ClamAV)
  end

  # Binds an ephemeral TCP port and immediately closes the listener, giving
  # back a port number that is real (won't collide with another test) but
  # has nothing listening on it — connecting there reliably yields
  # ECONNREFUSED, without hardcoding a port number that might be in use.
  defp closed_port! do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    :ok = :gen_tcp.close(listen_socket)
    port
  end

  defp reassemble_instream_payload(<<"zINSTREAM\0", rest::binary>>) do
    reassemble_chunks(rest, <<>>)
  end

  defp reassemble_chunks(<<0::32>>, acc), do: acc

  defp reassemble_chunks(<<len::32, chunk::binary-size(len), rest::binary>>, acc) do
    reassemble_chunks(rest, acc <> chunk)
  end
end
