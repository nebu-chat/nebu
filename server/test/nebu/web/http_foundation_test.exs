defmodule Nebu.Web.HttpFoundationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @moduletag :integration

  @port Application.compile_env(:nebu_http, :port, 4001)

  setup_all do
    # Restore logger level after integration tests to avoid leaking into other suites.
    original_level = Logger.level()
    Logger.configure(level: :info)

    {:ok, _} = Application.ensure_all_started(:inets)

    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  # AC1: GET /health returns 200 with {"status":"ok"} from Bandit
  test "GET /health returns 200 OK with status ok body" do
    {:ok, {{_http, status, _reason}, headers, body}} =
      :httpc.request(:get, {~c"http://localhost:#{@port}/health", []}, [timeout: 5000], [])

    assert status == 200

    content_type =
      headers
      |> Enum.find(fn {name, _} -> String.downcase(to_string(name)) == "content-type" end)
      |> elem(1)
      |> to_string()

    assert String.contains?(content_type, "application/json")

    decoded = Jason.decode!(IO.iodata_to_binary(body))
    assert decoded == %{"status" => "ok"}
  end

  # AC2: All responses include X-Request-Id with a UUID-v4 value
  test "response includes X-Request-Id header with UUID-v4 format" do
    {:ok, {_status_line, headers, _body}} =
      :httpc.request(:get, {~c"http://localhost:#{@port}/health", []}, [timeout: 5000], [])

    request_id =
      Enum.find(headers, fn {name, _} -> String.downcase(to_string(name)) == "x-request-id" end)

    assert request_id != nil, "X-Request-Id header must be present"

    {_, value} = request_id
    uuid = to_string(value)

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
             uuid
           ),
           "X-Request-Id must be a valid UUID v4, got: #{uuid}"
  end

  # AC3: A structured log line is emitted containing required fields
  test "structured log is emitted with method, path, status, duration_ms, and request_id" do
    log_output =
      capture_log(fn ->
        :httpc.request(:get, {~c"http://localhost:#{@port}/health", []}, [timeout: 5000], [])
      end)

    assert String.contains?(log_output, "method"), "log must contain 'method'"
    assert String.contains?(log_output, "path"), "log must contain 'path'"
    assert String.contains?(log_output, "status"), "log must contain 'status'"
    assert String.contains?(log_output, "duration_ms"), "log must contain 'duration_ms'"
    assert String.contains?(log_output, "request_id"), "log must contain 'request_id'"
  end

  # AC5: Bandit starts on the configured port and responds correctly
  test "server is reachable on configured port" do
    {:ok, {{_http, status, _}, _headers, _body}} =
      :httpc.request(:get, {~c"http://localhost:#{@port}/health", []}, [timeout: 5000], [])

    assert status == 200, "Bandit must respond with 200 on /health"
  end
end

defmodule Nebu.Web.DepsTest do
  use ExUnit.Case

  # AC5: Cowboy must NOT be a direct dependency of nebu_http
  test "cowboy is not listed as a mix dependency" do
    assert Mix.Project.config()[:app] == :nebu,
           "DepsTest must run from the single :nebu project context (ADR-019)"

    deps = Mix.Project.config()[:deps] || []

    dep_names =
      Enum.map(deps, fn
        {name, _} -> name
        {name, _, _} -> name
        name when is_atom(name) -> name
      end)

    refute :cowboy in dep_names, "cowboy must NOT be a direct dependency of nebu_http"
  end

  test "bandit is listed as a mix dependency" do
    deps = Mix.Project.config()[:deps] || []

    dep_names =
      Enum.map(deps, fn
        {name, _} -> name
        {name, _, _} -> name
        name when is_atom(name) -> name
      end)

    assert :bandit in dep_names, "bandit must be a direct dependency of nebu_http"
  end
end
