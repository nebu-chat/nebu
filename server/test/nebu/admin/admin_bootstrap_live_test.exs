defmodule Nebu.Web.AdminBootstrapLiveTest do
  @moduledoc """
  Acceptance test for the Bootstrap Wizard (`bugfix/fix-bootstrap-wizard-oidc-flow`).

  Exercises the Go-parity 3-step wizard sequence through real `handle_event/3`
  transitions (`save_step` for steps 1-2, claim mapping + `connect_oidc` on step 3).
  Step 3's "Connect with OIDC" persists the claim mapping and redirects to
  `/admin/login/start?mode=bootstrap` — it does NOT promote the draft or complete
  bootstrap (that happens at the post-login Confirm; see BootstrapOidcFlowTest).
  The `oidc_client_secret` is stored ENCRYPTED at rest, never in plaintext — round-
  tripping it through the wizard's own decryptor recovers the original secret.

  AC1 (heading "Bootstrap Setup", progress indicator, step labels) is asserted on
  the rendered markup.

  ## ADR-018 / no live Postgres

  The wizard's draft + server_config reads/writes are inline SQL against `Nebu.Repo`,
  which is not started in the unit suite. We install the project's thin
  injectable-boundary seam (`:admin_bootstrap_store`, the same shape as RoomsLive's
  `:admin_auto_join_writer`): a single `fun.(op, args)` dispatcher backed by an in-memory
  key/value Agent. The actual SQL stays inline in the LiveView; only its execution point
  is injected, so this is NOT a repository abstraction.

  ## Crash/restart — NOT APPLICABLE

  BootstrapLive is stateless / DB-backed (Persistenz Option C): the wizard re-reads its
  draft on mount, so there is no GenServer state to recover.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @client_secret "super-secret-oidc-value"
  @at_rest_key "bootstrap-at-rest-test-key"

  setup do
    # In-memory draft + server_config tables backing the inline-SQL seam.
    # start_supervised ties the Agent to the ExUnit supervisor so it is torn down
    # cleanly after on_exit runs (avoids racing a linked process's own shutdown).
    store = start_supervised!({Agent, fn -> %{draft: %{}, config: %{}} end})

    dispatcher = fn
      :load_draft, [] ->
        {:ok, Agent.get(store, & &1.draft)}

      :put_draft, [key, value] ->
        Agent.update(store, fn s -> put_in(s, [:draft, key], value) end)
        :ok

      :clear_draft, [] ->
        Agent.update(store, fn s -> %{s | draft: %{}} end)
        :ok

      :put_config, [key, value] ->
        Agent.update(store, fn s -> put_in(s, [:config, key], value) end)
        :ok

      :bootstrap_completed?, [] ->
        {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    # Deterministic at-rest key for the client-secret encryption seam (MINOR-3).
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    # Ensure OIDC env vars are clean so bootstrap form fields are NOT disabled (env-locked)
    # during these tests. A prior test may leak these values. The env-lock behavior is
    # tested separately in bootstrap_oidc_audience_test.exs (AC4).
    for k <- [:oidc_issuer, :oidc_audience, :matrix_oidc_client_id, :oidc_jwks_uri] do
      Application.delete_env(:nebu_http, k)
    end

    on_exit(fn ->
      for k <- [:admin_bootstrap_store, :admin_secret_at_rest, :oidc_issuer, :oidc_audience, :matrix_oidc_client_id, :oidc_jwks_uri] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    {:ok, store: store}
  end

  test "AC1: heading, progress indicator and step labels match the spec", %{store: _store} do
    {:ok, view, html} =
      live_isolated(Plug.Test.conn(:get, "/admin/bootstrap"), Nebu.Admin.BootstrapLive,
        session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      )

    # Heading "Bootstrap Setup" (not "Bootstrap Wizard").
    assert html =~ "Bootstrap Setup"
    # Progress indicator marks the active step (step 1 on a fresh draft).
    assert html =~ ~s(data-step="1")
    assert html =~ ~s(data-progress-step="1")
    assert html =~ ~s(data-step-active="1")
    # Step 1 label.
    assert html =~ "Instance Name"

    # Step 2 labels.
    view |> form("form", %{"instance_name" => "test-nebu"}) |> render_submit()
    html2 = render(view)
    assert html2 =~ ~s(data-step="2")
    assert html2 =~ ~s(data-step-active="2")
    assert html2 =~ "OIDC Issuer URL"
    assert html2 =~ "OIDC Client ID"
    assert html2 =~ "OIDC Client Secret"
  end

  test "AC2: walks steps 1-3 then Connect-with-OIDC redirects to login/start?mode=bootstrap",
       %{store: store} do
    {:ok, view, _html} =
      live_isolated(Plug.Test.conn(:get, "/admin/bootstrap"), Nebu.Admin.BootstrapLive,
        session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      )

    # Fresh draft → resumes at step 1.
    assert render(view) =~ ~s(data-step="1")

    # Step 1 → 2: instance name.
    view |> form("form", %{"instance_name" => "test-nebu"}) |> render_submit()
    assert render(view) =~ ~s(data-step="2")
    assert Agent.get(store, &(&1.draft["instance_name"])) == "test-nebu"

    # Step 2 → 3: OIDC config (client secret encrypted before it touches the store).
    # oidc_audience is required (M-2, cycle-1) when not set via NEBU_OIDC_AUDIENCE env.
    # oidc_jwks_uri is required (MAJOR-1, cycle-2) when not set via NEBU_OIDC_JWKS_URI env.
    view
    |> form("form", %{
      "oidc_issuer" => "https://idp.example.com",
      "oidc_client_id" => "nebu-admin",
      "oidc_client_secret" => @client_secret,
      "oidc_audience" => "nebu-admin",
      "oidc_jwks_uri" => "https://idp.example.com/.well-known/jwks.json"
    })
    |> render_submit()

    assert render(view) =~ ~s(data-step="3")

    stored_secret = Agent.get(store, &(&1.draft["oidc_client_secret"]))
    refute stored_secret == @client_secret, "client secret must NOT be stored in plaintext"
    assert is_binary(stored_secret) and stored_secret != ""
    assert Nebu.Admin.BootstrapLive.decrypt_secret(stored_secret) == @client_secret

    # Step 3: "Connect with OIDC" persists the claim mapping then redirects the browser
    # to the bootstrap-mode OIDC login leg. The draft must NOT be promoted yet and
    # bootstrap_completed must NOT be set (that happens at Confirm, after login).
    assert {:error, {:redirect, %{to: to}}} =
             view
             |> element(~s(button[phx-click="connect_oidc"]))
             |> render_click()

    assert to == "/admin/login/start?mode=bootstrap"

    # Claim mapping persisted; config still empty (no premature completion).
    # No claim value was submitted, so save_claim_mapping/1 stores the documented
    # default "name" (NOT the opaque "sub" — see @default_claim_mapping; it matches
    # the migration seed server_config.oidc_user_id_claim = 'name').
    assert Agent.get(store, &(&1.draft["oidc_user_id_claim"])) == "name"
    assert Agent.get(store, & &1.config) == %{}
  end

  test "step 1 rejects an empty instance name and stays on step 1" do
    {:ok, view, _html} =
      live_isolated(Plug.Test.conn(:get, "/admin/bootstrap"), Nebu.Admin.BootstrapLive,
        session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
      )

    view |> form("form", %{"instance_name" => "   "}) |> render_submit()

    html = render(view)
    assert html =~ ~s(data-step="1")
    assert html =~ "Instance name must not be empty."
  end
end
