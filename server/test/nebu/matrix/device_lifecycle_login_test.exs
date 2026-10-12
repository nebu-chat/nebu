defmodule Nebu.Matrix.DeviceLifecycleLoginTest do
  @moduledoc """
  RED-phase ATDD tests for story S2 "Device lifecycle at login + reliable
  device_id binding" (epic: device-management).

  S2 makes login OWN device creation and makes `conn.assigns[:device_id]`
  authoritative on EVERY authenticated request (opaque AND raw-JWT), removing the
  `sole_device_id/1` heuristic and the cross-device-transfer hole it implied.

  ## Red-phase rationale (historical — describes the PRE-S2 state)

  These notes record why each test FAILED against the code as it stood BEFORE S2 was
  implemented (red-by-construction). They are retained for traceability; S2 has since
  made them all green. Line numbers below are pre-S2 and no longer accurate.

    * AC1 — login did NOT create a `devices` row (`provision_and_respond` generated a
      `device_id` and responded but never called `DeviceKeyStore.upsert_device/3`, and
      `do_login_with` never read `initial_device_display_name`). Now: login owns the
      device upsert.

    * AC2 — login ALWAYS `generate_device_id()`d, so a client re-presenting its own
      `device_id` got a brand-new one each time → a duplicate row. Now: a
      client-supplied device_id is honored and reused.

    * AC3 — `OidcPlug.call_jwt/2` never assigned `:device_id`, so a raw-JWT session had
      no bound device and `GET /account/whoami` omitted `device_id`. Now: the plug
      resolves the device from the server-side token binding.

    * AC4 — `/keys/upload` fell back to `DeviceKeyStore.sole_device_id/1`, which
      mis-attributed (or dropped) OTKs for a genuine multi-device user. Now:
      `sole_device_id/1` is removed; attribution is via `conn.assigns[:device_id]`.

    * G1 — `upload_device_id/2` took the body `device_keys.device_id` as authoritative
      with NO comparison to the token's bound device, so T_A could publish keys for
      DEV_B (cross-device transfer). Now: a body device_id that contradicts the bound
      device is rejected up front.

  The G2/G3 refresh tests mirror the existing `login_refresh_test.exs` invariants —
  the do-not-regress guard. They pass once the device binding (AC3) is observable via
  whoami across a refresh.

  ## Seams (reused verbatim from login_refresh_test.exs / device_keys_test.exs)

    * `:matrix_sso_token_override` — the SSO code-exchange seam. A 3-tuple
      `{:ok, id_token, oidc_refresh_token}` drives the opaque-session login path; a
      2-tuple `{:ok, id_token}` drives the AC7 raw-JWT fallback (login WITHOUT
      `refresh_token: true`). Both are exercised here so we cover opaque AND raw-JWT.
    * `:oidc_jwks` / `:oidc_issuer` / `:oidc_audience` — inject the verifying JWK so
      no network call is needed.

  Tagged `:integration` — runs via `make test-integration`. Real flows only: no
  cookie forging, no DB-seeding of auth state (sessions are minted through the real
  SSO → loginToken → POST /login path).
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
  @kid "device-lifecycle-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])
  @hex64 ~r/^[0-9a-f]{64}$/

  # Per-test-unique sub → per-test-unique Matrix user id (see login_refresh_test.exs:
  # config/test.exs uses a RANDOM pii_encryption_key per boot, so a unique sub per
  # test avoids colliding with another boot's undecryptable PII rows → no login 500).
  defp fresh_sub, do: "dlc" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp current_sub, do: Process.get(:dlc_sub) || raise("sub not set by setup")

  # ── shared helpers ──────────────────────────────────────────────────────────

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
    Application.put_env(:nebu_http, :admin_secret_at_rest, "device-lifecycle-test-internal-secret")

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
  # /login. `exchange` is the value `:matrix_sso_token_override` returns — pass a
  # 3-tuple `{:ok, id_token, rt}` for an opaque-session login, or a 2-tuple
  # `{:ok, id_token}` for the raw-JWT (AC7) path. The id_token MUST carry the
  # callback nonce, so the override is built INSIDE this helper after the nonce is
  # known.
  defp mint_login_token(priv, kind) do
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

    id_token = sign_id_token(priv, %{"sub" => current_sub(), "nonce" => nonce})

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

  # Full opaque-session login → returns the decoded login body (access_token is an
  # opaque Nebu token; device_id is the bound device).
  defp login_opaque(priv, extra_body \\ %{}) do
    body =
      Map.merge(
        %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv, :opaque),
          "refresh_token" => true
        },
        extra_body
      )

    resp = call(:post, "/_matrix/client/v3/login", body)
    assert resp.status == 200, "opaque login must succeed (got #{resp.status}: #{resp.resp_body})"
    json(resp)
  end

  # Full raw-JWT login (AC7 path: no refresh_token) → returns the decoded login body
  # (access_token is the verified OIDC JWT itself; device_id is the bound device).
  defp login_jwt(priv, extra_body \\ %{}) do
    body =
      Map.merge(
        %{"type" => "m.login.token", "token" => mint_login_token(priv, :jwt)},
        extra_body
      )

    resp = call(:post, "/_matrix/client/v3/login", body)
    assert resp.status == 200, "jwt login must succeed (got #{resp.status}: #{resp.resp_body})"
    body = json(resp)
    assert String.contains?(body["access_token"], "."), "AC7 login must return a JWT access_token"
    body
  end

  # matrix-refresh-revalidates-with-idp: /refresh now contacts the IdP before
  # re-minting opaque tokens. These G2/G3 regression tests are about device
  # binding / opaque-token rotation mechanics, not the IdP-contact behavior
  # itself (covered by login_refresh_test.exs) — stub the round-trip with a
  # far-future fresh id_token.exp so it does not interfere with these
  # assertions. Mirrors login_refresh_test.exs's put_matrix_oidc_refresh_override/1.
  defp put_matrix_oidc_refresh_override(fun) do
    Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fun)
    on_exit(fn -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_override) end)
  end

  defp stub_matrix_oidc_refresh_ok do
    put_matrix_oidc_refresh_override(fn _decrypted_rt ->
      {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
    end)
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

  defp otk(id) do
    {"signed_curve25519:#{id}",
     %{
       "key" => "j3fR3HemM16M7CWhoI4Sk5ZsdmdfQHsKL1xuSft6MS#{String.slice(id, 0, 1)}",
       "signatures" => %{"@x" => %{"ed25519:DEV" => "sig"}}
     }}
  end

  setup do
    # Disable the per-IP login limiter LOCALLY (these tests hammer /login + /sync +
    # /refresh from one peer IP). Restore the prior value exactly (mirrors
    # login_refresh_test.exs so the RateLimitTest assertions can't be disturbed).
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
    Process.put(:dlc_sub, sub)
    uid = "@" <> sub <> ":" <> @server_name

    if Process.whereis(Nebu.Repo) do
      _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Alice", "alice@example.com")
      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Alice", nil)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          for table <- ["device_one_time_keys", "device_keys", "devices", "matrix_sessions", "profiles", "users"] do
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

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — Login registers a device.
  # A fresh login with initial_device_display_name "Element Desktop" creates a
  # `devices` row visible in GET /devices with that display_name + created_at.
  #
  # RED: do_login_with/2 never reads initial_device_display_name and
  # provision_and_respond/5 never calls upsert_device/3 — GET /devices is empty.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1 — login registers a device" do
    test "fresh login with initial_device_display_name appears in GET /devices", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login =
          login_opaque(priv, %{"initial_device_display_name" => "Element Desktop"})

        device_id = login["device_id"]
        assert is_binary(device_id) and device_id != ""

        # The opaque AT authenticates GET /devices.
        conn = call(:get, "/_matrix/client/v3/devices", nil, auth(login["access_token"]))
        assert conn.status == 200

        device =
          json(conn)["devices"]
          |> Enum.find(&(&1["device_id"] == device_id))

        assert is_map(device),
               "login must register device #{device_id} in `devices` (visible via GET /devices)"

        assert device["display_name"] == "Element Desktop",
               "the device must carry the initial_device_display_name from login"

        # AC1: created_at / last_seen are recorded for the device. last_seen_ts is the
        # Matrix Device field; assert it is present and an integer ms timestamp.
        assert is_integer(device["last_seen_ts"]),
               "login must record a last_seen_ts for the new device"
      else
        assert true
      end
    end

    test "AC1 (store level) — login creates exactly one devices row carrying created_at", %{
      priv_jwk: priv,
      user_id: uid
    } do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv, %{"initial_device_display_name" => "Element Desktop"})
        device_id = login["device_id"]

        got = DeviceKeyStore.get_device(uid, device_id)
        assert is_map(got), "login must upsert a `devices` row for #{device_id}"
        assert got["device_id"] == device_id

        {:ok, %{rows: [[created_at, cnt]]}} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "SELECT min(created_at)::bigint, count(*)::int FROM devices WHERE user_id = $1 AND device_id = $2",
            [uid, device_id]
          )

        assert cnt == 1, "login must create exactly one row for (#{uid}, #{device_id})"
        assert is_integer(created_at) and created_at > 0, "the device row must carry a created_at"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — stable per-client device_id: reusing a device_id keeps the same row,
  # and initial_device_display_name is IGNORED on reuse (Oracle edge case).
  #
  # RED: do_login_with/2 ignores a client-supplied device_id; provision_and_respond
  # always generate_device_id()s → a reused device_id never round-trips, and each
  # login spawns a NEW device.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2 — client-supplied device_id is reused, not duplicated" do
    test "a login that reuses its device_id keeps the SAME device row (no duplicate)", %{
      priv_jwk: priv,
      user_id: uid
    } do
      if Process.whereis(Nebu.Repo) do
        # First login claims a device_id of the client's choosing.
        first =
          login_opaque(priv, %{
            "device_id" => "MY_STABLE_DEV",
            "initial_device_display_name" => "Element Desktop"
          })

        assert first["device_id"] == "MY_STABLE_DEV",
               "login must honor a client-supplied device_id"

        # Second login (same user) re-presents the SAME device_id with a DIFFERENT
        # display name. Spec: reuse is allowed "provided the user remains the same",
        # and initial_device_display_name is only applied when CREATING the device —
        # it must be IGNORED on reuse.
        second =
          login_opaque(priv, %{
            "device_id" => "MY_STABLE_DEV",
            "initial_device_display_name" => "SHOULD-BE-IGNORED"
          })

        assert second["device_id"] == "MY_STABLE_DEV"

        # Exactly one device row for this (user, device_id) — no duplicate.
        {:ok, %{rows: [[cnt]]}} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "SELECT count(*)::int FROM devices WHERE user_id = $1 AND device_id = $2",
            [uid, "MY_STABLE_DEV"]
          )

        assert cnt == 1, "reusing a device_id must not create a second device row"

        # initial_device_display_name was ignored on reuse → still the original.
        got = DeviceKeyStore.get_device(uid, "MY_STABLE_DEV")
        assert got["display_name"] == "Element Desktop",
               "initial_device_display_name must be ignored when an existing device_id is reused"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — device_id bound to EVERY authenticated request (opaque AND raw-JWT).
  # Asserted via GET /account/whoami returning the login device_id for both
  # session kinds (no sole_device_id fallback).
  #
  # RED: OidcPlug.call_jwt/2 never assigns :device_id, and login (AC7 path) never
  # persists a token→device binding for the JWT, so whoami omits device_id there.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3 — whoami returns the bound device_id for both session kinds" do
    test "opaque session: whoami device_id == login device_id", %{priv_jwk: priv, user_id: uid} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv)

        conn = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(login["access_token"]))
        assert conn.status == 200
        body = json(conn)
        assert body["user_id"] == uid
        assert body["device_id"] == login["device_id"]
      else
        assert true
      end
    end

    test "raw-JWT session: whoami device_id == login device_id (the gap this story closes)", %{
      priv_jwk: priv,
      user_id: uid
    } do
      if Process.whereis(Nebu.Repo) do
        login = login_jwt(priv)
        jwt = login["access_token"]
        assert is_binary(login["device_id"]) and login["device_id"] != ""

        conn = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(jwt))
        assert conn.status == 200
        body = json(conn)
        assert body["user_id"] == uid

        # The crux of S2: a raw-JWT request must resolve to the SAME device_id login
        # bound to that token — NOT omitted, NOT a fresh/heuristic value.
        assert body["device_id"] == login["device_id"],
               "raw-JWT whoami must return the device_id bound at login (no sole_device_id fallback)"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — OTK-only upload attributes to the BOUND device (multi-device).
  # User has two devices; a raw-JWT session bound to DEV_A does an OTK-only
  # /keys/upload (no device_keys body) → the OTKs land on DEV_A, not dropped and
  # not mis-attributed. This is the exact case the sole_device_id heuristic failed.
  #
  # RED: with two devices, sole_device_id/1 returns nil (ambiguous) → upload_device_id
  # returns nil → the OTK-only upload is a no-op (counts stay 0). After S2 the JWT
  # carries a bound device, so the OTKs are attributed to DEV_A.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4 — OTK-only upload uses the token's bound device (multi-device)" do
    test "two devices, JWT bound to DEV_A: OTK-only upload lands on DEV_A", %{
      priv_jwk: priv,
      user_id: uid
    } do
      if Process.whereis(Nebu.Repo) do
        # DEV_A: the device this JWT session is bound to (created at login).
        login_a = login_jwt(priv, %{"device_id" => "DEV_A"})
        assert login_a["device_id"] == "DEV_A"
        token_a = login_a["access_token"]

        # DEV_B: a second, distinct device the same user owns (created via a separate
        # login). This makes the user genuinely multi-device → sole_device_id == nil.
        login_b = login_jwt(priv, %{"device_id" => "DEV_B"})
        assert login_b["device_id"] == "DEV_B"

        # Sanity: the user now has (at least) two devices.
        assert length(DeviceKeyStore.list_devices(uid)) >= 2

        # OTK-only upload on the DEV_A-bound session — NO device_keys in the body.
        otks = Map.new(["A1", "A2", "A3"], &otk/1)
        up = call(:post, "/_matrix/client/v3/keys/upload", %{"one_time_keys" => otks}, auth(token_a))
        assert up.status == 200

        # The OTKs were attributed to DEV_A (the bound device), returned in the counts.
        assert json(up)["one_time_key_counts"]["signed_curve25519"] == 3,
               "OTK-only upload on a multi-device JWT session must attribute to the bound DEV_A"

        # And at the store level the OTKs sit on DEV_A specifically, not DEV_B.
        assert DeviceKeyStore.otk_counts(uid, "DEV_A")["signed_curve25519"] == 3
        assert (DeviceKeyStore.otk_counts(uid, "DEV_B")["signed_curve25519"] || 0) == 0,
               "the OTKs must NOT land on DEV_B"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # SECURITY G1 (AC6) — no cross-device transfer.
  # A session bound to DEV_A (token T_A) plus a separate device DEV_B. A request
  # with T_A naming DEV_B (/keys/upload device_keys.device_id = "DEV_B") is
  # REJECTED; DEV_B's keys are unchanged.
  #
  # RED: upload_device_id/2 takes the body device_keys.device_id as authoritative
  # with NO check against the token's bound device → T_A successfully writes DEV_B's
  # keys (cross-device transfer). After S2 the body device_id must match the bound
  # device or the request is rejected.
  # ══════════════════════════════════════════════════════════════════════════

  describe "SECURITY G1 (AC6) — a token cannot publish keys for another device" do
    test "T_A naming DEV_B → rejected; DEV_B keys unchanged", %{priv_jwk: priv, user_id: uid} do
      if Process.whereis(Nebu.Repo) do
        # DEV_A bound to T_A.
        login_a = login_jwt(priv, %{"device_id" => "DEV_A"})
        token_a = login_a["access_token"]

        # DEV_B is a separate device with its OWN published keys (uploaded by a
        # legitimately-DEV_B-bound session).
        login_b = login_jwt(priv, %{"device_id" => "DEV_B"})
        token_b = login_b["access_token"]
        dev_b_keys = device_keys_obj(uid, "DEV_B")

        ok_b =
          call(
            :post,
            "/_matrix/client/v3/keys/upload",
            %{"device_keys" => dev_b_keys},
            auth(token_b)
          )

        assert ok_b.status == 200

        before =
          DeviceKeyStore.query_devices([uid]) |> get_in([uid, "DEV_B", "keys"])

        assert before == dev_b_keys["keys"], "precondition: DEV_B has its own keys"

        # ATTACK: T_A (bound to DEV_A) tries to publish keys naming DEV_B. The body
        # device_id contradicts the token's bound device → must be rejected (spec:
        # device_keys device_id "Must match the device ID used when logging in").
        attack =
          call(
            :post,
            "/_matrix/client/v3/keys/upload",
            %{
              "device_keys" =>
                device_keys_obj(uid, "DEV_B")
                |> Map.put("keys", %{"ed25519:DEV_B" => "ATTACKER_FORGED_KEY"})
            },
            auth(token_a)
          )

        assert attack.status in [400, 403],
               "T_A must NOT be allowed to publish keys for DEV_B (got #{attack.status})"

        assert json(attack)["errcode"] in ["M_FORBIDDEN", "M_INVALID_PARAM"]

        # DEV_B's keys are unchanged by the rejected attack.
        after_attack =
          DeviceKeyStore.query_devices([uid]) |> get_in([uid, "DEV_B", "keys"])

        assert after_attack == dev_b_keys["keys"],
               "the rejected cross-device upload must not have mutated DEV_B's keys"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # SECURITY G2 (AC7) — refresh keeps the device binding.
  # A session bound to DEV_A with a refresh token: POST /refresh → the new access
  # token resolves to DEV_A (device_id unchanged), asserted via whoami before/after.
  #
  # rotate_tokens/1 already carries device_id forward, so this guards against
  # regression. It is RED today only because the rotated token's device is asserted
  # via whoami, which requires AC3's binding to be observable.
  # ══════════════════════════════════════════════════════════════════════════

  describe "SECURITY G2 (AC7) — refresh does not re-bind the device" do
    test "device_id is identical before and after /refresh (whoami)", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv, %{"device_id" => "DEV_A"})
        at_before = login["access_token"]
        rt = login["refresh_token"]

        who_before = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(at_before))
        assert who_before.status == 200
        device_before = json(who_before)["device_id"]
        assert device_before == "DEV_A"

        stub_matrix_oidc_refresh_ok()
        refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
        assert refresh.status == 200
        at_after = json(refresh)["access_token"]
        assert at_after != at_before

        who_after = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(at_after))
        assert who_after.status == 200
        device_after = json(who_after)["device_id"]

        assert device_after == device_before,
               "the rotated access token must stay bound to the same device_id"
        assert device_after == "DEV_A"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # REGRESSION G3 (AC7) — the refresh feature must not regress.
  # Mirrors the oidc-session-refresh invariants (login_refresh_test.exs) so this
  # story's changes are caught if they break /refresh:
  #   * /refresh → new access_token + refresh_token + expires_in_ms
  #   * old RT stays valid while pending, then is revoked once the new AT is used
  #   * an expired AT → 401 M_UNKNOWN_TOKEN with soft_logout: true
  # These SHOULD stay green; they are mirrored (not duplicate-broken).
  # ══════════════════════════════════════════════════════════════════════════

  describe "REGRESSION G3 (AC7) — refresh flow intact" do
    test "/refresh returns new opaque AT + RT + expires_in_ms", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv)
        rt = login["refresh_token"]

        stub_matrix_oidc_refresh_ok()
        refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
        assert refresh.status == 200
        rbody = json(refresh)

        assert is_binary(rbody["access_token"])
        refute String.contains?(rbody["access_token"], ".")
        assert Regex.match?(@hex64, rbody["access_token"])
        assert is_binary(rbody["refresh_token"])
        assert is_integer(rbody["expires_in_ms"]) and rbody["expires_in_ms"] > 0

        # The new AT is immediately usable.
        sync = call(:get, "/_matrix/client/v3/sync", nil, auth(rbody["access_token"]))
        assert sync.status == 200
      else
        assert true
      end
    end

    test "rotated-then-used old RT → 401 M_UNKNOWN_TOKEN (RT consumed)", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv)
        rt_a = login["refresh_token"]

        stub_matrix_oidc_refresh_ok()
        refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt_a})
        assert refresh.status == 200
        at_b = json(refresh)["access_token"]

        # Use the new AT once — consumes the old RT row.
        assert call(:get, "/_matrix/client/v3/sync", nil, auth(at_b)).status == 200

        reuse = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt_a})
        assert reuse.status == 401
        assert json(reuse)["errcode"] == "M_UNKNOWN_TOKEN"
      else
        assert true
      end
    end

    test "expired opaque AT → 401 M_UNKNOWN_TOKEN with soft_logout: true", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv)
        at = login["access_token"]

        {:ok, _} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "UPDATE matrix_sessions SET expires_at = NOW() - INTERVAL '1 second' WHERE access_token_hash = $1",
            [Nebu.Matrix.Session.MatrixSessionStore.hash_token(at)]
          )

        resp = call(:get, "/_matrix/client/v3/sync", nil, auth(at))
        assert resp.status == 401
        body = json(resp)
        assert body["errcode"] == "M_UNKNOWN_TOKEN"
        assert body["soft_logout"] == true
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — last_seen_ts advances on authenticated activity (/sync), but is
  # THROTTLED so it does not write on every request.
  #
  # Deterministic (no sleep): after login, force the device's last_seen_ts into
  # the past via SQL, issue /sync, and assert it advanced (update happened). Then
  # immediately issue a SECOND /sync and assert last_seen_ts did NOT advance again
  # within the throttle window (proves the per-request write is throttled).
  #
  # RED: the request pipeline never touches `devices.last_seen_ts` on /sync, so it
  # stays at the rewound value — the first assertion (advancement) fails today.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5 — /sync advances last_seen_ts, throttled" do
    test "first /sync advances last_seen_ts; an immediate second /sync does not (throttle)", %{
      priv_jwk: priv,
      user_id: uid
    } do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv, %{"device_id" => "DEV_SEEN"})
        at = login["access_token"]
        assert login["device_id"] == "DEV_SEEN"

        # Force last_seen_ts well into the past so any throttle window has elapsed
        # and a real update is observable as a strict increase.
        rewound = System.system_time(:millisecond) - 3_600_000

        {:ok, _} =
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "UPDATE devices SET last_seen_ts = $1 WHERE user_id = $2 AND device_id = $3",
            [rewound, uid, "DEV_SEEN"]
          )

        before = DeviceKeyStore.get_device(uid, "DEV_SEEN")["last_seen_ts"]
        assert before == rewound, "precondition: last_seen_ts rewound to the past"

        # First authenticated /sync must advance last_seen_ts (best-effort update).
        assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200

        after_first = DeviceKeyStore.get_device(uid, "DEV_SEEN")["last_seen_ts"]

        assert is_integer(after_first) and after_first > rewound,
               "an authenticated /sync must advance the device's last_seen_ts (AC5)"

        # Second immediate /sync must NOT advance it again — the write is throttled
        # so we don't hammer the DB on every request.
        assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200

        after_second = DeviceKeyStore.get_device(uid, "DEV_SEEN")["last_seen_ts"]

        assert after_second == after_first,
               "an immediate second /sync must NOT re-write last_seen_ts (AC5 throttle)"
      else
        assert true
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Oracle edge case — GET /devices/{deviceId} for an unknown device → 404.
  # (Locks the per-device read contract for a session that genuinely has devices.)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Oracle edge — GET /devices/{deviceId} unknown → 404" do
    test "an authenticated session reading a non-existent device → 404 M_NOT_FOUND", %{priv_jwk: priv} do
      if Process.whereis(Nebu.Repo) do
        login = login_opaque(priv, %{"initial_device_display_name" => "Element Desktop"})

        conn =
          call(
            :get,
            "/_matrix/client/v3/devices/NO_SUCH_DEVICE_#{System.unique_integer([:positive])}",
            nil,
            auth(login["access_token"])
          )

        assert conn.status == 404
        assert json(conn)["errcode"] == "M_NOT_FOUND"
      else
        assert true
      end
    end
  end
end
