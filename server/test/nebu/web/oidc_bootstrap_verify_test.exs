defmodule Nebu.Web.OidcBootstrapVerifyTest do
  @moduledoc """
  RED-phase ATDD tests for bug `bugfix-oidc-bootstrap-only-e2e-regressions`,
  AC1 + AC2 — the `:no_keys` bootstrap blocker and the fail-closed invariant.

  ## Background (root cause)

  ADR-022 ("OIDC bootstrap-only") removed the env-var JWKS source
  (`NEBU_OIDC_JWKS_URI`, which warmed `Nebu.Web.JwksCache` at boot). During the
  bootstrap wizard the OIDC config lives in the `bootstrap_draft`, NOT yet in
  `server_config` — so the global `JwksCache`/`OidcConfig` are still EMPTY. The
  admin operator-login callback verifies the operator ID token via
  `OidcPlug.verify_token/2`, which today resolves keys from the global cache and
  the issuer from `OidcConfig` — both empty mid-bootstrap → `:no_keys`
  (or `:issuer_not_configured`) → bootstrap deadlock.

  ## AC1 — bootstrap-mode verification uses the DRAFT, not the global caches

  The fix extends `verify_token/2` to accept `:issuer` and `:jwks` (a list of JWK
  maps) overrides alongside the existing `:audience`. The bootstrap callback then
  calls:

      OidcPlug.verify_token(id_token,
        issuer: draft_issuer,
        audience: draft_client_id,
        jwks: keys_from_draft_jwks_uri)

  …so keys + issuer come from the draft. This test signs an ID token with an
  in-test RSA key, passes the matching public JWK via `:jwks` and the draft issuer
  via `:issuer`, with the GLOBAL caches deliberately EMPTY (no `:oidc_jwks`,
  `OidcConfig` configured with nils). Expected: `{:ok, claims}`.

  RED NOW: `verify_token/2` ignores `:issuer`/`:jwks`; `select_key/0` reads the
  (empty) global key list → `{:error, :no_keys}`, and `check_issuer` reads the
  (nil) global issuer → `{:error, :issuer_not_configured}`. Either way NOT `{:ok}`.

  ## AC2 — fail-closed invariant preserved (#1 invariant)

  The draft-verification path MUST NOT warm the global `JwksCache`/`OidcConfig`.
  While bootstrap is in progress, a Matrix Bearer request to `OidcPlug` MUST still
  return `401` — the Matrix API does not start accepting tokens until bootstrap
  completes and the global caches are refreshed from `server_config`. We model
  "empty global caches" by NOT injecting `:oidc_jwks` and configuring `OidcConfig`
  with nil issuer/audience. A well-formed Bearer JWT must be rejected `401`.

  This is the ADR-022 security invariant the reviewer (Kassandra) scrutinises:
  the local draft-verify path is a SEPARATE code path that never mutates the
  global caches, so it cannot make the Matrix surface accept tokens early.

  AC2 is most likely ALREADY GREEN — it is the invariant GUARD: this test proves
  the (future) AC1 fix does not regress fail-closed. We keep it.

  ## Crash/restart — NOT APPLICABLE

  Pure stateless verification on the request/caller process (Persistenz Option C).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  # The DRAFT issuer/client — what a bootstrap operator login would carry. These
  # are NEVER installed into the global OidcConfig: only passed via verify_token opts.
  @draft_issuer "https://dex.bootstrap.example.com/dex"
  @draft_client_id "nebu-bootstrap-client"
  @kid "bootstrap-key-1"

  setup do
    # Generate an RSA keypair in-test. The private key signs the operator ID token;
    # the matching public JWK is what the bootstrap path would fetch from the draft's
    # oidc_jwks_uri and pass via `:jwks` — NO global cache involvement.
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

    priv_map = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)

    # CRITICAL for AC1/AC2: the GLOBAL caches stay EMPTY.
    #  * Set :nebu_http, :oidc_jwks to [] — the explicit "empty global key cache"
    #    representation. available_keys/0 returns this [] WITHOUT a JwksCache
    #    GenServer.call, so the test is deterministic whether or not the JwksCache
    #    child is supervised (in the full unit env it is; here it pins []).
    #  * Configure OidcConfig with nil issuer/audience (so the global issuer/aud are nil).
    # This reproduces "fresh DB, empty server_config, mid-bootstrap".
    Nebu.Web.OidcTestSupport.configure(nil, nil)
    Application.put_env(:nebu_http, :oidc_jwks, [])

    on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Application.delete_env(:nebu_http, :oidc_jwks)
      Nebu.Web.OidcTestSupport.clear()
    end)

    {:ok, priv_jwk: priv_map, pub_jwk: pub_jwk}
  end

  defp sign_jwt(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp future_exp, do: System.system_time(:second) + 3600

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — bootstrap-mode verify succeeds with EMPTY global caches via draft opts
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — verify_token/2 uses draft :issuer + :jwks (not the global caches)" do
    # RED NOW: :issuer/:jwks are ignored; select_key reads the empty global key list
    # → {:error, :no_keys}. After the fix the keys come from the :jwks override and the
    # issuer from the :issuer override → {:ok, claims}.
    test "succeeds with {:ok, claims} when keys+issuer come from the draft, global caches empty",
         %{priv_jwk: priv_jwk, pub_jwk: pub_jwk} do
      claims = %{
        "iss" => @draft_issuer,
        "aud" => @draft_client_id,
        "sub" => "operator-kai",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"],
        "exp" => future_exp(),
        "iat" => System.system_time(:second)
      }

      id_token = sign_jwt(claims, priv_jwk)

      result =
        Nebu.Web.Plugs.OidcPlug.verify_token(id_token,
          issuer: @draft_issuer,
          audience: @draft_client_id,
          jwks: [pub_jwk]
        )

      assert {:ok, verified} = result,
             "bootstrap verify must succeed using draft-sourced issuer+jwks with empty " <>
               "global caches; got: #{inspect(result)} (RED now: :no_keys / :issuer_not_configured)"

      assert verified["sub"] == "operator-kai"
      assert verified["groups"] == ["instance_admin"]
    end

    # A draft-verified token whose iss does NOT match the draft issuer override must
    # still be rejected — the override is fail-closed, not a bypass.
    test "rejects a token whose iss does not match the draft :issuer override",
         %{priv_jwk: priv_jwk, pub_jwk: pub_jwk} do
      claims = %{
        "iss" => "https://evil.example.com/dex",
        "aud" => @draft_client_id,
        "sub" => "operator-kai",
        "exp" => future_exp()
      }

      id_token = sign_jwt(claims, priv_jwk)

      assert {:error, _} =
               Nebu.Web.Plugs.OidcPlug.verify_token(id_token,
                 issuer: @draft_issuer,
                 audience: @draft_client_id,
                 jwks: [pub_jwk]
               )
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — fail-closed preserved: Matrix Bearer still 401 mid-bootstrap (#1 invariant)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — fail-closed invariant: Matrix Bearer 401 with empty global caches" do
    @opts Nebu.Web.Plugs.OidcPlug.init([])

    # GUARD (likely ALREADY GREEN): the normal Matrix Bearer request path does NOT
    # pass :issuer/:jwks overrides, so it must resolve keys/issuer from the global
    # caches — which are empty during bootstrap → 401. This proves the AC1 draft path
    # does not pollute the global caches and let the Matrix API accept tokens early.
    test "a well-formed Bearer JWT is rejected 401 while global JwksCache/OidcConfig are empty",
         %{priv_jwk: priv_jwk} do
      claims = %{
        "iss" => @draft_issuer,
        "aud" => @draft_client_id,
        "sub" => "operator-kai",
        "exp" => future_exp()
      }

      token = sign_jwt(claims, priv_jwk)

      conn =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert conn.halted, "mid-bootstrap (empty global caches) the Matrix API must reject tokens"
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
      refute conn.assigns[:current_user]
    end

    # Belt-and-braces: even after a successful AC1 draft verify happens in-process,
    # the global key list must remain empty (the draft path must not warm it). We
    # invoke the draft-verify, then assert the Matrix Bearer path is STILL 401.
    test "an AC1 draft verify does NOT warm the global caches (Matrix Bearer still 401)",
         %{priv_jwk: priv_jwk, pub_jwk: pub_jwk} do
      claims = %{
        "iss" => @draft_issuer,
        "aud" => @draft_client_id,
        "sub" => "operator-kai",
        "exp" => future_exp()
      }

      id_token = sign_jwt(claims, priv_jwk)

      # Drive the draft-verify path (its success/failure is covered by AC1 above;
      # here we only care about its side effects on the global caches).
      _ =
        Nebu.Web.Plugs.OidcPlug.verify_token(id_token,
          issuer: @draft_issuer,
          audience: @draft_client_id,
          jwks: [pub_jwk]
        )

      # The global key-list override must STILL be empty — the draft path must not
      # add the draft JWKS to the global cache (that would let the Matrix API accept
      # tokens before bootstrap completes; the AC2 #1 invariant).
      assert Application.get_env(:nebu_http, :oidc_jwks) == [],
             "the draft-verify path must not write the draft JWKS into the global :oidc_jwks cache"

      # And the Matrix Bearer path must still be fail-closed.
      conn =
        conn(:get, "/_matrix/client/v3/sync")
        |> put_req_header("authorization", "Bearer " <> id_token)
        |> Nebu.Web.Plugs.OidcPlug.call(@opts)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end
end
