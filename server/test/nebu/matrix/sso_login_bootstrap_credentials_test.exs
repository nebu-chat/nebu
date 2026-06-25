defmodule Nebu.Matrix.SsoLoginBootstrapCredentialsTest do
  @moduledoc """
  Regression tests for bug bugfix/oidc-login-keycloak.

  ## Root Cause

  `resolve_client_credentials/0` in `Nebu.Matrix.SsoLogin` looked up the key
  `"oidc_client_secret_decrypted"` in `server_config`. That key does not exist.
  The Bootstrap wizard stores the encrypted secret under `"oidc_client_secret"`
  (AES-256-GCM blob via `Nebu.Admin.BootstrapLive.encrypt_secret/1`).

  The result: the DB-fallback path always sends an empty client_secret to the IdP
  token endpoint → 401 Unauthorized → "SSO login failed" / "Invalid or expired
  SSO state" depending on the scope.

  This matched the historical Go bug (commit `bfd4884f`): the Go SSO handler read
  the secret from ENV where `$` in the value caused shell-expansion to an empty
  string. The fix (commit `53904df6`) switched to the DB source. The Elixir port
  copied the DB lookup but used the wrong key name.

  ## Fix

  Read `"oidc_client_secret"` (the actual stored key) and decrypt it via
  `Nebu.Admin.BootstrapLive.decrypt_secret/1`.

  ## Test Design

  Two seams are used to exercise the code path without a live DB or IdP:

  - `:sso_bootstrap_reader` — a 1-arity fn injected into `config_value/1` that
    returns Bootstrap DB values (client_id + encrypted secret).
  - `:matrix_sso_token_override` — upgraded to support a 1-arity form `fn(cfg)`
    that receives the resolved OIDC config; the test asserts the correct
    (non-empty, correctly decrypted) `client_secret` is present before returning a
    fake id_token. A 0-arity form continues to work for existing tests.

  ## Acceptance Criteria

  - AC1: When `NEBU_OIDC_CLIENT_ID` env is absent and Bootstrap DB has
    `oidc_client_id` + encrypted `oidc_client_secret`, the SSO callback resolves
    the plaintext secret and completes the OIDC flow (302 with loginToken).
  - AC2: Secrets that contain special characters (e.g. `$`) are carried through
    unchanged — no shell expansion or truncation.
  - AC3: The env-path (when `NEBU_OIDC_CLIENT_ID` is set) is not broken by the fix
    and still takes priority over the DB path.
  - AC4: When both env path and DB path are absent, the admin client env fallback
    is used (consistent with the original priority chain).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer "https://keycloak.example.com/realms/INNOQ"
  @audience "innoq-nebu"
  @kid "kc-key-1"
  @authorize "https://keycloak.example.com/realms/INNOQ/protocol/openid-connect/auth"
  @token_endpoint "https://keycloak.example.com/realms/INNOQ/protocol/openid-connect/token"

  # The Keycloak client secret contains `$` — the bug caused this to become ""
  # after "oidc_client_secret_decrypted" lookup returned nil.
  @client_id "innoq-nebu-matrix"
  @client_secret "my$ecret!with$Special$Chars"
  # Must match what the DB would have — injected via :admin_secret_at_rest seam.
  @at_rest_key "sso-bootstrap-credentials-test-key"

  @router_opts Nebu.Web.Router.init([])

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600

  defp gen_rsa_keypair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.put("kid", @kid)
      |> Map.put("alg", "RS256")
      |> Map.put("use", "sig")

    {Map.put(priv_map, "kid", @kid), pub_jwk}
  end

  defp sign_id_token(priv_jwk, claims_overrides) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => "keycloak-user",
          "exp" => future_exp(),
          "iat" => System.system_time(:second)
        },
        claims_overrides
      )

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  # Sets up OIDC env WITHOUT setting :matrix_oidc_client_id — forces the
  # Bootstrap DB fallback path. Injects an encrypted Bootstrap secret via seam.
  defp setup_bootstrap_oidc(pub_jwk, credential_spy_ref) do
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)
    encrypted_secret = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :oidc_audience, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    # Bootstrap DB seam: returns real DB values without hitting Postgres.
    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> encrypted_secret
      _ -> nil
    end)

    # 1-arity exchange override: receives the resolved cfg so the test can assert
    # on client_id and client_secret before returning a fake id_token.
    Application.put_env(:nebu_http, :matrix_sso_token_override, fn cfg ->
      Process.put(credential_spy_ref, %{
        client_id: cfg.client_id,
        client_secret: cfg.client_secret
      })

      :not_yet_available
    end)

    on_exit(fn ->
      for k <- [
            :oidc_issuer,
            :oidc_audience,
            :oidc_jwks,
            :oidc_metadata_override,
            :sso_bootstrap_reader,
            :matrix_sso_token_override,
            :matrix_oidc_client_id,
            :matrix_oidc_client_secret,
            :admin_secret_at_rest
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    encrypted_secret
  end

  defp call(method, path) do
    Nebu.Web.Router.call(conn(method, path), @router_opts)
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  setup do
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 + AC2 — Bootstrap DB path resolves the decrypted secret (incl. `$`)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1+AC2 — Bootstrap DB fallback resolves non-empty, correctly decrypted secret" do
    test "SSO callback uses oidc_client_secret (not oidc_client_secret_decrypted); $ not truncated" do
      {priv_jwk, pub_jwk} = gen_rsa_keypair()
      spy_key = make_ref()
      _encrypted = setup_bootstrap_oidc(pub_jwk, spy_key)

      # Initiate to get a real, persisted state + nonce.
      init =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("http://localhost:7070")
        )

      assert init.status == 302, "expected 302 from SSO redirect, got #{init.status}"
      loc = location(init)
      params = loc |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      state = params["state"]
      nonce = params["nonce"]
      assert is_binary(state) and is_binary(nonce)

      # Now wire the 1-arity override to return a real id_token once we have the
      # nonce (we couldn't sign it before). The spy part already ran above in the
      # redirect, but the exchange happens in the callback.
      id_token = sign_id_token(priv_jwk, %{"sub" => "keycloak-user", "nonce" => nonce})

      Application.put_env(:nebu_http, :matrix_sso_token_override, fn cfg ->
        Process.put(spy_key, %{
          client_id: cfg.client_id,
          client_secret: cfg.client_secret
        })

        {:ok, id_token}
      end)

      # Trigger the callback.
      cb =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect/oidc?code=kc-code&state=" <>
            URI.encode_www_form(state)
        )

      # Retrieve what the exchange override captured.
      captured = Process.get(spy_key)
      assert captured != nil,
             "exchange override was never called — the SSO callback flow did not reach exchange/4"

      # AC1: client_id must match the Bootstrap DB value (not empty, not admin client).
      assert captured.client_id == @client_id,
             "expected client_id=#{@client_id} from Bootstrap DB, got: #{inspect(captured.client_id)}"

      # AC2: client_secret must be the decrypted plaintext — $ characters intact.
      # Before the fix this was "" (because oidc_client_secret_decrypted does not exist).
      assert captured.client_secret == @client_secret,
             "expected client_secret=#{inspect(@client_secret)} (decrypted from oidc_client_secret), " <>
               "got: #{inspect(captured.client_secret)}. " <>
               "Root cause: config_value(\"oidc_client_secret_decrypted\") returned nil; " <>
               "fix: read oidc_client_secret and call BootstrapLive.decrypt_secret/1."

      # AC1 (flow): the callback must complete with a 302 carrying loginToken.
      assert cb.status == 302,
             "expected 302 after successful token exchange, got #{cb.status}"

      loc2 = location(cb)
      assert is_binary(loc2) and String.contains?(loc2, "loginToken="),
             "expected loginToken in redirect location, got: #{inspect(loc2)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — Env path still takes priority over Bootstrap DB path
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — NEBU_OIDC_CLIENT_ID env takes priority over Bootstrap DB" do
    test "when matrix_oidc_client_id env is set, DB credentials are NOT used" do
      {_priv, pub_jwk} = gen_rsa_keypair()
      spy_key = make_ref()
      _encrypted = setup_bootstrap_oidc(pub_jwk, spy_key)

      # Override: set env credentials (different from DB values).
      env_client_id = "env-matrix-client"
      env_secret = "env-secret-value"
      Application.put_env(:nebu_http, :matrix_oidc_client_id, env_client_id)
      Application.put_env(:nebu_http, :matrix_oidc_client_secret, env_secret)

      # Initiate + capture credentials via 1-arity override.
      init =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("http://localhost:7070")
        )

      assert init.status == 302
      params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      state = params["state"]
      # nonce not needed — we don't sign a token in this test (credential priority only)

      # Don't need to sign a real token — we're testing credential priority, not
      # the full flow. Just inject a spy override to capture what was resolved.
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn cfg ->
        Process.put(spy_key, %{
          client_id: cfg.client_id,
          client_secret: cfg.client_secret
        })

        # Return error so the callback fails (we only care about credential resolution).
        {:error, :test_only}
      end)

      _cb =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect/oidc?code=kc-code&state=" <>
            URI.encode_www_form(state)
        )

      captured = Process.get(spy_key)
      assert captured != nil

      # Must use env credentials, not Bootstrap DB credentials.
      assert captured.client_id == env_client_id,
             "env credentials must take priority; got client_id=#{inspect(captured.client_id)}"

      assert captured.client_secret == env_secret,
             "env credentials must take priority; got client_secret=#{inspect(captured.client_secret)}"

      # Must NOT use Bootstrap DB values.
      refute captured.client_id == @client_id,
             "Bootstrap DB client_id must not be used when env is set"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — Admin-env fallback when both env-path and Bootstrap DB are absent
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — admin-env credentials used when NEBU_OIDC_CLIENT_ID and Bootstrap DB are absent" do
    test "admin_oidc_client_id/secret are used as last resort" do
      admin_client_id = "admin-fallback-client"
      admin_secret = "admin-fallback-secret"

      # Neither matrix_oidc_client_id env NOR sso_bootstrap_reader (= no DB cred).
      # Admin cred is the last fallback in resolve_client_credentials/0.
      Application.put_env(:nebu_http, :oidc_issuer, @issuer)
      Application.put_env(:nebu_http, :oidc_audience, @audience)
      Application.put_env(:nebu_http, :oidc_jwks, [%{}])
      Application.put_env(:nebu_http, :admin_oidc_client_id, admin_client_id)
      Application.put_env(:nebu_http, :admin_oidc_client_secret, admin_secret)

      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => @issuer,
        "authorization_endpoint" => @authorize,
        "token_endpoint" => @token_endpoint,
        "jwks_uri" => @issuer <> "/jwks"
      })

      spy_key = make_ref()

      Application.put_env(:nebu_http, :matrix_sso_token_override, fn cfg ->
        Process.put(spy_key, %{
          client_id: cfg.client_id,
          client_secret: cfg.client_secret
        })

        {:error, :test_only}
      end)

      on_exit(fn ->
        for k <- [
              :oidc_issuer,
              :oidc_audience,
              :oidc_jwks,
              :oidc_metadata_override,
              :admin_oidc_client_id,
              :admin_oidc_client_secret,
              :matrix_sso_token_override
            ] do
          Application.delete_env(:nebu_http, k)
        end
      end)

      # Initiate to get a valid state entry in the store.
      init =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("http://localhost:7070")
        )

      assert init.status == 302
      state = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("state")

      # Trigger callback.
      _cb =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect/oidc?code=code&state=" <>
            URI.encode_www_form(state)
        )

      captured = Process.get(spy_key)
      assert captured != nil, "exchange override was never called"

      assert captured.client_id == admin_client_id,
             "expected admin fallback client_id, got: #{inspect(captured.client_id)}"

      assert captured.client_secret == admin_secret,
             "expected admin fallback client_secret, got: #{inspect(captured.client_secret)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Regression guard — the wrong key name must not silently return a value
  # ════════════════════════════════════════════════════════════════════════════

  describe "regression guard — oidc_client_secret_decrypted key does not exist in server_config" do
    test "Bootstrap DB seam: oidc_client_secret_decrypted key returns nil; fix uses oidc_client_secret" do
      # This test documents the root cause directly.
      # The seam returns nil for any unknown key — just like the real server_config.
      Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_secret_at_rest) end)

      encrypted = Nebu.Admin.BootstrapLive.encrypt_secret("a_secret_value")

      reader = fn
        "oidc_client_id" -> "some-client"
        "oidc_client_secret" -> encrypted
        # oidc_client_secret_decrypted DOES NOT EXIST — the buggy code reads this:
        _any -> nil
      end

      # Wrong key → nil → empty secret.
      assert reader.("oidc_client_secret_decrypted") == nil

      # Correct key → encrypted blob → decryptable.
      raw = reader.("oidc_client_secret")
      assert is_binary(raw) and raw != ""
      assert Nebu.Admin.BootstrapLive.decrypt_secret(raw) == "a_secret_value"
    end
  end
end
