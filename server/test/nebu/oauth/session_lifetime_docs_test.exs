defmodule Nebu.OAuth.SessionLifetimeDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `session-lifetime-setting` (epic oauth-session-and-consent): the operator documentation of the Admin
  setting "Matrix session lifetime" in `docs/architecture/07-deployment.md` (own section, and a line in the protection list of the admin forms) and the
  entry under `[Unreleased]` of `CHANGELOG.md` (migration 000056, audit action, behaviour).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @changelog Path.join(@root, "CHANGELOG.md")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "07-deployment: the section 'Matrix session lifetime' names the key, bounds, default, env fallback, absolute ceiling, existing sessions and the audit action" do
    d = read(@deploy)
    assert d =~ "### Matrix session lifetime", "a section with this heading"
    sec = between(d, "### Matrix session lifetime", " ##")

    for word <- ["matrix_session_ttl_seconds", "NEBU_MATRIX_SESSION_TTL_SECONDS", "/admin/config", "8 hours", "1 hour", "90 days", "3600", "7776000", "session_lifetime_changed", "000056"] do
      assert sec =~ word, "the section must mention #{word}"
    end

    assert sec =~ ~r/existing OAuth sessions/i
    # decision M3: the absolute guarantee is for OAuth sessions; legacy sessions have no stored ceiling and follow the CURRENT setting (both directions)
    assert sec =~ ~r/legacy sessions follow/i
    assert sec =~ ~r/lowered/i and sec =~ ~r/raised/i
    assert sec =~ ~r/never shortened/i
    # decision: an unreadable server_config falls back to the env value / 8 hours (fail safe, not cached)
    assert sec =~ ~r/unreadable/i
    assert sec =~ ~r/absolute|never extend|does not extend|no sliding/i, "the ceiling is absolute from the login, a refresh does not extend it"
    assert sec =~ ~r/fresh sign-in/i
    assert sec =~ ~r/legacy/i, "it applies to the legacy login too"
    assert sec =~ ~r/NEBU_OAUTH_CONFIG_CACHE_MS|within a few seconds|within \d+ seconds/i, "other nodes follow within the cache TTL"
  end

  test "07-deployment (cycle 1): last-known-good, the in-flight refill race, the cache-off query per login and the legacy IdP expiry cap are described" do
    sec = read(@deploy) |> between("### Matrix session lifetime", " ##")
    # Kassandra #1 / code review INFO: a failed read or a damaged row keeps the last good value
    assert sec =~ ~r/last[- ]known[- ]good/i
    assert sec =~ ~r/never (been )?loaded|no good value/i, "the env value / 8 hours apply only when no good value was ever loaded on this node"
    # code review MINOR 5: the saving node is not 'at once' without the caveat
    assert sec =~ ~r/in-flight/i
    # code review MINOR 1: with the cache off every login (and refresh, worker row) reads the table
    assert sec =~ ~r/NEBU_OAUTH_CONFIG_CACHE_MS=0|cache (is )?(switched )?off/i
    assert sec =~ ~r/query per (login|call)|every login/i
    # code review MINOR 6: a legacy login is capped by the exp of the IdP token as well
    assert sec =~ ~r/identity provider/i
    assert sec =~ ~r/\bexp\b/
    refute sec =~ ~r/the failed read is not cached, the next call reads again\)\. A saved value that is damaged/, "the old fail-open sentence is gone"
  end

  test "07-deployment (cycle 1): the description of NEBU_OAUTH_CONFIG_CACHE_MS says that the cache holds the session lifetime too, and the last-known-good rule" do
    d = read(@deploy)
    [_, rest] = String.split(d, "**Environment variable `NEBU_OAUTH_CONFIG_CACHE_MS`**", parts: 2)
    [para | _] = String.split(rest, "**Environment variable", parts: 2)
    assert para =~ "matrix_session_ttl_seconds"
    assert para =~ ~r/session lifetime/i
    assert para =~ ~r/last[- ]known[- ]good/i
  end

  test "08-concepts (cycle 1): the session-lifetime ceiling is no longer 'inert in production' / 'primarily a test seam' and names the Admin setting" do
    c = File.read!(Path.join(@root, "docs/architecture/08-concepts.md")) |> String.replace(~r/\s+/, " ")
    refute c =~ "inert in production"
    refute c =~ ~r/primarily a \*\*test seam\*\*/
    [_, rest] = String.split(c, "**Configurable Nebu session-lifetime ceiling", parts: 2)
    [para | _] = String.split(rest, "Migration `000007`", parts: 2)
    assert para =~ "matrix_session_ttl_seconds"
    assert para =~ ~r/Admin/
    assert para =~ ~r/last[- ]known[- ]good/i
  end

  test "07-deployment (cycle 2): before_seconds is the saved value read inside the transaction, else the value this node had in effect" do
    sec = read(@deploy) |> between("### Matrix session lifetime", " ##")
    assert sec =~ "`before_seconds`"
    assert sec =~ ~r/saved value (read )?(inside|within) the (same )?transaction/i
    assert sec =~ ~r/(else|otherwise) the value this node had in effect/i
    refute sec =~ ~r/the value in effect inside the transaction/i
  end

  test "07-deployment (cycle 2): the oauth_access_token_ttl_seconds row no longer claims that the session ceiling stays env-only" do
    row = @deploy |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| `oauth_access_token_ttl_seconds`"))
    assert row
    refute row =~ ~r/that stays `NEBU_MATRIX_SESSION_TTL_SECONDS`/
    assert row =~ "matrix_session_ttl_seconds", "it points to the Admin setting"
    assert row =~ ~r/Admin/
  end

  test "ADR-033 carries a pointer sentence to the Admin session lifetime setting (the decision text stays)" do
    adr = File.read!(Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")) |> String.replace(~r/\s+/, " ")
    assert adr =~ "matrix_session_ttl_seconds"
    assert adr =~ "session-lifetime-setting"
    assert adr =~ "NEBU_MATRIX_SESSION_TTL_SECONDS", "the original decision (env value) is not edited away"
  end

  test "the @doc of oauth_issue_session (lib/nebu/matrix.ex), the runtime.exs comment and 08-concepts T3 name the Admin setting" do
    src = File.read!(Path.join(@root, "server/lib/nebu/matrix.ex"))
    [before_spec, _] = String.split(src, "  @spec oauth_issue_session", parts: 2)
    doc = before_spec |> String.split("@doc \"\"\"") |> List.last() |> String.replace(~r/\s+/, " ")
    assert doc =~ "matrix_session_ttl_seconds"
    assert doc =~ ~r/Admin/

    runtime = File.read!(Path.join(@root, "server/config/runtime.exs"))
    [_, rest] = String.split(runtime, "configurable Nebu session TTL ceilings", parts: 2)
    [comment | _] = String.split(rest, "for {env_name", parts: 2)
    comment = String.replace(comment, ~r/\s+/, " ")
    assert comment =~ "matrix_session_ttl_seconds"
    assert comment =~ ~r/Admin/

    # 08-concepts: the line that describes `matrix_sessions.expires_at` as a fixed 8 hours
    line = Path.join(@root, "docs/architecture/08-concepts.md") |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "expires_at "))
    assert line =~ "Nebu controls expiry"
    assert line =~ "matrix_session_ttl_seconds"
    refute line =~ ~r/NOW\(\) \+ 8 hours\)\s*$/, "not a fixed 8 hours any more"
  end

  test "the story's decision on an unreadable configuration matches the code: last-known-good, one warning per minute (no more 'fail safe: env value')" do
    story = File.read!(Path.join(@root, "docs/stories/oauth-session-and-consent/session-lifetime-setting.md"))
    [_, decisions] = String.split(story, "## Decisions", parts: 2)
    bullet = decisions |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- ")) |> Enum.find(&(&1 =~ ~r/unreadable/i))
    assert bullet, "a decision about an unreadable server_config"
    assert bullet =~ ~r/last[- ]known[- ]good/i
    assert bullet =~ ~r/one (warning )?per minute|once per minute/i
    refute bullet =~ ~r/answer the env value \/ 8 hours \(fail safe/
  end

  test "the module docs of Nebu.OAuth.Config and Nebu.Web.SessionConfig name the saved lifetime and the last-known-good rule (code review MINOR 1)" do
    for {mod, words} <- [{Nebu.OAuth.Config, ["matrix_session_ttl_seconds", "last-known-good"]}, {Nebu.Web.SessionConfig, ["Admin", "last-known-good"]}] do
      assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(mod)
      for w <- words, do: assert(moduledoc =~ w, "#{inspect(mod)} moduledoc must mention #{w}")
    end
  end

  test "07-deployment: the table of the admin forms has a row for the session lifetime with its page, protection and audit action" do
    row = @deploy |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| Matrix session lifetime"))
    assert row, "a table row starting with '| Matrix session lifetime'"
    assert row =~ "`/admin/config`"
    assert row =~ "fresh sign-in"
    assert row =~ "session_lifetime_changed"
  end

  test "CHANGELOG: [Unreleased] describes the setting, the audit action and migration 000056" do
    c = File.read!(@changelog)
    [_, rest] = String.split(c, "## [Unreleased]", parts: 2)
    [unreleased | _] = Regex.split(~r/\n## \[/, rest, parts: 2)
    unreleased = String.replace(unreleased, ~r/\s+/, " ")

    for word <- ["session lifetime", "matrix_session_ttl_seconds", "session_lifetime_changed", "000056", "/admin/config", "NEBU_MATRIX_SESSION_TTL_SECONDS", "90 days"] do
      assert unreleased =~ word, "[Unreleased] must mention #{word}"
    end

    assert unreleased =~ ~r/existing OAuth sessions/i
    assert unreleased =~ ~r/last[- ]known[- ]good/i
    assert unreleased =~ ~r/legacy sessions follow/i
  end
end
