defmodule Nebu.Admin.ComplianceLive do
  @moduledoc """
  Admin Compliance overview (Go parity: gateway/internal/admin/templates/compliance.html).

  Read-only list of compliance access requests (four-eyes review trail): requester,
  room, status, justification, time window. Inline SQL per ADR-018 against
  compliance_requests. Approve/deny actions remain a follow-up (this restores the
  read view + the nav section).
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @sql """
  SELECT requester_user_id, room_id, status, justification, created_at
  FROM compliance_requests
  ORDER BY created_at DESC, id DESC
  LIMIT 200
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "compliance")
     |> assign(:page_title, "Compliance")
     |> assign(:requests, load_requests())}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Compliance</h1>
    <p class="text-text-secondary mb-4">Privileged-access requests (four-eyes review trail).</p>

    <p :if={@requests == []} class="text-text-secondary">No compliance requests.</p>

    <div :if={@requests != []} class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Requester</th>
            <th>Room</th>
            <th>Status</th>
            <th>Justification</th>
            <th>Created</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @requests}>
            <td class="font-mono">{r.requester}</td>
            <td class="font-mono text-mono">{r.room_id}</td>
            <td><span class={["badge badge-sm", status_class(r.status)]}>{r.status}</span></td>
            <td class="max-w-md truncate">{r.justification}</td>
            <td class="font-mono text-mono whitespace-nowrap">{r.created_at}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp status_class("pending"), do: "badge-warning"
  defp status_class("approved"), do: "badge-success"
  defp status_class("denied"), do: "badge-error"
  defp status_class(_), do: "badge-ghost"

  defp load_requests do
    if Process.whereis(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql, []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [req, room, status, just, created] ->
            %{requester: req, room_id: room, status: status, justification: just, created_at: created}
          end)

        _ ->
          []
      end
    else
      []
    end
  end
end
