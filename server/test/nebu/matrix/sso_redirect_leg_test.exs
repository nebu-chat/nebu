defmodule Nebu.Matrix.SsoRedirectLegTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC2: the redirect leg
  `GET /_matrix/client/v3/login/sso/redirect[/{idpId}]?redirectUrl=...` (plug level through the full router,
  IdP stubbed, no DB).

  The leg calls `SsoRedirect.classify/1` exactly where it called `redirect_url_allowed?/1`: the error order
  (`M_MISSING_PARAM`, then the rejection, then `action`) and the rejection representation (JSON
  `400 M_INVALID_PARAM "redirectUrl scheme is not permitted"`, or the HTML page when `Accept` clearly prefers
  HTML) stay byte-identical; the WARNING `matrix SSO: redirectUrl rejected by allowlist` stays value-free.
  A rejected URL stores no SSO state and never reaches the IdP.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.SsoLogin
  alias Nebu.OAuth.TestSupport, as: T

  @expected_json %{"errcode" => "M_INVALID_PARAM", "error" => "redirectUrl scheme is not permitted"}

  setup do
    T.reset_rate_limits()
    T.setup_idp!()
    T.put_env_scoped(:sso_redirect_schemes_reader, fn -> ["myorg-matrix"] end)

    on_exit(fn -> T.restore_rate_limits() end)

    :ok
  end

  # D2 rows that are open redirects (or parser differentials) TODAY and must now answer the unchanged 400.
  @rejected [
    {"https://evil.example\\@listed.example/", "https"},
    {"http://evil.example\\@localhost/", "http"},
    {"https:evil.example", "https"},
    {"https:/evil.example", "https"},
    {"https:\\\\evil.example", "https"},
    {"https:///evil.example", "https"},
    {"https://%65vil.example/", "https"},
    {"https://element.example.com@evil.example/", "https"},
    {"http://127.0.0.1@evil.example/", "http"},
    {"https://evil.example./", "https"},
    {"https://bücher.example/", "https"},
    {"https://[::1]:8443/", "https"},
    {"https://example.com\t/", "https"},
    {"https://example.com:99999/", "https"},
    {"https://0x7f.0.0.1/", "https"},
    {"https://2130706433/", "https"},
    {"https://10.1/", "https"},
    {"http://localhost.evil.example/", "http"},
    {"http://[::1]:8080/", "http"},
    {"https://example.com/" <> String.duplicate("a", 2100), "https"},
    {"evilscheme://x", "evilscheme"},
    {"javascript:alert(1)", "javascript"}
  ]

  defp state_count, do: T.sso_count(:state)

  describe "AC2.1 — a D2-rejected URL answers the byte-identical 400, stores nothing, never reaches the IdP" do
    for {raw, _scheme} <- @rejected do
      test "JSON 400 for #{inspect(raw, limit: 60, printable_limit: 60)}" do
        before = state_count()
        conn = T.sso_redirect([], redirect_url: unquote(raw))

        assert conn.status == 400
        assert T.location(conn) == nil, "no redirect (not even to the IdP)"
        assert Jason.decode!(conn.resp_body) == @expected_json

        baseline = T.sso_redirect([], redirect_url: "evilscheme://baseline")
        assert conn.resp_body == baseline.resp_body, "byte-identical to today's rejection body"
        assert T.header(conn, "content-type") == T.header(baseline, "content-type")
        assert state_count() == before, "a rejected URL stores no SSO state"
      end
    end

    for {raw, scheme} <- @rejected, scheme != "evilscheme" do
      test "HTML 400 (Accept: text/html) names only the parsed scheme for #{inspect(raw, limit: 60, printable_limit: 60)}" do
        conn = T.sso_redirect([], redirect_url: unquote(raw), headers: [{"accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"}])
        assert conn.status == 400
        assert conn.resp_body == SsoLogin.render_html_error(unquote(scheme)), "the HTML page of render_html_error/1, unchanged"
        assert T.header(conn, "content-security-policy") == "default-src 'none'"
        refute conn.resp_body =~ "evil.example", "no part of the URL is echoed"
      end
    end

    test "the WARNING text is unchanged and carries no part of the URL" do
      log =
        capture_log(fn ->
          conn = T.sso_redirect([], redirect_url: "https://evil-marker.example\\@listed-marker.example/secret-path?q=secret-query")
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, %{status: 400}}
      assert log =~ "[warning] matrix SSO: redirectUrl rejected by allowlist"
      for part <- ["evil-marker", "listed-marker", "secret-path", "secret-query"], do: refute(log =~ part, "#{part} leaked into the log")
    end
  end

  describe "AC2.2 — missing and malformed redirectUrl parameters" do
    test "a missing redirectUrl and `redirectUrl[]=x` still answer 400 M_MISSING_PARAM" do
      for conn <- [T.sso_redirect([], redirect_url: nil), T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl[]=x")] do
        assert conn.status == 400
        assert T.json(conn)["errcode"] == "M_MISSING_PARAM"
      end
    end

    test "an empty redirectUrl is M_MISSING_PARAM (today's order: missing first)" do
      conn = T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=")
      assert conn.status == 400
      assert T.json(conn)["errcode"] == "M_MISSING_PARAM"
    end

    test "a repeated redirectUrl: the LAST value is classified AND stored" do
      qs = "redirectUrl=" <> URI.encode_www_form("https://a.example/") <> "&redirectUrl=" <> URI.encode_www_form("https://b.example/")
      conn = T.get("/_matrix/client/v3/login/sso/redirect?" <> qs)
      assert conn.status == 302
      state = T.idp_params(conn)["state"]
      assert {:ok, %{redirect_url: "https://b.example/"}} = Nebu.Matrix.SsoStore.peek_state(state)
    end

    test "a repeated redirectUrl whose last value is rejected is rejected even when the first is fine" do
      qs = "redirectUrl=" <> URI.encode_www_form("https://a.example/") <> "&redirectUrl=" <> URI.encode_www_form("https://evil.example\\@a.example/")
      conn = T.get("/_matrix/client/v3/login/sso/redirect?" <> qs)
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == @expected_json
    end

    test "the error order is unchanged: a rejected redirectUrl answers 400 before `action` is looked at" do
      plain = T.sso_redirect([], redirect_url: "https:evil.example")
      reg = T.sso_redirect([{"action", "register"}], redirect_url: "https:evil.example")
      assert {plain.status, plain.resp_body} == {reg.status, reg.resp_body}
      assert plain.status == 400
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2.3 — legitimate shapes still 302 to the IdP
  # ════════════════════════════════════════════════════════════════════════════

  @accepted [
    "http://localhost:7070/#/home",
    "http://127.0.0.1:9000/cb",
    "http://localhost:3001//login",
    "element://vector/webapp/",
    "element://vector/webapp/?element-desktop-ssoid=abc#/login",
    "schildichat://login",
    "im.fluffychat.auth://login",
    "myorg-matrix://login",
    "https://app.example.com/#/home",
    "https://app.example.com/?updated=1#/login",
    "https://10.0.0.5:8443/",
    "https://app.ex/#/user/@bob:ex.org",
    "https://app.ex/#/room/#a:ex.org",
    "https://app.ex/p%20q?x=%2F",
    "https://app.ex?x=1#/login",
    "https://Example.COM:443/a",
    "https://xn--bcher-kva.example/",
    "https://example.com/" <> String.duplicate("a", 2048 - byte_size("https://example.com/"))
  ]

  describe "AC2.3 — accepted shapes: 302 to the IdP with the URL stored byte-for-byte" do
    for raw <- @accepted do
      test "302 for #{inspect(raw, limit: 60, printable_limit: 60)}" do
        conn = T.sso_redirect([], redirect_url: unquote(raw))
        assert conn.status == 302, "got #{conn.status}: #{String.slice(conn.resp_body, 0, 200)}"
        idp = T.idp_params(conn)
        assert {:ok, %{redirect_url: stored}} = Nebu.Matrix.SsoStore.peek_state(idp["state"])
        assert stored == unquote(raw), "the stored value IS the checked value (no differential)"
        assert T.header(conn, "cache-control") =~ "no-store"
      end
    end
  end

  describe "AC2.5 (oracle m6) — the /{idpId} form behaves exactly like the plain form" do
    test "an accepted URL 302s to the IdP for /oidc and for any other idp id" do
      for idp <- ["oidc", "some-other-idp"] do
        conn = T.sso_redirect([], idp: idp, redirect_url: "https://app.example.com/#/home")
        assert conn.status == 302, "idp #{idp}"
        plain = T.sso_redirect([], redirect_url: "https://app.example.com/#/home")
        assert Map.drop(T.idp_params(conn), ~w(state nonce code_challenge)) == Map.drop(T.idp_params(plain), ~w(state nonce code_challenge))
      end
    end

    test "a rejected URL gives the same 400 on the /{idpId} form" do
      for raw <- ["https://evil.example\\@listed.example/", "https:evil.example", "http://127.0.0.1@evil.example/"] do
        conn = T.sso_redirect([], idp: "oidc", redirect_url: raw)
        assert conn.status == 400
        assert Jason.decode!(conn.resp_body) == @expected_json
      end
    end

    test "the idp id `confirm` is still an IdP-id redirect (the new /sso/confirm route does not collide)" do
      conn = T.sso_redirect([], idp: "confirm", redirect_url: "https://app.example.com/")
      assert conn.status == 302
      assert String.starts_with?(T.location(conn), T.idp_authorize_endpoint())
    end
  end

  describe "AC2.4 — the `action` handling and the IdP URL of story oauth-legacy-coexistence are unchanged" do
    test "the IdP authorize URL of an accepted https URL carries the legacy parameter set and prompt=login" do
      idp = T.sso_redirect([], redirect_url: "https://app.example.com/#/home") |> T.idp_params()
      assert idp["prompt"] == "login"
      refute Map.has_key?(idp, "max_age")
      assert idp["scope"] == "openid"
      assert idp["state"] =~ ~r/\A[0-9a-f]{32}\z/
    end
  end
end
