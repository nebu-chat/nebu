defmodule Nebu.Admin.AuditLogLive do
  @moduledoc """
  Admin Audit Log (Go parity: gateway/internal/admin/templates/audit_log.html).

  Read-only list of the most recent audit_log events (actor, action, target, outcome,
  time). Inline SQL per ADR-018; the audit_log table is the append-only compliance trail
  written by Nebu.Compliance.AuditWriter.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @sql """
  SELECT event_time, actor_user_id, action, target_type, target_id, outcome
  FROM audit_log
  ORDER BY event_time DESC, id DESC
  LIMIT 200
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "compliance")
     |> assign(:page_title, "Audit Log")
     |> assign(:events, load_events())}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Audit Log</h1>

    <p :if={@events == []} class="text-text-secondary">No audit events recorded.</p>

    <div :if={@events != []} class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Time</th>
            <th>Actor</th>
            <th>Action</th>
            <th>Target</th>
            <th>Outcome</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={e <- @events}>
            <td class="font-mono text-mono whitespace-nowrap">{e.event_time}</td>
            <td class="font-mono">{e.actor || "—"}</td>
            <td>{e.action}</td>
            <td class="font-mono text-mono">{e.target}</td>
            <td>
              <span class={["badge badge-sm", outcome_class(e.outcome)]}>{e.outcome || "—"}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp outcome_class("success"), do: "badge-success"
  defp outcome_class("failure"), do: "badge-error"
  defp outcome_class(_), do: "badge-ghost"

  defp load_events do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql, []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [t, actor, action, ttype, tid, outcome] ->
            %{
              event_time: t,
              actor: actor,
              action: action,
              target: [ttype, tid] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(":"),
              outcome: outcome
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  end
end
