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

  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

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

  # scope-admin-claim-to-path (code-review MAJOR M1 fix): a claim path is now mandatory
  # on bootstrap completion. Builds the JSON-encoded "admin_group_claim_choice" param
  # select_claim_html/1 now emits, matching the {path, value} pair stashed in
  # "bootstrap_claims" by build_full_draft/1 above (["instance_admin", "instance_admin"]).
  defp confirm_params(value, path) do
    %{"admin_group_claim_choice" => Jason.encode!(%{"value" => value, "path" => path})}
  end

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

  # ── MAJOR-1 — JWKS URI validation — SUPERSEDED (fix-bootstrap-wizard-liveview-bugs) ─
  #
  # The step-2 JWKS URI input field was removed in the BootstrapLive → BootstrapController
  # conversion. JWKS URI is now auto-discovered server-side from
  # `{issuer}/.well-known/openid-configuration`. The BootstrapLive.save_oidc/2 tests that
  # asserted "blank JWKS URI returns an error" tested the old LiveView behavior (which is
  # no longer the production code path — the route was removed). They were deleted to avoid
  # false confidence from tests that exercise dead code.
  #
  # Coverage of the new auto-discovery behavior lives in:
  #   server/test/nebu/admin/bootstrap_controller_test.exs
  #   "POST /admin/bootstrap/step/2 succeeds without a jwks_uri parameter (JWKS auto-discovered)"

  # ── env-locked JWKS-URI tests — REMOVED (ADR-022) ───────────────────────────
  #
  # oidc-bootstrap-only-config (ADR-022) removed the NEBU_OIDC_JWKS_URI env path and
  # the env-lock / env_fallback mechanism. The JWKS URI is now auto-discovered (see above).

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
        |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "instance_admin"))

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
      |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "instance_admin"))

      config = get_config(store)

      refute config["bootstrap_completed"] == "true",
             "bootstrap_completed must NOT be written when audience guard fires (audience missing)"
    end

    # NOTE: the former "succeeds when draft has no audience but NEBU_OIDC_AUDIENCE is
    # set" test was DELETED (ADR-022): there is no NEBU_OIDC_AUDIENCE env fallback —
    # the audience is required from the wizard draft alone. An empty draft audience
    # now always rejects with :audience_required (covered above).

    test "bootstrap_confirm_claim succeeds when draft has a valid audience" do
      Application.delete_env(:nebu_http, :oidc_audience)

      draft = build_full_draft(audience: "nebu-audience")
      store = install_store(draft)

      conn =
        session_conn(:post, "/admin/bootstrap/select-claim")
        |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "instance_admin"))

      assert get_resp_header(conn, "location") == ["/admin/dashboard"],
             "bootstrap_confirm_claim should succeed when draft has a valid audience"

      config = get_config(store)
      assert config["bootstrap_completed"] == "true"
      assert config["oidc_audience"] == "nebu-audience"
    end
  end
end
