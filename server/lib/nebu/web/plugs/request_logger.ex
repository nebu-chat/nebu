defmodule Nebu.Web.Plugs.RequestLogger do
  @moduledoc false
  @behaviour Plug

  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    start_ms = System.monotonic_time(:millisecond)

    # ORDERING DEPENDENCY: Nebu.Web.Plugs.RequestId MUST run before this plug in the
    # router pipeline. RequestId sets the "x-request-id" response header; we read it here.
    # If RequestId were placed after RequestLogger, request_id would be nil in the log line.
    request_id = Plug.Conn.get_resp_header(conn, "x-request-id") |> List.first()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration_ms = System.monotonic_time(:millisecond) - start_ms

      Logger.info(%{
        method: conn.method,
        path: conn.request_path,
        status: conn.status,
        duration_ms: duration_ms,
        request_id: request_id
      })

      conn
    end)
  end
end
