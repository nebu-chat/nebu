defmodule Nebu.Admin.Layouts do
  @moduledoc """
  Layouts for the LiveView Admin UI.

    * `:root` — the full HTML document wrapping the static render of every LiveView.
      Loads the Tailwind + DaisyUI stylesheet (/admin/static/assets/app.css, "nebu"
      Obsidian theme) and the Phoenix LiveView JS client.

    * `:live` — the shared admin chrome: a topbar + a left sidebar nav (Go-parity, see
      the former gateway/internal/admin/templates/base.html). The active item is
      highlighted from the `@active_nav` assign each LiveView sets in `mount/3`; the
      Bootstrap link is shown only while the instance is not yet bootstrapped
      (`@bootstrap_completed`, assigned by the `:require_admin` on_mount hook).
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="nebu">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>{assigns[:page_title] || "Nebu Admin"} · Nebu Admin</title>
        <link phx-track-static rel="stylesheet" href="/admin/static/assets/app.css" />
        <script defer type="text/javascript" src="/admin/static/assets/phoenix.min.js">
        </script>
        <script defer type="text/javascript" src="/admin/static/assets/phoenix_live_view.min.js">
        </script>
        <script defer phx-track-static type="text/javascript" src="/admin/static/assets/app.js">
        </script>
      </head>
      <body class="bg-base-100 text-base-content">
        <a href="#main-content" class="sr-only focus:not-sr-only">Skip to content</a>
        {@inner_content}
      </body>
    </html>
    """
  end

  # The shared admin shell: topbar + sidebar + content. Nav items mirror the Go admin.
  def live(assigns) do
    assigns =
      assigns
      |> assign_new(:active_nav, fn -> nil end)
      |> assign_new(:bootstrap_completed, fn -> true end)

    ~H"""
    <div class="min-h-screen flex flex-col">
      <header class="h-12 bg-base-300 flex items-center justify-between px-4 shrink-0" role="banner">
        <span class="font-semibold text-base-content">Nebu Admin</span>
      </header>

      <div class="flex flex-1 overflow-hidden">
        <nav
          aria-label="Admin navigation"
          class="w-60 bg-base-200 flex flex-col shrink-0 border-r border-base-300"
        >
          <ul role="list" class="flex flex-col gap-1 p-2 flex-1">
            <.nav_item :if={not @bootstrap_completed} navigate="/admin/bootstrap" key="bootstrap" active={@active_nav}>
              Bootstrap Setup
            </.nav_item>
            <.nav_item navigate="/admin/dashboard" key="dashboard" active={@active_nav}>Dashboard</.nav_item>
            <.nav_item navigate="/admin/compliance" key="compliance" active={@active_nav}>Compliance</.nav_item>
            <.nav_item navigate="/admin/users" key="users" active={@active_nav}>Users</.nav_item>
            <.nav_item navigate="/admin/rooms" key="rooms" active={@active_nav}>Rooms</.nav_item>
            <.nav_item navigate="/admin/spaces" key="spaces" active={@active_nav}>Spaces</.nav_item>
            <.nav_item navigate="/admin/config" key="config" active={@active_nav}>Configuration</.nav_item>
            <.nav_item navigate="/admin/config/role-mapping" key="role-mapping" active={@active_nav}>Role Mapping</.nav_item>
            <.nav_item navigate="/admin/config/claim-mapping" key="claim-mapping" active={@active_nav}>Claim Mapping</.nav_item>
          </ul>
          <div class="p-2 border-t border-base-300">
            <a
              href="/admin/logout"
              data-navkey="logout"
              class="flex items-center gap-2 px-3 py-3 rounded text-sm w-full font-medium text-base-content hover:bg-base-300 focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 focus:ring-offset-base-200"
            >
              Logout
            </a>
          </div>
        </nav>

        <main id="main-content" class="flex-1 overflow-auto p-6" role="main">
          {@inner_content}
        </main>
      </div>
    </div>
    """
  end

  # A single sidebar nav link. Highlights with the primary colour when active
  # (`key == active`), Go-parity classes + WCAG-AA focus ring.
  attr :navigate, :string, required: true
  attr :key, :string, required: true
  attr :active, :string, default: nil
  slot :inner_block, required: true

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@navigate}
        data-navkey={@key}
        aria-current={if @key == @active, do: "page"}
        class={[
          "flex items-center gap-2 px-3 py-3 rounded text-sm",
          "focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 focus:ring-offset-base-200",
          if(@key == @active,
            do: "bg-primary text-primary-content font-semibold",
            else: "font-medium text-base-content hover:bg-base-300"
          )
        ]}
      >
        {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end
end
