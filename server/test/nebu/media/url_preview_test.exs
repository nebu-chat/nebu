defmodule Nebu.Web.UrlPreviewTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC5 (preview_url).

  Story-declared test: mocked Finch OG-tag response → JSON has og:title,
  og:description.

  GET /_matrix/media/v3/preview_url?url=...:
    * fetches the target via the injected HTTP boundary (production: Finch),
      parses Open Graph tags (production: Floki), and returns a FLAT JSON object
      `%{"og:title" => .., "og:description" => .., "og:image" => ..}` (oracle §5).
    * SSRF guard (Kassandra): a url whose host resolves to a private / loopback /
      link-local / cloud-metadata address, or a non-http(s) scheme, is rejected
      BEFORE any fetch — the injected fetch boundary must NEVER be called for a
      blocked url.

  ## Why this MUST FAIL now

  No preview_url route exists; the request falls through to the protected
  `match _` (404 M_NOT_FOUND) or, unauthenticated, to OidcPlug (401). The OG-tag
  JSON shape and the SSRF rejection are not produced until `Nebu.Media`
  implements preview_url with the SSRF guard.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @og_html """
  <!doctype html><html><head>
    <meta property="og:title" content="Nebu Chat" />
    <meta property="og:description" content="Enterprise Matrix server" />
    <meta property="og:image" content="https://example.com/preview.png" />
  </head><body>hi</body></html>
  """

  setup do
    priv = S.setup_oidc_keys()
    {_uid, token} = S.bearer_for("kai", priv)

    Application.put_env(:nebu_http, :media_http_fetch_module, MediaFakes.HttpFetch)

    # F-1: preview_url now carries a per-IP rate limit (router/media.ex). The
    # SSRF/OG-shape tests below fire several requests from the shared Plug.Test
    # peer IP and are NOT about throttling, so disable rate limiting by default
    # here. The dedicated F-1 test re-ENABLES it (and pins a unique IP) locally.
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_http_fetch_module)
      Application.delete_env(:nebu_http, :media_fetch_fun)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token}
  end

  defp preview(url, token) do
    conn(:get, "/_matrix/media/v3/preview_url?url=" <> URI.encode_www_form(url))
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(S.router_opts())
  end

  # ── AC5 — OG tags extracted into flat JSON ─────────────────────────────────

  test "preview_url of an allowed http(s) url → 200 flat JSON with og:* tags", %{token: token} do
    test_pid = self()

    Application.put_env(:nebu_http, :media_fetch_fun, fn url ->
      send(test_pid, {:fetched, url})
      {:ok, %{status: 200, headers: [{"content-type", "text/html; charset=utf-8"}], body: @og_html}}
    end)

    conn = preview("https://example.com/article", token)

    assert conn.status == 200,
           "preview_url must return 200, got #{conn.status} — preview_url route not implemented"

    body = S.json(conn)
    assert body["og:title"] == "Nebu Chat"
    assert body["og:description"] == "Enterprise Matrix server"
    # og:image is extracted as well (oracle §5).
    assert is_binary(body["og:image"])

    # The handler actually performed the (mocked) fetch.
    assert_received {:fetched, "https://example.com/article"}
  end

  # ── SSRF guard — private/loopback/metadata or bad scheme rejected ──────────

  test "preview_url targeting a loopback/private address is rejected WITHOUT fetching", %{token: token} do
    test_pid = self()

    # If the handler reaches the fetch boundary for a blocked url, the SSRF guard failed.
    Application.put_env(:nebu_http, :media_fetch_fun, fn url ->
      send(test_pid, {:should_not_fetch, url})
      {:ok, %{status: 200, headers: [], body: "<html></html>"}}
    end)

    # 169.254.169.254 = cloud metadata; 127.0.0.1 = loopback; 10.x = private.
    for blocked <- [
          "http://169.254.169.254/latest/meta-data/",
          "http://127.0.0.1:8080/",
          "http://10.0.0.5/internal"
        ] do
      conn = preview(blocked, token)

      assert conn.status in [400, 403],
             "SSRF-blocked url #{blocked} must be rejected with 400/403, got #{conn.status}"

      assert S.json(conn)["errcode"] in ["M_FORBIDDEN", "M_INVALID_PARAM", "M_UNKNOWN"]
    end

    refute_received {:should_not_fetch, _},
                    "the SSRF guard MUST reject before the HTTP fetch boundary is called"
  end

  test "preview_url with a non-http(s) scheme (file://) is rejected", %{token: token} do
    Application.put_env(:nebu_http, :media_fetch_fun, fn _url ->
      flunk("non-http(s) scheme must be rejected before fetching")
    end)

    conn = preview("file:///etc/passwd", token)
    assert conn.status in [400, 403]
  end

  # ── F-1 (HIGH) — preview_url has a strict per-IP rate limit ────────────────
  #
  # preview_url is an authenticated outbound-fetch amplifier (egress-DoS
  # reflector). The Go media gateway capped it per IP; this asserts the Elixir
  # migration restored that control. Tier: 30/min, burst 10 (router/media.ex).
  #
  # Deterministic: rate limiting may be disabled in CI/e2e via
  # NEBU_RATE_LIMIT_DISABLED or :rate_limit_disabled, so this test EXPLICITLY
  # enables it (and clears the env var) for its duration, then restores.

  @rl_table :nebu_http_rate_limit_buckets

  test "burst+1 rapid preview_url requests from the same IP → 429 M_LIMIT_EXCEEDED + Retry-After",
       %{token: token} do
    # Enable rate limiting deterministically for this test only.
    prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
    System.delete_env("NEBU_RATE_LIMIT_DISABLED")
    prev_app = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, false)

    # Pin the clock to a fixed constant so now - last == 0 on every request →
    # zero refill across the burst → deterministic 429 regardless of CI speed.
    prev_clock = Application.get_env(:nebu_http, :rate_limit_clock_fn)
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 end)

    # Start from a clean bucket so the burst count is exact.
    if :ets.whereis(@rl_table) != :undefined, do: :ets.delete_all_objects(@rl_table)

    on_exit(fn ->
      if :ets.whereis(@rl_table) != :undefined, do: :ets.delete_all_objects(@rl_table)

      case prev_clock do
        nil -> Application.delete_env(:nebu_http, :rate_limit_clock_fn)
        v -> Application.put_env(:nebu_http, :rate_limit_clock_fn, v)
      end

      case prev_app do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end

      if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env)
    end)

    # A successful (mocked) fetch so non-limited requests return 200, not an error.
    Application.put_env(:nebu_http, :media_fetch_fun, fn _url ->
      {:ok, %{status: 200, headers: [], body: @og_html}}
    end)

    # burst is 10 — fire 10 from one peer IP; all should pass (200).
    for _ <- 1..10 do
      conn = preview_from_ip("https://example.com/article", token, {203, 0, 113, 7})
      assert conn.status == 200, "requests within the burst must pass, got #{conn.status}"
    end

    # The 11th from the same IP must be rejected with 429 M_LIMIT_EXCEEDED.
    blocked = preview_from_ip("https://example.com/article", token, {203, 0, 113, 7})

    assert blocked.status == 429,
           "the request past the burst must be rate-limited, got #{blocked.status}"

    assert S.json(blocked)["errcode"] == "M_LIMIT_EXCEEDED"

    retry_after = Plug.Conn.get_resp_header(blocked, "retry-after") |> List.first()
    assert retry_after != nil, "a 429 must carry a Retry-After header"
    assert String.to_integer(retry_after) >= 1
  end

  # Like preview/2 but pins a fixed peer IP so all requests share one bucket.
  defp preview_from_ip(url, token, ip) do
    %{
      conn(:get, "/_matrix/media/v3/preview_url?url=" <> URI.encode_www_form(url))
      | remote_ip: ip
    }
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(S.router_opts())
  end

  # ── F2 — SSRF.checked_target resolves once and returns the validated IP ─────
  #
  # The DNS-rebinding TOCTOU fix moves resolution into a single checked_target/1
  # that returns the validated IP so the fetch connects to the checked address
  # instead of re-resolving. A host (here a literal IP, no DNS needed) that maps
  # to a private/loopback/metadata address must be blocked through this path; a
  # public address returns {:ok, %{ip: ...}} carrying the pinned IP.

  alias Nebu.Media.SSRF

  test "checked_target blocks a host resolving to a private/loopback/metadata IP" do
    assert {:error, :blocked_address} = SSRF.checked_target("http://127.0.0.1:8080/")
    assert {:error, :blocked_address} = SSRF.checked_target("http://10.0.0.5/internal")
    assert {:error, :blocked_address} = SSRF.checked_target("http://169.254.169.254/latest/")
    assert {:error, :bad_scheme} = SSRF.checked_target("file:///etc/passwd")
  end

  test "checked_target returns the validated pinned IP for a public literal host" do
    assert {:ok, %{scheme: "http", host: "93.184.216.34", ip: {93, 184, 216, 34}}} =
             SSRF.checked_target("http://93.184.216.34/article")

    # check/1 stays consistent with checked_target/1 (legacy callers).
    assert :ok = SSRF.check("http://93.184.216.34/article")
    assert {:error, :blocked_address} = SSRF.check("http://127.0.0.1/")
  end
end
