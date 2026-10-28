defmodule Nebu.Matrix.SsoRedirectConfirmFlowTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3): the callback decision and the
  confirmation round trip. Covers AC3 (listed / direct targets are byte-identical to today), AC4 (an unlisted
  https target gets NO token, a pending confirmation), AC7 (Continue), AC8 (Cancel), AC10.1 / AC10.2 (TTL,
  single use under concurrency) and AC16.1 / AC16.3 (UIA fallback untouched, loginToken replay / expiry / forgery).

  Plug level through the full router, IdP stubbed (`T.setup_idp!/1`), `:sso_trusted_origin_check` stubbed so no
  DB is needed; the tests that redeem a loginToken at `POST /login` are `:integration`.

  Pinned (story D3, D7-D10; ATDD role):

    * callback, unlisted https target: `303 Location: /_matrix/client/v3/login/sso/confirm`, binding cookie,
      NO loginToken (the SsoStore token count is unchanged), a pending `:confirm` entry under SHA-256 of the
      cookie, the SSO state consumed.
    * Continue: `303` (never 302/307) to `append_login_token(redirect_url, token)` of the RAW redirect URL.
    * Cancel: `200` page `data-result="cancelled"`, nothing minted.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.SsoLogin
  alias Nebu.Matrix.SsoStore
  alias Nebu.OAuth.TestSupport, as: T

  @unlisted "https://unlisted.example/cb"

  setup do
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.drop_confirm_entries!()
    T.drop_token_entries!()
    T.sso_no_trusted_origins!()
    T.sso_origins!([])
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.restore_rate_limits()
      T.drop_confirm_entries!()
      T.drop_token_entries!()
    end)

    {:ok, priv: priv}
  end

  defp callback(priv, url, opts \\ []), do: T.legacy_callback!(priv, Keyword.get(opts, :sub, T.unique_sub()), url, opts)

  defp trusted_spy! do
    me = self()
    T.sso_trusted_check!(fn origin, raw_url ->
      send(me, {:trusted_asked, origin, raw_url})
      false
    end)
  end

  # AC3.1: exactly today's response (D20 aside): 302, no-store, Location = append_login_token(url, token),
  # empty body, no confirm cookie, no CSP / X-Frame-Options added by this story; the token is a live loginToken.
  defp assert_direct(conn, url) do
    assert conn.status == 302, "expected today's 302 for #{url}, got #{conn.status} Location=#{inspect(T.location(conn))} body=#{String.slice(conn.resp_body || "", 0, 200)}"
    assert T.header(conn, "cache-control") =~ "no-store"
    assert [token] = T.login_tokens_of(conn)
    assert T.location(conn) == SsoLogin.append_login_token(url, token)
    assert T.sso_confirm_set_cookies(conn) == [], "no confirm cookie for a listed / direct target"
    assert T.header(conn, "content-security-policy") == nil
    assert T.header(conn, "x-frame-options") == nil
    assert conn.resp_body in [nil, ""]
    ttl = T.sso_token_ttl(token)
    assert is_integer(ttl) and ttl in 25..30, "a 30 s loginToken, remaining lifetime: #{inspect(ttl)}"
    token
  end

  # a snapshot of the live loginToken keys: compared before / after (never absolute counts: the store is shared)
  defp token_count, do: T.sso_token_keys()

  # ════════════════════════════════════════════════════════════════════════════
  # AC3.1 — direct and listed targets: today's behaviour
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3.1 — :direct targets keep today's 302 with the loginToken" do
    test "(a) loopback http (the existing fixture shape)", %{priv: priv} do
      assert_direct(callback(priv, "http://localhost:7070/#/home"), "http://localhost:7070/#/home")
      assert_direct(callback(priv, "http://127.0.0.1:9000/cb?x=1"), "http://127.0.0.1:9000/cb?x=1")
    end

    test "(b) a default deep-link scheme and an operator extra scheme", %{priv: priv} do
      T.put_env_scoped(:sso_redirect_schemes_reader, fn -> ["myorg-matrix"] end)

      for url <- ["element://vector/webapp/", "schildichat://login", "im.fluffychat.auth://login", "myorg-matrix://login?a=1"] do
        assert_direct(callback(priv, url), url)
      end
    end

    test "direct targets never ask the trusted-origin check (no DB cost, no confirmation)", %{priv: priv} do
      trusted_spy!()
      assert_direct(callback(priv, "http://localhost:7070/#/home"), "http://localhost:7070/#/home")
      assert_direct(callback(priv, "element://vector/webapp/"), "element://vector/webapp/")
      refute_received {:trusted_asked, _, _}
    end
  end

  describe "AC3.1(c) — https://<server_name> is listed AUTOMATICALLY (never the Host header)" do
    test "server_name chat.example.test lists https://chat.example.test (default port)", %{priv: priv} do
      T.put_env_scoped(:server_name, "chat.example.test")
      assert_direct(callback(priv, "https://chat.example.test/#/home"), "https://chat.example.test/#/home")
      assert_direct(callback(priv, "https://CHAT.example.test:443/cb"), "https://CHAT.example.test:443/cb")
    end

    test "server_name chat.example.test:8448 lists https://chat.example.test:8448 and NOT https://chat.example.test", %{priv: priv} do
      T.put_env_scoped(:server_name, "chat.example.test:8448")
      assert_direct(callback(priv, "https://chat.example.test:8448/cb"), "https://chat.example.test:8448/cb")
      cb = callback(priv, "https://chat.example.test/cb")
      T.assert_confirm_redirect(cb)
    end

    test "an apex / subdomain / other port of the server name is NOT listed", %{priv: priv} do
      T.put_env_scoped(:server_name, "chat.example.test")

      for url <- ["https://example.test/cb", "https://sub.chat.example.test/cb", "https://chat.example.test:8443/cb"] do
        T.assert_confirm_redirect(callback(priv, url))
      end
    end

    test "an unparsable server_name contributes nothing (fail closed)", %{priv: priv} do
      T.put_env_scoped(:server_name, "bad name with spaces")
      T.assert_confirm_redirect(callback(priv, "https://bad.example/cb"))
    end

    test "the request Host header is NEVER used: a Host equal to the target does not list it (Host-spoof test)", %{priv: priv} do
      cb = callback(priv, "https://evil.example/cb", headers: [{"host", "evil.example"}])
      T.assert_confirm_redirect(cb)
      refute T.location(cb) =~ "evil.example"
    end
  end

  describe "AC3.1(d) — the operator list sso_redirect_allowed_origins" do
    test "a listed origin is direct, also with a different case and an explicit :443 in the redirectUrl", %{priv: priv} do
      T.sso_origins!(["https://listed.example"])

      for url <- ["https://listed.example/cb", "https://LISTED.Example:443/cb?x=1", "HTTPS://listed.example/#/login", "https://listed.example"] do
        assert_direct(callback(priv, url), url)
      end
    end

    test "the list can be the stored comma+space separated string, with a port origin", %{priv: priv} do
      T.sso_origins!("https://a.example, https://b.example:8443")
      assert_direct(callback(priv, "https://b.example:8443/x"), "https://b.example:8443/x")
      assert_direct(callback(priv, "https://a.example/x"), "https://a.example/x")
      T.assert_confirm_redirect(callback(priv, "https://b.example/x"))
    end

    test "a hand-edited entry that does not normalize is ignored and never widens the list", %{priv: priv} do
      T.sso_origins!("https://ok.example, *.evil.example, http://plain.example, https://u@userinfo.example")
      assert_direct(callback(priv, "https://ok.example/"), "https://ok.example/")

      for url <- ["https://sub.evil.example/", "https://userinfo.example/", "https://evil.example/"] do
        T.assert_confirm_redirect(callback(priv, url))
      end
    end

    test "classification at callback time sees the CURRENT list (the list may change during the 10 min IdP window)", %{priv: priv} do
      flow = T.sso_start!("https://late.example/cb")
      T.sso_origins!(["https://late.example"])
      assert_direct(T.sso_finish(flow, priv), "https://late.example/cb")
    end

    test "the list is read through the OidcConfig cache getter when no seam is installed", %{priv: priv} do
      Application.delete_env(:nebu_http, :sso_redirect_origins_reader)
      assert {:module, Nebu.Web.OidcConfig} = Code.ensure_loaded(Nebu.Web.OidcConfig)
      assert function_exported?(Nebu.Web.OidcConfig, :get_sso_redirect_allowed_origins, 0)
      # nothing configured: empty list => the confirmation page
      T.assert_confirm_redirect(callback(priv, "https://nothing-listed.example/cb"))
    end
  end

  describe "AC3.1(d) — the real OidcConfig cache is the source of the operator list (no seam)" do
    @describetag :integration

    setup do
      case Nebu.Web.OidcConfig.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      %{rows: prior} = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = 'sso_redirect_allowed_origins'")

      on_exit(fn ->
        T.privileged_sql!("DELETE FROM server_config WHERE key = 'sso_redirect_allowed_origins'")
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
        if Process.whereis(Nebu.Web.OidcConfig), do: Nebu.Web.OidcConfig.refresh()
      end)

      Application.delete_env(:nebu_http, :sso_redirect_origins_reader)
      :ok
    end

    test "an origin stored in server_config and refreshed into the cache is listed (302, no confirmation); another origin is not", %{priv: priv} do
      T.privileged_sql!("DELETE FROM server_config WHERE key = 'sso_redirect_allowed_origins'")

      T.privileged_sql!(
        "INSERT INTO server_config (key, value, set_at) VALUES ('sso_redirect_allowed_origins', 'https://cfg.example', 0)"
      )

      :ok = Nebu.Web.OidcConfig.refresh()
      assert apply(Nebu.Web.OidcConfig, :get_sso_redirect_allowed_origins, []) == "https://cfg.example"

      assert_direct(callback(priv, "https://cfg.example/cb"), "https://cfg.example/cb")
      T.assert_confirm_redirect(callback(priv, "https://other-cfg.example/cb"))
    end
  end

  describe "AC3.2 — what is NOT listed gets the confirmation" do
    test "an origin that only differs in port or by a subdomain from a listed one", %{priv: priv} do
      T.sso_origins!(["https://listed.example"])

      for url <- ["https://listed.example:8443/cb", "https://sub.listed.example/cb", "https://listed.example.evil.example/cb", "https://xlisted.example/cb"] do
        T.assert_confirm_redirect(callback(priv, url))
      end
    end

    test "a stored state whose URL no longer classifies (http://, even on a listed host) is refused with today's 403 (D3), no token, no cookie", %{priv: priv} do
      T.sso_origins!(["https://listed.example"])
      before = token_count()
      log = capture_log(fn -> send(self(), {:cb, T.legacy_callback_for_state!(priv, T.unique_sub(), "http://listed.example/cb")}) end)
      assert_received {:cb, cb}

      assert cb.status == 403
      assert T.json(cb)["errcode"] == "M_FORBIDDEN"
      assert T.json(cb)["error"] == "SSO login failed"
      assert T.location(cb) == nil
      assert T.sso_confirm_set_cookies(cb) == []
      assert token_count() == before
      assert log =~ "[warning]"
      refute log =~ "listed.example", "the WARNING is value-free"
    end

    test "the origin check asks for the NORMALIZED origin, only when sources 1 and 2 did not match", %{priv: priv} do
      trusted_spy!()
      T.sso_origins!(["https://listed.example"])
      assert_direct(callback(priv, "https://listed.example/cb"), "https://listed.example/cb")
      refute_received {:trusted_asked, _, _}

      T.assert_confirm_redirect(callback(priv, "HTTPS://Other.Example:443/cb"))
      assert_received {:trusted_asked, "https://other.example", "HTTPS://Other.Example:443/cb"}, "the check gets the NORMALIZED origin AND the raw redirect URL (SEC #1: approved clients match by registered URI)"
    end

    test "a trusted-origin check that says true makes the target direct (the OAuth auto sources)", %{priv: priv} do
      T.sso_trusted_check!(fn origin, raw_url -> origin == "https://approved-client.example" and String.starts_with?(raw_url, "https://approved-client.example/cb") end)
      assert_direct(callback(priv, "https://approved-client.example/cb"), "https://approved-client.example/cb")
      T.assert_confirm_redirect(callback(priv, "https://not-approved.example/cb"))
    end

    test "SEC #1: the check decides by the RAW URL: the same origin with another path is NOT trusted", %{priv: priv} do
      T.sso_trusted_check!(fn _origin, raw_url -> raw_url == "https://approved-client.example/cb" end)
      assert_direct(callback(priv, "https://approved-client.example/cb"), "https://approved-client.example/cb")
      T.assert_confirm_redirect(callback(priv, "https://approved-client.example/other"))
    end
  end

  describe "AC3.3 — no per-request I/O for the DB-free sources" do
    test "server name, the operator list, loopback and schemes never ask the trusted-origin check (even a raising one)", %{priv: priv} do
      me = self()
      T.sso_trusted_check!(fn origin, raw_url ->
        send(me, {:trusted_asked, origin, raw_url})
        raise "no DB for this source"
      end)
      T.put_env_scoped(:server_name, "chat.example.test")
      T.sso_origins!(["https://listed.example"])

      for url <- ["http://localhost:7070/#/home", "element://vector/webapp/", "https://chat.example.test/cb", "https://listed.example/cb"] do
        assert_direct(callback(priv, url), url)
      end

      refute_received {:trusted_asked, _, _}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — an unlisted https target: no token, a pending confirmation
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4.1 — the callback answers 303 to the confirmation page and mints nothing" do
    test "303, relative Location, binding cookie (http variant), flow headers, token count unchanged", %{priv: priv} do
      before = token_count()
      cb = callback(priv, @unlisted)
      T.assert_confirm_redirect(cb)
      assert token_count() == before, "no loginToken was minted"
      assert T.login_tokens_of(cb) == []
      refute T.location(cb) =~ "unlisted.example"
    end

    test "on an https request the cookie is `__Host-nebu_sso_confirm; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=300`", %{priv: priv} do
      cb = callback(priv, @unlisted, https: true)
      T.assert_confirm_redirect(cb, https: true)
      {name, _value, raw} = T.sso_confirm_cookie(cb)
      assert name == "__Host-nebu_sso_confirm"
      refute raw =~ ~r/domain=/i, "a __Host- cookie never carries Domain"
    end

    test "a second flow in the same browser overwrites the cookie (one pending confirmation per browser)", %{priv: priv} do
      first = callback(priv, "https://first.example/cb")
      second = callback(priv, "https://second.example/cb")
      {_, v1, _} = T.sso_confirm_cookie(first)
      {_, v2, _} = T.sso_confirm_cookie(second)
      refute v1 == v2
      assert T.confirm_entry(v1), "the first entry expires unused, it is not deleted by the second flow"
      assert T.confirm_entry(v2)
    end

    test "the logged-in user is only derived for display: no user provisioning happens before Continue", %{priv: priv} do
      sub = "no-provision-" <> T.rand(5)
      before = token_count()
      cb = callback(priv, @unlisted, sub: sub)
      T.assert_confirm_redirect(cb)
      assert token_count() == before

      # unit runs have no Repo: provisioning is only observable with a database
      if Process.whereis(Nebu.Repo) do
        assert {:ok, %{rows: [[0]]}} =
                 Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT count(*) FROM users WHERE user_id = $1", [T.sso_user_id(%{"sub" => sub})])
      end
    end
  end

  describe "AC4.2 — the pending entry and the consumed SSO state" do
    test "the entry (under SHA-256 of the cookie) holds the verified id_token, the IdP refresh token, the raw URL and the display fields", %{priv: priv} do
      sub = T.unique_sub()
      url = "https://Unlisted.Example:8443/cb/deep?app=1#/login"
      cb = callback(priv, url, sub: sub, idp_rt: "idp-rt-marker-123456")
      T.assert_confirm_redirect(cb)
      {_, value, _} = T.sso_confirm_cookie(cb)

      assert entry = T.confirm_entry(value), "no :confirm entry under sha256(cookie) (raw or hex)"
      assert length(String.split(entry.id_token, ".")) == 3, "the verified id_token (a JWT)"
      assert entry.oidc_refresh_token == "idp-rt-marker-123456"
      assert entry.redirect_url == url, "the RAW redirect url (the string that ends up in Location)"
      assert entry.origin == "https://unlisted.example:8443"
      assert entry.host == "unlisted.example"
      assert entry.port == 8443
      assert entry.path == "/cb/deep"
      assert entry.user_id == T.sso_user_id(%{"sub" => sub})
    end

    test "an IdP without a refresh token gives a nil refresh token; port 443 gives a nil port", %{priv: priv} do
      cb = callback(priv, "https://unlisted.example:443/cb", idp_rt: nil)
      {_, value, _} = T.sso_confirm_cookie(cb)
      entry = T.confirm_entry(value)
      assert entry.oidc_refresh_token == nil
      assert entry.port == nil
      assert entry.origin == "https://unlisted.example"
    end

    test "the cookie value itself and the bare id_token are never stored as the key", %{priv: priv} do
      cb = callback(priv, @unlisted)
      {_, value, _} = T.sso_confirm_cookie(cb)
      assert apply(SsoStore, :peek_confirm, [value]) == :error, "the key is a hash of the cookie, never the cookie"
    end

    test "the SSO state was consumed: a replay of the callback URL answers today's 400 M_UNKNOWN", %{priv: priv} do
      flow = T.sso_start!(@unlisted)
      first = T.sso_finish(flow, priv)
      T.assert_confirm_redirect(first)

      replay = T.sso_finish(flow, priv)
      assert replay.status == 400
      assert T.json(replay)["errcode"] == "M_UNKNOWN"
      assert T.json(replay)["error"] == "Invalid or expired SSO state"
      assert T.sso_confirm_set_cookies(replay) == []
    end

    test "a repeated redirectUrl parameter: the LAST value is the one that is confirmed (AC2.2)", %{priv: priv} do
      qs = "redirectUrl=" <> URI.encode_www_form("https://a.example/") <> "&redirectUrl=" <> URI.encode_www_form("https://b.example/")
      init = T.get("/_matrix/client/v3/login/sso/redirect?" <> qs)
      assert init.status == 302
      idp = T.idp_params(init)
      cb = T.sso_finish(%{state: idp["state"], nonce: idp["nonce"]}, priv)
      T.assert_confirm_redirect(cb)
      {_, value, _} = T.sso_confirm_cookie(cb)
      entry = T.confirm_entry(value)
      assert entry.host == "b.example"
      assert entry.redirect_url == "https://b.example/"
    end
  end

  describe "AC4.3 — the trusted-origin lookup fails closed" do
    test "a raising check => the confirmation page, never a token; sources 1 and 2 still work", %{priv: priv} do
      T.sso_trusted_check!(fn _origin, _raw_url -> raise "database exploded: secret-detail-123" end)
      T.sso_origins!(["https://listed.example"])
      before = token_count()

      log =
        capture_log(fn ->
          send(self(), {:cb, callback(priv, "https://unlisted.example/cb")})
          send(self(), {:listed, callback(priv, "https://listed.example/cb")})
        end)

      assert_received {:cb, cb}
      assert_received {:listed, listed}
      T.assert_confirm_redirect(cb)
      assert_direct(listed, "https://listed.example/cb")
      assert T.sso_new_tokens(before) == 1, "only the listed target minted a token"
      refute log =~ "secret-detail-123", "the exception message never reaches the log"
    end

    test "a check that returns a non-boolean or exits is treated as false", %{priv: priv} do
      T.sso_trusted_check!(fn _, _ -> :maybe end)
      T.assert_confirm_redirect(callback(priv, "https://unlisted.example/cb"))
      T.sso_trusted_check!(fn _, _ -> exit(:timeout) end)
      T.assert_confirm_redirect(callback(priv, "https://unlisted2.example/cb"))
    end
  end

  describe "AC4.4 — the confirm store is full" do
    test "10 000 live :confirm entries => the next unlisted callback answers the 503 unavailable page; no token, no cookie, WARNING", %{priv: priv} do
      fill = T.confirm_entry_fixture()
      for i <- 1..10_000, do: :ok = apply(SsoStore, :put_confirm, ["fill-key-#{i}", fill, 300])
      before = token_count()

      # the redirect leg is outside AC13 (its DEBUG line keeps the redirectUrl): start it BEFORE the capture
      flow = T.sso_start!(@unlisted)
      log = capture_log(fn -> send(self(), {:cb, T.sso_finish(flow, priv)}) end)
      T.drop_confirm_entries!()
      assert_received {:cb, cb}

      T.assert_confirm_error(cb, 503, "unavailable")
      assert T.sso_confirm_set_cookies(cb) == [], "no cookie"
      assert token_count() == before, "nothing minted"
      assert log =~ "[warning] matrix SSO: confirmation store full"
      refute log =~ "unlisted.example"
    end
  end

  describe "D10 — Continue when the loginToken store is full" do
    test "10 000 live loginTokens => the 503 unavailable page; the entry is CONSUMED, the cookie cleared, nothing is sent to the target", %{priv: priv} do
      cb = callback(priv, @unlisted)
      T.assert_confirm_redirect(cb)
      {_, value, _} = T.sso_confirm_cookie(cb)

      post =
        try do
          for i <- 1..10_000, do: :ok = SsoStore.put_login_token("full-token-#{i}", "id", 30)
          T.confirm!(cb, :continue)
        after
          T.drop_token_entries!()
        end

      T.assert_confirm_error(post, 503, "unavailable")
      assert T.location(post) == nil
      assert T.login_tokens_of(post) == []
      assert T.confirm_entry(value) == nil, "the entry was popped before minting and is never re-inserted"
      assert T.sso_confirm_cookie_cleared?(post)

      # the store has room again: a follow-up Continue still gives nothing (the sign-in has to be restarted)
      before = token_count()
      follow = T.confirm!({T.sso_confirm_cookie_name(), value}, :continue, get: false)
      T.assert_confirm_error(follow, 400, "invalid_state")
      assert token_count() == before
    end
  end

  describe "AC4.5 — IdP error, failed exchange and nonce mismatch keep today's answers" do
    test "an IdP authorization error: 403 M_FORBIDDEN, no entry, no cookie", %{priv: priv} do
      flow = T.sso_start!(@unlisted)
      before = T.sso_count(:confirm)

      conn =
        Plug.Test.conn(:get, "/_matrix/client/v3/login/sso/redirect/oidc?error=access_denied&state=" <> flow.state)
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 403
      assert T.json(conn)["error"] == "SSO provider rejected the authorization request"
      assert T.sso_confirm_set_cookies(conn) == []
      assert T.sso_count(:confirm) == before
      _ = priv
    end

    test "a failed code exchange: 403 M_FORBIDDEN `SSO login failed`", %{priv: _priv} do
      flow = T.sso_start!(@unlisted)
      T.stub_idp_exchange({:error, :token_endpoint_down})
      before = T.sso_count(:confirm)

      conn =
        Plug.Test.conn(:get, "/_matrix/client/v3/login/sso/redirect/oidc?code=c&state=" <> flow.state)
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 403
      assert T.json(conn)["error"] == "SSO login failed"
      assert T.sso_confirm_set_cookies(conn) == []
      assert T.sso_count(:confirm) == before
    end

    test "a nonce mismatch: 403 M_FORBIDDEN `SSO login failed`, no entry", %{priv: priv} do
      flow = T.sso_start!(@unlisted)
      before = T.sso_count(:confirm)
      conn = T.sso_finish(flow, priv, claims: %{"nonce" => "forged-nonce"})
      assert conn.status == 403
      assert T.json(conn)["error"] == "SSO login failed"
      assert T.sso_confirm_set_cookies(conn) == []
      assert T.sso_count(:confirm) == before
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — Continue
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7.1 — Continue answers 303 with the loginToken appended to the RAW redirect URL" do
    for {label, url} <- [
          {"no query, no fragment", "https://unlisted.example/cb"},
          {"with a query", "https://unlisted.example/cb?app=1"},
          {"with a fragment (the token goes before the #)", "https://unlisted.example/cb#/login"},
          {"with a query and a fragment", "https://unlisted.example/cb?app=1#/login"},
          {"an upper-case scheme and host (the RAW string is kept)", "HTTPS://Unlisted.Example/CB"},
          {"a pre-existing loginToken in the query (exactly one, the new one)", "https://unlisted.example/cb?loginToken=old&x=1"},
          {"a pre-existing loginToken in the fragment query", "https://unlisted.example/#/login?loginToken=old"},
          {"Element Web shape with @ and # in the fragment", "https://unlisted.example/#/user/@bob:ex.org"}
        ] do
      test "#{label}", %{priv: priv} do
        url = unquote(url)
        cb = callback(priv, url)
        T.assert_confirm_redirect(cb)
        post = T.confirm!(cb, :continue)
        token = T.assert_continue_redirect(post)
        assert T.location(post) == SsoLogin.append_login_token(url, token)
        assert T.login_tokens_of(post) == [token], "exactly one loginToken, the new one"
        refute T.location(post) =~ "loginToken=old"
        ttl = T.sso_token_ttl(token)
        assert is_integer(ttl) and ttl in 25..30, "a 30 s loginToken, remaining lifetime: #{inspect(ttl)}"
      end
    end

    test "Continue is also valid without any fetch-metadata / Origin header (old browsers, lenient level)", %{priv: priv} do
      cb = callback(priv, @unlisted)

      post =
        T.confirm!(cb, :continue,
          headers: [{"origin", nil}, {"sec-fetch-site", nil}, {"sec-fetch-mode", nil}, {"sec-fetch-dest", nil}, {"sec-fetch-user", nil}]
        )

      T.assert_continue_redirect(post)
    end

    test "Continue on an https request (the __Host- cookie)", %{priv: priv} do
      cb = callback(priv, @unlisted, https: true)
      T.assert_confirm_redirect(cb, https: true)
      post = T.confirm!(cb, :continue, https: true)
      T.assert_continue_redirect(post)
    end

    test "the Continue 303 never reveals the confirm URL to the target: Referrer-Policy no-referrer", %{priv: priv} do
      post = callback(priv, @unlisted) |> T.confirm!(:continue)
      assert T.header(post, "referrer-policy") == "no-referrer"
      assert T.header(post, "location") =~ "https://unlisted.example/cb"
    end
  end

  describe "AC7.3 — the entry is single use, the cookie is cleared" do
    test "after Continue the entry is gone, the cookie cleared, a replay gives 400 invalid_state and mints nothing", %{priv: priv} do
      cb = callback(priv, @unlisted)
      {_, value, _} = T.sso_confirm_cookie(cb)
      post = T.confirm!(cb, :continue)
      T.assert_continue_redirect(post)
      assert T.sso_confirm_cookie_cleared?(post), "the cookie is cleared on Continue"
      assert T.confirm_entry(value) == nil, "the pending entry is consumed"

      before = token_count()
      replay = T.confirm!({T.sso_confirm_cookie_name(), value}, :continue, get: false)
      T.assert_confirm_error(replay, 400, "invalid_state")
      assert token_count() == before, "a replay mints no token"
      assert T.sso_confirm_cookie_cleared?(replay), "the definite invalid_state clears the cookie"
    end

    test "Continue twice with the same cookie mints exactly one token (the entry is popped BEFORE minting)", %{priv: priv} do
      cb = callback(priv, @unlisted)
      {_, value, _} = T.sso_confirm_cookie(cb)
      before = token_count()
      _ = T.confirm!(cb, :continue)
      _ = T.confirm!({T.sso_confirm_cookie_name(), value}, :continue, get: false)
      assert T.sso_new_tokens(before) == 1
    end
  end

  describe "AC7.4 / AC8 — INFO lines carry the host only" do
    test "Continue logs `redirect confirmation confirmed host=<host>`, the callback logs `shown host=<host>`", %{priv: priv} do
      url = "https://Logs.Unlisted.Example:8443/secret-path?secret=q#frag-secret"

      flow = T.sso_start!(url)

      log =
        capture_log(fn ->
          cb = T.sso_finish(flow, priv)
          send(self(), {:token, T.confirm!(cb, :continue) |> T.assert_continue_redirect()})
        end)

      assert_received {:token, token}
      assert log =~ "[info] matrix SSO: redirect confirmation shown host=logs.unlisted.example:8443"
      assert log =~ "[info] matrix SSO: redirect confirmation confirmed host=logs.unlisted.example:8443"
      for secret <- ["secret-path", "secret=q", "frag-secret", token], do: refute(log =~ secret, "#{secret} leaked into the log")
    end

    test "a default-port host is logged without :port", %{priv: priv} do
      flow = T.sso_start!("https://plain.unlisted.example:443/cb")
      log = capture_log(fn -> T.sso_finish(flow, priv) |> T.confirm!(:continue) end)
      assert log =~ "redirect confirmation confirmed host=plain.unlisted.example\n" or log =~ ~r/confirmed host=plain\.unlisted\.example(\s|\z)/
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — Cancel
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8 — Cancel" do
    test "200 cancelled page, the entry gone, the cookie cleared, no token minted; a following Continue is invalid_state", %{priv: priv} do
      cb = callback(priv, @unlisted)
      {_, value, _} = T.sso_confirm_cookie(cb)
      before = token_count()

      post = T.confirm!(cb, :cancel)
      assert post.status == 200
      assert post.resp_body =~ ~r/<main[^>]*data-page="sso-confirm"/
      assert post.resp_body =~ ~s(data-result="cancelled")
      assert post.resp_body =~ ~r/<h1[^>]*>\s*Sign-in cancelled\s*<\/h1>/
      assert post.resp_body =~ "No access was given. You can close this window."
      assert T.location(post) == nil
      assert T.login_tokens_of(post) == []
      assert token_count() == before
      assert T.confirm_entry(value) == nil
      assert T.sso_confirm_cookie_cleared?(post)

      follow = T.confirm!({T.sso_confirm_cookie_name(), value}, :continue, get: false)
      T.assert_confirm_error(follow, 400, "invalid_state")
      assert token_count() == before
    end

    test "the INFO line `declined host=<host>` carries the host only", %{priv: priv} do
      flow = T.sso_start!("https://declined.example/secret-path?q=1")
      log = capture_log(fn -> T.sso_finish(flow, priv) |> T.confirm!(:cancel) end)
      assert log =~ "[info] matrix SSO: redirect confirmation declined host=declined.example"
      refute log =~ "secret-path"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.1 / AC10.2 — lifetime and concurrency
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10.1 — an entry older than 300 s is invalid_state on GET and POST" do
    test "an already expired entry (ttl -1): GET and POST answer 400 invalid_state, the cookie is cleared" do
      value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      T.put_confirm_both!(value, T.confirm_entry_fixture(), -1)
      pair = {T.sso_confirm_cookie_name(), value}

      get = T.sso_confirm_get(pair)
      T.assert_confirm_error(get, 400, "invalid_state")
      assert T.sso_confirm_cookie_cleared?(get)

      post = T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "continue"}], cookie: pair)
      T.assert_confirm_error(post, 400, "invalid_state")
    end
  end

  describe "AC10.2 — concurrent Continue POSTs of the same browser" do
    test "12 concurrent POSTs: exactly one 303 with a loginToken, the rest 400 invalid_state, exactly one token minted", %{priv: priv} do
      cb = callback(priv, @unlisted)
      {_name, value, _} = T.sso_confirm_cookie(cb)
      pair = {T.sso_confirm_cookie_name(), value}
      before = token_count()

      results =
        1..12
        |> Task.async_stream(
          fn _ -> T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "continue"}], cookie: pair) end,
          max_concurrency: 12,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, conn} -> conn end)

      assert Enum.count(results, &(&1.status == 303)) == 1
      assert Enum.count(results, &(&1.status == 400)) == 11
      assert Enum.all?(results, &(&1.status in [303, 400]))
      winner = Enum.find(results, &(&1.status == 303))
      assert [_token] = T.login_tokens_of(winner)
      assert T.sso_new_tokens(before) == 1, "exactly one loginToken minted"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7.2 / AC16.3 — redeeming the token (needs the DB)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7.2 — the loginToken minted by Continue redeems once at POST /login" do
    @describetag :integration

    test "200 with the user id of the page, a 30 s opaque token, a replay answers 403 M_FORBIDDEN", %{priv: priv} do
      sub = T.unique_sub()
      cb = callback(priv, @unlisted, sub: sub)
      T.assert_confirm_redirect(cb)

      page = T.sso_confirm_get(cb)
      [_, shown] = Regex.run(~r/data-role="user-id"[^>]*>([^<]+)</, page.resp_body)
      post = T.confirm!(cb, :continue)
      token = T.assert_continue_redirect(post)

      login = T.sso_token_login(token)
      assert login.status == 200, "got #{login.status} #{login.resp_body}"
      body = T.json(login)
      assert body["user_id"] == T.sso_user_id(%{"sub" => sub})
      assert shown == body["user_id"], "the page names the very user the token logs in"
      assert is_binary(body["access_token"]) and is_binary(body["device_id"])

      replay = T.sso_token_login(token)
      assert replay.status == 403
      assert T.json(replay)["errcode"] == "M_FORBIDDEN"
    end

    test "with an IdP refresh token captured and refresh_token: true the opaque-session path works as today", %{priv: priv} do
      cb = callback(priv, @unlisted, idp_rt: "idp-rt-" <> T.rand(10))
      token = T.confirm!(cb, :continue) |> T.assert_continue_redirect()
      login = T.sso_token_login(token, refresh_token: true)
      assert login.status == 200, "got #{login.status} #{login.resp_body}"
      body = T.json(login)
      assert body["access_token"] =~ ~r/\A[0-9a-f]{64}\z/, "an opaque access token"
      assert body["refresh_token"] =~ ~r/\A[0-9a-f]{64}\z/, "an opaque refresh token"
      assert is_integer(body["expires_in_ms"]) and body["expires_in_ms"] > 0
    end

    test "without a captured IdP refresh token the JWT fallback applies (no refresh_token), as today", %{priv: priv} do
      cb = callback(priv, @unlisted, idp_rt: nil)
      token = T.confirm!(cb, :continue) |> T.assert_continue_redirect()
      login = T.sso_token_login(token, refresh_token: true)
      assert login.status == 200
      refute Map.has_key?(T.json(login), "refresh_token")
    end

    test "a listed target's token redeems the same way (AC3.1: the loginToken redeems via POST /login)", %{priv: priv} do
      T.sso_origins!(["https://listed.example"])
      sub = T.unique_sub()
      cb = callback(priv, "https://listed.example/cb", sub: sub)
      [token] = T.login_tokens_of(cb)
      login = T.sso_token_login(token)
      assert login.status == 200
      assert T.json(login)["user_id"] == T.sso_user_id(%{"sub" => sub})
    end
  end

  describe "AC16.3 (oracle m6) — replayed, expired and forged loginTokens answer 403 M_FORBIDDEN and create nothing" do
    @describetag :integration

    test "replay, expired (short TTL) and forged / unknown tokens: 403 M_FORBIDDEN, no session, no device", %{priv: priv} do
      cb = callback(priv, @unlisted)
      token = T.confirm!(cb, :continue) |> T.assert_continue_redirect()
      assert T.sso_token_login(token).status == 200

      expired = "expired-token-" <> T.rand(8)
      SsoStore.put_login_token(expired, "not-a-jwt", -1)

      counts = fn ->
        %{rows: [[s]]} = T.sql!("SELECT count(*) FROM matrix_sessions")
        %{rows: [[d]]} = T.sql!("SELECT count(*) FROM devices")
        {s, d}
      end

      before = counts.()

      for bad <- [token, expired, String.duplicate("ab", 32), "forged", String.duplicate("0", 64)] do
        conn = T.sso_token_login(bad)
        assert conn.status == 403, "token #{String.slice(bad, 0, 10)}: got #{conn.status}"
        assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      end

      assert counts.() == before, "a refused loginToken creates no session and no device"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC16.1 — the UIA fallback is untouched
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC16.1 — the UIA m.login.sso fallback completes through the callback exactly as before" do
    @describetag :integration

    test "no confirmation, no cookie, no loginToken, the completion page, also when uia.local is not listed", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      sid = T.uia_session!(uid)
      T.sso_origins!(["https://elsewhere.example"])

      init = T.get("/_matrix/client/v3/auth/m.login.sso/fallback/web?session=" <> URI.encode_www_form(sid))
      assert init.status == 302
      idp = T.idp_params(init)
      before = token_count()

      cb = T.sso_finish(%{state: idp["state"], nonce: idp["nonce"]}, priv, sub: sub)
      assert cb.status == 200
      assert cb.resp_body =~ "Authentication complete"
      assert T.sso_confirm_set_cookies(cb) == []
      assert T.location(cb) == nil
      assert token_count() == before
      assert [[^sid, true, _]] = Enum.filter(T.uia_rows(uid), fn [s, _, _] -> s == sid end)
    end

    test "a CLIENT-supplied redirectUrl=https://uia.local/complete is an ordinary unlisted https target (confirmation)", %{priv: priv} do
      cb = callback(priv, "https://uia.local/complete")
      T.assert_confirm_redirect(cb)
    end
  end
end
