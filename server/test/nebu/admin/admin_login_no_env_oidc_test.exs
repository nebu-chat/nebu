defmodule Nebu.Admin.AdminLoginNoEnvOidcTest do
  @moduledoc """
  RED-phase regression tests for bug `admin-oidc-no-env`:
  Admin OIDC login returns 503 "client_id_not_configured" when OIDC env vars are
  absent even though the config lives in server_config (Bootstrap Wizard deployment).

  ## Root cause

  `Nebu.Admin.Auth.oidc_config/1` (normal mode) reads ONLY from Application env.
  It has no DB fallback — unlike `Nebu.Matrix.SsoLogin.oidc_config/0` which falls
  through to `server_config` via `config_value/1`, and unlike `OidcPlug` which falls
  through to `Nebu.Web.OidcConfig.get/0`.

  ## Acceptance criteria

  AC1: Admin login redirects to IdP (302) when OIDC config comes entirely from
       server_config (no env vars set).
  AC2: Admin login still works when env vars ARE set (regression guard).
  AC3: Admin login returns 503 when neither env vars nor server_config have values
       (fail-closed — must not regress).

  ## Seams

  - `:nebu_http, :admin_oidc_config_reader` — 1-arity fun `fn(key) -> value | nil`.
    Injects server_config values (client_id, client_secret) without a live DB.
    Mirrors `:sso_bootstrap_reader` from `Nebu.Matrix.SsoLogin`.
    The dev MUST add this seam to `Nebu.Admin.Auth.oidc_config/1` (normal mode).

  - `:nebu_http, :oidc_config_source` — 0-arity fun returning `%{issuer: _, audience: _}`.
    Already supported by `Nebu.Web.OidcConfig.get/0`. Used here to inject the issuer
    from "DB" without a running GenServer.

  - `:nebu_http, :oidc_metadata_override` — used to stub IdP discovery so login_start
    doesn't make real HTTP calls (already used in admin_scope_mode_test.exs).

  ## Crash/restart — NOT APPLICABLE

  Config read is stateless (request-process-scoped, Persistenz Option C).
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"
  @client_id "nebu-admin-from-db"

  setup do
    # oidc-bootstrap-only-config (ADR-022): start from a clean slate. issuer/audience
    # resolve via OidcConfig (the :oidc_config_source seam), the single admin OIDC
    # client via :admin_oidc_config_reader, redirect_uri derived from :server_name +
    # :admin_session_secure. No env config path remains.
    Application.delete_env(:nebu_http, :admin_oidc_config_reader)
    Application.delete_env(:nebu_http, :oidc_config_source)
    Application.delete_env(:nebu_http, :oidc_metadata_override)
    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    on_exit(fn ->
      for k <- [
            :admin_oidc_config_reader,
            :oidc_config_source,
            :oidc_metadata_override,
            :server_name,
            :admin_session_secure,
            :admin_oidc_refresh_mode_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    # Stub IdP discovery so login_start doesn't make real HTTP requests.
    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    # Default refresh mode to online (no offline_access scope confusion).
    Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> "online" end)

    :ok
  end

  defp start_login do
    conn(:get, "/admin/login/start")
    |> init_test_session(%{})
    |> Auth.login_start(%{})
  end

  # ── AC1: Admin login works from server_config DB (no env vars) ───────────────
  #
  # WILL FAIL until:
  #   1. `admin_config_value/1` helper is added to Auth (mirrors sso_login.ex)
  #   2. `oidc_config(_mode)` falls back to admin_config_value("oidc_client_id") when
  #      :admin_oidc_client_id env var is absent.
  #   3. Issuer falls back to Nebu.Web.OidcConfig.get().issuer when :oidc_issuer absent.

  describe "AC1 — admin login reads OIDC config from server_config when env vars absent" do
    test "login_start redirects to IdP (302) when client_id comes from server_config DB" do
      # Inject issuer via OidcConfig seam (DB path).
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @issuer, audience: @client_id}
      end)

      # Inject client_id / client_secret via the admin_oidc_config_reader seam.
      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "oidc_client_id" -> @client_id
        "oidc_client_secret" -> ""
        _ -> nil
      end)

      conn = start_login()

      refute conn.status == 503,
             "login_start must NOT return 503 when config is in server_config DB; got: #{conn.resp_body}"

      assert conn.status == 302,
             "login_start must redirect to IdP (302) when client_id comes from DB; got: #{conn.status}"

      [location] = get_resp_header(conn, "location")

      assert String.starts_with?(location, @authorization_endpoint),
             "Redirect must point to the configured authorization_endpoint"

      assert String.contains?(location, "client_id=#{@client_id}"),
             "Redirect must include the DB-sourced client_id"
    end

    test "login_start resolves both issuer and client_id from server_config DB" do
      # oidc-bootstrap-only-config (ADR-022): issuer AND client both come from
      # server_config — issuer via the OidcConfig seam, client via the reader seam.
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @issuer, audience: @client_id}
      end)

      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "oidc_client_id" -> @client_id
        _ -> nil
      end)

      conn = start_login()

      assert conn.status == 302,
             "login_start must redirect when issuer and client_id both come from DB; got: #{conn.status} #{conn.resp_body}"

      [location] = get_resp_header(conn, "location")
      assert String.contains?(location, "client_id=#{@client_id}")
    end
  end

  # ── AC2 (env-var deployments) — REMOVED (ADR-022) ────────────────────────────
  #
  # oidc-bootstrap-only-config (ADR-022) removed the OIDC env-var config path
  # entirely: issuer/audience resolve solely via OidcConfig and the single admin
  # client via server_config. There is no env path and no env-vs-DB priority chain,
  # so the former AC2 "env-var deployments unaffected" tests asserted removed
  # behaviour and were deleted.

  # ── AC3: Fail-closed when neither env vars nor DB have values ────────────────
  #
  # login_start MUST return 503 when no OIDC config is available at all.
  # This behavior must be preserved after the DB-fallback change.

  describe "AC3 — fail-closed when no OIDC config in env or DB" do
    test "login_start returns 503 when env vars absent and DB reader returns nil" do
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :admin_oidc_client_id)
      Application.delete_env(:nebu_http, :oidc_config_source)

      # DB reader returns nothing.
      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _key -> nil end)

      conn = start_login()

      assert conn.status == 503,
             "login_start must return 503 when no OIDC config is available anywhere"

      assert String.contains?(conn.resp_body, "not available"),
             "Error response must mention OIDC unavailability; body: #{conn.resp_body}"
    end

    test "login_start returns 503 when client_id is missing even if issuer is configured" do
      # Issuer is available (from DB seam) but no client_id anywhere.
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :admin_oidc_client_id)

      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @issuer, audience: nil}
      end)

      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _key -> nil end)

      conn = start_login()

      assert conn.status == 503,
             "login_start must fail closed when client_id is absent; got: #{conn.status}"
    end

    test "login_start returns 503 when admin_oidc_config_reader seam is absent and no env vars set" do
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :admin_oidc_client_id)
      Application.delete_env(:nebu_http, :oidc_config_source)
      Application.delete_env(:nebu_http, :admin_oidc_config_reader)

      conn = start_login()

      assert conn.status == 503,
             "login_start must fail closed when no seam and no env vars set; got: #{conn.status}"
    end
  end
end
