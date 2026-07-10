defmodule Nebu.Admin.AdminBootstrapGroupsScopeTest do
  @moduledoc """
  RED-phase ATDD test for bug `bugfix-oidc-bootstrap-only-e2e-regressions`, AC3.

  Also covers bug `bugfix-bootstrap-scope-ignored` (see the last `describe` block):
  `oidc_config("bootstrap")` must read extra scopes from the in-progress
  `bootstrap_draft`, not from `admin_oidc_scope/0`/`server_config` — that key
  doesn't exist yet mid-bootstrap, so the operator's Step 3 "Admin client scopes"
  field was being silently ignored on every bootstrap-mode OIDC redirect.

  ## Background (root cause)

  ADR-022 set the admin/bootstrap base scope to a fixed `"openid profile email"`
  and dropped `groups`. But Dex only releases the `groups` claim when the `groups`
  scope is requested. Without it the operator's token carries no `groups` claim, so
  `extract_discovered_claims/1` produces no `instance_admin` option and the
  bootstrap select-claim page has nothing to choose → bootstrap deadlock even after
  the `:no_keys` blocker (AC1) is fixed.

  ## AC3 — `groups` requested for the admin AND bootstrap operator login

  `Nebu.Admin.Auth.admin_oidc_scope/0` (a `defp`) must request
  `openid profile email groups`. The OBSERVABLE surface is the `scope` query param
  of the 302 redirect that `Auth.login_start/2` builds toward the IdP authorize
  endpoint (it puts `cfg.scope` — i.e. `admin_oidc_scope/0` — into the redirect),
  in BOTH normal admin mode (`login_start(conn, %{})`) and bootstrap mode
  (`login_start(conn, %{"mode" => "bootstrap"})`, which resolves issuer+client from
  the draft via the `:admin_bootstrap_store` seam).

  RED NOW: `admin_oidc_scope/0` returns `"openid profile email"` (no `groups`), so
  `"groups" in scopes` fails. The `openid`/`profile`/`email` assertions are already
  GREEN — they are kept as regression guards that the fix does not drop them.

  ## Seams (ADR-018 — no live Repo in the unit suite)

    * `Nebu.Web.OidcTestSupport.configure/2` — installs the OidcConfig issuer seam.
    * `:admin_oidc_config_reader` — the single admin OIDC client (normal mode).
    * `:admin_bootstrap_store` — the injectable draft/config dispatcher used by the
      bootstrap-mode `oidc_config("bootstrap")` resolution + `bootstrap_completed?/0`.
    * `:oidc_metadata_override` — discovery doc (authorization/token endpoints).
    * `:admin_oidc_refresh_mode_reader` — pins the refresh mode so offline_access is
      deterministic (we pin "online" so the assertion is purely about groups/base).

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
  @client_secret "super-secret-oidc-value"
  @at_rest_key "admin-bootstrap-groups-test-key"

  setup do
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    # Normal-mode admin OIDC client resolution.
    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)
      _ -> nil
    end)

    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    # Pin online so offline_access is absent and the test is purely about groups + base.
    Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> "online" end)
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
            :admin_oidc_extra_scopes_reader,
            :admin_bootstrap_store
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # In-memory draft store backing the bootstrap-mode oidc_config("bootstrap") read.
  # bootstrap NOT completed so the bootstrap-login leg is live. `extra_draft_fields`
  # merges in additional draft keys (e.g. "admin_oidc_extra_scopes") on top of the
  # base draft below, for tests that need the operator to have filled in Step 3's
  # scope field before "Connect with OIDC" is clicked.
  defp install_bootstrap_store(extra_draft_fields \\ %{}) do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    draft =
      Map.merge(
        %{
          "instance_name" => "test-nebu",
          "oidc_issuer" => @issuer,
          "oidc_client_id" => @client_id,
          "oidc_client_secret" => encrypted,
          "oidc_audience" => @client_id
        },
        extra_draft_fields
      )

    store = start_supervised!({Agent, fn -> %{draft: draft, config: %{}} end})

    dispatcher = fn
      :load_draft, [] -> {:ok, Agent.get(store, & &1.draft)}
      :put_draft, [k, v] -> Agent.update(store, &put_in(&1, [:draft, k], v)) && :ok
      :clear_draft, [] -> Agent.update(store, &%{&1 | draft: %{}}) && :ok
      :put_config, [k, v] -> Agent.update(store, &put_in(&1, [:config, k], v)) && :ok
      :bootstrap_completed?, [] -> {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    store
  end

  # Drives login_start/2 and returns the scope tokens from the 302 redirect's scope param.
  defp scope_params(params) do
    conn =
      conn(:get, "/admin/login/start")
      |> init_test_session(%{})
      |> Auth.login_start(params)

    assert conn.status == 302, "expected a 302 to the IdP; got status #{conn.status}"
    [loc] = get_resp_header(conn, "location")
    assert String.starts_with?(loc, @authorization_endpoint <> "?")

    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — admin/bootstrap scope requests `groups` (and openid profile email)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — admin scope default is openid only (OIDC Scopes Law)" do
    test "normal-mode login scope contains openid only (no groups/profile/email by default)" do
      # bugfix-remove-default-scopes: OIDC Scopes Law — profile/email/groups are NOT defaults.
      # Operators who need groups for Dex must configure admin_oidc_extra_scopes explicitly.
      scopes = scope_params(%{})

      assert "openid" in scopes

      refute "groups" in scopes,
             "groups must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"
    end
  end

  describe "AC3 — admin scope default is openid only (bootstrap operator login)" do
    test "bootstrap-mode login scope contains openid only (no groups/profile/email by default)" do
      # bugfix-remove-default-scopes: OIDC Scopes Law — same rule applies in bootstrap mode.
      install_bootstrap_store()

      scopes = scope_params(%{"mode" => "bootstrap"})

      assert "openid" in scopes

      refute "groups" in scopes,
             "groups must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "profile" in scopes
      refute "email" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # bugfix-bootstrap-scope-ignored — bootstrap-mode scope must read the DRAFT's
  # own admin_oidc_extra_scopes, not server_config (which doesn't have that key
  # until do_complete_bootstrap runs — after the operator has already had to pick
  # a claim). FIXED: oidc_config("bootstrap") now calls
  # OidcScopes.resolve_scope_with_extra(:admin, draft["admin_oidc_extra_scopes"])
  # instead of admin_oidc_scope/0, which read the SAME :admin_oidc_extra_scopes_reader
  # / server_config source as normal-mode login, completely ignoring what the
  # operator typed into Step 3's "Admin client scopes" field (persisted into the
  # draft, not server_config, at
  # this point). So the operator-configured scope is silently dropped and the IdP
  # is only ever asked for "openid" during bootstrap, no matter what.
  # ════════════════════════════════════════════════════════════════════════════

  describe "bugfix-bootstrap-scope-ignored — bootstrap-mode honors the draft's own scope field" do
    test "operator-configured draft scope IS requested during the bootstrap OIDC redirect" do
      install_bootstrap_store(%{"admin_oidc_extra_scopes" => "groups"})

      scopes = scope_params(%{"mode" => "bootstrap"})

      assert "openid" in scopes

      assert "groups" in scopes,
             "draft-configured admin_oidc_extra_scopes must be honored during bootstrap " <>
               "(Step 3's 'Admin client scopes' field would otherwise have no effect); " <>
               "got: #{inspect(scopes)}"
    end

    test "draft with no extra-scopes value still resolves to openid alone (Law default preserved)" do
      install_bootstrap_store()

      scopes = scope_params(%{"mode" => "bootstrap"})

      assert scopes == ["openid"]
    end

    test "bootstrap scope comes EXCLUSIVELY from the draft, never unioned with server_config" do
      # A fix that unions the draft's scope with whatever admin_oidc_extra_scopes_reader
      # (server_config) also returns would pass the two tests above but still be wrong —
      # per AC3 (Nebu.Web.OidcScopes' own no-cross-client-leak rule), the bootstrap login
      # is not "yet another server_config-configured client", it's the ONE flow that reads
      # the draft instead, because server_config doesn't have this key yet. Pin that the
      # draft's "groups" appears and the reader's unrelated "profile" does NOT.
      Application.put_env(:nebu_http, :admin_oidc_extra_scopes_reader, fn -> "profile" end)
      install_bootstrap_store(%{"admin_oidc_extra_scopes" => "groups"})

      scopes = scope_params(%{"mode" => "bootstrap"})

      assert scopes == ["openid", "groups"],
             "bootstrap scope must come exclusively from the draft; got: #{inspect(scopes)}"
    end

    test "an invalid draft scope string fails closed to openid-only (Kassandra LOW hardening)" do
      # resolve_scope_with_extra/2 is caller-supplied, not seam/server_config-validated,
      # so it must not trust its input blindly — a malformed value (however it got into
      # the draft) must never reach the outbound IdP request; it fails closed instead.
      install_bootstrap_store(%{"admin_oidc_extra_scopes" => "groups&evil=1"})

      scopes = scope_params(%{"mode" => "bootstrap"})

      assert scopes == ["openid"],
             "an invalid scope string must fail closed to openid-only; got: #{inspect(scopes)}"
    end
  end
end
