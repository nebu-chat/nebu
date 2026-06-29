defmodule Nebu.Admin.LoginBootstrapRedirectTest do
  @moduledoc """
  RED-phase regression tests for bug `bug-login-blocks-bootstrap`.

  ## The bug

  On a fresh (un-bootstrapped) Nebu installation, a user who lands on
  `/admin/login` sees only a "Login with SSO" button.  Clicking it starts
  the OIDC Authorization Code flow, which fails with 503 because no OIDC
  provider has been configured yet.  There is no link to `/admin/bootstrap`
  on the login page, so the operator is stuck.

  This happens because `LoginController.index/2` renders the login HTML
  unconditionally, without checking whether bootstrap has been completed.

  ## Expected behaviour (acceptance criteria)

  AC1 — Fresh install (bootstrap incomplete):
    `GET /admin/login` must redirect (302) to `/admin/bootstrap`, NOT render
    the login HTML.

  AC2 — Post-bootstrap (bootstrap complete):
    `GET /admin/login` must still render the login HTML (200) — no regression
    for the normal admin login flow.

  AC3 — Chain from `require_admin` on a fresh install:
    When an unauthenticated user visits any HTTP-controller-backed admin route
    (e.g. `/admin/users`) on a fresh install, `require_admin` redirects to
    `/admin/login`, which then redirects to `/admin/bootstrap`.  The net result
    must be a 302 to `/admin/bootstrap` (or a chain that ends there).

  ## Seams

  Uses the same `:admin_bootstrap_store` injectable seam as
  `Nebu.Admin.AuthBootstrapGateTest` and `admin_bootstrap_live_test.exs` to
  control `bootstrap_completed?/0` without a live Postgres connection.

  ## Crash/restart — NOT APPLICABLE

  `LoginController.index/2` is stateless (request-scoped, Persistenz Option C).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)

  # Install the same injectable bootstrap-state seam used by Auth and BootstrapLive.
  defp install_bootstrap_store(complete?) do
    store = start_supervised!({Agent, fn -> %{completed: complete?} end})

    dispatcher = fn
      :bootstrap_completed?, [] ->
        {:ok, Agent.get(store, & &1.completed)}
    end

    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    on_exit(fn -> Application.delete_env(:nebu_http, :admin_bootstrap_store) end)
    :ok
  end

  defp anon_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  # ── AC1 — fresh install: /admin/login redirects to /admin/bootstrap ───────────

  describe "AC1: fresh install (bootstrap incomplete)" do
    setup do: install_bootstrap_store(false)

    test "GET /admin/login redirects to /admin/bootstrap (302)" do
      conn = anon_conn(:get, "/admin/login") |> endpoint_call()

      assert conn.status == 302,
             "Expected 302 redirect from /admin/login to /admin/bootstrap on a fresh install; " <>
               "got #{conn.status}. The login page must not be shown before bootstrap completes."

      location = get_resp_header(conn, "location") |> List.first()

      assert location == "/admin/bootstrap",
             "Expected redirect target /admin/bootstrap; got #{inspect(location)}"
    end

    test "GET /admin/login does NOT render the SSO login HTML on a fresh install" do
      conn = anon_conn(:get, "/admin/login") |> endpoint_call()

      refute conn.resp_body =~ "Login with SSO",
             "The SSO login button must not appear on a fresh install — " <>
               "the user has no OIDC configured yet and cannot log in"
    end
  end

  # ── AC2 — post-bootstrap: /admin/login renders the login page ────────────────

  describe "AC2: post-bootstrap (bootstrap complete)" do
    setup do: install_bootstrap_store(true)

    test "GET /admin/login returns 200 with the SSO login HTML" do
      conn = anon_conn(:get, "/admin/login") |> endpoint_call()

      assert conn.status == 200,
             "After bootstrap is complete, /admin/login must render the login page; " <>
               "got #{conn.status}"

      assert conn.resp_body =~ "Login with SSO",
             "Login page must contain the SSO button after bootstrap is complete"
    end

    test "GET /admin/login does NOT redirect to /admin/bootstrap after bootstrap completes" do
      conn = anon_conn(:get, "/admin/login") |> endpoint_call()

      refute conn.status == 302 and
               get_resp_header(conn, "location") == ["/admin/bootstrap"],
             "After bootstrap, /admin/login must NOT redirect to /admin/bootstrap"
    end
  end

  # ── AC3 — require_admin chain on fresh install lands on /admin/bootstrap ──────

  describe "AC3: require_admin chain on a fresh install" do
    setup do: install_bootstrap_store(false)

    test "GET /admin/users (unauthenticated, fresh install) leads to /admin/bootstrap" do
      conn = anon_conn(:get, "/admin/users") |> endpoint_call()

      # require_admin redirects to /admin/login (302).
      # login page then redirects to /admin/bootstrap (302).
      # endpoint_call follows neither — we just need the final location to be
      # /admin/login (from require_admin), and THAT page must then redirect to
      # /admin/bootstrap (verified in AC1).
      #
      # In a real browser the chain is: /admin/users → /admin/login → /admin/bootstrap.
      # Here we assert the FIRST redirect goes to /admin/login (require_admin is not
      # changed), and AC1 guarantees /admin/login redirects onwards to /admin/bootstrap.
      assert conn.status == 302,
             "Unauthenticated GET /admin/users on fresh install must redirect; got #{conn.status}"

      location = get_resp_header(conn, "location") |> List.first()

      assert location == "/admin/login",
             "require_admin must redirect to /admin/login; got #{inspect(location)}"
    end
  end
end
