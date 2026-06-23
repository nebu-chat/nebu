defmodule Nebu.Media.HttpFetch do
  @moduledoc """
  HTTP fetch for `preview_url` via Finch. Production default for the
  `:media_http_fetch_module` seam; tests swap it for `Nebu.Web.MediaFakes.HttpFetch`.

  ## SSRF / DNS-rebinding (TOCTOU)

  The SSRF guard (`Nebu.Media.SSRF`) runs in the handler BEFORE this is ever
  reached, so a url pointing at a private/loopback/link-local/metadata address or
  using a non-http(s) scheme never gets here. That early check resolves DNS once,
  but Finch would normally re-resolve the host at connect time — a DNS server can
  return a public IP to the guard and a private IP to the client (TOCTOU). To
  close that gap this module re-validates AND pins the address itself via
  `SSRF.checked_target/1`:

    * `http`  — connects to the validated IP literal, with the original `Host`
      header preserved, so no second (attacker-influenced) DNS lookup occurs.
    * `https` — pinning the IP in the URL would break TLS SNI and certificate
      hostname validation, so the hostname is kept in the URL. The validation is
      still performed here (rejecting a now-private resolution), but the final
      TLS connect re-resolves the host. RESIDUAL CAVEAT: an https target remains
      theoretically rebindable in the window between this validation and Finch's
      connect. Closing it fully requires SNI-preserving IP-pinned TLS, tracked as
      a follow-up.

  Finch does NOT follow redirects, so a 3xx is returned verbatim and never chases
  a redirect into a private address. As defense-in-depth this fetch also caps the
  response body size and the request timeout.

  ## Streamed body cap (security-review F-2)

  The response body is consumed via `Finch.stream_while/5`, NOT the buffering
  `Finch.request/2`. A running byte total is accumulated and the stream is HALTED
  the moment it would exceed `@max_body_bytes` — so a malicious/large preview
  target can never force the core to materialize an unbounded body in memory
  before the cap is applied (the previous `Finch.request/2` buffered the ENTIRE
  upstream body first, an OOM vector). The cap is 1 MiB: more than enough for the
  HTML `<head>` Open Graph tags `extract_og_tags/1` reads, and a tight ceiling on
  per-request allocation. The IP-pinning (http) and SNI handling (https) for SSRF
  are unchanged.
  """

  alias Nebu.Media.SSRF

  @finch Nebu.Media.Finch
  # F-2: tight per-request preview cap — OG tags live in the HTML <head>, so 1 MiB
  # is ample; smaller than the old 2 MB buffer ceiling and now ENFORCED mid-stream.
  @max_body_bytes 1_048_576
  @recv_timeout 5_000

  @spec fetch(String.t()) ::
          {:ok, %{status: non_neg_integer(), headers: list(), body: binary()}}
          | {:error, term()}
  def fetch(url) do
    case SSRF.checked_target(url) do
      {:ok, target} -> do_fetch(url, target)
      {:error, _} = err -> err
    end
  end

  # http: pin the validated IP, preserve the original Host header (no re-resolve).
  defp do_fetch(url, %{scheme: "http", host: host, ip: ip}) do
    pinned = put_host(url, ip_to_string(ip))
    request(pinned, [{"accept", "text/html"}, {"host", host}])
  end

  # https: keep hostname for correct SNI/cert validation (residual TOCTOU caveat).
  defp do_fetch(url, %{scheme: "https"}) do
    request(url, [{"accept", "text/html"}])
  end

  defp request(url, headers) do
    req = Finch.build(:get, url, headers)
    acc = %{status: nil, headers: [], body: <<>>}

    # F-2: stream and abort the moment the running body total would exceed the
    # cap — never buffers the full upstream body. Truncated bodies are still
    # parseable for OG tags in <head>; an over-cap stream halts cleanly.
    case Finch.stream_while(req, @finch, acc, &on_chunk/2, receive_timeout: @recv_timeout) do
      {:ok, %{status: status, headers: rheaders, body: body}} ->
        {:ok, %{status: status, headers: rheaders, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp on_chunk({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp on_chunk({:headers, headers}, acc), do: {:cont, %{acc | headers: headers}}

  defp on_chunk({:data, data}, %{body: body} = acc) do
    remaining = @max_body_bytes - byte_size(body)

    cond do
      remaining <= 0 ->
        {:halt, acc}

      byte_size(data) > remaining ->
        {:halt, %{acc | body: body <> binary_part(data, 0, remaining)}}

      true ->
        {:cont, %{acc | body: body <> data}}
    end
  end

  defp on_chunk({:trailers, _trailers}, acc), do: {:cont, acc}

  # Rewrite only the host component, keeping scheme/port/path/query intact.
  defp put_host(url, host) do
    url |> URI.parse() |> Map.put(:host, host) |> URI.to_string()
  end

  defp ip_to_string(ip) do
    ip |> :inet.ntoa() |> to_string()
  end
end
