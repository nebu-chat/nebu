defmodule Nebu.Repo.QueryTelemetryTest do
  @moduledoc """
  Code-review cycle-2 fix (M3): dedicated unit test coverage for
  `Nebu.Repo.QueryTelemetry` — the sanitized global replacement for Ecto's
  default query logger (enhanced-logging/matrix-payload-debug-logging).

  This module is disabled by default in `:test` (`config :nebu,
  Nebu.Repo.QueryTelemetry, enabled: false`, see `server/config/test.exs`) to
  avoid `ExUnit.CaptureLog` cross-test interleaving with concurrently-running
  `async: true` tests. That default is left untouched here for every OTHER
  test suite — this test locally overrides the config for its own duration
  (restored via `on_exit/1`) and calls `QueryTelemetry.handle_event/4`
  DIRECTLY with synthetic Ecto telemetry metadata, so it needs neither a live
  `Nebu.Repo`/Postgres connection nor `--include integration`.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Nebu.Repo.QueryTelemetry

  @event [:nebu, :repo, :query]
  @secret_token "syt_super_secret_do_not_leak_abc123"

  setup do
    original_config = Application.get_env(:nebu, QueryTelemetry, [])
    original_level = Logger.level()

    Application.put_env(:nebu, QueryTelemetry, enabled: true)
    Logger.configure(level: :debug)

    on_exit(fn ->
      Application.put_env(:nebu, QueryTelemetry, original_config)
      Logger.configure(level: original_level)
    end)

    :ok
  end

  test "logs sanitized source and duration but NEVER the bound token parameter or raw SQL text" do
    metadata = %{
      type: :ecto_sql_query,
      repo: Nebu.Repo,
      result: {:ok, %{num_rows: 1}},
      params: [@secret_token],
      cast_params: nil,
      query: "SELECT * FROM matrix_sessions WHERE access_token = $1 -- #{@secret_token}",
      source: "matrix_sessions",
      stacktrace: nil,
      options: []
    }

    measurements = %{total_time: 4_200_000}

    log =
      capture_log(fn ->
        assert :ok = QueryTelemetry.handle_event(@event, measurements, metadata, nil)
      end)

    assert log =~ "source="
    assert log =~ "matrix_sessions"
    assert log =~ "duration_ms="

    refute log =~ @secret_token,
           "the bound SQL parameter value must never reach the sanitized log line"

    refute log =~ "SELECT",
           "the raw SQL query text must never reach the sanitized log line"
  end

  test "a successful query is classified as result=ok" do
    metadata = %{source: "profiles", result: {:ok, %{}}, query: "...", params: []}
    measurements = %{total_time: 1_000_000}

    log =
      capture_log(fn ->
        QueryTelemetry.handle_event(@event, measurements, metadata, nil)
      end)

    assert log =~ "result=ok"
  end

  test "a failed query is classified as result=error without leaking the raw exception" do
    metadata = %{
      source: "matrix_sessions",
      result: {:error, %RuntimeError{message: "constraint violated: #{@secret_token}"}},
      query: "...",
      params: []
    }

    measurements = %{total_time: 500_000}

    log =
      capture_log(fn ->
        QueryTelemetry.handle_event(@event, measurements, metadata, nil)
      end)

    assert log =~ "result=error"

    refute log =~ @secret_token,
           "the raw exception message from a failed query must never be logged"

    refute log =~ "constraint violated"
  end

  test "missing source defaults to \"unknown\" instead of crashing" do
    metadata = %{source: nil, result: {:ok, %{}}, query: "...", params: []}
    measurements = %{total_time: 100_000}

    log =
      capture_log(fn ->
        QueryTelemetry.handle_event(@event, measurements, metadata, nil)
      end)

    assert log =~ ~s(source="unknown")
  end

  test "when disabled via config, the handler runs but logs nothing" do
    Application.put_env(:nebu, QueryTelemetry, enabled: false)

    metadata = %{source: "matrix_sessions", result: {:ok, %{}}, query: "...", params: []}
    measurements = %{total_time: 100_000}

    log =
      capture_log(fn ->
        assert :ok = QueryTelemetry.handle_event(@event, measurements, metadata, nil)
      end)

    assert log == ""
  end
end
