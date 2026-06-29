defmodule Nebu.Matrix.SsoScopeModeTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-refresh-mode-config` (epic
  `fix-short-oidc-sessions`), AC2 + AC7 (Matrix side).

  ## What is under test

  `SsoLogin.@base_scopes` is `~w(openid profile email)` (story
  `oidc-bootstrap-only-e2e-regressions`, AC4 — supersedes the `fix-element-login`
  `~w(openid)` minimal scope: Dex omits `name` without `profile`, regressing the MXID
  to `sub`). The `offline_access` scope is configurable per the `server_config` key
  `matrix_oidc_refresh_mode` (`offline` | `online`), read LIVE on each
  login-start so a runtime change applies without a redeploy:

    * `matrix_oidc_refresh_mode = offline` (or unset → default offline) →
      scope INCLUDES `offline_access`.
    * `matrix_oidc_refresh_mode = online` → scope EXCLUDES `offline_access`
      (just the `openid profile email` base).
    * `openid`, `profile`, and `email` are always present (the fixed ADR-022 default).
      This test focuses on the `offline_access` refresh-mode toggle.

  ## Public surface (no testing of privates)

  `scope_list/0` is `defp`. We assert the OBSERVABLE result: the `scope`
  query-param of the 302 the Matrix client SSO redirect builds
  (`GET /_matrix/client/v3/login/sso/redirect`), which is the only public
  surface that calls `scope_list/0`. This is robust and matches the existing
  `matrix_sso_test.exs` style (assert on the authorize redirect params).

  ## Seam the dev MUST add (mode reader)

  These tests run in the UNIT suite (no live `Nebu.Repo`), so they cannot use
  `upsert_server_config/1`. They control the mode through an INJECTABLE READER
  SEAM the dev adds to `SsoLogin`, exactly mirroring the project's existing
  `OidcClaimCache` `:oidc_claim_reader` seam and the `:admin_bootstrap_store`
  seam — only the READ POINT is injected; the inline SQL
  (`SELECT value FROM server_config WHERE key='matrix_oidc_refresh_mode'`,
  ADR-018) stays in the module:

      # in Nebu.Matrix.SsoLogin, scope_list/0 resolves the mode via:
      #   reader = Application.get_env(:nebu_http, :matrix_oidc_refresh_mode_reader,
      #                                &default_refresh_mode/0)
      #   case reader.() do "online" -> ... ; _ -> offline (default) end
      Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "online" end)

  When the seam is ABSENT (unset env) the default reader does the live
  server_config read; with no row it MUST default to `offline`.

  A companion `@moduletag :integration` block (run only under
  `make test-integration` with a live DB) controls the mode via the REAL
  `Nebu.Admin.DB.upsert_server_config/1` and asserts the same observable
  behavior end-to-end (no DB mocking).

  ## Crash/restart — NOT APPLICABLE

  `scope_list/0` is a pure read of config on the request process (Persistenz
  Option C — stateless). No GenServer state to recover.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  # ── shared OIDC + discovery seam (mirrors matrix_sso_test.exs) ────────────────

  defp setup_oidc do
    # oidc-bootstrap-only-config (ADR-022): issuer via OidcConfig, the single SSO
    # OIDC client via the :sso_bootstrap_reader seam. No env config path.
    Nebu.Web.OidcTestSupport.configure(@issuer, "nebu-client")
    Application.put_env(:nebu_http, :admin_secret_at_rest, "sso-scope-mode-test-key")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("shhh")
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
            :admin_secret_at_rest,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_oidc_refresh_mode_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp set_mode(mode), do: Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> mode end)

  # The Matrix client SSO redirect (the only public caller of scope_list/0).
  defp scope_params do
    conn =
      conn(:get, "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("https://app.example.com/#/home"))

    conn = Nebu.Web.Router.call(conn, @router_opts)
    assert conn.status == 302
    loc = conn |> get_resp_header("location") |> List.first()
    assert is_binary(loc) and String.starts_with?(loc, @authorize)

    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  setup do
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    setup_oidc()
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — scope honors matrix_oidc_refresh_mode (unit; mode via reader seam)
  # ════════════════════════════════════════════════════════════════════════════

  describe "Matrix scope honors matrix_oidc_refresh_mode (AC2)" do
    test "offline mode → scope INCLUDES offline_access" do
      set_mode("offline")
      scopes = scope_params()
      assert "openid" in scopes
      assert "offline_access" in scopes
    end

    test "online mode → scope EXCLUDES offline_access (openid still present)" do
      set_mode("online")
      scopes = scope_params()
      assert "openid" in scopes
      refute "offline_access" in scopes
      # oidc-bootstrap-only-e2e-regressions (AC4): profile/email are now part of the fixed
      # base scope (supersedes fix-element-login). Online mode only toggles offline_access.
      assert "profile" in scopes
      assert "email" in scopes
    end

    test "unset mode → DEFAULTS to offline (includes offline_access) — AC1/AC7" do
      # "Unset" = no configured mode resolves. In the integration container Nebu.Repo
      # IS running and the shared DB may carry a real matrix_oidc_refresh_mode row (or
      # a concurrent/sibling test wrote 'online'), so a live DB read here is racy and
      # was the source of the SsoScopeModeTest:146 flake (expected offline, got online).
      # Model "unset" DETERMINISTICALLY via the documented reader seam returning nil:
      # matrix_refresh_mode/0 collapses nil → "offline" (the production default), so
      # offline_access MUST be present. No DB read, no race; the live row is untouched.
      # Restore the prior seam value in on_exit so nothing bleeds across files.
      prev = Application.get_env(:nebu_http, :matrix_oidc_refresh_mode_reader)
      Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> nil end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_mode_reader)
          v -> Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, v)
        end
      end)

      scopes = scope_params()
      assert "openid" in scopes
      assert "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2/AC5 — live server_config read (integration; mode via REAL upsert, no mock)
  # ════════════════════════════════════════════════════════════════════════════

  describe "Matrix scope reads server_config live (AC2/AC5)" do
    @describetag :integration

    setup do
      # These tests assert on the LIVE server_config read, so any leaked reader seam
      # (from a sibling unit test / another file) MUST be removed first — otherwise the
      # seam shadows the DB and the row we write is never consulted. Force-clear it here
      # and restore the prior value in on_exit. Also clean the row before AND after so a
      # stale 'online'/'offline' left by another run can't poison the default-read.
      prev_reader = Application.get_env(:nebu_http, :matrix_oidc_refresh_mode_reader)
      Application.delete_env(:nebu_http, :matrix_oidc_refresh_mode_reader)

      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM server_config WHERE key = 'matrix_oidc_refresh_mode'",
          []
        )
      end

      on_exit(fn ->
        case prev_reader do
          nil -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_mode_reader)
          v -> Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, v)
        end

        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM server_config WHERE key = 'matrix_oidc_refresh_mode'",
            []
          )
        end
      end)

      :ok
    end

    test "online written to server_config drops offline_access on the next login-start" do
      :ok = Nebu.Admin.DB.upsert_server_config(%{"matrix_oidc_refresh_mode" => "online"})
      scopes = scope_params()
      refute "offline_access" in scopes
      assert "openid" in scopes
    end

    test "offline written to server_config re-adds offline_access on the next login-start" do
      :ok = Nebu.Admin.DB.upsert_server_config(%{"matrix_oidc_refresh_mode" => "offline"})
      scopes = scope_params()
      assert "offline_access" in scopes
    end
  end
end
