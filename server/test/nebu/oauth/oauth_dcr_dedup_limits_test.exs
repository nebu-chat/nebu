defmodule Nebu.OAuth.OAuthDcrDedupLimitsTest do
  @moduledoc """
  Security review F-1 (partial, the part that needs no trusted-proxy configuration), story
  `oauth-metadata-dcr-admin-approval`, cycle 4:

    * (a) dedup first: `POST /oauth2/register` validates and looks the metadata hash up BEFORE it
      charges the STRICT buckets (50/h per IP, 500/h global). A DEDUP HIT (a known client
      re-registering at every login) only pays the LOOSE bucket (600/h per IP, no global bucket);
      only a request that would INSERT a new row is charged against the strict ones. Junk
      (invalid / unparsable / disabled-path requests) is charged to its OWN invalid-request
      buckets (600/h per IP, 5000/h global; security review F-1 remainder, cycle 5).
    * (b) a per-`client_uri`-host pending cap (`oauth_pending_host_cap`, default 20): NEW metadata
      for a host that already has that many pending rows is a `503 temporarily_unavailable` +
      `Retry-After` like the global cap; dedup hits bypass it.

  Integration tests (real PostgreSQL). The rate-limit clock is frozen (no refill), so bucket
  exhaustion is deterministic. Every new registration uses its OWN registrable domain so the
  (domain, source) pending cap never interferes with the bucket tests.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @strict_per_ip 50
  @strict_global 500

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    {:ok, ids} = Agent.start(fn -> [] end)

    on_exit(fn ->
      T.cleanup_clients(Agent.get(ids, & &1))
      Agent.stop(ids)
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, ids: ids}
  end

  # A valid web registration on a host of its own (unique per call). Since story
  # `oauth-dcr-abuse-hardening` (AH1) the host cap is keyed on the REGISTRABLE DOMAIN, so the unique
  # token is the second-level label (`h<n>-<rand>.com`), not a subdomain of one shared domain.
  defp body(host \\ nil) do
    host = host || "h#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}.com"

    T.web_body(%{
      "client_uri" => "https://" <> host,
      "redirect_uris" => ["https://" <> host <> "/callback"]
    })
  end

  defp register(body, ids, opts) do
    conn = T.register(body, opts)
    if conn.status == 201, do: Agent.update(ids, &[T.json(conn)["client_id"] | &1])
    conn
  end

  describe "F-1a — dedup hits do not spend the strict budget" do
    test "a known client re-registers far more often than the strict per-IP limit allows", %{ids: ids} do
      ip = T.unique_ip()
      b = body()
      first = register(b, ids, ip: ip)
      assert first.status == 201
      id = T.json(first)["client_id"]

      statuses =
        for _ <- 1..(@strict_per_ip + 30) do
          conn = T.register(b, ip: ip)
          {conn.status, T.json(conn)["client_id"]}
        end

      assert Enum.all?(statuses, &(&1 == {201, id})), "dedup hits must all be answered with the same client_id"
    end

    test "dedup hits leave the strict budget for NEW registrations untouched", %{ids: ids} do
      ip = T.unique_ip()
      known = body()
      assert register(known, ids, ip: ip).status == 201
      for _ <- 1..200, do: assert(T.register(known, ip: ip).status == 201)

      # the strict bucket of this IP has lost exactly one token (the first, new registration)
      statuses = for _ <- 1..(@strict_per_ip - 1), do: register(body(), ids, ip: ip).status
      assert Enum.all?(statuses, &(&1 == 201)), "got #{inspect(Enum.uniq(statuses))}"
      assert register(body(), ids, ip: ip).status == 429
    end

    test "the strict per-IP limit applies to NEW registrations only: the 51st is 429, a dedup hit is still 201", %{ids: ids} do
      ip = T.unique_ip()
      bodies = for _ <- 1..@strict_per_ip, do: body()
      for b <- bodies, do: assert(register(b, ids, ip: ip).status == 201)

      conn = register(body(), ids, ip: ip)
      assert conn.status == 429
      assert T.json(conn) == %{"error" => "too_many_requests"}
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
      assert T.header(conn, "access-control-allow-origin") == "*"

      assert T.register(hd(bodies), ip: ip).status == 201, "a dedup hit must not be throttled by the strict bucket"
      # ...and another IP is unaffected
      assert register(body(), ids, ip: T.unique_ip()).status == 201
    end

    test "a throttled NEW registration creates no row", %{ids: ids} do
      ip = T.unique_ip()
      for _ <- 1..@strict_per_ip, do: assert(register(body(), ids, ip: ip).status == 201)

      refused = body()
      assert T.register(refused, ip: ip).status == 429

      {:ok, %{hash: hash}} = Nebu.OAuth.Registration.validate(refused)
      assert T.count_by_hash(hash) == 0
    end

    test "invalid requests never spend the strict budget", %{ids: ids} do
      ip = T.unique_ip()
      for _ <- 1..120, do: assert(T.register(%{"client_uri" => "http://bad"}, ip: ip).status == 400)

      for _ <- 1..@strict_per_ip, do: assert(register(body(), ids, ip: ip).status == 201)
    end

    test "the strict GLOBAL limit applies to new registrations only", %{ids: ids} do
      first = body()
      assert register(first, ids, ip: T.unique_ip()).status == 201

      # 25 new registrations per IP keeps every strict per-IP bucket far below its own limit
      for i <- 2..@strict_global do
        ip = {10, 210, div(i, 25), rem(i, 25) + 1}
        assert register(body(), ids, ip: ip).status == 201, "registration #{i} should still be admitted"
      end

      assert T.register(body(), ip: T.unique_ip()) |> Map.fetch!(:status) == 429
      assert T.register(first, ip: T.unique_ip()).status == 201, "dedup hits are not subject to the strict global bucket"
    end
  end

  # Security review F-1 remainder (cycle 5): junk has its OWN buckets (600/h per IP + 5000/h global)
  # and a dedup hit (every login!) pays only a per-IP loose bucket of 600/h, NO global one.
  describe "F-1 remainder — junk cannot starve dedup hits" do
    test "an IP that exhausted its invalid-request bucket can still re-register a known client", %{ids: ids} do
      ip = T.unique_ip()
      b = body()
      assert register(b, ids, ip: ip).status == 201

      statuses = for _ <- 1..601, do: T.register(%{"client_uri" => "http://bad"}, ip: ip).status
      assert List.last(statuses) == 429, "the junk bucket of this IP must be exhausted"

      conn = T.register(b, ip: ip)
      assert conn.status == 201, "junk must not spend the dedup budget, got #{conn.status}"
    end

    test "a globally exhausted invalid-request bucket does not block dedup hits or new registrations", %{ids: ids} do
      b = body()
      assert register(b, ids, ip: T.unique_ip()).status == 201

      # 5000 junk requests, 25 per IP: only the GLOBAL invalid-request bucket can run dry
      for i <- 1..5000 do
        ip = {10, 220 + div(i, 25 * 256), rem(div(i, 25), 256), rem(i, 25) + 1}
        T.register(%{"client_uri" => "http://bad"}, ip: ip)
      end

      assert T.register(%{"client_uri" => "http://bad"}, ip: T.unique_ip()).status == 429,
             "the global invalid-request bucket must be exhausted"

      assert T.register(b, ip: T.unique_ip()).status == 201, "a dedup hit must survive a junk flood"
      assert register(body(), ids, ip: T.unique_ip()).status == 201, "a new valid registration must too"
    end

    test "dedup hits have NO global bucket: more than 5000/h across many IPs are all answered", %{ids: ids} do
      b = body()
      assert register(b, ids, ip: T.unique_ip()).status == 201

      # 10 IPs x 550 = 5500 requests, every per-IP bucket (600) stays below its limit
      statuses =
        for n <- 1..10, _ <- 1..550 do
          T.register(b, ip: {10, 230, 0, n}).status
        end

      assert Enum.uniq(statuses) == [201]
    end
  end

  describe "F-1a — dedup hits are still bounded by the LOOSE buckets" do
    test "600 requests/hour per IP, then 429 (also for dedup hits)", %{ids: ids} do
      ip = T.unique_ip()
      b = body()
      assert register(b, ids, ip: ip).status == 201

      statuses = for _ <- 1..599, do: T.register(b, ip: ip).status
      assert Enum.all?(statuses, &(&1 == 201))

      conn = T.register(b, ip: ip)
      assert conn.status == 429
      assert T.json(conn) == %{"error" => "too_many_requests"}
      assert T.header(conn, "retry-after")
    end
  end

  describe "F-1b — pending cap per (registrable domain, source)" do
    defp enable_with_host_cap(host_cap) do
      Application.put_env(:nebu_http, :oauth_config_source, fn ->
        %{enabled: true, issuer_url: T.issuer(), pending_host_cap: host_cap}
      end)
    end

    test "NEW metadata above the host cap => 503 temporarily_unavailable + Retry-After + CORS; no row", %{ids: ids} do
      enable_with_host_cap(3)
      ip = T.unique_ip()
      host = "capped-#{System.unique_integer([:positive])}.example.com"
      for _ <- 1..3, do: assert(register(body(host), ids, ip: ip).status == 201)

      refused = body(host)
      conn = T.register(refused, ip: ip)
      T.assert_oauth_error(conn, 503, "temporarily_unavailable")
      assert {n, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert n >= 1
      assert T.header(conn, "access-control-allow-origin") == "*"

      {:ok, %{hash: hash}} = Nebu.OAuth.Registration.validate(refused)
      assert T.count_by_hash(hash) == 0
    end

    test "another source is not refused (N-1): the cap is per source, not per host", %{ids: ids} do
      enable_with_host_cap(3)
      ip = T.unique_ip()
      host = "capped-#{System.unique_integer([:positive])}.example.com"
      for _ <- 1..3, do: assert(register(body(host), ids, ip: ip).status == 201)
      assert T.register(body(host), ip: ip).status == 503

      other = register(body(host), ids, ip: T.unique_ip())
      assert other.status == 201, "a registration from ANOTHER source for the same host must succeed, got #{other.status}"
    end

    test "dedup hits bypass the host cap; other hosts are unaffected", %{ids: ids} do
      enable_with_host_cap(2)
      ip = T.unique_ip()
      host = "capped-#{System.unique_integer([:positive])}.example.com"
      first = body(host)
      assert register(first, ids, ip: ip).status == 201
      assert register(body(host), ids, ip: ip).status == 201

      assert T.register(body(host), ip: ip).status == 503
      assert T.register(first, ip: ip).status == 201, "a known registration is answered although the host is at its cap"
      assert register(body(), ids, ip: ip).status == 201, "another registrable domain has its own cap"
    end

    test "the cap counts PENDING rows only: deciding one frees a slot", %{ids: ids} do
      enable_with_host_cap(1)
      ip = T.unique_ip()
      host = "capped-#{System.unique_integer([:positive])}.example.com"
      first = register(body(host), ids, ip: ip)
      assert first.status == 201
      assert T.register(body(host), ip: ip).status == 503

      assert :ok = Nebu.OAuth.approve_registration(T.json(first)["client_id"], "@admin:test.local")
      assert register(body(host), ids, ip: ip).status == 201
    end

    test "the host is compared case-insensitively and stored on the row", %{ids: ids} do
      enable_with_host_cap(1)
      ip = T.unique_ip()
      host = "mixed-#{System.unique_integer([:positive])}.example.com"
      first = register(body(String.upcase(host)), ids, ip: ip)
      assert first.status == 201
      assert T.client_row(T.json(first)["client_id"])["client_host"] == host
      assert T.register(body(host), ip: ip).status == 503
    end

    test "a missing/invalid stored value falls back to the default cap of 20", %{ids: ids} do
      Application.put_env(:nebu_http, :oauth_config_source, fn -> %{enabled: true, issuer_url: T.issuer()} end)
      assert %{host_cap: 20} = Nebu.OAuth.Config.pending_limits()

      ip = T.unique_ip()
      host = "default-#{System.unique_integer([:positive])}.example.com"
      for _ <- 1..20, do: assert(register(body(host), ids, ip: ip).status == 201)
      assert T.register(body(host), ip: ip).status == 503
    end

    test "subdomains of one registrable domain share the cap of a source (subdomain rotation is closed, gate 3)", %{ids: ids} do
      enable_with_host_cap(2)
      ip = T.unique_ip()
      d = "rot-#{System.unique_integer([:positive])}.example.com"
      assert register(body("a." <> d), ids, ip: ip).status == 201
      assert register(body("b." <> d), ids, ip: ip).status == 201
      assert T.register(body("c." <> d), ip: ip).status == 503
    end
  end
end
