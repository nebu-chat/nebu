defmodule Nebu.Web.AdminOidcLoginTest do
  @moduledoc """
  ATDD unit tests for the go-removal-cleanup story — Elixir admin OIDC
  Authorization-Code + PKCE login (Nebu.Admin.Auth.login_start/2, callback/2,
  logout/2). These replace the deleted Go gateway admin login.

  ## Why these MUST FAIL before the dev step (RED)

    * Before implementation, `Admin.Auth.login_start/2` did not exist — only the
      on_mount gate + put_current_user. `LoginController.start/2` redirected to
      itself (infinite loop). There was no callback, no PKCE, no state/nonce, no
      exchange.

  ## What is covered here vs the E2E

  The E2E (e2e/features/admin/admin-oidc-login.feature) drives the REAL Dex
  Authorization-Code + PKCE flow end-to-end in a browser (no cookie forging, no DB
  seeding). It requires the live Dex/Compose stack and so is deferred in this
  environment. These unit tests cover the security-sensitive logic that does NOT
  require a network round-trip:

    * login_start emits a PKCE S256 challenge derived from the verifier, plus a
      high-entropy state + nonce, and stashes the verifier/state/nonce in the
      signed Phoenix session (NOT a separate cookie).
    * callback rejects a missing / mismatched / expired state (CSRF / replay).
    * the ID-token nonce binding (fail-closed) is enforced.
    * the admin-group-claim gate denies a non-admin token.

  The token-EXCHANGE HTTP round-trip and full happy-path session mint are covered
  by the E2E (live Dex) — they cannot be exercised without a token endpoint.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @audience "nebu-admin"
  @client_id "nebu-admin"
  @kid "admin-key-1"

  # Authorization endpoint returned by the discovery override so login_start can build
  # the redirect without a network call.
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"

  setup do
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

    # oidc-bootstrap-only-config (ADR-022): issuer/audience resolve via OidcConfig,
    # the single admin OIDC client via the :admin_oidc_config_reader seam, and the
    # redirect_uri is DERIVED from :server_name + :admin_session_secure (no env path).
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :admin_secret_at_rest, "admin-oidc-login-test-key")

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    # Derive http://localhost:8008/admin/callback: localhost host + insecure scheme.
    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :oidc_jwks,
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    {:ok, priv_jwk: priv_map}
  end

  # Build a conn that already has a fetched (signed) session — Plug.Test.init_test_session
  # gives us put_session/get_session without the full endpoint pipeline.
  defp session_conn(method, path) do
    conn(method, path) |> init_test_session(%{})
  end

  defp sign_id_token(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  # ── login_start: PKCE + state + nonce ──────────────────────────────────────────

  test "login_start redirects to the IdP with PKCE S256 challenge, state and nonce" do
    conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

    assert conn.halted
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, @authorization_endpoint <> "?")

    %URI{query: query} = URI.parse(location)
    params = URI.decode_query(query)

    assert params["response_type"] == "code"
    assert params["client_id"] == @client_id
    assert params["redirect_uri"] == "http://localhost:8008/admin/callback"
    assert params["code_challenge_method"] == "S256"
    assert byte_size(params["code_challenge"]) > 20
    assert byte_size(params["state"]) > 8
    assert byte_size(params["nonce"]) > 8

    # The verifier is stashed server-side (signed session), NOT exposed in the URL.
    login_state = get_session(conn, "admin_oidc_login")
    assert is_binary(login_state["verifier"])
    assert login_state["state"] == params["state"]
    assert login_state["nonce"] == params["nonce"]
    refute query =~ login_state["verifier"]

    # The challenge MUST equal BASE64URL(SHA256(verifier)) (RFC 7636 S256).
    expected_challenge =
      :crypto.hash(:sha256, login_state["verifier"]) |> Base.url_encode64(padding: false)

    assert params["code_challenge"] == expected_challenge
  end

  test "login_start generates a fresh state + nonce on each call (no reuse)" do
    s1 = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{}) |> get_session("admin_oidc_login")
    s2 = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{}) |> get_session("admin_oidc_login")

    refute s1["state"] == s2["state"]
    refute s1["nonce"] == s2["nonce"]
    refute s1["verifier"] == s2["verifier"]
  end

  # ── callback: state / CSRF protection ───────────────────────────────────────────

  test "callback with NO prior login state (forged) is rejected 400" do
    conn =
      session_conn(:get, "/admin/callback")
      |> Auth.callback(%{"code" => "x", "state" => "forged"})

    assert conn.halted
    assert conn.status == 400
  end

  test "callback with a mismatched state is rejected 400 and clears login state" do
    conn =
      session_conn(:get, "/admin/callback")
      |> put_session("admin_oidc_login", %{
        "state" => "expected-state",
        "verifier" => "v",
        "nonce" => "n",
        "exp" => System.system_time(:second) + 600
      })
      |> Auth.callback(%{"code" => "x", "state" => "attacker-state"})

    assert conn.halted
    assert conn.status == 400
    assert get_session(conn, "admin_oidc_login") == nil
  end

  test "callback with an expired login state is rejected 400" do
    conn =
      session_conn(:get, "/admin/callback")
      |> put_session("admin_oidc_login", %{
        "state" => "s",
        "verifier" => "v",
        "nonce" => "n",
        "exp" => System.system_time(:second) - 1
      })
      |> Auth.callback(%{"code" => "x", "state" => "s"})

    assert conn.halted
    assert conn.status == 400
  end

  test "callback with a missing code (state valid) bounces to login with error" do
    conn =
      session_conn(:get, "/admin/callback")
      |> put_session("admin_oidc_login", %{
        "state" => "s",
        "verifier" => "v",
        "nonce" => "n",
        "exp" => System.system_time(:second) + 600
      })
      |> Auth.callback(%{"state" => "s"})

    assert conn.halted
    assert conn.status == 302
    assert [loc] = get_resp_header(conn, "location")
    assert loc =~ "/admin/login?error="
  end

  # ── nonce binding (fail-closed) — verified through the verify_token + check_nonce path
  # via the public admin_claim?/nonce helpers is internal; here we assert the end-to-end
  # contract that the ID-token verification reused from OidcPlug rejects a tampered token.

  test "the ID-token verifier (reused from OidcPlug) accepts a well-formed admin token", %{
    priv_jwk: priv_jwk
  } do
    # The admin ID token's aud is the admin OAuth client_id, verified via the override.
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "kai",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => "the-nonce",
      "groups" => ["instance_admin"]
    }

    token = sign_id_token(claims, priv_jwk)
    assert {:ok, verified} = Nebu.Web.Plugs.OidcPlug.verify_token(token, audience: @client_id)
    assert verified["nonce"] == "the-nonce"
    # Admin gate: the configured claim (default instance_admin) present in a list claim.
    assert Auth.admin_claim?(verified)
  end

  test "admin gate denies a token without the admin group claim", %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "alex",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => "the-nonce",
      "groups" => ["users"]
    }

    token = sign_id_token(claims, priv_jwk)
    assert {:ok, verified} = Nebu.Web.Plugs.OidcPlug.verify_token(token, audience: @client_id)
    refute Auth.admin_claim?(verified)
  end

  test "admin audience override rejects a token minted for the Matrix audience (no aud confusion)",
       %{priv_jwk: priv_jwk} do
    # A Matrix-audience token (aud = nebu-gateway) must NOT be accepted on the admin
    # path, which requires aud = the admin client_id. Fail-closed audience check.
    claims = %{
      "iss" => @issuer,
      "aud" => "nebu-gateway",
      "sub" => "kai",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => "the-nonce",
      "groups" => ["instance_admin"]
    }

    token = sign_id_token(claims, priv_jwk)
    assert {:error, :bad_audience} = Nebu.Web.Plugs.OidcPlug.verify_token(token, audience: @client_id)
  end

  # ── admin gate: nested (Keycloak-shaped) claims ─────────────────────────────────
  #
  # Keycloak's standard role claims are nested (`realm_access.roles`,
  # `resource_access.<client>.roles`) rather than flat top-level string/list-of-strings
  # like Dex's `groups`. `admin_claim?/1` must find the configured marker anywhere in
  # the claims tree, at any nesting depth, while remaining backward compatible with
  # flat claims (see the `groups` tests above, still unchanged).

  test "admin gate matches a Keycloak-shaped token via realm_access.roles (one level of nesting)" do
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "kai",
      "realm_access" => %{"roles" => ["instance_admin", "offline_access"]}
    }

    assert Auth.admin_claim?(claims)
  end

  test "admin gate denies a Keycloak-shaped token without the admin marker anywhere" do
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "alex",
      "realm_access" => %{"roles" => ["offline_access"]},
      "resource_access" => %{"nebu-admin" => %{"roles" => ["uma_authorization"]}}
    }

    refute Auth.admin_claim?(claims)
  end

  test "admin gate matches resource_access.<client>.roles (two levels of nesting)" do
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "kai",
      "realm_access" => %{"roles" => ["offline_access"]},
      "resource_access" => %{"nebu-admin" => %{"roles" => ["instance_admin"]}}
    }

    assert Auth.admin_claim?(claims)
  end

  test "admin gate still matches flat Dex-style groups claims (backward compatibility)" do
    assert Auth.admin_claim?(%{"sub" => "kai", "groups" => ["instance_admin"]})
    refute Auth.admin_claim?(%{"sub" => "alex", "groups" => ["users"]})
  end

  test "admin gate still matches a bare top-level string claim (backward compatibility)" do
    assert Auth.admin_claim?(%{"sub" => "kai", "role" => "instance_admin"})
    refute Auth.admin_claim?(%{"sub" => "alex", "role" => "user"})
  end

  # Historical note: before story scope-admin-claim-to-path, this test documented an
  # ACCEPTED RISK — admin_claim?/1 scanned every claim value regardless of key, so a
  # nested attacker-influenceable claim matching the marker was misclassified as admin.
  # With NO admin_group_claim_path configured (the case here — the setup/0 reader
  # returns nil for it), admin_claim?/1 falls back to that exact legacy any-key scan
  # (AC3.2 — deliberately NOT a regression, it IS pre-story behavior). This test now
  # pins the FALLBACK branch rather than "the" behavior — see the AC4 test below for the
  # actual fix, which applies once a path IS configured.
  test "admin gate (no path configured) falls back to legacy any-key scan — matches a nested attacker-influenceable claim" do
    claims = %{
      "sub" => "alex",
      "profile" => %{"custom_role" => "instance_admin"}
    }

    assert Auth.admin_claim?(claims)
  end

  # ── admin gate: PATH-scoped check (story scope-admin-claim-to-path, AC4/AC5) ────
  #
  # Closes the risk demonstrated by the fallback test above: once an
  # `admin_group_claim_path` is configured, the marker must appear AT THAT PATH — a
  # hit anywhere else in the claims tree (e.g. a self-editable `name` claim) no
  # longer counts.

  describe "admin gate — path-scoped (AC4/AC5)" do
    setup do
      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "oidc_client_id" -> @client_id
        "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
        "admin_group_claim_path" -> "groups"
        _ -> nil
      end)

      :ok
    end

    test "AC4 — a self-editable claim matching the marker value is NOT admin when the path is scoped elsewhere" do
      claims = %{
        "sub" => "alex",
        "groups" => ["user"],
        "name" => "instance_admin"
      }

      refute Auth.admin_claim?(claims)
    end

    test "AC5 — a real admin (marker present at the configured path) is still classified as admin" do
      claims = %{
        "sub" => "kai",
        "groups" => ["instance_admin"]
      }

      assert Auth.admin_claim?(claims)
    end
  end

  test "AC5 — fallback path (no admin_group_claim_path configured) still classifies a real admin correctly (no regression)" do
    # setup/0's default reader returns nil for admin_group_claim_path — same as an
    # existing deployment bootstrapped before this story shipped.
    claims = %{"sub" => "kai", "groups" => ["instance_admin"]}

    assert Auth.admin_claim?(claims)
  end

  # ── extract_discovered_claims: nested (Keycloak-shaped) claim discovery ─────────

  test "extract_discovered_claims surfaces nested realm_access.roles as selectable options" do
    claims = %{
      "sub" => "kai",
      "realm_access" => %{"roles" => ["instance_admin", "offline_access"]}
    }

    discovered = Auth.extract_discovered_claims(claims)

    assert {"realm_access.roles", "instance_admin"} in discovered
    assert {"realm_access.roles", "offline_access"} in discovered
    assert {"sub", "kai"} in discovered
  end

  test "extract_discovered_claims surfaces resource_access.<client>.roles (two levels of nesting)" do
    claims = %{
      "resource_access" => %{"nebu-admin" => %{"roles" => ["instance_admin"]}}
    }

    discovered = Auth.extract_discovered_claims(claims)

    assert {"resource_access.nebu-admin.roles", "instance_admin"} in discovered
  end

  test "extract_discovered_claims still surfaces flat Dex-style claims unchanged (backward compatibility)" do
    discovered = Auth.extract_discovered_claims(%{"sub" => "kai", "groups" => ["instance_admin"]})

    assert {"sub", "kai"} in discovered
    assert {"groups", "instance_admin"} in discovered
  end

  # ── session minting + expiry cap (session fixation / unbounded session) ─────────

  test "put_current_user caps session_exp at min(idToken.exp, now+8h)" do
    now = System.system_time(:second)

    # ID token expiring in 1h → session_exp follows the (earlier) token exp.
    short = %{"sub" => "kai", "exp" => now + 3600, "groups" => ["instance_admin"]}
    conn = session_conn(:get, "/admin/callback") |> Auth.put_current_user(short)
    user = get_session(conn, "current_user")
    assert user["session_exp"] == now + 3600
    assert user["admin"] == true

    # ID token expiring in 100h → session_exp is capped at the 8h ceiling.
    long = %{"sub" => "kai", "exp" => now + 100 * 3600, "groups" => ["instance_admin"]}
    conn2 = session_conn(:get, "/admin/callback") |> Auth.put_current_user(long)
    user2 = get_session(conn2, "current_user")
    assert user2["session_exp"] <= now + 8 * 3600 + 2
    assert user2["session_exp"] > now + 8 * 3600 - 2
  end

  test "on_mount denies an admin whose capped session has expired" do
    expired = %{"admin" => true, "sub" => "kai", "session_exp" => System.system_time(:second) - 1}
    assert {:halt, _socket} = Auth.on_mount(:require_admin, %{}, %{"current_user" => expired}, %Phoenix.LiveView.Socket{})

    live = %{"admin" => true, "sub" => "kai", "session_exp" => System.system_time(:second) + 600}
    assert {:cont, _socket} = Auth.on_mount(:require_admin, %{}, %{"current_user" => live}, %Phoenix.LiveView.Socket{})
  end

  test "on_mount denies an unauthenticated / non-admin session" do
    assert {:halt, _} = Auth.on_mount(:require_admin, %{}, %{}, %Phoenix.LiveView.Socket{})
    assert {:halt, _} = Auth.on_mount(:require_admin, %{}, %{"current_user" => %{"admin" => false}}, %Phoenix.LiveView.Socket{})
  end

  # ── logout ──────────────────────────────────────────────────────────────────────

  test "logout drops the session and redirects to /admin/login" do
    conn =
      session_conn(:get, "/admin/logout")
      |> put_session("current_user", %{"admin" => true, "sub" => "kai"})
      |> Auth.logout(%{})

    assert conn.halted
    assert conn.status == 302
    assert [loc] = get_resp_header(conn, "location")
    assert loc == "/admin/login"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # ATDD (RED phase) — story `provision-matrix-identity-on-admin-login`
  # (epic oidc-simplification), Step 2 of the nebu-pipeline.
  #
  # ## The bug
  #
  # The Matrix-client login path (`POST /_matrix/client/v3/login` →
  # `Nebu.Matrix.HttpPublic.provision_and_respond/6`) provisions a `users` DB row
  # on every login (`TokenValidator.validate/4` → `Profile.DB.upsert_profile/3`)
  # and — only for brand-new users — triggers
  # `EventDispatcher.Server.run_post_login_provisioning/2` (personal room +
  # auto-join). `normal_callback/2` and `bootstrap_confirm_claim/2` (this file's
  # existing subject) mint ONLY the Phoenix admin session via
  # `put_current_user/2` — no Matrix-domain write happens at all. An
  # admin-UI-only operator therefore never gets a `users` row and is invisible
  # to `GET /admin/users` (`Nebu.Admin.DB.list_users/3` reads exclusively from
  # that table), even though their `matrix_user_id` can already act (create
  # rooms, assign memberships) per the prior story
  # `fix-bootstrap-admin-session-identity`.
  #
  # ## Why these MUST FAIL now (RED)
  #
  # No production code calls any Matrix-domain provisioning function from
  # `normal_callback/2` or `bootstrap_confirm_claim/2` today — the whole call
  # graph out of `admin/auth.ex` after a successful OIDC callback is
  # `put_current_user/2` (+ `store_refresh_token/2` for the normal path) and a
  # redirect. So:
  #   * AC1 tests fail because `FakeTokenValidator.validate/4` (installed via
  #     the SAME `:session_manager, :validator_module` seam
  #     `oidc_plug_test.exs`/`auto_join_rooms_test.exs` use for the real Matrix
  #     login path) is never invoked by an admin login.
  #   * AC2's no-auto-join assertion is vacuously true right now (nothing is
  #     provisioned at all) — it is written so it keeps passing after AC1 ships
  #     UNLESS the dev deliberately wires auto-join in too (see note below).
  #   * AC3/AC5 fail because no `users` row exists for the admin-only login, so
  #     it cannot appear in `Nebu.Admin.DB.list_users/3`.
  #   * AC4 fails/is-inapplicable today for the same reason as AC1 (there is no
  #     prior admin-provisioned row for a subsequent Matrix login to collide
  #     with) — once AC1 ships, this guards the idempotent-upsert invariant.
  #
  # ## Test seams used (existing conventions, not invented here)
  #
  #   * `:session_manager, :validator_module` — the SAME behaviour-based DI
  #     point `Nebu.Matrix.Session.TokenValidator.validate/4` reads through
  #     (see `test/nebu/web/oidc_plug_test.exs`,
  #     `test/nebu/matrix/event_dispatcher/auto_join_rooms_test.exs`). Tests
  #     assert THAT the admin login path drives some call ending in a
  #     `users`-row upsert with the correct `matrix_user_id` — not any
  #     particular `Nebu.Matrix` facade function name (the story text
  #     explicitly leaves that name to dev's judgement; ADR-020 only requires
  #     it be reached via `Nebu.Matrix`, never a submodule directly).
  #   * `:event_dispatcher, :messages_db_module` + the registered
  #     `:auto_join_test_listener` process — mirrors
  #     `auto_join_rooms_test.exs`'s `FakeMessagesDB_AutoJoinRoom` pattern, used
  #     here to deterministically observe whether
  #     `ensure_auto_join_memberships/1` (part of
  #     `run_post_login_provisioning/2`) was triggered by an admin-only login.
  #   * `:admin_oidc_token_override` / `with_login_state/1`-equivalent — the
  #     existing normal-mode callback seam (see
  #     `admin_token_refresh_test.exs`).
  #   * `:admin_bootstrap_store` — the existing injectable bootstrap draft/config
  #     dispatcher (see `bootstrap_admin_session_identity_test.exs`), reused
  #     here for the `bootstrap_confirm_claim/2` half of AC1.
  #   * AC3/AC5 (real `users`-row visibility in `GET /admin/users`) require an
  #     actual `users` table — these are tagged `:integration` and run against a
  #     live PostgreSQL (`NEBU_DB_URL`), mirroring
  #     `test/nebu/admin/search_users_db_test.exs`. They are excluded from the
  #     plain unit run and exercised via `make test-integration` / the
  #     redeployed stack, per this repo's existing convention for DB-backed
  #     admin tests.
  describe "AC1: normal_callback/2 provisions the Matrix identity (same path as Matrix login)" do
    defmodule FakeTokenValidator_Provisioned do
      @moduledoc false
      @behaviour Nebu.Matrix.Session.TokenValidator

      @impl true
      def validate(user_id, system_role, display_name, email) do
        send(
          :provision_test_listener,
          {:validate_called, user_id, system_role, display_name, email}
        )

        {:ok,
         %{
           user_id: user_id,
           system_role: system_role,
           display_name: display_name,
           is_active: true,
           is_new: true
         }}
      end
    end

    setup do
      Application.put_env(:session_manager, :validator_module, FakeTokenValidator_Provisioned)
      Process.register(self(), :provision_test_listener)

      on_exit(fn ->
        Application.delete_env(:session_manager, :validator_module)

        if Process.whereis(:provision_test_listener) == self() do
          Process.unregister(:provision_test_listener)
        end
      end)

      :ok
    end

    test "a successful normal_callback/2 login triggers the SAME provisioning path a Matrix login uses" do
      claims = %{
        "sub" => "kai",
        "email" => "kai@example.com",
        "nonce" => "the-nonce",
        "exp" => System.system_time(:second) + 3600,
        "groups" => ["instance_admin"]
      }

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims, nil} end)

      on_exit(fn -> Application.delete_env(:nebu_http, :admin_oidc_token_override) end)

      conn =
        session_conn(:get, "/admin/callback")
        |> put_session("admin_oidc_login", %{
          "state" => "the-state",
          "verifier" => "the-verifier",
          "nonce" => "the-nonce",
          "exp" => System.system_time(:second) + 600,
          "mode" => nil
        })
        |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/dashboard"]

      expected_user_id = Nebu.Matrix.UserId.from_claims(claims, "localhost")

      assert_received {:validate_called, ^expected_user_id, _role, _display_name, _email},
                       "AC1: normal_callback/2 must provision the SAME matrix_user_id " <>
                         "(#{inspect(expected_user_id)}) the session carries, via the same " <>
                         "TokenValidator.validate/4 path (or its Nebu.Matrix-facade equivalent) " <>
                         "the real Matrix /login path uses. No {:validate_called, ...} message " <>
                         "was received — the admin login path currently does not provision at all."
    end

    test "a successful bootstrap_confirm_claim/2 completion ALSO provisions the Matrix identity" do
      claims = %{
        "sub" => "abc-123",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      }

      encrypted_secret = Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")

      draft = %{
        "instance_name" => "test-nebu",
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => encrypted_secret,
        "oidc_audience" => @audience,
        "oidc_user_id_claim" => "sub",
        "bootstrap_sub" => claims["sub"],
        "bootstrap_email" => claims["email"],
        "bootstrap_claims" =>
          Auth.extract_discovered_claims(claims) |> Enum.map(fn {k, v} -> [k, v] end) |> Jason.encode!(),
        "bootstrap_full_claims" => Jason.encode!(claims)
      }

      store = start_supervised!({Agent, fn -> %{draft: draft, config: %{}} end})

      dispatcher = fn
        :load_draft, [] -> {:ok, Agent.get(store, & &1.draft)}
        :put_draft, [k, v] -> Agent.update(store, &put_in(&1, [:draft, k], v)) && :ok
        :clear_draft, [] -> Agent.update(store, &%{&1 | draft: %{}}) && :ok
        :put_config, [k, v] -> Agent.update(store, &put_in(&1, [:config, k], v)) && :ok
        :bootstrap_completed?, [] -> {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
      end

      Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_bootstrap_store) end)

      conn =
        session_conn(:post, "/admin/bootstrap/select-claim")
        |> Auth.bootstrap_confirm_claim(%{
          "admin_group_claim_choice" => Jason.encode!(%{"value" => "instance_admin", "path" => "groups"})
        })

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/dashboard"]

      expected_user_id = Nebu.Matrix.UserId.from_claims(claims, "localhost")

      assert_received {:validate_called, ^expected_user_id, _role, _display_name, _email},
                       "AC1: bootstrap_confirm_claim/2 must ALSO provision the Matrix identity " <>
                         "for #{inspect(expected_user_id)} — bootstrap completion is a login too."
    end

    test "provisioning is idempotent — a second admin login for the SAME identity does not error" do
      claims = %{
        "sub" => "kai",
        "email" => "kai@example.com",
        "nonce" => "the-nonce",
        "exp" => System.system_time(:second) + 3600,
        "groups" => ["instance_admin"]
      }

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims, nil} end)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_oidc_token_override) end)

      login = fn ->
        session_conn(:get, "/admin/callback")
        |> put_session("admin_oidc_login", %{
          "state" => "the-state",
          "verifier" => "the-verifier",
          "nonce" => "the-nonce",
          "exp" => System.system_time(:second) + 600,
          "mode" => nil
        })
        |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})
      end

      conn1 = login.()
      assert conn1.status == 302
      assert get_resp_header(conn1, "location") == ["/admin/dashboard"]

      conn2 = login.()
      assert conn2.status == 302
      assert get_resp_header(conn2, "location") == ["/admin/dashboard"],
             "AC1: re-provisioning the same identity on a second admin login must not error " <>
               "or divert away from the normal dashboard redirect (idempotent upsert)"

      expected_user_id = Nebu.Matrix.UserId.from_claims(claims, "localhost")

      assert_received {:validate_called, ^expected_user_id, _role, _display_name, _email}
      assert_received {:validate_called, ^expected_user_id, _role, _display_name, _email},
                       "expected TWO provisioning calls (one per login), both succeeding"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — architecture decision: admin-only provisioning must NOT trigger
  # auto-join by default (this project's recommendation). Written to assert the
  # RECOMMENDED behavior. If the dev deviates with a documented justification
  # in the story/PR (per AC2's own text, this is allowed), THIS test's
  # expectation must flip from `refute_received` to `assert_received` and the
  # comment updated to point at that justification — do not silently delete it.
  # ══════════════════════════════════════════════════════════════════════════
  describe "AC2: admin-only login provisioning does NOT trigger auto-join by default" do
    defmodule FakeTokenValidator_NewUser do
      @moduledoc false
      @behaviour Nebu.Matrix.Session.TokenValidator

      @impl true
      def validate(user_id, system_role, display_name, _email) do
        {:ok,
         %{
           user_id: user_id,
           system_role: system_role,
           display_name: display_name,
           is_active: true,
           # Brand-new identity — this is exactly the condition
           # run_post_login_provisioning/2 uses to gate auto-join on the real
           # Matrix login path. If admin provisioning reuses that same
           # is_new-gated call, auto-join would fire here too unless AC2's
           # recommendation is honoured.
           is_new: true
         }}
      end
    end

    # test-review (Step 3, MAJOR-1 fix): the ORIGINAL version of this fake
    # asserted on `insert_member/2` (a real auto-join room + a listener
    # message on membership insert), mirroring
    # auto_join_rooms_test.exs's FakeMessagesDB_AutoJoinRoom. That assertion
    # was structurally vacuous: the actual join-success WRITE happens via
    # `Nebu.Matrix.Room.Server.join/2`, a real GenServer reached through
    # `Horde.DynamicSupervisor` (`RoomSupervisor.start_room/1`) — and *that*
    # process reads room persistence through a DIFFERENT config key
    # (`:room_manager, :db_module`, see `room/server.ex`), never stubbed
    # here. In the plain unit-test environment `Room.Server`/Horde is not
    # actually reachable, so `join/2` fails closed with `{:error, :noproc}`
    # (caught and logged, non-fatal) regardless of whether admin-only
    # provisioning correctly skips auto-join or incorrectly wires it in —
    # `refute_received {:insert_member_called}` would have passed either way.
    #
    # Fix: assert at the boundary that IS fully reachable in a plain unit
    # test without Horde — `list_auto_join_rooms/0` is the very first call
    # `ensure_auto_join_memberships/1` makes (event_dispatcher/server.ex,
    # `run_post_login_provisioning/2` → `ensure_auto_join_memberships/1` for
    # `is_new: true` users only), BEFORE any Room.Server/Horde involvement.
    # If admin-only provisioning never calls into the auto-join pipeline at
    # all (this story's AC2 recommendation), `list_auto_join_rooms/0` is
    # never invoked — a call notifies the test process, so the absence of
    # that notification IS a real, falsifiable signal: a dev implementation
    # that (incorrectly) wires `run_post_login_provisioning/2` into the
    # admin login path would reach this call and the test would fail.
    defmodule FakeMessagesDB_AutoJoinRoom_AdminLogin do
      @moduledoc false

      def list_auto_join_rooms do
        send(:admin_auto_join_test_listener, {:list_auto_join_rooms_called})
        {:ok, ["!general:nebu.local"]}
      end

      def get_personal_room_id(_user_id), do: {:ok, nil}
      def set_personal_room_id(_user_id, _room_id), do: :ok
      def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
      def insert_member(_room_id, _user_id), do: :ok
      def insert_event(_event), do: :ok
      def set_power_levels(_room_id, _levels), do: :ok
      def get_rooms_for_user(_user_id), do: {:ok, []}
      def get_recently_left_rooms_for_user(_), do: {:ok, []}
      def get_room_name(_room_id), do: {:ok, nil}
      def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
    end

    setup do
      Application.put_env(:session_manager, :validator_module, FakeTokenValidator_NewUser)
      Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AutoJoinRoom_AdminLogin)
      Process.register(self(), :admin_auto_join_test_listener)

      on_exit(fn ->
        Application.delete_env(:session_manager, :validator_module)
        Application.delete_env(:event_dispatcher, :messages_db_module)

        if Process.whereis(:admin_auto_join_test_listener) == self() do
          Process.unregister(:admin_auto_join_test_listener)
        end
      end)

      :ok
    end

    test "a brand-new identity provisioned via normal_callback/2 is NOT auto-joined to is_auto_join rooms" do
      claims = %{
        "sub" => "new-admin",
        "email" => "new-admin@example.com",
        "nonce" => "the-nonce",
        "exp" => System.system_time(:second) + 3600,
        "groups" => ["instance_admin"]
      }

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims, nil} end)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_oidc_token_override) end)

      conn =
        session_conn(:get, "/admin/callback")
        |> put_session("admin_oidc_login", %{
          "state" => "the-state",
          "verifier" => "the-verifier",
          "nonce" => "the-nonce",
          "exp" => System.system_time(:second) + 600,
          "mode" => nil
        })
        |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

      assert conn.status == 302

      # Give any fire-and-forget Task (run_post_login_provisioning's Task.start)
      # time to run before asserting its absence.
      Process.sleep(200)

      # test-review (Step 3, MAJOR-1 fix): asserts on `list_auto_join_rooms/0`
      # — the first call `ensure_auto_join_memberships/1` makes, reachable
      # without Horde/Room.Server — instead of the unreachable
      # `insert_member/2` write path. See the fake module's moduledoc above
      # for the full rationale.
      refute_received {:list_auto_join_rooms_called},
                       "AC2 (this architecture's recommendation): an admin-only login for a " <>
                         "brand-new identity must NOT trigger auto-join into is_auto_join rooms " <>
                         "— only AC1's provisioning (users row) should happen. If dev deviates " <>
                         "from this recommendation with a documented justification (permitted by " <>
                         "AC2), this assertion must be flipped to assert_received and this comment " <>
                         "updated to reference that justification."
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 + AC5 — the admin-only-provisioned operator becomes visible in
  # GET /admin/users. Requires a real `users` table (Nebu.Admin.DB.list_users/3
  # reads it via inline SQL, ADR-018) — tagged :integration, mirrors
  # search_users_db_test.exs. Run via `make test-integration` / the redeployed
  # stack (NEBU_DB_URL required); excluded from the plain unit run.
  # ══════════════════════════════════════════════════════════════════════════
  describe "AC3/AC5: admin-only-provisioned operator appears in GET /admin/users (integration)" do
    @moduletag :integration

    # dev-story fix: Nebu.Matrix.UserId.from_claims/2 always downcases the
    # localpart, but Base.url_encode64/2 can emit uppercase A-Z. Without
    # lowercasing here, the fixture's own sanity-check assertion
    # (`Nebu.Matrix.UserId.from_claims(claims, "localhost") == user_id`)
    # intermittently fails whenever the random bytes happen to include an
    # uppercase character — reproducible, unrelated to production code.
    @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) |> String.downcase()

    defp admin_only_user_id(run_id), do: "@#{run_id}_adminonly:localhost"

    setup do
      if Process.whereis(Nebu.Repo) == nil do
        flunk("Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set)")
      end

      on_exit(fn ->
        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [
          admin_only_user_id(@run_id)
        ])
      end)

      :ok
    end

    test "AC3: an operator provisioned ONLY via admin login appears in Nebu.Admin.DB.list_users/3" do
      user_id = admin_only_user_id(@run_id)

      claims = %{
        "sub" => "#{@run_id}_adminonly",
        "email" => "adminonly@example.com",
        "nonce" => "the-nonce",
        "exp" => System.system_time(:second) + 3600,
        "preferred_username" => "#{@run_id}_adminonly",
        "groups" => ["instance_admin"]
      }

      assert Nebu.Matrix.UserId.from_claims(claims, "localhost") == user_id,
             "test fixture must match the derived matrix_user_id for the seeded claims"

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims, nil} end)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_oidc_token_override) end)

      # Before this story's fix, no users row exists yet for this identity.
      {users_before, _} = Nebu.Admin.DB.list_users(500, "", "")
      refute Enum.any?(users_before, &(&1.user_id == user_id)),
             "sanity: the admin-only user must not pre-exist from a prior run"

      conn =
        session_conn(:get, "/admin/callback")
        |> put_session("admin_oidc_login", %{
          "state" => "the-state",
          "verifier" => "the-verifier",
          "nonce" => "the-nonce",
          "exp" => System.system_time(:second) + 600,
          "mode" => nil
        })
        |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

      assert conn.status == 302

      {users_after, _} = Nebu.Admin.DB.list_users(500, "", "")

      assert Enum.any?(users_after, &(&1.user_id == user_id)),
             "AC3: #{user_id} must appear in Nebu.Admin.DB.list_users/3 (backing GET " <>
               "/admin/users) after an admin-only login — got users: " <>
               "#{inspect(Enum.map(users_after, & &1.user_id))}"
    end

    # test-review (Step 3, MINOR-2 fix): split out of a single AC5-only-named
    # test so AC4 (idempotent upsert / no duplicate / no profile clobber on a
    # LATER real Matrix login) has its own named test, independently visible
    # in CI output rather than folded under an "AC5:"-titled test.
    test "AC4: a real Matrix login after admin-only provisioning does not error, does not duplicate, and does not clobber profile data the user set themselves" do
      user_id = admin_only_user_id(@run_id) |> String.replace("adminonly", "ac4")

      claims = %{
        "sub" => "#{@run_id}_ac4",
        "email" => "ac4@example.com",
        "nonce" => "the-nonce",
        "exp" => System.system_time(:second) + 3600,
        "preferred_username" => "#{@run_id}_ac4",
        "groups" => ["instance_admin"]
      }

      on_exit(fn ->
        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [user_id])
        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM profiles WHERE user_id = $1", [user_id])
      end)

      assert Nebu.Matrix.UserId.from_claims(claims, "localhost") == user_id

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims, nil} end)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_oidc_token_override) end)

      # Step 1: admin-only login provisions the row (AC1/AC3).
      admin_conn =
        session_conn(:get, "/admin/callback")
        |> put_session("admin_oidc_login", %{
          "state" => "the-state",
          "verifier" => "the-verifier",
          "nonce" => "the-nonce",
          "exp" => System.system_time(:second) + 600,
          "mode" => nil
        })
        |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

      assert admin_conn.status == 302

      {users_after_admin, _} = Nebu.Admin.DB.list_users(500, "", "")
      assert Enum.count(users_after_admin, &(&1.user_id == user_id)) == 1,
             "expected exactly one row after admin-only provisioning"

      # The user now sets their OWN profile displayname (simulating a
      # PUT /profile/{userId}/displayname the person made themselves between
      # the admin-only login and their later first real Matrix login).
      :ok = Nebu.Matrix.Profile.DB.upsert_profile(user_id, "Chosen By User", nil)

      # Step 2: the SAME identity now logs in via the real Matrix client path —
      # must not error and must not duplicate the row (idempotent upsert, AC4).
      resp =
        Nebu.Matrix.Session.TokenValidator.validate(user_id, "user", "AC4 Person", "ac4@example.com")

      assert {:ok, %{user_id: ^user_id}} = resp,
             "AC4: a subsequent real Matrix login of an admin-provisioned identity must " <>
               "succeed (idempotent upsert), not error. Got: #{inspect(resp)}"

      {users_after_matrix, _} = Nebu.Admin.DB.list_users(500, "", "")
      assert Enum.count(users_after_matrix, &(&1.user_id == user_id)) == 1,
             "AC4: no duplicate users row after the subsequent real Matrix login — got " <>
               "#{Enum.count(users_after_matrix, &(&1.user_id == user_id))} rows for #{user_id}"

      # test-review (Step 3, MINOR-3 fix): AC4's DoD wording explicitly
      # requires "keine überschriebenen Profildaten die der Nutzer inzwischen
      # selbst gesetzt hat" (no overwritten profile data the user has since
      # set themselves). Profile.DB.upsert_profile/3 uses
      # `COALESCE(EXCLUDED.displayname, profiles.displayname)` — a NIL
      # incoming displayname preserves the existing row, a non-nil incoming
      # value overwrites it. The real Matrix /login path
      # (provision_and_respond/6) passes `nil` when the OIDC claims carry no
      # preferred_username/name, so this asserts the COALESCE contract holds
      # end-to-end for that case: the user's self-set displayname survives a
      # subsequent OIDC claims-less profile touch.
      {:ok, profile} = Nebu.Matrix.Profile.DB.get_profile(user_id)

      assert profile.displayname == "Chosen By User",
             "AC4: the user's self-set displayname must survive a subsequent Matrix login/" <>
               "provisioning touch that carries no displayname of its own (nil-safe COALESCE " <>
               "upsert) — got: #{inspect(profile.displayname)}"
    end

    test "AC5: admin-only login without a prior Matrix login makes the operator visible in GET /admin/users" do
      user_id = admin_only_user_id(@run_id) |> String.replace("adminonly", "ac5")

      claims = %{
        "sub" => "#{@run_id}_ac5",
        "email" => "ac5@example.com",
        "nonce" => "the-nonce",
        "exp" => System.system_time(:second) + 3600,
        "preferred_username" => "#{@run_id}_ac5",
        "groups" => ["instance_admin"]
      }

      on_exit(fn -> Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM users WHERE user_id = $1", [user_id]) end)

      assert Nebu.Matrix.UserId.from_claims(claims, "localhost") == user_id

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims, nil} end)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_oidc_token_override) end)

      admin_conn =
        session_conn(:get, "/admin/callback")
        |> put_session("admin_oidc_login", %{
          "state" => "the-state",
          "verifier" => "the-verifier",
          "nonce" => "the-nonce",
          "exp" => System.system_time(:second) + 600,
          "mode" => nil
        })
        |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

      assert admin_conn.status == 302

      {users_after_admin, _} = Nebu.Admin.DB.list_users(500, "", "")
      assert Enum.any?(users_after_admin, &(&1.user_id == user_id)),
             "AC5: #{user_id} must appear in GET /admin/users after an admin-only login with " <>
               "no prior Matrix login — got users: " <>
               "#{inspect(Enum.map(users_after_admin, & &1.user_id))}"

      # AC5's second half (unchanged real Matrix login afterwards) is the
      # SAME invariant AC4 verifies in its own dedicated test above — not
      # duplicated here to avoid asserting the identical idempotent-upsert
      # behavior twice under two different test names.
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Regression guard (Oracle note): the standard POST /_matrix/client/v3/login
  # error contract (403 M_FORBIDDEN / 400 M_BAD_JSON-family) must be unchanged
  # by this story. The full /login contract is already covered elsewhere
  # (e.g. test/nebu/matrix/http_public*_test.exs and sibling login test files);
  # this is a narrow smoke assertion that admin-path changes do not alter the
  # unrelated Matrix HTTP error surface, kept local to this file so the ATDD
  # suite for this story is self-contained without duplicating a whole /login
  # suite.
  # ══════════════════════════════════════════════════════════════════════════
  describe "regression: Matrix /login error contract is unchanged by admin provisioning" do
    test "an invalid OIDC token on POST /_matrix/client/v3/login still returns 403 M_FORBIDDEN" do
      router_opts = Nebu.Web.Router.init([])

      conn =
        conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => "not-a-jwt"}))
        |> put_req_header("content-type", "application/json")
        |> Nebu.Web.Router.call(router_opts)

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["errcode"] == "M_FORBIDDEN"
    end

    test "a malformed JSON body on POST /_matrix/client/v3/login still returns 400 M_NOT_JSON" do
      router_opts = Nebu.Web.Router.init([])

      conn =
        conn(:post, "/_matrix/client/v3/login", "{not json")
        |> put_req_header("content-type", "application/json")
        |> Nebu.Web.Router.call(router_opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["errcode"] == "M_NOT_JSON"
    end
  end
end
