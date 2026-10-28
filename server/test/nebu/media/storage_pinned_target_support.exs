defmodule Nebu.Media.PinnedTargetTestSupport do
  @moduledoc """
  Test support for story `storage-test-pinned-target` (D5): a request recorder that plays the part of the S3 endpoint,
  a SigV4 verifier (what MinIO does with the `Host` header), a local-interface lookup and a TLS test chain with a
  configurable subjectAltName.

  Why a non-loopback interface address: the SSRF guard blocks loopback, link-local and metadata addresses
  UNCONDITIONALLY, so the "checked" address of a test can never be 127.0.0.1. A recorder that must RECEIVE the
  pinned request therefore listens on a local interface address (Docker: the container's `eth0`), which the guard
  accepts as private (`NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS` opt-in) or as public. The "rebinding" address of a test is
  127.0.0.1, a second recorder on the SAME port, which must never see a connection.

  The recorder sends its owner:

    * `{:accepted, tag}`                      a TCP connection was accepted (before any TLS / request bytes);
    * `{:request, tag, request}`              a complete request head; `request` is
                                              `%{method, target, headers (lowercase name => value), raw_headers, tls: boolean}`;
    * `{:sni, tag, host_binary}`              TLS only: the server name the client sent;
    * `{:tls_failed, tag, reason}`            TLS only: the handshake did not complete.
  """

  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @doc """
  A non-loopback, non-link-local IPv4 address of this host (an interface that is up) that this host can really CONNECT to
  itself (self-probe: listen on the address, connect to it, accept within 500 ms), or `nil` when there is none (a macOS laptop
  without network or behind an application firewall, a sandbox). `test/test_helper.exs` excludes the `:needs_iface_ip` tests
  when this is `nil` and fails hard when the `CI` environment variable is set (the coverage must not vanish silently in CI).
  """
  def local_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_name, opts} ->
          flags = Keyword.get(opts, :flags, [])

          if :up in flags and :loopback not in flags do
            opts |> Keyword.get_values(:addr) |> Enum.filter(&match?({_, _, _, _}, &1)) |> Enum.reject(&match?({169, 254, _, _}, &1))
          else
            []
          end
        end)
        |> Enum.find(&reachable?/1)

      _ ->
        nil
    end
  end

  defp reachable?(ip) do
    with {:ok, listen} <- :gen_tcp.listen(0, [:binary, active: false, ip: ip]),
         {:ok, {_, port}} <- :inet.sockname(listen) do
      result =
        case :gen_tcp.connect(ip, port, [:binary, active: false], 500) do
          {:ok, client} ->
            accepted =
              case :gen_tcp.accept(listen, 500) do
                {:ok, server} ->
                  :gen_tcp.close(server)
                  true

                _ ->
                  false
              end

            :gen_tcp.close(client)
            accepted

          _ ->
            false
        end

      :gen_tcp.close(listen)
      result
    else
      _ -> false
    end
  end

  @doc "Like `local_ip/0`, raising when there is none (only reachable when the `:needs_iface_ip` exclusion was bypassed)."
  def local_ip! do
    local_ip() ||
      raise "storage-test-pinned-target tests need a non-loopback IPv4 interface address " <>
              "(the SSRF guard blocks 127.0.0.0/8 unconditionally); none was found"
  end

  @doc """
  Starts a recorder listening on `{ip, port}` (`port: 0` picks a free one). Options: `:ip`, `:port`, `:tag`,
  `:owner` (default `self()`), `:tls` (a `ssl` server option list, e.g. `tls_chain/1`'s `server_config`),
  `:status` (default 200), `:headers` (extra response headers, a list of `{name, value}`, default none). Returns `%{pid, port, ip, tag}`.
  """
  def start_recorder(opts) do
    owner = Keyword.get(opts, :owner, self())
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        ip = Keyword.fetch!(opts, :ip)
        tag = Keyword.fetch!(opts, :tag)
        port = Keyword.get(opts, :port, 0)
        tls = Keyword.get(opts, :tls)

        listen_result =
          if tls do
            :ssl.listen(
              port,
              [:binary, active: false, reuseaddr: true, ip: ip] ++ tls ++ [sni_fun: sni_fun(owner, tag, tls)]
            )
          else
            :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: ip])
          end

        case listen_result do
          {:ok, listen} ->
            {:ok, {_, bound}} = if tls, do: :ssl.sockname(listen), else: :inet.sockname(listen)
            send(parent, {ref, {:ok, bound}})
            accept_loop(listen, tls != nil, owner, tag, {Keyword.get(opts, :status, 200), Keyword.get(opts, :headers, [])})

          {:error, reason} ->
            send(parent, {ref, {:error, reason}})
        end
      end)

    receive do
      {^ref, {:ok, bound}} -> %{pid: pid, port: bound, ip: Keyword.fetch!(opts, :ip), tag: Keyword.fetch!(opts, :tag)}
      {^ref, {:error, reason}} -> raise "recorder could not listen on #{inspect(Keyword.fetch!(opts, :ip))}: #{inspect(reason)}"
    after
      5_000 -> raise "recorder did not start"
    end
  end

  @doc """
  Starts recorder `a` (port picked by the OS) and recorder `b` on the SAME port with the given options (two different
  addresses, e.g. an interface address and 127.0.0.1). The port that is free on `a`'s address may be taken on `b`'s,
  so this retries up to `attempts` times with a fresh port. Returns `{a, b}`.
  """
  def start_recorder_pair(a_opts, b_opts, attempts \\ 3) do
    a = start_recorder(a_opts)

    try do
      {a, start_recorder(Keyword.put(b_opts, :port, a.port))}
    rescue
      e ->
        stop_recorder(a)
        if attempts > 1, do: start_recorder_pair(a_opts, b_opts, attempts - 1), else: reraise(e, __STACKTRACE__)
    end
  end

  def stop_recorder(%{pid: pid}), do: Process.exit(pid, :kill)

  defp sni_fun(owner, tag, tls) do
    fn host ->
      send(owner, {:sni, tag, List.to_string(host)})
      tls
    end
  end

  defp accept_loop(listen, tls?, owner, tag, status) do
    accepted = if tls?, do: :ssl.transport_accept(listen), else: :gen_tcp.accept(listen)

    case accepted do
      {:ok, socket} ->
        send(owner, {:accepted, tag})
        handle(socket, tls?, owner, tag, status)
        accept_loop(listen, tls?, owner, tag, status)

      {:error, :closed} ->
        :ok

      {:error, _other} ->
        accept_loop(listen, tls?, owner, tag, status)
    end
  end

  defp handle(socket, true, owner, tag, status) do
    case :ssl.handshake(socket, 5_000) do
      {:ok, tls_socket} ->
        serve(tls_socket, :ssl, owner, tag, true, status)

      {:error, reason} ->
        send(owner, {:tls_failed, tag, reason})
    end
  end

  defp handle(socket, false, owner, tag, status), do: serve(socket, :gen_tcp, owner, tag, false, status)

  defp serve(socket, mod, owner, tag, tls?, {status, extra_headers}) do
    case read_head(socket, mod, <<>>) do
      {:ok, head} ->
        send(owner, {:request, tag, parse_head(head, tls?)})
        extra = Enum.map_join(extra_headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)
        mod.send(socket, "HTTP/1.1 #{status} OK\r\ncontent-length: 0\r\nconnection: close\r\n" <> extra <> "\r\n")

      :error ->
        :ok
    end

    mod.close(socket)
  end

  defp read_head(socket, mod, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case mod.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, mod, acc <> data)
        {:error, _} -> :error
      end
    end
  end

  defp parse_head(head, tls?) do
    [head_part | _] = String.split(head, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head_part, "\r\n")
    [method, target | _] = String.split(request_line, " ")

    raw =
      Enum.map(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {name, String.trim(value)}
      end)

    %{
      method: method,
      target: target,
      raw_headers: raw,
      headers: Map.new(raw, fn {k, v} -> {String.downcase(k), v} end),
      tls: tls?
    }
  end

  @doc """
  Recomputes the AWS SigV4 signature of a recorded request exactly like an S3 server does (the signed `host`
  header is the value the client SENT; a request whose `Host` header differs from the signed host cannot verify).
  Returns `:ok` or `{:error, reason}`.
  """
  def verify_sigv4(%{method: method, target: target, headers: headers}, secret_key) do
    auth = Map.get(headers, "authorization", "")

    with [_, access_key, date, region, service, signed, signature] <-
           Regex.run(
             ~r/^AWS4-HMAC-SHA256 Credential=([^\/]+)\/(\d{8})\/([^\/]+)\/([^\/]+)\/aws4_request,\s*SignedHeaders=([^,]+),\s*Signature=([0-9a-f]+)$/,
             auth
           ) do
      signed_names = String.split(signed, ";")
      [path | query] = String.split(target, "?", parts: 2)

      canonical_headers =
        Enum.map_join(signed_names, "\n", fn name -> name <> ":" <> Map.get(headers, name, "<missing>") end)

      payload = if "x-amz-content-sha256" in signed_names, do: Map.get(headers, "x-amz-content-sha256"), else: @empty_sha256

      canonical =
        Enum.join(
          [String.upcase(method), path, Enum.join(query), canonical_headers <> "\n", signed, payload],
          "\n"
        )

      amz_date = Map.get(headers, "x-amz-date", "")

      string_to_sign =
        Enum.join(
          ["AWS4-HMAC-SHA256", amz_date, "#{date}/#{region}/#{service}/aws4_request", hex(:crypto.hash(:sha256, canonical))],
          "\n"
        )

      key =
        ("AWS4" <> secret_key)
        |> hmac(date)
        |> hmac(region)
        |> hmac(service)
        |> hmac("aws4_request")

      expected = hex(hmac(key, string_to_sign))

      if expected == signature do
        :ok
      else
        {:error, {:bad_signature, access_key: access_key, signed: signed_names, host: Map.get(headers, "host")}}
      end
    else
      _ -> {:error, {:no_sigv4_authorization, auth}}
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  @doc """
  A throw-away TLS chain (root CA + a server certificate signed by it). `san` is the subjectAltName list of the
  server certificate, e.g. `[dNSName: ~c"storage.pinned.test"]` or `[iPAddress: {10, 0, 0, 5}]`.
  Returns `%{server_config: [...], cacerts: [der]}`: `server_config` goes to `start_recorder(tls: ...)`, `cacerts` is
  the trust anchor a client must be given (hackney ships `certifi`, the test root is not in it).

  RSA keys (EC chains of `pkix_test_data/1` do not complete a TLS 1.3 handshake here).
  """
  def tls_chain(san) do
    san =
      Enum.map(san, fn
        {:iPAddress, {a, b, c, d}} -> {:iPAddress, [a, b, c, d]}
        other -> other
      end)

    key = {:rsa, 2048, 65_537}

    %{server_config: cfg} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: key],
          peer: [key: key, extensions: [{:Extension, {2, 5, 29, 17}, false, san}]]
        },
        client_chain: %{root: [], peer: []}
      })

    %{server_config: cfg, cacerts: Keyword.fetch!(cfg, :cacerts)}
  end
end
