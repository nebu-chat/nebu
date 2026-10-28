defmodule Nebu.OAuth.OAuthConsentFlowTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3): the consent step between the
  verified IdP login and the Nebu authorization code. AC1 (no code without consent), AC2.2 (stored
  `auth_time` = the raw claim or NULL), AC5 (Allow), AC6 (Deny), AC8 (lifetime, cap, purge,
  concurrency), AC9 (device takeover), AC15 (kill switch, rate limit, routing).

  Full in-process flow: authorize (302 to the IdP stub) -> IdP callback (`303 /oauth2/consent` + the
  consent cookie) -> `GET /oauth2/consent` -> `POST /oauth2/consent` (CSRF token from the page, the
  fetch-metadata headers of a top-level form submit) -> `303` to the client with the code.

  Also covers the review-cycle-1 items: per-user / per-source live caps (L-2), the device-holder re-check when
  the code is redeemed (L-1) and the consent cookie surviving a storage error (INFO1).

  Cluster safety: the single-use consumption of a consent row is ONE atomic `DELETE ... RETURNING`
  (proven with N parallel Allows: exactly one code). No sleeps.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @website "https://app.example.com"
  @https "https://app.example.com/cb"
  @https_query "https://app.example.com/cb?tenant=1"
  @private "com.example.app:/oauth2/callback"
  @loop_uris ["http://localhost/cb", "http://127.0.0.1/cb", "http://[::1]/cb"]

  @lib Path.expand("../../../lib/nebu", __DIR__)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    cid = T.oauth_client!([@https, @https_query, @private | @loop_uris], client_name: "Flow Test App", client_uri: @website)
    {:ok, priv: priv, cid: cid}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp cookie_cleared?(conn, name \\ nil) do
    names = if name, do: [name], else: [T.consent_cookie_name(false), T.consent_cookie_name(true)]
    Enum.any?(T.set_cookies(conn), fn c -> Enum.any?(names, &String.starts_with?(c, &1 <> "=")) and c =~ ~r/max-age=0(;|\z)/i end)
  end

  defp consent_count(cid), do: T.count_for("oauth_consent_requests", cid)
  defp code_count(cid), do: T.count_for("oauth_codes", cid)

  defp authz_count(state) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_authz_requests WHERE state_hash = $1", [T.sha256_hex(state)])
    n
  end

  # authorize -> IdP stub -> callback; returns the flow, the callback conn and the PKCE verifier
  defp to_consent(cid, redirect, overrides, priv, opts \\ []) do
    {verifier, challenge} = T.pkce_pair()
    overrides = Map.merge(%{"code_challenge" => challenge}, overrides)
    flow = T.start_flow(cid, redirect, overrides)
    sub = Keyword.get(opts, :sub, T.unique_sub())
    claims = opts |> Keyword.get(:claims, %{}) |> Map.put("sub", sub)
    rest = opts |> Keyword.drop([:sub, :claims]) |> Keyword.put_new(:idp_rt, "idp-rt-" <> T.rand(8))
    cb = T.finish_flow(flow, priv, [claims: claims] ++ rest)
    %{flow: flow, cb: cb, verifier: verifier, sub: sub, user_id: T.user_id_for(%{"sub" => sub}), redirect: redirect, cid: cid}
  end

  defp grant(ctx, params) do
    %{
      code: params["code"],
      verifier: ctx.verifier,
      challenge: nil,
      client_id: ctx.cid,
      redirect_uri: ctx.redirect,
      user_id: ctx.user_id,
      device_id: T.scope_device(T.param(ctx.flow.pairs, "scope")),
      scope: T.param(ctx.flow.pairs, "scope")
    }
  end

  defp issuer, do: T.get_metadata() |> T.json() |> Map.fetch!("issuer")

  defp code_row(code) do
    case T.sql!("SELECT *, extract(epoch FROM auth_time)::bigint AS auth_time_s FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(code)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — no code without consent
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1.1 — every successful callback answers 303 /oauth2/consent" do
    for {label, claims, fresh?} <- [
          {"fresh auth_time", :fresh, true},
          {"stale auth_time", :stale, false},
          {"absent auth_time", :absent, false}
        ] do
      test "#{label}: a consent row, a cookie, NO code, NO client redirect", %{cid: cid, priv: priv} do
        claims =
          case unquote(claims) do
            :fresh -> %{"auth_time" => System.system_time(:second)}
            :stale -> %{"auth_time" => System.system_time(:second) - 3600}
            :absent -> %{}
          end

        c = to_consent(cid, @https, %{}, priv, claims: Map.merge(%{"sub" => T.unique_sub()}, claims))
        T.assert_consent_redirect(c.cb)

        assert code_count(cid) == 0, "no oauth_codes row before the user's decision"
        assert consent_count(cid) == 1
        assert authz_count(c.flow.state) == 0, "the authorization request is consumed at the callback"
        refute T.location(c.cb) =~ "code="
        refute T.location(c.cb) =~ "state="
        refute T.location(c.cb) =~ "iss="
        refute T.location(c.cb) =~ "app.example.com", "the browser is NOT sent to the client yet"

        row = T.consent_row_of(c.cb)
        assert row["client_id"] == cid
        assert row["user_id"] == c.user_id
        assert row["login_fresh"] == unquote(fresh?), "login_fresh is the freshness verdict (FR3/FR6)"
        assert row["redirect_uri"] == @https
        assert row["code_challenge"] == T.param(c.flow.pairs, "code_challenge")
        assert row["device_id"] == "AbCdEfGhIj"
        assert row["scope"] == "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj"
        assert row["response_mode"] == "fragment"
        refute row["idp_rt_enc"] == nil
        assert {:ok, _} = Nebu.Web.SecretBox.decrypt(row["idp_rt_enc"]), "the IdP refresh token is stored SecretBox-encrypted only"
        refute row["binding_hash"] =~ c.flow.state
      end
    end

    test "the consent cookie: 256-bit value, HttpOnly, SameSite=Lax (Strict would not be sent after the IdP's cross-site chain), Max-Age 300, http name + path", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      {name, value, raw} = T.consent_cookie(c.cb)
      assert name == "nebu_oauth_consent"
      assert value =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert raw =~ ~r/HttpOnly/i
      assert raw =~ ~r/SameSite=Lax/i
      refute raw =~ ~r/SameSite=Strict/i
      assert raw =~ ~r/max-age=300/i
      assert raw =~ ~r/path=\/oauth2\/consent/i
      refute raw =~ ~r/secure/i, "plain-http request: no Secure"
      assert T.consent_row(value), "the row is keyed by sha256(cookie value)"
      refute T.consent_row_of(c.cb)["binding_hash"] == value, "the cookie value itself is never stored"
    end

    test "https request: __Host- cookie with Path=/ and Secure", %{cid: cid, priv: priv} do
      # story oauth-hardening-hygiene HY9: the flow's binding cookie is `__Host-nebu_oa_<16 hex>` on https and the
      # callback reads only the name of ITS scheme, so the authorize leg must be https as well (it was plain http here)
      flow = T.start_flow(cid, @https, %{}, headers: [{"x-forwarded-proto", "https"}])
      assert elem(flow.cookie, 0) =~ ~r/\A__Host-nebu_oa_[0-9a-f]{16}\z/
      stub = T.sign_id_token(priv, %{"sub" => T.unique_sub(), "nonce" => flow.nonce})
      T.stub_idp_exchange({:ok, stub, "idp-rt-" <> T.rand(8)})

      conn =
        Plug.Test.conn(:get, T.callback_path() <> "?" <> URI.encode_query(%{"code" => "c", "state" => flow.state}))
        |> Plug.Conn.put_req_header("cookie", "#{elem(flow.cookie, 0)}=#{elem(flow.cookie, 1)}")
        |> Map.merge(%{scheme: :https, port: 443, remote_ip: T.unique_ip()})
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 303
      {name, _value, raw} = T.consent_cookie(conn)
      assert name == "__Host-nebu_oauth_consent"
      assert raw =~ ~r/path=\/(;|\z)/i
      assert raw =~ ~r/secure/i
      assert raw =~ ~r/HttpOnly/i
    end

    test "two flows (two tabs): each cookie value decides ITS row only", %{cid: cid, priv: priv} do
      a = to_consent(cid, @https, %{}, priv)
      b = to_consent(cid, @https, %{}, priv)
      assert consent_count(cid) == 2
      {_, va, _} = T.consent_cookie(a.cb)
      {_, vb, _} = T.consent_cookie(b.cb)
      refute va == vb

      T.consent!(b.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(b.flow.pairs, "state"), issuer())
      assert consent_count(cid) == 1, "only b's row was consumed"
      assert T.consent_row(va), "a's row is still there"
      T.consent!(a.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(a.flow.pairs, "state"), issuer())
    end
  end

  describe "AC1.2 — static: CodeStore.insert is called only from the consent module" do
    test "lib/nebu/oauth/consent.ex exists and is the ONLY caller" do
      assert File.exists?(Path.join(@lib, "oauth/consent.ex")), "Nebu.OAuth.Consent (lib/nebu/oauth/consent.ex) missing"

      callers =
        Path.wildcard(Path.join(@lib, "**/*.ex"))
        |> Enum.filter(fn f -> File.read!(f) |> String.replace(~r/#[^\n]*/, "") |> String.match?(~r/CodeStore\.insert\b/) end)
        |> Enum.map(&Path.relative_to(&1, @lib))

      assert callers == ["oauth/consent.ex"], "CodeStore.insert must only be reachable after the user's Allow, got #{inspect(callers)}"
    end

    test "authorize.ex no longer mints codes (no CodeStore alias use)" do
      src = File.read!(Path.join(@lib, "oauth/authorize.ex")) |> String.replace(~r/#[^\n]*/, "")
      refute src =~ ~r/CodeStore\.insert/
    end

    test "no raw `INSERT INTO oauth_codes` (or an alias of CodeStore) outside oauth/code_store.ex either" do
      offenders =
        Path.wildcard(Path.join(@lib, "**/*.ex"))
        |> Enum.filter(fn f -> File.read!(f) |> String.replace(~r/#[^\n]*/, "") |> String.match?(~r/INSERT\s+INTO\s+oauth_codes/i) end)
        |> Enum.map(&Path.relative_to(&1, @lib))

      assert offenders == ["oauth/code_store.ex"], "only CodeStore writes oauth_codes, got #{inspect(offenders)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — consent-bypass negatives (test review MINOR 4)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — nothing before the user's Allow can be turned into a code or a session" do
    test "the IdP code, the IdP state, the consent cookie and the consent csrf token are all refused at POST /oauth2/token before Allow", %{cid: cid, priv: priv} do
      idp_code = "idp-code-" <> T.rand()
      c = to_consent(cid, @https, %{}, priv, code: idp_code)
      T.assert_consent_redirect(c.cb)
      {_name, cookie_value, _raw} = T.consent_cookie(c.cb)

      for {label, code} <- [{"IdP code", idp_code}, {"IdP state", c.flow.state}, {"consent cookie", cookie_value}, {"consent csrf", T.consent_csrf(cookie_value)}] do
        T.redeem(%{code: code, verifier: c.verifier, client_id: cid, redirect_uri: @https}) |> T.assert_token_error(400, "invalid_grant")
        assert T.session_rows(c.user_id, "AbCdEfGhIj") == [], "#{label}: no session"
      end

      assert code_count(cid) == 0
      assert T.consent_row(cookie_value), "the consent row is untouched by the token attempts"
    end

    test "GET /oauth2/consent?decision=allow&csrf_token=... mints nothing (a GET never decides)", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      {_n, value, _} = T.consent_cookie(c.cb)
      query = "?" <> URI.encode_query(%{"decision" => "allow", "csrf_token" => T.consent_csrf(value)})

      get = T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end), query: query)
      assert get.status == 200
      assert get.resp_body =~ ~s(data-page="oauth-consent"), "the page is simply rendered again"
      assert code_count(cid) == 0
      assert T.consent_row(value), "nothing consumed"
    end

    test "a Deny cannot be 'undone': a later Allow with the same cookie is invalid_state and mints nothing", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      T.consent!(c.cb, :deny) |> T.assert_deny_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      T.consent!(c.cb, :allow, get: false) |> T.assert_page(400, "invalid_state")
      assert code_count(cid) == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2.2 — stored auth_time: the raw claim or NULL
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2.2 / FR4 — the stored auth_time is the raw claim or NULL, never iat, never the consent time" do
    test "a claim: consent row, code row, matrix_sessions and the id_token all carry it", %{cid: cid, priv: priv} do
      at = System.system_time(:second) - 30
      nonce = "n-" <> T.rand()

      c = to_consent(cid, @https, %{"scope" => T.js_sdk_scope(), "nonce" => nonce, "response_mode" => "query"}, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => at})
      assert %{rows: [[^at]]} = T.sql!("SELECT extract(epoch FROM auth_time)::bigint FROM oauth_consent_requests WHERE binding_hash = $1", [T.sha256_hex(elem(T.consent_cookie(c.cb), 1))])

      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "query", T.param(c.flow.pairs, "state"), issuer())
      assert code_row(params["code"])["auth_time_s"] == at

      body = T.redeem!(grant(c, params))
      assert T.row_by_at(body["access_token"])["auth_time"] == at
      {_h, claims} = T.verify_id_token!(body["id_token"])
      assert claims["auth_time"] == at
      assert claims["nonce"] == nonce
    end

    test "NO claim (the id_token has `iat` only): NULL everywhere; the id_token has NO auth_time member", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{"scope" => T.js_sdk_scope(), "nonce" => "n-" <> T.rand(), "response_mode" => "query"}, priv)
      row = T.consent_row_of(c.cb)
      assert row["auth_time"] == nil
      assert row["login_fresh"] == false

      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "query", T.param(c.flow.pairs, "state"), issuer())
      assert code_row(params["code"])["auth_time"] == nil, "never iat, never the consent time"

      body = T.redeem!(grant(c, params))
      assert T.row_by_at(body["access_token"])["auth_time"] == nil
      {_h, claims} = T.verify_id_token!(body["id_token"])
      refute Map.has_key?(claims, "auth_time"), "an absent auth_time is omitted, not invented"
    end

    test "a STALE claim is stored as is (raw), but the login is not 'fresh'", %{cid: cid, priv: priv} do
      stale = System.system_time(:second) - 7200
      c = to_consent(cid, @https, %{}, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => stale})
      row = T.consent_row_of(c.cb)
      assert row["login_fresh"] == false
      assert %{rows: [[^stale]]} = T.sql!("SELECT extract(epoch FROM auth_time)::bigint FROM oauth_consent_requests WHERE binding_hash = $1", [row["binding_hash"]])
    end

    test "a future claim is clamped to now", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => System.system_time(:second) + 7200})
      %{rows: [[stored]]} = T.sql!("SELECT extract(epoch FROM auth_time)::bigint FROM oauth_consent_requests WHERE binding_hash = $1", [T.consent_row_of(c.cb)["binding_hash"]])
      assert stored <= System.system_time(:second)
      assert T.consent_row_of(c.cb)["login_fresh"] == true
    end

    test "login_fresh follows the 60 s skew against the REQUEST time: auth_time = request - 59 s is fresh", %{cid: cid, priv: priv} do
      # the authorization request is created "now"; an IdP session older than the request by < 60 s still counts
      c = to_consent(cid, @https, %{}, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => System.system_time(:second) - 59})
      assert T.consent_row_of(c.cb)["login_fresh"] == true
      c2 = to_consent(cid, @https, %{}, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => System.system_time(:second) - 3600})
      assert T.consent_row_of(c2.cb)["login_fresh"] == false
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — Allow
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.1 — Allow: 303 with code, state, iss in the row's response mode; the code redeems" do
    for {label, redirect, mode, extra} <- [
          {"https (default fragment)", @https, "fragment", %{}},
          {"https with a registered query (&code=)", @https_query, "query", %{"response_mode" => "query"}},
          {"https with a registered query, fragment mode", @https_query, "fragment", %{"response_mode" => "fragment"}},
          {"private-use scheme", @private, "query", %{}},
          {"127.0.0.1 with a port", "http://127.0.0.1:53682/cb", "query", %{}},
          {"localhost with a port", "http://localhost:53682/cb", "query", %{}},
          {"[::1] with a port", "http://[::1]:53682/cb", "query", %{}}
        ] do
      test "#{label}", %{cid: cid, priv: priv} do
        nonce = "n-" <> T.rand()
        overrides = Map.merge(%{"scope" => T.js_sdk_scope(), "nonce" => nonce}, unquote(Macro.escape(extra)))
        c = to_consent(cid, unquote(redirect), overrides, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => System.system_time(:second)})

        allow = T.consent!(c.cb, :allow)
        params = T.assert_allow_redirect(allow, unquote(redirect), unquote(mode), T.param(c.flow.pairs, "state"), issuer())

        if unquote(mode) == "query" and unquote(redirect) =~ "?" do
          assert T.location(allow) =~ "?tenant=1&code=", "a registered query is kept and the parameters are appended with &"
        end

        body = T.redeem!(grant(c, params))
        {_h, claims} = T.verify_id_token!(body["id_token"])
        assert claims["nonce"] == nonce, "the client nonce reaches the id_token (story-3 flow)"
        assert claims["iss"] == issuer()
      end
    end

    test "no client state => no state parameter; iss is byte-equal to the metadata issuer (trailing-slash config)", %{cid: cid, priv: priv} do
      T.enable_oauth("https://nebu.example.com/")
      c = to_consent(cid, @https, %{"state" => nil}, priv)
      T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", nil, "https://nebu.example.com")
    end

    test "AC5.1 the session is bound to the user and device of the consent row", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      row = code_row(params["code"])
      assert row["user_id"] == c.user_id
      assert row["client_id"] == cid
      assert row["device_id"] == "AbCdEfGhIj"
      assert row["redirect_uri"] == @https
      assert row["used_at"] == nil
      assert {:ok, _} = Nebu.Web.SecretBox.decrypt(row["idp_rt_enc"])
    end
  end

  describe "AC5.2 — single use" do
    test "the row is gone, the cookie cleared; a repeated POST is 400 invalid_state and issues no second code", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      {name, value, _} = T.consent_cookie(c.cb)

      allow = T.consent!(c.cb, :allow)
      T.assert_allow_redirect(allow, @https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      assert cookie_cleared?(allow, name), "the consent cookie is deleted (Max-Age=0) on the decision"
      assert T.consent_row(value) == nil
      assert code_count(cid) == 1

      again = T.consent!(c.cb, :allow, get: false)
      T.assert_page(again, 400, "invalid_state")
      assert again.resp_body =~ ~r/close this window/i, "correction 11: tell the user to close the window"
      assert again.resp_body =~ ~r/start signing in again from your app/i
      assert code_count(cid) == 1, "no second code"
      assert T.consent_get(c.cb).status == 400, "a reload after the decision is invalid_state too"
    end

    test "N parallel Allows: exactly one code, all others invalid_state (atomic consume, cluster safe)", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> T.consent!(pair, :allow, get: false) end) end)
        |> Task.await_many(30_000)

      {ok, rest} = Enum.split_with(results, &(&1.status == 303))
      assert length(ok) == 1, "exactly one winner, got #{inspect(Enum.map(results, & &1.status))}"
      for conn <- rest, do: T.assert_page(conn, 400, "invalid_state")
      assert code_count(cid) == 1
    end
  end

  describe "AC5.3 — the client is no longer approved at Allow" do
    test "403 client_rejected page, no code, no redirect (a P4 'revoked' counts as rejected)", %{priv: priv} do
      cid = T.oauth_client!([@https], client_uri: @website)
      c = to_consent(cid, @https, %{}, priv)
      T.assert_consent_redirect(c.cb)
      :ok = T.reject_approved_client!(cid)

      conn = T.consent!(c.cb, :allow, get: false)
      T.assert_page(conn, 403, "client_rejected")
      assert code_count(cid) == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — Deny
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6 — Deny: 303 access_denied with a fixed ASCII description, state, iss; nothing issued" do
    for {label, redirect, mode, extra} <- [
          {"https fragment", @https, "fragment", %{}},
          {"https query", @https, "query", %{"response_mode" => "query"}},
          {"registered URI with a query, query mode", @https_query, "query", %{"response_mode" => "query"}},
          {"registered URI with a query, fragment mode", @https_query, "fragment", %{"response_mode" => "fragment"}},
          {"loopback", "http://localhost:53682/cb", "query", %{}},
          {"private-use scheme", @private, "query", %{}}
        ] do
      test "#{label}", %{cid: cid, priv: priv} do
        c = to_consent(cid, unquote(redirect), unquote(Macro.escape(extra)), priv)
        {_n, value, _} = T.consent_cookie(c.cb)
        deny = T.consent!(c.cb, :deny)
        params = T.assert_deny_redirect(deny, unquote(redirect), unquote(mode), T.param(c.flow.pairs, "state"), issuer())
        assert params["error_description"] =~ ~r/\A[\x20-\x7E]+\z/
        refute String.contains?(params["error_description"], ["\"", "\\"])

        if unquote(mode) == "query" and unquote(redirect) =~ "?" do
          assert T.location(deny) =~ "?tenant=1&error=", "the registered query is kept"
        end

        assert code_count(c.cid) == 0
        assert T.consent_row(value) == nil, "the row is consumed by the decision"
        assert T.session_rows(c.user_id, "AbCdEfGhIj") == [], "no session"
        assert cookie_cleared?(deny)
      end
    end

    test "Deny without client state: no state parameter", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{"state" => nil}, priv)
      T.consent!(c.cb, :deny) |> T.assert_deny_redirect(@https, "fragment", nil, issuer())
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — lifetime, cap, purge
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8 — lifetime of a consent row" do
    test "a row older than 5 minutes: invalid_state on GET and on POST (POST consumes it), never a code", %{cid: cid} do
      uid = T.provision_user!()
      row = T.insert_consent!(cid, user_id: uid, created_sql: "now() - interval '6 minutes'", expires_sql: "now() - interval '1 minute'")

      T.consent_get(row.cookie) |> T.assert_page(400, "invalid_state")
      assert T.consent_row(row.value), "a GET never consumes"

      T.consent!(row.cookie, :allow, get: false) |> T.assert_page(400, "invalid_state")
      assert T.consent_row(row.value) == nil
      assert code_count(cid) == 0
    end

    test "an unknown / garbage cookie value: invalid_state; no cookie at all: invalid_state", %{cid: cid} do
      T.consent_get({"nebu_oauth_consent", Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}) |> T.assert_page(400, "invalid_state")
      T.consent_get({"nebu_oauth_consent", "x"}) |> T.assert_page(400, "invalid_state")
      assert code_count(cid) == 0
    end
  end

  describe "AC8 — soft cap of 10 000 live consent rows" do
    test "at the cap the callback answers a temporarily_unavailable error redirect; nothing is persisted", %{cid: cid, priv: priv} do
      T.sql!(
        "INSERT INTO oauth_consent_requests (binding_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
          "response_mode, openid_requested, login_fresh, created_at, expires_at) " <>
          "SELECT lpad(to_hex(g), 64, '0'), $1, 'https://app.example.com/cb', 'c', 'D', '@cap:test.local', 's', 'urn:matrix:client:', 'query', false, true, " <>
          "now(), now() + interval '300 seconds' FROM generate_series(1, 10000) g",
        [cid]
      )

      on_exit(fn -> T.sql!("DELETE FROM oauth_consent_requests WHERE client_id = $1", [cid]) end)

      flow = T.start_flow(cid, @https)
      conn = T.finish_flow(flow, priv)
      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))
      assert code_count(cid) == 0
      assert T.consent_set_cookies(conn) == [] or Enum.all?(T.consent_set_cookies(conn), &(&1 =~ ~r/max-age=0/i)), "no live consent cookie"
    end
  end

  describe "L-2 — per-user and per-source live caps (security review cycle 1)" do
    test "a user with 5 live consent rows gets temporarily_unavailable at the callback; another user is unaffected", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      for _ <- 1..5, do: T.insert_consent!(cid, user_id: uid)

      flow = T.start_flow(cid, @https)
      conn = T.finish_flow(flow, priv, claims: %{"sub" => sub})
      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))
      assert consent_count(cid) == 5, "nothing was added"
      assert T.consent_set_cookies(conn) == [] or Enum.all?(T.consent_set_cookies(conn), &(&1 =~ ~r/max-age=0/i))

      other = to_consent(cid, @https, %{}, priv)
      T.assert_consent_redirect(other.cb)
    end

    test "a source with 20 live consent rows is refused, a different source is not", %{cid: cid, priv: priv} do
      ip = T.unique_ip()
      source = Nebu.OAuth.SourceKey.from_ip(T.ip_string(ip))
      for n <- 1..20, do: T.insert_consent!(cid, user_id: "@src-#{n}-#{T.rand(4)}:test.local", source_key: source)

      flow = T.start_flow(cid, @https)
      T.finish_flow(flow, priv, ip: ip) |> T.assert_error_redirect(@https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))

      c = to_consent(cid, @https, %{}, priv)
      T.assert_consent_redirect(c.cb)
    end
  end

  describe "L-1 — the device holder is re-checked when the code is redeemed (security review cycle 1)" do
    test "another app took the device between Allow and the exchange => invalid_grant, no session of the code's app, the holder untouched", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      c = to_consent(cid, @https, %{"scope" => T.matrix_scope(T.stable_prefix(), "REDEEM0001")}, priv, sub: sub)
      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())

      # AFTER the Allow another approved app takes the (then free) device id
      other = T.oauth_client!(["https://other.example.org/cb"], client_uri: "https://other.example.org")
      holder = T.session!(other, "https://other.example.org/cb", priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "REDEEM0001")})

      T.redeem(grant(c, params)) |> T.assert_token_error(400, "invalid_grant")
      assert T.whoami(holder.at).status == 200, "the other app's session survives"
      assert [%{"client_id" => ^other}] = T.active_rows(c.user_id, "REDEEM0001")
    end

    test "the holder the user SAW (the same app) continues to be replaceable; a legacy session too", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      old = T.session!(cid, @https, priv, sub: sub)
      c = to_consent(cid, @https, %{}, priv, sub: sub)
      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      body = T.redeem!(grant(c, params))
      assert T.whoami(body["access_token"]).status == 200
      assert T.whoami(old.at).status == 401
    end

    test "the minted code records that the holder was checked and which app held the device", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      _old = T.session!(cid, @https, priv, sub: sub)
      c = to_consent(cid, @https, %{}, priv, sub: sub)
      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      row = code_row(params["code"])
      assert row["device_holder_checked"] == true
      assert row["device_holder_client_id"] == cid
    end
  end

  describe "INFO1 / INFO5 — cookie lifetime on a storage error, absurd auth_time" do
    test "a storage error at the decision keeps the consent cookie (a retry works); a definite outcome clears it", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      conn = T.consent_post([{"csrf_token", T.consent_csrf(elem(pair, 1))}, {"decision", "allow"}], cookie: pair)
      Application.delete_env(:nebu_http, :oauth_repo)

      assert conn.status == 503
      refute cookie_cleared?(conn), "the row may still be there: the cookie must stay"
      T.consent!(pair, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
    end

    test "an absurd auth_time claim is stored as NULL (never fresh), not raw", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv, claims: %{"sub" => T.unique_sub(), "auth_time" => -9_000_000_000_000})
      row = T.consent_row_of(c.cb)
      assert row["auth_time"] == nil
      assert row["login_fresh"] == false
    end
  end

  describe "AC8 — purge" do
    test "Nebu.OAuth.purge_expired_flow_state/0 removes expired consent rows, keeps live ones, reports consents:", %{cid: cid} do
      uid = T.provision_user!()
      live = T.insert_consent!(cid, user_id: uid)
      expired = T.insert_consent!(cid, user_id: uid, created_sql: "now() - interval '6 minutes'", expires_sql: "now() - interval '1 minute'")

      assert {:ok, %{authz_requests: a, codes: c, consents: n}} = Nebu.OAuth.purge_expired_flow_state()
      assert is_integer(a) and is_integer(c) and n >= 1
      assert T.consent_row(live.value)
      assert T.consent_row(expired.value) == nil
    end

    test "the purge worker source names the consent purge (static)" do
      src = File.read!(Path.join(@lib, "workers/oauth_flow_purge_worker.ex"))
      assert src =~ ~r/consent/i
    end

    test "the purge worker runs it and returns :ok", %{cid: cid} do
      uid = T.provision_user!()
      expired = T.insert_consent!(cid, user_id: uid, created_sql: "now() - interval '6 minutes'", expires_sql: "now() - interval '1 minute'")
      assert :ok = apply(Nebu.Workers.OAuthFlowPurgeWorker, :perform, [%Oban.Job{}])
      assert T.consent_row(expired.value) == nil
    end

    test "batched: more expired rows than one batch are removed in one call", %{cid: cid} do
      T.sql!(
        "INSERT INTO oauth_consent_requests (binding_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
          "response_mode, openid_requested, login_fresh, created_at, expires_at) " <>
          "SELECT lpad(to_hex(g + 20000), 64, '0'), $1, 'u', 'c', 'D', '@purge:test.local', 's', 'urn:matrix:client:', 'query', false, true, " <>
          "now() - interval '20 minutes', now() - interval '15 minutes' FROM generate_series(1, 1500) g",
        [cid]
      )

      assert {:ok, %{consents: n}} = Nebu.OAuth.purge_expired_flow_state()
      assert n >= 1500
      assert consent_count(cid) == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — device takeover (FR11)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9 — the holder cases that pass" do
    test "no holder: data-device=new; Allow works", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      assert T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)).resp_body =~ ~s(data-device="new")
      T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
    end

    test "same client_id: data-device=same_client; after Allow + exchange the old session is dead (T7), the new one works", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      old = T.session!(cid, @https, priv, sub: sub)

      c = to_consent(cid, @https, %{}, priv, sub: sub)
      page = T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end))
      assert page.resp_body =~ ~s(data-device="same_client")

      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      body = T.redeem!(grant(c, params))
      assert T.whoami(body["access_token"]).status == 200
      assert T.whoami(old.at).status == 401, "the earlier session of the device is replaced"
    end

    test "a DCR re-registration of the same app (other client_id, same normalized client_uri + redirect set): same_client, not refused", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      _old = T.session!(cid, @https, priv, sub: sub)
      redo = T.oauth_client!([@https, @https_query, @private | @loop_uris], client_name: "Flow Test App (again)", client_uri: @website <> "/")

      c = to_consent(redo, @https, %{}, priv, sub: sub)
      T.assert_consent_redirect(c.cb)
      assert T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)).resp_body =~ ~s(data-device="same_client")
      T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
    end

    test "a LEGACY session on the device: data-device=replace; after Allow and the exchange the legacy token is rejected (T7/T26)", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      legacy = T.legacy_session!(uid, "AbCdEfGhIj")
      assert T.whoami(legacy.at).status == 200

      c = to_consent(cid, @https, %{}, priv, sub: sub)
      page = T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end))
      assert page.resp_body =~ ~s(data-device="replace")
      assert T.whoami(legacy.at).status == 200, "nothing is replaced before the user decides"

      params = T.consent!(c.cb, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      assert T.whoami(legacy.at).status == 200, "nor before the code is exchanged"
      _body = T.redeem!(grant(c, params))
      assert T.whoami(legacy.at).status == 401
    end

    test "a Deny on a 'replace' consent leaves the legacy session alone", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      legacy = T.legacy_session!(uid, "AbCdEfGhIj")
      c = to_consent(cid, @https, %{}, priv, sub: sub)
      T.consent!(c.cb, :deny) |> T.assert_deny_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
      assert T.whoami(legacy.at).status == 200
    end

    test "a device row without a live session passes as 'replace'", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, "AbCdEfGhIj", display_name: "Dormant", last_seen_ts: System.system_time(:millisecond))
      c = to_consent(cid, @https, %{}, priv, sub: sub)
      T.assert_consent_redirect(c.cb)
      assert T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)).resp_body =~ ~s(data-device="replace")
    end
  end

  describe "AC9 — another app's device is refused (Nebu policy, FR11, stricter than the spec)" do
    setup %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      holder = T.session!(cid, @https, priv, sub: sub)
      {:ok, sub: sub, holder: holder}
    end

    test "another client_uri => 403 device_in_use at the callback: no row, no Location, no state/iss in the body, close-window text, no code", %{priv: priv, sub: sub, holder: holder} do
      other = T.oauth_client!([@https], client_name: "Other App", client_uri: "https://other.example.org")
      state = "client-state-" <> T.rand()
      flow = T.start_flow(other, @https, %{"state" => state})
      conn = T.finish_flow(flow, priv, claims: %{"sub" => sub})

      T.assert_page(conn, 403, "device_in_use")
      refute conn.resp_body =~ state, "no client state is echoed"
      refute conn.resp_body =~ T.issuer(), "no iss in the body"
      refute conn.resp_body =~ "code="
      assert conn.resp_body =~ "This app asked to take over a session that another app is using. This is not allowed."
      assert conn.resp_body =~ ~r/close this window/i
      assert conn.resp_body =~ ~r/start signing in again from your app/i
      assert T.consent_set_cookies(conn) |> Enum.reject(&(&1 =~ ~r/max-age=0/i)) == [], "no live consent cookie"
      assert consent_count(other) == 0
      assert code_count(other) == 0
      assert T.whoami(holder.at).status == 200, "the holder's session is untouched"
    end

    test "the same client_uri but ANOTHER redirect set => refused too", %{priv: priv, sub: sub, holder: holder} do
      other = T.oauth_client!(["https://app.example.com/other-callback"], client_uri: @website)
      flow = T.start_flow(other, "https://app.example.com/other-callback")
      conn = T.finish_flow(flow, priv, claims: %{"sub" => sub})
      T.assert_page(conn, 403, "device_in_use")
      assert consent_count(other) == 0
      assert T.whoami(holder.at).status == 200
    end

    test "a client without a client_uri counts as the same app only with an EQUAL client_id", %{priv: priv, sub: sub, holder: holder} do
      nouri = T.oauth_client!([@https], client_uri: nil)
      flow = T.start_flow(nouri, @https)
      T.finish_flow(flow, priv, claims: %{"sub" => sub}) |> T.assert_page(403, "device_in_use")
      assert T.whoami(holder.at).status == 200
    end

    test "the holder changes BETWEEN GET and Allow => refused at Allow: row consumed, no code, 403 device_in_use", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      c = to_consent(cid, @https, %{"scope" => T.matrix_scope(T.stable_prefix(), "RACEDEV001")}, priv, sub: sub)
      T.assert_consent_redirect(c.cb)
      {_n, value, _} = T.consent_cookie(c.cb)
      page = T.consent_get(T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end))
      assert page.resp_body =~ ~s(data-device="new")

      other = T.oauth_client!(["https://other.example.org/cb"], client_uri: "https://other.example.org")
      holder = T.session!(other, "https://other.example.org/cb", priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "RACEDEV001")})

      codes_before = code_count(cid)
      conn = T.consent!(c.cb, :allow, get: false)
      T.assert_page(conn, 403, "device_in_use")
      assert T.consent_row(value) == nil, "the row is consumed"
      assert code_count(cid) == codes_before, "no code is minted (the setup's holder session already used one)"
      assert T.whoami(holder.at).status == 200
    end
  end

  describe "AC9 — the holder lookup is unavailable" do
    test "at the callback => a temporarily_unavailable error redirect; no consent row, no code", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      T.put_env_scoped(:account_matrix_repo, T.NoSuchRepo)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      conn = T.finish_flow(flow, priv)
      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))
      assert consent_count(cid) == 0
      assert code_count(cid) == 0
    end

    test "at Allow => a 503 page; no code", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      T.assert_consent_redirect(c.cb)
      T.put_env_scoped(:account_matrix_repo, T.NoSuchRepo)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      conn = T.consent!(c.cb, :allow, get: false)
      assert conn.status == 503
      assert code_count(cid) == 0
    end
  end

  describe "AC9 — facade Nebu.Matrix.oauth_device_holder/2 (FR11, FR20)" do
    defp holder(user_id, device_id), do: apply(Nebu.Matrix, :oauth_device_holder, [user_id, device_id])

    test "exported with a @doc" do
      assert {:module, Nebu.Matrix} = Code.ensure_loaded(Nebu.Matrix)
      assert function_exported?(Nebu.Matrix, :oauth_device_holder, 2)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Nebu.Matrix)

      assert Enum.any?(docs, fn
               {{:function, :oauth_device_holder, 2}, _, _, %{"en" => d}, _} -> is_binary(d)
               _ -> false
             end)
    end

    test "nothing => {:ok, :none}; a legacy session => display_name, last_seen_ts, auth_api legacy, no client_id" do
      uid = T.provision_user!()
      assert {:ok, :none} = holder(uid, "HOLD000001")

      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, "HOLD000002", display_name: "Old Element", last_seen_ts: 1_700_000_000_000)
      _ = T.legacy_session!(uid, "HOLD000002")
      assert {:ok, %{display_name: "Old Element", last_seen_ts: 1_700_000_000_000, auth_api: "legacy", client_id: nil}} = holder(uid, "HOLD000002")
    end

    test "a device row without a live session => the map with nil auth_api / client_id", %{} do
      uid = T.provision_user!()
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, "HOLD000003", display_name: "Dormant")
      assert {:ok, %{display_name: "Dormant", auth_api: nil, client_id: nil}} = holder(uid, "HOLD000003")
    end

    test "a live OAuth session => auth_api oauth and its client_id", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      s = T.session!(cid, @https, priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "HOLD000004")})
      assert {:ok, %{auth_api: "oauth", client_id: ^cid}} = holder(s.user_id, "HOLD000004")
    end

    test "an unreachable database => {:error, :unavailable}" do
      T.put_env_scoped(:account_matrix_repo, T.NoSuchRepo)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      assert {:error, :unavailable} = holder("@x:test.local", "HOLD000005")
    end
  end

  describe "AC9 — ClientStore.client_identity/1 (deduped identity, correction 2)" do
    test "normalized client_uri + sorted, de-duplicated redirect URIs; equal for a re-registration, different otherwise" do
      a = T.oauth_client!(["https://app.example.com/b", "https://app.example.com/a", "https://app.example.com/a"], client_uri: "HTTPS://App.Example.com:443/")
      b = T.oauth_client!(["https://app.example.com/a", "https://app.example.com/b"], client_uri: "https://app.example.com")
      c = T.oauth_client!(["https://app.example.com/a"], client_uri: "https://app.example.com")
      d = T.oauth_client!(["https://app.example.com/a", "https://app.example.com/b"], client_uri: "https://other.example.org")

      ident = fn id -> apply(Nebu.OAuth.ClientStore, :client_identity, [id]) end
      assert {:ok, ia} = ident.(a)
      assert {:ok, ib} = ident.(b)
      assert {:ok, ic} = ident.(c)
      assert {:ok, id_} = ident.(d)
      assert ia == ib, "lower-cased scheme/host, default port and trailing / dropped, redirects sorted and de-duplicated"
      refute ia == ic
      refute ia == id_
    end

    test "a client without a client_uri has NO identity (only an equal client_id counts)" do
      nouri = T.oauth_client!([@https], client_uri: nil)
      assert {:ok, nil} = apply(Nebu.OAuth.ClientStore, :client_identity, [nouri])
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC15 — kill switch, rate limit, routing
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC15 — liveness is checked before the bucket and any DB access" do
    test "OAuth off => 404 unavailable page on GET and POST; no rate-limit token, no DB", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)
      ip = T.unique_ip()
      T.drain!("oauth_consent", ip, 10, 600, 1)
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      T.disable_oauth()

      T.assert_page(T.consent_get(pair, ip: ip), 404, "unavailable")
      T.assert_page(T.consent_post([{"csrf_token", T.consent_csrf(elem(pair, 1))}, {"decision", "allow"}], cookie: pair, ip: ip), 404, "unavailable")

      T.enable_oauth()
      Application.delete_env(:nebu_http, :oauth_repo)
      assert T.consent_get(pair, ip: ip).status == 200, "the last rate-limit token is still there, the row survived"
    end

    test "an unreadable config => 503 page unavailable", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)
      T.unreadable_oauth_config()
      conn = T.consent_get(pair)
      T.assert_page(conn, 503, "unavailable")
    end

    test "an unreadable config => 503 page unavailable on POST too, nothing consumed (MINOR 8)", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)
      T.unreadable_oauth_config()
      conn = T.consent_post([{"csrf_token", T.consent_csrf(elem(pair, 1))}, {"decision", "allow"}], cookie: pair)
      T.assert_page(conn, 503, "unavailable")
      refute cookie_cleared?(conn)
      assert T.consent_row(elem(pair, 1)), "nothing consumed"
      assert code_count(cid) == 0
    end

    test "an invalid (non-https) issuer is 'not live' too", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)
      T.enable_oauth("http://nebu.example.com")
      T.assert_page(T.consent_get(pair), 404, "unavailable")
    end
  end

  describe "AC15 — bucket {\"oauth_consent\", ip} (600/h)" do
    test "an exhausted bucket => 429 page + Retry-After; the cookie is kept and nothing is consumed", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)
      ip = T.unique_ip()
      T.drain!("oauth_consent", ip, 10, 600)

      get = T.consent_get(pair, ip: ip)
      T.assert_page(get, 429, "rate_limited")
      assert T.header(get, "retry-after")

      post = T.consent_post([{"csrf_token", T.consent_csrf(elem(pair, 1))}, {"decision", "allow"}], cookie: pair, ip: ip)
      T.assert_page(post, 429, "rate_limited")
      assert T.header(post, "retry-after")
      refute cookie_cleared?(post), "the cookie stays so the same browser can retry"
      assert T.consent_row(elem(pair, 1)), "nothing consumed"
      assert code_count(cid) == 0

      T.consent!(pair, :allow) |> T.assert_allow_redirect(@https, "fragment", T.param(c.flow.pairs, "state"), issuer())
    end
  end

  describe "AC15 — methods, sub-paths, CORS" do
    test "OPTIONS / PUT / DELETE => 405 page with Allow: GET, POST; no CORS even for a preflight", %{} do
      pre = T.options("/oauth2/consent", request_method: "POST")
      T.assert_page(pre, 405, "method_not_allowed")
      assert T.header(pre, "allow") =~ "GET" and T.header(pre, "allow") =~ "POST"
      refute Enum.any?(pre.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)

      for m <- [:put, :delete, :patch] do
        conn = T.consent_get({"nebu_oauth_consent", "x"}, method: m)
        T.assert_page(conn, 405, "method_not_allowed")
        assert T.header(conn, "allow") =~ "GET" and T.header(conn, "allow") =~ "POST"
      end
    end

    test "/oauth2/consent/x and /oauth2/consent/ with extras => 404", %{} do
      assert T.get("/oauth2/consent/x").status == 404
      assert T.get("/oauth2/consent/a/b").status == 404
    end

    test "no response carries an access-control-* header, with an Origin request header", %{cid: cid, priv: priv} do
      c = to_consent(cid, @https, %{}, priv)
      pair = T.consent_cookie(c.cb) |> then(fn {n, v, _} -> {n, v} end)

      for conn <- [T.consent_get(pair, headers: [{"origin", "https://evil.example.com"}]), T.consent_get({"nebu_oauth_consent", "x"}, headers: [{"origin", "https://evil.example.com"}])] do
        refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
      end
    end
  end

  describe "regression — the unchanged parts of the OAuth surface" do
    test "metadata does not advertise a consent endpoint (no metadata change in this story)" do
      doc = T.get_metadata() |> T.json()
      refute Enum.any?(doc, fn {_k, v} -> is_binary(v) and v =~ "/oauth2/consent" end)
    end

  end
end
