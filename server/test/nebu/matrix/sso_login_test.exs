defmodule Nebu.Matrix.SsoLoginTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-scopes-configurable`, AC4 + AC11 (Matrix side).

  ## What is under test

  After this story `scope_list/0` in `Nebu.Matrix.SsoLogin` must:

    1. Read `matrix_oidc_extra_scopes` from `server_config` (via the
       `:matrix_oidc_extra_scopes_reader` seam — mirrors the existing
       `:matrix_oidc_refresh_mode_reader` pattern).
    2. Always include `"openid"` (OIDC-mandatory).
    3. Append the extra scopes (default `""` if NULL/empty — OIDC Scopes Law: only "openid").
    4. Add `"offline_access"` iff `matrix_refresh_mode() == "offline"`.
    5. Return space-separated, de-duplicated, filtered string.

  TODAY `scope_list/0` uses a compile-time `@base_scopes ~w(openid profile email)` and
  does not consult `server_config` for extra scopes. The `:matrix_oidc_extra_scopes_reader`
  seam does NOT exist yet. All tests below are RED until the seam + runtime read is added.

  ## Public surface (no testing of privates)

  `scope_list/0` is `defp`. We assert via the only public observable: the `scope`
  query-param of the 302 `GET /_matrix/client/v3/login/sso/redirect` redirect — the
  same pattern as `sso_scope_mode_test.exs` and `sso_login_scope_test.exs`.

  ## Test seam

  `:matrix_oidc_extra_scopes_reader` — a 0-arity fun injected via Application.put_env.
  Returns a string of space-separated extra scopes (beyond `openid`), or `nil`/`""` to
  trigger the default `"profile email"` fallback. Mirrors `:matrix_oidc_refresh_mode_reader`.

  ## Crash/restart — NOT APPLICABLE

  Pure config read on the request process (Persistenz Option C — stateless).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  defp setup_oidc do
    Nebu.Web.OidcTestSupport.configure(@issuer, "nebu-client")
    Application.put_env(:nebu_http, :admin_secret_at_rest, "sso-login-extra-scopes-test-key")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("shhh")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    # Pin online mode so offline_access is absent by default — tests that need
    # offline mode set it explicitly via set_mode/1.
    Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "online" end)

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_oidc_refresh_mode_reader,
            :matrix_oidc_extra_scopes_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp set_mode(mode),
    do: Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> mode end)

  defp set_extra_scopes(scopes),
    do: Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> scopes end)

  defp scope_params do
    conn =
      conn(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
          URI.encode_www_form("https://app.example.com/#/home")
      )

    conn = Nebu.Web.Router.call(conn, @router_opts)
    assert conn.status == 302
    loc = conn |> get_resp_header("location") |> List.first()
    assert is_binary(loc) and String.starts_with?(loc, @authorize)

    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  setup do
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    setup_oidc()
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-1 — No extra scopes → returns "openid" only (OIDC Scopes Law: default is ONLY openid)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-1: no extra scopes configured → openid only (OIDC Scopes Law)" do
    test "nil extra scopes + online mode → openid only, no profile/email/offline_access" do
      # OIDC Scopes Law: default scope is ONLY "openid". No fallback to "profile email".
      # bugfix-remove-default-scopes: @default_matrix_extra_scopes must be "" not "profile email".
      set_extra_scopes(nil)
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile must NOT be in default scopes (OIDC Scopes Law violation); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scopes (OIDC Scopes Law violation); got: #{inspect(scopes)}"

      refute "offline_access" in scopes,
             "online mode must not add offline_access; got: #{inspect(scopes)}"
    end

    test "empty string extra scopes + online mode → openid only, no fallback to profile email" do
      # OIDC Scopes Law: empty string means no extra scopes — do not fall back to defaults.
      set_extra_scopes("")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      refute "profile" in scopes
      refute "email" in scopes
      refute "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-2 — Custom scopes via seam → returns openid + custom scopes
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-2: custom extra scopes via seam" do
    test "extra scopes 'profile email groups' → scope includes groups" do
      # The seam must cause scope_list/0 to use custom scopes instead of @base_scopes.
      set_extra_scopes("profile email groups")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "groups" in scopes,
             "custom extra scope 'groups' must appear in scope list; got: #{inspect(scopes)}"

      refute "offline_access" in scopes
    end

    test "extra scopes 'profile email' → no groups" do
      set_extra_scopes("profile email")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      refute "groups" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-3 — Offline mode + extra scopes → includes offline_access
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-3: offline mode + extra scopes → offline_access appended" do
    test "offline mode with custom scopes includes offline_access" do
      set_extra_scopes("profile email groups")
      set_mode("offline")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "groups" in scopes
      assert "offline_access" in scopes,
             "offline mode must include offline_access; got: #{inspect(scopes)}"
    end

    test "offline mode with nil extra scopes → openid + offline_access only (no defaults)" do
      # OIDC Scopes Law: nil extra scopes must NOT fall back to "profile email".
      # Only "openid" + "offline_access" for offline mode when no custom scopes set.
      set_extra_scopes(nil)
      set_mode("offline")

      scopes = scope_params()

      assert "openid" in scopes
      refute "profile" in scopes
      refute "email" in scopes
      assert "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-4 — Duplicate scopes → de-duplicated
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-4: duplicate scopes in extra_scopes are de-duplicated" do
    test "extra scopes containing openid are not duplicated" do
      # The seam returns extra scopes that include openid (which is always added).
      # Result must contain exactly one "openid".
      set_extra_scopes("openid profile email")
      set_mode("online")

      scopes = scope_params()

      assert Enum.count(scopes, &(&1 == "openid")) == 1,
             "openid must appear exactly once even when duplicated in extra scopes; got: #{inspect(scopes)}"

      assert "profile" in scopes
      assert "email" in scopes
    end

    test "extra scopes with repeated tokens are de-duplicated" do
      set_extra_scopes("profile profile email email")
      set_mode("online")

      scopes = scope_params()

      assert Enum.count(scopes, &(&1 == "profile")) == 1,
             "profile must appear exactly once; got: #{inspect(scopes)}"

      assert Enum.count(scopes, &(&1 == "email")) == 1,
             "email must appear exactly once; got: #{inspect(scopes)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story `fix-and-configure-sso-redirect-schemes` — RED-phase tests below.
  #
  # AC12.1 (bugfix regression), AC12.2 (feature: cache-backed extra schemes),
  # AC10 (callback_url/1 independence regression), and an additional near-miss
  # scheme rejection test required by the Oracle spec-compliance gate
  # (RFC 8252 §8.6 — exact-string matching only, no substring/prefix match).
  #
  # These exercise the ONLY public surface of the allowlist:
  # `Nebu.Matrix.SsoLogin.redirect_url_allowed?/1` (currently `@doc false` but
  # already called directly by other test files in this suite — see the module
  # docs above; this module makes it public-in-practice for tests). The
  # `:sso_redirect_schemes_reader` seam introduced here does NOT exist in the
  # implementation yet (`extra_redirect_schemes/0` still reads
  # `Application.get_env(:nebu_http, :sso_redirect_schemes)`), so
  # AC12.2 tests are expected to fail (RED) until AC6/AC7 are implemented.
  # ════════════════════════════════════════════════════════════════════════════

  alias Nebu.Matrix.SsoLogin

  defp set_extra_schemes_seam(fun) when is_function(fun, 0),
    do: Application.put_env(:nebu_http, :sso_redirect_schemes_reader, fun)

  defp clear_extra_schemes_seam,
    do: Application.delete_env(:nebu_http, :sso_redirect_schemes_reader)

  # ── AC12.1 — Bugfix Regression Tests (corrected default deep-link schemes) ──

  describe "AC12.1: corrected default deep-link schemes (bugfix)" do
    test "test_redirect_url_allowed_im_fluffychat_auth" do
      assert SsoLogin.redirect_url_allowed?("im.fluffychat.auth://open?loginToken=abc")
    end

    test "test_redirect_url_allowed_schildichat" do
      assert SsoLogin.redirect_url_allowed?("schildichat://open?loginToken=xyz")
    end

    test "test_redirect_url_not_allowed_io_element_fluffychat" do
      refute SsoLogin.redirect_url_allowed?("io.element.fluffychat://open?loginToken=abc")
    end

    test "test_redirect_url_not_allowed_bare_fluffychat" do
      refute SsoLogin.redirect_url_allowed?("fluffychat://open?loginToken=abc")
    end

    test "test_redirect_url_allowed_element" do
      assert SsoLogin.redirect_url_allowed?("element://open?loginToken=abc")
    end
  end

  # ── AC12.2 — Feature Tests (Cache + Extra Schemes) ──────────────────────────

  describe "AC12.2: extra_redirect_schemes/0 cache + seam behaviour" do
    setup do
      on_exit(&clear_extra_schemes_seam/0)
      :ok
    end

    test "test_extra_redirect_schemes_empty_when_not_set" do
      # No seam, no server_config value: the cache-backed read must yield [] so
      # only the hardcoded defaults + denylist govern the allowlist decision.
      #
      # This must be proven as a REAL toggle, not merely "myorg-matrix is
      # rejected" (which would pass vacuously even if the seam is never read
      # at all, e.g. a stubbed extra_redirect_schemes/0 that always returns
      # []). So: first prove the seam IS consulted (custom scheme allowed
      # while the seam is set), THEN clear the seam and prove the SAME
      # scheme flips back to rejected. Only an implementation that actually
      # reads the seam/cache on every call can pass both halves.
      set_extra_schemes_seam(fn -> ["myorg-matrix"] end)
      assert SsoLogin.redirect_url_allowed?("myorg-matrix://login?token=x")

      clear_extra_schemes_seam()
      refute SsoLogin.redirect_url_allowed?("myorg-matrix://login?token=x")
    end

    test "test_extra_redirect_schemes_from_cache" do
      # When the :sso_redirect_schemes_reader seam returns a list, extra scheme
      # membership must be honoured (downcase'd) by redirect_url_allowed?/1.
      set_extra_schemes_seam(fn -> ["myorg-matrix"] end)
      assert SsoLogin.redirect_url_allowed?("myorg-matrix://login?token=x")
    end

    test "test_extra_redirect_schemes_case_insensitive" do
      # Seam may return mixed-case, comma-separated-looking tokens already split;
      # the allowlist check itself downcases the incoming URL scheme, so a
      # mixed-case seam entry must still match a lowercase incoming scheme.
      set_extra_schemes_seam(fn -> ["MyOrg-Matrix", "Custom-App"] end)

      assert SsoLogin.redirect_url_allowed?("myorg-matrix://login?token=x")
      assert SsoLogin.redirect_url_allowed?("custom-app://login?token=x")
    end

    test "test_redirect_url_allowed_custom_scheme_from_cache" do
      set_extra_schemes_seam(fn -> ["myorg-matrix"] end)
      assert SsoLogin.redirect_url_allowed?("myorg-matrix://login?token=x")
    end

    test "test_redirect_url_rejected_custom_scheme_not_in_cache" do
      # Proves the seam value is used as a MEMBERSHIP list, not merely
      # "truthy seam set => allow everything": with a seam that returns
      # exactly ["myorg-matrix"], a DIFFERENT custom scheme not in that
      # list must still be rejected, while "myorg-matrix" itself is allowed.
      set_extra_schemes_seam(fn -> ["myorg-matrix"] end)

      assert SsoLogin.redirect_url_allowed?("myorg-matrix://login?token=x")
      refute SsoLogin.redirect_url_allowed?("unknown-scheme://login?token=x")
    end
  end

  # ── AC12.3 — Denylist (Existing, Preserved) ─────────────────────────────────
  # NOTE: the underlying denylist BEHAVIOUR (javascript/data/file/vbscript/blob
  # always rejected) is pre-existing and unchanged by this story — these are
  # NOT duplicate test artifacts; this is the first test file in the repo to
  # assert on redirect_url_allowed?/1 directly (grep confirms), so these are
  # newly-added tests under the exact AC12.3 names for traceability with the
  # story's explicit test list. They must keep passing unmodified before AND
  # after this story's changes (AC2).

  describe "AC12.3: denylist (exact test names from AC12)" do
    test "test_redirect_url_denied_javascript" do
      refute SsoLogin.redirect_url_allowed?("javascript:alert(1)")
    end

    test "test_redirect_url_denied_data" do
      refute SsoLogin.redirect_url_allowed?("data:text/html,<script>alert(1)</script>")
    end

    test "test_redirect_url_denied_file" do
      refute SsoLogin.redirect_url_allowed?("file:///etc/passwd")
    end

    test "test_redirect_url_denied_vbscript" do
      refute SsoLogin.redirect_url_allowed?("vbscript:msgbox(1)")
    end

    test "test_redirect_url_denied_blob" do
      refute SsoLogin.redirect_url_allowed?("blob:https://example.com/uuid")
    end
  end

  # ── AC12.4 — Denylist Wins Over Custom Allowlist ────────────────────────────

  describe "AC12.4: denylist wins over any custom allowlist entry" do
    setup do
      on_exit(&clear_extra_schemes_seam/0)
      :ok
    end

    test "test_redirect_url_denied_javascript_even_if_custom_allows_it" do
      # Even if an operator misconfigures the extra-schemes allowlist to include
      # a denylisted scheme, the hardcoded denylist must win (security-critical:
      # AC2, AC14 checklist item 2).
      set_extra_schemes_seam(fn -> ["javascript"] end)
      refute SsoLogin.redirect_url_allowed?("javascript:alert(1)")
    end
  end

  # ── Oracle spec-compliance gate — near-miss scheme rejection ────────────────
  # RFC 8252 §8.6 scheme-squatting mitigation depends on EXACT-STRING allowlist
  # membership, never substring/prefix matching. A scheme that merely CONTAINS
  # or is PREFIXED/SUFFIXED by an allowed scheme name must still be rejected.
  # This is an ADDITIONAL edge case beyond the story's own AC12 list, per the
  # Oracle spec-compliance step-result for this story.

  describe "near-miss scheme rejection (exact-match only, RFC 8252 section 8.6)" do
    test "element-evil scheme is rejected despite containing the allowed 'element' scheme" do
      refute SsoLogin.redirect_url_allowed?("element-evil://open?loginToken=abc")
    end

    test "xelement scheme is rejected despite ending in the allowed 'element' scheme" do
      refute SsoLogin.redirect_url_allowed?("xelement://open?loginToken=abc")
    end
  end

  # ── AC10 — Regression: callback_url/1 Untouched & Independent ──────────────
  # callback_url/1 is currently a private function (defp) in Nebu.Matrix.SsoLogin.
  # It is exercised indirectly today via the 302 Location header's redirect_uri
  # query param on the outbound IdP-authorize redirect (see setup_oidc/scope_params
  # above for the harness pattern). This regression test asserts independence from
  # the client-facing allowlist: even when the client redirectUrl is REJECTED,
  # the IdP-facing callback_url (used internally to build "redirect_uri") is
  # never reached/exercised on that path, AND when a redirect IS accepted, the
  # callback_url embedded in the outbound authorize request is Nebu's own fixed
  # per-request-host URL, entirely independent of the (allowed) client redirectUrl
  # value used to reach that point.
  describe "AC10: callback_url/1 is independent from client redirectUrl validation" do
    test "rejected client redirectUrl never produces an IdP-authorize redirect (callback_url is never used)" do
      conn =
        conn(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("javascript:alert(1)")
        )

      conn = Nebu.Web.Router.call(conn, @router_opts)

      # Rejected before do_redirect/2 (which computes callback_url/1) is ever reached.
      assert conn.status == 400
      assert get_resp_header(conn, "location") == []
    end

    test "callback_url embedded in the IdP redirect_uri is derived from request host, independent of the allowed client redirectUrl value" do
      if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
      setup_oidc()

      # NOTE: Plug.Conn/Plug.Test forbid setting the "host" *request header*
      # directly via put_req_header/3 (Plug.Conn.InvalidHeaderError — "host" is
      # a pseudo-header derived from the connection, not a settable header on
      # Plug.Adapters.Test.Conn). callback_url/1 reads get_req_header(conn,
      # "host") first and falls back to "#{conn.host}:#{conn.port}" — so to
      # exercise the fallback path (the realistic case for a direct, unproxied
      # request) we build the conn against a URL with an explicit host/port,
      # which Plug.Test derives conn.host/conn.port from, and assert against
      # THAT derived value instead of hardcoding "example.com".
      conn =
        conn(
          :get,
          "http://example.com:4000/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("https://app.example.com/#/home")
        )

      assert conn.host == "example.com"

      conn = Nebu.Web.Router.call(conn, @router_opts)
      assert conn.status == 302

      loc = conn |> get_resp_header("location") |> List.first()
      %URI{query: q} = URI.parse(loc)
      redirect_uri = URI.decode_query(q)["redirect_uri"]

      # callback_url/1 is built from the request scheme+host (here, via the
      # conn.host/conn.port fallback since no "host" header is present), NOT
      # from the client's redirectUrl ("https://app.example.com/..."). It must
      # point at THIS server's own fixed callback path on the request's own host.
      assert redirect_uri == "http://example.com:4000/_matrix/client/v3/login/sso/redirect/oidc",
             "callback_url must be derived solely from request host/scheme, never from the client redirectUrl; got: #{inspect(redirect_uri)}"

      refute String.contains?(redirect_uri, "app.example.com"),
             "callback_url must never leak/embed the client's redirectUrl host"
    end
  end
end
