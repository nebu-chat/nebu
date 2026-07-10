defmodule Nebu.Repo.QueryTelemetry do
  @moduledoc """
  Global, SANITIZED replacement for Ecto's built-in query logger
  (enhanced-logging/matrix-payload-debug-logging, CI-gate cycle-2 bug 2).

  ## Why this exists

  `config :nebu, Nebu.Repo, log: false` (`server/config/config.exs`) disables
  Ecto's own `Logger` call for every query against `Nebu.Repo`, in every env.
  That setting is necessary because Ecto's default query logger prints the
  **bound parameter values** of every query verbatim at `:debug` level — and
  several call sites in the codebase (e.g.
  `Nebu.Matrix.Session.MatrixSessionStore`) bind credentials (opaque
  access/refresh tokens) as plain SQL parameters. With the default logger
  enabled, simply turning on `:debug` logging anywhere (this whole epic's
  premise) leaks every token that flows through a query — a strictly worse
  hole than anything `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` guards
  against, and one that exists independently of that plug for ANY query,
  present or future, anywhere in the codebase.

  `log: false` only suppresses Ecto's OWN `Logger` call — it does NOT disable
  the underlying `[:nebu, :repo, :query]` `:telemetry` event, which
  `Ecto.Adapters.SQL` emits unconditionally for every query regardless of the
  `log:` setting. This module attaches a handler to that event and logs a
  **sanitized** summary (source/table name, duration in milliseconds, and a
  success/failure classification derived from the telemetry metadata's
  `:result` field) at `:debug` — deliberately never touching `:query` (the
  SQL text with `$1` placeholders is safe) or `:params` (the bound values,
  which are NOT safe), and never surfacing the raw `Exception` from a failed
  `:result` (only "ok"/"error"/"unknown").

  This restores equivalent-or-better debug visibility ("a query ran, on what
  table, how long it took, and whether it succeeded") without any bound
  parameter value ever reaching a log line, for every query in the codebase.

  ## Disabled in `:test`

  `config :nebu, Nebu.Repo.QueryTelemetry, enabled: false` in
  `server/config/test.exs` turns the `Logger.debug/1` call in this module's
  handler into a no-op (the handler still runs, it just skips logging).
  `ExUnit.CaptureLog.capture_log/1` intercepts the GLOBAL `:logger` handler for
  the duration of the call — it is not scoped to the calling process's
  descendants — so ANY concurrently-running `async: true` test that touches
  `Nebu.Repo` while another test has flipped `Logger.level(:debug)` and is
  mid-`capture_log/1` would otherwise inject an unrelated `"ecto query ..."`
  line into that test's captured output (this bit an ATDD test in
  `request_logger_test.exs` — AC1's JSON-line extraction regex is greedy and
  captures from the first `{` to the LAST `}` in the WHOLE captured string, so
  an interleaved line from a concurrent query landing between two unrelated
  `{...}` log lines corrupted the JSON). Every OTHER query in the codebase
  fires far more often (once per test, essentially) than any pre-existing
  sporadic `Logger.debug` call, which is what made this collision
  near-guaranteed under the full suite instead of a rare flake. Since no
  story or AC anywhere asserts on THIS module's own log output, and its whole
  purpose is real dev/prod/staging debugging sessions (not something ExUnit
  needs to see), disabling it in `:test` costs nothing while keeping the fix
  fully global for every environment that actually matters.

  ## Usage

  Attached once at boot from `Nebu.Application.start/2`, unconditionally
  (attaching is cheap and the handler itself only calls `Logger.debug/1` when
  enabled, which itself no-ops below `:debug` level — so this is safe to
  attach regardless of the configured log level).
  """

  require Logger

  @handler_id "nebu-repo-query-telemetry"
  @event [:nebu, :repo, :query]

  @doc """
  Attaches the sanitized query-logging handler to the `[:nebu, :repo, :query]`
  telemetry event. Idempotent — safe to call more than once (e.g. across
  Application restarts in the same VM during tests): `:telemetry.attach/4`
  returns `{:error, :already_exists}` in that case, which is ignored.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  # Telemetry handler callback. Logs ONLY the query source (table/schema name,
  # when Ecto supplies one), duration in milliseconds, and a success/failure
  # classification (code-review m3) — NEVER `:query` (raw SQL text), `:params`
  # (bound values), or the raw `Exception` struct from a failed `:result`,
  # which is the whole point of this module. Skips logging entirely when
  # disabled (see "Disabled in :test" above) — the handler still runs (so
  # attaching remains unconditional), it just does not call Logger in that
  # case.
  def handle_event(@event, measurements, metadata, _config) do
    if enabled?() do
      duration_ms = native_to_ms(Map.get(measurements, :total_time, 0))
      source = Map.get(metadata, :source) || "unknown"
      result = classify_result(Map.get(metadata, :result))

      Logger.debug(fn ->
        "ecto query source=#{inspect(source)} duration_ms=#{duration_ms} result=#{result}"
      end)
    end

    :ok
  end

  # code-review m3: distinguishes query success/failure — useful for
  # diagnosis ("query failed" vs "query succeeded" matters when debugging) —
  # WITHOUT ever surfacing the raw `Exception` struct/message from a failed
  # `:result`, which could itself carry sensitive data (e.g. a constraint
  # violation message echoing a bound value).
  defp classify_result({:ok, _}), do: "ok"
  defp classify_result({:error, _}), do: "error"
  defp classify_result(_), do: "unknown"

  defp enabled? do
    Application.get_env(:nebu, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  defp native_to_ms(native_time) do
    System.convert_time_unit(native_time, :native, :millisecond)
  end
end
