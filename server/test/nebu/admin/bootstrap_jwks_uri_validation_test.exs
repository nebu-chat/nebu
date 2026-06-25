defmodule Nebu.Admin.BootstrapJwksUriValidationTest do
  @moduledoc """
  Cycle-2 regression tests for two findings in `oidc-env-optional-bootstrap`:

  ## MAJOR-1 — JWKS URI is required when NEBU_OIDC_JWKS_URI is not set

  The step-2 HEEx template had a misleading comment claiming JwksCache derives
  the JWKS URI from OIDC discovery when the field is left blank. This is FALSE —
  no discovery is implemented. An operator who leaves the field blank and has no
  `NEBU_OIDC_JWKS_URI` env var ends up with `jwks_uri = nil` in OidcConfig →
  `JwksCache.http_fetch/0` gets nil → returns `{:ok, []}` → no signing keys →
  every Bearer token rejected with 401 forever.

  Fix: `save_oidc/2` returns an error when `jwks_uri` is blank AND
  `NEBU_OIDC_JWKS_URI` is not set. `env_fallback/2` is applied to the JWKS URI
  field just like the other three env-locked fields.

  ## MINOR-1 — Audience guard in `do_complete_bootstrap/2`

  `do_complete_bootstrap/2` previously had no guard for a missing audience.
  A draft that reaches completion without an `oidc_audience` AND without
  `NEBU_OIDC_AUDIENCE` being set leaves the instance in a permanently
  fail-closed state (OidcPlug rejects all tokens).

  Fix: `do_complete_bootstrap/2` returns `{:error, :audience_required}` and
  does NOT write `bootstrap_completed = "true"` when neither source provides
  an audience. `bootstrap_confirm_claim/2` then bounces to
  `/admin/login?error=auth_failed` instead of silently completing.

  ## Test strategy

  Both fixes are exercised against the same injectable `:admin_bootstrap_store`
  + `:admin_secret_at_rest` seams used by all other bootstrap tests — no live
  DB needed.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @endpoint Nebu.Admin.Endpoint

  @issuer "https://idp.example.com"
  @client_id "nebu-test"
  @client_secret "test-client-secret"
  @jwks_uri "https://idp.example.com/.well-known/jwks.json"
  @at_rest_key "bootstrap-jwks-validation-test-key"

  # ── Store helpers ─────────────────────────────────────────────────────────────

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

  defp get_config(store), do: Agent.get(store, & &1.config)

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  defp build_full_draft(opts) do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    %{
      "instance_name" => "test-nebu",
      "oidc_issuer" => Keyword.get(opts, :issuer, @issuer),
      "oidc_client_id" => @client_id,
      "oidc_client_secret" => encrypted,
      "oidc_audience" => Keyword.get(opts, :audience, "nebu-audience"),
      "oidc_jwks_uri" => Keyword.get(opts, :jwks_uri, @jwks_uri),
      "oidc_user_id_claim" => "sub",
      "oidc_displayname_claim" => "name",
      "oidc_email_claim" => "email",
      "bootstrap_sub" => "admin-1",
      "bootstrap_claims" => Jason.encode!([["instance_admin", "instance_admin"]])
    }
  end

  setup do
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    on_exit(fn ->
      for k <- [
            :admin_secret_at_rest,
            :oidc_issuer,
            :oidc_audience,
            :oidc_jwks_uri,
            :matrix_oidc_client_id,
            :admin_oidc_client_id,
            :admin_bootstrap_store
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # ── MAJOR-1 — JWKS URI validation in save_oidc/2 ────────────────────────────

  describe "MAJOR-1 — save_oidc/2 requires JWKS URI when env var not set" do
    test "submitting step 2 without JWKS URI and without NEBU_OIDC_JWKS_URI env returns an error" do
      # Ensure env var is NOT set
      Application.delete_env(:nebu_http, :oidc_jwks_uri)
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)

      install_store(%{"instance_name" => "test-nebu"})

      {:ok, view, _html} =
        live_isolated(
          Plug.Test.conn(:get, "/admin/bootstrap"),
          Nebu.Admin.BootstrapLive,
          session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
        )

      # Navigate to step 2
      view |> element("button[phx-click='goto_step'][phx-value-step='2']") |> render_click()

      # Submit without JWKS URI (blank field, no env var)
      html =
        view
        |> form("form", %{
          "oidc_issuer" => @issuer,
          "oidc_client_id" => @client_id,
          "oidc_client_secret" => @client_secret,
          "oidc_audience" => "nebu-audience",
          "oidc_jwks_uri" => ""
        })
        |> render_submit()

      # Should show an error about JWKS URI being required
      assert html =~ ~r/JWKS URI/i,
             "Expected an error mentioning JWKS URI when field is blank and NEBU_OIDC_JWKS_URI is not set, got: #{html}"

      # Should NOT have advanced to step 3 (still on step 2 with an error)
      assert html =~ ~r/step.*2|oidc_jwks_uri/i or html =~ "required"
    end

    test "submitting step 2 with JWKS URI provided succeeds" do
      Application.delete_env(:nebu_http, :oidc_jwks_uri)
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

      html =
        view
        |> form("form", %{
          "oidc_issuer" => @issuer,
          "oidc_client_id" => @client_id,
          "oidc_client_secret" => @client_secret,
          "oidc_audience" => "nebu-audience",
          "oidc_jwks_uri" => @jwks_uri
        })
        |> render_submit()

      # Should NOT show a JWKS URI required error — form advanced to step 3
      refute html =~ ~r/JWKS URI is required/i,
             "Should not show JWKS URI error when a valid URI is provided"
    end

    test "submitting step 2 without JWKS URI succeeds when NEBU_OIDC_JWKS_URI env var is set" do
      # Env var is set → field is pre-filled + disabled; blank submission is OK.
      # When the field is disabled the browser does NOT send it at all (absent from params).
      Application.put_env(:nebu_http, :oidc_jwks_uri, @jwks_uri)
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

      # Simulate real browser behaviour: disabled field is absent from the form payload.
      # render_submit/2 on the form element (without the disabled field) triggers the event.
      html =
        view
        |> element("form")
        |> render_submit(%{
          "oidc_issuer" => @issuer,
          "oidc_client_id" => @client_id,
          "oidc_client_secret" => @client_secret,
          "oidc_audience" => "nebu-audience"
          # oidc_jwks_uri intentionally absent — disabled browser field is not sent
        })

      # Should NOT show a JWKS URI error — env var covers the absent submission
      refute html =~ ~r/JWKS URI is required/i,
             "JWKS URI should be covered by NEBU_OIDC_JWKS_URI env var; absent field must not error"
    end
  end

  # ── MAJOR-1 — JWKS URI env_fallback applied in save_oidc/2 ──────────────────

  describe "MAJOR-1 — env_fallback applied to JWKS URI in save_oidc/2" do
    test "draft saves env JWKS URI value when field is blank (disabled, env-locked)" do
      Application.put_env(:nebu_http, :oidc_jwks_uri, @jwks_uri)
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)

      store = install_store(%{"instance_name" => "test-nebu"})

      {:ok, view, _html} =
        live_isolated(
          Plug.Test.conn(:get, "/admin/bootstrap"),
          Nebu.Admin.BootstrapLive,
          session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
        )

      view |> element("button[phx-click='goto_step'][phx-value-step='2']") |> render_click()

      # Simulate real browser behaviour: disabled field is absent from the form payload.
      # env_fallback/2 must substitute the env value when "oidc_jwks_uri" is absent.
      view
      |> element("form")
      |> render_submit(%{
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => @client_secret,
        "oidc_audience" => "nebu-audience"
        # oidc_jwks_uri intentionally absent — disabled browser field is not sent
      })

      draft = Agent.get(store, & &1.draft)

      assert draft["oidc_jwks_uri"] == @jwks_uri,
             "Expected draft[\"oidc_jwks_uri\"] = #{inspect(@jwks_uri)} (from env fallback), " <>
               "got #{inspect(draft["oidc_jwks_uri"])}. " <>
               "save_oidc/2 must apply env_fallback/2 to the JWKS URI field."
    end
  end

  # ── MINOR-1 — do_complete_bootstrap/2 audience guard ────────────────────────

  describe "MINOR-1 — do_complete_bootstrap/2 rejects missing audience" do
    test "bootstrap_confirm_claim returns error redirect when draft has no audience and NEBU_OIDC_AUDIENCE not set" do
      # Neither env var nor draft audience
      Application.delete_env(:nebu_http, :oidc_audience)

      # Build a draft with empty oidc_audience
      draft_no_audience = build_full_draft(audience: "")
      install_store(draft_no_audience)

      conn =
        session_conn(:post, "/admin/bootstrap/select-claim")
        |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

      # Should NOT have completed → must NOT redirect to dashboard
      refute get_resp_header(conn, "location") == ["/admin/dashboard"],
             "bootstrap_confirm_claim must NOT complete when audience is absent in both draft and env"

      # Should bounce to /admin/login or /admin/login?error=auth_failed
      [location] = get_resp_header(conn, "location")

      assert String.starts_with?(location, "/admin/login"),
             "Expected redirect to /admin/login (not dashboard) when audience is missing, " <>
               "got #{inspect(location)}"
    end

    test "bootstrap_confirm_claim does NOT write bootstrap_completed when audience is missing" do
      Application.delete_env(:nebu_http, :oidc_audience)

      draft_no_audience = build_full_draft(audience: "")
      store = install_store(draft_no_audience)

      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

      config = get_config(store)

      refute config["bootstrap_completed"] == "true",
             "bootstrap_completed must NOT be written when audience guard fires (audience missing)"
    end

    test "bootstrap_confirm_claim succeeds when draft has no audience but NEBU_OIDC_AUDIENCE is set" do
      # Audience comes from env, not draft
      Application.put_env(:nebu_http, :oidc_audience, "env-audience")

      draft_no_audience = build_full_draft(audience: "")
      store = install_store(draft_no_audience)

      conn =
        session_conn(:post, "/admin/bootstrap/select-claim")
        |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

      assert get_resp_header(conn, "location") == ["/admin/dashboard"],
             "bootstrap_confirm_claim should succeed when NEBU_OIDC_AUDIENCE env var is set"

      config = get_config(store)

      assert config["bootstrap_completed"] == "true",
             "bootstrap_completed must be written when audience is available via env"
    end

    test "bootstrap_confirm_claim succeeds when draft has a valid audience" do
      Application.delete_env(:nebu_http, :oidc_audience)

      draft = build_full_draft(audience: "nebu-audience")
      store = install_store(draft)

      conn =
        session_conn(:post, "/admin/bootstrap/select-claim")
        |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

      assert get_resp_header(conn, "location") == ["/admin/dashboard"],
             "bootstrap_confirm_claim should succeed when draft has a valid audience"

      config = get_config(store)
      assert config["bootstrap_completed"] == "true"
      assert config["oidc_audience"] == "nebu-audience"
    end
  end
end
