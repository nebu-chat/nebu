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

  # Sidebar IA (enhanced-logging/admin-sidebar-nesting + Trace Map "Leitstand"
  # design spec §1). Child keys are parent-namespaced (AC8); `role-mapping` /
  # `claim-mapping` keep their historical un-namespaced keys so pre-existing
  # E2E selectors like `[data-navkey="role-mapping"]` keep resolving (AC11).
  #
  # `/admin/logs/trace-map` is the real Leitstand page since
  # `trace-map-leitstand`; `/admin/logs/war-room` remains a stub route (it
  # renders the existing logs page) until `war-room-dedicated-page` lands.
  #
  # trace-map-leitstand AC14 (UX gate advisory A1, decided by Phil
  # 2026-07-07): the logs-config child is labeled "Log Retention" — NOT the
  # bare "Configuration", which duplicated the top-level Configuration
  # section's accessible name. The navkey `logs-config` and the
  # /admin/logs/config route are unchanged; only the label.
  @logs_nav_children [
    %{navigate: "/admin/logs", key: "logs-monitoring", label: "Live Stream"},
    %{navigate: "/admin/logs/trace-map", key: "logs-trace-map", label: "Trace Map"},
    %{navigate: "/admin/logs/war-room", key: "logs-war-room", label: "War Room"},
    %{navigate: "/admin/logs/config", key: "logs-config", label: "Log Retention"}
  ]

  # NOTE on ordering: the Leitstand spec (§1) lists "General" first, but the
  # keyboard-nav acceptance contract pins "Role Mapping" as the very next Tab
  # stop after the Configuration toggle (admin-sidebar-nesting.feature,
  # story Acceptance Test 8) and story AC5 enumerates exactly Role Mapping +
  # Claim Mapping as the children. "General" is APPENDED (not prepended) so
  # `/admin/config` stays reachable from the nav at all — the parent itself is
  # a pure disclosure toggle (<button>, AC9), no longer a link.
  @config_nav_children [
    %{navigate: "/admin/config/role-mapping", key: "role-mapping", label: "Role Mapping"},
    %{navigate: "/admin/config/claim-mapping", key: "claim-mapping", label: "Claim Mapping"},
    %{navigate: "/admin/config", key: "config-general", label: "General"}
  ]

  # The shared admin shell: topbar + sidebar + content. Nav items mirror the Go admin.
  # Works for both LiveView sockets (assign_new/3 with change tracking) and dead
  # controller renders (plain map — use Map.put_new/3 for compatibility).
  #
  # enhanced-logging/war-room-dedicated-page (amendment 4): `:war_room_active`/
  # `:war_room_started_at`/`:war_room_started_by` are new, safely-defaulted
  # assigns (mirrors the `:active_nav`/`:bootstrap_completed` precedent) —
  # every OTHER LiveView call site that does not set them gets `false`/`nil`,
  # i.e. no dot/pill at all, unaffected by this change. Sourced from
  # `Nebu.Admin.WarRoomManager.status/0`, polled by `Nebu.Admin.LogsLive`/
  # `Nebu.Admin.LogsLive.TraceMap`/`Nebu.Admin.LogsLive.WarRoom` the same 2s
  # interval way those modules already poll for their own war-room banners.
  def live(assigns) do
    assigns =
      if is_map_key(assigns, :__changed__) do
        assigns
        |> assign_new(:active_nav, fn -> nil end)
        |> assign_new(:bootstrap_completed, fn -> true end)
        |> assign_new(:war_room_active, fn -> false end)
        |> assign_new(:war_room_started_at, fn -> nil end)
        |> assign_new(:war_room_started_by, fn -> nil end)
      else
        assigns
        |> Map.put_new(:active_nav, nil)
        |> Map.put_new(:bootstrap_completed, true)
        |> Map.put_new(:war_room_active, false)
        |> Map.put_new(:war_room_started_at, nil)
        |> Map.put_new(:war_room_started_by, nil)
      end

    logs_children = war_room_dot_children(logs_nav_children(), assigns.war_room_active)

    assigns =
      if is_map_key(assigns, :__changed__) do
        assign(assigns, :logs_children, logs_children)
      else
        Map.put(assigns, :logs_children, logs_children)
      end

    ~H"""
    <div
      :if={is_map_key(assigns, :__changed__)}
      id="admin-session-keepalive"
      phx-hook="SessionKeepalive"
      class="hidden"
      aria-hidden="true"
    >
    </div>
    <div class="min-h-screen flex flex-col">
      <header class="h-12 bg-base-300 flex items-center justify-between px-4 shrink-0" role="banner">
        <span class="font-semibold text-base-content">Nebu Admin</span>
        <span
          :if={@war_room_active}
          data-testid="topbar-war-room-pill"
          id="topbar-war-room-pill"
          phx-hook="WarRoomPill"
          role="status"
          data-started-at={war_room_started_at_unix(@war_room_started_at)}
          class="pill--warroom inline-flex items-center gap-2 rounded-full border border-error bg-status-error-bg px-3 py-1 text-xs font-medium text-status-error-text"
        >
          <span class="tm-recdot" aria-hidden="true"></span>
          War Room recording
          <%!-- UX gate advisory 2: role="status" (implicit aria-atomic="true")
                so an operator elsewhere in the admin UI is notified when a
                session starts, matching the copy-toast's own pattern. The
                ticking mm:ss clock is aria-hidden — WITHOUT that, a status
                region would re-announce its entire content every second as
                the clock updates (the exact "ticking live region" anti-
                pattern `Nebu.Admin.LogsLive.TraceMap`'s own war-room banner
                deliberately avoids, per that module's own "UX gate V1" note:
                a per-second clock inside a live region re-announces the
                whole banner every second). The one-time "War Room recording"
                + started_by text still announces once when the pill mounts
                and again if `started_by` ever changes; the ticking number
                itself is decorative-only for screen-reader purposes, exactly
                like the Trace Map banner's own elapsed clock. --%>
          · <span data-testid="topbar-war-room-pill-clock" aria-hidden="true">{war_room_elapsed(@war_room_started_at)}</span>
          <span :if={@war_room_started_by} class="opacity-80">· {@war_room_started_by}</span>
        </span>
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
            <.nav_item :if={@bootstrap_completed} navigate="/admin/dashboard" key="dashboard" active={@active_nav}>Dashboard</.nav_item>
            <.nav_item :if={@bootstrap_completed} navigate="/admin/compliance" key="compliance" active={@active_nav}>Compliance</.nav_item>
            <.nav_item :if={@bootstrap_completed} key="logs" active={@active_nav} children={@logs_children}>Logs</.nav_item>
            <.nav_item :if={@bootstrap_completed} navigate="/admin/users" key="users" active={@active_nav}>Users</.nav_item>
            <.nav_item :if={@bootstrap_completed} navigate="/admin/rooms" key="rooms" active={@active_nav}>Rooms</.nav_item>
            <.nav_item :if={@bootstrap_completed} navigate="/admin/spaces" key="spaces" active={@active_nav}>Spaces</.nav_item>
            <.nav_item :if={@bootstrap_completed} key="config" active={@active_nav} children={config_nav_children()}>Configuration</.nav_item>
          </ul>
          <div :if={@bootstrap_completed} class="p-2 border-t border-base-300">
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

  defp logs_nav_children, do: @logs_nav_children
  defp config_nav_children, do: @config_nav_children

  # enhanced-logging/war-room-dedicated-page (amendment 4): additively marks
  # the "logs-war-room" child with `:dot` when a session is active — every
  # OTHER child renders unaffected (`nav_item/1`'s child clause only reads
  # `Map.get(child, :dot, false)`).
  defp war_room_dot_children(children, war_room_active) do
    Enum.map(children, fn child ->
      if child.key == "logs-war-room" do
        Map.put(child, :dot, war_room_active)
      else
        child
      end
    end)
  end

  defp war_room_started_at_unix(%DateTime{} = started_at), do: Integer.to_string(DateTime.to_unix(started_at))
  defp war_room_started_at_unix(_started_at), do: nil

  defp war_room_elapsed(%DateTime{} = started_at) do
    total = max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)
    minutes = div(total, 60)
    seconds = rem(total, 60)
    "#{String.pad_leading(Integer.to_string(minutes), 2, "0")}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"
  end

  defp war_room_elapsed(_started_at), do: "00:00"

  # A single sidebar nav entry, in one of two modes (admin-sidebar-nesting):
  #
  #   * LEAF (`children == []`, the default) — exactly the pre-nesting markup:
  #     a plain `<li><.link data-navkey=...>`. Zero behavior change for every
  #     existing call site that does not pass `:children` (AC2).
  #
  #   * PARENT (`children != []`) — an accessible disclosure group (AC9/AC10):
  #     a real `<button aria-expanded aria-controls>` toggle (with a chevron
  #     icon, AC13) followed by a nested, indented `<ul id="nav-{key}-children">`
  #     of child links. Children ALWAYS stay in the DOM; collapsing only adds
  #     the boolean `hidden` attribute. The child `<ul>` must NOT carry any
  #     display utility class (`flex`, `grid`, ...): an author-stylesheet
  #     `.flex { display: flex }` rule beats the UA's `[hidden] { display:
  #     none }` in the cascade and the collapsed state would not actually hide
  #     (the exact trace-map-hierarchy cycle-1 bug — do not reintroduce it).
  #
  # Highlight contract (AC3/AC4):
  #   * `key == active`            → primary highlight (leaf and parent alike)
  #   * a child's `key == active`  → the child gets primary + aria-current="page";
  #                                  the parent gets the SECONDARY `bg-base-300`
  #                                  accent (never `bg-primary`)
  #   * otherwise                  → neutral (hover accent only)
  #
  # The expand/collapse behavior is wired CSP-safely (`script-src 'self'`, no
  # inline JS) by `wireNavSectionToggles()` in priv/static/assets/app.js: a
  # single delegated click listener flips `aria-expanded` + `hidden` on the
  # native <button> — clicks, Space and Enter all fire `click` on a native
  # button, and the delegation works identically on dead controller renders
  # and LiveView pages. Sections default to EXPANDED (story Dev Notes Q3);
  # collapse state deliberately does not persist across navigations (Q1).
  #
  # `:navigate` is LEAF-ONLY (code-review MINOR-3): a parent renders as a pure
  # disclosure <button> that toggles and never navigates (AC9 + the keyboard
  # ATDD contract — Space must flip aria-expanded WITHOUT leaving the page),
  # so it has no use for a target. The attr is optional so parent call sites
  # don't pass a meaningless value; every LEAF call site must still pass it —
  # a leaf without `:navigate` would fall through to Phoenix.Component.link/1's
  # dead `href="#"` default.
  attr :navigate, :string, default: nil
  attr :key, :string, required: true
  attr :active, :string, default: nil
  attr :children, :list, default: []
  attr :expanded, :boolean, default: true
  slot :inner_block

  def nav_item(%{children: []} = assigns) do
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

  def nav_item(assigns) do
    highlight =
      cond do
        assigns.key == assigns.active -> "bg-primary text-primary-content font-semibold"
        Enum.any?(assigns.children, &(&1.key == assigns.active)) -> "bg-base-300 font-medium text-base-content"
        true -> "font-medium text-base-content hover:bg-base-300"
      end

    assigns = assign(assigns, :parent_highlight, highlight)

    ~H"""
    <li>
      <button
        type="button"
        data-navkey={@key}
        data-nav-toggle
        aria-expanded={to_string(@expanded)}
        aria-controls={"nav-#{@key}-children"}
        class={[
          "flex items-center gap-2 px-3 py-3 rounded text-sm w-full text-left",
          "focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 focus:ring-offset-base-200",
          @parent_highlight
        ]}
      >
        <svg
          data-testid="nav-toggle-icon"
          class={["h-4 w-4 shrink-0 transition-transform", @expanded && "rotate-90"]}
          viewBox="0 0 20 20"
          fill="currentColor"
          aria-hidden="true"
        >
          <path
            fill-rule="evenodd"
            d="M7.21 14.77a.75.75 0 01.02-1.06L11.168 10 7.23 6.29a.75.75 0 111.04-1.08l4.5 4.25a.75.75 0 010 1.08l-4.5 4.25a.75.75 0 01-1.06-.02z"
            clip-rule="evenodd"
          />
        </svg>
        {render_slot(@inner_block)}
      </button>
      <ul id={"nav-#{@key}-children"} role="list" class="ml-4 mt-1 space-y-1" hidden={not @expanded}>
        <li :for={child <- @children}>
          <.link
            navigate={child.navigate}
            data-navkey={child.key}
            aria-current={if child.key == @active, do: "page"}
            class={[
              "flex items-center gap-2 px-3 py-2 rounded text-sm",
              "focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 focus:ring-offset-base-200",
              if(child.key == @active,
                do: "bg-primary text-primary-content font-semibold",
                else: "font-medium text-base-content hover:bg-base-300"
              )
            ]}
          >
            {child.label}
            <span
              :if={Map.get(child, :dot, false)}
              data-testid="nav-war-room-dot"
              class="tm-recdot inline-block"
              aria-hidden="true"
            ></span>
            <%!-- UX gate (2026-07-08, BLOCKING VIOLATION): the dot above is
                  aria-hidden (a purely decorative pulse), so without this a
                  screen-reader user hears "War Room" regardless of whether a
                  session is recording — the topbar pill already states this
                  in visible text ("War Room recording · mm:ss"); this
                  sr-only span gives the sidebar item the same accessible-name
                  equivalent. --%>
            <span :if={Map.get(child, :dot, false)} data-testid="nav-war-room-dot-label" class="sr-only">
              (recording)
            </span>
          </.link>
        </li>
      </ul>
    </li>
    """
  end
end
