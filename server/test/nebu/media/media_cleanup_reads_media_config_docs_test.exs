defmodule Nebu.Media.MediaCleanupReadsMediaConfigDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for AC6 / AC8 of story `media-cleanup-reads-media-config` (follow-up `du`): the docs state the
  behaviour (07-deployment "Media retention windows", the pre-upgrade check, the fail-safe line), `du` is closed and the owner decision
  about the infected default (`eh`, decided 2026-10-16: keep 7 days) is recorded, and the dead `config :nebu, :media_cleanup` block is gone.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @config Path.join(@root, "server/config/config.exs")

  defp flat(path), do: path |> File.read!() |> String.replace(~r/\s+/, " ")
  defp table_row(text, id), do: text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} |"))

  test "07-deployment documents the windows, the defaults 30 / 7, the fail-safe and the pre-upgrade check; the old known-gap sentence is gone" do
    text = flat(@deploy)

    assert text =~ "Media retention windows"
    assert text =~ "30 days (deleted) and 7 days (infected)"
    assert text =~ "retention config unavailable, nothing deleted"
    assert text =~ "SELECT key, value FROM media_config WHERE key IN ('deleted_days', 'infected_days')"
    refute text =~ "the cleanup worker does not yet read"
  end

  test "follow-ups: du is closed, the owner decision about the infected default (eh) is recorded as decided" do
    text = File.read!(@followups)

    assert table_row(text, "du") =~ "CLOSED by story media-cleanup-reads-media-config"
    assert table_row(text, "du") =~ "| closed |"
    assert table_row(text, "eh") =~ "decided 2026-10-16 (owner)"
    assert table_row(text, "eh") =~ "INFECTED"
  end

  test "config.exs no longer carries the application key the worker used to read" do
    refute File.read!(@config) =~ ~r/^config :nebu, :media_cleanup/m
  end
end
