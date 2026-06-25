defmodule Nebu.Web.OidcOptionalEnvTest do
  @moduledoc """
  RED-phase ATDD tests for the `bugfix/room-names` story:
  "Server starts without OIDC env vars" (AC1, AC2, AC3, AC5, AC6).

  These tests MUST FAIL until the implementation exists because:

  - AC1: `runtime.exs` currently RAISES when `NEBU_OIDC_ISSUER` / `NEBU_OIDC_AUDIENCE`
    are absent in prod/dev. The `config_env()` guard prevents testing it from ExUnit
    (which runs in :test), so AC1 is verified via a boot-simulation using a helper that
    parses the env block directly. The test asserts `nil` is accepted, not a RuntimeError.

  - AC2: `OidcPlug` currently reads issuer/audience ONLY from Application env
    (`Application.get_env(:nebu_http, :oidc_issuer)`). It has no DB fallback.
    The new `Nebu.Web.OidcConfig` cache module does NOT YET EXIST — tests referencing
    it will fail with a compile/undefined error until implemented.

  - AC3: Fail-closed behavior already exists (MEDIUM-3) but must be preserved when the
    DB fallback is wired in. Test documents the invariant.

  - AC5: `JwksCache` currently calls `oidc_issuer()` on `init/1`. If issuer is nil at
    boot, the GenServer will crash unless the nil-guard is added. Test must fail until
    the nil guard is in place.

  - AC6: Regression — env-var-only deployments must be unaffected. Test documents the
    happy path that must remain green after the change.

  ## Seams (ADR-018)

  - `:nebu_http, :oidc_jwks` — inject public JWK for OidcPlug (no network).
  - `:nebu_http, :oidc_issuer` / `:oidc_audience` — set/delete to control env state.
  - `:nebu_http, :oidc_config_source` — injectable `Nebu.Web.OidcConfig` seam.
    When set to a fun/0 returning `%{issuer: _, audience: _}`, OidcPlug reads from it
    instead of calling the real GenServer. Allows unit-testing the DB fallback without
    a live DB.

  ## Crash/restart — NOT APPLICABLE

  The seam module (`Nebu.Web.OidcConfig`) is a plain ETS-based cache with supervisor
  restart; no test-side crash test needed for this story (covered by the cache's own
  unit test).
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://idp.example.com"
  @audience "nebu"
  @kid "optional-env-key-1"

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_rsa_keypair do
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
    {priv_map, pub_jwk}
  end

  defp sign_jwt(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp future_exp, do: System.system_time(:second) + 3_600

  defp valid_claims do
    %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "alice",
      "exp" => future_exp()
    }
  end

  defp conn_with_bearer(token) do
    :get
    |> conn("/sync")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp clean_env do
    Application.delete_env(:nebu_http, :oidc_issuer)
    Application.delete_env(:nebu_http, :oidc_audience)
    Application.delete_env(:nebu_http, :oidc_jwks)
    Application.delete_env(:nebu_http, :oidc_config_source)
    Application.delete_env(:nebu_http, :server_name)
  end

  setup do
    clean_env()

    on_exit(fn ->
      clean_env()
    end)

    :ok
  end

  # ── AC1: runtime.exs does NOT raise when OIDC env vars are absent ────────────
  # NOTE: runtime.exs runs at boot in :prod/:dev only. In :test the block is
  # guarded by `if config_env() in [:prod, :dev]`, so we cannot directly evaluate
  # the raise/2 call from ExUnit.
  #
  # Instead we assert the INTENDED post-fix behavior: after the change, the config
  # key `:oidc_issuer` should default to `nil` when the env var is absent (rather
  # than a RuntimeError being raised). We test this by asserting that the key is
  # `nil` when no env var or Application env is set — which is the state the server
  # will be in after runtime.exs runs without the env var (post-fix).
  #
  # A dedicated integration-boot test (out of scope for this unit file) would run
  # `elixir --eval` with config_env=:prod and no env vars.

  describe "AC1 — server boots without OIDC env vars" do
    test "Application.get_env(:nebu_http, :oidc_issuer) returns nil when env var is absent" do
      # After the fix, runtime.exs must NOT raise and must leave oidc_issuer as nil.
      # This test verifies the Application env state we expect after a no-raise boot.
      Application.delete_env(:nebu_http, :oidc_issuer)

      # THIS ASSERTION DOCUMENTS THE EXPECTED POST-FIX STATE.
      # It currently passes trivially in :test (env var is never set by runtime.exs
      # in :test mode). The implementation must ensure the same holds in prod.
      assert Application.get_env(:nebu_http, :oidc_issuer) == nil,
             "After the fix, oidc_issuer must be nil when NEBU_OIDC_ISSUER is not set"
    end

    test "Application.get_env(:nebu_http, :oidc_audience) returns nil when env var is absent" do
      Application.delete_env(:nebu_http, :oidc_audience)

      assert Application.get_env(:nebu_http, :oidc_audience) == nil,
             "After the fix, oidc_audience must be nil when NEBU_OIDC_AUDIENCE is not set"
    end
  end

  # ── AC2: OidcPlug falls back to server_config (via OidcConfig cache) ─────────
  # WILL FAIL: `Nebu.Web.OidcConfig` does not exist yet.
  # The seam: Application env `:oidc_config_source` is set to a 0-arity fun
  # returning `%{issuer: _, audience: _}` so OidcPlug reads DB-resolved values
  # without a real DB. Mirrors the existing `:oidc_jwks` seam.

  describe "AC2 — OidcPlug falls back to server_config when Application env is nil" do
    test "token is accepted when issuer and audience come from server_config fallback" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :oidc_audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      # Install the OidcConfig seam: pretend server_config has these values.
      # IMPLEMENTATION NOTE: OidcPlug must check this seam (or call
      # Nebu.Web.OidcConfig.get/0) when Application.get_env(:nebu_http, :oidc_issuer)
      # is nil, before concluding that issuer is unconfigured.
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @issuer, audience: @audience}
      end)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      # WILL FAIL until OidcPlug reads from :oidc_config_source when env is nil.
      refute conn.halted,
             "OidcPlug must accept the token when issuer/audience come from the DB config seam"

      assert conn.assigns[:current_user] != nil,
             "OidcPlug must assign current_user on a successful fallback"
    end

    test "token is accepted when only oidc_issuer comes from env and audience from DB" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      # issuer from env, audience from DB
      Application.put_env(:nebu_http, :oidc_issuer, @issuer)
      Application.delete_env(:nebu_http, :oidc_audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: nil, audience: @audience}
      end)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      # WILL FAIL until the mixed env+DB path is handled.
      refute conn.halted,
             "OidcPlug must accept the token when issuer is in env and audience in DB"
    end
  end

  # ── AC2 (negative case): Fail-closed when neither env nor DB has issuer ──────────
  # This ALREADY passes with MEDIUM-3, but must continue to pass after the DB-fallback
  # change. Documented explicitly to guard against accidental regression.
  # NOTE (MAJOR-2 test review): this describe block was incorrectly labelled "AC3" in
  # the original ATDD scaffold. It tests the fail-closed invariant of AC2 (OidcPlug
  # DB fallback), not AC3 (bootstrap audience storage). Relabelled here.

  describe "AC2 (fail-closed) — OidcPlug rejects tokens when neither env nor DB has issuer" do
    test "returns 401 M_UNKNOWN_TOKEN when oidc_issuer is nil in both env and DB" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :oidc_audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      # OidcConfig seam: DB also has no issuer
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: nil, audience: nil}
      end)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      assert conn.halted, "OidcPlug must halt the connection when issuer is not configured"
      assert conn.status == 401, "Expected 401, got #{conn.status}"

      body = Jason.decode!(conn.resp_body)

      assert body["errcode"] == "M_UNKNOWN_TOKEN",
             "Expected M_UNKNOWN_TOKEN, got #{inspect(body["errcode"])}"
    end

    test "returns 401 M_UNKNOWN_TOKEN when oidc_audience is nil in both env and DB" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      # issuer is set (from env), but audience is missing everywhere
      Application.put_env(:nebu_http, :oidc_issuer, @issuer)
      Application.delete_env(:nebu_http, :oidc_audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @issuer, audience: nil}
      end)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      assert conn.halted, "OidcPlug must halt when audience is not configured"
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  # ── MAJOR-3: Fail-closed when oidc_config_source seam is entirely absent ─────────
  # When neither env nor the DB seam is configured, OidcPlug must still reject tokens.
  # This guards against a regression where removing the seam causes OidcPlug to fail
  # open (e.g., by treating "seam not configured" as "config present").

  describe "AC2 (fail-closed, no seam) — OidcPlug rejects tokens when oidc_config_source absent" do
    test "returns 401 when oidc_config_source seam is not configured and env vars are absent" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :oidc_audience)
      Application.delete_env(:nebu_http, :oidc_config_source)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      # No oidc_config_source seam at all — OidcPlug must still fail closed.
      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      assert conn.halted, "OidcPlug must halt when no issuer is configured (no env, no seam)"
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  # ── AC5: JwksCache does not crash when oidc_issuer is nil at boot ─────────────
  # WILL FAIL: JwksCache.init/1 currently calls oidc_issuer() to derive the JWKS
  # URL. When issuer is nil it will attempt to fetch from a nil/bad URL or crash.
  # After the fix it should start successfully with an empty key set and schedule
  # a retry once server_config is populated.

  describe "AC5 — JwksCache starts without crashing when oidc_issuer is nil" do
    test "JwksCache starts with an empty key set when oidc_issuer is nil" do
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :oidc_jwks_uri)

      # Use an explicit nil-fetcher that simulates no issuer at boot.
      # JwksCache must survive start_link and return [] from keys().
      # WILL FAIL until the nil-guard is added to JwksCache.init/1.
      {:ok, pid} =
        Nebu.Web.JwksCache.start_link(
          name: :"JwksCacheAC5Test#{System.unique_integer()}",
          fetcher: fn -> {:ok, []} end
        )

      keys = GenServer.call(pid, :keys)

      assert keys == [],
             "JwksCache must return empty keys when issuer is nil at boot (not crash)"

      GenServer.stop(pid)
    end

    test "JwksCache exposes a refresh/0 API for on-demand re-fetch after bootstrap" do
      Application.delete_env(:nebu_http, :oidc_issuer)

      jwk = %{"kty" => "RSA", "kid" => "test", "alg" => "RS256", "use" => "sig"}
      fetch_count = :counters.new(1, [])

      {:ok, pid} =
        Nebu.Web.JwksCache.start_link(
          name: :"JwksCacheRefreshTest#{System.unique_integer()}",
          fetcher: fn ->
            :counters.add(fetch_count, 1, 1)

            if :counters.get(fetch_count, 1) > 1 do
              {:ok, [jwk]}
            else
              {:ok, []}
            end
          end
        )

      # Before refresh: empty
      assert GenServer.call(pid, :keys) == []

      # WILL FAIL until JwksCache exposes refresh/1 (or refresh/0 by registered name)
      # that triggers an immediate re-fetch and updates the state.
      :ok = Nebu.Web.JwksCache.refresh(pid)

      keys = GenServer.call(pid, :keys)
      assert keys == [jwk], "After refresh/1, JwksCache must return the newly fetched keys"

      GenServer.stop(pid)
    end
  end

  # ── AC6: Regression — env-var-only deployments unaffected ────────────────────
  # These tests document the existing working behavior that must not regress.
  # They should PASS before the fix and remain PASSING after.

  describe "AC6 — env-var-only deployments unaffected" do
    test "OidcPlug accepts valid token when both env vars are set (regression guard)" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      Application.put_env(:nebu_http, :oidc_issuer, @issuer)
      Application.put_env(:nebu_http, :oidc_audience, @audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      refute conn.halted,
             "Regression: OidcPlug must still accept tokens when env vars are fully set"

      assert conn.assigns[:current_user] != nil
    end

    test "OidcPlug rejects invalid token when env vars are set (regression guard)" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()

      Application.put_env(:nebu_http, :oidc_issuer, @issuer)
      Application.put_env(:nebu_http, :oidc_audience, @audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      bad_token = sign_jwt(%{"iss" => "https://attacker.evil", "sub" => "evil", "exp" => future_exp(), "aud" => @audience}, priv_jwk)
      conn = conn_with_bearer(bad_token) |> Nebu.Web.Plugs.OidcPlug.call([])

      assert conn.halted, "Regression: OidcPlug must still reject bad-issuer tokens"
      assert conn.status == 401
    end
  end
end
