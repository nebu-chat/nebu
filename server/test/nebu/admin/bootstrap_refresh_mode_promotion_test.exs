defmodule Nebu.Admin.BootstrapRefreshModePromotionTest do
  @moduledoc """
  RED-phase ATDD test for story `oidc-refresh-mode-config`, AC4 (set at bootstrap).

  Mirrors `bootstrap_oidc_flow_test.exs`: drives `Auth.bootstrap_confirm_claim/2`
  directly against the injectable `:admin_bootstrap_store` Agent seam (no live
  Repo). The wizard step writes the operator's chosen refresh modes into the
  `bootstrap_draft` (`matrix_oidc_refresh_mode` / `admin_oidc_refresh_mode`); on
  Confirm, `complete_bootstrap` must PROMOTE them into `server_config` alongside
  the existing OIDC keys (`oidc_issuer`, `admin_group_claim`, …).

  This FAILS today: `do_complete_bootstrap/2` promotes a FIXED key list that does
  NOT include the two refresh-mode keys, so they never reach `server_config`.

  ## Seam the dev MUST touch

  Add `matrix_oidc_refresh_mode` + `admin_oidc_refresh_mode` to the `keys`
  promoted in `Nebu.Admin.Auth.do_complete_bootstrap/2` (only promote when the
  draft value is a non-empty `offline`|`online`). The wizard
  (`Nebu.Admin.BootstrapLive`) writes them to the draft via `put_draft/2`; defaults
  Matrix=offline / Admin=online are preselected (covered by the ConfigLive/e2e
  tests + AC1 defaults).

  ## Crash/restart — NOT APPLICABLE (stateless DB-backed confirm, Persistenz C).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @client_id "nebu-admin"
  @client_secret "super-secret-oidc-value"
  @at_rest_key "bootstrap-at-rest-test-key"

  defp install_store(mode_overrides \\ %{}) do
    encrypted = Nebu.Admin.BootstrapLive.encrypt_secret(@client_secret)

    draft =
      %{
        "instance_name" => "test-nebu",
        "oidc_issuer" => @issuer,
        "oidc_client_id" => @client_id,
        "oidc_client_secret" => encrypted,
        # MINOR-1 (cycle-2): oidc_audience is required by do_complete_bootstrap/2 when
        # NEBU_OIDC_AUDIENCE is not set. All bootstrap confirm tests must include it.
        "oidc_audience" => "nebu-audience",
        "oidc_user_id_claim" => "sub",
        "oidc_displayname_claim" => "name",
        "oidc_email_claim" => "email",
        # The operator's chosen refresh modes, written by the wizard step.
        "matrix_oidc_refresh_mode" => "offline",
        "admin_oidc_refresh_mode" => "online",
        # Required guards for bootstrap_confirm_claim/2 (authenticated identity +
        # discovered claim set), exactly as bootstrap_oidc_flow_test.exs seeds them.
        "bootstrap_sub" => "kai",
        "bootstrap_claims" => Jason.encode!([["groups", "instance_admin"]])
      }
      |> Map.merge(mode_overrides)

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

  test "bootstrap completion promotes BOTH refresh modes into server_config (AC4)" do
    store = install_store()

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    # Sanity: the confirm completed (not bounced to login).
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    config = Agent.get(store, & &1.config)
    assert config["bootstrap_completed"] == "true"

    # The two refresh-mode keys must have been promoted from the draft.
    assert config["matrix_oidc_refresh_mode"] == "offline"
    assert config["admin_oidc_refresh_mode"] == "online"
  end

  # SECURITY (test-review): a junk draft value must NOT be promoted into server_config —
  # the enum guard rejects anything outside offline|online so no arbitrary scope can be
  # injected. The valid sibling mode is still promoted.
  test "junk refresh-mode value is rejected, not promoted (enum guard)" do
    store =
      install_store(%{
        "matrix_oidc_refresh_mode" => "offline_access evil",
        "admin_oidc_refresh_mode" => "online"
      })

    conn =
      session_conn(:post, "/admin/bootstrap/select-claim")
      |> Auth.bootstrap_confirm_claim(%{"admin_group_claim" => "instance_admin"})

    assert conn.status == 302

    config = Agent.get(store, & &1.config)
    refute Map.has_key?(config, "matrix_oidc_refresh_mode")
    assert config["admin_oidc_refresh_mode"] == "online"
  end
end
