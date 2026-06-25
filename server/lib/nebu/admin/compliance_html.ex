defmodule Nebu.Admin.ComplianceHTML do
  @moduledoc "Template module for ComplianceController."
  use Phoenix.Component

  embed_templates "templates/compliance/*"

  defp status_class("pending"), do: "badge-warning"
  defp status_class("approved"), do: "badge-success"
  defp status_class("denied"), do: "badge-error"
  defp status_class(_), do: "badge-ghost"
end
