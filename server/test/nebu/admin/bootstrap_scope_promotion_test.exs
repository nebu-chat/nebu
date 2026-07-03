defmodule Nebu.Admin.BootstrapScopePromotionTest do
  @moduledoc """
  RED-phase ATDD test for story `oidc-scopes-configurable`, AC6.

  ## What is under test

  `save_oidc/2` (Bootstrap Wizard step 3 in `BootstrapLive` / `BootstrapController`)
  validates and stores scope values via `put_draft/2`.

  `complete_bootstrap/1` (in `Nebu.Admin.Auth.bootstrap_confirm_claim/2`) must PROMOTE
  `matrix_oidc_extra_scopes` and `admin_oidc_extra_scopes` from the draft into
  `server_config`, analogously to `matrix_oidc_refresh_mode` / `admin_oidc_refresh_mode`
  (story oidc-refresh-mode-config, AC4 — implemented in `bootstrap_refresh_mode_promotion_test.exs`).

  ## Why RED

  Today `do_complete_bootstrap/2` in `Nebu.Admin.Auth` promotes a FIXED key list that
  does NOT include `matrix_oidc_extra_scopes` or `admin_oidc_extra_scopes`. The draft
  keys are written by the wizard but are silently dropped at Confirm. Both assertions
  below fail against the current implementation.

  ## Seam

  Same `:admin_bootstrap_store` Agent seam as `bootstrap_refresh_mode_promotion_test.exs`.
  The draft includes `matrix_oidc_extra_scopes` / `admin_oidc_extra_scopes` (written by
  the wizard step); after `bootstrap_confirm_claim/2` they must appear in the config.

  ## Scope validation at promotion time

  If a draft scope value contains characters outside `[a-zA-Z0-9_:.-]` (injection guard),
  it must NOT be promoted — analogous to the offline|online enum guard for refresh modes.
  The valid sibling key is still promoted.

  ## Crash/restart — NOT APPLICABLE (stateless DB-backed confirm, Persistenz C).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @client_id "nebu-admin"
  @client_secret "super-secret-oidc-value"
  @at_rest_key "bootstrap-scope-promotion-test-key"

  defp install_store(scope_overrides \\ %{}) do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    draft =
      %{
        "instance_name" => "test-nebu",
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => encrypted,
        "oidc_audience" => "nebu-audience",
        "oidc_user_id_claim" => "sub",
        "oidc_displayname_claim" => "name",
        "oidc_email_claim" => "email",
        "matrix_oidc_refresh_mode" => "offline",
        "admin_oidc_refresh_mode" => "online",
        # Scope values written by the wizard step (AC2/AC6).
        "matrix_oidc_extra_scopes" => "profile email",
        "admin_oidc_extra_scopes" => "profile email groups",
        # Required for bootstrap_confirm_claim/2 (authenticated identity + discovered claim set).
        "bootstrap_sub" => "kai",
        "bootstrap_claims" => Jason.encode!([["groups", "instance_admin"]])
      }
      |> Map.merge(scope_overrides)

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

  setup do
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    on_exit(fn ->
      for k <- [:admin_secret_at_rest, :admin_bootstrap_store] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  # scope-admin-claim-to-path (code-review MAJOR M1 fix): a claim path is now mandatory
  # on bootstrap completion. Builds the JSON-encoded "admin_group_claim_choice" param
  # select_claim_html/1 now emits, matching the {path, value} pair stashed in
  # "bootstrap_claims" by install_store/1 above (["groups", "instance_admin"]).
  defp confirm_params(value, path) do
    %{"admin_group_claim_choice" => Jason.encode!(%{"value" => value, "path" => path})}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — bootstrap completion promotes BOTH scope keys into server_config
  # ════════════════════════════════════════════════════════════════════════════

  test "bootstrap completion promotes matrix_oidc_extra_scopes into server_config (AC6)" do
    store = install_store()

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "groups"))

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)
    assert config["bootstrap_completed"] == "true"

    assert config["matrix_oidc_extra_scopes"] == "profile email",
           "bootstrap_confirm_claim must promote matrix_oidc_extra_scopes; got config: #{inspect(config)}"
  end

  test "bootstrap completion promotes admin_oidc_extra_scopes into server_config (AC6)" do
    store = install_store()

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "groups"))

    assert conn.status == 302

    config = Agent.get(store, & &1.config)

    assert config["admin_oidc_extra_scopes"] == "profile email groups",
           "bootstrap_confirm_claim must promote admin_oidc_extra_scopes; got config: #{inspect(config)}"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 SECURITY — invalid scope characters must NOT be promoted
  # ════════════════════════════════════════════════════════════════════════════

  test "junk matrix_oidc_extra_scopes value (invalid chars) is rejected, not promoted" do
    store =
      install_store(%{
        "matrix_oidc_extra_scopes" => "profile email!badscope",
        "admin_oidc_extra_scopes" => "profile email groups"
      })

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "groups"))

    assert conn.status == 302

    config = Agent.get(store, & &1.config)
    refute Map.has_key?(config, "matrix_oidc_extra_scopes"),
           "Invalid matrix_oidc_extra_scopes must NOT be promoted; got config: #{inspect(config)}"

    # Valid admin scope is still promoted.
    assert config["admin_oidc_extra_scopes"] == "profile email groups"
  end

  test "junk admin_oidc_extra_scopes value (invalid chars) is rejected, not promoted" do
    store =
      install_store(%{
        "matrix_oidc_extra_scopes" => "profile email",
        "admin_oidc_extra_scopes" => "profile <inject>"
      })

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "groups"))

    assert conn.status == 302

    config = Agent.get(store, & &1.config)
    refute Map.has_key?(config, "admin_oidc_extra_scopes"),
           "Invalid admin_oidc_extra_scopes must NOT be promoted; got config: #{inspect(config)}"

    # Valid matrix scope is still promoted.
    assert config["matrix_oidc_extra_scopes"] == "profile email"
  end

  test "scope keys absent from draft are silently skipped (no error)" do
    # If the operator somehow completes bootstrap without scope keys in the draft
    # (e.g. old wizard version), promotion must not crash.
    store =
      install_store(%{
        "matrix_oidc_extra_scopes" => nil,
        "admin_oidc_extra_scopes" => nil
      })

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(confirm_params("instance_admin", "groups"))

    # Must complete bootstrap normally (not crash).
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)
    assert config["bootstrap_completed"] == "true"
  end
end
