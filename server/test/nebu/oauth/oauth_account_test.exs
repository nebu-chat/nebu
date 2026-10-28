defmodule Nebu.OAuth.OAuthAccountTest do
  @moduledoc """
  Acceptance tests for story `oauth-account-management` (story 6 of epic oauth-broker),
  AC1-AC7 and the page part of AC9 (A2-A13, A16, A17, A19-A21; Must #2-#20, #30, #32, #34, #35,
  #47-#55) through the FULL `Nebu.Web.Router`:

    * AC1 routing / liveness (same predicate as `auth_metadata`), methods, A20 headers, no CORS,
      rate limit `{"oauth_account", ip}`;
    * AC2 sign-in through the SHARED IdP callback with the `o2.acct.` state tag (binding cookie,
      atomic consume, return target from the row, no provisioning, `auth_time` rules);
    * AC3 the DB-backed hashed browser session (cookie attributes, idle / absolute timeout, rotation,
      cap, logout, never a Matrix credential); AC4 CSRF; AC5 actions / aliases / `device_id` decoding;
    * AC6 device list; AC7 device deletion through the story-5 locked teardown (fresh / stale,
      legacy-only user, current device, concurrency, failure); AC9 approval page.

  Sessions are created through the real callback (`T.account_login!/3`) or inserted directly
  (`T.account_session!/2`, chosen `auth_time`).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @actions ~w(org.matrix.profile org.matrix.devices_list org.matrix.device_view org.matrix.device_delete org.matrix.cross_signing_reset)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https], client_name: "Element " <> T.rand(3))}
  end

  defp dev, do: "AC" <> String.upcase(T.rand(4))
  defp now, do: System.system_time(:second)

  defp no_db! do
    Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
    Application.put_env(:nebu_http, :account_matrix_repo, T.NoSuchRepo)
  end

  defp user!(sub \\ T.unique_sub()), do: %{sub: sub, uid: T.provision_user!(sub)}

  defp q(pairs), do: "/account?" <> URI.encode_query(pairs)

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — routing, liveness, methods, headers, rate limit (A2-A4, A19, A20; Must #2, #34, #35)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/A3/Must #2 — liveness = the auth_metadata predicate" do
    test "disabled / invalid issuer => 404 page `unavailable` on every /account* path, no DB, no rate-limit token" do
      no_db!()
      ip = T.unique_ip()
      T.drain!("oauth_account", ip, 10, 600, 1)

      for set <- [fn -> T.disable_oauth() end, fn -> T.enable_oauth("http://nebu.example.com") end, fn -> T.enable_oauth("https://nebu.example.com/x") end],
          path <- ["/account", "/account?action=org.matrix.devices_list", "/account/reauth", "/account/nope"] do
        set.()
        T.account_get(path, ip: ip) |> T.assert_account_error(404, "unavailable")
        assert T.get_metadata().status == 404
      end

      T.disable_oauth()
      T.account_post("/account/devices/delete", [{"device_id", "X"}], ip: ip) |> T.assert_account_error(404, "unavailable")
      T.enable_oauth()
      Application.delete_env(:nebu_http, :oauth_repo)
      Application.delete_env(:nebu_http, :account_matrix_repo)
      assert T.account_get("/account", ip: ip).status == 302, "the last rate-limit token is still there"
    end

    test ":unknown config => 503 page `unavailable` + Retry-After: 5" do
      no_db!()
      T.unreadable_oauth_config()
      conn = T.account_get("/account") |> T.assert_account_error(503, "unavailable")
      assert T.header(conn, "retry-after") == "5"
    end

    test "a runtime toggle flips the page on the next request (no cache)" do
      T.disable_oauth()
      T.account_get("/account") |> T.assert_account_error(404, "unavailable")
      T.enable_oauth()
      assert T.account_get("/account").status == 302
      T.disable_oauth()
      T.account_get("/account") |> T.assert_account_error(404, "unavailable")
    end
  end

  describe "AC1/A2/A4/Must #34 — methods, sub-paths, CORS, body handling" do
    test "wrong methods => 405 page with Allow; unknown sub-path => 404 page not_found; OPTIONS => 405 (no preflight answer)" do
      for {m, path, allow} <- [{:post, "/account", "GET"}, {:put, "/account", "GET"}, {:post, "/account/reauth", "GET"},
                               {:get, "/account/devices/delete", "POST"}, {:get, "/account/logout", "POST"},
                               {:get, "/account/cross_signing_reset/approve", "POST"}, {:delete, "/account/cross_signing_reset/decline", "POST"}] do
        conn = T.account_get(path, method: m)
        T.assert_account_error(conn, 405, "method_not_allowed")
        assert T.header(conn, "allow") =~ allow, "#{m} #{path}: Allow #{inspect(T.header(conn, "allow"))}"
      end

      T.account_get("/account/does/not/exist") |> T.assert_account_error(404, "not_found")

      pre = T.options("/account", request_method: "POST")
      T.assert_account_error(pre, 405, "method_not_allowed")
    end

    test "every response carries the A20 headers and NO access-control-* header, also with an Origin request header" do
      for conn <- [T.account_get("/account", origin: "https://evil.example.com"), T.account_get("/account/nope", origin: "https://evil.example.com"),
                   T.account_get("/account", method: :put, origin: "https://evil.example.com")] do
        T.assert_account_headers(conn)
      end
    end

    test "POST bodies: non-form content type, a query string, a duplicated field, > 16 KiB => invalid_request page" do
      %{uid: uid} = user!()
      s = T.account_session!(uid)

      for {body, opts} <- [
            {~s({"device_id":"X"}), [content_type: "application/json"]},
            {"device_id=X&csrf_token=#{s.csrf}&device_id=Y", []},
            {"device_id=X&csrf_token=#{s.csrf}&pad=" <> String.duplicate("a", 16_400), []}
          ] do
        T.account_post("/account/devices/delete", body, [cookie: s.cookie] ++ opts) |> T.assert_account_error(400, "invalid_request")
      end

      T.account_post("/account/devices/delete?x=1", [{"device_id", "X"}, {"csrf_token", s.csrf}], cookie: s.cookie)
      |> T.assert_account_error(400, "invalid_request")
    end
  end

  describe "AC1/A19/Must #35 — rate limit {\"oauth_account\", ip}" do
    test "an exhausted bucket => 429 page rate_limited + Retry-After, before any DB access" do
      ip = T.unique_ip()
      T.drain!("oauth_account", ip, 10, 600)
      no_db!()
      conn = T.account_get("/account", ip: ip) |> T.assert_account_error(429, "rate_limited")
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
      T.account_post("/account/logout", [], ip: ip) |> T.assert_account_error(429, "rate_limited")
    end

    test "the account branch of the IdP callback pays the same bucket (cookie kept, nothing consumed)", %{priv: priv} do
      flow = T.account_start!()
      ip = T.unique_ip()
      T.drain!("oauth_account", ip, 10, 600)
      cb = T.account_finish(flow, priv, T.unique_sub(), ip: ip)
      T.assert_account_error(cb, 429, "rate_limited")
      assert T.sql!("SELECT 1 FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]).num_rows == 1
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — sign-in through the IdP (A6, A7; Must #3-#7)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2/A6/Must #3 — GET /account without a session => 302 to the IdP" do
    test "the story-2 OAuth-leg parameter set, state o2.acct.+43, prompt=login + max_age=0, the shared callback, binding cookie, one row" do
      flow = T.account_start!("/account?action=org.matrix.device_delete&device_id=DEVX")
      idp = flow.idp
      assert idp["response_type"] == "code"
      assert idp["client_id"] == "nebu-client"
      assert idp["redirect_uri"] =~ ~r{/_matrix/client/v3/login/sso/redirect/oidc$}
      assert idp["state"] =~ ~r/\Ao2\.acct\.[A-Za-z0-9_-]{43}\z/
      assert is_binary(idp["nonce"]) and idp["nonce"] != ""
      assert idp["code_challenge"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert idp["code_challenge_method"] == "S256"
      assert idp["prompt"] == "login"
      assert idp["max_age"] == "0"
      assert idp["scope"] == T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(T.legacy_redirect_url())) |> T.idp_params() |> Map.get("scope"),
             "the OIDC Scopes Law scope of the legacy redirect, no new scope"

      {name, _} = flow.binding
      assert name =~ ~r/\Anebu_acct_[0-9a-f]{16}\z/
      raw = T.raw_set_cookie(flow.conn, name)
      for attr <- ["HttpOnly", "SameSite=Lax", "Path=/_matrix/client/v3/login/sso/redirect/oidc", "Max-Age=600"],
          do: assert(raw =~ ~r/#{Regex.escape(attr)}/i, "binding cookie lacks #{attr}: #{raw}")

      %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)])
      assert n == 1
      row = T.sql!("SELECT return_action, return_device_id FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]).rows
      assert row == [["org.matrix.device_delete", "DEVX"]]
      refute Enum.any?(T.sql!("SELECT * FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]).rows |> hd(), &(&1 == flow.state))
    end

    test "IdP discovery failure => 503 page unavailable, nothing persisted" do
      Application.put_env(:nebu_http, :oidc_metadata_override, %{"issuer" => T.idp_issuer()})
      %{rows: [[before]]} = T.sql!("SELECT count(*) FROM oauth_account_login_requests")
      T.account_get("/account") |> T.assert_account_error(503, "unavailable")
      %{rows: [[later]]} = T.sql!("SELECT count(*) FROM oauth_account_login_requests")
      assert later == before
    end
  end

  describe "AC2/A6/Must #4 — account callback success" do
    test "303 to the return target FROM THE ROW, session cookie, one session row, request consumed, binding cleared", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      flow = T.account_start!("/account?action=org.matrix.device_view&device_id=DEVQ")
      cb = T.account_finish(flow, priv, sub)
      assert cb.status == 303, "got #{cb.status}: #{cb.resp_body}"
      assert T.location(cb) == "/account?action=org.matrix.device_view&device_id=DEVQ"
      cookie = T.account_cookie_from(cb)
      assert cookie =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert T.account_session_row(cookie)["user_id"] == uid
      assert T.sql!("SELECT 1 FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]).num_rows == 0
      {bname, _} = flow.binding
      assert T.raw_set_cookie(cb, bname) =~ ~r/max-age=0/i, "binding cookie cleared"
      T.assert_account_headers(cb)
    end

    test "Must #4: the callback query cannot steer the target (open-redirect safe)", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!("/account?action=org.matrix.profile")
      cb = T.account_finish(flow, priv, sub)
      assert T.location(cb) == "/account?action=org.matrix.profile"
    end

    test "rotation: a presented old session is deleted; a different IdP account yields that account's session", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      old = T.account_session!(uid)
      flow = T.account_start!("/account", cookie: "not-a-session")
      cb = T.account_finish(flow, priv, sub, extra_cookies: [{T.account_cookie_name(), old.cookie}])
      assert cb.status == 303
      new = T.account_cookie_from(cb)
      refute new == old.cookie
      assert T.account_session_row(old.cookie) == nil, "session fixation defence: the replaced session is deleted"
      assert T.account_session_row(new)["user_id"] == uid
    end

    test "an invalid return target recorded at start becomes the default page", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!("/account?action=org.matrix.account_deactivate")
      cb = T.account_finish(flow, priv, sub)
      assert T.location(cb) in ["/account", "/account?"], "unknown action => default page target, got #{inspect(T.location(cb))}"
    end
  end

  describe "AC2/A6/A7/Must #4, #6, #7 — callback failures (each with its page, NO session)" do
    defp no_session_cookie(conn), do: assert(T.account_cookie_from(conn) == nil, "no account session may be set")

    test "unknown / replayed / expired state => 400 invalid_state", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      ok = T.account_finish(flow, priv, sub)
      assert ok.status == 303
      replay = T.account_finish(flow, priv, sub)
      T.assert_account_error(replay, 400, "invalid_state")
      no_session_cookie(replay)

      bogus = %{flow | state: "o2.acct." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
      T.account_finish(bogus, priv, sub) |> T.assert_account_error(400, "invalid_state")

      malformed = %{flow | state: "o2.acct.short"}
      T.account_finish(malformed, priv, sub) |> T.assert_account_error(400, "invalid_state")

      exp = T.account_start!()
      T.privileged_sql!(
        "UPDATE oauth_account_login_requests SET created_at = now() - interval '11 minutes', expires_at = now() - interval '1 minute' WHERE state_hash = $1",
        [T.sha256_hex(exp.state)]
      )

      T.account_finish(exp, priv, sub) |> T.assert_account_error(400, "invalid_state")
    end

    test "missing / mismatching binding cookie => invalid_state, the row consumed", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      T.account_finish(flow, priv, sub, cookies: []) |> T.assert_account_error(400, "invalid_state")
      assert T.sql!("SELECT 1 FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]).num_rows == 0

      flow2 = T.account_start!()
      {name, _} = flow2.binding
      T.account_finish(flow2, priv, sub, cookies: [{name, "wrong-value"}]) |> T.assert_account_error(400, "invalid_state")
    end

    test "IdP error param => access_denied (IdP text never shown)" do
      flow = T.account_start!()
      cb = T.callback([{"error", "access_denied"}, {"error_description", "IDP-TEXT-SECRET"}, {"state", flow.state}], [flow.binding])
      T.assert_account_error(cb, 403, "access_denied")
      refute cb.resp_body =~ "IDP-TEXT-SECRET"
      no_session_cookie(cb)
    end

    test "IdP exchange failure => access_denied or unavailable, no session", %{priv: _priv} do
      flow = T.account_start!()
      T.stub_idp_exchange({:error, :invalid_grant})
      cb = T.callback([{"code", "c-" <> T.rand()}, {"state", flow.state}], [flow.binding])
      assert cb.status in [403, 503]
      assert cb.resp_body =~ ~r/data-error="(access_denied|unavailable)"/
      no_session_cookie(cb)
    end

    test "Must #6: unknown user => no_account page and NO users row; deactivated => deactivated", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.user_id_for(%{"sub" => sub})
      cb = T.account_finish(T.account_start!(), priv, sub)
      T.assert_account_error(cb, 403, "no_account")
      assert T.sql!("SELECT 1 FROM users WHERE user_id = $1", [uid]).num_rows == 0, "no provisioning (A7)"
      no_session_cookie(cb)

      %{sub: sub2, uid: uid2} = user!()
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [uid2])
      T.account_finish(T.account_start!(), priv, sub2) |> T.assert_account_error(403, "deactivated")
    end

    test "Must #6: a DB error in the identity read => 503 unavailable (error-aware)", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      Application.put_env(:nebu_http, :account_matrix_repo, T.NoSuchRepo)
      T.account_finish(flow, priv, sub) |> T.assert_account_error(503, "unavailable")
    end

    test "Must #7: auth_time older than request - 60 s => reauth_failed, no session", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      cb = T.account_finish(flow, priv, sub, claims: %{"auth_time" => now() - 3600})
      T.assert_account_error(cb, 403, "reauth_failed")
      no_session_cookie(cb)
    end

    # story oauth-authorize-freshness (FR14, gate y) CHANGES this by design: an absent auth_time used to
    # become "the callback time", i.e. a session that was FRESH although the IdP proved nothing. Now the
    # session carries auth_time NULL (never fresh) and the destructive actions are unavailable.
    test "Must #7 (changed by FR14): auth_time ABSENT => a session with auth_time NULL + a WARNING without PII", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      flow = T.account_start!()
      log = capture_log(fn -> send(self(), {:cb, T.account_finish(flow, priv, sub, claims: %{"auth_time" => nil})}) end)
      assert_received {:cb, cb}
      assert cb.status == 303
      row = T.account_session_row(T.account_cookie_from(cb))
      assert row["auth_time"] == nil, "never the callback time: the IdP proved no authentication time"
      assert log =~ "no auth_time"
      assert log =~ "[warning]"
      refute log =~ uid, "the WARNING carries no user id"
      refute log =~ sub
    end

    test "FR14: the 'no auth_time' WARNING is throttled (once per hour per node), not per login", %{priv: priv} do
      log =
        capture_log(fn ->
          for _ <- 1..3 do
            %{sub: sub} = user!()
            T.account_finish(T.account_start!(), priv, sub, claims: %{"auth_time" => nil})
          end
        end)

      warnings = log |> String.split("\n") |> Enum.filter(&(&1 =~ "no auth_time"))
      assert warnings != []
      if System.get_env("NEBU_RATE_LIMIT_DISABLED") not in ["true", "1"], do: assert(length(warnings) == 1, "got #{length(warnings)}: #{inspect(warnings)}")
    end

    test "FR2: a fresh / stale / absent claim goes through the shared Nebu.OAuth.Freshness helper (one rule, no copy in account.ex)" do
      src = File.read!(Path.expand("../../../lib/nebu/oauth/account.ex", __DIR__)) |> String.replace(~r/#[^\n]*/, "")
      assert src =~ "Freshness", "account.ex must use Nebu.OAuth.Freshness (FR2)"
      refute src =~ ~r/defp\s+freshness\(/, "the private freshness/2 moved into Nebu.OAuth.Freshness"
    end

    test "iat is NOT a substitute for auth_time (claim only)", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      cb = T.account_finish(flow, priv, sub, claims: %{"auth_time" => now() - 3600, "iat" => now()})
      T.assert_account_error(cb, 403, "reauth_failed")
    end
  end

  describe "AC2/Must #5 — other states are unaffected" do
    test "a legacy SSO login state and the story-2 o2. state keep their branches", %{priv: priv} do
      init = T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(T.legacy_redirect_url()))
      idp = T.idp_params(init)
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, %{"sub" => T.unique_sub(), "nonce" => idp["nonce"]}), nil})
      cb = T.callback([{"code", "c"}, {"state", idp["state"]}])
      assert cb.status == 302
      assert T.location(cb) =~ "loginToken="
      assert T.account_cookie_from(cb) == nil
    end
  end

  describe "AC2/A17/Must #32 — the account login does not touch matrix_sessions.auth_time" do
    test "OAuth rows keep their auth_time after an account login", %{priv: priv, cid: cid} do
      %{sub: sub} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      T.sql!("UPDATE matrix_sessions SET auth_time = 1000 WHERE access_token_hash = $1", [T.token_hash(s.at)])
      _ = T.account_login!(priv, sub)
      assert T.row_by_at(s.at)["auth_time"] == 1000
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — session lifecycle (A8; Must #8-#11)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3/A8/Must #8 — cookie attributes per scheme, hash-only storage" do
    test "http: nebu_account, Path=/account, HttpOnly, SameSite=Lax, no Secure, no Max-Age; only the hash stored", %{priv: priv} do
      %{sub: sub} = user!()
      cb = T.account_finish(T.account_start!(), priv, sub)
      raw = T.raw_set_cookie(cb, "nebu_account") || flunk("no nebu_account cookie: #{inspect(T.set_cookies(cb))}")
      assert raw =~ ~r/path=\/account(;|$)/i
      assert raw =~ ~r/HttpOnly/i and raw =~ ~r/SameSite=Lax/i
      refute raw =~ ~r/secure/i
      refute raw =~ ~r/max-age/i
      cookie = T.account_cookie_from(cb)
      assert T.sql!("SELECT 1 FROM oauth_account_sessions WHERE session_hash = $1", [cookie]).num_rows == 0, "plaintext never stored"
      assert T.account_session_row(cookie)
    end

    test "https: __Host-nebu_account, Path=/, Secure, HttpOnly, SameSite=Lax", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!("/account", https: true)
      cb = T.account_finish(flow, priv, sub, https: true)
      raw = T.raw_set_cookie(cb, "__Host-nebu_account") || flunk("no __Host- cookie on https: #{inspect(T.set_cookies(cb))}")
      assert raw =~ ~r/path=\/(;|$)/i
      assert raw =~ ~r/secure/i and raw =~ ~r/HttpOnly/i and raw =~ ~r/SameSite=Lax/i
      refute raw =~ ~r/domain=/i
    end

    test "a tampered / unknown cookie => a new IdP login, no error page" do
      conn = T.account_get("/account", cookie: "tampered-" <> T.rand())
      assert conn.status == 302
      T.idp_params(conn)
    end
  end

  describe "AC3/A8/Must #9 — idle and absolute timeouts in SQL" do
    test "a request shortly (5 s) before idle expiry succeeds and slides idle_expires_at (never beyond expires_at)" do
      %{uid: uid} = user!()
      s = T.account_session!(uid, idle_sql: "now() + interval '5 seconds'", expires_sql: "now() + interval '600 seconds'")
      before = T.account_session_row(s.cookie)
      T.account_get("/account", cookie: s.cookie) |> T.assert_account_page("default")
      after_row = T.account_session_row(s.cookie)
      assert DateTime.compare(after_row["idle_expires_at"], before["idle_expires_at"]) == :gt
      assert DateTime.compare(after_row["idle_expires_at"], after_row["expires_at"]) != :gt
    end

    test "after idle expiry or absolute expiry => no session (IdP login), the stale row is not reused" do
      %{uid: uid} = user!()
      idle = T.account_session!(uid, idle_sql: "now() - interval '1 second'")
      assert T.account_get("/account", cookie: idle.cookie).status == 302

      abs = T.account_session!(uid, created_sql: "now() - interval '3599 seconds'", idle_sql: "now() - interval '1 second'", expires_sql: "now() - interval '1 second'")
      assert T.account_get("/account", cookie: abs.cookie).status == 302
    end

    test "deactivating the user => the next request deletes the session and renders deactivated" do
      %{uid: uid} = user!()
      s = T.account_session!(uid)
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [uid])
      T.account_get("/account", cookie: s.cookie) |> T.assert_account_error(403, "deactivated")
      assert T.account_session_row(s.cookie) == nil
    end
  end

  describe "AC3/A8/A19/Must #10, #11 — cap, logout, never a Matrix credential" do
    test "at most 20 live sessions per user: the 21st login deletes the oldest", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      # the absolute lifetime CHECK (`expires_at <= created_at + 1 hour`, A24) applies to the fixture too
      oldest = T.account_session!(uid, created_sql: "now() - interval '30 minutes'", expires_sql: "now() + interval '30 minutes'")
      for _ <- 1..19, do: T.account_session!(uid)
      assert T.account_session_count(uid) == 20
      _ = T.account_login!(priv, sub)
      assert T.account_session_count(uid) == 20
      assert T.account_session_row(oldest.cookie) == nil
    end

    test "POST /account/logout (CSRF) deletes the row, clears the cookie, renders signed_out; the old cookie => IdP login" do
      %{uid: uid} = user!()
      s = T.account_session!(uid)
      conn = T.account_post("/account/logout", [{"csrf_token", s.csrf}], cookie: s.cookie)
      assert conn.status == 200
      assert conn.resp_body =~ ~s(data-notice="signed_out")
      raw = T.raw_set_cookie(conn, "nebu_account")
      assert raw =~ ~r/max-age=0/i and raw =~ ~r/path=\/account/i
      assert T.account_session_row(s.cookie) == nil
      assert T.account_get("/account", cookie: s.cookie).status == 302
    end

    test "the account cookie never authenticates /_matrix/* (whoami => 401 M_MISSING_TOKEN)" do
      %{uid: uid} = user!()
      s = T.account_session!(uid)

      conn =
        Plug.Test.conn(:get, "/_matrix/client/v3/account/whoami")
        |> Plug.Conn.put_req_header("cookie", "nebu_account=" <> s.cookie)
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 401
      assert T.json(conn)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — CSRF (A9; Must #12, #13)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/A9/Must #12 — CSRF on every POST" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      {:ok, uid: uid, s: s, acct: T.account_session!(uid), other: T.account_session!(T.provision_user!())}
    end

    test "missing / wrong / other-session token, foreign Origin, Sec-Fetch-Site: cross-site => 403 forbidden, nothing changed, session valid", ctx do
      before = T.world_snapshot([ctx.uid])

      variants = [
        {[{"device_id", ctx.s.device_id}], []},
        {[{"device_id", ctx.s.device_id}, {"csrf_token", "wrong"}], []},
        {[{"device_id", ctx.s.device_id}, {"csrf_token", ctx.other.csrf}], []},
        {[{"device_id", ctx.s.device_id}, {"csrf_token", ctx.acct.csrf}], [headers: [{"origin", "https://evil.example.com"}]]},
        {[{"device_id", ctx.s.device_id}, {"csrf_token", ctx.acct.csrf}], [headers: [{"sec-fetch-site", "cross-site"}]]}
      ]

      log =
        capture_log(fn ->
          for {params, opts} <- variants do
            T.account_post("/account/devices/delete", params, [cookie: ctx.acct.cookie] ++ opts) |> T.assert_account_error(403, "forbidden")
          end
        end)

      assert T.world_snapshot([ctx.uid]) == before
      assert T.whoami(ctx.s.at).status == 200
      assert T.account_session_row(ctx.acct.cookie)
      assert log =~ "[warning]", "CSRF failures are logged as WARNING (no values)"
      T.refute_secrets_in_log(log, %{csrf: ctx.acct.csrf, other: ctx.other.csrf, cookie: ctx.acct.cookie})
    end

    test "a valid token with Origin = the issuer origin, or without Origin / Sec-Fetch-Site, is accepted", ctx do
      conn = T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", ctx.acct.csrf}],
               cookie: ctx.acct.cookie, headers: [{"origin", "https://nebu.example.com"}, {"sec-fetch-site", "same-origin"}])

      assert conn.status == 303
      assert T.notice_of(conn) == "device_deleted"

      s2 = T.legacy_session!(ctx.uid, dev())
      d2 = T.json(T.whoami(s2.at))["device_id"]
      conn2 = T.account_post("/account/devices/delete", [{"device_id", d2}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie)
      assert conn2.status == 303
    end

    test "Must #13: every action GET leaves all rows unchanged", ctx do
      before = {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)}

      for action <- @actions, extra <- [[], [{"device_id", ctx.s.device_id}]] do
        _ = T.account_get(q([{"action", action} | extra]), cookie: ctx.acct.cookie)
      end

      _ = T.account_get("/account", cookie: ctx.acct.cookie)
      assert {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)} == before
      assert T.whoami(ctx.s.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — actions, aliases, default page, device_id decoding (A5, A20; Must #15, #16, #47-#51)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5/A5 — actions and the default page" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      {:ok, uid: uid, s: s, acct: T.account_session!(uid)}
    end

    test "Must #50/#15: the bare URI, an absent / unknown action and account_deactivate => default page 200, raw value not echoed", ctx do
      for path <- ["/account", "/account?", q([{"action", "org.matrix.UNKNOWN-ECHO"}]), q([{"action", "org.matrix.account_deactivate"}])] do
        conn = T.account_get(path, cookie: ctx.acct.cookie)
        T.assert_account_page(conn, "default")
        refute conn.resp_body =~ "UNKNOWN-ECHO"
        assert conn.resp_body =~ ctx.s.device_id, "the default page combines the profile summary and the device list"
      end
    end

    test "org.matrix.profile => user id + display name, no form, the administrator note", ctx do
      conn = T.account_get(q([{"action", "org.matrix.profile"}]), cookie: ctx.acct.cookie)
      T.assert_account_page(conn, "org.matrix.profile")
      assert conn.resp_body =~ ctx.uid
      refute conn.resp_body =~ "<form"
      assert conn.resp_body =~ ~r/administrator/i
    end

    test "device_view => the device + the prominent sign-out control to the delete confirmation (Must #51)", ctx do
      conn = T.account_get(q([{"action", "org.matrix.device_view"}, {"device_id", ctx.s.device_id}]), cookie: ctx.acct.cookie)
      T.assert_account_page(conn, "org.matrix.device_view")
      assert [_, href] = Regex.run(~r/<a[^>]*data-role="device-sign-out"[^>]*href="([^"]+)"|<a[^>]*href="([^"]+)"[^>]*data-role="device-sign-out"/, conn.resp_body) |> then(fn
               [_, a] -> [nil, a]
               [_, "", b] -> [nil, b]
               other -> other || flunk("no device-sign-out link")
             end)

      decoded = href |> String.replace("&amp;", "&") |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert decoded["action"] == "org.matrix.device_delete"
      assert decoded["device_id"] == ctx.s.device_id
    end

    test "Must #16: device_id missing / invalid / unknown / foreign => identical device_not_found answer", ctx do
      foreign = T.legacy_session!(T.provision_user!(), dev())
      foreign_dev = T.json(T.whoami(foreign.at))["device_id"]

      bodies =
        for action <- ["org.matrix.device_view", "org.matrix.device_delete"],
            extra <- [[], [{"device_id", "bad\u0001id"}], [{"device_id", "UNKNOWN" <> T.rand(3)}], [{"device_id", foreign_dev}]] do
          conn = T.account_get(q([{"action", action} | extra]), cookie: ctx.acct.cookie)
          assert conn.status == 200
          assert conn.resp_body =~ ~s(data-notice="device_not_found"), "#{action} #{inspect(extra)}"
          refute conn.resp_body =~ foreign_dev
          String.replace(conn.resp_body, ~r/name="csrf_token" value="[^"]*"/, "")
        end

      assert bodies |> Enum.uniq() |> length() == 1, "one identical answer for the four cases (no IDOR / existence oracle)"
    end

    test "Must #49: aliases map to the spec names", ctx do
      for {alias_name, spec} <- [{"org.matrix.sessions_list", "org.matrix.devices_list"}, {"sessions_list", "org.matrix.devices_list"},
                                 {"org.matrix.session_view", "org.matrix.device_view"}, {"session_view", "org.matrix.device_view"},
                                 {"org.matrix.session_end", "org.matrix.device_delete"}, {"session_end", "org.matrix.device_delete"}] do
        conn = T.account_get(q([{"action", alias_name}, {"device_id", ctx.s.device_id}]), cookie: ctx.acct.cookie)
        T.assert_account_page(conn, spec)
      end
    end

    test "Must #48: device_id on profile / devices_list / cross_signing_reset is ignored (also an invalid one)", ctx do
      for action <- ["org.matrix.profile", "org.matrix.devices_list", "org.matrix.cross_signing_reset"], id <- [ctx.s.device_id, "bad\u0001"] do
        conn = T.account_get(q([{"action", action}, {"device_id", id}]), cookie: ctx.acct.cookie)
        T.assert_account_page(conn, action)
        refute conn.resp_body =~ ~s(data-notice="device_not_found")
      end
    end

    test "Must #47: device ids with +, %2B, /, %2F and non-ASCII are decoded and found consistently", ctx do
      for raw_id <- ["DEV A" <> T.rand(2), "DEV+B" <> T.rand(2), "DEV/C" <> T.rand(2), "DÉV" <> T.rand(2)] do
        Nebu.Matrix.DeviceKeyStore.upsert_device(ctx.uid, raw_id)
        enc_plus = "/account?action=org.matrix.device_view&device_id=" <> URI.encode_www_form(raw_id)
        enc_pct = "/account?action=org.matrix.device_view&device_id=" <> URI.encode(raw_id, &URI.char_unreserved?/1)

        for path <- [enc_plus, enc_pct] do
          conn = T.account_get(path, cookie: ctx.acct.cookie)
          T.assert_account_page(conn, "org.matrix.device_view")
          refute conn.resp_body =~ ~s(data-notice="device_not_found"), "#{inspect(raw_id)} via #{path}"
        end
      end
    end

    test "duplicated action / device_id or malformed percent-encoding => default page with notice invalid_request", ctx do
      for path <- ["/account?action=org.matrix.profile&action=org.matrix.devices_list", "/account?action=org.matrix.device_view&device_id=A&device_id=B",
                   "/account?action=%zz"] do
        conn = T.account_get(path, cookie: ctx.acct.cookie)
        T.assert_account_page(conn, "default")
        assert conn.resp_body =~ ~s(data-notice="invalid_request")
      end
    end

    test "every action page: one <h1>, a specific <title>, nav with aria-current", ctx do
      titles =
        for action <- @actions, action != "org.matrix.device_delete" do
          extra = if action == "org.matrix.device_view", do: [{"device_id", ctx.s.device_id}], else: []
          body = T.account_get(q([{"action", action} | extra]), cookie: ctx.acct.cookie).resp_body
          assert length(Regex.scan(~r/<h1[\s>]/, body)) == 1, "#{action}: exactly one <h1>"
          assert body =~ ~r/<nav[^>]*aria-label="Account"/
          assert body =~ ~s(aria-current="page")
          [_, t] = Regex.run(~r/<title>([^<]+)<\/title>/, body)
          t
        end

      assert titles |> Enum.uniq() |> length() == length(titles), "page-specific titles: #{inspect(titles)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — device list (A12; Must #17)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6/A12/Must #17 — device list" do
    test "legacy (named) + OAuth (app name, escaped) + session-less device listed, sorted by last activity; foreign never", %{priv: priv} do
      cid = T.oauth_client!([@https], client_name: "<script>alert(1)</script>App")
      %{sub: sub, uid: uid} = user!()
      oauth_dev = dev()
      _s = T.oauth_device!(cid, @https, priv, sub, oauth_dev)
      legacy_dev = dev()
      _l = T.legacy_session!(uid, legacy_dev)
      Nebu.Matrix.DeviceKeyStore.upsert_device(uid, legacy_dev, display_name: "My <b>Laptop</b>", last_seen_ts: System.system_time(:millisecond))
      idle_dev = dev()
      Nebu.Matrix.DeviceKeyStore.upsert_device(uid, idle_dev, last_seen_ts: System.system_time(:millisecond) - 86_400_000)
      foreign = T.legacy_session!(T.provision_user!(), dev())
      foreign_dev = T.json(T.whoami(foreign.at))["device_id"]
      acct = T.account_session!(uid)

      conn = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie)
      T.assert_account_page(conn, "org.matrix.devices_list")
      body = conn.resp_body
      ids = Regex.scan(~r/data-role="account-device"[^>]*data-device-id="([^"]+)"/, body) |> Enum.map(&List.last/1)
      assert legacy_dev in ids and oauth_dev in ids and idle_dev in ids
      refute foreign_dev in ids
      assert Enum.find_index(ids, &(&1 == legacy_dev)) < Enum.find_index(ids, &(&1 == idle_dev)), "sorted by last_seen_ts DESC"
      refute body =~ "<script>alert(1)</script>", "app names are escaped text"
      assert body =~ "&lt;script&gt;"
      refute body =~ "<b>Laptop</b>"
      assert body =~ "Unnamed device"
      assert body =~ ~r/<table/ and body =~ ~r/<caption/ and body =~ ~s(scope="col")
    end

    test "storage failure => 503 unavailable (never 'no devices')" do
      %{uid: uid} = user!()
      acct = T.account_session!(uid)
      Application.put_env(:nebu_http, :account_matrix_repo, T.NoSuchRepo)
      T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie) |> T.assert_account_error(503, "unavailable")
    end

    test "501 devices => 500 rows + '1 more device not shown'" do
      %{uid: uid} = user!()
      acct = T.account_session!(uid)
      now_ms = System.system_time(:millisecond)

      T.sql!(
        "INSERT INTO devices (user_id, device_id, created_at, updated_at) SELECT $1, 'BULK' || g, $2, $2 FROM generate_series(1, 501) g",
        [uid, now_ms]
      )

      body = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie).resp_body
      assert length(Regex.scan(~r/data-role="account-device"/, body)) == 500
      assert body =~ "1 more device not shown"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — device deletion (A10, A11, A13; Must #14, #18-#20, #52, #53)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7/A13 — device deletion" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      other = T.oauth_device!(cid, @https, priv, sub, dev())
      {:ok, uid: uid, sub: sub, s: s, other: other}
    end

    defp delete!(acct, device_id),
      do: T.account_post("/account/devices/delete", [{"device_id", device_id}, {"csrf_token", acct.csrf}], cookie: acct.cookie)

    test "Must #18: fresh session => confirmation form; POST => 303 device_deleted; the device ends completely; others untouched", ctx do
      T.seed_device_keys!(ctx.uid, ctx.s.device_id)
      acct = T.account_session!(ctx.uid)
      confirm = T.account_get(q([{"action", "org.matrix.device_delete"}, {"device_id", ctx.s.device_id}]), cookie: acct.cookie)
      T.assert_account_page(confirm, "org.matrix.device_delete")
      assert confirm.resp_body =~ ~s(data-role="delete-device-confirm")
      assert confirm.resp_body =~ ~r/<button[^>]*type="submit"/
      keep = T.rows_snapshot(ctx.uid, ctx.other.device_id)

      conn = delete!(acct, ctx.s.device_id)
      assert conn.status == 303
      assert T.notice_of(conn) == "device_deleted"
      assert URI.parse(T.location(conn)).path == "/account"
      assert T.session_rows(ctx.uid, ctx.s.device_id) == []
      assert T.device_gone?(ctx.uid, ctx.s.device_id)
      T.assert_unknown_token(T.whoami(ctx.s.at), false)
      T.refresh(ctx.s.client_id, ctx.s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.rows_snapshot(ctx.uid, ctx.other.device_id) == keep
      assert T.whoami(ctx.other.at).status == 200

      again = delete!(acct, ctx.s.device_id)
      assert T.notice_of(again) == "device_not_found", "idempotent: a second POST => device_not_found"
    end

    test "Must #52: deleting the device of the client that opened the page: its token 401, the page keeps working", ctx do
      acct = T.account_session!(ctx.uid)
      assert delete!(acct, ctx.s.device_id).status == 303
      T.assert_unknown_token(T.whoami(ctx.s.at), false)
      T.account_get("/account", cookie: acct.cookie) |> T.assert_account_page("default")
    end

    test "a legacy device of the same user is deleted the same way (opaque token + bound JWT dead)", ctx do
      ld = dev()
      legacy = T.legacy_session!(ctx.uid, ld)
      jwt = T.bound_jwt!(ctx.priv, ctx.sub, ld)
      acct = T.account_session!(ctx.uid)
      assert T.notice_of(delete!(acct, ld)) == "device_deleted"
      assert T.whoami(legacy.at).status == 401
      assert T.whoami(jwt).status == 401
    end

    test "foreign / unknown / already deleted device id => 303 device_not_found, nothing deleted", ctx do
      foreign = T.legacy_session!(T.provision_user!(), dev())
      foreign_uid = T.json(T.whoami(foreign.at))["user_id"]
      foreign_dev = T.json(T.whoami(foreign.at))["device_id"]
      acct = T.account_session!(ctx.uid)
      before = T.world_snapshot([ctx.uid, foreign_uid])

      for id <- [foreign_dev, "UNKNOWN" <> T.rand(3)] do
        conn = delete!(acct, id)
        assert conn.status == 303 and T.notice_of(conn) == "device_not_found"
      end

      assert T.world_snapshot([ctx.uid, foreign_uid]) == before
      assert T.whoami(foreign.at).status == 200
    end

    test "Must #14: stale session => reauth link instead of the form; POST anyway => 303 stale, nothing deleted; reauth returns to the confirmation", ctx do
      acct = T.account_session!(ctx.uid, auth_time: now() - 400)
      path = q([{"action", "org.matrix.device_delete"}, {"device_id", ctx.s.device_id}])
      page = T.account_get(path, cookie: acct.cookie)
      T.assert_account_page(page, "org.matrix.device_delete")
      assert page.resp_body =~ ~s(data-role="reauth")
      refute page.resp_body =~ ~s(data-role="delete-device-confirm")

      before = T.world_snapshot([ctx.uid])
      conn = delete!(acct, ctx.s.device_id)
      assert conn.status == 303 and T.notice_of(conn) == "stale"
      assert T.world_snapshot([ctx.uid]) == before

      [_, href] = Regex.run(~r/<a[^>]*data-role="reauth"[^>]*href="([^"]+)"/, page.resp_body) || Regex.run(~r/<a[^>]*href="([^"]+)"[^>]*data-role="reauth"/, page.resp_body)
      href = String.replace(href, "&amp;", "&")
      assert URI.parse(href).path == "/account/reauth"
      flow = T.account_start!(href, cookie: acct.cookie)
      cb = T.account_finish(flow, ctx.priv, ctx.sub, extra_cookies: [{T.account_cookie_name(), acct.cookie}])
      assert cb.status == 303
      assert T.location(cb) == path, "after the re-auth the user lands on the SAME confirmation page"
      fresh = T.account_get(T.location(cb), cookie: T.account_cookie_from(cb))
      assert fresh.resp_body =~ ~s(data-role="delete-device-confirm")
      assert T.account_session_row(acct.cookie) == nil, "the stale session was rotated away"
    end

    test "end_device_session failure => 500 page server_error, device and session intact", ctx do
      acct = T.account_session!(ctx.uid)
      before = T.world_snapshot([ctx.uid])
      _remove = T.block_session_deletes!(ctx.uid)
      delete!(acct, ctx.s.device_id) |> T.assert_account_error(500, "server_error")
      assert T.world_snapshot([ctx.uid]) == before
      assert T.whoami(ctx.s.at).status == 200
    end

    test "Must #19: concurrency: the POST waits for the devices lock; the rotated-in row dies too", ctx do
      acct = T.account_session!(ctx.uid)
      row = T.row_by_at(ctx.s.at)
      new_at = T.rand(32)
      new_rt = T.rand(32)

      {:ok, task} =
        Nebu.Repo.transaction(fn ->
          T.sql!("SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [ctx.uid, ctx.s.device_id])
          task = Task.async(fn -> T.safely(fn -> delete!(acct, ctx.s.device_id).status end) end)
          T.await_lock_wait!()
          assert Task.yield(task, 0) == nil, "the deletion must wait for the devices row lock"
          T.sql!("UPDATE matrix_sessions SET revoked_at = now(), grace_until = NULL WHERE access_token_hash = $1", [row["access_token_hash"]])

          T.sql!(
            "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, session_expires_at, auth_time, auth_api, client_id, scope, oauth_code_hash, created_at) " <>
              "VALUES ($1, $2, $3, $4, $5, LEAST(now() + interval '900 seconds', $6::timestamptz), $6::timestamptz, $7, 'oauth', $8, $9, $10, now())",
            [T.token_hash(new_at), T.token_hash(new_rt), row["oidc_refresh_token"], row["user_id"], row["device_id"], row["session_expires_at"],
             row["auth_time"], row["client_id"], row["scope"], row["oauth_code_hash"]]
          )

          task
        end)

      assert {:ok, 303} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      assert T.session_rows(ctx.uid, ctx.s.device_id) == []
      T.assert_unknown_token(T.whoami(new_at), false)
    end
  end

  describe "AC7/Must #53 — a LEGACY-ONLY user signs in and signs out a legacy device" do
    test "IdP login (no OAuth session ever), device list, deletion; the opaque token is dead", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      ld = dev()
      legacy = T.legacy_session!(uid, ld)
      Nebu.Matrix.DeviceKeyStore.upsert_device(uid, ld)
      login = T.account_login!(priv, sub)
      assert login.conn.resp_body =~ ld
      conn = T.account_post("/account/devices/delete", [{"device_id", ld}, {"csrf_token", login.csrf}], cookie: login.cookie)
      assert T.notice_of(conn) == "device_deleted"
      assert T.whoami(legacy.at).status == 401
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — approval page (A15, A16; Must #30, #54, #55)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9/A16 — cross-signing reset approval page" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      s2 = T.oauth_device!(cid, @https, priv, sub, dev())
      assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "A")).status == 200
      {:ok, uid: uid, sub: sub, s: s, s2: s2}
    end

    defp challenge!(s, uid, tag) do
      conn = T.device_signing_upload(s.at, T.cross_signing_keys(uid, tag))
      assert conn.status == 401, "expected the m.oauth challenge, got #{conn.status}: #{conn.resp_body}"
      T.json(conn)["session"]
    end

    # story oauth-client-revocation SO2: approving a reset needs the strict fetch metadata of a user-clicked form submit
    # (a real browser sends all four headers); decline keeps the lenient rules
    defp act!(acct, verb, sid) do
      headers = if verb == "approve", do: T.strict_fetch_headers(), else: []
      T.account_post("/account/cross_signing_reset/" <> verb, [{"session_id", sid}, {"csrf_token", acct.csrf}], cookie: acct.cookie, headers: headers)
    end

    test "Must #30: lists only the user's pending requests with the requesting device; none => the no-pending text", ctx do
      acct = T.account_session!(ctx.uid)
      empty = T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie)
      T.assert_account_page(empty, "org.matrix.cross_signing_reset")
      assert empty.resp_body =~ "There is no pending request"

      sid = challenge!(ctx.s, ctx.uid, "B")
      page = T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie)
      assert page.resp_body =~ ~s(data-role="reset-request")
      assert page.resp_body =~ ctx.s.device_id
      assert page.resp_body =~ ~s(data-role="approve-reset") and page.resp_body =~ ~s(data-role="decline-reset")
      assert page.resp_body =~ sid, "the forms name the concrete UIA session (request-first)"

      other_acct = T.account_session!(T.provision_user!())
      refute T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: other_acct.cookie).resp_body =~ ctx.s.device_id
    end

    test "storage failure => 503 page", ctx do
      acct = T.account_session!(ctx.uid)
      Application.put_env(:nebu_http, :account_matrix_repo, T.NoSuchRepo)
      T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie) |> T.assert_account_error(503, "unavailable")
    end

    test "approve (fresh, CSRF) => 303 reset_approved; stage_complete, expires_at <= now + 600; twice => reset_not_found", ctx do
      sid = challenge!(ctx.s, ctx.uid, "C")
      acct = T.account_session!(ctx.uid)
      conn = act!(acct, "approve", sid)
      assert conn.status == 303 and T.notice_of(conn) == "reset_approved"
      row = T.uia_row(sid)
      assert row["stage_complete"] == true
      assert row["expires_at"] <= now() + 600
      assert T.notice_of(act!(acct, "approve", sid)) == "reset_not_found"
    end

    test "unknown / foreign / expired / consumed / non-reset session => reset_not_found, nothing changed", ctx do
      acct = T.account_session!(ctx.uid)
      foreign_uid = T.provision_user!()
      foreign_sid = Nebu.Matrix.Uia.mint_session(foreign_uid, "cross_signing_reset", "{}")
      delete_sid = Nebu.Matrix.Uia.mint_session(ctx.uid, "delete_devices", "{}")
      expired_sid = challenge!(ctx.s2, ctx.uid, "D")
      T.sql!("UPDATE uia_sessions SET expires_at = $2 WHERE session_id = $1", [expired_sid, now() - 1])

      for sid <- ["nope-" <> T.rand(), foreign_sid, delete_sid, expired_sid] do
        before = T.uia_row(sid)
        assert T.notice_of(act!(acct, "approve", sid)) == "reset_not_found"
        assert T.uia_row(sid) == before
      end
    end

    test "Must #55: approving request A does not authorise request B of another device", ctx do
      a = challenge!(ctx.s, ctx.uid, "E")
      b = challenge!(ctx.s2, ctx.uid, "F")
      acct = T.account_session!(ctx.uid)
      assert T.notice_of(act!(acct, "approve", a)) == "reset_approved"
      assert T.uia_row(b)["stage_complete"] == false
    end

    test "decline => consumed, reset_declined; the client's next attempt gets a new challenge", ctx do
      sid = challenge!(ctx.s, ctx.uid, "G")
      acct = T.account_session!(ctx.uid)
      assert T.notice_of(act!(acct, "decline", sid)) == "reset_declined"
      assert T.uia_row(sid)["consumed"] == true
      retry = T.device_signing_upload(ctx.s.at, Map.put(T.cross_signing_keys(ctx.uid, "G"), "auth", %{"session" => sid}))
      assert retry.status == 401
      refute T.json(retry)["session"] == sid
    end

    test "stale session => reauth link instead of the forms; POST anyway => stale, nothing changed", ctx do
      sid = challenge!(ctx.s, ctx.uid, "H")
      acct = T.account_session!(ctx.uid, auth_time: now() - 400)
      page = T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie)
      assert page.resp_body =~ ~s(data-role="reauth")
      refute page.resp_body =~ ~s(data-role="approve-reset")
      before = T.uia_row(sid)
      assert T.notice_of(act!(acct, "approve", sid)) == "stale"
      assert T.uia_row(sid) == before
    end

    test "Must #54: the client's UIA session expired (900 s after mint) => not listed; a stale approve => reset_not_found; retry gets a new challenge", ctx do
      sid = challenge!(ctx.s, ctx.uid, "I")
      T.sql!("UPDATE uia_sessions SET expires_at = $2 WHERE session_id = $1", [sid, now() - 1])
      acct = T.account_session!(ctx.uid)
      refute T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie).resp_body =~ ~s(data-role="reset-request")
      assert T.notice_of(act!(acct, "approve", sid)) == "reset_not_found"
      retry = T.device_signing_upload(ctx.s.at, Map.put(T.cross_signing_keys(ctx.uid, "I"), "auth", %{"session" => sid}))
      assert retry.status == 401
      refute T.json(retry)["session"] == sid
    end
  end
  # ════════════════════════════════════════════════════════════════════════════
  # story oauth-authorize-freshness — AC11 / FR14 (gate y, fail closed): a session WITHOUT auth_time
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11/FR14 — NULL auth_time: destructive actions are unavailable, viewing works, no reauth loop" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      other = T.oauth_device!(cid, @https, priv, sub, dev())
      assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "N")).status == 200
      {:ok, uid: uid, sub: sub, s: s, other: other}
    end

    @freshness_text "Your sign-in provider does not report when you last signed in, so Nebu cannot confirm it is you. Signing out devices and approving key resets are not available here. Ask your administrator."

    test "the notice code exists in AccountPages.notice_codes/0", %{} do
      assert "freshness_unavailable" in Nebu.OAuth.AccountPages.notice_codes()
    end

    test "device delete page: the notice, its text, NO reauth link, NO confirmation form; the device list still works", ctx do
      acct = T.account_session!(ctx.uid, auth_time: nil)
      page = T.account_get(q([{"action", "org.matrix.device_delete"}, {"device_id", ctx.s.device_id}]), cookie: acct.cookie)
      T.assert_account_page(page, "org.matrix.device_delete")
      assert page.resp_body =~ ~s(data-notice="freshness_unavailable")
      assert page.resp_body =~ @freshness_text
      refute page.resp_body =~ ~s(data-role="reauth"), "a reauth link would loop: the IdP will not report auth_time next time either"
      refute page.resp_body =~ ~s(data-role="delete-device-confirm")
      refute page.resp_body =~ "/account/reauth"

      list = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie)
      T.assert_account_page(list, "org.matrix.devices_list")
      assert list.resp_body =~ ctx.s.device_id
      assert list.resp_body =~ ctx.other.device_id
    end

    test "POST delete => 303 with the notice; the device, its tokens and sessions are untouched", ctx do
      acct = T.account_session!(ctx.uid, auth_time: nil)
      before = T.world_snapshot([ctx.uid])
      conn = delete!(acct, ctx.s.device_id)
      assert conn.status == 303
      assert T.notice_of(conn) == "freshness_unavailable"
      assert T.world_snapshot([ctx.uid]) == before
      assert T.whoami(ctx.s.at).status == 200
      refute T.device_gone?(ctx.uid, ctx.s.device_id)
    end

    test "reset page: notice, no reauth link, no forms; POST approve / decline => 303 notice, UIA survives", ctx do
      sid = challenge!(ctx.s, ctx.uid, "NB")
      acct = T.account_session!(ctx.uid, auth_time: nil)
      page = T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie)
      T.assert_account_page(page, "org.matrix.cross_signing_reset")
      assert page.resp_body =~ ~s(data-notice="freshness_unavailable")
      assert page.resp_body =~ @freshness_text
      refute page.resp_body =~ ~s(data-role="reauth")
      refute page.resp_body =~ ~s(data-role="approve-reset")
      refute page.resp_body =~ ~s(data-role="decline-reset")

      before = T.uia_row(sid)
      for verb <- ["approve", "decline"] do
        conn = act!(acct, verb, sid)
        assert conn.status == 303
        assert T.notice_of(conn) == "freshness_unavailable"
      end

      assert T.uia_row(sid) == before, "the pending request is neither approved nor declined"
    end

    test "the destructive POST still checks CSRF first (a forged POST is a 403, not the notice)", ctx do
      acct = T.account_session!(ctx.uid, auth_time: nil)
      conn = T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", "wrong"}], cookie: acct.cookie)
      T.assert_account_error(conn, 403, "forbidden")
    end

    test "end to end through the real login: an IdP without auth_time => the delete page says so, deleting does nothing", %{priv: priv} = ctx do
      login = T.account_login!(priv, ctx.sub, claims: %{"auth_time" => nil})
      assert T.account_session_row(login.cookie)["auth_time"] == nil

      page = T.account_get(q([{"action", "org.matrix.device_delete"}, {"device_id", ctx.s.device_id}]), cookie: login.cookie)
      assert page.resp_body =~ ~s(data-notice="freshness_unavailable")
      refute page.resp_body =~ ~s(data-role="reauth")

      conn = T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", login.csrf}], cookie: login.cookie)
      assert T.notice_of(conn) == "freshness_unavailable"
      assert T.whoami(ctx.s.at).status == 200
    end

    test "regression: a FRESH session still deletes (story-6 fresh path unchanged)", ctx do
      acct = T.account_session!(ctx.uid, auth_time: now())
      conn = delete!(acct, ctx.s.device_id)
      assert T.notice_of(conn) == "device_deleted"
    end

    test "regression: a STALE claim at the callback is still 403 reauth_failed (unchanged)", %{priv: priv} = ctx do
      cb = T.account_finish(T.account_start!(), priv, ctx.sub, claims: %{"auth_time" => now() - 3600})
      T.assert_account_error(cb, 403, "reauth_failed")
    end
  end
end
