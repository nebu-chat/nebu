defmodule Nebu.OAuth.OAuthDcrValidationTest do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval`, AC2 (request validation +
  error codes + disabled behaviour). Pure unit tests: every request here is REJECTED before
  any DB access, so no Postgres is needed (success paths live in
  `oauth_dcr_integration_test.exs`).

  Error format is RFC 7591 3.2.2 `{"error","error_description"}` (NO `errcode`); only the
  "OAuth disabled" case uses the Matrix shape (`404 M_UNRECOGNIZED`).

  Redirect-URI rules (Matrix spec v1.18 / oracle-context.md):
    * all: no fragment
    * web: https, no userinfo, host == client_uri host or a subdomain of it
    * native private-use scheme: scheme prefixed with reverse-DNS of client_uri host,
      no authority component
    * native loopback: http on localhost / 127.0.0.1 / [::1], NO port at registration
    * native claimed https: same rules as web
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.enable_oauth()
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    :ok
  end

  # ── AC2: disabled behaviour ────────────────────────────────────────────────

  describe "AC2 — OAuth disabled" do
    test "POST /oauth2/register with valid metadata => 404 M_UNRECOGNIZED (Matrix shape)" do
      T.disable_oauth()
      T.register(T.web_body()) |> T.assert_unrecognized_404()
    end

    test "no config at all (default false) => 404 M_UNRECOGNIZED" do
      T.clear_oauth_config()
      T.register(T.web_body()) |> T.assert_unrecognized_404()
    end

    test "disabled wins over validation: an INVALID body is still 404, not 400" do
      T.disable_oauth()
      T.register(%{"client_uri" => "http://bad"}) |> T.assert_unrecognized_404()
    end

    test "disabled wins over body parsing: malformed JSON is still 404" do
      T.disable_oauth()
      T.register("{not json") |> T.assert_unrecognized_404()
    end
  end

  # ── AC2: invalid_request ───────────────────────────────────────────────────

  describe "AC2 — invalid_request (other validation failures)" do
    test "malformed JSON body => 400 invalid_request (OAuth shape, NOT M_NOT_JSON)" do
      T.register("{not json") |> T.assert_oauth_error(400, "invalid_request")
    end

    test "JSON body that is not an object (array) => 400 invalid_request" do
      T.register("[1,2,3]") |> T.assert_oauth_error(400, "invalid_request")
    end

    test "empty body => 400 invalid_request" do
      T.register("") |> T.assert_oauth_error(400, "invalid_request")
    end
  end

  # ── AC2: invalid_redirect_uri — web ────────────────────────────────────────

  @invalid_web_redirects [
    {"fragment", "https://example.com/callback#fragment"},
    {"http scheme", "http://example.com/callback"},
    {"http://localhost (web)", "http://localhost/"},
    {"other host", "https://app.com/cb"},
    {"userinfo", "https://user:pass@example.com/cb"},
    {"suffix-boundary host (evilexample.com)", "https://evilexample.com/cb"},
    {"client host as subdomain of attacker", "https://example.com.evil.com/cb"},
    {"private-use scheme on a web client", "com.example.app:/cb"},
    {"not a URI at all", "not a uri"},
    {"empty string", ""}
  ]

  describe "AC2 — invalid_redirect_uri (web)" do
    for {label, uri} <- @invalid_web_redirects do
      test "web client with #{label} => 400 invalid_redirect_uri" do
        T.register(T.web_body(%{"redirect_uris" => [unquote(uri)]}))
        |> T.assert_oauth_error(400, "invalid_redirect_uri")
      end
    end

    test "application_type omitted defaults to web => private-use scheme rejected" do
      body = T.native_body() |> Map.delete("application_type")
      T.register(body) |> T.assert_oauth_error(400, "invalid_redirect_uri")
    end

    test "ONE bad URI among valid ones rejects the whole registration" do
      T.register(
        T.web_body(%{"redirect_uris" => ["https://example.com/ok", "http://example.com/bad"]})
      )
      |> T.assert_oauth_error(400, "invalid_redirect_uri")
    end

    test "empty redirect_uris list is rejected" do
      conn = T.register(T.web_body(%{"redirect_uris" => []}))
      assert conn.status == 400
      assert T.json(conn)["error"] in ["invalid_redirect_uri", "invalid_client_metadata"]
    end

    test "missing redirect_uris is rejected (required for redirect-based flows)" do
      conn = T.register(T.web_body() |> Map.delete("redirect_uris"))
      assert conn.status == 400
      assert T.json(conn)["error"] in ["invalid_redirect_uri", "invalid_client_metadata"]
    end

    test "redirect_uris that is not a list of strings is rejected" do
      conn = T.register(T.web_body(%{"redirect_uris" => "https://example.com/cb"}))
      assert conn.status == 400
      assert T.json(conn)["error"] in ["invalid_redirect_uri", "invalid_client_metadata"]

      conn = T.register(T.web_body(%{"redirect_uris" => [123, nil]}))
      assert conn.status == 400
      assert T.json(conn)["error"] in ["invalid_redirect_uri", "invalid_client_metadata"]
    end
  end

  # ── AC2: invalid_redirect_uri — native ─────────────────────────────────────

  @invalid_native_redirects [
    {"private-use scheme not reverse-DNS of client host (example:/cb)", "example:/cb"},
    {"private-use scheme of a foreign domain", "org.evil.app:/cb"},
    {"private-use scheme WITH authority (com.example.app://cb)", "com.example.app://cb"},
    {"private-use scheme with host+path authority", "com.example.app://host/cb"},
    {"private-use scheme with fragment", "com.example.app:/cb#frag"},
    {"https://localhost (native)", "https://localhost/cb"},
    {"loopback with port at registration (localhost:1234)", "http://localhost:1234/cb"},
    {"loopback with port at registration (127.0.0.1)", "http://127.0.0.1:3000/cb"},
    {"loopback with port at registration ([::1])", "http://[::1]:8080/cb"},
    {"loopback with userinfo", "http://user:pass@localhost/callback"},
    {"loopback with fragment", "http://localhost/cb#frag"},
    {"http on a non-loopback host", "http://example.com/cb"},
    {"look-alike loopback host", "http://localhost.example.com/cb"}
  ]

  describe "AC2 — invalid_redirect_uri (native)" do
    for {label, uri} <- @invalid_native_redirects do
      test "native client with #{label} => 400 invalid_redirect_uri" do
        T.register(T.native_body(%{"redirect_uris" => [unquote(uri)]}))
        |> T.assert_oauth_error(400, "invalid_redirect_uri")
      end
    end

    test "native claimed-https follows the web rules: other host rejected" do
      T.register(T.native_body(%{"redirect_uris" => ["https://other.com/cb"]}))
      |> T.assert_oauth_error(400, "invalid_redirect_uri")
    end

    test "native claimed-https with fragment rejected" do
      T.register(T.native_body(%{"redirect_uris" => ["https://example.com/cb#x"]}))
      |> T.assert_oauth_error(400, "invalid_redirect_uri")
    end
  end

  # ── AC2: invalid_client_metadata ───────────────────────────────────────────

  describe "AC2 — invalid_client_metadata: client_uri" do
    test "http client_uri" do
      T.register(T.web_body(%{"client_uri" => "http://example.com"}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "client_uri with userinfo" do
      T.register(T.web_body(%{"client_uri" => "https://user:pass@example.com"}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "missing client_uri (required by the Matrix spec)" do
      T.register(T.web_body() |> Map.delete("client_uri"))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "client_uri that is not a string" do
      T.register(T.web_body(%{"client_uri" => 42}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end
  end

  # ── story oauth-dcr-abuse-hardening, AC2.1 (AH5): a client_uri host that IS a public suffix ─────

  describe "AH5 — client_uri host that is a public suffix is refused" do
    for {label, host} <- [
          {"github.io", "github.io"},
          {"co.uk", "co.uk"},
          {"vercel.app", "vercel.app"},
          {"upper-case GITHUB.IO", "GITHUB.IO"},
          {"s3.amazonaws.com", "s3.amazonaws.com"}
        ] do
      test "client_uri https://#{label} => 400 invalid_client_metadata with a helpful description" do
        conn =
          T.register(T.web_body(%{"client_uri" => "https://" <> unquote(host), "redirect_uris" => ["https://" <> unquote(host) <> "/cb"]}))

        T.assert_oauth_error(conn, 400, "invalid_client_metadata")
        desc = T.json(conn)["error_description"]
        assert desc =~ ~r/public suffix/i, "description must name the problem, got #{inspect(desc)}"
        assert desc =~ "github.io", "description gives the github.io example"
      end
    end

    test "a native client with a private-use scheme derived from a suffix host is refused as well" do
      T.register(T.native_body(%{"client_uri" => "https://github.io", "redirect_uris" => ["io.github:/cb"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "a subdomain of a private suffix is NOT refused by validation (it gets a badge instead)" do
      assert {:ok, %{client_host: "name.github.io", client_domain: "name.github.io"}} =
               Nebu.OAuth.Registration.validate(
                 T.web_body(%{"client_uri" => "https://name.github.io", "redirect_uris" => ["https://name.github.io/cb"]})
               )
    end

    test "validate/1 itself returns the error triple (no DB, no rate limit involved)" do
      assert {:error, "invalid_client_metadata", desc} =
               Nebu.OAuth.Registration.validate(T.web_body(%{"client_uri" => "https://co.uk", "redirect_uris" => ["https://co.uk/cb"]}))

      assert desc =~ ~r/public suffix/i
    end

    test "the refusal is charged to the invalid-request budget (600/h per IP), never to the strict one" do
      ip = T.unique_ip()
      body = T.web_body(%{"client_uri" => "https://github.io", "redirect_uris" => ["https://github.io/cb"]})

      statuses = for _ <- 1..601, do: T.register(body, ip: ip).status
      assert Enum.take(statuses, 600) |> Enum.all?(&(&1 == 400))
      assert List.last(statuses) == 429, "the 601st junk request of one IP is throttled by the invalid-request bucket"
    end
  end

  describe "AC2 — invalid_client_metadata: logo_uri / tos_uri / policy_uri" do
    for field <- ~w(logo_uri tos_uri policy_uri) do
      test "#{field} over http" do
        T.register(T.web_body(%{unquote(field) => "http://example.com/x"}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end

      test "#{field} on another host" do
        T.register(T.web_body(%{unquote(field) => "https://other.com/x"}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end

      test "#{field} on a suffix-look-alike host (evilexample.com)" do
        T.register(T.web_body(%{unquote(field) => "https://evilexample.com/x"}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end
    end
  end

  describe "AC2 — invalid_client_metadata: application_type, auth method, types" do
    test "unknown application_type" do
      T.register(T.web_body(%{"application_type" => "custom"}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    for method <- ~w(client_secret_basic client_secret_post private_key_jwt) do
      test "unsupported token_endpoint_auth_method #{method}" do
        T.register(T.web_body(%{"token_endpoint_auth_method" => unquote(method)}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end
    end

    test "response_types explicitly excluding code" do
      T.register(T.web_body(%{"response_types" => ["token"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "grant_types explicitly excluding authorization_code (implicit)" do
      T.register(T.web_body(%{"grant_types" => ["implicit"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "grant_types containing only refresh_token / client_credentials" do
      T.register(T.web_body(%{"grant_types" => ["refresh_token"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")

      T.register(T.web_body(%{"grant_types" => ["client_credentials"]}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end
  end

  # ── AC2: error shape ───────────────────────────────────────────────────────

  describe "AC2 — error response format" do
    test "error bodies carry exactly error + error_description (no Matrix errcode)" do
      conn = T.register(T.web_body(%{"client_uri" => "http://example.com"}))
      body = T.json(conn)
      assert Map.keys(body) |> Enum.sort() == ["error", "error_description"]
    end

    test "400 responses also carry Access-Control-Allow-Origin: * (browser clients must read errors)" do
      conn = T.register(T.web_body(%{"client_uri" => "http://example.com"}), origin: "https://client.example.com")
      assert conn.status == 400
      assert T.header(conn, "access-control-allow-origin") == "*"
    end
  end
end
