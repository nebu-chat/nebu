defmodule Nebu.OAuth.OAuthDcrRateLimitCorsTest do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval`, AC6 (rate limiting + CORS)
  and the AC2 rate-limit/OPTIONS clauses.

  Rate limit (AC2/AC6, reworked by security review F-1a in cycle 4 and F-1 remainder in cycle 5):
  `POST /oauth2/register` has THREE bucket families:

    * INVALID (own buckets: 600 req/hour per IP, 5000 req/hour globally): charged by a request that
      is junk — unparsable/oversize/invalid body or OAuth disabled. Exceeding => `429` instead of
      the 4xx. Junk never touches the budget of a dedup hit (every login depends on it).
    * LOOSE (600 req/hour per IP, NO global bucket): charged by every VALID request, so it is the
      only budget of a dedup hit.
    * STRICT (50/hour per IP, 500/hour globally): only a request that would INSERT a new row.

  LOOSE and STRICT need the database and are tested in `oauth_dcr_dedup_limits_test.exs`.
  Exceeding => `429` with body EXACTLY `{"error":"too_many_requests"}` (OAuth style, no errcode)
  and a `Retry-After` header.

  The tests here drive the INVALID limiter with deliberately INVALID bodies (rejected before any DB
  access). The frozen `:rate_limit_clock_fn` seam makes bucket exhaustion deterministic (no
  refill).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  # INVALID-request buckets (loose/strict ones: oauth_dcr_dedup_limits_test.exs)
  @per_ip 600
  @global 5000
  @bucket_table :nebu_http_rate_limit_buckets

  setup do
    T.enable_oauth()
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    :ok
  end

  defp invalid_register(ip, opts \\ []), do: T.register(%{"client_uri" => "http://bad"}, [ip: ip] ++ opts)

  describe "AC2/AC6 — per-IP rate limit on invalid POST /oauth2/register requests" do
    test "the 601st invalid request from one IP within the window is 429; the first 600 are not" do
      ip = T.unique_ip()
      statuses = for _ <- 1..(@per_ip + 1), do: invalid_register(ip).status

      assert Enum.take(statuses, @per_ip) |> Enum.all?(&(&1 != 429)),
             "first #{@per_ip} requests must pass the limiter, got #{inspect(Enum.uniq(statuses))}"

      assert List.last(statuses) == 429
    end

    test "429 body is exactly {\"error\":\"too_many_requests\"} (OAuth style, no Matrix errcode)" do
      ip = T.unique_ip()
      for _ <- 1..@per_ip, do: invalid_register(ip)
      conn = invalid_register(ip)

      assert conn.status == 429
      assert T.json(conn) == %{"error" => "too_many_requests"}
      assert (T.header(conn, "content-type") || "") =~ "application/json"
    end

    test "429 carries a Retry-After header with a positive integer number of seconds" do
      ip = T.unique_ip()
      for _ <- 1..@per_ip, do: invalid_register(ip)
      conn = invalid_register(ip)

      assert conn.status == 429
      retry_after = T.header(conn, "retry-after")
      assert retry_after, "Retry-After header is required on 429"
      assert {secs, ""} = Integer.parse(retry_after)
      assert secs > 0
    end

    test "429 responses still carry Access-Control-Allow-Origin: * (browser clients must read them)" do
      ip = T.unique_ip()
      for _ <- 1..@per_ip, do: invalid_register(ip)
      conn = invalid_register(ip, origin: "https://client.example.com")

      assert conn.status == 429
      assert T.header(conn, "access-control-allow-origin") == "*"
    end

    test "another IP is not affected by an exhausted IP" do
      ip_a = T.unique_ip()
      for _ <- 1..(@per_ip + 1), do: invalid_register(ip_a)

      conn = invalid_register(T.unique_ip())
      refute conn.status == 429
      assert conn.status == 400
    end

    test "OPTIONS preflights do not consume the bucket (no endpoint logic is run)" do
      ip = T.unique_ip()
      for _ <- 1..(@per_ip - 1), do: invalid_register(ip)
      for _ <- 1..30, do: T.options("/oauth2/register", ip: ip)

      # exactly one POST slot is left: the 600th passes, the 601st is blocked
      refute invalid_register(ip).status == 429, "OPTIONS must not count against the register rate limit"
      assert invalid_register(ip).status == 429
    end
  end

  describe "F-1 remainder — OAuth-disabled requests are charged to the invalid-request bucket" do
    test "600 requests while disabled are 404, the 601st is 429 (abuse control runs before the 404)" do
      T.disable_oauth()
      ip = T.unique_ip()

      statuses = for _ <- 1..(@per_ip + 1), do: T.register(T.web_body(), ip: ip).status
      assert Enum.take(statuses, @per_ip) |> Enum.all?(&(&1 == 404))
      assert List.last(statuses) == 429
    end
  end

  describe "AC2/AC6 — global rate limit on invalid POST /oauth2/register requests" do
    test "after #{@global} requests across many IPs the endpoint answers 429 for EVERY ip" do
      # 25 requests per IP keeps every per-IP bucket far below its own limit, so only the
      # GLOBAL bucket can produce a 429 here (the invalid-request family: 5000 per hour).
      responses =
        for i <- 1..(@global + 20) do
          ip = {10, 100 + rem(div(i, 25 * 256), 100), rem(div(i, 25), 256), rem(i, 25) + 1}
          invalid_register(ip)
        end

      # Exactly the first #{@global} requests are admitted, the 5001st is the first 429
      # (frozen clock => no refill; every per-IP bucket stays far below its own limit).
      first_429 = Enum.find_index(responses, &(&1.status == 429))
      assert first_429 != nil, "no 429 after #{@global + 20} requests: global limit is not enforced"
      assert first_429 == @global, "first 429 at request index #{first_429}, expected exactly #{@global}"

      assert responses |> Enum.take(@global) |> Enum.all?(&(&1.status != 429)),
             "a request below the global limit was throttled"

      assert responses |> Enum.drop(@global) |> Enum.all?(&(&1.status == 429)),
             "requests above the global limit must ALL be throttled"

      blocked = Enum.at(responses, first_429)
      assert T.json(blocked) == %{"error" => "too_many_requests"}
      assert T.header(blocked, "retry-after")

      fresh = invalid_register(T.unique_ip())
      assert fresh.status == 429, "a brand-new IP must also be blocked once the global limit is hit"
    end
  end

  describe "AC2/AC6 — limiter resilience (ETS bucket table lost at runtime)" do
    test "register keeps working when the ETS bucket table is deleted: no 500, table recreated, limits still enforced" do
      ip = T.unique_ip()
      for _ <- 1..3, do: invalid_register(ip)
      assert :ets.whereis(@bucket_table) != :undefined

      :ets.delete(@bucket_table)
      assert :ets.whereis(@bucket_table) == :undefined

      # per-IP AND global bucket checks both run against the vanished table
      conn = invalid_register(ip)
      assert conn.status == 400, "expected the normal validation answer, got #{conn.status}: #{conn.resp_body}"
      assert :ets.whereis(@bucket_table) != :undefined, "the limiter must lazily recreate its bucket table"

      # one per-IP bucket + one GLOBAL bucket (invalid-request family) live in the recreated table
      assert :ets.info(@bucket_table, :size) >= 2,
             "per-IP and global buckets must both be recreated, got #{inspect(:ets.tab2list(@bucket_table))}"

      # ...and the recreated per-IP bucket enforces the limit again (fresh bucket: 599 more pass, then 429)
      statuses = for _ <- 1..@per_ip, do: invalid_register(ip).status
      assert Enum.take(statuses, @per_ip - 1) |> Enum.all?(&(&1 == 400))
      assert List.last(statuses) == 429
    end
  end

  describe "AC6 — CORS on POST /oauth2/register" do
    test "POST with Origin returns Access-Control-Allow-Origin: * on the real response" do
      conn = T.register(T.web_body(%{"client_uri" => "http://bad"}), origin: "https://client.example.com")
      assert conn.status == 400
      assert T.header(conn, "access-control-allow-origin") == "*"
    end

    test "404 (OAuth disabled) response carries Access-Control-Allow-Origin: *" do
      T.disable_oauth()
      conn = T.register(T.web_body(), origin: "https://client.example.com") |> T.assert_unrecognized_404()
      assert T.header(conn, "access-control-allow-origin") == "*"
    end

    test "OPTIONS /oauth2/register: ACAO *, methods include POST and OPTIONS, headers include Content-Type + Authorization" do
      conn = T.options("/oauth2/register")

      # Story says 200; CORSPlug's native preflight answer is 204 — both are acceptable "no-logic" answers.
      assert conn.status in [200, 204], "preflight status was #{conn.status}"
      assert T.header(conn, "access-control-allow-origin") == "*"

      methods = (T.header(conn, "access-control-allow-methods") || "") |> String.upcase()
      assert methods =~ "POST"
      assert methods =~ "OPTIONS"

      headers = (T.header(conn, "access-control-allow-headers") || "") |> String.downcase()
      assert headers =~ "content-type"
      assert headers =~ "authorization"
      assert headers =~ "x-requested-with"
      assert conn.resp_body in ["", nil]
    end

    test "OPTIONS /oauth2/register while OAuth is disabled still answers the preflight (not 404)" do
      T.disable_oauth()
      conn = T.options("/oauth2/register")
      assert conn.status in [200, 204]
      assert T.header(conn, "access-control-allow-origin") == "*"
    end

    test "OPTIONS /_matrix/client/v1/auth_metadata advertises the same CORS header set" do
      conn = T.options("/_matrix/client/v1/auth_metadata", request_method: "GET")
      assert conn.status in [200, 204]
      assert T.header(conn, "access-control-allow-origin") == "*"
      headers = (T.header(conn, "access-control-allow-headers") || "") |> String.downcase()
      assert headers =~ "authorization"
      assert headers =~ "x-requested-with"
    end
  end
end
