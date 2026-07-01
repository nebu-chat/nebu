defmodule Nebu.Web.SignaturesUploadTest do
  @moduledoc """
  RED-phase ATDD acceptance tests for the `device-management` bugfix story,
  Bug 2 — POST /_matrix/client/v3/keys/signatures/upload.

  ## What is tested here

  AC5/AC6/AC7 from the story:

    * AC5 — POST /_matrix/client/v3/keys/signatures/upload (authenticated) returns
             HTTP 200 with body {"failures": {}}
    * AC6 — The endpoint requires a valid Bearer token (same OidcPlug pipeline as
             all protected routes). A valid token produces 200.
    * AC7 — An unauthenticated / invalid-token request returns 401
             (OidcPlug halts before the route is reached).

  ## Why these MUST FAIL NOW (RED)

  `Nebu.Web.Router.Protected` has no route for
  `POST /client/v3/keys/signatures/upload`. The Plug.Router match-all clause
  (`match _` at the end of Protected) emits 404 for unrecognised paths. Until
  the dev step adds:

      post "/client/v3/keys/signatures/upload" do
        send_json(conn, 200, %{"failures" => %{}})
      end

  AC5/AC6 will fail with status 404, and AC7 depends on OidcPlug rejecting the
  request before the missing route matters (so AC7 may pass early, but it must
  still be confirmed).

  ## Auth strategy (mirrors device_keys_test.exs)

  We use the same RSA JWT / JOSE helpers as the existing device-key tests:
    * `setup_oidc_keys/0` — generates an RSA key pair, configures OidcTestSupport
    * `bearer_for/2`       — mints a signed JWT for a given sub claim
    * `call/4`             — dispatches through Nebu.Web.Router

  These helpers are copied verbatim from device_keys_test.exs so this file is
  self-contained (no shared helper module yet).

  ## Crash/restart — NOT APPLICABLE

  Stateless endpoint. Persistenz Option C.
  """
  # async: false — uses Application.put_env; cannot run concurrently
  use ExUnit.Case, async: false

  @moduletag :integration

  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "sig-upload-test-key-1"
  @router_opts Nebu.Web.Router.init([])

  # ── Auth helpers (mirror device_keys_test.exs) ────────────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600

  defp setup_oidc_keys do
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

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    Map.put(priv_map, "kid", @kid)
  end

  defp bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => future_exp(),
      "iat" => System.system_time(:second)
    }

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    {"@" <> sub <> ":" <> @server_name, compact}
  end

  defp call(method, path, body, headers) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  # ── AC5 + AC6: authenticated request returns 200 {"failures": {}} ────────────

  describe "POST /keys/signatures/upload — authenticated" do
    setup do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("sig-upload-user", priv)
      {:ok, token: token}
    end

    test "AC5/AC6 — returns 200 with {\"failures\": {}} for any valid JSON body",
         %{token: token} do
      # RED: the route does not exist yet; Protected's catch-all emits 404.
      # The test will be green only after the stub route is added.
      conn =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          %{},
          auth(token)
        )

      assert conn.status == 200,
             "expected 200 but got #{conn.status} — route is likely missing (still RED)"

      body = json(conn)

      assert Map.has_key?(body, "failures"),
             "response body must contain a 'failures' key"

      assert body["failures"] == %{},
             "response body must be {\"failures\": {}}"
    end

    test "AC5/AC6 — realistic body for an UNSTORED key → 200 with per-key M_INVALID_SIGNATURE",
         %{token: token} do
      # client-crypto-setup (cross-signing-readback) replaced the no-op stub with a real
      # validate-then-merge handler: a signature whose target key is not stored for the user
      # cannot be validated, so it is reported under `failures` with errcode
      # M_INVALID_SIGNATURE (Matrix CS §/keys/signatures/upload). MYDEVICEID was never
      # uploaded for this user, so this body fails by design — still HTTP 200.
      realistic_body = %{
        "@sig-upload-user:test.local" => %{
          "ed25519:MYDEVICEID" => %{
            "user_id" => "@sig-upload-user:test.local",
            "usage" => ["self_signing"],
            "keys" => %{
              "ed25519:base64pubkey==" => "base64pubkey=="
            },
            "signatures" => %{
              "@sig-upload-user:test.local" => %{
                "ed25519:MYDEVICEID" => "base64signature=="
              }
            }
          }
        }
      }

      conn =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          realistic_body,
          auth(token)
        )

      assert conn.status == 200,
             "expected 200 but got #{conn.status} — route is likely missing (still RED)"

      user_failures = json(conn)["failures"]["@sig-upload-user:test.local"]

      assert is_map(user_failures) and map_size(user_failures) > 0,
             "an unstored target key must be reported under failures"

      assert Enum.any?(user_failures, fn {_key_id, entry} ->
               entry["errcode"] == "M_INVALID_SIGNATURE"
             end),
             "unstored/unverifiable key must yield errcode M_INVALID_SIGNATURE"
    end
  end

  # ── AC7: unauthenticated request returns 401 ─────────────────────────────────

  describe "POST /keys/signatures/upload — unauthenticated" do
    setup do
      # OIDC keys must be configured so OidcPlug can validate and reject the
      # unauthenticated request.
      _priv = setup_oidc_keys()
      :ok
    end

    # These tests are auth-pipeline confirmation. OidcPlug rejects before the route
    # is dispatched, so they would pass even without the stub. The AC5/AC6 tests
    # guard route existence.
    test "AC7 — no Bearer token → 401 M_UNKNOWN_TOKEN (OidcPlug rejects before route)" do
      # This test may already pass before the route is added (OidcPlug rejects
      # before reaching the match/dispatch phase), but it is included to confirm
      # the full auth pipeline is intact for this endpoint.
      conn =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          %{},
          []
        )

      assert conn.status == 401,
             "expected 401 but got #{conn.status}"

      body = json(conn)

      assert body["errcode"] in ["M_UNKNOWN_TOKEN", "M_MISSING_TOKEN"],
             "expected M_UNKNOWN_TOKEN or M_MISSING_TOKEN, got: #{inspect(body["errcode"])}"
    end

    test "AC7 — invalid / expired Bearer token → 401 M_UNKNOWN_TOKEN" do
      conn =
        call(
          :post,
          "/_matrix/client/v3/keys/signatures/upload",
          %{},
          auth("not.a.real.jwt")
        )

      assert conn.status == 401,
             "expected 401 but got #{conn.status}"

      body = json(conn)

      assert body["errcode"] in ["M_UNKNOWN_TOKEN", "M_MISSING_TOKEN"],
             "expected M_UNKNOWN_TOKEN or M_MISSING_TOKEN, got: #{inspect(body["errcode"])}"
    end
  end
end
