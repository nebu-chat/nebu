defmodule Nebu.Matrix.DeviceEndpointsTest do
  @moduledoc """
  RED-phase ATDD tests for story S3 "Matrix device-management endpoints
  (rename, delete, delete_devices)" (epic: device-management).

  S3 adds the WRITE side of Matrix device management on top of the read-only
  `GET /devices` / `GET /devices/{id}` shipped by S1/S2:

    * `PUT  /_matrix/client/v3/devices/{deviceId}`   — rename (owner-only, NOT UIA-gated)
    * `DELETE /_matrix/client/v3/devices/{deviceId}`  — delete (UIA-gated, Option B SSO)
    * `POST /_matrix/client/v3/delete_devices`        — bulk delete (same UIA gate)

  Deleting a device is a full session teardown: it removes the `devices` +
  `device_keys`/OTK/fallback rows, revokes the bound `matrix_sessions` token, AND
  denylists the JWT bound to that device — so a subsequent request carrying that
  exact token authenticates no more (→ 401 M_UNKNOWN_TOKEN).

  ## Red-phase rationale (why each test FAILS against the code as it stands today)

  Today the protected router mounts ONLY `GET /client/v3/devices` and
  `GET /client/v3/devices/{deviceId}` (protected.ex). There is no PUT, no DELETE,
  no `POST /delete_devices`, no UIA challenge machinery, no per-device kill-switch,
  and no ingress-boundary device_id validation. Each test below therefore fails by
  construction:

    * AC2 Rename / Rename-IDOR — `PUT /devices/{id}` is unrouted → the router returns
      its catch-all (404 M_UNRECOGNIZED / no body match), so the 200-and-GET-reflects
      and the owner-only-404 assertions both fail.

    * AC3 Delete-revokes-session / F-1 KILL-SWITCH — `DELETE /devices/{id}` is unrouted;
      even once routed, the bound-JWT denylist (the kill-switch) is the part S3 adds, so
      the "subsequent request with that token → 401 M_UNKNOWN_TOKEN" assertion fails today.

    * AC4 delete_devices bulk — `POST /delete_devices` is unrouted.

    * AC2/AC3 IDOR (delete/rename other user's device → 404) — no handler, no
      current-user scoping → fails.

    * AC5 UIA G1 fresh / stale — there is no UIA challenge: no `auth_time` freshness
      compare, no `401 {flows, session, params}` body, no `auth`-block re-submit path.
      Both the "fresh ≤15min proceeds" and the "stale >15min challenged then completes"
      tests fail.

    * AC5/G2 UIA replay — no UIA session store, so the replay-rejection contract cannot
      hold yet.

    * F-2 device_id VALIDATION — login and `/keys/upload` accept arbitrary device_id
      strings today (no length / control-char rejection at the ingress boundary), so the
      "oversized / control-char device_id → 400" assertions fail.

  ## Staleness control (assumption — see Dev Notes in s3-matrix-device-endpoints.md)

  The 15-minute fresh-auth window is configurable (story: env
  `NEBU_UIA_FRESH_AUTH_SECONDS`, default 900). To drive staleness deterministically
  (no sleeping), these tests set the *application env* the implementation is expected
  to read:

      Application.put_env(:nebu_http, :uia_fresh_auth_seconds, 0)   # force "stale" → always challenge
      Application.put_env(:nebu_http, :uia_fresh_auth_seconds, 86_400) # force "fresh" → never challenge

  ASSUMPTION: the impl reads the app-env key `:uia_fresh_auth_seconds` under the
  `:nebu_http` OTP app (mirrors how the rest of this suite injects config — e.g.
  `:rate_limit_disabled`, `:oidc_issuer`). The env var `NEBU_UIA_FRESH_AUTH_SECONDS`
  is its runtime.exs source. The dev step must align the impl to THIS key (or update
  these tests if a different key is chosen). on_exit restores the prior value.

  Tagged `:integration` — runs via `make test-integration`. Real flows only: no
  cookie forging, no DB-seeding of auth state. Sessions are minted through the real
  SSO → loginToken → POST /login path (scaffolding copied verbatim from
  device_lifecycle_login_test.exs).
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
  @kid "device-endpoints-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  # Per-test-unique sub → per-test-unique Matrix user id (config/test.exs uses a
  # RANDOM pii_encryption_key per boot, so a unique sub per test avoids colliding
  # with another boot's undecryptable PII rows → no login 500).
  defp fresh_sub, do: "den" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp current_sub, do: Process.get(:den_sub) || raise("sub not set by setup")

  # ── shared helpers (verbatim from device_lifecycle_login_test.exs) ────────────

  defp future_exp, do: System.system_time(:second) + 3600

  defp setup_oidc do
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

    priv_jwk = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :admin_secret_at_rest, "device-endpoints-test-internal-secret")

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
            :oidc_jwks,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_sso_token_override,
            :admin_secret_at_rest
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    priv_jwk
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
  defp auth(token), do: [{"authorization", "Bearer " <> token}]
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  # Run the real SSO redirect → callback flow with an injected token exchange,
  # returning the single-use opaque loginToken the client then redeems at POST
  # /login. `kind` selects the exchange shape: :opaque → {:ok, id_token, rt},
  # :jwt → {:ok, id_token}. `claim_overrides` are merged into the signed id_token
  # (e.g. an explicit `auth_time` to drive the UIA freshness gate).
  defp mint_login_token(priv, kind, claim_overrides \\ %{}) do
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

    id_token =
      sign_id_token(priv, Map.merge(%{"sub" => current_sub(), "nonce" => nonce}, claim_overrides))

    exchange =
      case kind do
        :opaque -> {:ok, id_token, "oidc-rt-from-keycloak"}
        :jwt -> {:ok, id_token}
      end

    Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> exchange end)

    cb =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <> URI.encode_www_form(state)
      )

    assert cb.status == 302
    cb_query = cb |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    login_token = cb_query["loginToken"]
    assert is_binary(login_token) and login_token != ""
    login_token
  end

  # Full opaque-session login → decoded login body (opaque access_token, bound device_id).
  defp login_opaque(priv, extra_body \\ %{}, claim_overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv, :opaque, claim_overrides),
          "refresh_token" => true
        },
        extra_body
      )

    resp = call(:post, "/_matrix/client/v3/login", body)
    assert resp.status == 200, "opaque login must succeed (got #{resp.status}: #{resp.resp_body})"
    json(resp)
  end

  # Full raw-JWT login (no refresh_token) → decoded login body (JWT access_token,
  # bound device_id; the token→device binding lands in jwt_device_bindings — the
  # row F-1's kill-switch must denylist).
  defp login_jwt(priv, extra_body) do
    body =
      Map.merge(
        %{"type" => "m.login.token", "token" => mint_login_token(priv, :jwt)},
        extra_body
      )

    resp = call(:post, "/_matrix/client/v3/login", body)
    assert resp.status == 200, "jwt login must succeed (got #{resp.status}: #{resp.resp_body})"
    body = json(resp)
    assert String.contains?(body["access_token"], "."), "jwt login must return a JWT access_token"
    body
  end

  defp device_keys_obj(uid, device_id) do
    %{
      "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
      "device_id" => device_id,
      "keys" => %{
        "curve25519:#{device_id}" => "3C5BFWi2Y8MaVvjM8M22DBmh24PmgR0nPvJOIArzgyI",
        "ed25519:#{device_id}" => "lEuiRJBit0IG6nUf5pUzWTUEsRVVe/HJkoKuEww9ULI"
      },
      "signatures" => %{
        uid => %{
          "ed25519:#{device_id}" =>
            "dSO80A01XiigH3uBiDVx/EjzaoycHcjq9lfQX0uWsqxl2giMIiSPR8a4d291W1ihKJL/a+myXS367WT6NAIcBA"
        }
      },
      "user_id" => uid
    }
  end

  # Force the UIA freshness window. seconds == 0 → every session is "stale" (always
  # challenge); a large value → every session is "fresh" (never challenge). See the
  # moduledoc "Staleness control" assumption about the env key.
  defp set_uia_window!(seconds) do
    prev = Application.get_env(:nebu_http, :uia_fresh_auth_seconds)
    Application.put_env(:nebu_http, :uia_fresh_auth_seconds, seconds)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:nebu_http, :uia_fresh_auth_seconds)
        v -> Application.put_env(:nebu_http, :uia_fresh_auth_seconds, v)
      end
    end)
  end

  setup do
    # Disable the per-IP login limiter locally (these tests hammer /login + /sync).
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    priv = setup_oidc()

    sub = fresh_sub()
    Process.put(:den_sub, sub)
    uid = "@" <> sub <> ":" <> @server_name

    if Process.whereis(Nebu.Repo) do
      _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Alice", "alice@example.com")
      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Alice", nil)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          for table <- [
                "jwt_device_bindings",
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
      end)
    end

    {:ok, priv_jwk: priv, user_id: uid}
  end

  # A second user (user B) minted through the SAME real SSO flow, for IDOR tests.
  # Returns {uid_b, login_body_b}. Switches the per-process sub to B's, runs the
  # login, registers B's cleanup, then restores the original (A's) sub so the rest
  # of the test continues to act as A.
  defp login_other_user!(priv, extra_body) do
    a_sub = Process.get(:den_sub)
    b_sub = fresh_sub()
    Process.put(:den_sub, b_sub)
    uid_b = "@" <> b_sub <> ":" <> @server_name

    _ = Nebu.Matrix.Session.TokenValidator.validate(uid_b, "user", "Bob", "bob@example.com")
    _ = Nebu.Matrix.Profile.DB.upsert_profile(uid_b, "Bob", nil)

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        for table <- [
              "jwt_device_bindings",
              "device_one_time_keys",
              "device_keys",
              "devices",
              "matrix_sessions",
              "profiles",
              "users"
            ] do
          _ = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM #{table} WHERE user_id = $1", [uid_b])
        end
      end
    end)

    login_b = login_opaque(priv, extra_body)
    # restore A as the active subject
    Process.put(:den_sub, a_sub)
    {uid_b, login_b}
  end

  # Complete the `m.login.sso` UIA stage for an in-flight UIA `session` THE SPEC WAY
  # (CS v1.18, confirmed by Oracle): there is NO inline credential for m.login.sso —
  # completion is exclusively out-of-band via the auth FALLBACK mechanism. The client:
  #   1. opens GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id>,
  #      which the server handles like /login/sso/redirect (302 → IdP authorize),
  #   2. the IdP callback is validated and the server marks THIS UIA session's
  #      m.login.sso stage complete (and refreshes auth_time for Option B),
  #   3. the client then RE-SUBMITS the original request with `auth: {"session": id}`
  #      — session ONLY, no `type`, no token.
  #
  # This drives the REAL fallback endpoint (no shortcut, no inline token) so the dev
  # step builds the handler against the spec wire contract, not a bespoke shape.
  #
  # Returns the spec-shaped re-submit auth dict `%{"session" => session_id}`.
  defp complete_uia_sso!(priv, session_id) do
    result = complete_uia_sso_as!(priv, session_id, current_sub())

    # A matching-sub completion marks the stage complete (200 success page or 302).
    assert result.cb_status in [200, 302],
           "the SSO callback must complete for a matching sub (got #{result.cb_status})"

    result.resubmit_auth
  end

  # Variant of complete_uia_sso! that signs the fallback id_token with an EXPLICIT
  # `sub` (rather than the current subject). Used by the H-1 cross-sub attack test:
  # a DIFFERENT IdP identity completes the fallback for a victim's UIA session. The
  # `cb_status` returned lets the caller assert the server's reaction (200 success
  # page on a matching sub, 403 mismatch page on a foreign sub).
  defp complete_uia_sso_as!(priv, session_id, sub) do
    # 1. open the SSO auth-fallback for this UIA session → 302 to the IdP authorize.
    init =
      call(:get, "/_matrix/client/v3/auth/m.login.sso/fallback/web?session=" <> URI.encode_www_form(session_id))

    assert init.status == 302,
           "the m.login.sso auth fallback must 302 to the IdP (got #{init.status}: #{init.resp_body})"

    params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    state = params["state"]
    nonce = params["nonce"]
    assert is_binary(state) and state != "", "the auth fallback must carry an SSO state"

    # 2. the IdP callback: a freshly-authenticated id_token for the given `sub`.
    id_token = sign_id_token(priv, %{"sub" => sub, "nonce" => nonce})
    Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> {:ok, id_token, "uia-rt"} end)

    cb =
      call(:get, "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <> URI.encode_www_form(state))

    %{cb_status: cb.status, resubmit_auth: %{"session" => session_id}}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — PUT /devices/{deviceId} renames; owner-only; NOT UIA-gated.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2 — PUT /devices/{deviceId} (rename)" do
    test "rename success → 200 {}, GET reflects the new display_name", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv, %{"device_id" => "REN_DEV", "initial_device_display_name" => "Old Name"})
        at = login["access_token"]
        assert login["device_id"] == "REN_DEV"

        put =
          call(
            :put,
            "/_matrix/client/v3/devices/REN_DEV",
            %{"display_name" => "My Laptop"},
            auth(at)
          )

        assert put.status == 200, "rename must return 200 (got #{put.status}: #{put.resp_body})"
        assert json(put) == %{}, "rename returns an empty object"

        got = call(:get, "/_matrix/client/v3/devices/REN_DEV", nil, auth(at))
        assert got.status == 200
        assert json(got)["display_name"] == "My Laptop",
               "GET /devices/{id} must reflect the renamed display_name"
      else
        assert true
      end
    end

    test "rename IDOR: A renaming B's device → 404 M_NOT_FOUND, B unchanged", %{priv_jwk: priv, user_id: _uid_a} do
      if Process.whereis(Nebu.Repo) do
        login_a = login_opaque(priv, %{"device_id" => "A_DEV"})
        at_a = login_a["access_token"]

        {uid_b, login_b} =
          login_other_user!(priv, %{"device_id" => "B_DEV", "initial_device_display_name" => "Bob Phone"})

        # A attempts to rename B's device by naming B's device_id in the path.
        attack =
          call(
            :put,
            "/_matrix/client/v3/devices/B_DEV",
            %{"display_name" => "Pwned"},
            auth(at_a)
          )

        assert attack.status == 404, "renaming another user's device must 404 (no IDOR / no oracle)"
        assert json(attack)["errcode"] == "M_NOT_FOUND"

        # B's device is unchanged (still its original display name).
        got_b = call(:get, "/_matrix/client/v3/devices/B_DEV", nil, auth(login_b["access_token"]))
        assert got_b.status == 200
        assert json(got_b)["display_name"] == "Bob Phone",
               "the rejected cross-user rename must not have mutated B's device"

        # Store-level sanity: B's row is intact.
        assert DeviceKeyStore.get_device(uid_b, "B_DEV")["display_name"] == "Bob Phone"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — DELETE /devices/{deviceId} revokes the session + removes key material.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3 — DELETE /devices/{deviceId}" do
    test "delete (fresh auth) revokes the session token and removes the device", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        # Fresh window so DELETE proceeds directly without a UIA challenge.
        set_uia_window!(86_400)

        login = login_opaque(priv, %{"device_id" => "DEL_DEV"})
        at = login["access_token"]

        # Sanity: the session authenticates before the delete.
        assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200

        del = call(:delete, "/_matrix/client/v3/devices/DEL_DEV", %{}, auth(at))
        assert del.status == 200, "fresh-auth DELETE must succeed (got #{del.status}: #{del.resp_body})"
        assert json(del) == %{}

        # The revoked session can no longer authenticate.
        post = call(:get, "/_matrix/client/v3/sync", nil, auth(at))
        assert post.status == 401, "deleting the device must revoke its session token"
        assert json(post)["errcode"] == "M_UNKNOWN_TOKEN"

        # The device is gone from the directory (use a fresh session to read).
        reader = login_opaque(priv)
        list = call(:get, "/_matrix/client/v3/devices", nil, auth(reader["access_token"]))
        assert list.status == 200
        refute Enum.any?(json(list)["devices"], &(&1["device_id"] == "DEL_DEV")),
               "the deleted device must disappear from GET /devices"
      else
        assert true
      end
    end

    test "delete is idempotent: re-deleting a now-gone device → 200 {}", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)

        login = login_opaque(priv, %{"device_id" => "IDEMP_DEV"})
        at = login["access_token"]

        assert call(:delete, "/_matrix/client/v3/devices/IDEMP_DEV", %{}, auth(at)).status == 200

        # The original session is now revoked; re-attempt the delete from a fresh session.
        again = login_opaque(priv)

        redel = call(:delete, "/_matrix/client/v3/devices/IDEMP_DEV", %{}, auth(again["access_token"]))
        assert redel.status == 200, "re-deleting an absent device must be idempotent (200 {})"
        assert json(redel) == %{}
      else
        assert true
      end
    end

    test "delete other user's device → 404, B's device intact", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)

        login_a = login_opaque(priv, %{"device_id" => "A_ONLY"})
        at_a = login_a["access_token"]
        {uid_b, login_b} = login_other_user!(priv, %{"device_id" => "B_ONLY"})

        attack = call(:delete, "/_matrix/client/v3/devices/B_ONLY", %{}, auth(at_a))
        assert attack.status == 404, "deleting another user's device must 404"
        assert json(attack)["errcode"] == "M_NOT_FOUND"

        # B's device + session still work.
        assert is_map(DeviceKeyStore.get_device(uid_b, "B_ONLY")),
               "the rejected cross-user delete must not have removed B's device"

        assert call(:get, "/_matrix/client/v3/sync", nil, auth(login_b["access_token"])).status == 200
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # F-1 KILL-SWITCH (Security, HIGH) — deleting a device denylists the JWT bound
  # to it. A raw-JWT session (login_jwt binds token→device in jwt_device_bindings)
  # whose device is deleted must STOP authenticating: 401 M_UNKNOWN_TOKEN.
  # ══════════════════════════════════════════════════════════════════════════

  describe "F-1 — deleting a device denylists the bound JWT (kill-switch)" do
    test "raw-JWT bound to the deleted device → subsequent request 401 M_UNKNOWN_TOKEN", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)

        # Raw-JWT login binds the JWT → device in jwt_device_bindings.
        login = login_jwt(priv, %{"device_id" => "JWT_DEV"})
        jwt = login["access_token"]
        assert login["device_id"] == "JWT_DEV"

        # The bound JWT authenticates before the delete.
        assert call(:get, "/_matrix/client/v3/account/whoami", nil, auth(jwt)).status == 200

        del = call(:delete, "/_matrix/client/v3/devices/JWT_DEV", %{}, auth(jwt))
        assert del.status == 200, "fresh-auth DELETE of the bound device must succeed"

        # KILL-SWITCH: the JWT bound to the deleted device is denylisted → no longer valid.
        after_del = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(jwt))
        assert after_del.status == 401,
               "the JWT bound to a deleted device must be denylisted (kill-switch)"

        assert json(after_del)["errcode"] == "M_UNKNOWN_TOKEN"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — POST /delete_devices (bulk).
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4 — POST /delete_devices (bulk)" do
    test "two of the caller's device_ids → both removed (after UIA satisfied)", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)

        # Two devices for the SAME user, plus a third reader session.
        _d1 = login_opaque(priv, %{"device_id" => "BULK_1"})
        _d2 = login_opaque(priv, %{"device_id" => "BULK_2"})
        caller = login_opaque(priv, %{"device_id" => "BULK_CALLER"})
        at = caller["access_token"]

        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"devices" => ["BULK_1", "BULK_2"], "auth" => %{}},
            auth(at)
          )

        assert resp.status == 200, "bulk delete must return 200 (got #{resp.status}: #{resp.resp_body})"
        assert json(resp) == %{}

        list = call(:get, "/_matrix/client/v3/devices", nil, auth(at))
        assert list.status == 200
        ids = Enum.map(json(list)["devices"], & &1["device_id"])
        refute "BULK_1" in ids, "BULK_1 must be deleted"
        refute "BULK_2" in ids, "BULK_2 must be deleted"
      else
        assert true
      end
    end

    test "raw-JWT caller bulk-deleting OTHER devices keeps its OWN JWT alive and completes the batch",
         %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        # MINOR-1 regression: a raw-JWT caller that bulk-deletes devices OTHER than its
        # own must NOT have its own bound JWT denylisted — it has to finish the batch and
        # keep authenticating afterwards. (The prior code only spared the OPAQUE session;
        # a JWT caller was logged out mid-batch even when not targeting its own device.)
        set_uia_window!(86_400)

        # Caller logs in as a raw JWT bound to JWT_CALLER (binding in jwt_device_bindings).
        caller = login_jwt(priv, %{"device_id" => "JWT_CALLER"})
        jwt = caller["access_token"]
        assert caller["device_id"] == "JWT_CALLER"

        # Two OTHER devices for the SAME user (raw-JWT too, so each has its own binding).
        _other1 = login_jwt(priv, %{"device_id" => "JWT_OTHER_1"})
        _other2 = login_jwt(priv, %{"device_id" => "JWT_OTHER_2"})

        # The caller's JWT authenticates before the batch.
        assert call(:get, "/_matrix/client/v3/account/whoami", nil, auth(jwt)).status == 200

        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"devices" => ["JWT_OTHER_1", "JWT_OTHER_2"], "auth" => %{}},
            auth(jwt)
          )

        assert resp.status == 200, "bulk delete of OTHER devices must return 200 (got #{resp.status}: #{resp.resp_body})"
        assert json(resp) == %{}

        # The caller's OWN JWT is still alive (it did not target its own device).
        after_batch = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(jwt))
        assert after_batch.status == 200,
               "a raw-JWT caller that did NOT target its own device must keep authenticating"

        # The two OTHER devices are gone.
        list = call(:get, "/_matrix/client/v3/devices", nil, auth(jwt))
        ids = Enum.map(json(list)["devices"], & &1["device_id"])
        refute "JWT_OTHER_1" in ids, "JWT_OTHER_1 must be deleted"
        refute "JWT_OTHER_2" in ids, "JWT_OTHER_2 must be deleted"
        assert "JWT_CALLER" in ids, "the caller's own device must survive"
      else
        assert true
      end
    end

    test "raw-JWT caller bulk-deleting its OWN device keeps its OWN live JWT alive (symmetric preserve)",
         %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        # MINOR-1 semantics pin: a caller that bulk-deletes its OWN device must keep the
        # credential MAKING the request alive so it can finish the batch and keep managing
        # devices — IDENTICALLY for opaque and raw-JWT callers. The prior code spared only
        # the opaque matrix_sessions row; a raw-JWT caller was logged out mid-batch by the
        # unconditional kill-switch. The fix skips the caller's OWN token hash in the
        # kill-switch, so a JWT caller's live token survives just like an opaque caller's.
        set_uia_window!(86_400)

        caller = login_jwt(priv, %{"device_id" => "JWT_SELF"})
        jwt = caller["access_token"]
        assert caller["device_id"] == "JWT_SELF"

        assert call(:get, "/_matrix/client/v3/account/whoami", nil, auth(jwt)).status == 200

        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"devices" => ["JWT_SELF"], "auth" => %{}},
            auth(jwt)
          )

        assert resp.status == 200, "the batch deleting the caller's own device returns 200 (got #{resp.status})"
        assert json(resp) == %{}

        # The caller's OWN live JWT survives so it can finish managing devices.
        after_batch = call(:get, "/_matrix/client/v3/devices", nil, auth(jwt))
        assert after_batch.status == 200,
               "a JWT caller's own live token must survive deleting its own device in a batch"

        # The device itself is gone from the directory.
        ids = Enum.map(json(after_batch)["devices"], & &1["device_id"])
        refute "JWT_SELF" in ids, "the caller's own device must be deleted even though its live token survives"
      else
        assert true
      end
    end

    test "empty devices array → 200 {} (valid no-op)", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)
        caller = login_opaque(priv, %{"device_id" => "NOOP_CALLER"})

        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"devices" => [], "auth" => %{}},
            auth(caller["access_token"])
          )

        assert resp.status == 200, "an empty devices array is a valid no-op (got #{resp.status})"
        assert json(resp) == %{}
      else
        assert true
      end
    end

    test "missing \"devices\" key → 400 M_MISSING_PARAM", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)
        caller = login_opaque(priv, %{"device_id" => "MISS_CALLER"})

        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"auth" => %{}},
            auth(caller["access_token"])
          )

        assert resp.status == 400, "missing devices must be 400 (got #{resp.status}: #{resp.resp_body})"
        assert json(resp)["errcode"] == "M_MISSING_PARAM"
      else
        assert true
      end
    end

    test "oversized devices array (>100 entries) → 400 M_INVALID_PARAM", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)
        caller = login_opaque(priv, %{"device_id" => "CAP_CALLER"})

        oversized = for n <- 1..101, do: "CAP_DEV_#{n}"

        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"devices" => oversized, "auth" => %{}},
            auth(caller["access_token"])
          )

        assert resp.status == 400,
               "a devices array larger than 100 must be rejected (got #{resp.status}: #{resp.resp_body})"

        assert json(resp)["errcode"] == "M_INVALID_PARAM"
      else
        assert true
      end
    end

    test "IDOR: a foreign device_id mixed into the array is NOT deleted (scoped to caller)",
         %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(86_400)

        # Caller A owns OWN_DEV; user B owns VICTIM_DEV.
        caller = login_opaque(priv, %{"device_id" => "OWN_DEV"})
        at_a = caller["access_token"]
        {uid_b, login_b} = login_other_user!(priv, %{"device_id" => "VICTIM_DEV"})

        # A submits a bulk delete mixing its own device with B's device_id.
        resp =
          call(
            :post,
            "/_matrix/client/v3/delete_devices",
            %{"devices" => ["OWN_DEV", "VICTIM_DEV"], "auth" => %{}},
            auth(at_a)
          )

        # Spec is idempotent/lenient on the response code (200), but the security
        # invariant is that B's device is UNTOUCHED — the op is scoped to the caller.
        assert resp.status in [200, 404],
               "bulk delete must not error-leak; it scopes to the caller (got #{resp.status})"

        # A's own device IS gone.
        ids_a = call(:get, "/_matrix/client/v3/devices", nil, auth(at_a)) |> json() |> Map.get("devices") |> Enum.map(& &1["device_id"])
        refute "OWN_DEV" in ids_a, "the caller's own listed device must be deleted"

        # B's device MUST survive (no cross-user deletion / IDOR).
        assert DeviceKeyStore.get_device(uid_b, "VICTIM_DEV"),
               "another user's device must NOT be deletable via the bulk array"

        got_b = call(:get, "/_matrix/client/v3/devices/VICTIM_DEV", nil, auth(login_b["access_token"]))
        assert got_b.status == 200, "B's device must still be present after A's cross-user bulk attempt"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 / G1 — UIA SSO fresh-auth window (Option B, 15 min, configurable).
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5 G1 — UIA fresh-auth window" do
    test "fresh (≤15min) → DELETE proceeds directly, no 401 challenge", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        # Large window → the just-completed login is well within "fresh".
        set_uia_window!(86_400)

        login = login_opaque(priv, %{"device_id" => "FRESH_DEV"})
        at = login["access_token"]

        del = call(:delete, "/_matrix/client/v3/devices/FRESH_DEV", %{}, auth(at))
        assert del.status == 200, "a fresh session must delete without a UIA challenge (got #{del.status})"
        assert json(del) == %{}
      else
        assert true
      end
    end

    test "stale (>15min) → first DELETE 401 with flows+session; complete SSO + re-submit auth → 200, gone",
         %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        # Window 0 → every session is immediately "stale" → always challenge.
        set_uia_window!(0)

        login = login_opaque(priv, %{"device_id" => "STALE_DEV"})
        at = login["access_token"]

        # First attempt must be challenged.
        first = call(:delete, "/_matrix/client/v3/devices/STALE_DEV", %{}, auth(at))
        assert first.status == 401, "a stale session must be UIA-challenged (got #{first.status})"
        body = json(first)

        assert body["flows"] == [%{"stages" => ["m.login.sso"]}],
               "the UIA challenge must offer the m.login.sso stage"

        assert is_binary(body["session"]) and body["session"] != "",
               "the UIA challenge must carry a server-issued session id"

        assert body["params"] == %{}, "the UIA challenge params must be an (empty) object"

        # Complete the m.login.sso stage out-of-band via the REAL auth fallback for
        # THIS UIA session, then re-submit the original DELETE with the spec-shaped
        # `auth: {"session": id}` (session only). Use a large window so the fresh auth
        # the fallback established satisfies the gate.
        set_uia_window!(86_400)
        resubmit_auth = complete_uia_sso!(priv, body["session"])

        second =
          call(
            :delete,
            "/_matrix/client/v3/devices/STALE_DEV",
            %{"auth" => resubmit_auth},
            auth(at)
          )

        assert second.status == 200,
               "re-submitting with a completed m.login.sso auth must succeed (got #{second.status}: #{second.resp_body})"

        assert json(second) == %{}

        # The device is gone.
        reader = login_opaque(priv)
        list = call(:get, "/_matrix/client/v3/devices", nil, auth(reader["access_token"]))
        refute Enum.any?(json(list)["devices"], &(&1["device_id"] == "STALE_DEV")),
               "after UIA completes, the device must be deleted"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 / G2 — UIA session integrity: a completed/foreign session cannot be replayed.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5 G2 — UIA session cannot be replayed" do
    test "a UIA session minted by user A cannot be reused by user B / for a different op", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(0)

        # User A obtains a UIA challenge for deleting A's device.
        login_a = login_opaque(priv, %{"device_id" => "A_REPLAY"})
        at_a = login_a["access_token"]

        challenge = call(:delete, "/_matrix/client/v3/devices/A_REPLAY", %{}, auth(at_a))
        assert challenge.status == 401
        session_a = json(challenge)["session"]
        assert is_binary(session_a) and session_a != ""

        # User B logs in and tries to ride A's UIA session for B's OWN deletion.
        {_uid_b, login_b} = login_other_user!(priv, %{"device_id" => "B_REPLAY"})
        at_b = login_b["access_token"]

        replay =
          call(
            :delete,
            "/_matrix/client/v3/devices/B_REPLAY",
            # spec re-submit shape: session only. The session belongs to (user A, A's
            # pending op) — B presents it for B's own delete.
            %{"auth" => %{"session" => session_a}},
            auth(at_b)
          )

        # The session is bound to (user A, A's pending op): B must NOT be honored.
        assert replay.status in [401, 403],
               "a foreign UIA session must not be honored for another user (got #{replay.status})"

        # B's device is intact (the replay did nothing).
        assert call(:get, "/_matrix/client/v3/devices/B_REPLAY", nil, auth(at_b)).status == 200
      else
        assert true
      end
    end

    test "a satisfied UIA session is single-use: it cannot be replayed for a second op", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        set_uia_window!(0)

        # Two devices for the same user A.
        login = login_opaque(priv, %{"device_id" => "SU_DEV_1"})
        at = login["access_token"]
        _ = login_opaque(priv, %{"device_id" => "SU_DEV_2"})

        # Challenge + satisfy UIA to delete the first device.
        challenge = call(:delete, "/_matrix/client/v3/devices/SU_DEV_1", %{}, auth(at))
        assert challenge.status == 401
        session = json(challenge)["session"]
        resubmit_auth = complete_uia_sso!(priv, session)

        first = call(:delete, "/_matrix/client/v3/devices/SU_DEV_1", %{"auth" => resubmit_auth}, auth(at))
        assert first.status == 200, "the satisfied UIA delete must succeed (got #{first.status})"

        # Re-using the SAME (now-consumed) session for a DIFFERENT op must NOT be a
        # free pass — the server must re-challenge (a single-use session is spent).
        replay = call(:delete, "/_matrix/client/v3/devices/SU_DEV_2", %{"auth" => %{"session" => session}}, auth(at))

        assert replay.status == 401,
               "a consumed UIA session must not authorize a second operation (got #{replay.status})"

        # The second device is still present (it was not deleted by the replay).
        list = call(:get, "/_matrix/client/v3/devices", nil, auth(at))
        assert Enum.any?(json(list)["devices"], &(&1["device_id"] == "SU_DEV_2")),
               "the second device must survive the replayed (spent) UIA session"
      else
        assert true
      end
    end

    # H-1 (HIGH) — UIA m.login.sso completion MUST be bound to the freshly-authenticated
    # identity. Against the buggy code (complete/1 keyed only by session_id) a DIFFERENT
    # IdP account completing the victim's fallback satisfied the step-up: the attacker
    # holding the victim's open access token re-submitted and the victim's device was
    # deleted. After the fix (complete/2 with AND user_id = <sub-from-verified-id_token>),
    # a foreign-sub completion matches 0 rows → stage never goes complete → the re-submit
    # is still 401 and the victim's device is INTACT.
    test "H-1: a foreign IdP identity completing the fallback does NOT satisfy the victim's step-up",
         %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        # Victim A logs in and triggers a stale DELETE → UIA session bound to A.
        set_uia_window!(0)

        login_a = login_opaque(priv, %{"device_id" => "VICTIM_HW"})
        at_a = login_a["access_token"]

        challenge = call(:delete, "/_matrix/client/v3/devices/VICTIM_HW", %{}, auth(at_a))
        assert challenge.status == 401, "a stale session must be UIA-challenged (got #{challenge.status})"
        session_a = json(challenge)["session"]
        assert is_binary(session_a) and session_a != ""

        # An attacker with a DIFFERENT IdP identity (sub B) completes A's fallback. Use a
        # large window so that, IF the completion were honored, the re-submit would pass —
        # this isolates the identity-binding as the only thing that can block it.
        set_uia_window!(86_400)
        attacker_sub = fresh_sub()
        result = complete_uia_sso_as!(priv, session_a, attacker_sub)

        # The completion for a foreign sub must NOT mark the stage complete: the callback
        # renders the mismatch failure page (403), not the success page.
        assert result.cb_status == 403,
               "a foreign-sub fallback completion must be rejected (got #{result.cb_status})"

        # A re-submits the DELETE with the (un-completed) session. It must still be
        # challenged — the foreign completion bound nothing.
        resubmit =
          call(
            :delete,
            "/_matrix/client/v3/devices/VICTIM_HW",
            %{"auth" => %{"session" => session_a}},
            auth(at_a)
          )

        assert resubmit.status == 401,
               "a foreign-sub completion must NOT satisfy the victim's step-up (got #{resubmit.status})"

        # A's device is INTACT (the cross-sub attack deleted nothing).
        reader = login_opaque(priv)
        list = call(:get, "/_matrix/client/v3/devices", nil, auth(reader["access_token"]))
        assert Enum.any?(json(list)["devices"], &(&1["device_id"] == "VICTIM_HW")),
               "the victim's device must survive a cross-sub UIA completion attack (H-1)"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # F-2 device_id VALIDATION (Security, HIGH) — the ingress boundary (login
  # device_id + /keys/upload device_id) rejects oversized (256+ bytes) and
  # control-char (\x00-\x1f, \x7f, newline) device_ids with 400; accepts a valid
  # ≤255 printable device_id.
  # ══════════════════════════════════════════════════════════════════════════

  describe "F-2 — device_id ingress validation" do
    test "valid ≤255 printable device_id is accepted at login", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        ok_id = "VALID-device_id.123"

        body = %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv, :opaque),
          "refresh_token" => true,
          "device_id" => ok_id
        }

        resp = call(:post, "/_matrix/client/v3/login", body)
        assert resp.status == 200, "a valid printable device_id must be accepted (got #{resp.status})"
        assert json(resp)["device_id"] == ok_id
      else
        assert true
      end
    end

    test "oversized (256+ byte) device_id at login → 400", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        oversized = String.duplicate("a", 300)

        body = %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv, :opaque),
          "refresh_token" => true,
          "device_id" => oversized
        }

        resp = call(:post, "/_matrix/client/v3/login", body)
        assert resp.status == 400, "an oversized device_id must be rejected at ingress (got #{resp.status})"
        assert json(resp)["errcode"] == "M_INVALID_PARAM"
      else
        assert true
      end
    end

    test "control-char device_id at login → 400", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        bad_id = "evil\x00\ndevice"

        body = %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv, :opaque),
          "refresh_token" => true,
          "device_id" => bad_id
        }

        resp = call(:post, "/_matrix/client/v3/login", body)
        assert resp.status == 400, "a control-char device_id must be rejected at ingress (got #{resp.status})"
        assert json(resp)["errcode"] == "M_INVALID_PARAM"
      else
        assert true
      end
    end

    test "control-char device_id in /keys/upload device_keys → 400", %{priv_jwk: priv, user_id: uid} do
      if Process.whereis(Nebu.Repo) do
        login = login_jwt(priv, %{"device_id" => "GOOD_DEV"})
        at = login["access_token"]

        bad_id = "evil\x7f\x01dev"

        up =
          call(
            :post,
            "/_matrix/client/v3/keys/upload",
            %{"device_keys" => device_keys_obj(uid, bad_id)},
            auth(at)
          )

        assert up.status == 400,
               "a control-char device_id in /keys/upload must be rejected at ingress (got #{up.status})"

        assert json(up)["errcode"] == "M_INVALID_PARAM"
      else
        assert true
      end
    end

    test "oversized device_id in /keys/upload device_keys → 400", %{priv_jwk: priv, user_id: uid} do
      if Process.whereis(Nebu.Repo) do
        login = login_jwt(priv, %{"device_id" => "GOOD_DEV2"})
        at = login["access_token"]

        oversized = String.duplicate("k", 300)

        up =
          call(
            :post,
            "/_matrix/client/v3/keys/upload",
            %{"device_keys" => device_keys_obj(uid, oversized)},
            auth(at)
          )

        assert up.status == 400,
               "an oversized device_id in /keys/upload must be rejected at ingress (got #{up.status})"

        assert json(up)["errcode"] == "M_INVALID_PARAM"
      else
        assert true
      end
    end
  end
end
