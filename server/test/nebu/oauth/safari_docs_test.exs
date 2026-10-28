defmodule Nebu.OAuth.SafariDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `safari-fetch-metadata-compat`, AC8: the documentation states that Safari sends no
  `Sec-Fetch-User`, names the click proof, lists the MANUAL per-browser check, and no longer claims that Chrome, Firefox AND Safari send
  all four fetch metadata headers.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @risks Path.join(@root, "docs/architecture/11-risks.md")
  @blocks Path.join(@root, "docs/architecture/05-building-blocks.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  test "07-deployment: the manual verification names Safari / Firefox / Chrome, the missing Sec-Fetch-User, the click proof and MANUAL" do
    d = read(@deploy)
    assert d =~ "Safari (macOS and iOS) sends the first three but NEVER `Sec-Fetch-User`"
    assert d =~ "`_click_proof`"
    assert d =~ "MANUAL"
    assert d =~ "In EACH of current Chrome, Firefox and Safari"
    assert d =~ "JavaScript disabled"
    assert d =~ "both `/admin/config` SSO trust forms"
    assert d =~ "VoiceOver"
    assert d =~ "native confirm dialog accepted"
  end

  test "07-deployment: SO7 states the click proof and its residual; Safari 16.4+ is not locked out any more" do
    d = read(@deploy)
    assert d =~ "click proof replaces it"
    assert d =~ "no longer even has to wait for a user click"
    refute d =~ "Old browsers without fetch metadata (Safari before 16.4) are locked out"
    refute d =~ "Chrome, Firefox, Safari 16.4+): a mouse click AND an Enter-key submit"
  end

  test "ADR-033: SO9 exists (mechanism, WebKit-only, notice, residual), SO2 / SO7 / manual verification no longer claim Safari sends four headers" do
    a = read(@adr)
    assert a =~ "**SO9 (Safari / WebKit: the click proof"
    assert a =~ "does NOT send `Sec-Fetch-User`"
    assert a =~ "`Nebu.Web.ClickProofScript`"
    assert a =~ "AppleWebKit/"
    assert a =~ "oauth-activation-unproven"
    refute a =~ "(2) Chrome, Firefox and Safari send the four fetch metadata headers"
    refute a =~ "old browsers without fetch metadata (Safari before 16.4) are locked out"
  end

  test "11-risks, 05-building-blocks and follow-ups record the finding (rows cx-cz, gate row) and the new module" do
    assert read(@risks) =~ "Safari / WebKit sends no `Sec-Fetch-User`"
    assert read(@blocks) =~ "`Nebu.Web.ClickProofScript`"
    f = read(@followups)
    assert f =~ "| cx | **GATE FINDING (Safari / WebKit never sends `Sec-Fetch-User`"
    assert f =~ "| cy | **Residual: the proof is attested by page script"
    assert f =~ "| cz | **User-Agent classification is a heuristic."
    assert f =~ "| gate cx (Safari / WebKit sends no `Sec-Fetch-User`"
    assert f =~ "MANUAL"
  end
end
