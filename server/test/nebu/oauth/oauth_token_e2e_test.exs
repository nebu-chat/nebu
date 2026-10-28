defmodule Nebu.OAuth.OAuthTokenE2eTest do
  @moduledoc """
  RED-phase happy-path acceptance test for story `oauth-token-endpoint` (story 3 of epic
  oauth-broker), the epic-4 retro quality gate "happy path with a real client sequence": the exact
  matrix-js-sdk 41.3.0 sequence through the FULL router, no shortcuts:

  DCR register -> admin approve -> authorize (js-sdk shape: openid + unstable prefix + nonce +
  response_mode=query) -> IdP stub -> shared callback -> `POST /oauth2/token` -> id_token verified
  against `GET /oauth2/jwks` + the metadata issuer -> whoami -> /sync -> refresh (new id_token,
  no nonce) -> whoami with the new AT -> old AT soft_logout -> old RT => reuse => revoked -> new AT
  401 -> `/.well-known/openid-configuration` issuer byte-equal.

  Red today: `/oauth2/token`, `/oauth2/jwks` and `/.well-known/openid-configuration` are not routed.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @redirect "https://example.com/callback"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_user_active_override], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv}
  end

  test "register -> approve -> authorize -> token -> whoami -> sync -> refresh -> reuse => revoked", %{priv: priv} do
    # 1. Dynamic Client Registration (story 1) + admin approval
    reg = T.register(T.web_body(%{"redirect_uris" => [@redirect]}))
    assert reg.status == 201, "DCR must register, got #{reg.status}: #{reg.resp_body}"
    cid = T.json(reg)["client_id"]
    on_exit(fn -> T.cleanup_clients([cid]) end)
    assert :ok = Nebu.OAuth.approve_registration(cid, "@admin:test.local")

    # 2. metadata (as the js-sdk reads it)
    meta = T.get_metadata()
    assert meta.status == 200
    issuer = T.json(meta)["issuer"]
    assert T.json(meta)["jwks_uri"] == issuer <> "/oauth2/jwks"

    # 3. authorize + IdP + callback (story 2), js-sdk shape
    d = "AbCd" <> String.upcase(T.rand(3))
    nonce = "js-nonce-" <> T.rand()

    grant =
      T.flow_code!(cid, @redirect, priv,
        authorize: %{"scope" => T.js_sdk_scope(d), "nonce" => nonce, "response_mode" => "query"}
      )

    # 4. token
    conn = T.redeem(grant)
    body = T.assert_token_success(conn, id_token: true)
    assert body["scope"] == T.js_sdk_scope(d), "scope echoes the REQUEST's (unstable) prefix and openid"

    {header, claims} = T.verify_id_token!(body["id_token"])
    assert header["alg"] == "ES256"
    assert claims["iss"] == issuer, "iss byte-equal to the metadata issuer (js-sdk compares exactly)"
    assert claims["aud"] == cid
    assert claims["sub"] == grant.user_id
    assert claims["nonce"] == nonce
    assert claims["exp"] - claims["iat"] == 300

    # 5. Matrix API with the Nebu access token
    who = T.whoami(body["access_token"])
    assert who.status == 200
    assert T.json(who) == %{"user_id" => grant.user_id, "device_id" => d, "is_guest" => false}
    assert T.sync(body["access_token"]).status == 200

    # 6. refresh (js-sdk sends no scope), IdP re-validation per_refresh
    T.idp_refresh_ok(grant.sub)
    refreshed = T.refresh(cid, body["refresh_token"]) |> T.assert_token_success(id_token: true)
    assert_received {:idp_refresh, rt} when rt == grant.idp_rt
    assert refreshed["scope"] == body["scope"]
    {_h2, c2} = T.verify_id_token!(refreshed["id_token"])
    refute Map.has_key?(c2, "nonce"), "a refreshed id_token carries no nonce (OIDC Core 12.2)"
    assert Map.take(c2, ~w(iss sub aud auth_time)) == Map.take(claims, ~w(iss sub aud auth_time))

    # 7. new AT works, old AT is superseded (soft logout)
    assert T.whoami(refreshed["access_token"]).status == 200
    old = T.whoami(body["access_token"])
    assert old.status == 401
    assert T.json(old)["soft_logout"] == true

    # 8. the old RT is now consumed => reuse => the whole session is revoked
    T.refresh(cid, body["refresh_token"]) |> T.assert_token_error(400, "invalid_grant")
    gone = T.whoami(refreshed["access_token"])
    assert gone.status == 401
    assert T.json(gone)["errcode"] == "M_UNKNOWN_TOKEN"
    T.refresh(cid, refreshed["refresh_token"]) |> T.assert_token_error(400, "invalid_grant")

    # 9. OidcTokenRefresher discovery document (C7)
    oc = T.get("/.well-known/openid-configuration")
    assert oc.status == 200
    assert T.json(oc)["issuer"] == issuer
    assert T.json(oc)["jwks_uri"] == issuer <> "/oauth2/jwks"
  end

  # story 4 (oauth-token-revocation-logout): the Dart-SDK logout sequence (RED: /oauth2/revoke unrouted)
  test "story 4: login -> whoami -> AT expires -> revoke with the EXPIRED AT (Dart params) -> 401 without soft_logout -> RT invalid_grant -> device gone",
       %{priv: priv} do
    cid = T.oauth_client!([@redirect])
    d = "DaRt" <> String.upcase(T.rand(3))
    grant = T.flow_code!(cid, @redirect, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), d)})
    body = T.redeem!(grant)
    at = body["access_token"]
    rt = body["refresh_token"]
    other = T.legacy_session!(grant.user_id, "OTHER" <> String.upcase(T.rand(3)))

    assert T.whoami(at).status == 200
    T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE access_token_hash = $1", [T.token_hash(at)])

    # the metadata advertises the endpoint the client calls
    revocation_endpoint = T.json(T.get_metadata())["revocation_endpoint"]
    assert URI.parse(revocation_endpoint).path == "/oauth2/revoke"

    T.revoke([{"token", at}, {"token_type_hint", "access_token"}, {"client_id", cid}]) |> T.assert_revoke_ok()

    T.whoami(at) |> T.assert_unknown_token(false)
    T.refresh(cid, rt) |> T.assert_token_error(400, "invalid_grant")

    devices = T.matrix_request(:get, "/_matrix/client/v3/devices", other.at)
    assert devices.status == 200
    refute d in Enum.map(T.json(devices)["devices"], & &1["device_id"]), "the revoked device is no longer listed"
  end
end
