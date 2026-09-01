defmodule Nebu.Media.ClamAV do
  @moduledoc """
  TCP client for the ClamAV `clamd` daemon, speaking the `INSTREAM` protocol
  directly over `:gen_tcp` (ADR-021 — no NIF, no shell-out, no new TCP client
  dependency; ADR-024 — self-hosted malware scanning, no file content leaves
  the deployment).

  Story `media-security-admin-control/3-clamav-genserver`. This module is the
  standalone scanner boundary; it does not implement the Oban worker that
  drives the `media_files` state machine (Story 4b, `MediaScanWorker`) and it
  never touches a file path — `scan_binary/1` operates exclusively on an
  in-memory binary the caller has already fetched/decrypted/decompressed
  (`Nebu.Media.Storage` / `Nebu.Media.Crypto`, Story 12.x).

  ## Configuration

      config :nebu, Nebu.Media.ClamAV,
        address: {:tcp, "127.0.0.1", 3310},
        max_file_size_bytes: 100 * 1024 * 1024,
        connect_timeout_ms: 5_000,   # optional, defaults to 5000
        recv_timeout_ms: 5_000       # optional, defaults to 5000

  Only the `{:tcp, host, port}` address shape is implemented; `{:unix, path}`
  is a documented, not-yet-implemented future option (AC2) and is out of scope
  for this story.

  ## Connection lifecycle

  A single named GenServer process serializes scan calls against one clamd
  TCP connection (no pool, matching the epic's "S" sizing). The socket is
  connected lazily on first use and reused across calls; any detected
  transport error (send/recv failure, peer close, recv timeout) closes and
  clears the socket so the connection is re-established — retried once,
  transparently, within the very call that discovered the drop, so a caller
  never has to know about TCP reconnects (AC8).

  `init/1` deliberately does NOT open an eager connection at boot: `scan_binary/1`'s
  file-size guard (AC4) must return `{:error, :file_too_large}` "without opening
  a TCP connection at all", which a proactive init-time health probe would
  violate whenever clamd happens to be reachable. `health_check/0` (and any
  scan call) perform the actual on-demand connection probe instead, logging a
  `Logger.warning/1` on failure — the GenServer itself always starts
  successfully (AC7), never crashing the supervision tree just because clamd
  isn't up yet.
  """

  use GenServer

  require Logger

  @chunk_size 4096
  @default_timeout_ms 5_000
  # Kassandra security review (F-1, 2026-07-13): clamd's happy-path reply is
  # a tiny fixed line ("stream: OK\0" / "stream: <sig> FOUND\0" / ...) — well
  # under 1 KB. clamd is the one process in this deployment whose job is to
  # chew on attacker-controlled bytes, so its wire output must be treated as
  # adversarial, not trusted: a compromised/buggy clamd streaming continuous
  # non-null bytes without ever timing out would otherwise grow
  # `recv_until_null/3`'s accumulator without bound, OOM-ing this GenServer
  # and, since this is a single-node OTP app (ADR-019), the whole node.
  @max_reply_bytes 65_536

  defstruct address: nil,
            max_file_size_bytes: nil,
            socket: nil,
            healthy: false,
            changed_at: nil,
            connect_timeout_ms: @default_timeout_ms,
            recv_timeout_ms: @default_timeout_ms

  @type scan_result :: {:ok, :clean} | {:ok, {:infected, String.t()}} | {:error, term()}
  @type health :: %{healthy: boolean(), changed_at: DateTime.t()}

  # media-security-admin-control/10b-clamav-status-freshclam-age: the trailing
  # build-date segment of clamd's `zVERSION\0` reply is C-asctime-style
  # ("%a %b %e %H:%M:%S %Y", e.g. "Sun Jul 19 06:24:00 2026") with no
  # timezone — treated as UTC per this story's verified ground truth. Elixir
  # has no built-in asctime parser, so this is hand-rolled below.
  @asctime_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Scans an in-memory binary via clamd's INSTREAM protocol.

  Returns `{:ok, :clean}`, `{:ok, {:infected, signature}}`, or a tagged
  `{:error, reason}` — never raises (AC3/AC6).
  """
  @spec scan_binary(binary()) :: scan_result()
  def scan_binary(bytes) when is_binary(bytes) do
    GenServer.call(__MODULE__, {:scan_binary, bytes}, call_timeout_ms())
  end

  @doc """
  Reports whether the last known connection attempt to clamd succeeded (AC7),
  plus the timestamp of the last observed `healthy` state transition (10b
  AC2: `%{healthy: boolean(), changed_at: DateTime.t()}` — `changed_at` is
  set on `init/1` and updated only when `healthy` actually flips, never on
  every read, so a polling dashboard doesn't undercount true outage
  duration).
  """
  @spec health_check() :: health()
  def health_check do
    GenServer.call(__MODULE__, :health_check, call_timeout_ms())
  end

  @doc """
  Sends `zVERSION\\0` over the same managed connection `scan_binary/1` uses
  (10b Technical Requirements #2 — no second TCP connection, same
  lazy-reconnect-on-next-use machinery), parses the trailing build-date
  segment of the reply, and returns `{:ok, DateTime.t()}` (the signature
  database's build date, in UTC) or a tagged `{:error, reason}` for every
  failure mode (connection error, timeout, unparseable reply) — never
  raises, same discipline as `scan_binary/1` (Story 3 AC6).
  """
  @spec signature_info() :: {:ok, DateTime.t()} | {:error, term()}
  def signature_info do
    GenServer.call(__MODULE__, :signature_info, call_timeout_ms())
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config =
      :nebu
      |> Application.get_env(__MODULE__, [])
      |> Keyword.merge(opts || [])

    state = %__MODULE__{
      address: Keyword.fetch!(config, :address),
      max_file_size_bytes: Keyword.fetch!(config, :max_file_size_bytes),
      connect_timeout_ms: Keyword.get(config, :connect_timeout_ms, @default_timeout_ms),
      recv_timeout_ms: Keyword.get(config, :recv_timeout_ms, @default_timeout_ms),
      socket: nil,
      healthy: false,
      changed_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:scan_binary, bytes}, _from, state) do
    if byte_size(bytes) > state.max_file_size_bytes do
      {:reply, {:error, :file_too_large}, state}
    else
      had_socket? = not is_nil(state.socket)

      case ensure_connected(state) do
        {:ok, state1} ->
          handle_scan_attempt(bytes, state1, had_socket?)

        {:error, reason, state1} ->
          {:reply, {:error, reason}, state1}
      end
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    # code-review cycle 2 (MAJOR-1): whether this specific call caused a real
    # unhealthy -> healthy transition is determined by comparing `state`'s
    # `healthy` (before `ensure_connected/1`) against the returned state's
    # `healthy` (after) — the SAME transition this module's own `put_healthy/2`
    # helper already tracks via `changed_at` (see its moduledoc-adjacent
    # comment above). `ensure_connected/1` returns the state UNCHANGED when a
    # socket is already open (no reconnect attempted), so on every
    # already-healthy poll `was_healthy? == new_state.healthy == true` and no
    # log fires — only the single call that actually flips `healthy` logs.
    was_healthy? = state.healthy

    case ensure_connected(state) do
      {:ok, new_state} ->
        # media-security-admin-control/10e-trace-map-war-room-integration
        # (AC1): a successful connect/health-check-state transition, tagged
        # with route_template only (no request_id — a pipeline-wide event,
        # not tied to one file). 2-arity call-site metadata, never
        # Logger.metadata/1 — this GenServer's process is long-lived and
        # must not leak stale metadata onto whatever it logs next.
        #
        # code-review cycle 2 (MAJOR-1/MAJOR-2): gated to fire ONLY on the
        # actual unhealthy -> healthy transition (was_healthy? == false),
        # never on every already-healthy poll — health_check/0 is called on
        # every scan job, by the periodic alerts-checker worker, and on every
        # dashboard render, so an unconditional log here would write an
        # unbounded "clamd connection healthy" row to operational_logs on
        # every single clean poll (WARN/ERROR entries are always persisted by
        # LogStore.Handler, never policy-gated like INFO/DEBUG). Logger.info/2
        # (not :warning) per MAJOR-2 — a recovery event is informational, not
        # a warning. The corresponding test
        # (clamav_test.exs's "10e AC1" describe block) now raises the Logger
        # level to :info for the duration of its own tests (mirroring
        # request_logger_test.exs's Logger.configure(level: :info) precedent)
        # so this call is actually observable there.
        if not was_healthy? and new_state.healthy do
          Logger.info(
            "Nebu.Media.ClamAV: clamd connection healthy",
            route_template: "/media/clamav"
          )
        end

        {:reply, health_reply(new_state), new_state}

      {:error, reason, new_state} ->
        # media-security-admin-control/10e-trace-map-war-room-integration
        # (AC1): this is Story 3's existing unreachable-clamd warning
        # (unchanged message, unchanged unconditional-per-poll behavior) —
        # only the route_template metadata is new, added at the call site
        # itself, never via Logger.metadata/1. Out of scope for the
        # cycle-2 MAJOR-1 transition-gating fix (which only concerns the
        # "healthy" branch above) — see the story's Dev Agent Guardrails and
        # code-review cycle-2 findings for the exact, narrow scope of that fix.
        Logger.warning(
          "Nebu.Media.ClamAV: clamd unreachable at #{inspect(new_state.address)}: #{inspect(reason)}",
          route_template: "/media/clamav"
        )

        {:reply, health_reply(new_state), new_state}
    end
  end

  @impl true
  def handle_call(:signature_info, _from, state) do
    had_socket? = not is_nil(state.socket)

    case ensure_connected(state) do
      {:ok, state1} ->
        handle_signature_attempt(state1, had_socket?)

      {:error, reason, state1} ->
        {:reply, {:error, reason}, state1}
    end
  end

  defp health_reply(%__MODULE__{healthy: healthy, changed_at: changed_at}) do
    %{healthy: healthy, changed_at: changed_at}
  end

  # ── signature_info attempt (mirrors handle_scan_attempt's reconnect-and-
  #    retry shape — 10b reuses Story 3's lazy-reconnect-on-next-use
  #    machinery rather than building new reconnect logic) ──────────────────

  defp handle_signature_attempt(state, had_socket?) do
    case do_version_query(state) do
      {:ok, datetime, new_state} ->
        {:reply, {:ok, datetime}, new_state}

      {:error, :connection_closed, new_state} when had_socket? and is_nil(new_state.socket) ->
        retry_version_after_reconnect(new_state)

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  defp retry_version_after_reconnect(state) do
    case ensure_connected(state) do
      {:ok, state1} ->
        case do_version_query(state1) do
          {:ok, datetime, state2} -> {:reply, {:ok, datetime}, state2}
          {:error, reason, state2} -> {:reply, {:error, reason}, state2}
        end

      {:error, reason, state1} ->
        {:reply, {:error, reason}, state1}
    end
  end

  # ── scan attempt (with a single reconnect-and-retry on a stale socket) ──

  defp handle_scan_attempt(bytes, state, had_socket?) do
    case do_scan(bytes, state) do
      {:ok, result, new_state} ->
        log_scan_outcome(bytes, {:ok, result})
        {:reply, {:ok, result}, new_state}

      # The socket we just used was REUSED from prior state (not freshly
      # connected in this very call) and do_scan detected a dropped
      # connection (cleared socket back to nil) — AC8: reconnect once and
      # retry within this same call, so the caller never sees a stale-socket
      # error. A bare :timeout on a reused socket is deliberately excluded:
      # clamd is still connected but slow, and retrying immediately would
      # just re-send the whole payload to an already-slow daemon, doubling
      # the wait — that case falls through to the plain error clause below.
      {:error, :connection_closed, new_state} when had_socket? and is_nil(new_state.socket) ->
        retry_after_reconnect(bytes, new_state)

      {:error, reason, new_state} ->
        log_scan_outcome(bytes, {:error, reason})
        {:reply, {:error, reason}, new_state}
    end
  end

  defp retry_after_reconnect(bytes, state) do
    case ensure_connected(state) do
      {:ok, state1} ->
        case do_scan(bytes, state1) do
          {:ok, result, state2} ->
            log_scan_outcome(bytes, {:ok, result})
            {:reply, {:ok, result}, state2}

          {:error, reason, state2} ->
            log_scan_outcome(bytes, {:error, reason})
            {:reply, {:error, reason}, state2}
        end

      {:error, reason, state1} ->
        log_scan_outcome(bytes, {:error, reason})
        {:reply, {:error, reason}, state1}
    end
  end

  # ── socket management ───────────────────────────────────────────────────

  defp ensure_connected(%__MODULE__{socket: nil} = state), do: connect(state)
  defp ensure_connected(%__MODULE__{} = state), do: {:ok, state}

  defp connect(%__MODULE__{address: {:tcp, host, port}} = state) do
    opts = [
      :binary,
      packet: :raw,
      active: false,
      send_timeout: state.recv_timeout_ms,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(String.to_charlist(host), port, opts, state.connect_timeout_ms) do
      {:ok, socket} ->
        {:ok, put_healthy(%{state | socket: socket}, true)}

      {:error, reason} ->
        {:error, reason, put_healthy(%{state | socket: nil}, false)}
    end
  end

  # {:unix, path} is a documented, not-yet-implemented future option (AC2).
  # This clause exists solely so that a deployment which sets it gets a
  # clean tagged error instead of a FunctionClauseError crashing the
  # GenServer (which would raise in the caller, violating AC6's "never
  # raises" contract) — actual unix-socket support is out of scope.
  defp connect(%__MODULE__{address: {:unix, _path}} = state) do
    {:error, :unix_socket_not_implemented, put_healthy(%{state | socket: nil}, false)}
  end

  # 10b/AC2: `changed_at` only moves when `healthy` actually flips — a
  # dashboard/GenServer that re-derived "down since"/"up since" on every read
  # instead would undercount true outage duration (this is why every
  # `healthy:` mutation in this module MUST go through this helper instead of
  # setting the struct field directly).
  #
  # Known limitation (code-review cycle 1, MINOR-2): during NORMAL (connected)
  # operation, `changed_at` can still churn to ~now on every healthy poll
  # cycle, because a one-shot command whose peer closes the connection after
  # every use (like `signature_info/0`'s `zVERSION` query) causes the next
  # call's `do_version_query/1` to discover the peer-closed socket and flip
  # `healthy` false, immediately followed by a successful reconnect flipping
  # it back to true — two flips, one `changed_at` bump, per tick. This is
  # expected/documented behavior, not a bug: a genuine outage does NOT churn
  # `changed_at` this way, because `connect/1` keeps failing and
  # `put_healthy(state, false)` is a no-op on every subsequent tick (the
  # `healthy: healthy` clause below matches and returns state unchanged).
  # Downstream consumers (future stories 10c/10d) reading `changed_at` while
  # `healthy: true` should NOT assume it means "connection established this
  # long ago" during normal operation — only that it's non-nil, and that it
  # IS a trustworthy, monotonically-fresh "down since" timestamp once
  # `healthy: false` during a genuine sustained outage.
  defp put_healthy(%__MODULE__{healthy: healthy} = state, healthy), do: state
  defp put_healthy(state, healthy?), do: %{state | healthy: healthy?, changed_at: DateTime.utc_now()}

  # ── INSTREAM protocol ────────────────────────────────────────────────────

  defp do_scan(bytes, state) do
    socket = state.socket

    case send_instream(socket, bytes) do
      :ok ->
        case recv_until_null(socket, state.recv_timeout_ms) do
          {:ok, reply} -> handle_reply(reply, state)
          {:error, :timeout} -> transport_error(:timeout, socket, state)
          {:error, :reply_too_large} -> transport_error(:reply_too_large, socket, state)
          {:error, _reason} -> transport_error(:connection_closed, socket, state)
        end

      {:error, _reason} ->
        transport_error(:connection_closed, socket, state)
    end
  end

  # clamd null-terminates its INSTREAM reply so a client can read until the
  # null byte; a single :gen_tcp.recv/3 call only returns whatever is
  # currently available and could in principle hand back a partial reply if
  # a TCP segment boundary lands before the terminating null. This loops
  # across segments (each individual recv still respects the configured
  # timeout — timeouts are not summed across iterations) until a null byte
  # appears in the accumulated buffer, the accumulator exceeds
  # @max_reply_bytes (F-1 — see moduledoc-adjacent comment above), or the
  # connection times out/closes.
  #
  # If the peer stalls or drops the connection after already delivering at
  # least one chunk, that partial buffer is treated as the complete reply
  # rather than surfaced as a bare transport error: clamd's reply line is
  # tiny (well under one TCP segment) and downstream `parse_reply/1` already
  # safely classifies anything that isn't a recognized "stream: ..." line as
  # `{:error, {:clamd_error, line}}`, so a reply that's missing only its
  # trailing null still lands on a clean, tagged error rather than a raw
  # `:timeout`/`:connection_closed`. A timeout/close with NO data received
  # at all (acc == <<>>) is a genuine transport failure and is still
  # reported as such.
  defp recv_until_null(socket, timeout, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        buffer = acc <> data

        cond do
          String.contains?(buffer, <<0>>) ->
            {:ok, buffer}

          byte_size(buffer) > @max_reply_bytes ->
            {:error, :reply_too_large}

          true ->
            recv_until_null(socket, timeout, buffer)
        end

      {:error, :timeout} when acc != <<>> ->
        {:ok, acc}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _other} when acc != <<>> ->
        {:ok, acc}

      {:error, _other} ->
        {:error, :connection_closed}
    end
  end

  defp handle_reply(reply, state) do
    case parse_reply(reply) do
      {:ok, result} -> {:ok, result, put_healthy(state, true)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp transport_error(reason, socket, state) do
    close_socket(socket)
    {:error, reason, put_healthy(%{state | socket: nil}, false)}
  end

  # ── VERSION protocol (10b Technical Requirements #2) ────────────────────
  #
  # Same managed socket, same reconnect-on-next-use machinery as the
  # INSTREAM path above — `zVERSION\0` is a one-shot command; the real
  # `clamd` closes the connection after answering it (verified against the
  # dev-stack container), so a subsequent call transparently reconnects via
  # the exact same `ensure_connected/1` + retry-once path `scan_binary/1`
  # already relies on (no new reconnect logic).

  defp do_version_query(state) do
    socket = state.socket

    case :gen_tcp.send(socket, "zVERSION\0") do
      :ok ->
        case recv_until_null(socket, state.recv_timeout_ms) do
          {:ok, reply} -> handle_version_reply(reply, state)
          {:error, :timeout} -> transport_error(:timeout, socket, state)
          {:error, :reply_too_large} -> transport_error(:reply_too_large, socket, state)
          {:error, _reason} -> transport_error(:connection_closed, socket, state)
        end

      {:error, _reason} ->
        transport_error(:connection_closed, socket, state)
    end
  end

  defp handle_version_reply(reply, state) do
    case parse_version_reply(reply) do
      {:ok, datetime} -> {:ok, datetime, put_healthy(state, true)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Parses clamd's `zVERSION\0` reply: `"ClamAV <engine>/<db>/<build-date>"`.
  # Only the trailing build-date segment matters here (AC3); engine/db
  # version strings are not otherwise validated. Anything that doesn't split
  # into exactly 3 `/`-separated segments, or whose trailing segment isn't a
  # parseable asctime string, is a tagged error — never a raise (mirrors
  # `parse_reply/1`'s "every failure mode is a tagged result" discipline).
  defp parse_version_reply(reply) do
    line = reply |> reply_head() |> String.trim()

    case String.split(line, "/", parts: 3) do
      [_engine, _db_version, build_date] -> parse_asctime(String.trim(build_date))
      _other -> {:error, {:unparseable_version_reply, line}}
    end
  end

  # Parses a C-`asctime`-style datetime string, e.g.
  # "Sun Jul 19 06:24:00 2026" (`%a %b %e %H:%M:%S %Y`, no timezone — treated
  # as UTC per this story's verified ground truth). The leading weekday token
  # is matched but intentionally unused (decorative, not cross-checked
  # against the actual date). `%e` (day-of-month) is space-padded for
  # single-digit days in real `asctime` output, hence `\s+` (not a fixed
  # single space) between every token below.
  defp parse_asctime(str) do
    pattern = ~r/^\w+\s+(\w+)\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})$/

    with [_, month_name, day_str, hour_str, min_str, sec_str, year_str] <-
           Regex.run(pattern, str),
         {:ok, month} <- asctime_month(month_name),
         {day, ""} <- Integer.parse(day_str),
         {hour, ""} <- Integer.parse(hour_str),
         {minute, ""} <- Integer.parse(min_str),
         {second, ""} <- Integer.parse(sec_str),
         {year, ""} <- Integer.parse(year_str),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> {:error, {:unparseable_build_date, str}}
    end
  end

  defp asctime_month(name) do
    case Enum.find_index(@asctime_months, &(&1 == name)) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: :gen_tcp.close(socket)

  defp send_instream(socket, bytes) do
    with :ok <- :gen_tcp.send(socket, "zINSTREAM\0"),
         :ok <- send_chunks(socket, bytes, byte_size(bytes), 0),
         :ok <- :gen_tcp.send(socket, <<0::32>>) do
      :ok
    end
  end

  defp send_chunks(_socket, _bytes, total, offset) when offset >= total, do: :ok

  defp send_chunks(socket, bytes, total, offset) do
    len = min(@chunk_size, total - offset)
    chunk = :binary.part(bytes, offset, len)

    case :gen_tcp.send(socket, <<byte_size(chunk)::32-big, chunk::binary>>) do
      :ok -> send_chunks(socket, bytes, total, offset + len)
      {:error, reason} -> {:error, reason}
    end
  end

  # Parses clamd's INSTREAM reply line. Per the protocol:
  #   "stream: OK\0"                       -> {:ok, :clean}
  #   "stream: <signature> FOUND\0"        -> {:ok, {:infected, signature}}
  #   "stream: <message> ERROR\0"          -> {:error, {:clamd_error, message}}
  #   anything else unrecognized/malformed -> {:error, {:clamd_error, raw_line}}
  defp parse_reply(reply) do
    reply
    |> reply_head()
    |> String.trim()
    |> classify_reply()
  end

  defp reply_head(reply) do
    case :binary.split(reply, <<0>>) do
      [head, _rest] -> head
      [head] -> head
    end
  end

  defp classify_reply("stream: OK"), do: {:ok, :clean}

  defp classify_reply(line) do
    cond do
      match = Regex.run(~r/^stream: (.+) FOUND$/, line) ->
        {:ok, {:infected, Enum.at(match, 1)}}

      match = Regex.run(~r/^stream: (.+) ERROR$/, line) ->
        {:error, {:clamd_error, Enum.at(match, 1)}}

      true ->
        {:error, {:clamd_error, line}}
    end
  end

  # ── logging (AC9: size/outcome/signature only, never the scanned content) ──

  defp log_scan_outcome(bytes, {:ok, :clean}) do
    Logger.info("Nebu.Media.ClamAV: scan of #{byte_size(bytes)} bytes -> clean")
  end

  defp log_scan_outcome(bytes, {:ok, {:infected, signature}}) do
    Logger.warning(
      "Nebu.Media.ClamAV: scan of #{byte_size(bytes)} bytes -> infected (#{signature})"
    )
  end

  defp log_scan_outcome(bytes, {:error, reason}) do
    Logger.warning(
      "Nebu.Media.ClamAV: scan of #{byte_size(bytes)} bytes -> error (#{inspect(reason)})"
    )
  end

  defp call_timeout_ms do
    config = Application.get_env(:nebu, __MODULE__, [])
    connect_timeout = Keyword.get(config, :connect_timeout_ms, @default_timeout_ms)
    recv_timeout = Keyword.get(config, :recv_timeout_ms, @default_timeout_ms)
    # Worst case internal work is up to two full connect+recv cycles (AC8's
    # single reconnect-and-retry on a dropped connection does a SECOND
    # connect + do_scan after the first), so the outer GenServer.call
    # timeout must budget for both cycles plus slack — otherwise it could
    # fire before the internal retry completes and raise an exit in the
    # caller, violating AC6.
    2 * (connect_timeout + recv_timeout) + 2_000
  end
end
