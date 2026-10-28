defmodule Nebu.OAuth.OAuthDcrHardeningTest do
  @moduledoc """
  Hardening tests for `POST /oauth2/register` (code-review cycle 0 of story
  `oauth-metadata-dcr-admin-approval`, findings 2, 3, 4 and 8). Pure unit tests: every request here
  is rejected before any DB access.

    * `client_name` with NUL / control / bidi / zero-width characters => `400 invalid_client_metadata`
      (Postgres jsonb cannot store NUL; bidi/zero-width text can reorder or hide text in the admin
      approval page)
    * non-ASCII / punycode / look-alike hosts in `client_uri`, `logo_uri`, redirect URIs are
      rejected (a host suffix comparison on look-alike characters must never pass)
    * oversize body => `413 invalid_request`, deep nesting => `400 invalid_request`, both in the
      RFC 7591 error shape (never plain text, never 5xx)
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.Registration
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

  describe "client_name — control / bidi / zero-width characters" do
    @bad_names [
      {"NUL", "Evil\u0000App"},
      {"escaped NUL at the start", "\u0000"},
      {"C0 control (BEL)", "App\u0007"},
      {"newline", "App\nName"},
      {"tab", "App\tName"},
      {"DEL", "App\u007F"},
      {"C1 control", "App\u0085Name"},
      {"RIGHT-TO-LEFT OVERRIDE", "App \u202Eexe.txt"},
      {"LEFT-TO-RIGHT OVERRIDE", "\u202DApp"},
      {"RIGHT-TO-LEFT ISOLATE", "App\u2067x"},
      {"POP DIRECTIONAL ISOLATE", "App\u2069"},
      {"LEFT-TO-RIGHT MARK", "App\u200E"},
      {"ARABIC LETTER MARK", "App\u061C"},
      {"ZERO WIDTH SPACE", "Pay\u200Bpal"},
      {"ZERO WIDTH JOINER", "App\u200D"},
      {"WORD JOINER", "App\u2060"},
      {"BOM / ZERO WIDTH NO-BREAK SPACE", "\uFEFFApp"},
      {"SOFT HYPHEN", "Ap\u00ADp"},
      {"LINE SEPARATOR", "App\u2028x"},
      {"PARAGRAPH SEPARATOR", "App\u2029x"},
      {"private-use code point", "App\uE000"}
    ]

    for {label, name} <- @bad_names do
      test "#{label} => 400 invalid_client_metadata" do
        T.register(T.web_body(%{"client_name" => unquote(name)}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end
    end

    test "the raw JSON escape \\u0000 (as sent over the wire) is rejected, not a 503" do
      raw =
        ~s({"client_name":"Evil\\u0000App","client_uri":"https://example.com","redirect_uris":["https://example.com/cb"]})

      T.register(raw) |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "ordinary names (unicode letters, emoji, punctuation) stay valid" do
      for name <- ["Élan Vital 日本語", "Chat 💬 App", "O'Reilly & Sons (beta) - v1.2"] do
        assert {:ok, %{metadata: %{"client_name" => ^name}}} =
                 Registration.validate(T.web_body(%{"client_name" => name}))
      end
    end
  end

  describe "hosts — ASCII LDH only (IDN, punycode, unicode look-alikes)" do
    @bad_client_uris [
      {"fullwidth solidus before the suffix", "https://evil.com\uFF0F.example.com"},
      {"fullwidth full stop", "https://evil\uFF0Eexample.com"},
      {"ideographic full stop", "https://evil\u3002com"},
      {"fullwidth commercial at", "https://good.com\uFF20evil.example.com"},
      {"cyrillic a in the host", "https://ex\u0430mple.com"},
      {"IDN (unicode) host", "https://b\u00FCcher.example"},
      {"KELVIN SIGN folding to k", "https://\u212Aeep.example.com"},
      {"punycode label", "https://xn--bcher-kva.example"},
      {"uppercase punycode label", "https://XN--bcher-kva.example"},
      {"trailing dot", "https://example.com."},
      {"empty label", "https://exa..mple.com"},
      {"leading hyphen label", "https://-example.com"},
      {"underscore", "https://exa_mple.com"},
      {"IPv6 literal", "https://[2001:db8::1]"},
      {"zero-width space in host", "https://exam\u200Bple.com"},
      {"bidi override in path", "https://example.com/\u202Epath"},
      {"NUL in path", "https://example.com/a\u0000b"}
    ]

    for {label, uri} <- @bad_client_uris do
      test "client_uri with #{label} => 400 invalid_client_metadata" do
        T.register(T.web_body(%{"client_uri" => unquote(uri)}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end
    end

    test "a look-alike solidus host must not pass the host-suffix check of a redirect URI" do
      T.register(T.web_body(%{"redirect_uris" => ["https://evil.com\uFF0F.example.com/cb"]}))
      |> T.assert_oauth_error(400, "invalid_redirect_uri")
    end

    test "look-alike / IDN hosts in redirect URIs of a native claimed-https client are rejected" do
      for uri <- ["https://ex\u0430mple.com/cb", "https://app.xn--e1afmkfd.example.com/cb"] do
        T.register(T.native_body(%{"redirect_uris" => [uri]}))
        |> T.assert_oauth_error(400, "invalid_redirect_uri")
      end
    end

    for field <- ~w(logo_uri tos_uri policy_uri) do
      test "#{field} with a unicode look-alike host => 400 invalid_client_metadata" do
        T.register(T.web_body(%{unquote(field) => "https://evil.com\uFF0F.example.com/x"}))
        |> T.assert_oauth_error(400, "invalid_client_metadata")
      end
    end

    test "private-use scheme redirects with a bidi/zero-width character are rejected" do
      T.register(T.native_body(%{"redirect_uris" => ["com.example.app\u200B:/cb"]}))
      |> T.assert_oauth_error(400, "invalid_redirect_uri")
    end

    test "plain ASCII hosts (subdomains, digits, hyphens, uppercase) remain valid" do
      for host <- ["example.com", "app-1.example.com", "EXAMPLE.com", "a.b.c.d.example.com", "x1.co"] do
        assert {:ok, _} =
                 Registration.validate(%{
                   "client_uri" => "https://" <> host,
                   "redirect_uris" => ["https://" <> host <> "/cb"]
                 })
      end
    end
  end

  # security review F-4: `https://com` would "own" every *.com redirect and a numeric host
  # (`https://0.1` is a host-suffix of `127.0.0.1`) is an IP literal, not a DNS name.
  describe "F-4 — client host must be a DNS name with at least two labels and a non-numeric TLD" do
    for host <- ["com", "localhost", "intranet", "10.0.0.5", "127.0.0.1", "0.1", "1.2.3.4", "a.b.123"] do
      test "client_uri https://#{host} is rejected" do
        host = unquote(host)

        assert {:error, "invalid_client_metadata", _} =
                 Registration.validate(%{
                   "client_uri" => "https://" <> host,
                   "redirect_uris" => ["https://" <> host <> "/cb"]
                 })
      end
    end

    # security review N-2: the WHATWG URL parser treats a last label `0x...` as a number too
    # (`https://127.0.0.0x1` -> 127.0.0.1, `https://0x7f.0x1` -> 127.0.0.1).
    for host <- ["127.0.0.0x1", "10.0.0.0x5", "0x7f.0x1", "0.0x1", "example.0x", "example.0XFF", "a.b.0177"] do
      test "client_uri https://#{host} (hex / octal-ish IPv4 literal) is rejected" do
        host = unquote(host)

        assert {:error, "invalid_client_metadata", _} =
                 Registration.validate(%{
                   "client_uri" => "https://" <> host,
                   "redirect_uris" => ["https://" <> host <> "/cb"]
                 })
      end
    end

    test "a hex-notation IPv4 host is rejected for logo_uri and redirect URIs too (N-2)" do
      base = %{"client_uri" => "https://example.com", "redirect_uris" => ["https://example.com/cb"]}

      assert {:error, "invalid_client_metadata", _} =
               Registration.validate(Map.put(base, "logo_uri", "https://127.0.0.0x1/logo.png"))

      assert {:error, "invalid_redirect_uri", _} =
               Registration.validate(%{base | "redirect_uris" => ["https://10.0.0.0x5/cb"]})
    end

    test "the 0.0x1 / 127.0.0.0x1 pair cannot reach a loopback redirect through the suffix rule (N-2)" do
      assert {:error, _, _} =
               Registration.validate(%{
                 "client_uri" => "https://0.0x1",
                 "application_type" => "native",
                 "redirect_uris" => ["https://127.0.0.0x1/cb"]
               })
    end

    test "a last label that merely CONTAINS 'x' or digits is still a DNS name (N-2 no over-blocking)" do
      for host <- ["example.0xyz", "example.x1", "example.co1", "ex0x1.example.com"] do
        assert {:ok, _} =
                 Registration.validate(%{
                   "client_uri" => "https://" <> host,
                   "redirect_uris" => ["https://" <> host <> "/cb"]
                 }),
               "#{host} must stay valid"
      end
    end

    test "a single-label / IPv4 host is rejected for logo_uri and redirect URIs too" do
      base = %{"client_uri" => "https://example.com", "redirect_uris" => ["https://example.com/cb"]}

      assert {:error, "invalid_client_metadata", _} =
               Registration.validate(Map.put(base, "logo_uri", "https://10.0.0.5/logo.png"))

      assert {:error, "invalid_redirect_uri", _} =
               Registration.validate(%{base | "redirect_uris" => ["https://10.0.0.5/cb"]})

      assert {:error, "invalid_redirect_uri", _} =
               Registration.validate(
                 Map.merge(base, %{"application_type" => "native", "redirect_uris" => ["https://com/cb"]})
               )
    end

    test "an IPv4 look-alike client host cannot reach a loopback redirect through the suffix rule" do
      assert {:error, _, _} =
               Registration.validate(%{
                 "client_uri" => "https://0.1",
                 "application_type" => "native",
                 "redirect_uris" => ["https://127.0.0.1/cb"]
               })
    end

    test "numeric labels elsewhere are fine (only the LAST label must not be all digits)" do
      assert {:ok, %{client_host: "123.example.com"}} =
               Registration.validate(%{
                 "client_uri" => "https://123.example.com",
                 "redirect_uris" => ["https://123.example.com/cb"]
               })
    end
  end

  describe "request body size / shape — OAuth error shape, never plain text or 5xx" do
    test "a body above the 128 KiB registration cap => 413 invalid_request (JSON, OAuth shape)" do
      big = T.web_body(%{"client_name" => String.duplicate("A", 140_000)})

      conn = T.register(big)
      T.assert_oauth_error(conn, 413, "invalid_request")
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert T.header(conn, "cache-control") == "no-store"
    end

    test "a padded body just below the cap is parsed and validated normally (client_name too long => 400)" do
      body = T.web_body(%{"x_padding" => String.duplicate("A", 100_000)})
      assert {:ok, _} = Registration.validate(body)
      # reaches validation (not the 413 path): an over-long name is an invalid_client_metadata
      T.register(Map.put(body, "client_name", String.duplicate("N", 300)))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "oversize is answered the same way while OAuth is enabled and the body is not an object" do
      raw = "[" <> String.duplicate("1,", 100_000) <> "1]"
      T.register(raw) |> T.assert_oauth_error(413, "invalid_request")
    end

    test "deeply nested objects (within the byte cap) => 400 invalid_request" do
      depth = 20_000
      nested = String.duplicate(~s({"a":), depth) <> "1" <> String.duplicate("}", depth)
      raw = ~s({"client_uri":"https://example.com","redirect_uris":["https://example.com/cb"],"x":) <> nested <> "}"
      assert byte_size(raw) < 131_072

      T.register(raw) |> T.assert_oauth_error(400, "invalid_request")
    end

    test "deeply nested arrays => 400 invalid_request" do
      depth = 30_000
      nested = String.duplicate("[", depth) <> String.duplicate("]", depth)
      raw = ~s({"client_uri":"https://example.com","redirect_uris":["https://example.com/cb"],"x":) <> nested <> "}"
      assert byte_size(raw) < 131_072

      T.register(raw) |> T.assert_oauth_error(400, "invalid_request")
    end

    test "ordinary nesting (an unknown nested field) is untouched by the depth guard" do
      # rejected for the http client_uri (before any DB access) — NOT as invalid_request/too deep
      T.register(T.web_body(%{"client_uri" => "http://bad", "unknown_nested" => %{"a" => %{"b" => [1, 2, %{"c" => 3}]}}}))
      |> T.assert_oauth_error(400, "invalid_client_metadata")
    end

    test "the body cap is scoped to /oauth2/register: other JSON routes keep the 1 MB default" do
      raw = Jason.encode!(%{"padding" => String.duplicate("A", 200_000)})

      conn =
        Plug.Test.conn(:post, "/_matrix/client/v3/login", raw)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      refute conn.status == 413
    end
  end
end
