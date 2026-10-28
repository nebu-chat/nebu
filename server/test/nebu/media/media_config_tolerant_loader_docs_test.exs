defmodule Nebu.Media.MediaConfigTolerantLoaderDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for AC10 of story `media-config-tolerant-loader` (follow-up `ej`): the follow-up row is closed with a reference to
  the story, the break-glass sentence of 07-deployment tells the operator that the value must be plain digits and what a wrong value does, and the
  building-blocks entry of `Nebu.Media.Config` names `damaged_keys/0`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @blocks Path.join(@root, "docs/architecture/05-building-blocks.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")

  defp flat(path), do: path |> File.read!() |> String.replace(~r/\s+/, " ")
  defp table_row(text, id), do: text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} |"))

  test "follow-ups: ej is closed with a reference to the story and no longer open" do
    row = table_row(File.read!(@followups), "ej")

    assert row =~ "CLOSED by story media-config-tolerant-loader"
    refute row =~ "open, non-gating"
    assert String.ends_with?(String.trim(row), "| closed |"), "the status column reads closed, like the closed rows of the same table (du)"
  end

  test "07-deployment: the break-glass UPDATE of the media policy row says plain digits and what a wrong value does" do
    row = @deploy |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| Media policy (`/admin/media/settings`)"))

    assert row, "the media policy row of the admin form table exists"
    row = String.replace(row, ~r/\s+/, " ")

    assert row =~ "Break-glass"
    assert row =~ "plain digits"
    assert row =~ "warning", "a wrong value shows a warning on the media settings page"
    assert row =~ "at its default", "the damaged key stays at its default"
    assert row =~ "paused", "the cleanup is paused for deleted_days / infected_days"
  end

  test "07-deployment: the retention paragraph no longer says that the Admin form silently shows the defaults for a damaged row" do
    text = flat(@deploy)

    refute text =~ "an existing limitation of the table read, follow-up `ej`"
    assert text =~ "Media retention windows"
  end

  test "05-building-blocks: the Nebu.Media.Config entry mentions damaged_keys/0" do
    assert flat(@blocks) =~ "damaged_keys/0"
  end
end
