defmodule Nebu.OAuth.OAuthMetadataTest do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval`, AC1 (+ AC6 metadata part).

  `GET /_matrix/client/v1/auth_metadata` becomes Nebu's OWN RFC 8414 document (Nebu is the
  authorization server, broker model O2 / ADR-033) instead of the current passthrough of the
  IdP's `/.well-known/openid-configuration`.

  Pure unit tests (no DB): the OAuth config is injected through the
  `:nebu_http, :oauth_config_source` seam (see `Nebu.OAuth.TestSupport`).

  Matrix spec v1.18 (oracle-context.md): 200 RFC 8414 document or
  `404 {"errcode":"M_UNRECOGNIZED","error":...}` (Matrix error shape); no auth; not rate-limited.

  Crash/restart — NOT APPLICABLE (stateless, request-scoped config read).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @idp_issuer "https://idp.corp.example.org/realms/corp"

  @required_urls ~w(issuer authorization_endpoint token_endpoint revocation_endpoint registration_endpoint)

  # Fields that MUST NOT be advertised by this story (not implemented / not in the v1.x doc).
  # story 6 (oauth-account-management, A18 / Trap 7): changed deliberately — account_management_uri and
  # account_management_actions_supported are advertised from story 6 on (the page is live under the
  # same predicate); see the "AC10 (story 6)" describe below.
  @forbidden_fields ~w(device_authorization_endpoint prompt_values_supported auth_issuer)

  setup do
    # The IdP passthrough override must NOT leak into the new document.
    Nebu.Web.OidcTestSupport.configure(@idp_issuer, "nebu-client")

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @idp_issuer,
      "authorization_endpoint" => @idp_issuer <> "/auth",
      "token_endpoint" => @idp_issuer <> "/token",
      "jwks_uri" => @idp_issuer <> "/jwks"
    })

    on_exit(fn ->
      T.clear_oauth_config()
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_metadata_override)
      T.restore_rate_limits()
    end)

    :ok
  end

  # Fetches the document AND proves it is Nebu's OWN RFC 8414 document (issuer = Nebu's URL),
  # not the legacy passthrough of the IdP's openid-configuration — otherwise generic
  # assertions below could pass vacuously against the IdP document.
  defp doc(opts \\ []) do
    conn = T.get_metadata(opts)
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    body = T.json(conn)

    assert body["issuer"] == "https://nebu.example.com",
           "auth_metadata must be Nebu's own document (issuer=Nebu), got issuer=#{inspect(body["issuer"])}"

    {conn, body}
  end

  describe "AC1 — OAuth enabled: RFC 8414 document" do
    setup do
      T.enable_oauth()
      :ok
    end

    test "returns 200 application/json without any Authorization header" do
      {conn, _} = doc()
      assert (T.header(conn, "content-type") || "") =~ "application/json"
    end

    test "every REQUIRED field is present and endpoints live under Nebu's own issuer" do
      {_, body} = doc()

      assert body["issuer"] == "https://nebu.example.com"
      assert body["authorization_endpoint"] == "https://nebu.example.com/oauth2/authorize"
      assert body["token_endpoint"] == "https://nebu.example.com/oauth2/token"
      assert body["revocation_endpoint"] == "https://nebu.example.com/oauth2/revoke"
      assert body["registration_endpoint"] == "https://nebu.example.com/oauth2/register"
    end

    test "issuer is Nebu's URL, NOT the corporate IdP, and nothing is proxied from the IdP" do
      {conn, body} = doc()
      refute body["issuer"] == @idp_issuer
      refute conn.resp_body =~ "idp.corp.example.org", "IdP URLs must not leak into Nebu's metadata"
      # story 3 (oauth-token-endpoint, AC18): changed deliberately — `jwks_uri` is now advertised,
      # but it is NEBU'S OWN JWKS (id_token signing keys), never the IdP's.
      assert body["jwks_uri"] == "https://nebu.example.com/oauth2/jwks", "jwks_uri must be Nebu's own JWKS"
      refute body["jwks_uri"] == @idp_issuer <> "/jwks", "no IdP jwks_uri passthrough"
    end

    test "issuer has no query and no fragment (RFC 8414)" do
      {_, %{"issuer" => issuer}} = doc()
      uri = URI.parse(issuer)
      assert uri.scheme == "https"
      assert uri.query == nil
      assert uri.fragment == nil
    end

    test "response_types_supported contains code" do
      {_, body} = doc()
      assert "code" in body["response_types_supported"]
    end

    test "grant_types_supported contains authorization_code and refresh_token" do
      {_, body} = doc()
      grants = body["grant_types_supported"]
      assert "authorization_code" in grants
      assert "refresh_token" in grants
    end

    test "response_modes_supported contains query and fragment" do
      {_, body} = doc()
      modes = body["response_modes_supported"]
      assert "query" in modes
      assert "fragment" in modes
    end

    test "code_challenge_methods_supported contains S256" do
      {_, body} = doc()
      assert "S256" in body["code_challenge_methods_supported"]
    end

    test "Cache-Control is exactly 'public, max-age=259200' (3 days, Dart SDK caching)" do
      {conn, _} = doc()
      assert T.header(conn, "cache-control") == "public, max-age=259200"
    end

    for field <- @forbidden_fields do
      test "does NOT advertise #{field} (not implemented in this story)" do
        {_, body} = doc()
        refute Map.has_key?(body, unquote(field))
      end
    end

    test "no unknown/deprecated fields: only required + explicitly supported keys" do
      {conn, _} = doc()
      allowed =
        MapSet.new(
          @required_urls ++
            ~w(response_types_supported grant_types_supported response_modes_supported
               code_challenge_methods_supported token_endpoint_auth_methods_supported
               scopes_supported revocation_endpoint_auth_methods_supported
               authorization_response_iss_parameter_supported) ++
            # story 3 (oauth-token-endpoint, AC18): changed deliberately — Nebu's own JWKS + id_token alg
            ~w(jwks_uri id_token_signing_alg_values_supported) ++
            # story 6 (oauth-account-management, A18): changed deliberately
            ~w(account_management_uri account_management_actions_supported)
        )

      extra = conn |> T.json() |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed)
      assert MapSet.size(extra) == 0, "unexpected fields in auth_metadata: #{inspect(MapSet.to_list(extra))}"
    end

    # story 3 (oauth-token-endpoint, AC18 / T30): new tests
    test "AC18 (story 3): id_token_signing_alg_values_supported is exactly [\"ES256\"]" do
      {_, body} = doc()
      assert body["id_token_signing_alg_values_supported"] == ["ES256"]
    end

    test "AC18 (story 3): jwks_uri is https and lives under Nebu's issuer" do
      {_, body} = doc()
      assert is_binary(body["jwks_uri"]), "jwks_uri missing"
      assert String.starts_with?(body["jwks_uri"], "https://")
      assert body["jwks_uri"] == body["issuer"] <> "/oauth2/jwks"
    end

    test "AC18 (story 3): grant_types_supported and token_endpoint_auth_methods_supported are unchanged" do
      {_, body} = doc()
      assert body["grant_types_supported"] == ["authorization_code", "refresh_token"]
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
      assert body["revocation_endpoint"] == "https://nebu.example.com/oauth2/revoke", "still advertised (story 4)"
    end

    # story oauth-authorize-idp-delegation-code, AC16 / D15 (RFC 9207): every authorization
    # response carries `iss`, so the metadata says so; the other story-2-relevant fields stay as
    # they are (prompt_values_supported stays ABSENT, D11).
    test "AC16 (story 2): authorization_response_iss_parameter_supported is true (RFC 9207)" do
      {_, body} = doc()
      assert body["authorization_response_iss_parameter_supported"] == true
    end

    test "AC16 (story 2): response modes, PKCE methods unchanged; prompt_values_supported absent" do
      {_, body} = doc()
      assert body["response_modes_supported"] == ["query", "fragment"]
      assert body["code_challenge_methods_supported"] == ["S256"]
      refute Map.has_key?(body, "prompt_values_supported")
    end

    test "https-for-all-URLs (Nebu rule, stricter than spec): every URL value is https" do
      {conn, _} = doc()

      urls =
        conn
        |> T.json()
        |> Enum.flat_map(fn {_k, v} -> List.wrap(v) end)
        |> Enum.filter(&(is_binary(&1) and String.match?(&1, ~r{^[a-z][a-z0-9+.-]*://}i)))

      assert length(urls) >= 5
      for u <- urls, do: assert(String.starts_with?(u, "https://"), "non-https URL advertised: #{u}")
    end

    test "a non-https issuer_url fails closed: 404 M_UNRECOGNIZED (treated as unavailable), never a document" do
      # Nebu rule (https-for-all-URLs): a non-https issuer is an invalid configuration, so the
      # endpoint fails closed exactly like the disabled case instead of advertising http:// URLs.
      T.enable_oauth("http://nebu.example.com")
      conn = T.get_metadata() |> T.assert_unrecognized_404()

      refute conn.resp_body =~ "http://", "no plain-http URL may appear anywhere in the response"
      refute conn.resp_body =~ "nebu.example.com", "the misconfigured issuer must not be echoed"
      body = T.json(conn)
      for field <- ~w(issuer authorization_endpoint token_endpoint registration_endpoint),
          do: refute(Map.has_key?(body, field), "error body must not look like a metadata document (#{field})")
    end

    test "is not rate limited (no Retry-After / 429 after many calls from one IP)" do
      ip = T.unique_ip()
      doc(ip: ip)
      statuses = for _ <- 1..70, do: T.get_metadata(ip: ip).status
      assert Enum.all?(statuses, &(&1 == 200)), "statuses: #{inspect(Enum.uniq(statuses))}"
    end

    test "GET with Origin returns Access-Control-Allow-Origin: * (AC6)" do
      {conn, _} = doc(origin: "https://client.example.com")
      assert T.header(conn, "access-control-allow-origin") == "*"
    end
  end

  describe "AC1 — OAuth disabled (default): 404 M_UNRECOGNIZED" do
    test "oauth_enabled=false => 404 with the MATRIX error shape" do
      T.disable_oauth()
      T.get_metadata() |> T.assert_unrecognized_404()
    end

    test "no config at all (default false) => 404 M_UNRECOGNIZED, not 503 and not an IdP passthrough" do
      T.clear_oauth_config()
      conn = T.get_metadata()
      refute conn.status == 503
      T.assert_unrecognized_404(conn)
      refute conn.resp_body =~ "authorization_endpoint"
    end

    test "disabled 404 still carries CORS Access-Control-Allow-Origin: * so browsers can read it" do
      T.disable_oauth()
      conn = T.get_metadata(origin: "https://client.example.com") |> T.assert_unrecognized_404()
      assert T.header(conn, "access-control-allow-origin") == "*"
    end
  end

  describe "AC1/AC6 — OPTIONS preflight on auth_metadata (no endpoint logic)" do
    test "enabled: CORS headers, ACAO *, empty body" do
      T.enable_oauth()
      conn = T.options("/_matrix/client/v1/auth_metadata", request_method: "GET")

      # Story says 200; CORSPlug's native preflight answer is 204. Both are "success, no body".
      assert conn.status in [200, 204], "preflight status was #{conn.status}"
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert (T.header(conn, "access-control-allow-methods") || "") =~ "GET"
      assert conn.resp_body in ["", nil]
    end

    test "disabled: OPTIONS still answers with CORS headers (never 404, endpoint logic not run)" do
      T.disable_oauth()
      conn = T.options("/_matrix/client/v1/auth_metadata", request_method: "GET")

      assert conn.status in [200, 204], "preflight must not be handled by the disabled-404 logic, got #{conn.status}"
      assert T.header(conn, "access-control-allow-origin") == "*"
    end
  end
  # Security review F-2 (spec section 14 decision #7): once OAuth is enabled, discovery names ONE
  # issuer — Nebu's. `auth_issuer` (v1 + unstable MSC2965) and the unstable `auth_metadata` are
  # served by Nebu.OAuth.Http instead of the IdP passthrough. While OAuth is disabled the legacy
  # passthrough is unchanged (Element/FluffyChat compat; see matrix_router_test.exs).
  describe "F-2 — a single issuer is advertised once OAuth is enabled" do
    @issuer_paths ["/_matrix/client/v1/auth_issuer", "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"]
    @unstable_metadata "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata"

    for path <- @issuer_paths do
      test "enabled: GET #{path} answers Nebu's issuer (never the IdP's)" do
        T.enable_oauth()
        conn = T.get(unquote(path))

        assert conn.status == 200
        assert T.json(conn) == %{"issuer" => "https://nebu.example.com"}
        refute conn.resp_body =~ "idp.corp.example.org"
        assert (T.header(conn, "content-type") || "") =~ "application/json"
        assert T.header(conn, "access-control-allow-origin") == "*"
      end

      test "enabled with an invalid issuer: GET #{path} is 404 M_UNRECOGNIZED (fail closed, value not echoed)" do
        T.enable_oauth("http://nebu.example.com/path?x=1")
        conn = T.get(unquote(path)) |> T.assert_unrecognized_404()
        refute conn.resp_body =~ "nebu.example.com"
      end

      test "disabled: GET #{path} is still the legacy IdP passthrough (unchanged behaviour)" do
        T.disable_oauth()
        conn = T.get(unquote(path))

        assert conn.status == 200
        assert T.json(conn)["issuer"] == @idp_issuer
      end
    end

    test "enabled: the unstable auth_metadata is Nebu's document, identical to the stable one" do
      T.enable_oauth()
      stable = T.get_metadata()
      unstable = T.get(@unstable_metadata)

      assert unstable.status == 200
      assert T.json(unstable) == T.json(stable)
      assert T.json(unstable)["issuer"] == "https://nebu.example.com"
      refute unstable.resp_body =~ "idp.corp.example.org", "no IdP field may leak into the unstable alias"
      assert T.header(unstable, "cache-control") == "public, max-age=259200"
    end

    test "enabled: v1 and unstable auth_issuer name the same issuer as the metadata document" do
      T.enable_oauth()
      %{"issuer" => meta_issuer} = T.get_metadata() |> T.json()

      for path <- @issuer_paths, do: assert(T.json(T.get(path))["issuer"] == meta_issuer)
      assert T.json(T.get(@unstable_metadata))["issuer"] == meta_issuer
    end

    test "disabled: the unstable auth_metadata is still the legacy IdP passthrough" do
      T.disable_oauth()
      conn = T.get(@unstable_metadata)

      assert conn.status == 200
      assert T.json(conn)["issuer"] == @idp_issuer
    end

    # story oauth-room-summary-unrecognized (af, RU14): changed deliberately. While OAuth is live a non-GET on
    # the discovery paths is "known endpoint, wrong method": 405 M_UNRECOGNIZED + Allow: GET, OPTIONS (was the
    # pinned 404 without Allow). Disabled / invalid issuer keeps the 404 (oauth_room_summary: unrecognized_routes_test).
    test "enabled: a non-GET on the discovery paths is 405 M_UNRECOGNIZED + Allow: GET, OPTIONS" do
      T.enable_oauth()

      for path <- @issuer_paths ++ [@unstable_metadata] do
        conn =
          Plug.Test.conn(:post, path, "")
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

        assert conn.status == 405, "POST #{path} => #{conn.status}"
        assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNRECOGNIZED"

        assert conn |> Plug.Conn.get_resp_header("allow") |> List.first() |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.sort() ==
                 ["GET", "OPTIONS"]
      end
    end

    # security review N-4: the config is tri-state. A positively read "disabled" takes the legacy
    # passthrough; an UNREADABLE server_config (e.g. a DB timeout while OAuth is enabled) must not,
    # or discovery would briefly advertise the IdP issuer next to Nebu's own.
    test "unreadable config: the three discovery paths answer 503 (no IdP issuer, no Nebu issuer)" do
      T.unreadable_oauth_config()

      for path <- @issuer_paths ++ [@unstable_metadata] do
        conn = T.get(path, origin: "https://client.example.com")

        assert conn.status == 503, "GET #{path} => #{conn.status}"
        refute conn.resp_body =~ "idp.corp.example.org"
        refute conn.resp_body =~ "nebu.example.com"
        refute conn.resp_body =~ "issuer"
        assert T.header(conn, "cache-control") == "no-store"
        assert T.header(conn, "access-control-allow-origin") == "*"
        assert (T.header(conn, "content-type") || "") =~ "application/json"
        assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN"
      end
    end

    test "unreadable config: the stable auth_metadata fails closed (404 M_UNRECOGNIZED, no document)" do
      T.unreadable_oauth_config()
      conn = T.get_metadata() |> T.assert_unrecognized_404()
      refute conn.resp_body =~ "authorization_endpoint"
    end

    test "unreadable config: POST /oauth2/register fails closed (404 M_UNRECOGNIZED, nothing stored)" do
      T.unreadable_oauth_config()
      T.register(T.web_body()) |> T.assert_unrecognized_404()
    end

    test "the three config states are reported by Nebu.OAuth.config/0" do
      T.enable_oauth()
      assert %{state: :enabled, enabled: true} = Nebu.OAuth.config()
      T.disable_oauth()
      assert %{state: :disabled, enabled: false} = Nebu.OAuth.config()
      T.unreadable_oauth_config()
      assert %{state: :unknown, enabled: false, issuer_url: nil} = Nebu.OAuth.config()
    end
  end

  # ── story oauth-token-revocation-logout (story 4), AC11 / R23 / Must #33 (RED: revoke unrouted) ──

  describe "AC11/R23/Must #33 (story 4) — the advertised revocation_endpoint is real" do
    setup do
      T.enable_oauth()
      T.reset_rate_limits()
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_session_repo) end)
      :ok
    end

    test "revocation_endpoint == issuer <> /oauth2/revoke, auth methods [\"none\"], and the endpoint answers 200 {} (also while disabled)" do
      {_, body} = doc()
      assert body["revocation_endpoint"] == body["issuer"] <> "/oauth2/revoke"
      assert body["revocation_endpoint_auth_methods_supported"] == ["none"]
      path = URI.parse(body["revocation_endpoint"]).path

      # a malformed token is answered without DB access (NoSuchRepo would turn a lookup into 503)
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)

      for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
        set.()
        conn = T.revoke(T.revoke_params("not-a-real-token"), path: path)
        refute conn.status == 404, "the advertised revocation_endpoint must be routed (R23), got 404 #{inspect(conn.resp_body)}"
        T.assert_revoke_ok(conn)
      end
    end
  end

  # ── story oauth-account-management (story 6), AC10 / A18 / Must #1 (account management fields) ──

  describe "AC10/A18/Must #1 (story 6) — account management fields" do
    setup do
      T.enable_oauth()
      :ok
    end

    @actions ~w(org.matrix.profile org.matrix.devices_list org.matrix.device_view org.matrix.device_delete org.matrix.cross_signing_reset)

    test "account_management_uri == issuer <> /account (https) and exactly the five actions in order" do
      {_, body} = doc()
      assert body["account_management_uri"] == "https://nebu.example.com/account"
      assert body["account_management_actions_supported"] == @actions
    end

    test "byte-identical across auth_metadata, the unstable alias and /.well-known/openid-configuration" do
      a = T.get_metadata()
      b = T.get("/_matrix/client/unstable/org.matrix.msc2965/auth_metadata")
      c = T.get("/.well-known/openid-configuration")
      assert a.status == 200 and b.status == 200 and c.status == 200
      assert T.json(a)["account_management_uri"] == "https://nebu.example.com/account"
      assert a.resp_body == b.resp_body and b.resp_body == c.resp_body
    end

    test "Must #56: the shape matrix-js-sdk validateAuthMetadata requires (string URI, list of strings)" do
      {_, body} = doc()
      assert is_binary(body["account_management_uri"]) and URI.parse(body["account_management_uri"]).scheme == "https"
      assert Enum.all?(body["account_management_actions_supported"], &is_binary/1)
    end

    test "still 404 while disabled" do
      T.disable_oauth()
      assert T.get_metadata().status == 404
    end
  end
end
