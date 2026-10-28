defmodule Nebu.Media.StorageTestPinnedTargetDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `storage-test-pinned-target`, AC6: what 07-deployment and ADR-033 SO11
  say about the pinned storage test target and the residual of the operational S3 calls, the follow-ups rows (`do` part a
  closed, part b split out, a new row for the residual) and the code docs where the guard is described.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @storage_config Path.join(@root, "server/lib/nebu/media/storage_config.ex")
  @ssrf Path.join(@root, "server/lib/nebu/media/ssrf.ex")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    assert String.contains?(text, from), "the start marker #{inspect(from)} exists"
    [_, rest] = String.split(text, from, parts: 2)
    assert String.contains?(rest, to), "the end marker #{inspect(to)} exists after #{inspect(from)}"
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "07-deployment: the forms section says what is pinned (check = request address, Host / SNI / certificate keep the name) and the residual of the operational calls" do
    sec = between(read(@deploy), "### Admin configuration forms and their protection", "### Preconditions")

    for word <- ["DNS rebinding", "checked address", "`Host`", "SNI", "certificate", "operational", "residual", "storage-test-pinned-target"] do
      assert sec =~ word, "07-deployment (forms section) names #{word}"
    end
  end

  test "07-deployment: the test connection row of the table states the pin" do
    row = between(read(@deploy), "| Test connection (storage form)", "| Log retention")

    assert row =~ "pinned"
    assert row =~ "DNS rebinding"
  end

  test "ADR-033: an SO11 addendum records the decision (pin to the checked IP, Host / SNI / certificate for the name, upsert makes no request, residual of the operational calls)" do
    sec = between(read(@adr), "- **SO11 addendum: the pinned storage test target", "- **SO8 ")

    for word <- ["storage-test-pinned-target", "`Nebu.Media.SSRF.checked_target/2`", "DNS rebinding", "checked IP", "`Host`", "SNI", "certificate", "`upsert/1`", "operational", "residual", "`allow_private`", "`do`"] do
      assert sec =~ word, "ADR-033 SO11 addendum names #{word}"
    end
  end

  test "follow-ups: `do` part a is closed by the story, part b is split out as an own feature, the operational-calls residual is a new row" do
    do_row =
      @followups
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "| do |"))
      |> to_string()
      |> String.replace(~r/\s+/, " ")

    assert do_row =~ "PART A CLOSED by story storage-test-pinned-target"
    assert do_row =~ "split out: own feature (owner idea), not part of this epic"

    residual_rows =
      @followups
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&(String.starts_with?(&1, "| ") and &1 =~ "storage-test-pinned-target" and &1 =~ "operational" and &1 =~ "rebinding"))

    assert residual_rows != [], "a follow-ups row (new id) records the residual of the operational S3 calls (stored operator-trusted endpoint, rebinding after the save)"
    refute Enum.any?(residual_rows, &String.starts_with?(&1, "| do |")), "the residual is a NEW row, not the `do` row"
  end

  test "code docs: StorageConfig's moduledoc and the SSRF moduledoc name the pinned test connection" do
    sc = read(@storage_config)
    assert sc =~ "storage-test-pinned-target"
    assert sc =~ "pinned"

    ssrf = read(@ssrf)
    assert ssrf =~ "ExAws"
    assert ssrf =~ "pinned"
  end
end
