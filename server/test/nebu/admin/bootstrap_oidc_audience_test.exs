defmodule Nebu.Admin.BootstrapOidcAudienceTest do
  @moduledoc """
  RED-phase ATDD tests for the `bugfix/room-names` story: Bootstrap stores and
  promotes `oidc_audience` (AC3/AC4).

  ## What MUST fail (red phase)

  1. **AC3 — Bootstrap saves `oidc_audience`**: The bootstrap wizard step 2 OIDC
     form currently does NOT collect an `oidc_audience` field. `save_oidc/2` does
     not call `put_draft("oidc_audience", ...)`. Tests assert that after `save_step`
     the draft contains `oidc_audience` — this WILL FAIL until the field is added.

  2. **AC4 — Bootstrap promotes `oidc_audience`**: `do_complete_bootstrap/2` in
     `Nebu.Admin.Auth` promotes these keys from draft:
     `~w(instance_name oidc_issuer oidc_client_id oidc_client_secret
         oidc_user_id_claim oidc_displayname_claim oidc_email_claim)`.
     `oidc_audience` is NOT in that list. Tests assert `server_config` contains
     `oidc_audience` after `bootstrap_confirm_claim/2` — this WILL FAIL until
     `oidc_audience` is added to the promote list in `Auth.do_complete_bootstrap/2`.

  ## Seams (ADR-018, no live Repo in the unit suite)

    * `:admin_bootstrap_store` — injectable draft/config dispatcher (same shape as
      all other bootstrap tests, backed by an in-memory Agent).
    * `:admin_secret_at_rest` — deterministic AES key for client-secret encryption.
    * `:oidc_metadata_override` — discovery doc stub (authorization/token endpoints).
    * `:admin_oidc_token_override` — short-circuits the IdP token exchange for the
      `bootstrap_confirm_claim/2` path (borrowed from `BootstrapOidcFlowTest`).

  ## Crash/restart — NOT APPLICABLE

  Both `BootstrapLive` (draft collection) and `Auth.bootstrap_confirm_claim/2`
  (draft promotion) are stateless request handlers over DB-backed state
  (Persistenz Option C). No GenServer crash test needed.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @endpoint Nebu.Admin.Endpoint

  @issuer "https://idp.example.com"
  @authorization_endpoint "https://idp.example.com/auth"
  @token_endpoint "https://idp.example.com/token"
  @client_id "nebu-test"
  @client_secret "test-client-secret"
  @oidc_audience "nebu-audience"
  @at_rest_key "bootstrap-audience-test-key"

  # ── Store builder ────────────────────────────────────────────────────────────

  defp install_store(draft_override, config_override \\ %{}) do
    store = start_supervised!({Agent, fn -> %{draft: draft_override, config: config_override} end})

    dispatcher = fn
      :load_draft, [] ->
        {:ok, Agent.get(store, & &1.draft)}

      :put_draft, [k, v] ->
        Agent.update(store, &put_in(&1, [:draft, k], v))
        :ok

      :clear_draft, [] ->
        Agent.update(store, fn s -> %{s | draft: %{}} end)
        :ok

      :put_config, [k, v] ->
        Agent.update(store, &put_in(&1, [:config, k], v))
        :ok

      :bootstrap_completed?, [] ->
        {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    store
  end

  # Returns the current draft/config state from the store Agent.
  defp get_draft(store), do: Agent.get(store, & &1.draft)
  defp get_config(store), do: Agent.get(store, & &1.config)

  setup do
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)
    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :admin_oidc_client_id, @client_id)
    Application.put_env(:nebu_http, :admin_oidc_redirect_uri, "http://localhost:8008/admin/callback")

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      for k <- [
            :admin_secret_at_rest,
            :oidc_issuer,
            :oidc_audience,
            :matrix_oidc_client_id,
            :admin_oidc_client_id,
            :admin_oidc_redirect_uri,
            :oidc_metadata_override,
            :admin_bootstrap_store,
            :admin_oidc_token_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # ── AC3 — Bootstrap step 2 saves oidc_audience to the draft ──────────────────
  # WILL FAIL: BootstrapLive.save_oidc/2 does not yet collect oidc_audience.
  # After the fix: the step-2 form must have an `oidc_audience` field and
  # `save_oidc/2` must call `put_draft("oidc_audience", audience)`.

  describe "AC3 — Bootstrap wizard step 2 collects and saves oidc_audience" do
    test "save_step on step 2 writes oidc_audience to the draft" do
      # Remove env-var OIDC config so the bootstrap form fields are NOT disabled
      # (they are locked when the env var is set — that's AC4 behavior tested elsewhere).
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)

      store = install_store(%{"instance_name" => "test-nebu"})

      {:ok, view, _html} =
        live_isolated(
          Plug.Test.conn(:get, "/admin/bootstrap"),
          Nebu.Admin.BootstrapLive,
          session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
        )

      # Navigate to step 2
      view |> element("button[phx-click='goto_step'][phx-value-step='2']") |> render_click()

      # Submit step 2 with oidc_audience included.
      # oidc_jwks_uri is also required (MAJOR-1, cycle-2) when not set via env.
      view
      |> form("form", %{
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => @client_secret,
        "oidc_audience" => @oidc_audience,
        "oidc_jwks_uri" => "https://idp.example.com/.well-known/jwks.json"
      })
      |> render_submit()

      draft = get_draft(store)

      # WILL FAIL: draft currently won't contain "oidc_audience"
      assert draft["oidc_audience"] == @oidc_audience,
             "Expected draft[\"oidc_audience\"] = #{inspect(@oidc_audience)}, " <>
               "got #{inspect(draft["oidc_audience"])}. " <>
               "BootstrapLive.save_oidc/2 must persist oidc_audience to the draft."
    end

    test "oidc_audience field is present on the step-2 form HTML" do
      # Remove env-var OIDC config so fields are not locked/disabled.
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)

      install_store(%{"instance_name" => "test-nebu"})

      {:ok, view, _html} =
        live_isolated(
          Plug.Test.conn(:get, "/admin/bootstrap"),
          Nebu.Admin.BootstrapLive,
          session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
        )

      view |> element("button[phx-click='goto_step'][phx-value-step='2']") |> render_click()

      html = render(view)

      # WILL FAIL: the step-2 form does not yet have an oidc_audience input.
      assert html =~ ~r/name="oidc_audience"/,
             "Step-2 HTML must contain an oidc_audience input field"
    end
  end

  # ── AC4 — bootstrap_confirm_claim promotes oidc_audience to server_config ────
  # WILL FAIL: do_complete_bootstrap/2 in Auth does not include "oidc_audience" in
  # the promoted keys list. server_config will not contain oidc_audience until the
  # list is updated.

  describe "AC4 — bootstrap completion promotes oidc_audience to server_config" do
    test "server_config contains oidc_audience after bootstrap_confirm_claim/2" do
      encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

      # Draft includes oidc_audience (as it will after AC3 is implemented).
      # bootstrap_sub + bootstrap_claims are required guard fields populated by the
      # bootstrap_callback/2 step (post-OIDC); without them bootstrap_confirm_claim/2
      # rejects the call (missing identity check). Mirror bootstrap_refresh_mode_promotion_test.exs.
      draft = %{
        "instance_name" => "test-nebu",
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => encrypted,
        "oidc_audience" => @oidc_audience,
        "oidc_user_id_claim" => "sub",
        "oidc_displayname_claim" => "name",
        "oidc_email_claim" => "email",
        "bootstrap_sub" => "admin-1",
        "bootstrap_claims" => Jason.encode!([["instance_admin", "instance_admin"]])
      }

      store = install_store(draft)

      # Build a minimal conn that looks like the POST /admin/bootstrap/select-claim.
      # init_test_session/2 is required so configure_session/2 inside bootstrap_confirm_claim
      # can call get_session — mirrors bootstrap_refresh_mode_promotion_test.exs.
      conn =
        :post
        |> conn("/admin/bootstrap/select-claim", "admin_group_claim=instance_admin")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> init_test_session(%{})

      # Directly call bootstrap_confirm_claim/2 (same pattern as BootstrapOidcFlowTest).
      # WILL FAIL until oidc_audience is added to do_complete_bootstrap/2.
      # bootstrap_confirm_claim/2 returns a halted conn (redirect), not {:ok, conn}.
      conn = Auth.bootstrap_confirm_claim(conn, %{"admin_group_claim" => "instance_admin"})

      # Sanity: confirm completed (redirected to dashboard, not bounced to login).
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/dashboard"]

      config = get_config(store)

      assert config["oidc_audience"] == @oidc_audience,
             "Expected server_config[\"oidc_audience\"] = #{inspect(@oidc_audience)}, " <>
               "got #{inspect(config["oidc_audience"])}. " <>
               "Auth.do_complete_bootstrap/2 must promote oidc_audience from the draft."
    end

    test "oidc_audience promotion does not overwrite existing value when draft entry is empty" do
      encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

      # Draft has an empty oidc_audience — must NOT overwrite an existing server_config value.
      # bootstrap_sub + bootstrap_claims are required guard fields (see test above).
      # MINOR-1 (cycle-2): audience guard in do_complete_bootstrap/2 requires a non-empty
      # audience from either draft or env. Simulate NEBU_OIDC_AUDIENCE being set (env covers
      # the empty draft, which is the realistic scenario when an operator re-runs the wizard
      # on an instance that was originally configured via env vars).
      Application.put_env(:nebu_http, :oidc_audience, "existing-audience")

      draft = %{
        "instance_name" => "test-nebu",
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => encrypted,
        "oidc_audience" => "",
        "oidc_user_id_claim" => "sub",
        "oidc_displayname_claim" => "name",
        "oidc_email_claim" => "email",
        "bootstrap_sub" => "admin-1",
        "bootstrap_claims" => Jason.encode!([["instance_admin", "instance_admin"]])
      }

      # Pre-seed server_config with an existing audience
      store = install_store(draft, %{"oidc_audience" => "existing-audience"})

      conn =
        :post
        |> conn("/admin/bootstrap/select-claim", "admin_group_claim=instance_admin")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> init_test_session(%{})

      conn = Auth.bootstrap_confirm_claim(conn, %{"admin_group_claim" => "instance_admin"})

      # Sanity: confirm completed (redirected to dashboard).
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/dashboard"]

      config = get_config(store)

      # Empty draft value must NOT overwrite the pre-existing server_config value.
      assert config["oidc_audience"] == "existing-audience",
             "An empty draft oidc_audience must not overwrite an existing server_config value"
    end
  end
end
