defmodule Nebu.Web.RequestScheme do
  @moduledoc """
  The ONE rule for "was this request made over https?" behind a TLS-terminating reverse proxy
  (story oauth-account-management review cycle 1, INFO i3: it was copied four times):
  the FIRST value of `X-Forwarded-Proto` (a proxy chain may send `https,http`; several header lines are
  read in order) when it is `https`, else the connection's own scheme (unchanged for every other value).

  Used for the `.well-known` base URL, the IdP callback URL, the `Secure` attribute of the OAuth
  browser-binding cookies and the account page (`__Host-` cookie). The header is trusted only as far
  as the reference nginx overwrites it (trusted-proxy gate item 1): a client reaching the server
  directly can only influence the attributes of its OWN response.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @doc "True when the request is https (see the moduledoc)."
  @spec https?(Plug.Conn.t()) :: boolean()
  def https?(conn) do
    case first_forwarded_proto(conn) do
      "https" -> true
      _other -> conn.scheme == :https
    end
  end

  @doc "`\"https\"` or `\"http\"` (see `https?/1`)."
  @spec scheme(Plug.Conn.t()) :: String.t()
  def scheme(conn), do: if(https?(conn), do: "https", else: "http")

  defp first_forwarded_proto(conn) do
    conn
    |> get_req_header("x-forwarded-proto")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> List.first()
  end
end
