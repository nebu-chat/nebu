defmodule Nebu.OAuth.ConsentGrantDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for the documentation half of story `persistent-consent-grants` (epic oauth-session-and-consent, REQ-2026-003):
  the operator section in `docs/architecture/07-deployment.md`, the erasure inventory of `08-concepts.md`, the ADR-033 addendum (FR1 "consent on every
  authorization" is changed by this story: the decision must be recorded), the building blocks table and the `[Unreleased]` entry of `CHANGELOG.md`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @blocks Path.join(@root, "docs/architecture/05-building-blocks.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @changelog Path.join(@root, "CHANGELOG.md")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  # `=~` would print the whole (huge) document on a failure: a boolean keeps the message short
  defp has?(text, %Regex{} = pattern), do: Regex.match?(pattern, text)
  defp has?(text, needle) when is_binary(needle), do: String.contains?(text, needle)

  defp between(text, from, to) do
    assert has?(text, from), "the document has no #{inspect(from)}"
    [_, rest] = String.split(text, from, parts: 2)
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "07-deployment: the section 'Remembered consent grants' names the table, migration, binding, skip rule, deletion paths and the rolling deploy" do
    d = read(@deploy)
    assert has?(d, "### Remembered consent grants"), "a section with this heading"
    sec = between(d, "### Remembered consent grants", " ##")

    for word <- ["oauth_consent_grants", "000057", "force_consent", "prompt=consent", "/account/apps", "client_approved_at", "REQ-2026-003"] do
      assert has?(sec, word), "the section must mention #{word}"
    end

    for {pattern, why} <- [
          {~r/one (grant|row) per user and client/i, "one grant per user and client"},
          {~r/device (id|token)/i, "the device is named"},
          {~r/not (part of|stored)|without the device/i, "the device is not part of the remembered scope"},
          {~r/redirect URI/i, "the redirect URI"},
          {~r/exact/i, "compared exactly"},
          {~r/subset|covered|narrower/i, "a narrower request skips, a broader one asks again"},
          {~r/profile/i, "profile / email"},
          {~r/ignored|never granted/i, "profile / email are dropped by the scope parser and never granted"},
          {~r/sign-in at the identity provider (still )?(happens|runs|applies)|login is not skipped|identity provider login still/i, "the IdP login is not skipped"},
          {~r/PKCE/, "PKCE binding unchanged"},
          {~r/device holder/i, "the device holder rule is unchanged"},
          {~r/freshness|auth_time/i, "freshness is unchanged"},
          {~r/revok/i, "revocation deletes the grants"},
          {~r/same transaction/i, "in the revoke transaction"},
          {~r/approved again|re-approv/i, "a re-approved client does not inherit a grant"},
          {~r/GDPR|erasure/i, "erasure deletes the grants"},
          {~r/withdraw/i, "the user's withdrawal"},
          {~r/does not (sign out|end|revoke)/i, "withdrawing does not end existing sessions"},
          {~r/no (expiry|expiration)|never expires|does not expire/i, "decision: a grant has no expiry"},
          {~r/rolling/i, "rolling deploy"},
          {~r/previous release|old(er)? node/i, "old nodes keep asking"},
          {~r/down migration|rollback/i, "rollback"},
          {~r/unreadable|cannot be read|storage/i, "an unreadable table"},
          {~r/asks? (for consent )?again|consent screen/i, "fails towards asking"},
          {~r/SELECT[^;]*oauth_consent_grants|DELETE FROM oauth_consent_grants/i, "an operator query or statement"}
        ] do
      assert has?(sec, pattern), "the section must say: #{why}"
    end
  end

  test "07-deployment: the operator's erasure sweep deletes the table too (built from erased_tables/0)" do
    assert has?(read(@deploy), ~r/DELETE FROM oauth_consent_grants WHERE user_id IN \(SELECT user_id FROM users WHERE deletion_status = 'keys_deleted'\)/)
  end

  test "07-deployment: the GDPR erasure paragraph lists the table" do
    para = read(@deploy) |> between("GDPR erasure covers every per-user table", "Backups:")
    assert has?(para, "oauth_consent_grants")
  end

  test "08-concepts: the erasure inventory lists oauth_consent_grants as erased by the transaction" do
    c = read(@concepts)
    assert has?(between(c, "**Erased by the transaction**", " (`oauth_codes` needs"), "oauth_consent_grants")
  end

  test "ADR-033: an addendum records that FR1 (consent on every authorization) is relaxed by remembered grants, with the rules" do
    a = read(@adr)

    for {pattern, why} <- [
          {"oauth_consent_grants", "the table"},
          {~r/persistent[- ]consent|persistent-consent-grants/i, "the story"},
          {~r/Remembered consent/i, "the decision heading"},
          {~r/prompt=consent/, "prompt=consent"},
          {~r/client_approved_at|approval time/i, "the client binding"}
        ] do
      assert has?(a, pattern), "the ADR must mention: #{why}"
    end

    # FR1 itself carries the pointer so a reader of the old decision is not misled
    fr1 = between(a, "- **FR1 Consent on EVERY authorization", "- **FR2")
    assert has?(fr1, "persistent-consent-grants"), "FR1 must point to the story that relaxes it (the old text itself says 'no remembered grants')"
  end

  test "05-building-blocks: the OAuth table names the grant store and its table" do
    b = read(@blocks)
    assert has?(b, "ConsentGrantStore")
    assert has?(b, "oauth_consent_grants")
  end

  test "CHANGELOG [Unreleased]: the entry names the story, the migration, the skip rule, prompt=consent, the account page and the erasure" do
    c = read(@changelog)
    assert has?(c, "## [Unreleased]")
    [_, rest] = String.split(c, "## [Unreleased]", parts: 2)
    unreleased = rest |> String.split(~r/ ## \[\d/, parts: 2) |> hd()
    entry = between(unreleased, "persistent-consent-grants", "- **")

    for word <- ["000057", "oauth_consent_grants", "prompt=consent", "/account/apps", "erasure", "revoc"] do
      assert has?(entry, word), "the entry must mention #{word}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # cycle 1 (code review MINOR 1-4, Kassandra MEDIUM #1 / LOW #2 / LOW #3 / INFO #4)
  # ════════════════════════════════════════════════════════════════════════════

  @lib Path.join(@root, "server/lib/nebu/oauth")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")

  defp source(name), do: File.read!(Path.join(@lib, name))

  # the text of the first `@moduledoc """ ... """`
  defp moduledoc(name) do
    [_, rest] = String.split(source(name), ~s(@moduledoc """), parts: 2)
    rest |> String.split(~s("""), parts: 2) |> hd() |> String.replace(~r/\s+/, " ")
  end

  defp section_of(doc), do: read(@deploy) |> between("### Remembered consent grants", " ##") |> then(&(&1 <> doc))

  test "07-deployment (Kassandra LOW #3): the rollout note says a prompt=consent / prompt=login request started on an old node may be skipped during the deploy window" do
    sec = section_of("")
    assert has?(sec, ~r/deploy window/i)
    assert has?(sec, ~r/prompt=consent/) and has?(sec, ~r/prompt=login/)
    assert has?(sec, ~r/started on a node of the previous release/i)
    assert has?(sec, ~r/may be skipped/i)
  end

  test "07-deployment (cycle 1): the section states the device rule, prompt=login, the stored host and the return target" do
    sec = section_of("")

    for {pattern, why} <- [
          {~r/device (state|holder)[^.]*(new|same app)|new device or (a device )?(already )?held by the same app/i, "a skip needs a new device or one held by the same app"},
          {~r/legacy session[^.]*(consent screen|asks)|replace[^.]*consent screen/i, "a device that would REPLACE another session shows the consent screen"},
          {~r/prompt=login/, "prompt=login forces the screen"},
          {~r/stored `client_host`|stored client_host|verified host/i, "the Website column shows the stored host, not the claimed one"},
          {~r/return[s]? to `?\/account\/apps/i, "the sign-in started at /account/apps returns there"}
        ] do
      assert has?(sec, pattern), "the section must say: #{why}"
    end
  end

  test "CHANGELOG (cycle 1): the entry mentions prompt=login, the device rule and the deploy window" do
    c = read(@changelog)
    [_, rest] = String.split(c, "## [Unreleased]", parts: 2)
    entry = rest |> String.split(~r/ ## \[\d/, parts: 2) |> hd() |> between("persistent-consent-grants", "- **")

    for {pattern, why} <- [{~r/no `prompt=login`/, "prompt=login as a reason to ask again"}, {~r/deploy window/i, "the deploy window"}, {~r/legacy session|another session|replace/i, "the device rule"}] do
      assert has?(entry, pattern), "the CHANGELOG entry must mention #{why}"
    end
  end

  test "code review MINOR 1: the moduledoc of Consent no longer claims 'no code without the user's click' and describes the remembered Allow" do
    doc = moduledoc("consent.ex")
    assert has?(doc, "remembered Allow")
    refute has?(doc, "no code exists without the user's click"), "the claim is false since persistent-consent-grants"
    refute has?(doc, "BEFORE any authorization code exists")
    assert has?(doc, "issue_remembered")
  end

  test "code review MINOR 2: the moduledoc and the callback comment of Authorize describe the remembered branch and its decision point" do
    doc = moduledoc("authorize.ex")
    assert has?(doc, "remembered Allow")
    assert has?(doc, "ConsentGrantStore")
    refute has?(doc, "A successful IdP login does NOT issue a code"), "stale claim"
    refute has?(doc, "only after the user clicks Allow"), "stale claim"
    refute has?(File.read!(Path.join(@lib, "authorize.ex")), "after the user's Allow, never here"), "stale comment of request_consent/5"
  end

  test "code review MINOR 3: the revoke step list of ClientStore names the grants delete" do
    src = File.read!(Path.join(@lib, "client_store.ex")) |> String.replace(~r/\s+/, " ")
    assert has?(between(src, "Withdraws an APPROVED client", "After the COMMIT"), "oauth_consent_grants")
  end

  test "code review MINOR 3: 06-runtime shows the skip branch in the callback sequence and the grants delete in the revoke steps" do
    r = read(@runtime)
    assert has?(r, "DELETE oauth_authz_requests, oauth_consent_requests, oauth_consent_grants of the client")
    assert has?(r, ~r/remembered Allow \(oauth_consent_grants[^)]*\)/), "the callback sequence names the remembered-Allow branch"
    assert has?(r, "issue_remembered")
  end

  test "code review MINOR 3: 05-building-blocks no longer says 'consent on every authorization' for Consent" do
    row =
      File.read!(@blocks)
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "| `Nebu.OAuth.Consent`, `ConsentStore`, `ConsentPage`, `Freshness`"))

    assert row, "the Consent row is gone"
    refute has?(row, "consent on every authorization:"), "relaxed by persistent-consent-grants"
    assert has?(row, "remembered Allow")
  end

  test "code review MINOR 3: the gate rows i, y and i / y of 07-deployment say '(relaxed by persistent-consent-grants)'" do
    lines = File.read!(@deploy) |> String.split("\n")

    for key <- ["| i |", "| y |", "| i / y (server-owned) |"] do
      row = Enum.find(lines, &String.starts_with?(&1, key))
      assert row, "gate row #{key} not found"
      assert has?(row, "(relaxed by persistent-consent-grants)"), "gate row #{key} must carry the note"
    end
  end

  test "code review MINOR 4: the moduledoc of Account lists the two new routes" do
    doc = moduledoc("account.ex")
    assert has?(doc, "`GET /account/apps`")
    assert has?(doc, "`POST /account/apps/withdraw`")
  end
end
