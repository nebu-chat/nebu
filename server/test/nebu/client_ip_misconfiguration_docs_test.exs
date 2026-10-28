defmodule Nebu.ClientIPMisconfigurationDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `client-ip-misconfiguration-warnings` (epic oauth-broker, SEC gate 3 G3-2):

    * AC16 - W3: the OpenTofu `check` blocks `client_ip_check.tf` in both reference templates
    * AC17 - W5: "fail-safe" no longer describes the shared bucket in the deploy files
    * AC18 - W5: the "Positive test" blocks in both READMEs and the Stackit RUNBOOK
    * AC19 - W5: `docs/architecture/07-deployment.md` (misconfiguration warnings, activation step 0, group A)
    * AC20 - W5: ADR-033 TP13 / TP14 / AH12
    * AC21 - W5: `follow-ups.md` (rows cf-ci, `as`, `ap6`, the G3-2 status row)

  Only text that the story's D3 / D5 say MUST exist is pinned. `tofu fmt` / `tofu validate` are NOT run by this test (and
  cannot run in the isolated environment: no OpenTofu toolchain in the elixir image); AC15 stays a dev-gate command
  (`ghcr.io/opentofu/opentofu:1.9`, see the story).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @upcloud Path.join(@root, "deploy/tofu/examples/upcloud")
  @stackit Path.join(@root, "deploy/tofu/examples/stackit")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")

  # the nine deploy files D5 lists (UpCloud has no RUNBOOK)
  @deploy_files [
    Path.join(@upcloud, "README.md"),
    Path.join(@upcloud, "terraform.tfvars.example"),
    Path.join(@upcloud, "variables.tf"),
    Path.join(@upcloud, "cloud-init.tftpl"),
    Path.join(@stackit, "README.md"),
    Path.join(@stackit, "RUNBOOK.md"),
    Path.join(@stackit, "terraform.tfvars.example"),
    Path.join(@stackit, "variables.tf"),
    Path.join(@stackit, "cloud-init.tftpl")
  ]

  defp read!(path), do: File.read!(path)
  defp table_row(text, id), do: text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} |"))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  # the text AFTER `marker`, or a failing test with a message (never a MatchError)
  defp after!(text, marker) when is_binary(marker) do
    case String.split(text, marker, parts: 2) do
      [_, rest] -> rest
      _ -> flunk("expected heading / marker not found: #{inspect(marker)}")
    end
  end

  defp after_re!(text, regex) do
    case String.split(text, regex, parts: 2) do
      [_, rest] -> rest
      _ -> flunk("expected heading not found: #{inspect(regex)}")
    end
  end

  # HCL without strings and comments: references and block keywords are looked up here only
  defp hcl_code(src), do: src |> String.replace(~r/"(?:[^"\\]|\\.)*"/, "\"\"") |> String.replace(~r/(#|\/\/)[^\n]*/, "")

  # every `condition = <expr>` of the file (up to the next `error_message`), whitespace collapsed
  defp conditions(src) do
    Regex.scan(~r/condition\s*=\s*(.*?)\s*error_message/s, flat(src), capture: :all_but_first) |> Enum.map(fn [c] -> c end)
  end

  # HCL / tftpl comments: drop the leading `#` of every line, then collapse whitespace (a phrase may wrap)
  defp flat_comments(text), do: text |> String.replace(~r/^\s*#+ ?/m, "") |> flat()

  defp check_src!(dir) do
    path = Path.join(dir, "client_ip_check.tf")
    assert File.exists?(path), "#{Path.relative_to(path, @root)} missing"
    read!(path)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC16 - W3: OpenTofu check blocks
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC16 - client_ip_check.tf (OpenTofu check blocks, D3)" do
    test "both examples ship a client_ip_check.tf with a `check \"...\"` block that names lb_real_ip_cidrs and oauth_enabled" do
      for dir <- [@upcloud, @stackit] do
        path = Path.join(dir, "client_ip_check.tf")
        assert File.exists?(path), "#{path} missing"
        src = read!(path)
        assert src =~ ~r/^check\s+"[^"]+"\s*\{/m, "#{path}: a `check \"...\" {` block is required"
        assert src =~ "lb_real_ip_cidrs"
        assert src =~ "oauth_enabled"
        assert src =~ "NOT safe for availability", "#{path}: the message must say `safe against spoofing, NOT safe for availability`"
        assert src =~ "safe against spoofing"
      end
    end

    test "UpCloud: assert 1 = NOT (alb or dynamic AND empty lb_real_ip_cidrs), assert 2 = alb or dynamic (TCP-mode, ap3)" do
      src = check_src!(@upcloud)
      assert length(Regex.scan(~r/\bassert\s*\{/, hcl_code(src))) == 2, "exactly two asserts (HTTP-mode without realip, TCP-mode frontend)"

      [first, second] = conditions(src)

      negated_and = ~r/^!\(\s*contains\(\["alb", "dynamic"\], var\.tls_mode\)\s*&&\s*length\(var\.lb_real_ip_cidrs\)\s*==\s*0\s*\)$/
      de_morgan = ~r/^!contains\(\["alb", "dynamic"\], var\.tls_mode\)\s*\|\|\s*length\(var\.lb_real_ip_cidrs\)\s*(>|!=)\s*0$/

      assert first =~ negated_and or first =~ de_morgan,
             "assert 1 must be the NEGATION of (alb/dynamic && empty list) (or its De Morgan form), got: #{first}"

      assert second =~ ~r/^contains\(\["alb", "dynamic"\], var\.tls_mode\)$/, "assert 2: got #{second}"
      assert src =~ "ap3"
      assert src =~ "PROXY protocol"
      assert src =~ ~r/Do NOT enable `?oauth_enabled/
      assert src =~ "Reverse-proxy routes, client-IP trust and access logs"
    end

    test "Stackit: only the NEGATED alb / empty lb_real_ip_cidrs assert; no condition about acme or none (NLB source address unverified, ap7)" do
      src = check_src!(@stackit)
      assert length(Regex.scan(~r/\bassert\s*\{/, hcl_code(src))) == 1

      [cond] = conditions(src)

      negated_and = ~r/^!\(\s*var\.tls_mode\s*==\s*"alb"\s*&&\s*length\(var\.lb_real_ip_cidrs\)\s*==\s*0\s*\)$/
      de_morgan = ~r/^var\.tls_mode\s*!=\s*"alb"\s*\|\|\s*length\(var\.lb_real_ip_cidrs\)\s*(>|!=)\s*0$/

      assert cond =~ negated_and or cond =~ de_morgan, "the Stackit condition must be the NEGATION of (alb && empty list), got: #{cond}"
      refute cond =~ ~r/acme|none/, "no condition about acme / none"
      assert src =~ ~r/Do NOT enable `?oauth_enabled/
    end

    test "the checks reference only var.* and local.* roots, declare no data block and no precondition / postcondition / validation" do
      for dir <- [@upcloud, @stackit] do
        code = dir |> check_src!() |> hcl_code()

        roots =
          Regex.scan(~r/(?<![\w.\-])([a-z][a-z0-9_]*)\.[a-z_]/, code, capture: :all_but_first)
          |> List.flatten()
          |> Enum.uniq()

        assert roots -- ["var", "local"] == [], "#{dir}: only var.* / local.* may be referenced, found roots #{inspect(roots)}"
        refute code =~ ~r/\bdata\s+"/
        refute code =~ ~r/\b(precondition|postcondition|validation)\s*\{/, "a check block warns; it must not add blocking conditions"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC17 - W5: "fail-safe" wording
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC17 - 'fail-safe' no longer describes the shared bucket (D5)" do
    test "no line of the nine deploy files describes the shared bucket as fail-safe (the four story patterns)" do
      pattern = ~r/shared bucket, fail-safe|bucket \(fail-safe|one shared bucket,\s*$|fail-safe\)/

      offenders =
        for path <- @deploy_files,
            {line, n} <- path |> read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(pattern, line),
            do: "#{Path.relative_to(path, @root)}:#{n}"

      assert offenders == [], "still describes the shared bucket as fail-safe: #{inspect(offenders)}"
    end

    test "every deploy file that talks about an empty lb_real_ip_cidrs says `NOT safe for availability`" do
      offenders =
        for path <- @deploy_files,
            text = read!(path),
            text =~ "lb_real_ip_cidrs" and text =~ ~r/empty/i,
            not (flat_comments(text) =~ "NOT safe for availability"),
            do: Path.relative_to(path, @root)

      assert offenders == [], "missing `NOT safe for availability`: #{inspect(offenders)}"
    end

    test "the nginx comment blocks of both cloud-init templates and the lb_real_ip_cidrs descriptions carry the new wording" do
      for dir <- [@upcloud, @stackit] do
        assert flat_comments(read!(Path.join(dir, "cloud-init.tftpl"))) =~ "safe against spoofing, NOT safe for availability"
        assert read!(Path.join(dir, "variables.tf")) =~ "NOT safe for availability"
        assert flat_comments(read!(Path.join(dir, "terraform.tfvars.example"))) =~ "NOT safe for availability"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC18 - W5: Positive test blocks
  # ════════════════════════════════════════════════════════════════════════════

  defp positive_block(text) do
    marker = "Positive test (required before `oauth_enabled`"
    assert text =~ marker, "the block `**#{marker}, GATING).**` is missing"
    [before, rest] = String.split(text, marker, parts: 2)
    assert before =~ "Negative test (required before `oauth_enabled`", "the Positive test block must come after the Negative test block"
    rest |> String.split(~r/\n## /, parts: 2) |> hd() |> String.slice(0, 6_000)
  end

  describe "AC18 - Positive test block (GATING)" do
    for {label, rel} <- [
          {"UpCloud README", "deploy/tofu/examples/upcloud/README.md"},
          {"Stackit README", "deploy/tofu/examples/stackit/README.md"},
          {"Stackit RUNBOOK", "deploy/tofu/examples/stackit/RUNBOOK.md"}
        ] do
      test "#{label}: DISTINCT last_seen_ip, hammered login, tofu plan check, `client IP:` prefix, do NOT enable" do
        block = positive_block(read!(Path.join(@root, unquote(rel))))
        f = flat(block)

        assert f =~ "GATING"
        assert f =~ "DISTINCT"
        assert f =~ "last_seen_ip"
        assert f =~ "POST /_matrix/client/v3/login"
        assert f =~ "tofu plan"
        assert f =~ "client IP:"
        assert f =~ "do NOT enable"
        assert f =~ "NEVER be silenced by widening"
        assert f =~ "W1 cannot fire"
        assert f =~ ~r/LB|load balancer/i
      end
    end
  end

  describe "AC18 - link integrity" do
    test "the READMEs keep the heading that the check messages point to" do
      for dir <- [@upcloud, @stackit] do
        assert read!(Path.join(dir, "README.md")) =~ ~r/^## Reverse-proxy routes, client-IP trust and access logs/m
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC19 - W5: 07-deployment.md
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC19 - 07-deployment.md" do
    test "'Client IP behind a reverse proxy' documents the three warnings, what they prove and that their absence does not replace the positive test" do
      d = read!(@deploy)
      sub = after_re!(d, ~r/^###\s+Client IP behind a reverse proxy \(`NEBU_TRUSTED_PROXY_CIDRS`\)[^\n]*\n/m)
      sub = sub |> String.split(~r/^### /m, parts: 2) |> hd()
      f = flat(sub)

      assert f =~ "Misconfiguration warnings (story client-ip-misconfiguration-warnings)"
      assert f =~ "client IP: a request carried X-Forwarded-For"
      assert f =~ ~r/client IP: all .{1,12}devices/
      assert f =~ "tofu plan"
      assert f =~ ~r/does NOT replace the positive test|absence[^.]{0,80}proves nothing/
      assert f =~ ~r/\bcheck\b/
      assert f =~ "single NAT"
      assert f =~ "NEBU_TRUSTED_PROXY_CIDRS"
    end

    test "activation step 0 requires a clean `tofu plan` check and no W2 `client IP: all` line in the last 24 h (W1 only explained); their absence does NOT replace the positive test" do
      d = read!(@deploy)
      steps = after!(d, "### Activation steps and smoke test")
      step0 = steps |> String.split(~r/\n1\. /, parts: 2) |> hd() |> flat()

      assert step0 =~ "client IP: all"
      assert step0 =~ "must never be silenced by widening `NEBU_TRUSTED_PROXY_CIDRS`"
      assert step0 =~ "tofu plan"
      assert step0 =~ "24 h"
      assert step0 =~ "does NOT replace the positive test"
    end

    test "group A has a bullet: no W2 line in the server log, no client-IP check warning in `tofu plan`, a W1 line only explained, never silenced by widening" do
      d = read!(@deploy)
      rest = after!(d, "**A. Load balancer, proxy and cluster**")
      a = rest |> String.split(~r/\n\*\*[B-Z]\. /, parts: 2) |> hd() |> flat()

      assert a =~ "No W2 line (`client IP: all"
      assert a =~ "`tofu plan`"
      assert a =~ "a W1 line (`client IP: a request carried X-Forwarded-For`) only needs an explanation"
      assert a =~ "NEVER be silenced by widening `NEBU_TRUSTED_PROXY_CIDRS`"
    end

    test "the already pinned phrases of adr_033_test.exs survive (additive edits only)" do
      d = read!(@deploy)
      for phrase <- ["203.0.113.99", "NEGATIVE test", "over IPv4 AND over IPv6", "empty or invalid list never allows spoofing", "too-broad list does", "verified to APPEND", "LB-shared bucket", "Privacy and retention"] do
        assert d =~ phrase, "pinned phrase vanished: #{phrase}"
      end

      refute d =~ ~r/Nebu cannot detect a wrong list\. Trusting/
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC20 - W5: ADR-033 TP13 / TP14 / AH12
  # ════════════════════════════════════════════════════════════════════════════

  defp adr_item(text, id) do
    case Regex.run(~r/- \*\*#{id}\b[^\n]*(?:\n(?!\s*- \*\*)  [^\n]+)*/, text) do
      [block] -> flat(block)
      nil -> flunk("#{id} not found in ADR-033")
    end
  end

  describe "AC20 - ADR-033" do
    test "TP13: one throttled WARNING per node and 10 minutes for an untrusted peer's X-Forwarded-For; never an address or header value" do
      tp13 = adr_item(read!(@adr), "TP13")
      assert tp13 =~ "EXCEPT one throttled WARNING per node and 10 minutes"
      assert tp13 =~ "untrusted peer sends `X-Forwarded-For`"
      assert tp13 =~ "client-ip-misconfiguration-warnings"
      assert tp13 =~ "no line ever carries an address or a header value"
    end

    test "TP14: keeps its pinned sentences and adds the warn-but-never-block statement" do
      tp14 = adr_item(read!(@adr), "TP14")
      for kept <- ["/32", "127.0.0.1", "rootless", "APPEND", "ap4"], do: assert(tp14 =~ kept, "TP14 lost #{kept}")
      assert tp14 =~ "Nebu warns where a misconfiguration is reliably visible"
      assert tp14 =~ "W1"
      assert tp14 =~ "W2"
      assert tp14 =~ "W3"
      assert tp14 =~ "activation is never blocked in code"
    end

    test "AH12 names the consent cap (consent 20 per source, 300 in-flight logins, 100 pending registrations)" do
      ah12 = adr_item(read!(@adr), "AH12")
      assert ah12 =~ "consent 20"
      assert ah12 =~ "300"
      assert ah12 =~ "100"
    end

    test "the refuted sentence `Nebu cannot detect a wrong list. Trusting` stays out of the ADR" do
      refute read!(@adr) =~ ~r/Nebu cannot detect a wrong list\. Trusting/
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC21 - W5: follow-ups.md
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC21 - follow-ups.md" do
    test "the section header and the rows cf, cg, ch, ci exist exactly once, all non-gating" do
      f = read!(@followups)
      assert f =~ ~r/^## From story client-ip-misconfiguration-warnings \(2026-10-13\)/m

      assert f =~ "## From story legacy-sso-redirect-confirmation (2026-10-13)"
      {legacy_at, _} = :binary.match(f, "## From story legacy-sso-redirect-confirmation (2026-10-13)")
      {new_at, _} = :binary.match(f, "## From story client-ip-misconfiguration-warnings (2026-10-13)")
      assert new_at > legacy_at, "the new section goes at the end"

      for id <- ~w(cf cg ch ci) do
        rows = f |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| #{id} |"))
        assert length(rows) == 1, "row #{id} must exist exactly once, found #{length(rows)}"
        assert hd(rows) =~ "non-gating", "row #{id} is non-gating"
      end

      assert table_row(f, "cf") =~ ~r/dashboard/i
      assert table_row(f, "cg") =~ "X-Real-IP"
      assert table_row(f, "ch") =~ "config_update_mutable"
      assert table_row(f, "ci") =~ "ap7"
    end

    test "the reserved ids co and cp stay untouched by this story (their rows belong to legacy-sso-redirect-confirmation)" do
      f = read!(@followups)
      assert f =~ "## From story client-ip-misconfiguration-warnings (2026-10-13)", "the new section header is missing"
      {new_at, _} = :binary.match(f, "## From story client-ip-misconfiguration-warnings (2026-10-13)")
      after_header = binary_part(f, new_at, byte_size(f) - new_at)
      refute after_header =~ ~r/^\| (co|cp) \|/m
    end

    test "row `as` names the consent cap in its small-global-caps sentence" do
      as = table_row(read!(@followups), "as") || flunk("row as missing")
      assert as =~ "consent 20"
    end

    test "row `ap6` gets the appended availability note" do
      ap6 = table_row(read!(@followups), "ap6") || flunk("row ap6 missing")
      assert ap6 =~ "NOT for availability"
      assert ap6 =~ "G3-2"
    end

    test "the G3-2 status row names this story and keeps the positive test MANUAL and gating" do
      row = read!(@followups) |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| gate G3-2")) || flunk("G3-2 status row missing")
      assert row =~ "client-ip-misconfiguration-warnings"
      assert row =~ "MANUAL"
    end
  end
end
