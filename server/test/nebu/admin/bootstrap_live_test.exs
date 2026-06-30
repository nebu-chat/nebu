defmodule Nebu.Admin.BootstrapLiveTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-scopes-configurable`, AC2 + AC3 + AC6 + AC12.

  ## What is under test

  The Bootstrap Wizard Step 3 (claim mapping / OIDC connect) must render two new text
  input fields BEFORE the "OIDC refresh mode" fieldset (AC2):

    1. **"Matrix client scopes"** (name: `matrix_oidc_extra_scopes`)
       - Placeholder: `"profile email"`
       - Default pre-filled value: `"profile email"`

    2. **"Admin client scopes"** (name: `admin_oidc_extra_scopes`)
       - Placeholder: `"profile email groups"`
       - Default pre-filled value: `"profile email groups"`

  Scope values are validated against `[a-zA-Z0-9_:.-]` characters only (AC3).
  Invalid values (including newlines) reject the form with an error message (AC3).
  Valid scope values are persisted in the draft after save (AC6).

  ## Why these tests are RED

  Today the Bootstrap Wizard step-3 form (in `index.html.heex` and `bootstrap_live.ex`)
  does NOT render `matrix_oidc_extra_scopes` or `admin_oidc_extra_scopes` fields.
  The `save_claim_mapping/1` function does NOT persist them. The scope-character
  validation does NOT exist. All assertions below fail against the current implementation.

  ## Test approach

  The Bootstrap Wizard is exercised through its `BootstrapController` (plain HTTP
  controller) which uses the same `:admin_bootstrap_store` seam as `BootstrapLive`.
  We drive `GET /admin/bootstrap` (with `?step=3` to pre-navigate) and `POST
  /admin/bootstrap/step/3` through `Nebu.Admin.Endpoint.call/2`.

  Note: The BootstrapController is behind `:bootstrap_gate` (not `:require_admin`),
  so no admin session is needed — bootstrap is accessible before completion.

  ## ADR-018 / no live Postgres

  The `:admin_bootstrap_store` seam (Agent-backed in-memory store) replaces all
  DB reads/writes. The actual inline SQL stays in the controller; only the execution
  point is injected.

  ## Crash/restart — NOT APPLICABLE

  BootstrapController is stateless / DB-backed (Persistenz Option C). No GenServer.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-bootstrap-scope-test-key-base!", 2)

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    # In-memory draft + server_config store.
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
    Application.put_env(:nebu_http, :admin_secret_at_rest, "bootstrap-scope-at-rest-key")

    on_exit(fn ->
      for k <- [
            :admin_csrf_bypass,
            :admin_bootstrap_store,
            :admin_secret_at_rest
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    {:ok, store: store}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp seed_step2_draft(store) do
    Agent.update(store, fn s ->
      draft = %{
        "instance_name" => "test-nebu",
        "oidc_issuer" => "https://idp.example.com",
        "oidc_client_id" => "nebu-admin",
        "oidc_client_secret" => Nebu.Admin.BootstrapLive.encrypt_secret("secret"),
        "oidc_audience" => "nebu-admin",
        "oidc_jwks_uri" => "https://idp.example.com/jwks"
      }

      %{s | draft: draft}
    end)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12-1 — Scope fields rendered before refresh-mode fieldset
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12-1: scope input fields render before the OIDC refresh mode fieldset" do
    test "step 3 renders matrix_oidc_extra_scopes input before refresh mode fieldset",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:get, "/admin/bootstrap?step=3")
        |> endpoint_call()

      assert conn.status == 200
      html = conn.resp_body

      # Field must be present.
      assert html =~ ~s(name="matrix_oidc_extra_scopes"),
             "Step 3 must render matrix_oidc_extra_scopes field; got:\n#{html}"

      # Must appear BEFORE the refresh-mode fieldset.
      matrix_scopes_pos = :binary.match(html, "matrix_oidc_extra_scopes") |> elem(0)
      refresh_fieldset_pos = :binary.match(html, "OIDC refresh mode") |> elem(0)

      assert matrix_scopes_pos < refresh_fieldset_pos,
             "matrix_oidc_extra_scopes must appear before 'OIDC refresh mode' fieldset"
    end

    test "step 3 renders admin_oidc_extra_scopes input before refresh mode fieldset",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:get, "/admin/bootstrap?step=3")
        |> endpoint_call()

      assert conn.status == 200
      html = conn.resp_body

      assert html =~ ~s(name="admin_oidc_extra_scopes"),
             "Step 3 must render admin_oidc_extra_scopes field; got:\n#{html}"

      admin_scopes_pos = :binary.match(html, "admin_oidc_extra_scopes") |> elem(0)
      refresh_fieldset_pos = :binary.match(html, "OIDC refresh mode") |> elem(0)

      assert admin_scopes_pos < refresh_fieldset_pos,
             "admin_oidc_extra_scopes must appear before 'OIDC refresh mode' fieldset"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12-2 — Default values pre-filled
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12-2: scope fields pre-filled with correct defaults" do
    test "matrix_oidc_extra_scopes pre-filled with 'profile email'",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:get, "/admin/bootstrap?step=3")
        |> endpoint_call()

      assert conn.status == 200
      html = conn.resp_body

      # The default value "profile email" must appear as the input value.
      assert html =~ "profile email",
             "matrix_oidc_extra_scopes must be pre-filled with 'profile email'; got:\n#{html}"
    end

    test "admin_oidc_extra_scopes pre-filled with 'profile email groups'",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:get, "/admin/bootstrap?step=3")
        |> endpoint_call()

      assert conn.status == 200
      html = conn.resp_body

      assert html =~ "profile email groups",
             "admin_oidc_extra_scopes must be pre-filled with 'profile email groups'; got:\n#{html}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12-3 — Valid characters accepted
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12-3: valid scope characters accepted" do
    test "scope values with only [a-zA-Z0-9_:.-] characters are accepted",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email openid:offline",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      # Valid scopes → step 3 proceeds (redirect to OIDC login start).
      assert conn.status == 302,
             "Valid scope characters must be accepted; got status #{conn.status}"

      [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/admin/login/start")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12-4 — Invalid characters rejected with error
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12-4: invalid scope characters rejected with error message" do
    test "scope value with space-separated invalid token is rejected",
         %{store: store} do
      seed_step2_draft(store)

      # A scope containing a character outside [a-zA-Z0-9_:.-] e.g. "!" should fail.
      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email!",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      # Must re-render with 200 and an error message (not redirect).
      assert conn.status == 200,
             "Invalid scope characters must cause a 200 re-render (not redirect); got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i,
             "Error message about invalid scope characters expected; got:\n#{conn.resp_body}"
    end

    test "scope value with HTML injection characters is rejected",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile <script>",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      assert conn.status == 200
      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12-5 — Newlines in scope values rejected
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12-5: newlines in scope values are rejected" do
    test "matrix_oidc_extra_scopes with newline is rejected",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile\nemail",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      assert conn.status == 200,
             "Scope with newline must be rejected (200 re-render); got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i
    end

    test "admin_oidc_extra_scopes with newline is rejected",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email",
          "admin_oidc_extra_scopes" => "profile\nemail\ngroups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      assert conn.status == 200
      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i
    end

    test "scope with trailing newline is rejected (\\z anchor regression)",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email\n",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      assert conn.status == 200,
             "Trailing newline must be rejected (\\z required, not $); got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12-6 — Scope values persisted in draft after save
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12-6: valid scope values persisted in draft after step-3 POST" do
    test "matrix_oidc_extra_scopes persisted to draft on valid submission",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email groups",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      assert conn.status == 302

      draft = Agent.get(store, & &1.draft)

      assert draft["matrix_oidc_extra_scopes"] == "profile email groups",
             "matrix_oidc_extra_scopes must be persisted in draft; got: #{inspect(draft)}"
    end

    test "admin_oidc_extra_scopes persisted to draft on valid submission",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email",
          "admin_oidc_extra_scopes" => "profile email",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      assert conn.status == 302

      draft = Agent.get(store, & &1.draft)

      assert draft["admin_oidc_extra_scopes"] == "profile email",
             "admin_oidc_extra_scopes must be persisted in draft; got: #{inspect(draft)}"
    end

    test "scope values NOT persisted when validation fails",
         %{store: store} do
      seed_step2_draft(store)

      conn =
        build_conn(:post, "/admin/bootstrap/step/3")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email!invalid",
          "admin_oidc_extra_scopes" => "profile email groups",
          "matrix_oidc_refresh_mode" => "offline",
          "admin_oidc_refresh_mode" => "online"
        })
        |> endpoint_call()

      # Validation failed — no draft write.
      assert conn.status == 200

      draft = Agent.get(store, & &1.draft)

      refute Map.has_key?(draft, "matrix_oidc_extra_scopes"),
             "Invalid scope must NOT be persisted; got draft: #{inspect(draft)}"
    end
  end
end
