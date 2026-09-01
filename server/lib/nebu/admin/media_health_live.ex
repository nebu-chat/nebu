defmodule Nebu.Admin.MediaHealthLive do
  @moduledoc """
  Scan Health & Alerts Dashboard — `/admin/media/health`
  (media-security-admin-control/10a-scan-stats-rollup).

  Story: docs/stories/media-security-admin-control/10a-scan-stats-rollup.md

  This story's own slice renders exactly one section — the rollup metrics
  computed from `media_scan_stats` (ADR-018: inline SQL, no Ecto schema; the
  epic's own explicit requirement for this story: "liest die Rollup-Tabelle
  (kein Live-Query über die volle Historie)" — this module NEVER queries
  `media_state_transitions` directly). Story 10b (ClamAV status) and Story
  10c (`media_alerts`) attach further sections to this same module later —
  see the story's own Summary for why this is a LiveView (not a plain
  controller+template) from the start, even though this story's own content
  needs no `PubSub`/`handle_info/2`.

  `mount/3` runs three inline-SQL reads once (no `handle_params/3` — this
  route takes no query/path params): the latest row (current-hour
  throughput/duration/backlog), the rolling-24-row aggregate, and the
  rolling-168-row aggregate. AC7: when the latest-row query returns no rows,
  `@empty?` is `true` and the template renders the empty-state copy instead
  of attempting any arithmetic on absent values.

  ## ClamAV status + signature age (media-security-admin-control/10b-clamav-status-freshclam-age)

  A second section on this same page (AC5), sourced entirely via the shared
  `Nebu.Admin.ClamAVStatusIndicator` helper (`status/0` + `assign_status/2`
  in `mount/3`, `schedule/0` + `handle_info/2` for the periodic poll tick —
  AC6, mirroring `Nebu.Admin.WarRoomIndicator`'s wiring precedent on every
  other admin LiveView).

  ## Open alerts (media-security-admin-control/10c-media-alerts-triggers)

  A third section, rendered ABOVE the 10a/10b sections above (AC4): every
  unresolved `media_alerts` row, sourced via `Nebu.Media.Alerts.list_open/0`
  (this module never queries `media_alerts` directly — same "one seam"
  precedent `Nebu.Media.Config.get/0` established). Additive to — not a
  replacement for — the Story 5b/7 nav attention-badges (individual
  `:infected`/`scan_failed` files, a different concern from this story's
  pipeline-level operational alerts).

  The section headings for the 10a metrics sub-sections below are rendered
  unconditionally (only their VALUE elements are gated on `@empty?`) so this
  new alerts section's "renders above the metrics sections" ordering
  assertion (AT10) holds regardless of whether `media_scan_stats` happens to
  be empty at the time of a given page load.
  """

  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  alias Nebu.Repo
  alias Nebu.Admin.ClamAVStatusIndicator
  alias Nebu.Admin.WarRoomManager
  alias Nebu.Media.Alerts

  @sql_latest_row """
  SELECT window_start, scans_total, avg_scan_duration_ms, p95_scan_duration_ms, backlog_depth
    FROM media_scan_stats
   ORDER BY window_start DESC
   LIMIT 1
  """

  @sql_rolling_sums """
  SELECT COALESCE(SUM(scans_total), 0), COALESCE(SUM(scans_failed), 0)
    FROM (
      SELECT scans_total, scans_failed
        FROM media_scan_stats
       ORDER BY window_start DESC
       LIMIT $1
    ) recent
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    latest = fetch_latest_row()
    rolling_24h = fetch_rolling_sums(24)
    rolling_7d = fetch_rolling_sums(168)

    if connected?(socket), do: ClamAVStatusIndicator.schedule()

    {:ok,
     socket
     |> assign(:active_nav, "media-health")
     |> assign(:page_title, "Medien – Health")
     |> assign(:empty?, is_nil(latest))
     |> assign(:latest, latest)
     |> assign(:rolling_24h, rolling_24h)
     |> assign(:rolling_7d, rolling_7d)
     |> assign(:open_alerts, Alerts.list_open())
     # media-security-admin-control/10e-trace-map-war-room-integration
     # (AC8/AC9): the acting admin's identity for start_session/1's
     # started_by, and the conflict-message assign this layout's own
     # convention requires (Nebu.Admin.Layouts does not render Phoenix's
     # built-in @flash — see Nebu.Admin.MediaLive's own @action_flash for
     # the established precedent this mirrors).
     |> assign(:current_admin_id, actor_id(socket.assigns.current_user))
     |> assign(:diagnosis_error, nil)
     |> ClamAVStatusIndicator.assign_status(ClamAVStatusIndicator.status())}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh_clamav_status, socket) do
    ClamAVStatusIndicator.schedule()
    {:noreply, ClamAVStatusIndicator.assign_status(socket, ClamAVStatusIndicator.status())}
  end

  # media-security-admin-control/10e-trace-map-war-room-integration (AC8):
  # "Live-Diagnose starten" — scopes a new War Room session to the media
  # domain (AC7's list-shaped scope) and jumps straight to the existing,
  # already-shipped bookmarkable /admin/logs?war_room_id=... pattern
  # (enhanced-logging/war-room-mode AC12) — reused verbatim, not a new page.
  # max_entries/max_duration_s below are this story's own illustrative
  # starting form values (1,000/900s) — WarRoomManager's existing
  # 10..10_000/10..3_600s bounds apply unchanged and are never widened here.
  @impl Phoenix.LiveView
  def handle_event("start_media_diagnosis", %{"reason" => reason}, socket) do
    case WarRoomManager.start_session(%{
           started_by: socket.assigns.current_admin_id,
           reason: reason,
           scope: ["/media/clamav", "/media/scan_worker", "/admin/media"],
           max_entries: 1_000,
           max_duration_s: 900
         }) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: "/admin/logs?war_room_id=#{session.id}")}

      {:error, :conflict, message} ->
        {:noreply, assign(socket, :diagnosis_error, message)}

      {:error, :invalid_params, message} ->
        {:noreply, assign(socket, :diagnosis_error, message)}
    end
  end

  # Mirrors Nebu.Admin.MediaLive's own actor_id/1 convention exactly
  # (matrix_user_id, falling back to sub — always a Matrix-ID string, never
  # a UUID).
  defp actor_id(current_user) do
    case current_user do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> nil
    end
  end

  defp fetch_latest_row do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query!(Repo, @sql_latest_row, []) do
        %{rows: [[window_start, scans_total, avg_ms, p95_ms, backlog_depth]]} ->
          %{
            window_start: window_start,
            scans_total: scans_total,
            avg_scan_duration_ms: avg_ms,
            p95_scan_duration_ms: p95_ms,
            backlog_depth: backlog_depth
          }

        %{rows: []} ->
          nil
      end
    else
      nil
    end
  end

  defp fetch_rolling_sums(limit) do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query!(Repo, @sql_rolling_sums, [limit]) do
        %{rows: [[total_sum, failed_sum]]} ->
          %{
            scans_total_sum: total_sum,
            scans_failed_sum: failed_sum,
            error_rate_pct: error_rate_pct(failed_sum, total_sum)
          }
      end
    else
      %{scans_total_sum: 0, scans_failed_sum: 0, error_rate_pct: nil}
    end
  end

  # AC7: never a literal NaN/Infinity from an unguarded division — nil (not
  # 0.0) when the denominator is 0, so the template can render the empty-data
  # dash rather than a misleading "0.0%".
  defp error_rate_pct(_failed_sum, 0), do: nil
  defp error_rate_pct(failed_sum, total_sum), do: failed_sum / total_sum * 100

  defp format_pct(nil), do: "—"
  defp format_pct(pct), do: "#{Float.round(pct, 1)}%"

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when is_integer(ms), do: "#{ms} ms"

  defp format_count(nil), do: "—"
  defp format_count(n) when is_integer(n), do: Integer.to_string(n)

  # ── 10b: ClamAV status + signature age helpers ──────────────────────────

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp signature_age_copy({:ok, built_at}, true) do
    "Signaturen veraltet (vor #{humanize_age(built_at)} aktualisiert)"
  end

  defp signature_age_copy({:ok, built_at}, false) do
    "Signaturen aktuell (vor #{humanize_age(built_at)} aktualisiert)"
  end

  defp signature_age_copy(:unknown, _stale?), do: "Alter unbekannt"

  defp humanize_age(built_at) do
    hours = DateTime.diff(DateTime.utc_now(), built_at, :second) |> div(3600)
    "#{hours}h"
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Medien – Health</h1>

    <%!-- media-security-admin-control/10c-media-alerts-triggers (AC4): open
          alerts render above the 10a/10b metrics sections below, critical
          before warning, most-recently-opened first within each severity —
          Nebu.Media.Alerts.list_open/0 already returns rows in that order,
          this template just renders them as-is. Additive to (not a
          replacement for) the Story 5b/7 nav attention-badges. --%>
    <section
      :if={@open_alerts != []}
      aria-labelledby="media-alerts-heading"
      class="p-4 rounded border border-base-300 mb-6"
    >
      <h2 id="media-alerts-heading" class="text-body font-semibold mb-2">Offene Alerts</h2>

      <%!-- media-security-admin-control/10e-trace-map-war-room-integration
            (AC8): the conflict message from a rejected start_session/1 call
            — this layout does not render Phoenix's built-in @flash (see
            Nebu.Admin.MediaLive's own @action_flash precedent), so this is a
            dedicated assign rendered directly here instead. --%>
      <p
        :if={@diagnosis_error}
        data-testid="media-diagnosis-error"
        class="alert alert-error mb-2"
        role="alert"
      >
        {@diagnosis_error}
      </p>

      <ul class="space-y-2">
        <li
          :for={alert <- @open_alerts}
          data-testid={"media-alert-row-#{alert.id}"}
          class={["alert", if(alert.severity == "critical", do: "alert-error", else: "alert-warning")]}
          role={if alert.severity == "critical", do: "alert", else: "status"}
        >
          <div>
            <span class="font-semibold">
              {if alert.severity == "critical", do: "Kritisch:", else: "Warnung:"}
            </span>
            {alert.message}

            <%!-- AC9: a text hint, independent of severity, whenever the
                  triggering alert names a specific file — NOT a new filter
                  mechanism; LogsLive's existing per-request grouping already
                  does the work once the operator is inside the session. --%>
            <span
              :if={alert.media_id}
              data-testid="media-alert-media-id-hint"
              class="block text-caption text-text-secondary"
            >
              Betroffene Datei: <code>{alert.media_id}</code>
            </span>
          </div>

          <%!-- AC8: "Live-Diagnose starten" — critical alerts only. Pre-fills
                the reason from the alert's own message (editable) and starts
                a War Room session scoped to the media domain (AC7). --%>
          <form
            :if={alert.severity == "critical"}
            id={"start-media-diagnosis-form-#{alert.id}"}
            phx-submit="start_media_diagnosis"
            data-testid="start-media-diagnosis-form"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <label class="sr-only" for={"diagnosis-reason-#{alert.id}"}>
              Grund für die Live-Diagnose
            </label>
            <input
              type="text"
              id={"diagnosis-reason-#{alert.id}"}
              name="reason"
              value={alert.message}
              class="input input-bordered input-sm"
            />
            <button type="submit" class="btn btn-sm btn-warning">
              Live-Diagnose starten
            </button>
          </form>
        </li>
      </ul>
    </section>

    <p :if={@empty?} data-testid="media-health-empty-state" class="text-text-secondary">
      Noch keine Scan-Daten — wartet auf den ersten stündlichen Rollup.
    </p>

    <div class="space-y-6">
      <section aria-labelledby="media-health-throughput-heading" class="p-4 rounded border border-base-300">
        <h2 id="media-health-throughput-heading" class="text-body font-semibold mb-2">Scan-Durchsatz</h2>
        <dl :if={not @empty?} class="grid grid-cols-2 gap-4">
          <div>
            <dt class="text-caption text-text-secondary">Letzte volle Stunde</dt>
            <dd data-testid="current-hour-total">{format_count(@latest.scans_total)}</dd>
          </div>
          <div>
            <dt class="text-caption text-text-secondary">Letzte 24h (Summe)</dt>
            <dd data-testid="throughput-24h">{format_count(@rolling_24h.scans_total_sum)}</dd>
          </div>
        </dl>
      </section>

      <section aria-labelledby="media-health-duration-heading" class="p-4 rounded border border-base-300">
        <h2 id="media-health-duration-heading" class="text-body font-semibold mb-2">Ø-/p95-Scan-Dauer</h2>
        <dl :if={not @empty?} class="grid grid-cols-2 gap-4">
          <div>
            <dt class="text-caption text-text-secondary">Durchschnitt (letzte Stunde)</dt>
            <dd data-testid="avg-duration">{format_ms(@latest.avg_scan_duration_ms)}</dd>
          </div>
          <div>
            <dt class="text-caption text-text-secondary">p95 (letzte Stunde)</dt>
            <dd data-testid="p95-duration">{format_ms(@latest.p95_scan_duration_ms)}</dd>
          </div>
        </dl>
      </section>

      <section aria-labelledby="media-health-backlog-heading" class="p-4 rounded border border-base-300">
        <h2 id="media-health-backlog-heading" class="text-body font-semibold mb-2">Backlog-Tiefe</h2>
        <p :if={not @empty?} data-testid="backlog-depth">{format_count(@latest.backlog_depth)}</p>
      </section>

      <section aria-labelledby="media-health-error-rate-heading" class="p-4 rounded border border-base-300">
        <h2 id="media-health-error-rate-heading" class="text-body font-semibold mb-2">Fehlerrate</h2>
        <dl :if={not @empty?} class="grid grid-cols-2 gap-4">
          <div>
            <dt class="text-caption text-text-secondary">Rollierend 24h</dt>
            <dd data-testid="error-rate-24h">{format_pct(@rolling_24h.error_rate_pct)}</dd>
          </div>
          <div>
            <dt class="text-caption text-text-secondary">Rollierend 7d</dt>
            <dd data-testid="error-rate-7d">{format_pct(@rolling_7d.error_rate_pct)}</dd>
          </div>
        </dl>
      </section>
    </div>

    <section aria-labelledby="clamav-status-heading" class="p-4 rounded border border-base-300 mt-6">
      <h2 id="clamav-status-heading" class="text-body font-semibold mb-2">ClamAV-Status</h2>

      <%!-- UX gate (2026-07-20): this section re-renders on the same 2s
            ClamAVStatusIndicator poll tick as WarRoomIndicator's topbar pill
            and MediaAttentionBadge's nav badge (layouts.ex) — both of which
            carry `role="status"` (implicit aria-live="polite" +
            aria-atomic="true") per that file's own documented rule: a
            live-updating value needs this so a screen-reader user is
            notified of a connectivity flip or a staleness-threshold crossing
            without having to navigate back into the section. Story 10b's own
            AC6 explicitly models this section on WarRoomIndicator, so this
            closes the gap between copying the poll mechanics and copying the
            accessibility half of that same pattern. Unlike the war-room
            pill's ticking mm:ss clock (deliberately aria-hidden there to
            avoid re-announcing every second) or the nav badge's bare number
            (needing a separate sr-only sentence), every string rendered here
            is already a complete, self-describing sentence ("Verbunden",
            "Nicht erreichbar" + "down seit ...", "Signaturen
            aktuell/veraltet (vor Xh aktualisiert)") — so the visible text
            itself is the live-region content; no redundant sr-only
            duplicate is needed, and LiveView only patches the DOM (so only
            re-announces) when a value actually changes, not on every poll
            tick. --%>
      <div role="status" class="flex flex-col gap-1">
        <span :if={@clamav_healthy} data-testid="clamav-status-connected" class="badge badge-success">
          Verbunden
        </span>
        <span :if={not @clamav_healthy} data-testid="clamav-status-disconnected" class="badge badge-error">
          Nicht erreichbar
        </span>
        <p :if={not @clamav_healthy} data-testid="clamav-down-since" class="text-caption text-text-secondary">
          down seit {format_datetime(@clamav_down_since)}
        </p>

        <span
          :if={@clamav_signature_stale?}
          data-testid="clamav-signature-warning"
          class="badge badge-warning"
        >
          Signaturen veraltet
        </span>
        <p class="text-caption text-text-secondary">
          {signature_age_copy(@clamav_signature_age, @clamav_signature_stale?)}
        </p>
      </div>
    </section>
    """
  end
end
