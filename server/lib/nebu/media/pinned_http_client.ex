defmodule Nebu.Media.PinnedHttpClient do
  @moduledoc """
  An `ExAws.Request.HttpClient` that connects to the address the SSRF guard CHECKED (story `storage-test-pinned-target`,
  follow-up `do` part a, ADR-033 SO11 addendum).

  `Nebu.Media.StorageConfig.test_connection/1` validates the candidate storage endpoint with
  `Nebu.Media.SSRF.checked_target/2` (the host name is resolved ONCE, every answer is checked) and carries the checked
  target `%{scheme, host, ip}` to the request. A plain `ExAws` / hackney request would resolve the host name AGAIN, and a DNS
  server could answer a public address to the check and a private one to the request (DNS rebinding, time-of-check /
  time-of-use). This client closes that window: it is selected per request through the ExAws config override
  (`http_client: Nebu.Media.PinnedHttpClient`, `http_opts: [pinned_target: target]`, see
  `Nebu.Media.StorageConfig`) and

    * connects to the PINNED ip: the URL host is replaced by the ip (an IPv6 ip in brackets), the host name is never
      resolved by the HTTP client;
    * keeps the ORIGINAL `Host` header: ExAws signs the request (AWS SigV4) over the original host (`host[:port]`), a default
      port (443 / 80) is absent from the URL and from the signed host, so the `Host` value sent is exactly the signed one;
    * https: keeps the TLS SNI (`server_name_indication`, a charlist) and the certificate hostname verification for the
      ORIGINAL host name (hackney verifies against the SNI), so a certificate for the ip only, or for another name, is
      refused and the request is never sent. The `ssl_options` configured under `config :ex_aws, :hackney_opts`
      (e.g. a test CA via `cacerts:`) are MERGED, the pin only sets the SNI; the production default (certifi) is unchanged;
    * FAILS CLOSED: no `pinned_target` in the options, or a URL whose host is not the pinned host, is an error and never a
      normal (re-resolving) request;
    * never follows a redirect (it would bypass the pin: the `Location` is an address nobody checked; a 302 / 303 / 307 / 308
      answer is an `{:error, %{reason: {:redirect_not_followed, status}}}`), uses no connection pool (`pool: false`, no keep-alive
      reuse across checks), speaks HTTP/1.1 only (`protocols: [:http1]`: HTTP/2 would send the pinned IP as `:authority` and drop
      the `Host` header the SigV4 signature covers) and adds no `proxy` option of its own.

  ## Why it merges the hackney options itself

  `ExAws` passes `http_opts` to the client and `ExAws.Request.Hackney` would prepend them to the configured
  `:hackney_opts`; this client owns the whole connection, so it reads
  `Application.get_env(:ex_aws, :hackney_opts, [recv_timeout: 30_000])` itself and sets its pin options with
  `Keyword.put/3` (hackney takes the FIRST `ssl_options` entry: a prepended duplicate would silently drop the configured ones).

  ## hackney 4.x HEAD answers

  hackney 4.x answers a `HEAD` with the 3-tuple `{:ok, status, headers}` (no body). `ExAws.Request.Hackney` only matches
  the 4-tuple, so the production test connection (`ExAws.S3.head_bucket/1`) raised a `CaseClauseError` against ANY server
  before this client existed. This client maps both shapes to `{:ok, %{status_code:, headers:, body:}}` (`body: ""` for
  a HEAD): a 403 / 404 / 5xx then reaches ExAws as an HTTP status and becomes `{:error, {:http_error, status, _}}`.

  No credential and no request / response content is logged here.
  """

  @behaviour ExAws.Request.HttpClient

  @default_hackney_opts [recv_timeout: 30_000]

  @type target :: %{scheme: String.t(), host: String.t(), ip: :inet.ip_address()}

  @doc """
  ExAws entry point. `http_opts` must carry `pinned_target: target` (set by `Nebu.Media.StorageConfig`); without it, or when
  the URL host is not the pinned host, the request fails closed with `{:error, %{reason: :no_pinned_target |
  :pinned_host_mismatch | :invalid_url}}` and no connection is made.
  """
  @impl ExAws.Request.HttpClient
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    pinned = if is_list(http_opts), do: Keyword.get(http_opts, :pinned_target), else: nil

    with {:ok, %{url: pinned_url, host_header: host_header, scheme: scheme}} <- pin(url, pinned) do
      headers = put_host_header(headers, host_header)

      method
      |> :hackney.request(pinned_url, headers, body, hackney_opts(pinned, scheme))
      |> map_response()
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # hackney 4.x: HEAD -> `{:ok, status, headers}`; every other method, and a redirect even on HEAD -> the 4-tuple.
  defp map_response({:ok, status, resp_headers}), do: map_response({:ok, status, resp_headers, ""})

  # A redirect is never followed (the `Location` is an address nobody checked) and `ExAws` has no clause for 302 / 303 / 307 / 308
  # (it would raise a `CaseClauseError`): report it as an error. 301 (ExAws: `{:error, {:http_error, 301, "redirected"}}`) and
  # 304 (ExAws: success) keep their own ExAws handling.
  defp map_response({:ok, status, _resp_headers, _resp_body}) when status in 300..399 and status not in [301, 304],
    do: {:error, %{reason: {:redirect_not_followed, status}}}

  defp map_response({:ok, status, resp_headers, resp_body}),
    do: {:ok, %{status_code: status, headers: resp_headers, body: resp_body}}

  defp map_response({:error, reason}), do: {:error, %{reason: reason}}

  @doc """
  The pinned form of `url`: `{:ok, %{url:, host_header:, scheme:}}` where `url` connects to the pinned ip (host replaced,
  port / path / query unchanged, an IPv6 ip in brackets, a default port absent), `host_header` is the ORIGINAL authority
  (`host[:port]`, exactly what ExAws signed) and `scheme` is the scheme of the URL (the transport that is really used; the
  `scheme` of the pinned target is the SSRF check's and may be a synthetic one). `{:error, :no_pinned_target}` without a usable target,
  `{:error, :pinned_host_mismatch}` when the URL host is not the pinned host, `{:error, :invalid_url}` for an
  unparseable URL.
  """
  @spec pin(String.t(), term()) ::
          {:ok, %{url: String.t(), host_header: String.t(), scheme: String.t()}}
          | {:error, :no_pinned_target | :pinned_host_mismatch | :invalid_url}
  def pin(url, %{host: pinned_host, ip: ip}) when is_binary(url) and is_binary(pinned_host) and is_tuple(ip) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, authority: authority} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_binary(authority) ->
        if same_host?(host, pinned_host) do
          pinned_url = URI.to_string(%{uri | host: ip_host(ip), authority: nil, userinfo: nil})
          {:ok, %{url: pinned_url, host_header: strip_userinfo(authority), scheme: scheme}}
        else
          {:error, :pinned_host_mismatch}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  def pin(_url, _pinned), do: {:error, :no_pinned_target}

  @doc """
  The hackney options of a pinned request: the configured `:hackney_opts` (default `[recv_timeout: 30_000]`) with
  `follow_redirect: false`, `pool: false` and, for an https request (`scheme`, the scheme of the request URL) to a host
  NAME, the SNI merged into `ssl_options`.
  """
  @spec hackney_opts(target(), String.t()) :: keyword()
  def hackney_opts(%{host: host}, scheme) do
    base = Application.get_env(:ex_aws, :hackney_opts, @default_hackney_opts)

    base
    |> Keyword.put(:follow_redirect, false)
    |> Keyword.put(:pool, false)
    # HTTP/1.1 only: HTTP/2 (https ALPN) carries the host in `:authority` (= the pinned IP) and drops the `Host` header, which
    # would break the SigV4 signature over the original name (and an h3 attempt would not honour the pin either).
    |> Keyword.put(:protocols, [:http1])
    |> put_sni(scheme, host, base)
  end

  # https + host name: SNI = the name (hackney verifies the certificate against the SNI). A literal ip gets no SNI (RFC 6066):
  # hackney then verifies against the ip, as for any literal-ip endpoint.
  defp put_sni(opts, "https", host, base) do
    if ip_literal?(host) do
      opts
    else
      ssl = base |> Keyword.get(:ssl_options, []) |> Keyword.put(:server_name_indication, String.to_charlist(host))
      Keyword.put(opts, :ssl_options, ssl)
    end
  end

  defp put_sni(opts, _scheme, _host, _base), do: opts

  defp ip_literal?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  # The Host value is the signed authority WITHOUT any userinfo (`u@host` is never a Host header value; ExAws builds its URLs
  # without userinfo, so this changes nothing for a signed request).
  defp strip_userinfo(authority), do: authority |> String.split("@") |> List.last()

  defp same_host?(a, b), do: String.downcase(a) == String.downcase(b)

  # `URI.to_string/1` writes an IPv6 host in brackets itself (a pre-bracketed host would be bracketed twice).
  defp ip_host(ip), do: ip |> :inet.ntoa() |> to_string()

  # The Host header the request is signed over, exactly once (hackney would otherwise derive it from the pinned ip).
  defp put_host_header(headers, host_header) do
    rest = Enum.reject(headers, fn {name, _value} -> String.downcase(to_string(name)) == "host" end)
    [{"host", host_header} | rest]
  end
end
