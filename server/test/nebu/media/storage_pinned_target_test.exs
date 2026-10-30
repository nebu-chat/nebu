defmodule Nebu.Media.StoragePinnedTargetTest do
  @moduledoc """
  ATDD (red phase) for story `storage-test-pinned-target` (follow-up `do`, part a): the request of
  `Nebu.Media.StorageConfig.test_connection/1` connects to the address the SSRF guard CHECKED, never to a second
  resolution of the host name (DNS rebinding, time-of-check / time-of-use).

  These tests drive the REAL default test connection (`ExAws.S3.head_bucket/1` through `ExAws.request/2`): the
  `:media_storage_test_connection_fun` seam is NOT set, except in the AC1 test, which only looks at what is handed
  to the request.

  ## Seam contracts the implementation must provide (D5)

    * `Application.put_env(:nebu_http, :media_ssrf_resolver, fun)` — `fun.(host :: String.t()) ::
      {:ok, [:inet.ip_address(), ...]} | {:error, atom()}`. Consulted by `Nebu.Media.SSRF` (`checked_target/2`) for every
      host that is NOT an IP literal, INSTEAD of `:inet.getaddrs/2` (both families). Unset: `:inet.getaddrs/2` as before.
      A literal IP never consults it.
    * the candidate map handed to `:media_storage_test_connection_fun` carries the checked target under
      `:pinned_target` (`%{scheme: String.t(), host: String.t(), ip: :inet.ip_address()}`, D1) next to the
      existing keys.
    * https trust: the request honours `config :ex_aws, :hackney_opts` `ssl_options` (e.g. `cacerts:`), MERGED with the
      SNI / hostname options of the pin (hackney takes the FIRST `ssl_options` entry, so a pinned client that passes
      its own `ssl_options` must merge the configured ones). The TLS tests use that documented ExAws knob to trust
      a throw-away test CA; the production default (certifi) is unchanged.

  ## How the tests see where a request went

  The SSRF guard blocks 127.0.0.0/8 unconditionally, so the "checked" address cannot be loopback. The checked address
  `A` is a local interface address (see `Nebu.Media.PinnedTargetTestSupport.local_ip!/0`, `allow_private` opt-in); the
  "rebinding" address is 127.0.0.1, a second recorder on the same port. The host name is `localhost` in the rebinding test
  (the system resolver, which an un-pinned client uses, answers 127.0.0.1) or `storage.pinned.test` (reserved TLD:
  the system resolver answers NXDOMAIN, so a request that reaches `A` proves the host name was not resolved again).

  ## Where this runs (read before you run it on a laptop)

  The recorder-based tests (tagged `:needs_iface_ip`) need a non-loopback IPv4 interface address that accepts inbound
  connections from the host itself. They run reliably only in Linux / a container (the GitLab unit job,
  `make test-unit-elixir`). On macOS the application firewall often blocks the inbound connection to the interface address
  (the test then fails with a refused / timed-out request), so run them in the container there. Without any such interface
  `test/test_helper.exs` excludes the tag locally and FAILS HARD when `CI` is set: the coverage must not vanish silently.
  The pin client itself is unit-tested against loopback recorders in `storage_pinned_http_client_test.exs` (no interface needed).
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_pinned_target_support.exs", __DIR__)

  alias Nebu.Media.PinnedTargetTestSupport, as: Support
  alias Nebu.Media.SSRF
  alias Nebu.Media.StorageConfig

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter (same shape as storage_config_test.exs). Test-private."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}
    def insert!(struct, _opts \\ []), do: struct
  end

  @host "storage.pinned.test"
  @access_key "AKIAPINNEDTARGET"
  @secret_key "pinned-target-secret-key"
  @public_ip {93, 184, 216, 34}
  @hackney_timeouts [recv_timeout: 5_000, connect_timeout: 2_000]

  @env_keys [
    {:nebu_http, :media_storage_test_connection_fun},
    {:nebu_http, :media_ssrf_resolver},
    {:nebu_http, :media_storage_allow_private_endpoints},
    {:nebu_http, :media_storage_env_reader},
    {:nebu_http, :media_storage_config_loader},
    {:nebu_http, :media_storage_config_writer},
    {:nebu_http, :admin_secret_at_rest},
    {:ex_aws, :retries},
    {:ex_aws, :hackney_opts}
  ]

  setup do
    saved = Enum.map(@env_keys, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)
    Enum.each(@env_keys, fn {app, key} -> Application.delete_env(app, key) end)

    # One attempt, no backoff: a refused / failed request must fail the test fast, not retry ten times.
    Application.put_env(:ex_aws, :retries, max_attempts: 1, base_backoff_in_ms: 1, max_backoff_in_ms: 1)

    # Bounded timeouts for EVERY test (a request that is refused by a firewall or never answered must fail in seconds, not hang
    # for hackney's 8 s connect / 30 s receive defaults). The old value is restored by the on_exit below (it is in @env_keys).
    Application.put_env(:ex_aws, :hackney_opts, @hackney_timeouts)

    on_exit(fn ->
      Enum.each(saved, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp candidate(endpoint, overrides \\ %{}) do
    Map.merge(
      %{endpoint: endpoint, bucket: "pinned-bucket", region: "us-east-1", use_ssl: false, access_key: @access_key, secret_key: @secret_key},
      overrides
    )
  end

  defp allow_private!, do: Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, true)

  defp put_resolver(fun), do: Application.put_env(:nebu_http, :media_ssrf_resolver, fun)

  # A resolver that always answers `ips` and tells the test every lookup.
  defp resolver(ips) do
    test_pid = self()

    fn host ->
      send(test_pid, {:resolved, host})
      {:ok, ips}
    end
  end

  # DNS rebinding: the 1st lookup answers `first` (what the SSRF guard sees), every later one `later`.
  #
  # NOTE on the "later" branch: it is never reached through THIS seam by a correct implementation (the seam is consulted
  # only by the SSRF check, and the check resolves once). A second resolution by the HTTP client does not go through the
  # seam at all: it goes through the SYSTEM resolver, which answers 127.0.0.1 for the name `localhost`. That is the real
  # rebinding signal of the test (a connection to the 127.0.0.1 recorder); the "later" answer only documents the intent and
  # makes a second seam consultation (a second check that would use another answer) visible as the wrong address.
  defp rebinding_resolver(first, later) do
    test_pid = self()
    counter = :counters.new(1, [])

    fn host ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      send(test_pid, {:resolved, host})
      if n == 0, do: {:ok, [first]}, else: {:ok, [later]}
    end
  end

  defp recorder!(opts) do
    recorder = Support.start_recorder(opts)
    on_exit(fn -> Support.stop_recorder(recorder) end)
    recorder
  end

  defp flush_resolved(acc \\ 0) do
    receive do
      {:resolved, _host} -> flush_resolved(acc + 1)
    after
      0 -> acc
    end
  end

  # ── SSRF resolver seam (D5 precondition) ───────────────────────────────────

  describe "Nebu.Media.SSRF resolver seam (:media_ssrf_resolver)" do
    test "checked_target/2 resolves a host name through the seam and returns the first answer as the pinned ip" do
      put_resolver(resolver([@public_ip, {93, 184, 216, 35}]))

      assert {:ok, %{scheme: "https", host: "rebind.example.test", ip: @public_ip}} =
               SSRF.checked_target("https://rebind.example.test/path")

      assert_received {:resolved, "rebind.example.test"}
    end

    test "every answer is checked: a private address among public ones blocks the host (:blocked_address)" do
      put_resolver(resolver([@public_ip, {10, 0, 0, 5}]))
      assert {:error, :blocked_address} = SSRF.checked_target("https://rebind.example.test/")

      put_resolver(resolver([{127, 0, 0, 1}]))
      assert {:error, :blocked_address} = SSRF.checked_target("https://rebind.example.test/", allow_private: true)
    end

    test "a resolver error is returned unchanged (the same atoms as a failing :inet.getaddrs/2)" do
      put_resolver(fn _host -> {:error, :nxdomain} end)
      assert {:error, :nxdomain} = SSRF.checked_target("https://rebind.example.test/")

      put_resolver(fn _host -> {:error, :timeout} end)
      assert {:error, :timeout} = SSRF.checked_target("https://rebind.example.test/")
    end

    test "an IP literal never consults the seam" do
      put_resolver(fn host -> flunk("the resolver was consulted for the literal #{inspect(host)}") end)

      assert {:ok, %{ip: {10, 1, 2, 3}}} = SSRF.checked_target("http://10.1.2.3:9000/", allow_private: true)
      assert {:ok, %{ip: @public_ip}} = SSRF.checked_target("http://93.184.216.34/")
    end
  end

  # ── AC1: the checked target is carried to the request ──────────────────────

  describe "AC1: test_connection/1 carries the checked target" do
    test "the candidate handed to the request carries the pinned target (host + first checked ip) and the host is resolved once" do
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
        send(test_pid, {:test_connection_called, candidate})
        :ok
      end)

      put_resolver(resolver([@public_ip, {93, 184, 216, 35}]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:9000", %{use_ssl: true}))

      assert_received {:test_connection_called, c}
      assert %{host: @host, ip: @public_ip} = c.pinned_target, "the {:ok, target} of the SSRF check is thrown away"
      # the existing candidate keys are unchanged
      assert c.endpoint == "#{@host}:9000" and c.bucket == "pinned-bucket" and c.use_ssl == true
      assert c.access_key == @access_key and c.secret_key == @secret_key

      assert flush_resolved() == 1, "the host must be resolved exactly once (check = pin), not once for the check and again for the request"
    end

    @tag :needs_iface_ip
    test "upsert/1 (save) validates (resolves once, writes) and performs no request: no connection reaches the recorder" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      test_pid = self()

      # The audit write of a successful save goes to an in-process fake (same `:compliance, :repo` seam as
      # storage_config_test.exs), never to a real DB; the old values are restored on exit.
      saved_repo = Application.fetch_env(:compliance, :repo)
      Application.put_env(:compliance, :repo, FakeAuditRepo)

      on_exit(fn ->
        case saved_repo do
          {:ok, value} -> Application.put_env(:compliance, :repo, value)
          :error -> Application.delete_env(:compliance, :repo)
        end
      end)

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
        send(test_pid, {:writer_called, columns})
        :ok
      end)

      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      put_resolver(resolver([a.ip]))

      # the save path validates only (D4): it checks the endpoint (one resolution) and writes, no HTTP request is issued
      # (a changed endpoint needs both keys in the same save, which are encrypted for the write:
      # media-storage-uses-admin-config, fix B)
      Application.put_env(:nebu_http, :admin_secret_at_rest, "pinned-target-test-at-rest-secret")

      assert :ok =
               StorageConfig.upsert(
                 %{endpoint: "#{@host}:#{a.port}", access_key: "AKIA-SAVE-0001", secret_key: "save-secret-0002"},
                 "atdd-actor"
               )

      assert_received {:resolved, @host}
      assert_received {:writer_called, %{"endpoint" => _}}
      refute_received {:accepted, :checked}, "the save path must not issue a request"
    end
  end

  # ── AC2 / AC3: the request connects to the checked ip, Host + SigV4 keep the name ──

  describe "AC2: DNS rebinding simulation (http)" do
    @describetag :needs_iface_ip

    test "1st resolution = checked address A, every later one = 127.0.0.1: the request goes to A and NEVER to 127.0.0.1" do
      allow_private!()
      a_ip = Support.local_ip!()
      # a 127.0.0.1 recorder on the SAME port as A (3 attempts: the port that is free on the interface may be taken on loopback)
      {a, b} = Support.start_recorder_pair([ip: a_ip, tag: :checked], ip: {127, 0, 0, 1}, tag: :rebound)
      on_exit(fn -> Support.stop_recorder(a) end)
      on_exit(fn -> Support.stop_recorder(b) end)
      put_resolver(rebinding_resolver(a_ip, {127, 0, 0, 1}))

      result = StorageConfig.test_connection(candidate("localhost:#{a.port}"))

      refute_received {:accepted, :rebound},
                      "a connection reached 127.0.0.1: the host name was resolved a SECOND time by the request (DNS rebinding window)"

      assert_received {:request, :checked, req}
      assert req.method == "HEAD" and req.target in ["/pinned-bucket", "/pinned-bucket/"]
      assert req.headers["host"] == "localhost:#{a.port}", "the Host header keeps the original host name"
      assert result == :ok
    end

    test "the request reaches the checked ip although the host name does not resolve at all (no resolution by the HTTP client)" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      put_resolver(resolver([a.ip]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))

      assert_received {:request, :checked, req}
      assert req.headers["host"] == "#{@host}:#{a.port}"
    end

    test "the host name is resolved exactly once per test connection (check = pin)" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      put_resolver(resolver([a.ip]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))

      assert flush_resolved() == 1
    end

    test "with several answers the FIRST checked address is the one connected to (D3)" do
      allow_private!()
      a_ip = Support.local_ip!()
      a = recorder!(ip: a_ip, tag: :checked)
      # a second public-looking address that is not reachable here: a client that tried the 2nd answer would fail / hang
      put_resolver(resolver([a_ip, {192, 0, 2, 7}]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))
      assert_received {:request, :checked, _req}
    end
  end

  describe "AC2: one attempt" do
    @describetag :needs_iface_ip

    test "a failing request (503) is made ONCE although ex_aws is configured for more attempts (retries override of the test connection only)" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked, status: 503)
      Application.put_env(:ex_aws, :retries, max_attempts: 5, base_backoff_in_ms: 1, max_backoff_in_ms: 1)
      put_resolver(resolver([a.ip]))

      assert {:error, {:http_error, 503, _}} = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))

      assert_received {:accepted, :checked}
      refute_receive {:accepted, :checked}, 300
    end
  end

  describe "AC3: Host header and SigV4 signature" do
    @describetag :needs_iface_ip

    test "the request carries the ORIGINAL Host (host:port) and the SigV4 signature, computed over it, verifies like on a real S3 server" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      put_resolver(resolver([a.ip]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))

      assert_received {:request, :checked, req}
      assert req.headers["host"] == "#{@host}:#{a.port}"
      assert req.headers["authorization"] =~ "Credential=#{@access_key}/"
      assert req.headers["authorization"] =~ ~r/SignedHeaders=[^,]*\bhost\b/
      assert :ok = Support.verify_sigv4(req, @secret_key)
    end
  end

  # ── AC3 (https): SNI + certificate hostname validation for the ORIGINAL name ──

  describe "AC3: https keeps SNI and certificate hostname validation for the original host name" do
    @describetag :needs_iface_ip

    test "connects to the checked ip, sends the host name as SNI and accepts a certificate valid for the NAME" do
      allow_private!()
      chain = Support.tls_chain(dNSName: String.to_charlist(@host))
      a = recorder!(ip: Support.local_ip!(), tag: :tls, tls: chain.server_config)
      Application.put_env(:ex_aws, :hackney_opts, @hackney_timeouts ++ [ssl_options: [cacerts: chain.cacerts]])
      put_resolver(resolver([a.ip]))

      result = StorageConfig.test_connection(candidate("#{@host}:#{a.port}", %{use_ssl: true}))

      assert_received {:sni, :tls, @host}
      assert_received {:request, :tls, req}
      assert req.tls
      assert req.headers["host"] == "#{@host}:#{a.port}"
      assert :ok = Support.verify_sigv4(req, @secret_key)
      assert result == :ok
    end

    test "a certificate for the IP only (no DNS name) is refused: the name is verified, not the pinned ip; the request is never sent" do
      allow_private!()
      a_ip = Support.local_ip!()
      chain = Support.tls_chain(iPAddress: a_ip)
      a = recorder!(ip: a_ip, tag: :tls, tls: chain.server_config)
      Application.put_env(:ex_aws, :hackney_opts, @hackney_timeouts ++ [ssl_options: [cacerts: chain.cacerts]])
      put_resolver(resolver([a_ip]))

      result = StorageConfig.test_connection(candidate("#{@host}:#{a.port}", %{use_ssl: true}))

      assert_received {:sni, :tls, @host}
      assert {:error, _reason} = result
      assert_receive {:tls_failed, :tls, _reason}, 2_000
      refute_received {:request, :tls, _req}, "the request was sent although the certificate is not valid for the host name"
    end

    test "a certificate for another host name is refused and the request is never sent" do
      allow_private!()
      chain = Support.tls_chain(dNSName: ~c"other.pinned.test")
      a = recorder!(ip: Support.local_ip!(), tag: :tls, tls: chain.server_config)
      Application.put_env(:ex_aws, :hackney_opts, @hackney_timeouts ++ [ssl_options: [cacerts: chain.cacerts]])
      put_resolver(resolver([a.ip]))

      result = StorageConfig.test_connection(candidate("#{@host}:#{a.port}", %{use_ssl: true}))

      assert_received {:sni, :tls, @host}
      assert {:error, _reason} = result
      assert_receive {:tls_failed, :tls, _reason}, 2_000
      refute_received {:request, :tls, _req}
    end

    test "a certificate of an untrusted CA is still refused (the default trust store, not the pin, decides)" do
      allow_private!()
      chain = Support.tls_chain(dNSName: String.to_charlist(@host))
      a = recorder!(ip: Support.local_ip!(), tag: :tls, tls: chain.server_config)
      # no ssl_options (only the timeouts of the setup): the test root is not in certifi
      put_resolver(resolver([a.ip]))

      assert {:error, _reason} = StorageConfig.test_connection(candidate("#{@host}:#{a.port}", %{use_ssl: true}))
      assert_received {:sni, :tls, @host}, "the TLS handshake did not reach the recorder (the refute below would be vacuous)"
      assert_receive {:tls_failed, :tls, _reason}, 2_000
      refute_received {:request, :tls, _req}
    end
  end

  # ── AC4: unchanged behaviour ───────────────────────────────────────────────

  describe "AC4: literal ip, use_ssl: false, allow_private, blocked and unresolvable endpoints behave as before" do
    # NOTE (found while writing the ATDD): this one is red BEFORE the pin too, for a pre-existing reason: hackney 4.x answers a
    # HEAD with `{:ok, status, headers}` (3-tuple, no body) and `ExAws.Request.Hackney` (ex_aws 2.7.0) only matches the 4-tuple,
    # so the production default test connection ends in `{:error, %CaseClauseError{}}` against ANY server. The own
    # `ExAws.Request.HttpClient` of the pin has to map the 3-tuple to `{:ok, %{status_code:, headers:, body: ""}}`.
    @tag :needs_iface_ip
    test "a literal-IP endpoint works unchanged: Host is ip:port, the resolver is never consulted, the signature verifies" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      put_resolver(fn host -> flunk("the resolver was consulted for the literal #{inspect(host)}") end)

      ip_string = a.ip |> :inet.ntoa() |> to_string()
      assert :ok = StorageConfig.test_connection(candidate("#{ip_string}:#{a.port}"))

      assert_received {:request, :checked, req}
      assert req.headers["host"] == "#{ip_string}:#{a.port}"
      assert :ok = Support.verify_sigv4(req, @secret_key)
    end

    @tag :needs_iface_ip
    test "a host that resolves to a private address is refused WITHOUT the opt-in, before any request (:invalid_endpoint)" do
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      put_resolver(resolver([{10, 0, 0, 5}]))

      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))
      assert_received {:resolved, @host}, "the guard did not run (the resolver was not consulted): the refute below would be vacuous"
      refute_received {:accepted, :checked}
    end

    @tag :needs_iface_ip
    test "one private address among several answers blocks the endpoint, before any request (:invalid_endpoint)" do
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      put_resolver(resolver([@public_ip, {10, 0, 0, 5}]))

      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))
      assert_received {:resolved, @host}, "the guard did not run (the resolver was not consulted): the refute below would be vacuous"
      refute_received {:accepted, :checked}
    end

    test "a host that resolves to loopback stays refused WITH the allow_private opt-in, before any request (:invalid_endpoint)" do
      allow_private!()
      b = recorder!(ip: {127, 0, 0, 1}, tag: :rebound)
      put_resolver(resolver([{127, 0, 0, 1}]))

      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("#{@host}:#{b.port}"))
      assert_received {:resolved, @host}, "the guard did not run (the resolver was not consulted): the refute below would be vacuous"
      refute_received {:accepted, :rebound}
    end

    @tag :needs_iface_ip
    test "an unresolvable host fails before any request with the same atom (:invalid_endpoint) and the same admin message" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      test_pid = self()

      put_resolver(fn host ->
        send(test_pid, {:resolved, host})
        {:error, :nxdomain}
      end)

      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))
      assert_received {:resolved, @host}, "the guard did not run (the resolver was not consulted): the refute below would be vacuous"
      refute_received {:accepted, :checked}

      assert StorageConfig.describe_invalid_endpoint("#{@host}:#{a.port}") =~ "could not be resolved via DNS (nxdomain)"
    end

    test "an endpoint with user info (user@host) is refused before any resolution or request, on the test and on the save path" do
      put_resolver(fn host -> flunk("the resolver was consulted for #{inspect(host)}") end)
      Application.put_env(:nebu_http, :media_storage_config_writer, fn _columns, _set_at -> flunk("the writer was reached") end)
      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)

      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("user@#{@host}:9000"))
      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("#{@host}@93.184.216.34:9000"))
      assert {:error, :invalid_endpoint} = StorageConfig.upsert(%{endpoint: "user:pw@#{@host}:9000"}, "atdd-actor")
      assert StorageConfig.describe_invalid_endpoint("user@#{@host}:9000") =~ "no user info"
    end

    test "a scheme-prefixed endpoint is still refused before any resolution or request (:invalid_endpoint)" do
      put_resolver(fn host -> flunk("the resolver was consulted for #{inspect(host)}") end)

      assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate("https://#{@host}:9000"))
    end
  end

  # ── AC5: never persists, stored credentials only for the stored endpoint ───

  describe "AC5: no persistence, stored credentials stay bound to the stored endpoint" do
    @describetag :needs_iface_ip

    setup do
      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      :ok
    end

    test "a pinned test connection never reaches the DB writer" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)
      test_pid = self()

      Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
        send(test_pid, {:writer_called, columns})
        :ok
      end)

      put_resolver(resolver([a.ip]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:#{a.port}"))
      assert_received {:request, :checked, _req}
      refute_received {:writer_called, _columns}
    end

    test "blank keys + the STORED endpoint: the stored access key signs the request to the pinned ip of the stored endpoint" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_ENDPOINT" => "#{@host}:#{a.port}",
          "NEBU_MINIO_BUCKET" => "pinned-bucket",
          "NEBU_S3_REGION" => "us-east-1",
          "NEBU_MINIO_USE_SSL" => "false",
          "NEBU_MINIO_ACCESS_KEY" => "STOREDACCESSKEY",
          "NEBU_MINIO_SECRET_KEY" => "stored-secret-key"
        }
      end)

      put_resolver(resolver([a.ip]))

      assert :ok = StorageConfig.test_connection(candidate("#{@host}:#{a.port}", %{access_key: "", secret_key: nil}))

      assert_received {:request, :checked, req}
      assert req.headers["authorization"] =~ "Credential=STOREDACCESSKEY/"
      assert :ok = Support.verify_sigv4(req, "stored-secret-key")
    end

    test "blank keys + ANOTHER endpoint: {:error, :secret_required}, nothing is resolved for a request and nothing is sent" do
      allow_private!()
      a = recorder!(ip: Support.local_ip!(), tag: :checked)

      Application.put_env(:nebu_http, :media_storage_env_reader, fn ->
        %{
          "NEBU_MINIO_ENDPOINT" => "stored.pinned.test:9000",
          "NEBU_MINIO_BUCKET" => "pinned-bucket",
          "NEBU_S3_REGION" => "us-east-1",
          "NEBU_MINIO_USE_SSL" => "false",
          "NEBU_MINIO_ACCESS_KEY" => "STOREDACCESSKEY",
          "NEBU_MINIO_SECRET_KEY" => "stored-secret-key"
        }
      end)

      put_resolver(resolver([a.ip]))

      assert {:error, :secret_required} = StorageConfig.test_connection(candidate("#{@host}:#{a.port}", %{access_key: nil, secret_key: nil}))
      assert_received {:resolved, @host}, "the endpoint check did not run: the refute below would be vacuous"
      refute_received {:accepted, :checked}, "stored credentials were sent to another endpoint"
    end
  end
end
