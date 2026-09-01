defmodule Nebu.Media.Alerts do
  @moduledoc """
  Public read seam (ADR-020) for `media_alerts`
  (media-security-admin-control/10c-media-alerts-triggers).

  `Nebu.Workers.MediaAlertsCheckerWorker` is the only writer of this table
  (opens/auto-resolves rows via its own inline SQL, per ADR-018/Dev Agent
  Guardrails — this module never writes). `list_open/0` is the single read
  seam the `/admin/media/health` dashboard LiveView (`Nebu.Admin.MediaHealthLive`)
  calls instead of querying `media_alerts` directly — mirroring
  `Nebu.Media.Config.get/0`'s "one seam, no raw queries from callers"
  precedent (Technical Requirements, "Dashboard integration").
  """

  alias Nebu.Repo

  @sql_list_open """
  SELECT id, alert_type, severity, message, media_id, condition_metadata, opened_at, resolved_at
    FROM media_alerts
   WHERE resolved_at IS NULL
   ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, opened_at DESC
  """

  @doc """
  Returns every unresolved `media_alerts` row (`resolved_at IS NULL`),
  `critical` severity before `warning`, most-recently-opened first within
  each severity (AC4). Returns `[]` (never `nil`/an error tuple) when there
  are no open alerts, including when `Nebu.Repo` is not running (e.g. plain
  unit-test runs without a live DB).
  """
  @spec list_open() :: [map()]
  def list_open do
    if Process.whereis(Nebu.Repo) do
      %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, @sql_list_open, [])

      Enum.map(rows, fn [id, alert_type, severity, message, media_id, condition_metadata,
                          opened_at, resolved_at] ->
        %{
          id: id,
          alert_type: alert_type,
          severity: severity,
          message: message,
          media_id: media_id,
          condition_metadata: condition_metadata,
          opened_at: opened_at,
          resolved_at: resolved_at
        }
      end)
    else
      []
    end
  end
end
