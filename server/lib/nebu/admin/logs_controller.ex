defmodule Nebu.Admin.LogsController do
  @moduledoc """
  HTTP controller for the Admin Logs Retention Settings page
  (enhanced-logging/admin-logs-retention-settings).

  `GET /admin/logs/config` renders the configuration form; `POST
  /admin/logs/config/retention` validates + persists it. Deliberately a
  plain Phoenix Controller, NOT a LiveView (AC13, literal) — follows
  `Nebu.Admin.ConfigController`'s exact pattern (plug-based
  `:require_admin`, `render_config/1`-style helper). Story admin-forms-gate-sweep: the POST is
  behind `click_gate/2` (strict fetch metadata) and saves value and audit row `log_settings_changed` in one transaction (`save_config_audited/3`; test-build seam via
  `Nebu.Admin.DB`).

  See:
  `_bmad-output/nebu/epics/enhanced-logging/step-results/admin-logs-retention-settings/design-decisions.md`
  for the full rationale behind every naming/architecture choice below —
  most importantly, the REAL `server_config` keys used
  (`log_collect_info`/`log_retention_info_days`/`log_retention_info_max_count`/
  `log_collect_debug`/`log_retention_debug_days`/`log_retention_debug_max_count`)
  are NOT the story's own placeholder DB-key guesses (`info_enabled` etc.) —
  those remain only the HTML *form field* names (AC13's example JSON),
  mapped to the real keys here.

  ## Client-side interactivity lives in app.js, not here

  AC7 (click-to-toggle a bubble reveals/hides retention fields), AC8
  (pre-fill defaults live, before any submit), AC11 (DEBUG warning
  show/hide live) are implemented ENTIRELY in
  `priv/static/assets/app.js`'s `wireLogsConfigToggles()` — there is no
  LiveView socket on this page, so `phx-click` on the reused
  `Nebu.Admin.LogsLive.TraceMapBubble` component is inert here; it is only
  reused for its visual styling (color/shape via `mode={:configure}`). The
  actual round-trip is a REAL native form submit.

  ## Blank/zero ALWAYS means "no limit" — unconditionally (AC9/AC10)

  `AC9`/`AC10` are explicit and unconditional: a blank or "0" retention
  field always means "no limit for that dimension" server-side, with no
  exception. The 7-day/1000-entry "sensible defaults" mentioned in AC8 are
  applied ENTIRELY client-side (`priv/static/assets/app.js`'s
  `wireLogsConfigToggles()`, per design-decisions.md #2/#4c) — the moment a
  level is toggled ON in the browser, the retention `<input>` fields are
  pre-filled with the literal strings "7"/"1000" (editable — the operator
  can change or clear them). A REAL submission therefore never actually
  sends blank fields for a freshly-enabled level unless the operator
  deliberately clears them, in which case "no limit" (this controller's
  literal, unconditional behavior) is exactly correct. There is
  deliberately NO server-side "was this level previously configured"
  fallback/discriminator here — an earlier attempt at one (keyed off
  `log_collect_<level>`'s mere presence in `server_config`) was removed: it
  is unreliable in practice because `server_config` has no DELETE policy
  (by design — no production code path ever deletes a config row), so
  "was previously configured" trends toward permanently `true` after the
  very first write of a session/test run, making such a discriminator
  order-dependent rather than a genuine one-time "first enable" signal.
  """
  # NOTE: NOT the bare `formats: [:html]` convention every other controller in
  # this codebase uses (which would derive the view module as `LogsHTML`) —
  # design-decisions.md #5b explicitly names the view module
  # `Nebu.Admin.LogsConfigHTML` to avoid ambiguity with the sibling
  # `Nebu.Admin.LogsLive` monitoring-page module. `{:html, "ConfigHTML"}`
  # tells `Phoenix.Controller.__plugs__/2` to derive
  # `#{base}ConfigHTML` (base = controller module with "Controller"
  # stripped, i.e. `Nebu.Admin.Logs`) instead of the default `#{base}HTML`.
  use Phoenix.Controller, formats: [html: "ConfigHTML"]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  # story admin-forms-gate-sweep: the strict fetch metadata of a user-clicked form submit (Safari: the click proof) before anything is read or changed
  import Nebu.Admin.OAuthAdminHelpers, only: [click_gate: 2]
  plug :click_gate when action in [:save_retention]

  @days_bounds {1, 90}
  @max_entries_bounds {1, 10_000}
  @default_days 7
  @default_max_entries 1000

  def index(conn, _params) do
    render_config(conn, load_state_from_db())
  end

  def save_retention(conn, params) do
    case validate_and_normalize(params) do
      {:ok, changes} ->
        case persist(conn, changes) do
          {:ok, :audited} ->
            conn
            |> put_flash(:info, "Logging settings saved")
            |> redirect(to: "/admin/logs/config")

          {:ok, :unaudited} ->
            conn
            |> put_flash(:error, Nebu.Admin.OAuthAdminHelpers.unaudited_flash("Logging settings"))
            |> redirect(to: "/admin/logs/config")

          {:error, :audit} ->
            conn
            |> put_flash(:error, Nebu.Admin.OAuthAdminHelpers.audit_refused_flash("Logging settings"))
            |> redirect(to: "/admin/logs/config")

          {:error, :db} ->
            conn
            |> put_flash(:error, "Failed to save logging settings")
            |> redirect(to: "/admin/logs/config")
        end

      {:error, message} ->
        conn
        |> put_status(200)
        |> put_flash(:error, message)
        |> render_config(state_from_params(params))
    end
  end

  # ── validation (AC10) ───────────────────────────────────────────────────────

  defp validate_and_normalize(params) do
    with {:ok, info_changes} <- validate_level(params, "info"),
         {:ok, debug_changes} <- validate_level(params, "debug") do
      {:ok, Map.merge(info_changes, debug_changes)}
    end
  end

  defp validate_level(params, level) do
    enabled = params["#{level}_enabled"] == "true"

    {min_days, max_days} = @days_bounds
    {min_entries, max_entries_bound} = @max_entries_bounds

    with {:ok, days} <-
           validate_bound(
             params["#{level}_days"],
             min_days,
             max_days,
             "Retention days must be between 1 and 90, or left blank"
           ),
         {:ok, max_entries} <-
           validate_bound(
             params["#{level}_max_entries"],
             min_entries,
             max_entries_bound,
             "Max entries must be between 1 and 10000, or left blank"
           ) do
      max_key =
        if level == "info",
          do: "log_retention_info_max_count",
          else: "log_retention_debug_max_count"

      # code-review MAJOR fix: when a level is submitted as DISABLED, its
      # retention `<input>`s were never rendered in the form at all (the
      # template only shows them `:if={@state.<level>_enabled}`), so
      # `params["<level>_days"]`/`params["<level>_max_entries"]` are simply
      # absent (nil) — NOT the operator explicitly clearing them. Only
      # persist the retention-window keys when the level is actually
      # ENABLED in this submission; a disabled level's previously-stored
      # retention window must survive unrelated saves (e.g. toggling ONLY
      # the other level). Without this guard, saving the form while DEBUG
      # happened to be off silently reset DEBUG's stored days/max-count to
      # "no limit" every single time, even though the operator never
      # touched DEBUG's settings — a real data-loss bug, not merely
      # cosmetic (a previously-tuned retention window vanishes the next
      # time the level is re-enabled).
      base = %{"log_collect_#{level}" => to_string(enabled)}

      changes =
        if enabled do
          base
          |> Map.put("log_retention_#{level}_days", finalize(days))
          |> Map.put(max_key, finalize(max_entries))
        else
          base
        end

      {:ok, changes}
    end
  end

  defp validate_bound(raw, min, max, error_message) do
    trimmed = String.trim(raw || "")

    if trimmed == "" do
      {:ok, :blank}
    else
      case Integer.parse(trimmed) do
        {0, ""} -> {:ok, :blank}
        {n, ""} when n >= min and n <= max -> {:ok, n}
        _ -> {:error, error_message}
      end
    end
  end

  # AC9/AC10: blank or "0" ALWAYS means "no limit" (""), unconditionally —
  # never the literal string "0" (test-review MAJOR-1: `prune_ttl/2` and
  # `prune_max_count/2` only short-circuit on `nil`; a stored "0" would be
  # parsed back to the integer 0 and prune EVERYTHING on the next sweep).
  defp finalize(:blank), do: ""
  defp finalize(n) when is_integer(n), do: to_string(n)

  # ── state loading (GET / error re-render) ───────────────────────────────────

  defp load_state_from_db do
    {:ok, policy} = Nebu.Web.LogStore.get_policy()

    info_enabled = policy.log_collect_info == true
    debug_enabled = policy.log_collect_debug == true

    %{
      info_enabled: info_enabled,
      info_days: display_value(info_enabled, policy.log_retention_info_days, @default_days),
      info_max_entries:
        display_value(info_enabled, policy.log_retention_info_max_count, @default_max_entries),
      debug_enabled: debug_enabled,
      debug_days: display_value(debug_enabled, policy.log_retention_debug_days, @default_days),
      debug_max_entries:
        display_value(debug_enabled, policy.log_retention_debug_max_count, @default_max_entries)
    }
  end

  # When a level is enabled but no explicit retention value has ever been
  # stored (nil), DISPLAY the sensible default (AC8/AC16) rather than a
  # blank field — a pure display fallback, not itself persisted until the
  # operator actually submits the form.
  defp display_value(_enabled, value, _default) when is_integer(value), do: to_string(value)
  defp display_value(true, nil, default), do: to_string(default)
  defp display_value(false, nil, _default), do: ""

  # AC15: on a validation error, echo the operator's submitted values back
  # verbatim (never silently clear them), regardless of bounds/blankness.
  defp state_from_params(params) do
    %{
      info_enabled: params["info_enabled"] == "true",
      info_days: params["info_days"] || "",
      info_max_entries: params["info_max_entries"] || "",
      debug_enabled: params["debug_enabled"] == "true",
      debug_days: params["debug_days"] || "",
      debug_max_entries: params["debug_max_entries"] || ""
    }
  end

  # ── persistence (story admin-forms-gate-sweep D5) ───────────────────────────
  #
  # Value and audit row `log_settings_changed` in ONE transaction (`OAuthAdminHelpers.save_config_audited/3`). Shorter retention deletes INFO / DEBUG rows and DEBUG
  # collects more personal data, so the row is mandatory; the only change applied without it is a pure "collection off" one (every changed key is a `log_collect_*`
  # key set to `false`: less collection, the way back).
  defp persist(conn, changes) do
    way_back? = fn stored ->
      Enum.all?(changes, fn {key, value} -> (String.starts_with?(key, "log_collect_") and value == "false") or value == stored[key] end)
    end

    # a database that fails here must not become a 500: an unreadable stored state is the empty one (only a pure "collection off" change then passes unaudited)
    stored =
      try do
        case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
          {:ok, cfg} -> cfg
          _ -> %{}
        end
      rescue
        _ -> %{}
      end

    Nebu.Admin.OAuthAdminHelpers.save_config_audited(conn, changes,
      action: "log_settings_changed",
      target_id: "log_settings",
      metadata: changes,
      label: "log retention",
      form: :logs_retention,
      unaudited_ok: way_back?.(stored),
      narrowing: way_back?
    )
  end

  # ── rendering ────────────────────────────────────────────────────────────────

  defp render_config(conn, state) do
    conn
    |> assign(:state, state)
    |> assign(:page_title, "Logs Configuration")
    # admin-sidebar-nesting coordination contract (story Dev Notes item 5):
    # highlight the "Configuration" CHILD of the nested "Logs" nav section.
    |> assign(:active_nav, "logs-config")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end
end
