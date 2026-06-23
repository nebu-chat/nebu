defmodule Nebu.Admin.LoginController do
  @moduledoc """
  Minimal admin login page controller (admin-ui-migration, AC3).

  `/admin/login` renders an SSO login page (the AC3 redirect target for non-admins).
  `/admin` redirects to `/admin/rooms`.

  The full OIDC Authorization-Code + PKCE login is owned by `Nebu.Admin.Auth`
  (go-removal-cleanup — re-implemented in Elixir after the Go gateway was deleted):

    * `GET /admin/login/start` → `Admin.Auth.login_start/2` (PKCE+state+nonce → IdP)
    * `GET /admin/callback`    → `Admin.Auth.callback/2` (exchange + verify + session mint)
    * `GET /admin/logout`      → `Admin.Auth.logout/2` (clears the session)

  This controller provides the landing page and delegates the auth legs to `Admin.Auth`.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def root_redirect(conn, _params) do
    # Land on the Dashboard; the LiveView on_mount bootstrap gate redirects to
    # /admin/bootstrap if the instance is not yet bootstrapped.
    conn
    |> redirect(to: "/admin/dashboard")
    |> halt()
  end

  @doc """
  GET /admin/login/start — begins the OIDC Authorization-Code + PKCE login.

  Delegates to `Nebu.Admin.Auth.login_start/2`, which generates the PKCE
  verifier/challenge + state + nonce, stashes them in the signed Phoenix session, and
  302-redirects to the provider's authorization endpoint. (Previously this 302'd back to
  the Go gateway, which no longer exists — that produced an infinite redirect loop.)
  """
  def start(conn, params) do
    Nebu.Admin.Auth.login_start(conn, params)
  end

  @doc """
  GET /admin/callback — completes the OIDC login (token exchange + verify + session mint).
  """
  def callback(conn, params) do
    Nebu.Admin.Auth.callback(conn, params)
  end

  @doc """
  GET /admin/logout — clears the admin session.
  """
  def logout(conn, params) do
    Nebu.Admin.Auth.logout(conn, params)
  end

  @doc """
  GET /admin/bootstrap/select-claim — bootstrap-mode claim-selection landing.

  Delegates to `Nebu.Admin.Auth.select_claim_page/2`. The page is normally rendered
  inline by the bootstrap-mode OIDC callback; a direct GET bounces back into the wizard
  (or to /admin/login once bootstrap is complete — AC5).
  """
  def select_claim(conn, params) do
    Nebu.Admin.Auth.select_claim_page(conn, params)
  end

  @doc """
  POST /admin/bootstrap/select-claim — completes bootstrap with the chosen admin group
  claim (Go parity: ClaimSelectionHandler). Delegates to
  `Nebu.Admin.Auth.bootstrap_confirm_claim/2`.
  """
  def confirm_claim(conn, params) do
    Nebu.Admin.Auth.bootstrap_confirm_claim(conn, params)
  end

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, login_html())
  end

  defp login_html do
    """
    <!DOCTYPE html>
    <html lang="en" data-theme="nebu">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Sign in · Nebu Admin</title>
        <link rel="stylesheet" href="/admin/static/assets/app.css" />
      </head>
      <body class="bg-base-100 text-base-content">
        <main role="main" class="min-h-screen flex items-center justify-center p-6">
          <div class="card bg-base-200 shadow p-8 max-w-sm w-full">
            <h1 class="text-xl font-bold mb-4">Nebu Admin</h1>
            <p class="mb-4 text-base-content/70">Sign in to manage this instance.</p>
            <a href="/admin/login/start" class="btn btn-primary w-full" role="button">
              Login with SSO
            </a>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
