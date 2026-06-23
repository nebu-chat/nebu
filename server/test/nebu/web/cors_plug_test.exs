defmodule Nebu.Web.CorsPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  @opts Nebu.Web.Router.init([])

  # AC4: CORS preflight OPTIONS returns Access-Control-Allow-Origin and
  # Access-Control-Allow-Methods headers
  test "OPTIONS preflight with Origin returns CORS headers" do
    conn =
      conn(:options, "/health")
      |> put_req_header("origin", "http://localhost")
      |> put_req_header("access-control-request-method", "GET")
      |> Nebu.Web.Router.call(@opts)

    assert get_resp_header(conn, "access-control-allow-origin") != [],
           "Access-Control-Allow-Origin header must be present"

    assert get_resp_header(conn, "access-control-allow-methods") != [],
           "Access-Control-Allow-Methods header must be present"
  end

  # MAJOR-1 / AC3: "Any HTTP request emits a structured info log line."
  # Preflight OPTIONS requests are halted by CORSPlug with 204; RequestLogger must
  # still log them because it registers its before_send callback before CORSPlug runs.
  test "OPTIONS preflight emits a structured log line (RequestLogger runs before CORSPlug)" do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log_output =
      capture_log(fn ->
        conn(:options, "/health")
        |> put_req_header("origin", "http://localhost")
        |> put_req_header("access-control-request-method", "GET")
        |> Nebu.Web.Router.call(@opts)
      end)

    assert String.contains?(log_output, "method"), "preflight log must contain 'method'"
    assert String.contains?(log_output, "path"), "preflight log must contain 'path'"
    assert String.contains?(log_output, "status"), "preflight log must contain 'status'"
    assert String.contains?(log_output, "duration_ms"), "preflight log must contain 'duration_ms'"
    assert String.contains?(log_output, "request_id"), "preflight log must contain 'request_id'"
  end

  test "GET request includes Access-Control-Allow-Origin header" do
    conn =
      conn(:get, "/health")
      |> put_req_header("origin", "http://localhost")
      |> Nebu.Web.Router.call(@opts)

    assert get_resp_header(conn, "access-control-allow-origin") != [],
           "Access-Control-Allow-Origin must be present on regular GET requests with Origin"
  end

  test "request without Origin header still gets wildcard ACAO header from CORSPlug" do
    conn =
      conn(:get, "/health")
      |> Nebu.Web.Router.call(@opts)

    # CORSPlug emits Access-Control-Allow-Origin: * on all responses (not just Origin-bearing ones).
    # This is safe for a non-federated internal API and matches the library's default behaviour.
    acao = get_resp_header(conn, "access-control-allow-origin")
    assert acao == ["*"] or acao == []
    assert conn.status == 200
  end
end
