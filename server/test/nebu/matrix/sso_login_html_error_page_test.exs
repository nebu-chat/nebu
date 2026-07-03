defmodule Nebu.Matrix.SsoLoginHtmlErrorPageTest do
  @moduledoc """
  RED-phase ATDD tests for story `sso-redirect-error-page` /
  `html-error-page-for-rejected-sso-redirect-scheme`.

  ## What is under test

  Today `Nebu.Matrix.SsoLogin.redirect/1` rejects a non-allowlisted
  `redirectUrl` scheme by ALWAYS returning the JSON error envelope:

      {"errcode":"M_INVALID_PARAM","error":"redirectUrl scheme is not permitted"}

  This story adds content negotiation on the `Accept` request header: when the
  client (a real browser navigating to this endpoint, per the Matrix SSO flow)
  clearly prefers `text/html`, the server must instead render a minimal,
  safely-escaped HTML error page (still HTTP 400) that echoes ONLY the parsed
  scheme, includes `Content-Security-Policy: default-src 'none'`, and directs
  the user to the Admin UI ("SSO redirect schemes" section under
  `/admin/config`). Any other/missing/ambiguous Accept header must continue to
  return the EXACT pre-existing JSON body, byte-for-byte (regression, AC2).

  None of this exists yet: there is no `html_accepted?/1`, no
  `render_html_error/1` (or equivalent), and `redirect/1`'s rejection branch
  unconditionally calls `Nebu.Matrix.Http.error/4`. Every HTML-path test below
  is expected to FAIL (RED) until the feature is implemented — either with a
  compile-time `UndefinedFunctionError` (if a unit test targets a
  not-yet-existing helper directly) or a run-time assertion failure showing
  the response is still the JSON envelope / missing the new headers/body
  content.

  ## Test seam / dispatch pattern

  These are plain-Plug integration tests using `Plug.Test.conn/3` dispatched
  through the full `Nebu.Web.Router` — the SAME pattern already used by
  `sso_login_test.exs` (`@router_opts = Nebu.Web.Router.init([])`,
  `Nebu.Web.Router.call(conn, @router_opts)`). The rejection branch inside
  `SsoLogin.redirect/1` is reached BEFORE any OIDC config / `SsoStore` state is
  touched (the allowlist check happens first, `do_redirect/2` — which needs
  OIDC config and `SsoStore` — is only called on the ACCEPT path), so none of
  the OIDC/bootstrap test seams or `SsoStore` supervision used elsewhere in
  `sso_login_test.exs` are needed here.

  No seam is needed to force "not allowlisted" either: any scheme that is not
  `https`, loopback `http`, one of the default deep-link schemes
  (`element`, `schildichat`, `im.fluffychat.auth`), or in the (empty-by-default)
  extra-schemes list is rejected out of the box. `unknown-scheme` and
  `evilscheme` (used below) are not in any of those lists.

  ## Crash/restart — NOT APPLICABLE

  Pure per-request rejection-response formatting; no process state, no ETS, no
  DB read on this path.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoLogin

  @router_opts Nebu.Web.Router.init([])

  @rejected_json ~s({"errcode":"M_INVALID_PARAM","error":"redirectUrl scheme is not permitted"})

  defp dispatch(query, accept_header) do
    conn =
      conn(:get, "/_matrix/client/v3/login/sso/redirect?" <> query)

    conn =
      if is_binary(accept_header) do
        put_req_header(conn, "accept", accept_header)
      else
        conn
      end

    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp rejected_scheme_query(scheme \\ "unknown-scheme") do
    "redirectUrl=" <> URI.encode_www_form("#{scheme}://host")
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 1 (AC1) — HTML negotiation: realistic browser Accept header → HTML 400
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 1 (AC1): text/html preferred by a realistic browser Accept header" do
    test "rejected scheme + browser Accept header → 400, text/html, HTML body containing the scheme" do
      conn =
        dispatch(
          rejected_scheme_query("unknown-scheme"),
          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "text/html")),
             "expected Content-Type: text/html, got: #{inspect(get_resp_header(conn, "content-type"))}"

      body = conn.resp_body

      assert String.downcase(body) =~ "<!doctype html",
             "expected an HTML document (doctype), got: #{inspect(body)}"

      assert body =~ "unknown-scheme",
             "expected the rejected scheme to be shown in human-readable form in the HTML body"
    end

    test "rejected scheme on the /sso/redirect/{idpId} variant also negotiates HTML" do
      conn =
        conn(
          :get,
          "/_matrix/client/v3/login/sso/redirect/some-idp?" <>
            rejected_scheme_query("unknown-scheme")
        )
        |> put_req_header("accept", "text/html")

      conn = Nebu.Web.Router.call(conn, @router_opts)

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "text/html"))

      assert conn.resp_body =~ "unknown-scheme"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 2 (AC2) — JSON fallback: explicit Accept: application/json
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 2 (AC2): explicit Accept: application/json → exact JSON, unchanged" do
    test "rejected scheme + Accept: application/json → 400, application/json, byte-identical body" do
      conn = dispatch(rejected_scheme_query(), "application/json")

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "application/json"))

      assert conn.resp_body == @rejected_json,
             "JSON error body must match byte-for-byte; got: #{inspect(conn.resp_body)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 3 (AC2) — JSON fallback: no Accept header at all
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 3 (AC2): missing Accept header → same exact JSON fallback" do
    test "rejected scheme + no Accept header → 400, byte-identical JSON body" do
      conn = dispatch(rejected_scheme_query(), nil)

      assert conn.status == 400
      assert conn.resp_body == @rejected_json
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 4 (AC3/AC4) — Scheme-only echo (integration) + escaping (unit)
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 4a (AC4): HTML echoes ONLY the scheme, never host/path/query" do
    test "hostile-looking redirectUrl → HTML contains the scheme but nothing else from the URL" do
      hostile_url = "evilscheme://attacker.example:9999/secret/path?token=admin"

      conn =
        conn(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form(hostile_url) <> "&<script>=1"
        )
        |> put_req_header("accept", "text/html")

      conn = Nebu.Web.Router.call(conn, @router_opts)

      assert conn.status == 400

      body = conn.resp_body

      assert body =~ "evilscheme",
             "expected the rejected scheme 'evilscheme' to appear in the HTML body"

      refute body =~ "attacker.example",
             "HTML body must never echo the redirectUrl host"

      refute body =~ "/secret/path",
             "HTML body must never echo the redirectUrl path"

      refute body =~ "token=admin",
             "HTML body must never echo the redirectUrl query string"
    end
  end

  describe "Test 4b (AC3): render-helper unit test — hostile string is HTML-entity-escaped" do
    test "render_html_error/1 escapes a hostile string, never emits raw markup" do
      # This directly exercises the NEW template-rendering helper the story
      # introduces in Nebu.Matrix.SsoLogin (named `render_html_error/1` in the
      # story's Implementation Notes; adjust here only if the dev step chooses
      # a different name for the same responsibility — the behavioural
      # contract under test is: hostile input in, HTML-entity-escaped output).
      #
      # The function does not exist yet, so this test is expected to fail with
      # `UndefinedFunctionError` (or, if the module exports it under a
      # different arity/visibility, a compile warning) until AC3 is
      # implemented. It is written as a `apply/3` call so the test file itself
      # still COMPILES today (the function plainly does not exist, so calling
      # it directly by name would be a compile-time `undefined function`
      # error inside this very module, which is red-phase-friendly but would
      # block the whole file from compiling for the OTHER 7 tests). Using
      # apply/3 defers the failure to run-time, which is the failure mode we
      # want for a RED-phase scaffold that must otherwise compile cleanly.
      hostile = "<script>alert(1)</script>"

      output = apply(SsoLogin, :render_html_error, [hostile])

      assert is_binary(output)

      assert output =~ "&lt;script&gt;alert(1)&lt;/script&gt;",
             "expected HTML-entity-escaped form in render output, got: #{inspect(output)}"

      refute output =~ "<script>alert(1)</script>",
             "raw, unescaped <script> markup must never appear in rendered output"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 5 (AC5) — CSP + nosniff headers present on the HTML path
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 5 (AC5): security headers on the HTML error response" do
    test "HTML response includes CSP default-src 'none' and X-Content-Type-Options: nosniff" do
      conn = dispatch(rejected_scheme_query(), "text/html")

      assert conn.status == 400

      csp = conn |> get_resp_header("content-security-policy")

      assert "default-src 'none'" in csp,
             "expected Content-Security-Policy: default-src 'none', got: #{inspect(csp)}"

      nosniff = conn |> get_resp_header("x-content-type-options")

      assert "nosniff" in nosniff,
             "expected X-Content-Type-Options: nosniff (set globally by Router.security_headers), got: #{inspect(nosniff)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 6 (AC1/story) — Actionable text referencing the Admin UI
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 6: HTML body is actionable — points to the Admin UI SSO scheme config" do
    test "HTML body references the administrator and the /admin/config SSO redirect schemes section" do
      conn = dispatch(rejected_scheme_query(), "text/html")

      assert conn.status == 400
      body = conn.resp_body

      assert body =~ ~r/administrator/i,
             "expected the HTML body to direct the user to contact the server administrator"

      assert body =~ "/admin/config",
             "expected the HTML body to reference the real Admin UI location (/admin/config), " <>
               "got: #{inspect(body)}"

      assert body =~ "SSO redirect schemes",
             "expected the HTML body to reference the \"SSO redirect schemes\" section heading (see " <>
               "server/lib/nebu/admin/templates/config/index.html.heex), got: #{inspect(body)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 7 (AC6) — Allowlist logic regression (smoke check only)
  # ════════════════════════════════════════════════════════════════════════════

  # The full regression gate for `redirect_url_allowed?/1` and scheme
  # categorization is `server/test/nebu/matrix/sso_login_test.exs`, which is
  # NOT modified by this story and must keep passing unmodified (AC6). This
  # file adds only a minimal smoke check that the function is untouched and
  # still importable/callable with its pre-existing behaviour, so a failure
  # here would immediately flag an accidental regression introduced by this
  # story's changes to the SAME module.
  describe "Test 7 (AC6): redirect_url_allowed?/1 untouched (smoke check)" do
    test "a known-good https scheme is still allowed" do
      assert SsoLogin.redirect_url_allowed?("https://example.com")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 8 (Implementation Notes heuristic) — Accept-header q-value edge cases
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 8: Accept-header heuristic edge cases (conservative, JSON-biased)" do
    test "Accept: application/json, text/html;q=0.8 → JSON wins (explicit json, no q vs implicit q=1 html)" do
      conn = dispatch(rejected_scheme_query(), "application/json, text/html;q=0.8")

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "application/json")),
             "json (no explicit q, i.e. q=1) must win over html;q=0.8"

      assert conn.resp_body == @rejected_json
    end

    test "Accept: */*, text/html → HTML wins (explicit html present, no competing higher-priority json)" do
      conn = dispatch(rejected_scheme_query(), "*/*, text/html")

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "text/html")),
             "explicit text/html (no json in the header at all) must win over a bare */* wildcard"
    end

    test "Accept: text/html;q=0.1, application/json;q=0.9 → JSON wins (higher q-value)" do
      conn = dispatch(rejected_scheme_query(), "text/html;q=0.1, application/json;q=0.9")

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "application/json")),
             "application/json;q=0.9 must win over text/html;q=0.1"

      assert conn.resp_body == @rejected_json
    end

    test "Accept: */* (bare wildcard, no text/html token at all) → JSON (AC1 explicit case)" do
      conn = dispatch(rejected_scheme_query(), "*/*")

      assert conn.status == 400

      assert conn
             |> get_resp_header("content-type")
             |> Enum.any?(&String.starts_with?(&1, "application/json")),
             "a bare */* with no text/html token present must fall back to JSON"

      assert conn.resp_body == @rejected_json
    end
  end
end
