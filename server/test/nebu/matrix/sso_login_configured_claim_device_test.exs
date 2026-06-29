defmodule Nebu.Matrix.SsoLoginConfiguredClaimDeviceTest do
  @moduledoc """
  Regression tests for bug `matrix-login-user-id-claim`.

  ## Root cause (bug B — token lacks the configured claim)

  The dev/e2e stack sets `server_config.oidc_user_id_claim = "name"`, so a Matrix
  login SHOULD derive the user_id localpart from the token's `name` claim — e.g.
  dev user "alex" → `@alex:localhost`. Instead every Matrix device registered
  under a `sub`-derived id like `@ciq…lvy2fs:localhost`, so the Admin per-user
  device page (keyed by the human MXID `@alex:localhost`) showed NO devices and
  the device-management E2E scenarios failed.

  ## What this test pins (post ADR-022)

  This test asserts the load-bearing invariant: when the operator-configured
  user_id claim is `name` and the verified token CARRIES that claim, a real
  SSO → loginToken → POST /login derives `@<name>:localhost` AND creates the
  `devices` row under that id, never under the opaque `sub`.

  Scopes/claims are now purely an IdP-client concern. ADR-022 removed Nebu's
  `NEBU_OIDC_EXTRA_SCOPES` config: the Matrix SSO leg requests the fixed base scope
  `openid profile email` (+`offline_access` in offline mode — story
  oidc-bootstrap-only-e2e-regressions, AC4), and the IdP client is responsible
  for releasing whatever claims (e.g. `name`) it is configured to. This test
  therefore models an IdP client that releases `name`: the
  `:matrix_sso_token_override` seam returns a token that UNCONDITIONALLY carries
  `name`, and we assert the configured-claim → user_id → device-row binding.

  Tagged `:integration` — runs via `make test-integration` against the real
  Plug router + DB. Real flow only: no cookie forging, no DB-seeding of the
  session (the session is minted through the real SSO → loginToken → /login path).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  alias Nebu.Matrix.SsoStore
  alias Nebu.Matrix.DeviceKeyStore

  @server_name "test.local"
  @issuer "https://idp.example.com/realms/nebu"
  @audience "nebu-client"
  @kid "configured-claim-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  # Per-test-unique name + sub so concurrent test modules (random per-boot
  # pii_encryption_key) never collide on a Matrix user id.
  defp fresh_name, do: "alex" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp current_name, do: Process.get(:cc_name) || raise("name not set by setup")
  defp current_sub, do: Process.get(:cc_sub) || raise("sub not set by setup")

  defp future_exp, do: System.system_time(:second) + 3600

  defp setup_oidc do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"kid" => @kid, "use" => "sig", "alg" => "RS256"})

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    # SecretBox at-rest key for the opaque-session token (refresh_token: true path).
    Application.put_env(:nebu_http, :admin_secret_at_rest, "configured-claim-test-internal-secret")

    # The SSO single client comes from the Bootstrap DB via the :sso_bootstrap_reader
    # seam (ADR-022) — NOT from removed :matrix_oidc_client_* env keys. The redirect
    # leg needs it to build the authorize URL; the token exchange itself is stubbed by
    # :matrix_sso_token_override.
    encrypted_secret = Nebu.Admin.BootstrapLive.encrypt_secret("shhh")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> encrypted_secret
      _ -> nil
    end)

    # Inject the verifying JWK as a bare list so OidcPlug.available_keys/0 uses it
    # directly and never calls the JwksCache GenServer (not started in this test VM).
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :server_name,
            :sso_bootstrap_reader,
            :oidc_jwks,
            :oidc_metadata_override,
            :matrix_sso_token_override,
            :admin_secret_at_rest
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    priv_map
  end

  defp sign_id_token(priv_jwk, overrides) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => current_sub(),
          "exp" => future_exp(),
          "iat" => System.system_time(:second)
        },
        overrides
      )

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # Drive the real SSO redirect → callback → loginToken flow. ADR-022: scopes/claims
  # are an IdP-client concern, not Nebu config — the SSO leg requests the fixed base
  # scope `openid profile email` (+`offline_access`). We model an IdP client that is
  # configured to release the `name` claim, so the verified ID token carries `name`.
  defp mint_login_token(priv) do
    redirect_url = "http://localhost:7070/#/home"

    init =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(redirect_url)
      )

    assert init.status == 302, "SSO redirect must 302 to set up the login-token flow"
    params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    state = params["state"]
    nonce = params["nonce"]

    # The IdP client releases `name`, so the token always carries it.
    claims = %{"sub" => current_sub(), "nonce" => nonce, "name" => current_name()}

    id_token = sign_id_token(priv, claims)

    Application.put_env(:nebu_http, :matrix_sso_token_override, fn ->
      {:ok, id_token, "oidc-rt"}
    end)

    cb =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <>
          URI.encode_www_form(state)
      )

    assert cb.status == 302
    cb_query = cb |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    login_token = cb_query["loginToken"]
    assert is_binary(login_token) and login_token != ""
    login_token
  end

  defp login(priv, extra_body \\ %{}) do
    body =
      Map.merge(
        %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv),
          "refresh_token" => true
        },
        extra_body
      )

    resp = call(:post, "/_matrix/client/v3/login", body)
    assert resp.status == 200, "login must succeed (got #{resp.status}: #{resp.resp_body})"
    json(resp)
  end

  setup do
    # These tests need the real DB (server_config + devices). Skip cleanly DB-less.
    if Process.whereis(Nebu.Repo) == nil do
      {:skip, "requires Nebu.Repo (run via make test-integration)"}
    else
      prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
      priv = setup_oidc()

      name = fresh_name()
      sub = "CiQ" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :upper)
      Process.put(:cc_name, name)
      Process.put(:cc_sub, sub)

      expected_uid = "@" <> name <> ":" <> @server_name
      sub_uid = "@" <> Nebu.Matrix.UserId.localpart(%{"sub" => sub}) <> ":" <> @server_name

      # Configure the operator claim = "name" (the dev/e2e setting). Use the public
      # write helper so it ALSO invalidates the OidcClaimCache (ADR-018/ADR-020).
      prev_claim =
        case Ecto.Adapters.SQL.query(
               Nebu.Repo,
               "SELECT value FROM server_config WHERE key = 'oidc_user_id_claim' LIMIT 1",
               []
             ) do
          {:ok, %{rows: [[v]]}} -> v
          _ -> nil
        end

      :ok = Nebu.Admin.DB.upsert_server_config(%{"oidc_user_id_claim" => "name"})

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          for uid <- [expected_uid, sub_uid] do
            for table <- [
                  "device_one_time_keys",
                  "device_keys",
                  "devices",
                  "matrix_sessions",
                  "profiles",
                  "users"
                ] do
              _ =
                Ecto.Adapters.SQL.query(
                  Nebu.Repo,
                  "DELETE FROM #{table} WHERE user_id = $1",
                  [uid]
                )
            end
          end

          case prev_claim do
            nil ->
              Ecto.Adapters.SQL.query!(
                Nebu.Repo,
                "DELETE FROM server_config WHERE key = 'oidc_user_id_claim'",
                []
              )

              Nebu.Matrix.OidcClaimCache.reset_for_test()

            v ->
              :ok = Nebu.Admin.DB.upsert_server_config(%{"oidc_user_id_claim" => v})
          end
        end

        case prev_rl do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end
      end)

      {:ok, priv_jwk: priv, expected_uid: expected_uid, sub_uid: sub_uid}
    end
  end

  # ── The configured claim resolves the Matrix user_id (post ADR-022) ────────────

  test "login derives user_id from the configured `name` claim, not the opaque sub", %{
    priv_jwk: priv,
    expected_uid: expected_uid,
    sub_uid: sub_uid
  } do
    body = login(priv)

    assert body["user_id"] == expected_uid,
           "expected user_id from the configured `name` claim (#{expected_uid}), " <>
             "got #{inspect(body["user_id"])}. Falling through to the opaque sub " <>
             "(#{sub_uid}) is the bug."

    refute body["user_id"] == sub_uid,
           "user_id must NOT be derived from the opaque sub when the configured " <>
             "claim `name` is present in the token"
  end

  test "the devices row is created under @<name>:localhost (Admin per-user page key)", %{
    priv_jwk: priv,
    expected_uid: expected_uid,
    sub_uid: sub_uid
  } do
    body = login(priv)
    device_id = body["device_id"]
    assert is_binary(device_id) and device_id != ""

    # The device the login created must be attributed to the `name`-derived id —
    # this is exactly the row the Admin per-user device page reads.
    assert DeviceKeyStore.get_device(expected_uid, device_id),
           "expected a devices row under #{expected_uid}/#{device_id}"

    devices_for_name = DeviceKeyStore.list_devices(expected_uid)
    assert length(devices_for_name) >= 1,
           "Admin per-user device page (keyed by #{expected_uid}) must list the device"

    # And it must NOT have leaked under the opaque-sub id.
    assert DeviceKeyStore.list_devices(sub_uid) == [],
           "no device may be registered under the opaque-sub id #{sub_uid}"
  end
end
