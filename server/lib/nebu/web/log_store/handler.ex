defmodule Nebu.Web.LogStore.Handler do
  @moduledoc """
  The Erlang `:logger` handler callback for the operational log store
  (enhanced-logging/operational-log-store, AC2/AC10).

  Attached (idempotently) via `Nebu.Web.LogStore.attach_handler/0`, this
  module's `log/2` is invoked SYNCHRONOUSLY, in the calling process, for
  EVERY `Logger.*` call app-wide once attached — it therefore MUST be cheap
  and MUST NEVER raise (a crash here would crash whatever unrelated code
  happened to log something). It does no blocking DB write itself: it always
  broadcasts (cheap, in-memory `Phoenix.PubSub.broadcast/3`) and, only when
  the entry's level should be persisted per policy, hands the entry to
  `Nebu.Web.LogStore.Writer.write_async/1` — a non-blocking `GenServer.cast/2`
  to a dedicated batching writer process.

  ## SECURITY LAW — never a second unredacted leak path

  This is a GENERIC handler — it has no awareness of HTTP requests, Matrix
  events, or `PayloadRedactor`. It renders whatever the log event's `msg`
  already is and passes it through UNCHANGED. The "No Sensitive Data in Logs"
  guarantee for HTTP payload content is therefore entirely the upstream
  responsibility of `Nebu.Web.Plugs.RequestLogger` (which redacts BEFORE
  calling `Logger.debug/1`) — this handler does no redaction of its own and
  needs none, precisely BECAUSE it never re-derives fields from anything
  other than the already-rendered log event it is handed.
  """

  alias Nebu.Web.LogStore

  @doc """
  The `:logger` handler callback: `HandlerModule:log(LogEvent, Config)`.
  Always returns `:ok` — any unexpected shape in `log_event` is caught and
  swallowed rather than raised, since this runs inline in an arbitrary
  caller's process.
  """
  @spec log(map(), map()) :: :ok
  def log(log_event, _config) do
    entry =
      log_event
      |> parse_log_event()
      |> maybe_tag_war_room()

    safe_broadcast(entry)

    # enhanced-logging/war-room-mode (AC4): an active, MATCHING war room
    # session persists REGARDLESS of the ambient per-level retention policy
    # — e.g. a DEBUG entry even when log_collect_debug is false. The
    # war-room match/tag decision (maybe_tag_war_room/1 above) already ran
    # BEFORE this gate, synchronously, precisely so an entry it tagged is
    # never discarded here.
    # enhanced-logging/trace-map-node-controls (AC4): route-aware so the
    # Trace Map's off-by-default long-polling endpoints are genuinely not
    # collected server-side (unless a temporary capture is active, or the
    # entry is ERROR-level — errors-always-persist).
    if LogStore.should_persist?(entry.level, entry.route_template) or not is_nil(entry[:war_room_id]) do
      safe_write(entry)
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── parsing ─────────────────────────────────────────────────────────────────

  defp parse_log_event(log_event) do
    meta = Map.get(log_event, :meta, %{})

    %{
      level: level_to_string(Map.get(log_event, :level)),
      source: source_from_meta(meta),
      route_template: metadata_string(Map.get(meta, :route_template)),
      request_id: metadata_string(Map.get(meta, :request_id)),
      message: render_msg(Map.get(log_event, :msg)),
      metadata: safe_metadata(meta)
    }
  end

  defp level_to_string(level) when is_atom(level), do: Atom.to_string(level)
  defp level_to_string(level) when is_binary(level), do: level
  defp level_to_string(level), do: inspect(level)

  # A best-effort classification, only used to populate the `source` column —
  # never relied upon for redaction/security decisions. Falls back to the
  # calling module's own name so unrecognised sources are still identifiable.
  #
  # bug-fix cycle 6 (admin-logs-monitoring-view, code-review finding M2
  # follow-up): this used to key off a bare `:module` metadata key, which
  # Elixir's `Logger.debug/info/warning/error` macros NEVER actually inject —
  # only `:mfa` (`{module, function, arity}`), captured automatically at the
  # macro's call site regardless of whether the call is
  # `Logger.info("string", metadata)` or the "report" style
  # `Logger.info(map)`/`Logger.debug(fn -> ... end)` used by `RequestLogger`
  # and `Nebu.Repo.QueryTelemetry`. That meant `source_from_meta/1` ALWAYS
  # fell through to `"unknown"` for every real call in the app, breaking
  # `LogsLive.build_row/1`'s `source == "http"` lookup (AC6: status/method/
  # duration row display) and the AC1 "Sources" trace-map bubble counts for
  # ALL real traffic — see the regression tests below and in
  # `handler_test.exs`/`request_logger_test.exs`. `module_from_meta/1` derives
  # the calling module from `:mfa` first, falling back to a bare `:module` key
  # (cheap, harmless) for any caller that ever sets it explicitly.
  defp source_from_meta(meta) do
    case module_from_meta(meta) do
      Nebu.Web.Plugs.RequestLogger -> "http"
      Nebu.Repo.QueryTelemetry -> "ecto"
      module when is_atom(module) and not is_nil(module) -> Atom.to_string(module)
      _ -> "unknown"
    end
  end

  defp module_from_meta(meta) do
    case Map.get(meta, :mfa) do
      {module, _fun, _arity} -> module
      _ -> Map.get(meta, :module)
    end
  end

  defp metadata_string(nil), do: nil
  defp metadata_string(value) when is_binary(value), do: value
  defp metadata_string(value), do: to_string(value)

  # Drops the fields already surfaced as their own columns/handled elsewhere
  # (time/pid/gl/domain/module/function/file/line/mfa are Logger-internal
  # bookkeeping; request_id/route_template are their own columns) and coerces
  # remaining metadata values into JSON/inspect-safe terms.
  @drop_meta_keys ~w(time pid gl domain module function file line mfa request_id route_template)a

  defp safe_metadata(meta) when is_map(meta) do
    meta
    |> Map.drop(@drop_meta_keys)
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), safe_meta_value(v)} end)
  end

  defp safe_metadata(_meta), do: %{}

  defp safe_meta_value(v) when is_pid(v), do: inspect(v)
  defp safe_meta_value(v) when is_reference(v), do: inspect(v)
  defp safe_meta_value(v) when is_function(v), do: inspect(v)
  defp safe_meta_value(v) when is_tuple(v), do: inspect(v)
  defp safe_meta_value(v) when is_atom(v), do: v
  defp safe_meta_value(v) when is_binary(v), do: v
  defp safe_meta_value(v) when is_number(v), do: v
  defp safe_meta_value(v) when is_map(v), do: safe_metadata(v)
  defp safe_meta_value(v) when is_list(v), do: Enum.map(v, &safe_meta_value/1)
  defp safe_meta_value(v), do: inspect(v)

  # Renders the `:logger` event's `msg` field, whatever shape it arrives in,
  # to a plain string — WITHOUT touching/re-deriving its content (see
  # moduledoc SECURITY LAW). `RequestLogger`'s `Logger.debug(fn -> ... end)`
  # calls already return the fully-redacted, `Jason.encode!/1`-ed JSON string
  # by the time it reaches here as a `{:string, binary}` msg.
  defp render_msg({:string, chardata}) do
    IO.chardata_to_string(chardata)
  rescue
    _ -> inspect(chardata)
  end

  defp render_msg({:report, report}) when is_map(report) or is_list(report) do
    inspect(report)
  end

  defp render_msg({:format, format, args}) do
    format
    |> :io_lib.format(args)
    |> IO.iodata_to_binary()
  rescue
    _ -> inspect({format, args})
  end

  defp render_msg(other), do: inspect(other)

  # ── war room tagging (enhanced-logging/war-room-mode, AC4/AC9) ─────────────
  #
  # Delegates the scope/filter match (against route_template/metadata's
  # user_id/device_id — never message content, see moduledoc SECURITY LAW)
  # to Nebu.Web.LogStore.WarRoom.check/1, which is cheap/non-blocking when
  # no war room session is active (see that module's own moduledoc) and
  # never raises (any failure — including the WarRoom process being down —
  # is caught and treated as "no match", never a logging-path crash).
  defp maybe_tag_war_room(entry) do
    case safe_war_room_check(entry) do
      nil -> entry
      war_room_id -> Map.put(entry, :war_room_id, war_room_id)
    end
  end

  defp safe_war_room_check(entry) do
    Nebu.Web.LogStore.WarRoom.check(entry)
  rescue
    _ -> nil
  end

  # ── side effects (broadcast / write) — isolated so one failing does not
  # prevent the other, and neither ever propagates back to the caller ──────────

  defp safe_broadcast(entry) do
    if Process.whereis(Nebu.PubSub) do
      Phoenix.PubSub.broadcast(Nebu.PubSub, "operational_logs", entry)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp safe_write(entry) do
    Nebu.Web.LogStore.Writer.write_async(entry)
  rescue
    _ -> :ok
  end
end
