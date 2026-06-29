defmodule Nebu.Matrix.SsoLoginScopeTest do
  @moduledoc """
  Regression tests for the Matrix SSO base scope.

  ## SUPERSEDED decision (read this first)

  This file originally guarded bug `fix-element-login`, which set
  `@base_scopes` in `Nebu.Matrix.SsoLogin` to the MINIMAL `~w(openid)` and asserted
  `profile`/`email` MUST NOT appear.

  Story **`oidc-bootstrap-only-e2e-regressions`** (ADR-022 end-to-end fix) REVERSES
  that decision: the base scope is now the fixed default `~w(openid profile email)`.
  The `~w(openid)`-only scope broke the live flow — Dex omits the `name` claim unless
  `profile` is requested, so the configured `oidc_user_id_claim = "name"` could not
  resolve and the MXID regressed to the opaque `sub` (the regression `df249f8c` had
  originally fixed, via the now-removed `NEBU_OIDC_EXTRA_SCOPES`). ADR-022 removed the
  env var, so the scopes must be requested as fixed server-side defaults instead.

  This file is therefore CONVERTED into a regression guard for the NEW default. The
  authoritative RED-phase test for the new contract is
  `sso_scope_profile_email_test.exs` (AC4); the assertions here are kept consistent
  with it so a future change cannot silently revert to the broken `~w(openid)` scope.

  ## Acceptance Criteria covered (new contract)

    * AC1 — Base scope contains `openid profile email`: online mode →
      `openid profile email` (NO `offline_access`); offline mode →
      `openid profile email offline_access`.
    * AC3 — offline_access behavior unchanged: offline mode still gets
      `offline_access`; online mode still excludes it. The
      `:matrix_oidc_refresh_mode_reader` seam controls this without a DB.
    * AC4 — Regression guard: explicit assertion that `profile`/`email` ARE present
      and that the broken `~w(openid)`-only scope is NOT in effect.

  (The former AC2 "extra scopes additive via NEBU_OIDC_EXTRA_SCOPES" tests asserted
  removed behaviour — ADR-022 deleted that env var — and are gone.)

  ## Public surface

  `scope_list/0` is `defp`. We assert via the observable result: the `scope`
  query-param of the 302 redirect built by
  `GET /_matrix/client/v3/login/sso/redirect`, which is the only public caller of
  `scope_list/0`. This style mirrors `sso_scope_mode_test.exs`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp setup_oidc do
    # oidc-bootstrap-only-config (ADR-022): issuer via OidcConfig, the single SSO
    # OIDC client via the :sso_bootstrap_reader seam. No env config path.
    Nebu.Web.OidcTestSupport.configure(@issuer, "nebu-client")
    Application.put_env(:nebu_http, :admin_secret_at_rest, "sso-login-scope-test-key")

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

  defp set_mode(mode),
    do: Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> mode end)

  # Drive the only public caller of scope_list/0 and return the scope tokens.
  defp scope_params do
    conn =
      conn(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
          URI.encode_www_form("https://app.example.com/#/home")
      )

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
  # AC1 — Base scope is `openid profile email` (NEW default, ADR-022 e2e fix)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — base scope contains openid profile email" do
    test "online mode: scope contains openid profile email and NO offline_access" do
      # SUPERSEDES fix-element-login: the base scope is now ~w(openid profile email) so
      # Dex releases the `name`/`email` claims (MXID derives from `name`, not `sub`).
      set_mode("online")
      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      assert "profile" in scopes,
             "profile MUST be in base scope so the `name` claim is released; got: #{inspect(scopes)}"

      assert "email" in scopes,
             "email MUST be in base scope; got: #{inspect(scopes)}"

      refute "offline_access" in scopes,
             "online mode must NOT add offline_access; got: #{inspect(scopes)}"
    end

    test "offline mode: scope contains openid profile email AND offline_access" do
      set_mode("offline")
      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      assert "profile" in scopes,
             "profile MUST be in base scope; got: #{inspect(scopes)}"

      assert "email" in scopes,
             "email MUST be in base scope; got: #{inspect(scopes)}"

      assert "offline_access" in scopes,
             "offline_access must be present in offline mode; got: #{inspect(scopes)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — offline_access behavior is not regressed
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — offline_access behavior unchanged after base-scope reduction" do
    test "offline mode still includes offline_access" do
      set_mode("offline")
      scopes = scope_params()
      assert "offline_access" in scopes
    end

    test "online mode still excludes offline_access" do
      set_mode("online")
      scopes = scope_params()
      refute "offline_access" in scopes
    end

    test "unset / nil mode defaults to offline (includes offline_access)" do
      # Model 'unset' deterministically via the seam returning nil so we avoid a
      # racy live DB read. matrix_refresh_mode/0 collapses nil → "offline".
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
  # AC4 — Regression guard: the broken `~w(openid)`-only scope is NOT in effect
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — regression guard: base scope is openid profile email (not openid-only)" do
    test "online mode → scope list is exactly ['openid', 'profile', 'email'] (order-independent)" do
      # SUPERSEDES fix-element-login: the OLD @base_scopes ~w(openid) broke the live flow
      # (Dex omits `name` without `profile` → MXID = sub). The fixed default requests
      # openid+profile+email so the IdP releases name/email.
      set_mode("online")
      scopes = scope_params()

      assert Enum.sort(scopes) == Enum.sort(["openid", "profile", "email"]),
             "expected base scope to be exactly [\"openid\", \"profile\", \"email\"] but got: " <>
               "#{inspect(scopes)}. Regression guard: the OLD @base_scopes ~w(openid) must NOT " <>
               "be in effect (it omits the `name` claim → MXID regresses to `sub`)."
    end

    test "offline mode → scope list is exactly openid+profile+email+offline_access (order-independent)" do
      set_mode("offline")
      scopes = scope_params()

      assert Enum.sort(scopes) ==
               Enum.sort(["openid", "profile", "email", "offline_access"]),
             "expected base scope to be exactly [\"openid\", \"profile\", \"email\", " <>
               "\"offline_access\"] but got: #{inspect(scopes)}."
    end
  end
end
