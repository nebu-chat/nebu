defmodule Nebu.Admin.LogsConfigHTML do
  @moduledoc """
  Template module for `Nebu.Admin.LogsController`
  (enhanced-logging/admin-logs-retention-settings). Mirrors
  `Nebu.Admin.ConfigHTML`'s exact pattern (`embed_templates
  "templates/config/*"` + a single `templates/config/index.html.heex`).

  Named `LogsConfigHTML` (not `LogsHTML`) to avoid ambiguity with the
  sibling `Nebu.Admin.LogsLive` monitoring-page module.
  """
  use Phoenix.Component

  embed_templates "templates/logs_config/*"
end
