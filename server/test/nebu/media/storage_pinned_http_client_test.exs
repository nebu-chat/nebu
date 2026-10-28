defmodule Nebu.Media.StoragePinnedHttpClientTest do
  @moduledoc """
  Unit tests of `Nebu.Media.PinnedHttpClient` (story `storage-test-pinned-target`, D2), the `ExAws.Request.HttpClient` that
  connects to the CHECKED ip while the `Host` header, the SigV4 signature, the TLS SNI and the certificate hostname
  verification keep the ORIGINAL host name.

  The client does not apply the SSRF guard (the guard runs before, in `StorageConfig.test_connection/1`), so these tests
  use LOOPBACK recorders (127.0.0.1) and need no network interface: they run everywhere, also on a laptop. The end-to-end
  tests through the SSRF guard and the real `ExAws` call are in `storage_pinned_target_test.exs` (they need an interface).

  The host name used here (`storage.pinned.test`, reserved TLD) never resolves: a request that reaches the recorder proves
  the client did not resolve the name.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_pinned_target_support.exs", __DIR__)

  alias Nebu.Media.PinnedHttpClient, as: Client
  alias Nebu.Media.PinnedTargetTestSupport, as: Support

  @host "storage.pinned.test"
  @loopback {127, 0, 0, 1}
  @v6 {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
  @timeouts [recv_timeout: 5_000, connect_timeout: 2_000]

  @env_keys [{:ex_aws, :hackney_opts}, {:ex_aws, :retries}]

  setup do
    saved = Enum.map(@env_keys, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)
    Application.put_env(:ex_aws, :hackney_opts, @timeouts)
    Application.put_env(:ex_aws, :retries, max_attempts: 1, base_backoff_in_ms: 1, max_backoff_in_ms: 1)

    on_exit(fn ->
      Enum.each(saved, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  defp target(host \\ @host, ip \\ @loopback, scheme \\ "http"), do: %{scheme: scheme, host: host, ip: ip}

  defp recorder!(opts) do
    recorder = Support.start_recorder(Keyword.merge([ip: @loopback, tag: :rec], opts))
    on_exit(fn -> Support.stop_recorder(recorder) end)
    recorder
  end

  defp head(url, pinned, headers \\ nil) do
    uri = URI.parse(url)
    headers = headers || [{"host", uri.authority}, {"x-amz-date", "20260101T000000Z"}]
    Client.request(:head, url, "", headers, pinned_target: pinned)
  end

  # ── pin/2: the URL rewrite (pure) ──────────────────────────────────────────

  describe "pin/2 rewrites the connect address and keeps the original authority as the Host value" do
    test "http with a port and a query: the host becomes the ip, port / path / query stay, the Host value is name:port" do
      assert {:ok, %{url: "http://10.0.0.5:9000/bucket?x=1&y=2", host_header: "storage.pinned.test:9000"}} =
               Client.pin("http://storage.pinned.test:9000/bucket?x=1&y=2", target(@host, {10, 0, 0, 5}))
    end

    test "a default port (443 / 80) is absent from the rewritten url AND from the Host value (what ExAws signs)" do
      assert {:ok, %{url: "https://10.0.0.5/bucket", host_header: "storage.pinned.test"}} =
               Client.pin("https://storage.pinned.test/bucket", target(@host, {10, 0, 0, 5}, "https"))

      assert {:ok, %{url: "http://10.0.0.5/bucket", host_header: "storage.pinned.test"}} =
               Client.pin("http://storage.pinned.test/bucket", target(@host, {10, 0, 0, 5}))
    end

    test "an IPv6 pin is written in brackets, with and without a port; the Host value keeps the name" do
      assert {:ok, %{url: "http://[2001:db8::1]:9000/bucket", host_header: "storage.pinned.test:9000"}} =
               Client.pin("http://storage.pinned.test:9000/bucket", target(@host, @v6))

      assert {:ok, %{url: "https://[2001:db8::1]/bucket", host_header: "storage.pinned.test"}} =
               Client.pin("https://storage.pinned.test/bucket", target(@host, @v6, "https"))
    end

    test "an IPv6 LITERAL endpoint keeps its brackets in the url and in the Host value" do
      assert {:ok, %{url: "http://[2001:db8::1]:9000/bucket", host_header: "[2001:db8::1]:9000"}} =
               Client.pin("http://[2001:db8::1]:9000/bucket", target("2001:db8::1", @v6))
    end

    test "user info in the url never reaches the Host value or the connect url" do
      assert {:ok, %{url: url, host_header: "storage.pinned.test:9000"}} =
               Client.pin("http://user:pw@storage.pinned.test:9000/bucket", target(@host, {10, 0, 0, 5}))

      refute url =~ "@"
      refute url =~ "user"
    end

    test "fail closed: no pinned target (missing, nil, not a map) is an error, never a url to connect to" do
      assert {:error, :no_pinned_target} = Client.pin("http://#{@host}:9000/b", nil)
      assert {:error, :no_pinned_target} = Client.pin("http://#{@host}:9000/b", :not_a_map)
      assert {:error, :no_pinned_target} = Client.pin("http://#{@host}:9000/b", %{host: @host})
    end

    test "fail closed: a url whose host is not the pinned host is an error (the pin of another host never applies)" do
      assert {:error, :pinned_host_mismatch} = Client.pin("http://other.pinned.test:9000/b", target())
      assert {:error, :pinned_host_mismatch} = Client.pin("http://127.0.0.1:9000/b", target())
    end
  end

  # ── hackney options (pure): http_opts REPLACES hackney_opts, so the client merges them ──

  describe "hackney_opts/1 builds the connection options" do
    test "no redirect following, no keep-alive pool, no proxy option, the configured timeouts are kept" do
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [follow_redirect: true, pool: :default, max_redirect: 5])
      opts = Client.hackney_opts(target(), "http")

      assert opts[:follow_redirect] == false
      assert opts[:pool] == false
      assert opts[:recv_timeout] == 5_000 and opts[:connect_timeout] == 2_000
      refute Keyword.has_key?(opts, :proxy)
      assert Keyword.get_values(opts, :follow_redirect) == [false]
      assert Keyword.get_values(opts, :pool) == [false]
      assert Keyword.get(opts, :ssl_options) == nil, "an http target gets no ssl_options"
    end

    test "HTTP/1.1 only (protocols: [:http1]), also when a configuration asks for more: HTTP/2 would send the pinned ip as :authority" do
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [protocols: [:http2, :http1]])

      for scheme <- ["http", "https"] do
        assert Keyword.get_values(Client.hackney_opts(target(), scheme), :protocols) == [[:http1]]
      end
    end

    test "without any :hackney_opts config the ExAws default (recv_timeout 30_000) applies" do
      Application.delete_env(:ex_aws, :hackney_opts)
      assert Client.hackney_opts(target(), "http")[:recv_timeout] == 30_000
    end

    test "https: the SNI is the host NAME as a charlist, MERGED into the configured ssl_options (one ssl_options entry, cacerts kept)" do
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [cacerts: [:ca_der], verify: :verify_peer]])
      opts = Client.hackney_opts(target(@host, @loopback, "https"), "https")

      assert [ssl] = Keyword.get_values(opts, :ssl_options), "hackney takes the FIRST ssl_options entry: there must be exactly one"
      assert ssl[:server_name_indication] == String.to_charlist(@host)
      assert ssl[:cacerts] == [:ca_der]
      assert ssl[:verify] == :verify_peer
    end

    test "https: a configured server_name_indication is replaced by the pinned host name (the pin decides the SNI)" do
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [server_name_indication: ~c"evil.pinned.test"]])
      opts = Client.hackney_opts(target(@host, @loopback, "https"), "https")

      assert [ssl] = Keyword.get_values(opts, :ssl_options)
      assert Keyword.get_values(ssl, :server_name_indication) == [String.to_charlist(@host)]
    end

    test "https with an IP-literal host: no SNI is added (RFC 6066), the configured ssl_options stay untouched" do
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [cacerts: [:ca_der]]])
      opts = Client.hackney_opts(target("127.0.0.1", @loopback, "https"), "https")

      assert Keyword.get(opts, :ssl_options) == [cacerts: [:ca_der]]
      assert Keyword.get(hackney_opts_without_config(target("127.0.0.1", @loopback, "https")), :ssl_options) == nil
    end
  end

  defp hackney_opts_without_config(target) do
    Application.delete_env(:ex_aws, :hackney_opts)
    Client.hackney_opts(target, "https")
  end

  # ── live requests against a loopback recorder ─────────────────────────────

  describe "request/5 (http): connects to the pinned ip, keeps Host, maps the hackney 4.x HEAD 3-tuple" do
    test "HEAD: the request reaches the pinned ip with the ORIGINAL Host (name:port), method, path and query; the answer is mapped" do
      a = recorder!([])

      assert {:ok, %{status_code: 200, headers: headers, body: ""}} = head("http://#{@host}:#{a.port}/bucket?acl=1", target())
      assert is_list(headers)

      assert_received {:request, :rec, req}
      assert req.method == "HEAD" and req.target == "/bucket?acl=1"
      assert req.headers["host"] == "#{@host}:#{a.port}"
      assert req.headers["x-amz-date"] == "20260101T000000Z", "the other headers pass unchanged"
    end

    test "a Host header that came in under another spelling / value is replaced by the original authority (one Host header)" do
      a = recorder!([])

      assert {:ok, %{status_code: 200}} =
               head("http://#{@host}:#{a.port}/bucket", target(), [{"Host", "attacker.example"}, {"x-amz-date", "20260101T000000Z"}])

      assert_received {:request, :rec, req}
      assert req.headers["host"] == "#{@host}:#{a.port}"
      assert Enum.count(req.raw_headers, fn {name, _} -> String.downcase(name) == "host" end) == 1
    end

    test "a non-HEAD request (4-tuple of hackney) is mapped the same way" do
      a = recorder!([])

      assert {:ok, %{status_code: 200, body: "", headers: _}} =
               Client.request(:get, "http://#{@host}:#{a.port}/bucket", "", [{"host", "#{@host}:#{a.port}"}], pinned_target: target())

      assert_received {:request, :rec, %{method: "GET"}}
    end

    test "a connection error is an {:error, %{reason: _}} (the ExAws contract), never a raise" do
      {:ok, listen} = :gen_tcp.listen(0, ip: @loopback)
      {:ok, {_, closed_port}} = :inet.sockname(listen)
      :gen_tcp.close(listen)

      assert {:error, %{reason: _reason}} = head("http://#{@host}:#{closed_port}/bucket", target())
    end

    test "an IPv6 pin connects to the bracketed address (skipped silently where the host has no IPv6 loopback)" do
      case :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
        {:ok, probe} ->
          :gen_tcp.close(probe)
          a = recorder!(ip: {0, 0, 0, 0, 0, 0, 0, 1})

          assert {:ok, %{status_code: 200}} = head("http://#{@host}:#{a.port}/bucket", target(@host, {0, 0, 0, 0, 0, 0, 0, 1}))
          assert_received {:request, :rec, req}
          assert req.headers["host"] == "#{@host}:#{a.port}"

        {:error, _no_ipv6} ->
          :ok
      end
    end
  end

  describe "request/5: a redirect is NOT followed (it would bypass the pin)" do
    test "a 302 to another loopback listener is an error, not followed: the second listener never sees a connection, even with follow_redirect: true configured" do
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [follow_redirect: true, max_redirect: 5])
      other = recorder!(tag: :other)
      a = recorder!(status: 302, headers: [{"location", "http://127.0.0.1:#{other.port}/stolen"}])

      assert {:error, %{reason: {:redirect_not_followed, 302}}} = head("http://#{@host}:#{a.port}/bucket", target())

      assert_received {:request, :rec, _req}
      refute_received {:accepted, :other}, "the redirect was followed to an address the SSRF guard never checked"
      refute_receive {:accepted, :other}, 200
    end
  end

  describe "through ExAws.request/2: a redirect answer is an error tuple, never a crash" do
    for status <- [302, 303, 307, 308] do
      test "HEAD answered #{status} (Location: another listener) -> {:error, _}; that listener is never contacted" do
        other = recorder!(tag: :other)
        a = recorder!(status: unquote(status), headers: [{"location", "http://127.0.0.1:#{other.port}/stolen"}])

        assert {:error, _reason} =
                 "pinned-bucket"
                 |> ExAws.S3.head_bucket()
                 |> ExAws.request(exaws_overrides(a.port))

        assert_received {:request, :rec, _req}
        refute_receive {:accepted, :other}, 200
      end
    end
  end

  describe "request/5: fail closed" do
    test "without a pinned_target in http_opts the request is refused and NO connection is made" do
      a = recorder!([])

      assert {:error, %{reason: :no_pinned_target}} = Client.request(:head, "http://127.0.0.1:#{a.port}/b", "", [], [])
      assert {:error, %{reason: :no_pinned_target}} = Client.request(:head, "http://127.0.0.1:#{a.port}/b", "", [], pinned_target: nil)
      assert {:error, %{reason: :no_pinned_target}} = Client.request(:head, "http://127.0.0.1:#{a.port}/b", "", [])

      refute_receive {:accepted, :rec}, 200
    end

    test "a url host that differs from the pinned host is refused and NO connection is made (the pin of another host never applies)" do
      a = recorder!([])

      assert {:error, %{reason: :pinned_host_mismatch}} = head("http://127.0.0.1:#{a.port}/b", target())
      assert {:error, %{reason: :pinned_host_mismatch}} = head("http://other.pinned.test:#{a.port}/b", target())

      refute_receive {:accepted, :rec}, 200
    end

    test "an unparseable url is an error, not a raise" do
      assert {:error, %{reason: _}} = Client.request(:head, "not a url", "", [], pinned_target: target())
    end
  end

  # ── https ──────────────────────────────────────────────────────────────────

  describe "request/5 (https): SNI + certificate hostname verification for the ORIGINAL name" do
    test "connects to the pinned ip, sends the host name as SNI and accepts a certificate valid for the NAME" do
      chain = Support.tls_chain(dNSName: String.to_charlist(@host))
      a = recorder!(tls: chain.server_config)
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [cacerts: chain.cacerts]])

      # the pinned target carries the SSRF check's SYNTHETIC scheme (http, see StorageConfig): the transport is the URL's
      assert {:ok, %{status_code: 200}} = head("https://#{@host}:#{a.port}/bucket", target(@host, @loopback, "http"))

      assert_received {:sni, :rec, @host}
      assert_received {:request, :rec, req}
      assert req.tls
      assert req.headers["host"] == "#{@host}:#{a.port}"
    end

    test "a server that prefers HTTP/2 (ALPN h2, http/1.1) is still spoken to in HTTP/1.1 with the ORIGINAL Host (SigV4 covers it)" do
      chain = Support.tls_chain(dNSName: String.to_charlist(@host))
      a = recorder!(tls: chain.server_config ++ [alpn_preferred_protocols: ["h2", "http/1.1"]])
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [cacerts: chain.cacerts]])

      assert {:ok, %{status_code: 200}} = head("https://#{@host}:#{a.port}/bucket", target(@host, @loopback, "https"))

      assert_received {:request, :rec, req}
      assert req.method == "HEAD" and req.target == "/bucket", "the request was not HTTP/1.1 (an HTTP/2 preface was recorded instead)"
      assert req.headers["host"] == "#{@host}:#{a.port}"
    end

    test "a configured ssl_options server_name_indication cannot override the pinned name (SNI on the wire is the host name)" do
      chain = Support.tls_chain(dNSName: String.to_charlist(@host))
      a = recorder!(tls: chain.server_config)

      Application.put_env(
        :ex_aws,
        :hackney_opts,
        @timeouts ++ [ssl_options: [cacerts: chain.cacerts, server_name_indication: ~c"evil.pinned.test"]]
      )

      assert {:ok, %{status_code: 200}} = head("https://#{@host}:#{a.port}/bucket", target(@host, @loopback, "https"))
      assert_received {:sni, :rec, @host}
      refute_received {:sni, :rec, "evil.pinned.test"}
    end

    test "a certificate valid for the IP only is refused (the name is verified, not the pinned ip) and no request is sent" do
      chain = Support.tls_chain(iPAddress: @loopback)
      a = recorder!(tls: chain.server_config)
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [cacerts: chain.cacerts]])

      assert {:error, %{reason: _reason}} = head("https://#{@host}:#{a.port}/bucket", target(@host, @loopback, "https"))

      assert_received {:sni, :rec, @host}
      assert_receive {:tls_failed, :rec, _reason}, 2_000
      refute_received {:request, :rec, _req}
    end

    test "a certificate for another host name is refused and no request is sent" do
      chain = Support.tls_chain(dNSName: ~c"other.pinned.test")
      a = recorder!(tls: chain.server_config)
      Application.put_env(:ex_aws, :hackney_opts, @timeouts ++ [ssl_options: [cacerts: chain.cacerts]])

      assert {:error, %{reason: _reason}} = head("https://#{@host}:#{a.port}/bucket", target(@host, @loopback, "https"))

      assert_received {:sni, :rec, @host}
      assert_receive {:tls_failed, :rec, _reason}, 2_000
      refute_received {:request, :rec, _req}
    end

    test "a certificate of an untrusted CA is refused (no ssl_options: the default trust store decides)" do
      chain = Support.tls_chain(dNSName: String.to_charlist(@host))
      a = recorder!(tls: chain.server_config)

      assert {:error, %{reason: _reason}} = head("https://#{@host}:#{a.port}/bucket", target(@host, @loopback, "https"))

      assert_received {:sni, :rec, @host}
      assert_receive {:tls_failed, :rec, _reason}, 2_000
      refute_received {:request, :rec, _req}
    end
  end

  # ── the ExAws pipeline around the client: error statuses, no crash ────────

  describe "through ExAws.request/2 with the pin client: a HEAD error status is an error tuple, never a crash" do
    for status <- [403, 404, 503] do
      test "HEAD answered #{status} -> {:error, {:http_error, #{status}, _}}" do
        a = recorder!(status: unquote(status))

        assert {:error, {:http_error, unquote(status), _response}} =
                 "pinned-bucket"
                 |> ExAws.S3.head_bucket()
                 |> ExAws.request(exaws_overrides(a.port))

        assert_received {:request, :rec, %{method: "HEAD"}}
      end
    end

    test "HEAD answered 200 -> {:ok, _} with a SigV4 signature that verifies against the ORIGINAL Host (what MinIO does)" do
      a = recorder!([])

      assert {:ok, %{status_code: 200}} =
               "pinned-bucket"
               |> ExAws.S3.head_bucket()
               |> ExAws.request(exaws_overrides(a.port))

      assert_received {:request, :rec, req}
      assert req.headers["host"] == "#{@host}:#{a.port}"
      assert :ok = Support.verify_sigv4(req, "pinned-secret-key")
    end
  end

  defp exaws_overrides(port) do
    [
      access_key_id: "AKIAPINNEDCLIENT",
      secret_access_key: "pinned-secret-key",
      host: @host,
      scheme: "http://",
      port: port,
      region: "us-east-1",
      http_client: Client,
      http_opts: [pinned_target: target()]
    ]
  end
end
