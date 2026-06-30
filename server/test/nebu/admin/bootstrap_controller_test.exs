defmodule Nebu.Admin.BootstrapControllerTest do
  @moduledoc """
  RED PHASE: Acceptance tests for the BootstrapLive → plain HTTP controller conversion.

  These tests FAIL against the current Phoenix LiveView implementation and will PASS
  once `BootstrapLive` is converted to a plain `BootstrapController` and the route is
  moved outside the `live_session :admin` gate.

  ## Three bugs being fixed

  **Bug 1 — Infinite redirect:**
  `GET /admin/bootstrap` lives in `live_session :admin` with
  `on_mount: {Nebu.Admin.Auth, :require_admin}`. Before bootstrap is complete, this
  on_mount hook redirects unauthenticated requests to `/admin/login`, which in turn
  redirects back to `/admin/bootstrap` (because bootstrap is not complete) — infinite
  loop. Fix: move the route outside the `:admin` live_session and out of the
  `require_admin` gate.

  **Bug 2 — Form fields clearing:**
  LiveView WebSocket/longpoll reconnection remounts the LiveView, resetting socket
  assigns and clearing the operator's in-progress form inputs. Plain HTML POST forms
  with server-side redirects are not affected. Fix: convert to a plain HTTP controller.

  **Bug 3 — JWKS URI field still present:**
  Step 2 exposes a "JWKS URI" input that operators must fill manually. The OIDC
  well-known endpoint already provides this value. Fix: auto-discover the JWKS URI
  server-side from `{issuer}/.well-known/openid-configuration` and remove the field.

  ## Test strategy

  Both tests drive the REAL `Nebu.Web.Router` (the production entry point) via
  `Plug.Test` — the same pattern as `BootstrapConfirmHttpTest`. The injectable
  `:admin_bootstrap_store` seam is installed so no live Postgres is needed.

  The CSRF bypass (`:admin_csrf_bypass` env) is enabled for POST tests — the
  existing CSRF security for the confirm-claim path is unaffected and tested
  separately in `BootstrapConfirmHttpTest`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @secret_key_base String.duplicate("nebu-bootstrap-ctrl-test-secret!", 2)

  setup do
    # In-memory draft store — same seam as other bootstrap tests (ADR-018).
    store = start_supervised!({Agent, fn -> %{draft: %{}, config: %{}} end})

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
    Application.put_env(:nebu_http, :admin_secret_at_rest, "bootstrap-ctrl-test-key")
    # Allow POST forms to bypass CSRF in tests — only for the bootstrap steps
    # (NOT the select-claim path; that is tested with real CSRF in BootstrapConfirmHttpTest).
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    on_exit(fn ->
      for k <- [:admin_bootstrap_store, :admin_secret_at_rest, :admin_csrf_bypass] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    {:ok, store: store}
  end

  # ── helper ──────────────────────────────────────────────────────────────────

  defp router_call(method, path, body \\ nil, headers \\ []) do
    base = if body, do: conn(method, path, body), else: conn(method, path)
    conn = %{base | secret_key_base: @secret_key_base}

    conn =
      Enum.reduce(headers, conn, fn
        {_k, nil}, c -> c
        {k, v}, c -> put_req_header(c, k, v)
      end)

    Nebu.Web.Router.call(conn, Nebu.Web.Router.init([]))
  end

  # ── Bug 1 — GET /admin/bootstrap accessible without authentication ────────────

  # RED PHASE: fails against current LiveView implementation.
  #
  # Current behaviour: `GET /admin/bootstrap` is in `live_session :admin` with
  # `on_mount: {Nebu.Admin.Auth, :require_admin}`. Without an admin session,
  # Phoenix's LiveView transport redirects to `/admin/login`. The login controller
  # then redirects back to `/admin/bootstrap` because bootstrap is not complete →
  # infinite redirect loop. With `Plug.Test` the loop is cut after one redirect
  # (302 to /admin/login), so the assertion below sees a 302, not 200.
  #
  # Expected behaviour after fix: `GET /admin/bootstrap` is a plain HTTP controller
  # action outside the `:admin` gate. It returns 200 to any request when bootstrap
  # is not yet complete (bootstrap requires no prior authentication by design).
  test "GET /admin/bootstrap returns 200 without an admin session when bootstrap is not complete" do
    # Ensure bootstrap is NOT complete (default store state).
    conn = router_call(:get, "/admin/bootstrap")

    assert conn.status == 200,
           "Expected 200 from GET /admin/bootstrap (unauthenticated, bootstrap not complete). " <>
             "Got #{conn.status}. Current code redirects to /admin/login (live_session :admin gate). " <>
             "Fix: move the route outside live_session :admin."

    # The response body must be HTML containing the wizard heading.
    assert conn.resp_body =~ "Bootstrap Setup",
           "Response body must contain 'Bootstrap Setup' heading."

    # Must NOT have a LiveView transport marker — the page is now plain HTML.
    refute conn.resp_body =~ "phx-main",
           "Response must not contain LiveView markers after the controller conversion."
  end

  # ── Bug 3 — POST /admin/bootstrap/step/2 must NOT require a JWKS URI field ────

  # RED PHASE: fails against current LiveView implementation.
  #
  # Current behaviour: the bootstrap wizard is a LiveView; there is no
  # `POST /admin/bootstrap/step/2` route. The router raises a `NoRouteError`
  # (404) for this path. Even if the route existed, step 2 in the current
  # LiveView (`save_oidc/2`) validates that `oidc_jwks_uri` is non-blank and
  # returns an error when it is missing — the JWKS URI field is required.
  #
  # Expected behaviour after fix:
  #   1. `POST /admin/bootstrap/step/2` is a real route handled by BootstrapController.
  #   2. The controller auto-discovers the JWKS URI from
  #      `{issuer}/.well-known/openid-configuration` so operators do not provide it.
  #   3. A POST with issuer/client_id/client_secret/audience but WITHOUT a jwks_uri
  #      field succeeds (303 redirect to step 3), not an error.
  test "POST /admin/bootstrap/step/2 succeeds without a jwks_uri parameter (JWKS auto-discovered)" do
    # Install the OidcMetadata override seam so JWKS discovery succeeds without a
    # live IdP. The override returns a minimal well-known document with jwks_uri set.
    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => "https://idp.example.com",
      "jwks_uri" => "https://idp.example.com/.well-known/jwks.json",
      "authorization_endpoint" => "https://idp.example.com/auth",
      "token_endpoint" => "https://idp.example.com/token"
    })

    on_exit(fn -> Application.delete_env(:nebu_http, :oidc_metadata_override) end)

    # Seed step-1 draft so the wizard resumes at step 2.
    Application.put_env(:nebu_http, :admin_bootstrap_store,
      fn
        :load_draft, [] -> {:ok, %{"instance_name" => "test-nebu"}}
        :put_draft, [_k, _v] -> :ok
        :clear_draft, [] -> :ok
        :put_config, [_k, _v] -> :ok
        :bootstrap_completed?, [] -> {:ok, false}
      end
    )

    body =
      URI.encode_query(%{
        "oidc_issuer" => "https://idp.example.com",
        "oidc_client_id" => "nebu-admin",
        "oidc_client_secret" => "super-secret",
        "oidc_audience" => "nebu-admin"
        # NOTE: no "oidc_jwks_uri" field — must succeed after fix
      })

    conn =
      router_call(:post, "/admin/bootstrap/step/2", body, [
        {"content-type", "application/x-www-form-urlencoded"}
      ])

    # After the fix: 303 redirect to step 3 (or to /admin/bootstrap?step=3).
    # Before the fix: 404 NoRouteError (route does not exist) OR 200 with an
    # error message because `oidc_jwks_uri` is blank.
    assert conn.status in [302, 303],
           "Expected a redirect (302/303) from POST /admin/bootstrap/step/2 without a " <>
             "jwks_uri field. Got #{conn.status}. " <>
             "Fix: remove the JWKS URI field; auto-discover it server-side from the well-known endpoint."

    # Must NOT show a JWKS URI error in the body (only relevant if status is 200).
    refute conn.resp_body =~ ~r/jwks uri.*required/i,
           "Response must not demand a JWKS URI — it should be auto-discovered."
  end
end
