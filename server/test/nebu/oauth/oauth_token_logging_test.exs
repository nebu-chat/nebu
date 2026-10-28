defmodule Nebu.OAuth.OAuthTokenLoggingTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint` (story 3 of epic oauth-broker),
  AC19 / T23 / T29 / must-test 31 (No Sensitive Data in Logs law): log capture at `:debug` over
  both grants (success and error paths, code reuse, refresh-token reuse, IdP transient and
  confirmed failures) and the JWKS / lazy key-generation path. None of these may appear in ANY log
  line: access/refresh tokens (old and new), the authorization code, the PKCE verifier, the
  id_token, the IdP refresh token, the client redirect URI, the scope value (device ids themselves are logged at INFO by design, T29),
  the signing key's SecretBox ciphertext or a private JWK member (`"d"`).

  Also: `RequestLogger` masks the query string of `/oauth2/token` to parameter names only
  (`@names_only_query_paths`) and never captures its request body (`body_params` stays
  `Unfetched`).

  Red today: there is no token endpoint (the session helpers fail at `POST /oauth2/token` with the
  router's 404) and `/oauth2/token` is not on the names-only list.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_user_active_override], do: Application.delete_env(:nebu_http, k)
    end)

    redirect = "https://app.example.com/cb-" <> T.rand(6)
    {:ok, priv: priv, redirect: redirect, cid: T.oauth_client!([redirect])}
  end

  defp debug_log(fun), do: capture_log([level: :debug], fun)
  defp dev, do: "LOG" <> String.upcase(T.rand(4))

  defp grant_opts(device_id, extra \\ %{}),
    do: [authorize: Map.merge(%{"scope" => T.js_sdk_scope(device_id), "nonce" => "n-" <> T.rand()}, extra)]

  defp secrets_of(grant, extra) do
    Map.merge(
      %{
        code: grant.code,
        verifier: grant.verifier,
        challenge: grant.challenge,
        idp_rt: grant.idp_rt,
        redirect_uri: grant.redirect_uri,
        scope: grant.scope
      },
      extra
    )
  end

  test "authorization_code + refresh_token success paths and their errors never log a secret (AC19, must-test 31)",
       %{cid: cid, priv: priv, redirect: redirect} do
    grant = T.flow_code!(cid, redirect, priv, grant_opts(dev()))
    T.idp_refresh_ok(grant.sub, "rotated-idp-rt-" <> T.rand(8))
    holder = self()

    log =
      debug_log(fn ->
        body = T.redeem!(grant)
        # code reuse with the valid verifier (revokes)
        _ = T.redeem(grant)
        send(holder, {:first, body})
      end)

    assert_received {:first, first}

    grant2 = T.flow_code!(cid, redirect, priv, grant_opts(dev()))

    log2 =
      debug_log(fn ->
        b2 = T.redeem!(grant2)
        r1 = T.refresh!(cid, b2["refresh_token"])
        _ = T.whoami(r1["access_token"])
        # consumed RT => reuse => revoke
        _ = T.refresh(cid, b2["refresh_token"])
        # invalid_client / invalid_grant / invalid_request shapes
        _ = T.refresh("unknown-client-" <> T.rand(), r1["refresh_token"])
        _ = T.refresh(cid, String.duplicate("a", 64))
        _ = T.token_request([{"grant_type", "authorization_code"}, {"code", grant2.code}])
        send(holder, {:second, b2, r1})
      end)

    assert_received {:second, b2, r1}

    all = log <> log2

    T.refute_secrets_in_log(
      all,
      Map.merge(secrets_of(grant, %{}), %{
        at: first["access_token"],
        rt: first["refresh_token"],
        id_token: first["id_token"],
        code2: grant2.code,
        verifier2: grant2.verifier,
        idp_rt2: grant2.idp_rt,
        scope2: grant2.scope,
        at2: b2["access_token"],
        rt2: b2["refresh_token"],
        id_token2: b2["id_token"],
        at3: r1["access_token"],
        rt3: r1["refresh_token"],
        id_token3: r1["id_token"]
      })
    )

    refute all =~ "rotated-idp-rt-", "the provider-rotated IdP refresh token leaked"
    refute all =~ ~r/"d"\s*:\s*"/, "a private JWK member leaked"
  end

  test "IdP transient and confirmed failures on refresh log only the classification", %{cid: cid, priv: priv, redirect: redirect} do
    grant = T.flow_code!(cid, redirect, priv, grant_opts(dev()))
    body = T.redeem!(grant)

    log =
      debug_log(fn ->
        T.idp_refresh_error({:token_endpoint_unreachable, %{secret_detail: "IDP-ERROR-DETAIL-" <> grant.idp_rt}})
        _ = T.refresh(cid, body["refresh_token"])
        T.idp_refresh_error({:token_endpoint_status, 400})
        _ = T.refresh(cid, body["refresh_token"])
      end)

    T.refute_secrets_in_log(log, secrets_of(grant, %{at: body["access_token"], rt: body["refresh_token"], id_token: body["id_token"]}))
    refute log =~ "IDP-ERROR-DETAIL", "only RefreshErrors.describe/1 output may be logged"
    assert log =~ "[warning]", "a confirmed IdP rejection is logged as WARNING (T29)"
  end

  test "JWKS GET / lazy key generation never logs key material or the SecretBox ciphertext (must-test 27)" do
    log = debug_log(fn -> assert T.jwks().status == 200 end)

    for row <- T.signing_key_rows() do
      assert is_binary(row["private_jwk_enc"])
      refute String.contains?(log, row["private_jwk_enc"]), "signing-key ciphertext leaked into the log"
    end

    refute log =~ ~r/"d"\s*:\s*"/, "a private JWK member leaked"
  end

  describe "AC19/T23 — RequestLogger on /oauth2/token" do
    defp query_strings(log) do
      ~r/"query_string":"((?:[^"\\]|\\.)*)"/
      |> Regex.scan(log)
      |> Enum.map(fn [_, qs] -> qs end)
    end

    test "a (wrong) query string on POST /oauth2/token is logged names-only; the body is never captured" do
      body = "grant_type=refresh_token&refresh_token=BODY-RT-SECRET-0123&client_id=BODY-CLIENT-VALUE&scope=BODY-SCOPE-VALUE"

      log =
        debug_log(fn ->
          T.token_request(body, query: "state=QS-STATE-VALUE&client_id=QS-CLIENT-VALUE&redirect_uri=QS-REDIRECT-VALUE")
        end)

      assert [qs | _] = query_strings(log), "the DEBUG line must carry a query_string field"
      assert qs =~ "state=***" and qs =~ "client_id=***" and qs =~ "redirect_uri=***", qs
      for v <- ~w(QS-STATE-VALUE QS-CLIENT-VALUE QS-REDIRECT-VALUE BODY-RT-SECRET BODY-CLIENT-VALUE BODY-SCOPE-VALUE), do: refute(log =~ v, "#{v} leaked")
    end

    test "GET /oauth2/token?... is masked as well" do
      log = debug_log(fn -> T.get("/oauth2/token?client_id=GQS-CLIENT-VALUE&nonce=GQS-NONCE-VALUE") end)
      assert [qs | _] = query_strings(log)
      assert qs =~ "client_id=***"
      refute log =~ "GQS-CLIENT-VALUE"
      refute log =~ "GQS-NONCE-VALUE"
    end
  end
end
