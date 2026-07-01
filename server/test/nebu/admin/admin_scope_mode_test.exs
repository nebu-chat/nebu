defmodule Nebu.Admin.AdminScopeModeTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-refresh-mode-config` (epic
  `fix-short-oidc-sessions`), AC3 + AC7 (admin side).

  ## What is under test

  Today `Nebu.Admin.Auth.admin_oidc_scope/0` FORCE-ADDS `offline_access`
  (`["openid", "offline_access"] ++ configured`). This story removes the force
  and makes it configurable per the `server_config` key
  `admin_oidc_refresh_mode` (`offline` | `online`), read LIVE so a runtime
  change applies without a redeploy:

    * `admin_oidc_refresh_mode = offline` → scope INCLUDES `offline_access`.
    * `admin_oidc_refresh_mode = online` (or unset → DEFAULT online) → scope is
      `openid` only (OIDC Scopes Law), with NO `offline_access`.
    * `openid` is ALWAYS present (mandatory), in every mode.
    * `profile`/`email`/`groups` are NOT hardcoded defaults (OIDC Scopes Law —
      `bugfix-remove-default-scopes`); operators configure them explicitly.

  Note the DEFAULT differs from Matrix: admin defaults to `online` (no forced
  offline_access → no special IdP approval needed), Matrix defaults to
  `offline` (preserves refresh on Dex & Keycloak).

  ## Public surface (no testing of privates)

  `admin_oidc_scope/0` is `defp`. We assert the OBSERVABLE result: the `scope`
  query-param of the 302 `Nebu.Admin.Auth.login_start/2` builds toward the IdP
  authorize endpoint (it puts `cfg.scope` — i.e. `admin_oidc_scope/0` — into the
  redirect). This mirrors `admin_oidc_login_test.exs`, which asserts on the same
  redirect's params.

  ## Seam the dev MUST add (mode reader)

  Unit suite (no live `Nebu.Repo`) → control the mode via an INJECTABLE READER
  SEAM the dev adds to `Auth`, mirroring `OidcClaimCache`'s `:oidc_claim_reader`
  and the `:admin_bootstrap_store` seam (only the read point is injected; the
  inline SQL `SELECT value FROM server_config WHERE key='admin_oidc_refresh_mode'`
  stays in the module — ADR-018):

      Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> "offline" end)

  Seam ABSENT (unset env) → default reader does the live server_config read; no
  row → DEFAULT `online` (the new admin default; un-forces offline_access).

  ## Crash/restart — NOT APPLICABLE

  Pure config read on the request process (Persistenz Option C — stateless).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"
  @client_id "nebu-admin"

  setup do
    # oidc-bootstrap-only-config (ADR-022): issuer via OidcConfig, the single admin
    # OIDC client via the :admin_oidc_config_reader seam. No env config path.
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "admin-scope-mode-test-key")

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    # Isolate from server_config DB — OIDC Scopes Law: default is empty (openid only).
    Application.put_env(:nebu_http, :admin_oidc_extra_scopes_reader, fn -> nil end)

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override,
            :admin_oidc_refresh_mode_reader,
            :admin_oidc_extra_scopes_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp set_mode(mode), do: Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> mode end)

  # login_start/2 builds the admin authorize redirect and puts admin_oidc_scope/0
  # into its `scope` query param — the public observable surface.
  defp scope_params do
    conn =
      conn(:get, "/admin/login/start")
      |> init_test_session(%{})
      |> Auth.login_start(%{})

    assert conn.status == 302
    [loc] = get_resp_header(conn, "location")
    assert String.starts_with?(loc, @authorization_endpoint <> "?")

    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — admin scope honors admin_oidc_refresh_mode; offline_access NOT forced
  # ════════════════════════════════════════════════════════════════════════════

  describe "admin scope honors admin_oidc_refresh_mode (AC3)" do
    test "offline mode → scope INCLUDES offline_access" do
      set_mode("offline")
      scopes = scope_params()
      assert "openid" in scopes
      assert "offline_access" in scopes
    end

    test "online mode → openid only, NO offline_access" do
      # bugfix-remove-default-scopes: OIDC Scopes Law — profile/email are NOT hardcoded defaults.
      set_mode("online")
      scopes = scope_params()
      assert "openid" in scopes
      refute "profile" in scopes
      refute "email" in scopes
      refute "offline_access" in scopes
    end

    test "unset mode → DEFAULTS to online (NO offline_access) — AC1/AC3 default" do
      # "unset" means the default reader resolves no configured mode and falls back
      # to the admin "online" default. In the integration container Nebu.Repo IS
      # running and the shared DB carries a real admin_oidc_refresh_mode row (the
      # live server persists one), and concurrent integration tests in this module
      # write 'offline'/'online' — so a live DB read here is racy. Model "unset"
      # DETERMINISTICALLY with the documented reader seam returning nil (the same
      # seam shape the other AC3 tests use): the reader collapses nil → "online",
      # so offline_access must NOT be added. No DB writes → no race; the live
      # config row is never touched. Restore in on_exit.
      prev = Application.get_env(:nebu_http, :admin_oidc_refresh_mode_reader)
      Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> nil end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:nebu_http, :admin_oidc_refresh_mode_reader)
          v -> Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, v)
        end
      end)

      scopes = scope_params()
      assert "openid" in scopes
      refute "offline_access" in scopes
    end

    test "openid is always present even with a custom configured scope in online mode" do
      set_mode("online")
      # oidc-bootstrap-only-config (ADR-022): the admin scope is a fixed base set
      # ("openid profile email"); there is no operator-configurable :admin_oidc_scope
      # env anymore. openid stays mandatory and offline_access is absent in online mode.
      scopes = scope_params()
      assert "openid" in scopes
      refute "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3/AC5 — live server_config read (integration; REAL upsert, no DB mock)
  # ════════════════════════════════════════════════════════════════════════════

  describe "admin scope reads server_config live (AC3/AC5)" do
    @describetag :integration

    setup do
      # These tests assert on the LIVE server_config read, so any leaked reader seam
      # (from a sibling unit test / another file) MUST be removed first — otherwise it
      # shadows the DB and the row we write is never consulted. Force-clear it here and
      # restore the prior value in on_exit. Clean the row before AND after so a stale
      # value left by another run can't poison the read.
      prev_reader = Application.get_env(:nebu_http, :admin_oidc_refresh_mode_reader)
      Application.delete_env(:nebu_http, :admin_oidc_refresh_mode_reader)

      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM server_config WHERE key = 'admin_oidc_refresh_mode'",
          []
        )
      end

      on_exit(fn ->
        case prev_reader do
          nil -> Application.delete_env(:nebu_http, :admin_oidc_refresh_mode_reader)
          v -> Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, v)
        end

        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM server_config WHERE key = 'admin_oidc_refresh_mode'",
            []
          )
        end
      end)

      :ok
    end

    test "offline written to server_config adds offline_access on the next login-start" do
      :ok = Nebu.Admin.DB.upsert_server_config(%{"admin_oidc_refresh_mode" => "offline"})
      scopes = scope_params()
      assert "offline_access" in scopes
    end

    test "online written to server_config drops offline_access on the next login-start" do
      :ok = Nebu.Admin.DB.upsert_server_config(%{"admin_oidc_refresh_mode" => "online"})
      scopes = scope_params()
      refute "offline_access" in scopes
      assert "openid" in scopes
    end
  end
end
