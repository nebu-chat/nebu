defmodule Nebu.OAuth.OAuthTokenCodeGrantTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint` (story 3), AC5-AC8 + AC12 (code
  grant id_token): `POST /oauth2/token` with `grant_type=authorization_code`, driven through the
  REAL story-2 flow (authorize -> IdP stub -> shared callback -> code) and, for deterministic edge
  cases, directly inserted `oauth_codes` rows (`T.insert_code!/2`).

  Covers T6 (per_refresh without IdP RT fails closed), T7 (device reuse revokes every earlier
  credential of the device, keeps the device + keys), T8 (proof-bound code-reuse revocation),
  T14-T16 (scope echo, id_token when/claims), T19 (error-aware is_active), T30 (`last_used_at`),
  T33 (`expires_in` vs the stored `expires_at`); Must-test #4-#12, #23, #25, #35.

  Red today: `/oauth2/token` is not routed (the router's plain 404 "not found"), migration 000042
  (`matrix_sessions.auth_api/client_id/scope/session_expires_at/oauth_code_hash`,
  `oauth_signing_keys`) does not exist, and neither do `Nebu.OAuth.Token`, the signing-key store,
  `GET /oauth2/jwks` or the `Nebu.Matrix.oauth_*` facade.

  Cluster safety: single use is the story-2 atomic UPDATE (N parallel redemptions => exactly one
  200). No sleeps: expiry is produced by inserting an already expired code row.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @https2 "https://app.example.com/other"
  @loop_registered "http://localhost/cb"
  @loop "http://localhost:53682/cb"
  @t6_description "Sign-in cannot be completed: the server is not configured for refreshable sessions."

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()

      for k <- [:oauth_repo, :oauth_session_repo, :oauth_user_active_override],
          do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https, @https2, @loop_registered])}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp code_row(code) do
    case T.sql!(
           "SELECT *, extract(epoch FROM auth_time)::bigint AS auth_time_s FROM oauth_codes WHERE code_hash = $1",
           [T.sha256_hex(code)]
         ) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  defp assert_code_used(code) do
    row = code_row(code)
    assert row, "the code row must still exist"
    assert row["used_at"], "the code stays USED after a failed redemption (T9)"
  end

  defp assert_no_session(user_id, device_id),
    do: assert(T.session_rows(user_id, device_id) == [], "no matrix_sessions row may be created")

  defp fresh_code(cid, attrs \\ %{}), do: T.insert_code!(cid, Map.merge(%{user_id: T.provision_user!()}, Map.new(attrs)))

  defp legacy_refresh(rt) do
    Plug.Test.conn(:post, "/_matrix/client/v3/refresh", Jason.encode!(%{"refresh_token" => rt}))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  defp assert_unknown_token(conn) do
    assert conn.status == 401, "expected 401, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    body = Jason.decode!(conn.resp_body)
    assert body["errcode"] == "M_UNKNOWN_TOKEN"
    body
  end

  defp epoch(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp stored_lifetime(at) do
    %{rows: [[secs]]} =
      T.sql!("SELECT extract(epoch FROM expires_at - created_at)::float8 FROM matrix_sessions WHERE access_token_hash = $1", [
        T.token_hash(at)
      ])

    secs
  end

  defp valid_format_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # ════════════════════════════════════════════════════════════════════════════
  # AC5/AC8 — success shapes (real story-2 flow)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5/AC8/T14 — success shapes (Must #11, #12)" do
    test "stable prefix: 200 RFC 6749 5.1 body, scope echoed verbatim, no id_token", %{cid: cid, priv: priv} do
      grant = T.flow_code!(cid, @https, priv)
      body = grant |> T.redeem() |> T.assert_token_success()
      assert body["scope"] == T.matrix_scope(T.stable_prefix(), grant.device_id)
      assert body["scope"] == grant.scope
      refute Map.has_key?(body, "id_token"), "no openid => no id_token (T15)"
    end

    test "matrix-js-sdk 41.3.0 shape (openid + unstable prefix + nonce + response_mode=query): id_token, scope echoes the unstable prefix (AC12)",
         %{cid: cid, priv: priv} do
      nonce = "js-nonce-" <> T.rand()

      grant =
        T.flow_code!(cid, @https, priv, authorize: %{"scope" => T.js_sdk_scope(), "nonce" => nonce, "response_mode" => "query"})

      body = grant |> T.redeem() |> T.assert_token_success(id_token: true)
      assert body["scope"] == T.js_sdk_scope(), "T14: the stored granted scope with the REQUEST's prefix"
      assert is_binary(body["id_token"])
    end

    test "Dart SDK shape (unstable prefix, no openid) on a loopback port: no id_token", %{cid: cid, priv: priv} do
      scope = T.matrix_scope(T.unstable_prefix(), "ABCDEFGHIJ")
      grant = T.flow_code!(cid, @loop, priv, authorize: %{"scope" => scope})
      assert grant.redirect_uri == @loop
      body = grant |> T.redeem() |> T.assert_token_success()
      assert body["scope"] == scope
      refute Map.has_key?(body, "id_token")
    end

    test "the access token authenticates /whoami (user_id + device_id + is_guest false) and /devices lists the device",
         %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      who = T.whoami(s.at)
      assert who.status == 200, "whoami with the new access token: #{who.status} #{who.resp_body}"
      assert Jason.decode!(who.resp_body) == %{"user_id" => s.user_id, "device_id" => s.device_id, "is_guest" => false}

      devices = T.matrix_request(:get, "/_matrix/client/v3/devices", s.at)
      assert devices.status == 200
      ids = devices.resp_body |> Jason.decode!() |> Map.fetch!("devices") |> Enum.map(& &1["device_id"])
      assert s.device_id in ids, "AC7: the devices row exists after issuance"
    end

    test "the session row: auth_api oauth, client_id, granted scope, code hash, two expiries, IdP RT ciphertext, auth_time; only hashes stored",
         %{cid: cid, priv: priv} do
      grant = T.flow_code!(cid, @https, priv)
      code = code_row(grant.code)
      body = T.redeem!(grant)
      at = body["access_token"]
      rt = body["refresh_token"]

      row = T.row_by_at(at)
      assert row, "row keyed by access_token_hash = sha256_hex(access_token)"
      assert row["refresh_token_hash"] == T.token_hash(rt)
      assert row["auth_api"] == "oauth"
      assert row["client_id"] == cid
      assert row["scope"] == body["scope"]
      assert row["oauth_code_hash"] == T.sha256_hex(grant.code), "T8: the code hash is stored on the session"
      assert row["revoked_at"] == nil
      assert row["user_id"] == grant.user_id
      assert row["device_id"] == grant.device_id

      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      now = System.system_time(:second)
      sess_exp = epoch(row["session_expires_at"])
      assert sess_exp >= now + ttl - 60 and sess_exp <= now + ttl + 5, "T3: session_expires_at = now + session TTL"
      assert DateTime.compare(row["expires_at"], row["session_expires_at"]) != :gt, "expires_at <= session_expires_at"

      assert row["oidc_refresh_token"] == code["idp_rt_enc"], "T5: the code row's ciphertext is stored verbatim"
      assert row["oidc_refresh_token"] != grant.idp_rt
      assert {:ok, grant.idp_rt} == Nebu.Web.SecretBox.decrypt(row["oidc_refresh_token"])
      assert row["auth_time"] == code["auth_time_s"], "auth_time (BIGINT seconds) from the code row (Trap 18)"

      for {col, v} <- row, is_binary(v) do
        refute v == at, "plaintext access token in column #{col}"
        refute v == rt, "plaintext refresh token in column #{col}"
        refute v == grant.code, "plaintext code in column #{col}"
        refute v == grant.idp_rt, "plaintext IdP refresh token in column #{col}"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T4 / T33 — access-token TTL and expires_in
  # ════════════════════════════════════════════════════════════════════════════

  describe "T4/T33 — expires_in (Must #11, #35)" do
    test "default TTL: 890 <= expires_in <= 900 and equal to the stored expires_at - created_at", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      assert s.body["expires_in"] >= 890 and s.body["expires_in"] <= 900
      stored = stored_lifetime(s.at)
      assert s.body["expires_in"] <= stored, "T33: never advertise more than the server-side lifetime"
      assert stored - s.body["expires_in"] < 2, "T33: expires_in computed from the same now() as expires_at"
      assert T.whoami(s.at).status == 200, "no 401 before expires_in elapsed"
    end

    test "oauth_access_token_ttl_seconds = 120 is honoured", %{cid: cid, priv: priv} do
      T.enable_oauth(T.issuer(), %{access_token_ttl_seconds: "120"})
      s = T.session!(cid, @https, priv)
      assert s.body["expires_in"] <= 120 and s.body["expires_in"] >= 110
      assert stored_lifetime(s.at) - s.body["expires_in"] < 2
    end

    for bad <- ["30", "7200", "abc"] do
      test "out-of-range TTL #{inspect(bad)} falls back to 900", %{cid: cid, priv: priv} do
        T.enable_oauth(T.issuer(), %{access_token_ttl_seconds: unquote(bad)})
        s = T.session!(cid, @https, priv)
        assert s.body["expires_in"] > 120 and s.body["expires_in"] <= 900
        assert s.body["expires_in"] >= 890
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 / T16 — id_token on the code grant
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12/T16 — id_token claims and signature (Must #25)" do
    test "verifies with the JWKS key of its kid (ES256); header exactly alg/kid/typ; exact claim set", %{cid: cid, priv: priv} do
      nonce = "js-nonce-" <> T.rand()

      grant =
        T.flow_code!(cid, @https, priv, authorize: %{"scope" => T.js_sdk_scope(), "nonce" => nonce, "response_mode" => "query"})

      code = code_row(grant.code)
      body = grant |> T.redeem() |> T.assert_token_success(id_token: true)
      {header, claims} = T.verify_id_token!(body["id_token"])

      assert Enum.sort(Map.keys(header)) == ~w(alg kid typ)
      assert header["alg"] == "ES256"
      assert header["typ"] == "JWT"
      assert is_binary(header["kid"]) and header["kid"] != ""

      assert Enum.sort(Map.keys(claims)) == ~w(aud auth_time exp iat iss nonce sub), "no other claims (data minimization)"

      issuer = T.get_metadata() |> T.json() |> Map.fetch!("issuer")
      assert claims["iss"] == issuer, "iss byte-equal to the auth_metadata issuer (js-sdk compares exactly)"
      assert claims["aud"] == cid, "aud is the client_id as a STRING"
      assert is_binary(claims["aud"])

      who = body["access_token"] |> T.whoami() |> Map.fetch!(:resp_body) |> Jason.decode!()
      assert claims["sub"] == who["user_id"]
      assert claims["sub"] == grant.user_id
      assert claims["nonce"] == nonce
      assert claims["auth_time"] == code["auth_time_s"]

      now = System.system_time(:second)
      assert is_integer(claims["iat"]) and abs(claims["iat"] - now) <= 10
      assert claims["exp"] - claims["iat"] == 300
    end

    test "openid without a client nonce: the id_token carries no nonce claim", %{cid: cid, priv: priv} do
      grant = T.flow_code!(cid, @https, priv, authorize: %{"scope" => T.js_sdk_scope()})
      body = grant |> T.redeem() |> T.assert_token_success(id_token: true)
      {_header, claims} = T.verify_id_token!(body["id_token"])
      refute Map.has_key?(claims, "nonce")
      assert Enum.sort(Map.keys(claims)) == ~w(aud auth_time exp iat iss sub)
    end

    test "openid with the stable prefix also yields an id_token; no openid never does", %{cid: cid, priv: priv} do
      with_openid = T.flow_code!(cid, @https, priv, authorize: %{"scope" => "openid " <> T.matrix_scope()})
      body = with_openid |> T.redeem() |> T.assert_token_success(id_token: true)
      assert body["scope"] == "openid " <> T.matrix_scope()

      without = T.flow_code!(cid, @https, priv)
      refute without |> T.redeem() |> T.assert_token_success() |> Map.has_key?("id_token")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — every invalid_grant cause (none creates a session; the code stays used)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5 — unknown / malformed / expired / used codes (Must #6, #8)" do
    test "an unknown code => invalid_grant", %{cid: cid} do
      g = fresh_code(cid)
      unknown = %{g | code: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
      T.redeem(unknown) |> T.assert_token_error(400, "invalid_grant")
      assert_no_session(g.user_id, g.device_id)
    end

    test "a malformed code => invalid_grant", %{cid: cid} do
      g = fresh_code(cid)
      T.redeem(%{g | code: "short"}) |> T.assert_token_error(400, "invalid_grant")
      assert_no_session(g.user_id, g.device_id)
    end

    test "an expired code (> 60 s, inserted already expired) => invalid_grant, no session", %{cid: cid} do
      g = fresh_code(cid, created_sql: "now() - interval '120 seconds'", expires_sql: "now() - interval '60 seconds'")
      T.redeem(g) |> T.assert_token_error(400, "invalid_grant")
      assert_no_session(g.user_id, g.device_id)
    end

    test "a code burned by a failed first redemption (T9) => a correct second presentation is invalid_grant", %{cid: cid} do
      g = fresh_code(cid)
      T.redeem(g, %{"code_verifier" => valid_format_verifier()}) |> T.assert_token_error(400, "invalid_grant")
      assert_code_used(g.code)
      T.redeem(g) |> T.assert_token_error(400, "invalid_grant")
      assert_no_session(g.user_id, g.device_id)
    end

    test "second redemption of a successfully redeemed code => invalid_grant (RFC 6749 4.1.2 MUST)", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      T.redeem(s) |> T.assert_token_error(400, "invalid_grant")
    end

    test "the code of another client (A's code with B's client_id) => invalid_grant", %{cid: cid, priv: priv} do
      other = T.oauth_client!([@https])
      g = T.flow_code!(cid, @https, priv)
      T.redeem(%{g | client_id: other}) |> T.assert_token_error(400, "invalid_grant")
      assert_code_used(g.code)
      assert_no_session(g.user_id, g.device_id)
    end
  end

  describe "AC5.3 — redirect_uri byte-equal (Must #5)" do
    for {label, presented} <- [
          {"another loopback port", "http://localhost:53683/cb"},
          {"the registered loopback uri without the port actually used", "http://localhost/cb"},
          {"a trailing slash", "http://localhost:53682/cb/"},
          {"a case change", "http://LOCALHOST:53682/cb"}
        ] do
      test "loopback code presented with #{label} => invalid_grant", %{cid: cid} do
        g = fresh_code(cid, redirect_uri: @loop)
        T.redeem(g, %{"redirect_uri" => unquote(presented)}) |> T.assert_token_error(400, "invalid_grant")
        assert_code_used(g.code)
        assert_no_session(g.user_id, g.device_id)
      end
    end

    for {label, presented} <- [
          {"another registered uri", @https2},
          {"a trailing slash", @https <> "/"},
          {"a case change of the path", "https://app.example.com/CB"}
        ] do
      test "https code presented with #{label} => invalid_grant", %{cid: cid} do
        g = fresh_code(cid, redirect_uri: @https)
        T.redeem(g, %{"redirect_uri" => unquote(presented)}) |> T.assert_token_error(400, "invalid_grant")
        assert_no_session(g.user_id, g.device_id)
      end
    end

    test "a percent-encoded redirect_uri (even %2E for dots) equals the stored decoded one => 200", %{cid: cid} do
      g = fresh_code(cid, redirect_uri: @https)

      raw =
        "grant_type=authorization_code&code=#{g.code}&redirect_uri=https%3A%2F%2Fapp%2Eexample%2Ecom%2Fcb" <>
          "&code_verifier=#{g.verifier}&client_id=#{URI.encode_www_form(cid)}"

      T.token_request(raw) |> T.assert_token_success()
    end

    test "the exact loopback port used at authorize succeeds", %{cid: cid} do
      g = fresh_code(cid, redirect_uri: @loop)
      T.redeem(g) |> T.assert_token_success()
    end
  end

  describe "AC5.4 — PKCE S256 (Must #4)" do
    test "the correct verifier succeeds", %{cid: cid} do
      g = fresh_code(cid)
      T.redeem(g) |> T.assert_token_success()
    end

    test "missing code_verifier => invalid_request", %{cid: cid} do
      g = fresh_code(cid)
      T.redeem(g, %{"code_verifier" => nil}) |> T.assert_token_error(400, "invalid_request")
      assert_no_session(g.user_id, g.device_id)
    end

    test "empty code_verifier= (empty = omitted) => invalid_request", %{cid: cid} do
      g = fresh_code(cid)
      T.redeem(g, %{"code_verifier" => ""}) |> T.assert_token_error(400, "invalid_request")
      assert_no_session(g.user_id, g.device_id)
    end

    for {label, verifier} <- [
          {"a wrong (well-formed) verifier", :wrong},
          {"a 42-char verifier", String.duplicate("a", 42)},
          {"a 129-char verifier", String.duplicate("a", 129)},
          {"a verifier with a forbidden character", String.duplicate("a", 42) <> "+"},
          {"the plain challenge as verifier (plain method against S256)", :challenge}
        ] do
      test "#{label} => invalid_grant, no session, code burned", %{cid: cid} do
        g = fresh_code(cid)

        v =
          case unquote(verifier) do
            :wrong -> valid_format_verifier()
            :challenge -> g.challenge
            literal -> literal
          end

        T.redeem(g, %{"code_verifier" => v}) |> T.assert_token_error(400, "invalid_grant")
        assert_code_used(g.code)
        assert_no_session(g.user_id, g.device_id)
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T6 — per_refresh without an IdP refresh token fails closed
  # ════════════════════════════════════════════════════════════════════════════

  describe "T6 — per_refresh + code without IdP RT (Must #23)" do
    # story oauth-authorize-freshness (FR13, gate l): the real flow with `per_refresh` and NO IdP refresh
    # token is now refused at the callback (a server_error redirect, see oauth_idp_callback_test.exs, AC10).
    # T6 at the token endpoint stays as the second line of defence for a code that exists anyway (a code
    # minted before an upgrade / by an older node), so it is exercised with a directly inserted code.
    test "=> invalid_grant with the fixed description, ONE warning naming the fix, no session", %{cid: cid} do
      g = fresh_code(cid, idp_rt: nil)
      assert code_row(g.code)["idp_rt_enc"] == nil

      log = capture_log(fn -> send(self(), {:resp, T.redeem(g)}) end)
      assert_received {:resp, conn}
      T.assert_token_error(conn, 400, "invalid_grant")
      assert T.json(conn)["error_description"] == @t6_description

      warnings =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/matrix_oidc_refresh_mode=offline|oauth_idp_revalidation=off/))

      assert length(warnings) == 1, "exactly one WARNING naming the fix, got: #{inspect(warnings)}"
      assert log =~ "[warning]"
      assert_no_session(g.user_id, g.device_id)
    end

    test "a directly inserted code without IdP RT behaves the same (default mode is per_refresh)", %{cid: cid} do
      g = fresh_code(cid, idp_rt: nil)
      conn = T.redeem(g)
      T.assert_token_error(conn, 400, "invalid_grant")
      assert T.json(conn)["error_description"] == @t6_description
    end

    test "an unknown idp_revalidation value is fail safe (= per_refresh)", %{cid: cid} do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "bogus"})
      g = fresh_code(cid, idp_rt: nil)
      T.redeem(g) |> T.assert_token_error(400, "invalid_grant")
    end

    test "mode off: the same situation succeeds; oidc_refresh_token stays NULL", %{cid: cid, priv: priv} do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "off"})
      g = T.flow_code!(cid, @https, priv, idp_rt: nil)
      body = g |> T.redeem() |> T.assert_token_success()
      assert T.row_by_at(body["access_token"])["oidc_refresh_token"] == nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T19 / AC5.6-7 — deactivated user, DB errors, signing key unavailable
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.7/T19 — user state and transient failures (Must #9, Trap 5)" do
    test "user deactivated between callback and token request => invalid_grant, no session", %{cid: cid, priv: priv} do
      g = T.flow_code!(cid, @https, priv)
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [g.user_id])
      T.redeem(g) |> T.assert_token_error(400, "invalid_grant")
      assert_no_session(g.user_id, g.device_id)
    end

    test "an unknown user (code row for a never provisioned user) => invalid_grant", %{cid: cid} do
      g = T.insert_code!(cid, user_id: T.user_id_for(%{"sub" => T.unique_sub()}))
      T.redeem(g) |> T.assert_token_error(400, "invalid_grant")
      assert_no_session(g.user_id, g.device_id)
    end

    test "DB error during the is_active check (:oauth_user_active_override) => 503 {} + Retry-After, no session", %{cid: cid} do
      g = fresh_code(cid)
      T.put_env_scoped(:oauth_user_active_override, fn _uid -> {:error, :db} end)
      T.redeem(g) |> T.assert_token_5xx()
      assert_no_session(g.user_id, g.device_id)
    end

    test "the Matrix session store unavailable (:oauth_session_repo NoSuchRepo) => 503 {}, no session", %{cid: cid} do
      g = fresh_code(cid)
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      T.redeem(g) |> T.assert_token_5xx()
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert_no_session(g.user_id, g.device_id)
    end

    test "the code store unavailable (:oauth_repo NoSuchRepo) => 503 {}", %{cid: cid} do
      g = fresh_code(cid)
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      T.redeem(g) |> T.assert_token_5xx()
      Application.delete_env(:nebu_http, :oauth_repo)
      assert_no_session(g.user_id, g.device_id)
    end

    test "signing key unavailable (SecretBox without secret) for an openid code => 503 {} and NO orphan session", %{cid: cid} do
      g = fresh_code(cid, openid: true)
      # test review (a): empty the key table first so no per-node cache of a decoded key can hide
      # the failure: the request must GENERATE (encrypt) a key and SecretBox has no secret.
      T.reset_signing_keys!()
      secret = Application.get_env(:nebu_http, :admin_secret_at_rest)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)

      conn =
        try do
          T.redeem(g)
        after
          Application.put_env(:nebu_http, :admin_secret_at_rest, secret)
        end

      T.assert_token_5xx(conn)
      assert_no_session(g.user_id, g.device_id)
      assert_code_used(g.code)
    end

    test "a non-openid code needs no SecretBox at issuance (the IdP RT ciphertext is copied, not decrypted) => 200", %{cid: cid} do
      g = fresh_code(cid)
      secret = Application.get_env(:nebu_http, :admin_secret_at_rest)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)

      conn =
        try do
          T.redeem(g)
        after
          Application.put_env(:nebu_http, :admin_secret_at_rest, secret)
        end

      T.assert_token_success(conn)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T7 — device reuse
  # ════════════════════════════════════════════════════════════════════════════

  describe "T7 — device reuse revokes every earlier credential of the device (Must #10)" do
    test "a prior LEGACY opaque session of the same (user, device) is dead afterwards", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      legacy = T.legacy_session!(uid, "AbCdEfGhIj")
      assert T.whoami(legacy.at).status == 200

      s = T.session!(cid, @https, priv, sub: sub)
      assert s.user_id == uid and s.device_id == "AbCdEfGhIj"

      body = legacy.at |> T.whoami() |> assert_unknown_token()
      refute body["soft_logout"] == true, "a destroyed credential is not a soft logout"
      assert T.row_by_rt(legacy.rt) == nil
      assert legacy_refresh(legacy.rt).status == 401
      assert [row] = T.active_rows(uid, "AbCdEfGhIj")
      assert row["access_token_hash"] == T.token_hash(s.at)
      assert length(T.session_rows(uid, "AbCdEfGhIj")) == 1, "every earlier row of the device is DELETED"
    end

    test "a prior OAuth session of the same device is dead afterwards (AT 401, RT invalid_grant)", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      s1 = T.session!(cid, @https, priv, sub: sub)
      s2 = T.session!(cid, @https, priv, sub: sub)
      assert s1.device_id == s2.device_id

      assert_unknown_token(T.whoami(s1.at))
      T.refresh(cid, s1.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.whoami(s2.at).status == 200
      assert [_] = T.active_rows(s2.user_id, s2.device_id)
    end

    test "a prior raw-JWT binding of the device is denylisted (T25 a); device row and device keys survive; another user's same device id is untouched",
         %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      dev = "AbCdEfGhIj"
      jwt = T.bound_jwt!(priv, sub, dev)
      before = T.whoami(jwt)
      assert before.status == 200
      assert Jason.decode!(before.resp_body)["device_id"] == dev

      :ok =
        Nebu.Matrix.DeviceKeyStore.put_device_keys(uid, dev, %{
          "user_id" => uid,
          "device_id" => dev,
          "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
          "keys" => %{"curve25519:#{dev}" => "atdd-curve-key"}
        })

      other_uid = T.provision_user!()
      other = T.legacy_session!(other_uid, dev)

      s = T.session!(cid, @https, priv, sub: sub)
      assert s.device_id == dev

      assert_unknown_token(T.whoami(jwt))

      assert %{rows: [[1]]} = T.sql!("SELECT count(*)::int FROM devices WHERE user_id = $1 AND device_id = $2", [uid, dev])
      assert %{rows: [[1]]} = T.sql!("SELECT count(*)::int FROM device_keys WHERE user_id = $1 AND device_id = $2", [uid, dev]),
             "E2EE key material of a reused device is KEPT"

      assert T.whoami(other.at).status == 200, "another user's device with the same id is untouched"
      assert T.whoami(s.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 / T8 — code reuse (proof-bound revocation)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6/T8 — code reuse (Must #7)" do
    test "reuse WITH the valid verifier/redirect/client => invalid_grant AND the derived session is revoked", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      assert T.whoami(s.at).status == 200

      log = capture_log(fn -> send(self(), {:resp, T.redeem(s)}) end)
      assert_received {:resp, conn}
      T.assert_token_error(conn, 400, "invalid_grant")
      assert log =~ "authorization code reused"

      assert_unknown_token(T.whoami(s.at))
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "review cycle 1 (MINOR 3): a failing revocation is logged as WARNING (no secrets); the reused code is still invalid_grant",
         %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      remove = T.block_session_deletes!(s.user_id)

      log = capture_log(fn -> send(self(), {:resp, T.redeem(s)}) end)
      assert_received {:resp, conn}
      T.assert_token_error(conn, 400, "invalid_grant")

      assert log =~ "[warning]" and log =~ "revocation FAILED"
      T.refute_secrets_in_log(log, %{code: s.code, verifier: s.verifier, at: s.at, rt: s.rt})
      assert T.whoami(s.at).status == 200, "nothing was revoked"

      remove.()
    end

    test "the derived session is found after it was refreshed once (the code hash is copied on rotation)", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      T.idp_refresh_ok(s.sub)
      r = T.refresh!(cid, s.rt)
      assert T.whoami(r["access_token"]).status == 200
      assert T.row_by_at(r["access_token"])["oauth_code_hash"] == T.sha256_hex(s.code)

      T.redeem(s) |> T.assert_token_error(400, "invalid_grant")
      assert_unknown_token(T.whoami(r["access_token"]))
      T.refresh(cid, r["refresh_token"]) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "reuse WITHOUT a valid verifier => invalid_grant and NOTHING is revoked", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv)
      snap = T.rows_snapshot(s.user_id, s.device_id)

      T.redeem(s, %{"code_verifier" => valid_format_verifier()}) |> T.assert_token_error(400, "invalid_grant")
      T.redeem(s, %{"code_verifier" => nil}) |> T.assert_token_error(400, "invalid_request")

      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      assert T.whoami(s.at).status == 200
    end

    test "reuse with a wrong redirect_uri or another client's id => invalid_grant, nothing revoked", %{cid: cid, priv: priv} do
      other = T.oauth_client!([@https])
      s = T.session!(cid, @https, priv)
      snap = T.rows_snapshot(s.user_id, s.device_id)

      T.redeem(s, %{"redirect_uri" => @https <> "/"}) |> T.assert_token_error(400, "invalid_grant")
      T.redeem(%{s | client_id: other}) |> T.assert_token_error(400, "invalid_grant")

      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      assert T.whoami(s.at).status == 200
    end

    test "an unrelated earlier session of the same device is never the 'derived' one", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      s1 = T.session!(cid, @https, priv, sub: sub)
      s2 = T.session!(cid, @https, priv, sub: sub)
      s3 = T.session!(cid, @https, priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "OtherDevIc")})
      assert s3.device_id == "OtherDevIc"

      # Row inspection: s1's rows were deleted by T7, so no row carries s1's code hash any more.
      assert %{rows: [[0]]} =
               T.sql!("SELECT count(*)::int FROM matrix_sessions WHERE oauth_code_hash = $1", [T.sha256_hex(s1.code)])

      assert T.row_by_at(s2.at)["oauth_code_hash"] == T.sha256_hex(s2.code)

      T.redeem(s1) |> T.assert_token_error(400, "invalid_grant")
      assert T.whoami(s2.at).status == 200, "the later session of the same device is not derived from s1's code"
      assert T.whoami(s3.at).status == 200, "another device of the same user is untouched"
    end

    test "steps 2-5 never revoke: a failed redemption of a NEW code for the device leaves the live session alive",
         %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      s = T.session!(cid, @https, priv, sub: sub)
      g2 = T.flow_code!(cid, @https, priv, sub: sub)
      assert g2.device_id == s.device_id

      T.redeem(g2, %{"code_verifier" => valid_format_verifier()}) |> T.assert_token_error(400, "invalid_grant")
      assert T.whoami(s.at).status == 200
      assert [_] = T.active_rows(s.user_id, s.device_id)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Concurrency — single use is cluster-safe
  # ════════════════════════════════════════════════════════════════════════════

  describe "concurrency — N parallel redemptions of one code (Must #6)" do
    test "exactly one 200, all others 400 invalid_grant, never 5xx; at most one live session", %{cid: cid, priv: priv} do
      g = T.flow_code!(cid, @https, priv)

      conns =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> T.redeem(g) end) end)
        |> Task.await_many(30_000)

      statuses = Enum.map(conns, & &1.status)
      assert Enum.count(statuses, &(&1 == 200)) == 1, "exactly one winner, got #{inspect(statuses)}"
      assert Enum.count(statuses, &(&1 == 400)) == 9, "the losers get invalid_grant, got #{inspect(statuses)}"

      for c <- conns, c.status == 400, do: T.assert_token_error(c, 400, "invalid_grant")

      # invariant: at most one active row, and never a live session that no 200 handed out
      # (a loser with the valid verifier may revoke the winner's fresh session: T8 double-submit risk)
      [winner] = for c <- conns, c.status == 200, do: T.json(c)["access_token"]

      case T.active_rows(g.user_id, g.device_id) do
        [] -> :ok
        [row] -> assert row["access_token_hash"] == T.token_hash(winner), "the only live session is the winner's"
        rows -> flunk("at most one active row, got #{length(rows)}")
      end

      assert Enum.all?(T.session_rows(g.user_id, g.device_id), &(&1["access_token_hash"] == T.token_hash(winner))),
             "no session row exists that no 200 handed out"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T30 — last_used_at touch
  # ════════════════════════════════════════════════════════════════════════════

  describe "T30 — oauth_clients.last_used_at (at most once per hour)" do
    test "set by a successful grant, bumped when older than an hour, unchanged within the hour", %{cid: cid, priv: priv} do
      assert T.client_row(cid)["last_used_at"] == nil
      T.session!(cid, @https, priv)
      first = T.client_row(cid)["last_used_at"]
      assert %DateTime{} = first

      T.privileged_sql!("UPDATE oauth_clients SET last_used_at = now() - interval '2 hours' WHERE client_id = $1", [cid])
      old = T.client_row(cid)["last_used_at"]

      T.session!(cid, @https, priv)
      bumped = T.client_row(cid)["last_used_at"]
      assert DateTime.compare(bumped, old) == :gt
      assert abs(DateTime.diff(bumped, DateTime.utc_now())) <= 60

      T.session!(cid, @https, priv)
      assert T.client_row(cid)["last_used_at"] == bumped, "within the hour the column is not rewritten"
    end

    test "a failed grant does not touch last_used_at", %{cid: cid} do
      g = fresh_code(cid)
      T.redeem(g, %{"code_verifier" => valid_format_verifier()}) |> T.assert_token_error(400, "invalid_grant")
      assert T.client_row(cid)["last_used_at"] == nil
    end
  end
end
