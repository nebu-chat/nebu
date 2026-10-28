defmodule Nebu.Web.Unrecognized do
  @moduledoc """
  Shared `M_UNRECOGNIZED` answers of the Matrix router fall-throughs (story
  oauth-room-summary-unrecognized, decisions RU9 - RU11, RU15).

  Matrix spec (v1.18, "Common error codes"): `M_UNRECOGNIZED` with a 404 "if the endpoint is not
  implemented" or a 405 "if the endpoint is implemented, but the incorrect HTTP method is used".

    * `not_found/1`  - `404 {"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}`
    * `method_not_allowed/2` - `405 {"errcode":"M_UNRECOGNIZED","error":"Unsupported method"}` + `Allow`
    * `options/2` - a NON-preflight `OPTIONS` on a known path: `204` + `Allow`, no logic, no auth
      (a CORS preflight never gets here: `CORSPlug` halts it in the top-level router)
    * `respond/2` - the single entry point of a router's catch-all: `methods` is the list of methods
      that really route for the request path (each router probes its OWN clauses), the answer follows
      from it and from the request method.

  `methods` never contains `OPTIONS`; the `Allow` header always appends it (RFC 9110: a 405 MUST carry
  `Allow`). No function here writes a log line, and none of them touches a DB or a rate-limit bucket.
  """

  import Plug.Conn

  @type methods :: [String.t()]

  @doc "404 `M_UNRECOGNIZED` (no endpoint at this path for any method)."
  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  def not_found(conn), do: json(conn, 404, "Unrecognized request")

  @doc "405 `M_UNRECOGNIZED` + `Allow: <methods>, OPTIONS`."
  @spec method_not_allowed(Plug.Conn.t(), methods()) :: Plug.Conn.t()
  def method_not_allowed(conn, methods) do
    conn
    |> put_allow(methods)
    |> json(405, "Unsupported method")
  end

  @doc """
  204 + `Allow: <methods>, OPTIONS` for a non-preflight `OPTIONS`. `CORSPlug` adds no header to an
  `OPTIONS` without `access-control-request-method`, so the allow-origin header is set here (same
  value `CORSPlug` uses for every other response of the router).
  """
  @spec options(Plug.Conn.t(), methods()) :: Plug.Conn.t()
  def options(conn, methods) do
    conn
    |> put_allow(methods)
    |> put_cors_origin()
    |> send_resp(204, "")
  end

  @doc """
  Answer of a router catch-all. `methods == []`: nothing routes at this path => 404. Otherwise a
  non-preflight `OPTIONS` => 204 and every other method => 405.
  """
  @spec respond(Plug.Conn.t(), methods()) :: Plug.Conn.t()
  def respond(conn, []), do: not_found(conn)
  def respond(%Plug.Conn{method: "OPTIONS"} = conn, methods), do: options(conn, methods)
  def respond(conn, methods), do: method_not_allowed(conn, methods)

  @probe_methods ["GET", "PUT", "POST", "DELETE", "PATCH"]

  @doc """
  The methods (other than the request method) for which `route_match?` finds a real route at the
  request path, in a stable order. `route_match?` receives the conn with the request method replaced
  by the probe method; each router passes a function around its private `do_match/4` (a probe SELECTS
  a clause, it never dispatches).
  """
  @spec probe(Plug.Conn.t(), (Plug.Conn.t() -> boolean())) :: methods()
  def probe(%Plug.Conn{method: request_method} = conn, route_match?) when is_function(route_match?, 1) do
    for method <- @probe_methods, method != request_method, route_match?.(%{conn | method: method}), do: method
  end

  defp put_allow(conn, methods), do: put_resp_header(conn, "allow", Enum.join(methods ++ ["OPTIONS"], ", "))

  defp put_cors_origin(conn) do
    case get_resp_header(conn, "access-control-allow-origin") do
      [] -> put_resp_header(conn, "access-control-allow-origin", "*")
      _ -> conn
    end
  end

  defp json(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"errcode" => "M_UNRECOGNIZED", "error" => message}))
  end
end
