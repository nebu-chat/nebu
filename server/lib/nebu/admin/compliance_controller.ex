defmodule Nebu.Admin.ComplianceController do
  @moduledoc """
  HTTP controller for the Admin Compliance page (admin-http-refactor story).

  Replaces Nebu.Admin.ComplianceLive. Read-only GET that renders the compliance
  requests table (inline SQL, ADR-018).

  ADR-018: SQL inline in action, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  @sql """
  SELECT requester_user_id, room_id, status, justification, created_at
  FROM compliance_requests
  ORDER BY created_at DESC, id DESC
  LIMIT 200
  """

  def index(conn, _params) do
    conn
    |> assign(:requests, load_requests())
    |> assign(:page_title, "Compliance")
    |> assign(:active_nav, "compliance")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

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
