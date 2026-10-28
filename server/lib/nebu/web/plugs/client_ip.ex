defmodule Nebu.Web.Plugs.ClientIP do
  @moduledoc """
  Resolves the client address ONCE per request (story `oauth-trusted-proxy-client-ip`, TP9).

  Placed in `Nebu.Web.Router` directly after `Nebu.Web.Plugs.RequestId`, so every forwarded
  sub-router (Matrix, media, OAuth, `/admin`) sees the result. Stores

    * `conn.private[:nebu_client_ip]` - the client address string (canonical text form of the
      IPv4-normalised tuple, built by `Nebu.Web.ClientIP`), consumed through `Nebu.Web.ClientIP.get/1`;
    * `conn.private[:nebu_client_bucket]` - the rate-limit key (`Nebu.Web.ClientIP.bucket/1`: IPv4
      unchanged, native IPv6 aggregated to its /64);
    * `conn.private[:nebu_client_ip_source]` - `:peer` (direct peer) or `:forwarded` (the
      forwarding header of a trusted proxy was honoured).

  The socket peer on the conn is NOT rewritten, the plug never halts, never reads the body and
  never raises on any header content. The forwarding header is only read when the direct peer is
  trusted (`NEBU_TRUSTED_PROXY_CIDRS`, see `Nebu.Web.ClientIP`). RFC 7239 forwarded-element headers
  and the real-ip header of some proxies are ignored entirely (TP6). Logs nothing itself (TP13): when a request
  carries the forwarding header but its direct peer is NOT trusted, it calls
  `Nebu.Web.ClientIP.note_untrusted_forwarding/0` (one throttled WARNING per node and 10 minutes, no address,
  no header value; story `client-ip-misconfiguration-warnings`). The header is still ignored.
  """

  @behaviour Plug

  alias Nebu.Web.ClientIP

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{remote_ip: peer} = conn, _opts) when is_tuple(peer) do
    trusted = ClientIP.trusted()

    lines =
      if trusted != [] and ClientIP.trusted?(ClientIP.normalize(peer), trusted) do
        Plug.Conn.get_req_header(conn, "x-forwarded-for")
      else
        # W1: only a key lookup on the untrusted path (no header copy, no string building).
        if List.keymember?(conn.req_headers, "x-forwarded-for", 0), do: ClientIP.note_untrusted_forwarding()
        []
      end

    {source, ip} = ClientIP.resolve(peer, lines, trusted)
    store(conn, source, ClientIP.format(ip), ClientIP.bucket_for(ip))
  end

  def call(%Plug.Conn{remote_ip: other} = conn, _opts) do
    string = ClientIP.peer_string(other)
    store(conn, :peer, string, string)
  end

  defp store(conn, source, ip_string, bucket) do
    conn
    |> Plug.Conn.put_private(:nebu_client_ip, ip_string)
    |> Plug.Conn.put_private(:nebu_client_bucket, bucket)
    |> Plug.Conn.put_private(:nebu_client_ip_source, source)
  end
end
