defmodule Nebu.Admin.UsersHTML do
  @moduledoc "Template module for UsersController."
  use Phoenix.Component

  embed_templates "templates/users/*"

  # ── Device-detail render helpers (device-management S4) ───────────────────────

  @doc false
  # Reads an optional device field by string key from the device map.
  def device_field(device, key), do: Map.get(device, key)

  @doc false
  # Renders a BIGINT epoch-millis timestamp as a human ISO-8601 UTC token, or an
  # em-dash when absent (MINOR-2 / MINOR-3 — created + last-seen are shown as a
  # date/time, not a raw integer).
  def format_ts(nil), do: "—"

  def format_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> "—"
    end
  end

  def format_ts(_), do: "—"

  @doc false
  # Combines last-seen timestamp + IP into a single human cell (MINOR-3).
  def last_seen_cell(device) do
    ts = format_ts(Map.get(device, "last_seen_ts"))
    ip = Map.get(device, "last_seen_ip")

    cond do
      ip in [nil, ""] -> ts
      true -> "#{ts} · #{ip}"
    end
  end

  @doc false
  # Display name shown in the list / rename input default, falling back to the
  # device id when the device has no display name.
  def device_display_name(device) do
    case Map.get(device, "display_name") do
      name when is_binary(name) and name != "" -> name
      _ -> ""
    end
  end
end
