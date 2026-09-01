defmodule Nebu.Media.ClamAVFakeServer do
  @moduledoc """
  A REAL `:gen_tcp` listener standing in for `clamd`, for `clamav_test.exs`
  (story `media-security-admin-control/3-clamav-genserver`) and, since
  story `media-security-admin-control/10b-clamav-status-freshclam-age`,
  also for `clamav_status_indicator_test.exs` / `media_health_live_test.exs`
  (the new `zVERSION\\0` query).

  There is no Mox dependency in this project (see `media_fakes.exs` for the
  established "function-backed fake boundary" convention used elsewhere in
  `Nebu.Media` tests). `Nebu.Media.ClamAV` speaks a raw binary TCP protocol
  (ClamAV's INSTREAM framing, and now the one-shot `VERSION` command)
  directly over `:gen_tcp` — there is no function boundary to inject a fake
  behind, so the equivalent fake for this story is a real socket: an actual
  `:gen_tcp.listen/2` on an ephemeral 127.0.0.1 port, driven by a small
  per-connection response "script" the test controls.

  ## Usage (INSTREAM, Story 3)

      {:ok, fake} = Nebu.Media.ClamAVFakeServer.start(script: [
        fn socket -> :gen_tcp.send(socket, "stream: OK\\0") end
      ])

      # fake.port is the ephemeral port to point `Nebu.Media.ClamAV`'s
      # `address: {:tcp, "127.0.0.1", fake.port}` config at.

      Nebu.Media.ClamAVFakeServer.accept_count(fake)
      Nebu.Media.ClamAVFakeServer.received_bytes(fake, 0)
      Nebu.Media.ClamAVFakeServer.stop(fake)

  Each accepted connection is handed to the next handler fun in `:script`
  (the last entry repeats for any additional connections beyond the script's
  length — useful when a test only cares about the first N connections).
  Before the handler runs, the fake fully drains the client's INSTREAM
  request (the `zINSTREAM\\0` greeting, every `<<len::32, chunk::binary>>`
  frame, and the terminating `<<0::32>>`) and records the exact raw bytes
  received so tests can assert on wire-level framing (AC5 / chunk-framing
  test). The handler then decides what (if anything) to send back, and may
  close the socket to simulate a dropped connection (AC8 reconnect test).

  ## Usage (VERSION, Story 10b)

      {:ok, fake} = Nebu.Media.ClamAVFakeServer.start(
        version_reply: Nebu.Media.ClamAVFakeServer.format_version_reply(build_datetime)
      )

  A single fake listener serves BOTH protocols: each accepted connection is
  dispatched based on the client's own opening command line (`zINSTREAM\\0`
  vs. `zVERSION\\0`, read byte-by-byte until the NUL terminator, since the
  two commands are different lengths — 10 vs. 9 bytes — so a fixed-size
  greeting read, as Story 3's original implementation used, cannot frame
  both). This mirrors the real dev-stack `clamd`, which serves every command
  over the same TCP port and — per this story's own protocol verification —
  closes the connection after a one-shot `zVERSION\\0` reply, exactly like
  it does after an INSTREAM session; `Nebu.Media.ClamAV`'s existing
  lazy-reconnect-on-next-use machinery (Story 3, AC8) is reused for
  `signature_info/0` rather than a second connection.

  `:version_reply` may be a raw binary (sent verbatim, so malformed/
  unparseable replies for the "degrades gracefully" acceptance test are
  just any string that doesn't match the real `engine/db/build-date` shape)
  or a 1-arity fun `(socket -> any())` for tests that need finer control
  (e.g. closing the connection without replying at all).
  """

  # Verified against the real `clamav/clamav:stable` dev-stack container
  # (see _bmad-output/nebu/epics/media-security-admin-control/step-results/
  # 10b-clamav-status-freshclam-age/clamav-version-protocol-verification.md):
  # a single NUL-terminated line, "ClamAV <engine>/<db>/<build-date>", where
  # <build-date> is C-`asctime`-style with no timezone (treated as UTC).
  @default_version_reply "ClamAV 1.5.3/28065/Sun Jul 19 06:24:00 2026\0"

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Starts a fake clamd on an ephemeral 127.0.0.1 TCP port.

  Options:
    * `:script` — list of `(socket -> any)` handler funs for INSTREAM
      connections, one per expected accepted connection (the last one
      repeats for extra connections). Defaults to a single handler that
      replies `stream: OK\\0`.
    * `:version_reply` — binary or `(socket -> any)` fun used to answer a
      `zVERSION\\0` connection. Defaults to a well-formed reply (see
      `format_version_reply/2`).

  Returns `{:ok, %{agent: pid, accept_pid: pid, listen_socket: socket, port: non_neg_integer}}`.
  """
  def start(opts \\ []) do
    script = Keyword.get(opts, :script, [&default_handler/1])
    version_reply = Keyword.get(opts, :version_reply, @default_version_reply)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{accept_count: 0, received: %{}, handler_pids: [], version_request_count: 0}
      end)

    accept_pid = spawn(fn -> accept_loop(listen_socket, script, version_reply, agent, 0) end)

    {:ok,
     %{
       agent: agent,
       accept_pid: accept_pid,
       listen_socket: listen_socket,
       port: port
     }}
  end

  @doc """
  Stops the fake listener, its accept loop, and every per-connection handler
  task spawned so far (e.g. a `Process.sleep(:infinity)` handler used by the
  recv-timeout test) so no orphaned process or open socket survives past the
  test that started this fake.
  """
  def stop(%{listen_socket: listen_socket, accept_pid: accept_pid, agent: agent}) do
    :gen_tcp.close(listen_socket)
    if Process.alive?(accept_pid), do: Process.exit(accept_pid, :kill)

    if Process.alive?(agent) do
      handler_pids = Agent.get(agent, & &1.handler_pids)

      Enum.each(handler_pids, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      Agent.stop(agent)
    end

    :ok
  end

  @doc "Number of TCP connections accepted so far (INSTREAM + VERSION combined)."
  def accept_count(%{agent: agent}), do: Agent.get(agent, & &1.accept_count)

  @doc "Number of `zVERSION\\0` connections handled so far."
  def version_request_count(%{agent: agent}), do: Agent.get(agent, & &1.version_request_count)

  @doc """
  Raw bytes received (full INSTREAM wire protocol, including the
  `zINSTREAM\\0` greeting, every 4-byte length prefix, and the terminating
  `<<0::32>>`) for the `index`-th accepted INSTREAM connection (0-based;
  VERSION connections do not count towards this index).
  Returns `<<>>` if that connection hasn't sent anything (yet).
  """
  def received_bytes(%{agent: agent}, index \\ 0) do
    Agent.get(agent, fn state -> Map.get(state.received, index, <<>>) end)
  end

  @doc """
  Builds a realistic `zVERSION\\0` reply string
  (`"ClamAV <engine>/<db_version>/<asctime>\\0"`) for the given UTC
  `datetime`, for tests that need to control the reported signature
  build-date precisely (AC3/AC4/AT3-5). `opts` may override `:engine`
  (default `"1.5.3"`) and `:db_version` (default `"28065"`) — irrelevant
  to this story's parsing beyond "some non-empty segment", but kept
  realistic.
  """
  def format_version_reply(%DateTime{} = datetime, opts \\ []) do
    engine = Keyword.get(opts, :engine, "1.5.3")
    db_version = Keyword.get(opts, :db_version, "28065")

    "ClamAV #{engine}/#{db_version}/#{format_asctime(datetime)}\0"
  end

  @doc """
  Formats `datetime` (assumed already UTC) in clamd's own C-`asctime` style
  (`"%a %b %e %H:%M:%S %Y"`), e.g. `"Sun Jul 19 06:24:00 2026"` — no
  timezone; day-of-month is SPACE-padded to width 2 for single-digit days
  (`%e`, e.g. " 9"), matching real `asctime` output rather than
  zero-padding it (which real clamd/asctime never does).
  """
  def format_asctime(%DateTime{} = datetime) do
    day_name = Enum.at(@days, Date.day_of_week(datetime) - 1)
    month_name = Enum.at(@months, datetime.month - 1)
    day = datetime.day |> Integer.to_string() |> String.pad_leading(2)

    "#{day_name} #{month_name} #{day} #{pad2(datetime.hour)}:#{pad2(datetime.minute)}:#{pad2(datetime.second)} #{datetime.year}"
  end

  # -- internals --------------------------------------------------------

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp default_handler(socket), do: :gen_tcp.send(socket, "stream: OK\0")

  defp accept_loop(listen_socket, script, version_reply, agent, index) do
    case :gen_tcp.accept(listen_socket, 2_000) do
      {:ok, socket} ->
        Agent.update(agent, fn s -> %{s | accept_count: s.accept_count + 1} end)

        {:ok, handler_pid} =
          Task.start(fn -> dispatch_connection(socket, script, version_reply, agent, index) end)

        Agent.update(agent, fn s -> %{s | handler_pids: [handler_pid | s.handler_pids]} end)

        accept_loop(listen_socket, script, version_reply, agent, index + 1)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen_socket, script, version_reply, agent, index)
    end
  end

  # Peeks the client's opening command line (read byte-by-byte until the
  # NUL terminator, since "zINSTREAM\0" and "zVERSION\0" are different
  # lengths) and dispatches to the matching protocol handling. An
  # INSTREAM connection still counts towards `received_bytes/2`'s `index`
  # (VERSION connections are excluded from that index, matching the
  # pre-existing Story 3 test suite's own indexing, which only ever sees
  # INSTREAM connections).
  defp dispatch_connection(socket, script, version_reply, agent, index) do
    case recv_command_name(socket) do
      {:ok, "zVERSION\0"} ->
        Agent.update(agent, fn s -> %{s | version_request_count: s.version_request_count + 1} end)
        send_version_reply(socket, version_reply)

      {:ok, "zINSTREAM\0" = greeting} ->
        full_bytes = recv_chunks(socket, greeting)
        Agent.update(agent, fn s -> %{s | received: Map.put(s.received, index, full_bytes)} end)
        handler = Enum.at(script, index) || List.last(script) || (&default_handler/1)
        handler.(socket)

      {:ok, _other} ->
        # Unrecognized opening command — close rather than hang forever;
        # no test in this suite currently sends anything else.
        :gen_tcp.close(socket)

      {:error, _reason} ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Bug fix (10b dev-story): the moduledoc above documents that this fake
  # "closes the connection after a one-shot zVERSION\0 reply, exactly like
  # [real clamd] does after an INSTREAM session" — the real dev-stack
  # container was verified to do exactly that. The binary-reply clause here
  # previously didn't actually close the socket, which is silently correct
  # for a SINGLE zVERSION round trip in isolation but breaks any scenario
  # that queries `signature_info/0` twice over what would, against real
  # clamd, be two separate one-shot connections — e.g. Phoenix LiveView's
  # ordinary "static/dead render, then connected mount" double-`mount/3`
  # call, which is exactly what `media_health_live_test.exs`'s AT3/AT4
  # exercise. Without this close, the second `zVERSION\0` on the reused
  # socket has no reader on the fake side (its one-shot dispatch task
  # already returned) and the client-side call stalls until its own recv
  # timeout instead of promptly detecting a closed connection and
  # reconnecting (`Nebu.Media.ClamAV`'s existing lazy-reconnect-on-next-use
  # machinery, Story 3 AC8, reused here per this story's own guardrail).
  # A function-based reply keeps full control (e.g. a test that wants to
  # simulate "closes without ever replying") — only the common binary case
  # auto-closes.
  defp send_version_reply(socket, reply) when is_binary(reply) do
    :gen_tcp.send(socket, reply)
    :gen_tcp.close(socket)
  end

  defp send_version_reply(socket, reply) when is_function(reply, 1), do: reply.(socket)

  defp recv_command_name(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 1, 5_000) do
      {:ok, <<0>> = zero} -> {:ok, acc <> zero}
      {:ok, byte} -> recv_command_name(socket, acc <> byte)
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_chunks(socket, acc) do
    case :gen_tcp.recv(socket, 4, 5_000) do
      {:ok, <<0::32>> = zero_prefix} ->
        acc <> zero_prefix

      {:ok, <<len::32>> = prefix} when len > 0 ->
        case :gen_tcp.recv(socket, len, 5_000) do
          {:ok, chunk} -> recv_chunks(socket, acc <> prefix <> chunk)
          {:error, _reason} -> acc <> prefix
        end

      {:error, _reason} ->
        acc
    end
  end
end
