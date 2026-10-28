defmodule Nebu.OAuth.AdminOAuthSwitchDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `admin-oauth-switch`, AC9: the documentation no longer says that the `oauth_*` keys can
  be written by SQL only, describes the Admin UI switch (flip step, protection, audit, cache, status, honest limits), lists the
  manual per-browser check of the checkbox flow and the rollback rehearsal on a running instance, and records the follow-up rows.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @blocks Path.join(@root, "docs/architecture/05-building-blocks.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @tls_readme Path.join(@root, "dev/tls/README.md")
  @tls_script Path.join(@root, "dev/tls/oauth.sh")
  @readme Path.join(@root, "README.md")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  # the text between two headings / markers (the pins below hold for the section, not for anything anywhere in the file)
  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "no document claims any more that there is no Admin UI writer for the oauth_* keys" do
    for p <- [@deploy, @adr, @readme, @tls_readme, @tls_script, @followups] do
      t = read(p)
      refute t =~ ~r/no Admin UI writer for/i, "#{p}"
      refute t =~ ~r/there is NO Admin UI writer/i, "#{p}"
      refute t =~ ~r/Admin UI writer for `?oauth_\*`? keys?: SQL only/i, "#{p}"
      refute t =~ ~r/the `ConfigController` allowlist has none/i, "#{p}"
    end
  end

  test "07-deployment: the section 'The Admin UI switch' (fields, protection, acknowledgement, audit, cache) and the flip step (Admin UI OR SQL)" do
    d = read(@deploy)
    sec = between(d, "### The Admin UI switch (story admin-oauth-switch)", "### Preconditions")
    assert sec =~ "`/admin/config`"
    assert sec =~ "OAuth 2.0 authorization server"
    assert sec =~ "Save OAuth settings"
    assert sec =~ "I have read the activation checklist"
    assert sec =~ "`oauth_switch_changed`"
    assert sec =~ "fresh sign-in"
    assert sec =~ "`NEBU_OAUTH_CONFIG_CACHE_MS`"
    assert sec =~ "kill switch"
    assert sec =~ "Acknowledgement"

    steps = between(d, "### Activation steps and smoke test", "2. Verify:")
    assert steps =~ "Flip"
    assert steps =~ ~r/Admin UI OR SQL|Admin UI or SQL/
    assert steps =~ "Rollback: uncheck the checkbox and save"
    # the SQL path stays documented (emergency, no Admin UI, IdP down)
    assert steps =~ "INSERT INTO server_config"

    kill = between(d, "### Kill switch, caches and rollback", "**Rate limits in this area")
    assert kill =~ "uncheck"
    assert kill =~ "oauth_switch_changed"
  end

  test "07-deployment: the status list and its honest limits; the manual group D lists the checkbox flow per browser and the rollback on a running instance" do
    d = read(@deploy)
    sec = between(d, "### The Admin UI switch (story admin-oauth-switch)", "### Preconditions")
    assert sec =~ "`NEBU_TRUSTED_PROXY_CIDRS` is empty"
    assert sec =~ "cannot see the load balancer"
    assert sec =~ "positive client-IP test"
    assert sec =~ "None of this blocks saving and none of it says that OAuth is ready"

    group_d = between(d, "**D. Admin**", "**E. Operator rehearsals")
    bullet = between(group_d, "- **OAuth switch checkbox flow", "- Registrations UI")
    for word <- ["Safari", "Firefox", "Chrome", "rollback on a running instance", "acknowledgement", "oauth_switch_changed", "fetch()", "VoiceOver", "320 px"] do
      assert bullet =~ word, word
    end
  end

  test "ADR-033: the section 'Admin UI switch' with the decisions AS1-AS12, the audit asymmetry and the cache race" do
    a = read(@adr)
    assert a =~ "## Admin UI switch (story admin-oauth-switch)"
    sec = between(a, "## Admin UI switch (story admin-oauth-switch)", "## Legacy SSO redirect confirmation (epic SEC gate 3")

    for n <- 1..12, do: assert(sec =~ "**AS#{n} ", "AS#{n}")

    assert sec =~ "`oauth_switch_changed`"
    assert sec =~ "`Nebu.OAuth.SwitchStore`"
    assert sec =~ "`unaudited_ok`"
    assert sec =~ "kill switch"
    assert sec =~ "bounded staleness"
    assert sec =~ "SO7"
  end

  test "05-building-blocks and 08-concepts name the new modules and the control" do
    b = read(@blocks)
    assert b =~ "`Nebu.Admin.OAuthSwitch`"
    assert b =~ "`Nebu.OAuth.SwitchStore`"
    assert b =~ "`POST /admin/config/oauth-switch`"
    c = read(@concepts)
    assert c =~ "`admin-oauth-switch`"
    assert c =~ "`oauth_switch_changed`"
  end

  test "the local dev helper stays and points at the Admin UI as the other way" do
    assert File.exists?(@tls_script)
    assert File.read!(@tls_script) =~ "Admin UI"
    t = read(@tls_readme)
    assert t =~ "Admin UI"
    assert t =~ "OAuth 2.0 authorization server"
    assert t =~ "make dev-tls-oauth-on"
  end

  test "follow-ups: the story's rows da-dc and the status line" do
    f = read(@followups)
    assert f =~ "admin-oauth-switch"
    assert f =~ "| da |"
    assert f =~ "| db |"
    assert f =~ "| dc |"
    assert f =~ ~r/gate da|Admin UI switch/
  end
end
