defmodule Nebu.Web.ClientIPIntegrationTest do
  @moduledoc """
  Acceptance tests for story `oauth-trusted-proxy-client-ip` (P1), AC5, through the FULL
  `Nebu.Web.Router` (the resolution plug lives there; a direct sub-router call would bypass it, TP10).

    * AC5.1 — two clients behind ONE trusted peer get two login buckets (429 isolation)
    * AC5.2 — OAuth buckets (`oauth_jwks`, `oauth_register_invalid`, `oauth_authorize`) are keyed per
              forwarded client and never by the proxy address
    * AC5.3 — spoof: an untrusted peer rotating XFF values stays in ONE bucket
    * AC5.4 — default regression: without configuration the key is the peer, exactly as before
    * AC5.5 — `@tag :integration` (DB): `created_from_ip` stores the resolved client IP (exact address)

  The limiter is ENABLED (setup follows `rate_limit_test.exs`): `reset_rate_limits/0` deletes
  `:rate_limit_disabled`, freezes `:rate_limit_clock_fn` and empties the ETS table; the OS escape
  hatch must not be "true". `async: false`, `configure/1` reset in `on_exit`.

  Bucket keys are asserted directly in the ETS table (no need to exhaust 600/h): the table holds
  `{key, tokens, ts}` objects, a bare string key for the RateLimit plug tiers and `{tag, ip}` for the
  OAuth buckets.

  Security review cycle 1: IPv6 rate-limit keys are the /64 network (`Nebu.Web.ClientIP.bucket/1`);
  stored addresses (`created_from_ip`) keep the exact address (`get/1`).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T

  @table :nebu_http_rate_limit_buckets
  @router_opts Nebu.Web.Router.init([])

  @proxy {10, 0, 0, 5}
  @proxy_s "10.0.0.5"

  setup do
    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "ClientIPIntegrationTest requires the limiter ENABLED — NEBU_RATE_LIMIT_DISABLED must not be \"true\""

    # start from "no trusted proxy" even if another module leaked a set (m-2)
    Nebu.Web.ClientIP.configure(nil)
    T.enable_oauth()
    T.reset_rate_limits()

    on_exit(fn ->
      Nebu.Web.ClientIP.configure(nil)
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    :ok
  end

  defp configure(spec), do: Nebu.Web.ClientIP.configure(spec)

  # login with SEVERAL x-forwarded-for header lines (request order)
  defp login_lines(peer, lines) do
    c =
      conn(:post, "/_matrix/client/v3/login", "not json")
      |> put_req_header("content-type", "application/json")

    headers = c.req_headers ++ Enum.map(lines, &{"x-forwarded-for", &1})
    Nebu.Web.Router.call(%{c | remote_ip: peer, req_headers: headers}, @router_opts)
  end

  defp login(peer, xff) do
    c =
      conn(:post, "/_matrix/client/v3/login", "not json")
      |> put_req_header("content-type", "application/json")

    c = if xff, do: put_req_header(c, "x-forwarded-for", xff), else: c
    Nebu.Web.Router.call(%{c | remote_ip: peer}, @router_opts)
  end

  defp keys, do: if(:ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table) |> Enum.map(&elem(&1, 0)))

  # bare-string keys (RateLimit plug tiers)
  defp ip_keys, do: Enum.filter(keys(), &is_binary/1)

  # `{tag, ip}` keys of one OAuth family
  defp family_keys(tag), do: for({^tag, ip} <- keys(), is_binary(ip), do: ip)

  defp mentions_proxy?(keys) do
    Enum.any?(keys, fn
      k when is_binary(k) -> k == @proxy_s
      {_tag, ip} when is_binary(ip) -> ip == @proxy_s
      _ -> false
    end)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.1 — login isolation behind one trusted proxy
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.1 — two clients behind one trusted peer" do
    test "client A exhausts its login burst (11th => 429 M_LIMIT_EXCEEDED); client B is unaffected" do
      configure("10.0.0.0/8")

      statuses = for _ <- 1..10, do: login(@proxy, "203.0.113.7").status
      refute 429 in statuses, "the first 10 logins of client A are within the burst"

      eleventh = login(@proxy, "203.0.113.7")
      assert eleventh.status == 429
      assert Jason.decode!(eleventh.resp_body)["errcode"] == "M_LIMIT_EXCEEDED"

      b = login(@proxy, "203.0.113.8")
      refute b.status == 429, "client B behind the same proxy must have its own bucket"
    end

    test "the per-client keys are the forwarded addresses, not the proxy" do
      configure("10.0.0.0/8")
      login(@proxy, "203.0.113.7")
      login(@proxy, "203.0.113.8")

      keys = ip_keys()
      assert "203.0.113.7" in keys
      assert "203.0.113.8" in keys
      refute @proxy_s in keys
    end

    test "trusted hops to the right of the client are skipped (rightmost untrusted wins)" do
      configure("10.0.0.0/8")
      login(@proxy, "198.51.100.1, 203.0.113.7, 10.0.0.9")
      keys = ip_keys()
      assert "203.0.113.7" in keys
      refute "198.51.100.1" in keys, "the client-written left-hand element must be ignored"
    end

    test "the refresh tier shares the per-client bare key with login (TP8: shared across tiers)" do
      configure("10.0.0.0/8")

      c =
        conn(:post, "/_matrix/client/v3/refresh", "not json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-forwarded-for", "203.0.113.7")

      Nebu.Web.Router.call(%{c | remote_ip: @proxy}, @router_opts)
      assert ip_keys() == ["203.0.113.7"]
    end
  end

  describe "AC5.1 — header shapes through the router (never a raise)" do
    test "two x-forwarded-for header LINES are joined in request order" do
      configure("10.0.0.0/8")
      login_lines(@proxy, ["203.0.113.7", "10.0.0.9"])
      assert ip_keys() == ["203.0.113.7"]
    end

    test "duplicated header lines: the client-written first line cannot displace the proxy-appended one" do
      configure("10.0.0.0/8")
      login_lines(@proxy, ["198.51.100.1", "203.0.113.7"])
      assert ip_keys() == ["203.0.113.7"]
    end

    test "invalid UTF-8 LEFT of the client resolves the client" do
      configure("10.0.0.0/8")
      resp = login(@proxy, <<0xC3, 0x28>> <> ", 203.0.113.7")
      refute resp.status >= 500
      assert ip_keys() == ["203.0.113.7"]
    end

    test "invalid UTF-8 as an intermediate hop falls back to the proxy address and answers normally" do
      configure("10.0.0.0/8")
      resp = login(@proxy, "203.0.113.7, " <> <<0xC3, 0x28>> <> ", 10.0.0.9")
      refute resp.status >= 500
      assert ip_keys() == [@proxy_s]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.2 — OAuth buckets keyed per forwarded client
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.2 — OAuth bucket keys" do
    test "{\"oauth_jwks\", ip} holds the two client addresses and NO key with the proxy address" do
      configure("10.0.0.0/8")

      # the signing-key lookup needs the DB; the bucket is charged BEFORE it (NoSuchRepo answers the
      # lookup with an error instead of touching a database), which is all that matters here
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)

      for xff <- ["203.0.113.7", "203.0.113.8"] do
        T.get("/oauth2/jwks", ip: @proxy, xff: xff)
      end

      ips = family_keys("oauth_jwks")
      assert "203.0.113.7" in ips
      assert "203.0.113.8" in ips
      refute mentions_proxy?(keys()), "no key may contain the proxy address, got #{inspect(keys())}"
    end

    test "{\"oauth_register_invalid\", ip} (junk DCR body) is keyed per forwarded client" do
      configure("10.0.0.0/8")

      for xff <- ["203.0.113.7", "203.0.113.8"] do
        T.register("this is not json", ip: @proxy, xff: xff)
      end

      ips = family_keys("oauth_register_invalid")
      assert "203.0.113.7" in ips
      assert "203.0.113.8" in ips
      refute mentions_proxy?(keys()), "no key may contain the proxy address, got #{inspect(keys())}"
    end

    test "{\"oauth_authorize\", ip} is keyed per forwarded client (charged before the DB)" do
      configure("10.0.0.0/8")
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)

      for xff <- ["203.0.113.7", "203.0.113.8"] do
        T.authorize([{"response_type", "code"}], ip: @proxy, xff: xff)
      end

      ips = family_keys("oauth_authorize")
      assert "203.0.113.7" in ips
      assert "203.0.113.8" in ips
      refute mentions_proxy?(keys()), "no key may contain the proxy address, got #{inspect(keys())}"
    end

    test "{\"oauth_register_invalid\", ip} with an untrusted peer ignores XFF" do
      configure("10.0.0.0/8")
      T.register("this is not json", ip: {198, 51, 100, 9}, xff: "203.0.113.7")
      assert family_keys("oauth_register_invalid") == ["198.51.100.9"]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.3 — spoofing from an untrusted peer
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.3 — an untrusted peer cannot choose its bucket" do
    test "11 logins with 11 DIFFERENT XFF values: the 11th is 429, the only per-IP key is the peer" do
      configure("10.0.0.0/8")
      peer = {198, 51, 100, 9}

      statuses = for i <- 1..11, do: login(peer, "203.0.113.#{i}").status

      assert List.last(statuses) == 429, "rotating XFF must not escape the bucket, got #{inspect(statuses)}"
      refute 429 in Enum.take(statuses, 10)
      assert ip_keys() == ["198.51.100.9"]
    end

    test "an untrusted peer behind a configured set that sends garbage XFF is still bucketed by the peer" do
      configure("10.0.0.0/8")
      login({198, 51, 100, 9}, String.duplicate(",", 10_000))
      assert ip_keys() == ["198.51.100.9"]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.4 — default regression (no configuration)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.4 — default (empty trusted set) behaves exactly as before the story" do
    # Characterization of the default: without configuration the key is the direct peer (IPv4
    # unchanged; IPv6 aggregated to its /64, cycle 1).
    test "peer 10.0.0.5 with XFF 203.0.113.7: the key is the peer" do
      login(@proxy, "203.0.113.7")
      assert ip_keys() == [@proxy_s]
    end

    test "an unconfigured deployment never honours XFF on the OAuth buckets either" do
      T.register("this is not json", ip: @proxy, xff: "203.0.113.7")
      assert family_keys("oauth_register_invalid") == [@proxy_s]
    end

    test "a stale legacy NEBU_TRUSTED_PROXY-style value must not enable trust: only the CIDR variable counts" do
      # TP1: a NEW variable name on purpose; config that merely looks like "true" trusts nobody
      # the ignored value logs ONE boot warning; capture it so the suite output stays clean
      ExUnit.CaptureLog.capture_log(fn -> configure("true") end)
      login(@proxy, "203.0.113.7")
      assert ip_keys() == [@proxy_s]
    end

    test "IPv6 peers are bucketed by their /64 network (canonical form)" do
      {:ok, v6} = :inet.parse_strict_address(~c"2001:db8::1")
      login(v6, nil)
      assert ip_keys() == ["2001:db8::/64"]
    end

    test "two addresses of one /64 share the login bucket (11th => 429), another /64 is independent" do
      {:ok, a} = :inet.parse_strict_address(~c"2001:db8:1:2::1")
      {:ok, other_64} = :inet.parse_strict_address(~c"2001:db8:1:3::1")

      statuses = for i <- 1..11, do: login(put_elem(a, 7, i), nil).status
      assert List.last(statuses) == 429, "rotating the host part of one /64 must not mint fresh buckets"
      refute 429 in Enum.take(statuses, 10)
      refute login(other_64, nil).status == 429
      assert Enum.sort(ip_keys()) == ["2001:db8:1:2::/64", "2001:db8:1:3::/64"]
    end

    test "an OAuth bucket of an IPv6 client is the /64 too" do
      {:ok, v6} = :inet.parse_strict_address(~c"2001:db8:9:9::5")
      T.register("this is not json", ip: v6)
      assert family_keys("oauth_register_invalid") == ["2001:db8:9:9::/64"]
    end

    test "11 logins from one peer still hit the burst (shared bucket, unchanged rate)" do
      statuses = for _ <- 1..11, do: login({192, 0, 2, 77}, nil).status
      assert List.last(statuses) == 429
      refute 429 in Enum.take(statuses, 10)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.5 — created_from_ip (DB)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.5 — created_from_ip stores the resolved client IP" do
    @describetag :integration

    setup do
      {:ok, ids} = Agent.start(fn -> [] end)

      on_exit(fn ->
        T.cleanup_clients(Agent.get(ids, & &1))
        Agent.stop(ids)
      end)

      {:ok, track: fn id -> Agent.update(ids, &[id | &1]); id end}
    end

    defp created_from_ip(client_id) do
      %{rows: [[ip]]} =
        T.sql!("SELECT split_part(created_from_ip::text, '/', 1) FROM oauth_clients WHERE client_id = $1", [client_id])

      ip
    end

    test "with configure(\"10.0.0.0/8\"): peer 10.0.0.5 + XFF 203.0.113.7 => '203.0.113.7'", %{track: track} do
      configure("10.0.0.0/8")
      conn = T.register(T.web_body(), ip: @proxy, xff: "203.0.113.7")
      assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
      id = track.(T.json(conn)["client_id"])
      assert created_from_ip(id) == "203.0.113.7"
    end

    test "without configuration: the same request stores the peer '10.0.0.5'", %{track: track} do
      configure(nil)
      conn = T.register(T.web_body(), ip: @proxy, xff: "203.0.113.7")
      assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
      id = track.(T.json(conn)["client_id"])
      assert created_from_ip(id) == "10.0.0.5"
    end

    test "created_from_ip keeps the EXACT IPv6 address (no /64 aggregation of stored data)", %{track: track} do
      {:ok, v6} = :inet.parse_strict_address(~c"2001:db8:9:9::5")
      configure(nil)
      conn = T.register(T.web_body(), ip: v6)
      assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
      id = track.(T.json(conn)["client_id"])
      assert created_from_ip(id) == "2001:db8:9:9::5"
    end

    test "an untrusted peer cannot choose created_from_ip", %{track: track} do
      configure("10.0.0.0/8")
      conn = T.register(T.web_body(), ip: {198, 51, 100, 9}, xff: "203.0.113.7")
      assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
      id = track.(T.json(conn)["client_id"])
      assert created_from_ip(id) == "198.51.100.9"
    end
  end
end
