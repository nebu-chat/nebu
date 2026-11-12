defmodule Nebu.OAuth.DeviceNameDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `oauth-device-default-display-name` (epic oauth-session-and-consent, REQ-2026-004): a few ANCHORS in the documentation
  (`docs/architecture/08-concepts.md`, `CHANGELOG.md` under `[Unreleased]`; the wording is the dev's), the new module has no log call, the Matrix domain never builds
  the name (ADR-020: the OAuth domain owns the client record), and the Matrix store keeps the `display_name IS NULL` guard. The behaviour itself (never overwrite,
  sanitising, suffix) is pinned by the flow and pure tests.

  There is deliberately NO test for "no migration": migration number 000058 is reserved for another story, so a pin on the highest migration number would be a time
  bomb. The story adds none (it writes `devices.display_name`, which exists); the reference implementation touches no migration.
  """
  use ExUnit.Case, async: true

  @server Path.expand("../../..", __DIR__)
  @root Path.expand("..", @server)
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @module Path.join(@server, "lib/nebu/oauth/device_name.ex")
  @store Path.join(@server, "lib/nebu/matrix/session/oauth_session_store.ex")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  @heading "### Default display name of OAuth devices (story oauth-device-default-display-name)"

  test "08-concepts: a section for the story names the client name, the fallback, the never-overwrite rule and the module" do
    c = read(@concepts)
    assert c =~ @heading, "a section with this heading"
    sec = between(c, @heading, " ##")

    for anchor <- ["client_name", "OAuth client", "Nebu.OAuth.DeviceName"], do: assert(sec =~ anchor, "the section must mention #{anchor}")
    assert sec =~ ~r/never overwrit/i
  end

  test "CHANGELOG [Unreleased]: an entry for the story that says what a user sees" do
    unreleased = @changelog |> read() |> between("## [0.4.0]", " ## [")
    assert unreleased =~ "oauth-device-default-display-name"
    [_, rest] = String.split(unreleased, "oauth-device-default-display-name", parts: 2)
    entry = rest |> String.split(" - **", parts: 2) |> hd()
    assert entry =~ "REQ-2026-004"
    assert entry =~ ~r/display name/i
  end

  test "the module exists, documents itself, and has no log call (code only: comments and docs are not looked at)" do
    src = File.read!(@module)
    assert src =~ "defmodule Nebu.OAuth.DeviceName"
    assert src =~ "@moduledoc"

    code =
      src
      |> String.replace(~r/"""(.|\n)*?"""/, "")
      |> String.replace(~r/#.*$/m, "")

    refute code =~ ~r/Logger\.(debug|info|notice|warn|warning|error|critical|alert|emergency|log)\b/, "the name must not be logged"
    refute code =~ ~r/IO\.(puts|inspect)/
  end

  test "cycle 1 - 08-concepts and CHANGELOG do not claim 'not logged' without the caveat: the new code does not log it, the debug request logger's GET /devices capture shows it" do
    sec = @concepts |> read() |> between(@heading, " ##")
    unreleased = @changelog |> read() |> between("## [0.4.0]", " ## [")
    [_, rest] = String.split(unreleased, "oauth-device-default-display-name", parts: 2)
    entry = rest |> String.split(" - **", parts: 2) |> hd()

    for {where, text} <- [{"08-concepts", sec}, {"CHANGELOG", entry}] do
      assert text =~ ~r/the new code does not log (it|the name)/i, "#{where}: the wording 'the new code does not log it'"
      assert text =~ ~r/debug request logger/i, "#{where}: the caveat about the debug request logger"
      assert text =~ ~r/GET \/devices/, "#{where}: the caveat names GET /devices"
      refute text =~ ~r/name is not logged/i, "#{where}: no unqualified 'not logged' claim"
    end
  end

  @follow_ups Path.join(@root, "docs/stories/oauth-session-and-consent/follow-ups.md")

  test "cycle 1 - the follow-up register of the epic exists and holds the three entries of the review" do
    assert File.exists?(@follow_ups), "docs/stories/oauth-session-and-consent/follow-ups.md"
    text = @follow_ups |> read() |> String.downcase()

    for entry <- [
          "redact device names in the debug request logger",
          "thread client_name through authenticate/redeem to avoid the second client select",
          "confusable/mixed-script warning on approve_confirm"
        ] do
      assert text =~ entry, "follow-ups.md must contain: #{entry}"
    end
  end

  test "ADR-020: the Matrix domain never builds the name; the OAuth domain hands it over" do
    for file <- Path.wildcard(Path.join(@server, "lib/nebu/matrix/**/*.ex")) do
      refute File.read!(file) =~ "Nebu.OAuth.DeviceName", "#{Path.relative_to(file, @server)} must not call the OAuth domain's naming"
    end

    assert File.read!(Path.join(@server, "lib/nebu/oauth/token.ex")) =~ "DeviceName", "the token endpoint (OAuth domain) builds the name"
  end

  test "the Matrix store fills an UNSET name only (the guard is also pinned by behaviour in the flow tests)" do
    assert File.read!(@store) =~ "display_name IS NULL"
  end
end
