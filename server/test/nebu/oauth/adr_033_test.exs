defmodule Nebu.OAuth.Adr033Test do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval`, AC8: ADR-033
  "Nebu ist Authorization Server (Broker)" must exist and document the decision.
  Static content check (no DB, no network).
  """
  use ExUnit.Case, async: true

  @adr Path.expand(
         "../../../../docs/architecture/adr/ADR-033-authorization-server-broker-model.md",
         __DIR__
       )

  # ADR index of record: the decisions table in the arc42 chapter 9 (one row per ADR).
  @index Path.expand("../../../../docs/architecture/09-decisions.md", __DIR__)

  setup do
    assert File.exists?(@adr), "ADR-033 not found at #{@adr}"
    {:ok, text: File.read!(@adr)}
  end

  test "has the ADR-033 title and a Status/Context/Decision structure", %{text: t} do
    assert t =~ ~r/^# ADR-033\b.*Authorization Server.*Broker/mi, "title must name the decision (Authorization Server / Broker)"
    assert t =~ ~r/^## Status/m
    assert t =~ ~r/^## Context/m
    assert t =~ ~r/^## (Decision|Entscheidung)/m
  end

  test "documents the roles: Nebu = Authorization Server + Resource Server, IdP = identity provider only", %{text: t} do
    assert t =~ ~r/Authorization Server/i
    assert t =~ ~r/Resource Server/i
    assert t =~ ~r/Broker/i
    assert t =~ ~r/IdP|Identity Provider/i
    assert t =~ ~r/\bO2\b/, "must reference the broker model by its spec name \"O2\""
  end

  test "documents token issuance: only Nebu issues Matrix tokens, IdP JWTs are not accepted as Bearer (legacy exception)", %{text: t} do
    assert t =~ ~r/access/i and t =~ ~r/refresh/i
    assert t =~ ~r/legacy/i
    assert t =~ ~r/Bearer/i
  end

  test "documents scope management is Nebu-internal and the IdP sees a single Nebu client", %{text: t} do
    assert t =~ ~r/scope/i
    assert t =~ ~r/single|ein(en)? (einzigen )?Client|one client/i
  end

  test "documents the https-for-all-URLs rule as a Nebu rule stricter than RFC 6749 / RFC 8414", %{text: t} do
    assert t =~ ~r/https[- ]for[- ]all[- ]URLs/i, "must name the rule \"https-for-all-URLs\""
    assert t =~ ~r/RFC 6749/, "must contrast the rule with RFC 6749"
    assert t =~ ~r/stricter|strenger/i
  end

  test "documents the implications: legacy /refresh + workers deprecated, coexistence is temporary", %{text: t} do
    assert t =~ ~r/coexist|Koexistenz/i
    assert t =~ ~r/refresh/i
  end

  test "is registered in the ADR index (docs/architecture/09-decisions.md decisions table)" do
    assert File.exists?(@index), "ADR index #{@index} not found"

    assert File.read!(@index) =~ ~r/^\|\s*\[?ADR-033\]?(\([^)]*ADR-033[^)]*\))?\s*\|/m,
           "ADR-033 must have its own row in the 09-decisions.md table"
  end

  test "documents the pending-row protection: TTL purge, cap, 503, RLS-confined DELETE, pagination", %{text: t} do
    assert t =~ ~r/oauth_pending_ttl_days/
    assert t =~ ~r/oauth_pending_cap/
    assert t =~ ~r/OAuthPendingPurgeWorker/
    assert t =~ ~r/FOR UPDATE SKIP LOCKED/
    assert t =~ ~r/503/ and t =~ ~r/Retry-After/
    assert t =~ ~r/row level security/i
    assert t =~ ~r/never purged|NEVER purged/
    assert t =~ ~r/dedup hit/i
    assert t =~ ~r/paginated/i
  end

  test "documents the logo decision: no passive contact, strict CSP, exact origins on click, trade-off", %{text: t} do
    assert t =~ ~r/Client-hosted logos/
    assert t =~ ~r/img-src 'self' data:/
    assert t =~ ~r/logos=1/
    assert t =~ ~r/exact origins/i
    assert t =~ ~r/Trade-off/i
  end

  test "documents the cycle-4 security decisions: one issuer, DB invariants, retention, rate limits, gate items", %{text: t} do
    assert t =~ ~r/Discovery: one issuer/
    assert t =~ ~r/auth_issuer/
    assert t =~ ~r/legacy bypass/i
    assert t =~ ~r/oauth_clients_decision_check/
    assert t =~ ~r/immutable|can never be rewritten/i
    assert t =~ ~r/oauth_pending_host_cap/
    assert t =~ ~r/Retention of first-registrant data/
    assert t =~ ~r/Registration rate limits/
    assert t =~ ~r/Gate items before `oauth_enabled`/
    assert t =~ ~r/Trusted-proxy client-IP resolution/
    assert t =~ ~r/Bulk reject/
    assert t =~ ~r/Public-suffix/
    assert t =~ ~r/ONE database transaction/
  end

  # ── story oauth-authorize-idp-delegation-code, AC17 (RED until the docs step) ──

  test "story 2: section 'Authorization endpoint, IdP delegation and codes (story 2)' records D1-D23", %{text: t} do
    assert t =~ ~r/^##+\s+Authorization endpoint, IdP delegation and codes \(story 2\)/m
    [_, section] = String.split(t, ~r/^##+\s+Authorization endpoint, IdP delegation and codes \(story 2\)[^\n]*\n/m, parts: 2)
    section = section |> String.split(~r/^## /m, parts: 2) |> hd()

    for n <- 1..23, do: assert(section =~ ~r/\bD#{n}\b/, "D#{n} missing in the story-2 ADR section")
    assert section =~ "/_matrix/client/v3/login/sso/redirect/oidc", "D1: the shared callback deviation"
    assert section =~ ~r/oauth_authz_requests/ and section =~ ~r/oauth_codes/
    assert section =~ ~r/SsoStore/, "D3: why the node-local SsoStore is not used"
    assert section =~ ~r/nebu_oa_/, "D4: binding cookie"
    assert section =~ ~r/response_mode/, "D10"
    assert section =~ ~r/reuse/i, "D17"
  end

  test "story 2 (D23): ADR records the story-3 obligation to issue a Nebu id_token (iss, aud, nonce)", %{text: t} do
    assert t =~ ~r/id_token/
    assert t =~ ~r/openid_requested/
    assert t =~ ~r/story 3/i
    assert t =~ ~r/\baud\b/ and t =~ ~r/client_id/ and t =~ ~r/nonce/
  end

  test "story 2: gate item 1 (trusted proxy) also covers the authorize/callback buckets", %{text: t} do
    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert gates =~ ~r/authorize/i and gates =~ ~r/callback/i
  end

  # story 3 (oauth-token-endpoint, Trap 13): changed deliberately. The story-2 assertion
  # "`/oauth2/token` ... not implemented" became wrong by design (the token endpoint exists now);
  # it is replaced by the story-3 assertions in the "AC20 (story 3)" test below.
  # story 4 (oauth-token-revocation-logout, AC13 / Trap 7): changed deliberately again. The
  # "/oauth2/revoke not implemented" part became wrong by design (revoke is live); the story-4
  # assertions live in the "AC13 (story 4)" tests below.
  test "story 2: matrix-api-scope.md documents GET /oauth2/authorize and the callback branch; revoke no longer 'not implemented'" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    assert scope =~ ~r/\|\s*GET\s*\|\s*`\/oauth2\/authorize`/
    assert scope =~ ~r/sso\/redirect\/oidc[^\n]*OAuth/i
    refute scope =~ ~r/`\/oauth2\/revoke`[^\n]*not implemented/i
  end

  # ── story oauth-token-endpoint (story 3), AC20 (RED until the docs step) ──

  defp story3_section(t) do
    assert t =~ ~r/^##+\s+Token endpoint, sessions, refresh and id_token \(story 3\)/m,
           "ADR-033 needs the section 'Token endpoint, sessions, refresh and id_token (story 3)'"

    [_, section] = String.split(t, ~r/^##+\s+Token endpoint, sessions, refresh and id_token \(story 3\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  test "AC20 (story 3): ADR section records T1-T33", %{text: t} do
    section = story3_section(t)
    for n <- 1..33, do: assert(section =~ ~r/\bT#{n}\b/, "T#{n} missing in the story-3 ADR section")
  end

  test "AC20 (story 3): data model, refresh semantics, key decision with rejected alternatives", %{text: t} do
    section = story3_section(t)
    assert section =~ "auth_api" and section =~ "session_expires_at", "T2/T3 data model"
    assert section =~ "oauth_code_hash", "T8 proof-bound code-reuse revocation"
    assert section =~ ~r/reuse/i
    assert section =~ "ES256"
    for alt <- ~w(HS256 RS256 EdDSA), do: assert(section =~ alt, "rejected alternative #{alt} must be recorded (T17)")
    assert section =~ "oauth_signing_keys"
    assert section =~ "jwks_uri"
  end

  # test review (f): structured, not trivially satisfiable substring checks: each rule must be ONE
  # sentence/table row (same line) carrying its condition and its consequence.
  test "AC20 (story 3): error mapping rules: 5xx body {} without error member, never 429 on refresh, :unknown => 503", %{text: t} do
    section = story3_section(t)
    lines = String.split(section, "\n")
    has = fn res -> Enum.any?(lines, fn l -> Enum.all?(res, &Regex.match?(&1, l)) end) end

    assert has.([~r/5xx/, ~r/`\{\}`/, ~r/Retry-After/, ~r/`error`/]),
           "T20: one line stating that every 5xx carries Retry-After and the body `{}` without an `error` member"

    assert has.([~r/\b429\b/, ~r/refresh_token/, ~r/\b503\b/]),
           "T21: one line stating that grant_type=refresh_token is never answered 429 (503 instead)"

    assert has.([~r/:unknown/, ~r/\b503\b/]), "T22: one line stating that an unreadable config (:unknown) answers 503"
    assert has.([~r/oidc-client-ts|matrix-js-sdk/, ~r/logout|logs? (the client )?out/i]), "T20 rationale (oracle C1)"
  end

  test "AC20 (story 3): deliberate deviations (C10 proof-gated code-reuse revocation, C8 legacy-to-legacy reuse) and the issuer-path constraint", %{text: t} do
    section = story3_section(t)
    assert section =~ ~r/deviation/i
    assert section =~ ~r/4\.1\.2/, "C10: the weakened RFC 6749 4.1.2 SHOULD"
    assert section =~ ~r/legacy-to-legacy/i, "C8: legacy-to-legacy device reuse deviation"
    assert section =~ "/.well-known/openid-configuration", "T31"
    assert section =~ ~r/issuer[^\n]*path|path[^\n]*issuer/i, "T31: the issuer must have an empty path"
    assert section =~ ~r/JWT/ and section =~ ~r/legacy/i, "T25: legacy IdP JWT excluded for OAuth devices"
  end

  # story 4: title changed (revoke is no longer 404); the assertions still hold for the story-4 gate text.
  test "AC20 (story 3): gate items mention /oauth2/revoke, story 4 and the oauth_token buckets", %{text: t} do
    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert gates =~ "/oauth2/revoke"
    assert gates =~ ~r/story 4/i
    assert gates =~ ~r/oauth_token/, "trusted proxy (item 1) also covers the oauth_token* buckets"
  end

  test "AC20 (story 3): matrix-api-scope.md: token implemented, jwks row, /refresh legacy only (revoke: story 4)" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    assert scope =~ ~r/\|\s*POST\s*\|\s*`\/oauth2\/token`\s*\|\s*✅/, "the /oauth2/token row is implemented (✅)"
    refute scope =~ ~r/`\/oauth2\/token`[^\n]*not implemented/i
    [token_row] = Regex.run(~r/^[^\n]*`\/oauth2\/token`[^\n]*$/m, scope)
    assert token_row =~ "authorization_code" and token_row =~ "refresh_token"
    assert token_row =~ "429", "the no-429-on-refresh rule is documented"
    assert scope =~ ~r/\|\s*GET\s*\|\s*`\/oauth2\/jwks`\s*\|\s*✅/
    # story 4 (Trap 7): changed deliberately: revoke is implemented now (see "AC13 (story 4)").
    refute scope =~ ~r/`\/oauth2\/revoke`[^\n]*not implemented/i
    assert scope =~ ~r/`\/_matrix\/client\/v3\/refresh`[^\n]*legacy sessions only/i
    assert scope =~ "/.well-known/openid-configuration"
  end

  test "AC20 (story 3): follow-ups.md story-3 section with the new gate items (l) and (m)" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert f =~ ~r/^## .*oauth-token-endpoint/m
    [_, s3] = String.split(f, ~r/^## .*oauth-token-endpoint[^\n]*\n/m, parts: 2)
    s3 = s3 |> String.split(~r/^## /m, parts: 2) |> hd()
    assert s3 =~ ~r/trusted[- ]proxy/i and s3 =~ "oauth_jwks", "(a) item 1 covers oauth_token*/oauth_jwks"
    assert s3 =~ ~r/rotation/i and s3 =~ ~r/runbook/i and s3 =~ "not_after", "(b) signing-key rotation runbook"
    assert s3 =~ "display_name", "(c) OAuth device display names"
    assert s3 =~ ~r/m\.oauth|UIA/, "(d) UIA for OAuth sessions"
    assert s3 =~ ~r/legacy-to-legacy/i and s3 =~ ~r/deviation/i, "(f) the pre-existing spec deviation"
    assert f =~ ~r/(\(l\)|\|\s*l\s*\|)[^\n]*refresh token/i, "gate item (l): detect the missing IdP RT at the callback"
    assert f =~ ~r/(\(m\)|\|\s*m\s*\|)[^\n]*(proxy|nginx|route)/i, "gate item (m): reverse-proxy routes for /oauth2/ and openid-configuration"
  end

  test "story 2: follow-ups.md gains the story-2 notes (trusted proxy, consent D5, I-1, prompt_values_supported, id_token)" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert f =~ ~r/^## .*oauth-authorize-idp-delegation-code/m
    [_, s2] = String.split(f, ~r/^## .*oauth-authorize-idp-delegation-code[^\n]*\n/m, parts: 2)
    assert s2 =~ ~r/trusted[- ]proxy/i
    assert s2 =~ ~r/consent/i
    assert s2 =~ ~r/prompt_values_supported/
    assert s2 =~ ~r/id_token/
    assert s2 =~ ~r/oauth_enabled/
  end

  test "relates to existing ADRs (018 inline SQL / 020 cluster safety / 022 OIDC bootstrap)", %{text: t} do
    assert t =~ "ADR-022"
  end

  # ── story oauth-token-revocation-logout (story 4), AC13 (RED until the docs step) ──

  defp story4_section(t) do
    assert t =~ ~r/^##+\s+Token revocation and logout \(story 4\)/m,
           "ADR-033 needs the section 'Token revocation and logout (story 4)'"

    [_, section] = String.split(t, ~r/^##+\s+Token revocation and logout \(story 4\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  defp line_with?(text, res), do: text |> String.split("\n") |> Enum.any?(fn l -> Enum.all?(res, &Regex.match?(&1, l)) end)

  test "AC13 (story 4): ADR section records R1-R24", %{text: t} do
    section = story4_section(t)
    for n <- 1..24, do: assert(section =~ ~r/\bR#{n}\b/, "R#{n} missing in the story-4 ADR section")
  end

  test "AC13 (story 4): R4 conforms to the Matrix spec (SHOULD still revoke), NOT a deviation; R16 is the deviation", %{text: t} do
    section = story4_section(t)
    assert line_with?(section, [~r/\bR4\b/, ~r/conforms to the Matrix spec/i, ~r/SHOULD still revoke/])
    refute line_with?(section, [~r/\bR4\b/, ~r/deviation/i]), "R4 is worded as conformance (oracle gate), not as a deviation"
    assert line_with?(section, [~r/\bR16\b/, ~r/deviation/i, ~r/\/logout/]), "R16 (RESOLVED by legacy-logout-per-device) still names the /logout deviation"
  end

  test "AC13 (story 4): R2 contrast with T8/T11, R13 kill-switch exemption, unreachable 401/400, 200 {} rationale", %{text: t} do
    section = story4_section(t)
    assert line_with?(section, [~r/\bR2\b/, ~r/device/i]) and section =~ ~r/\bT11\b/ and section =~ ~r/\bT8\b/
    assert line_with?(section, [~r/\bR13\b/, ~r/:unknown/, ~r/\b503\b/]), "R13: only :unknown => 503"
    assert section =~ ~r/exempt/i, "R13: revoke is exempt from the T22 kill switch"
    assert section =~ "invalid_client" and section =~ "unsupported_token_type", "R7: the unreachable errors"
    assert section =~ ~r/`?200 \{\}`?/, "R6: 200 {} (oracle O3)"
    assert section =~ "oidc-client-ts"
  end

  test "AC13 (story 4): story-2/3 'stays unrouted' texts are marked, T22 points at the exemption, gate paragraph updated", %{text: t} do
    refute t =~ ~r/`\/oauth2\/revoke` stays unrouted(?!\s*\(until story 4\))/, "story-2/3 'stays unrouted' must get '(until story 4)' or be updated"
    assert t =~ ~r/`\/oauth2\/revoke` is exempt, story 4 R13/, "T22 text gets '(`/oauth2/revoke` is exempt, story 4 R13)'"
    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert gates =~ ~r/Story 4 update/
    assert gates =~ ~r/every advertised endpoint exists/i
    assert gates =~ ~r/gate items 1, h, i, l, m, n, r\b/, "AC13 gate text: oauth_enabled stays false because of gate items 1, h, i, l, m, n, r"
  end

  test "AC13 (story 4): matrix-api-scope.md: revoke ✅, /logout OAuth current device only, /logout/all ✅" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    assert scope =~ ~r/\|\s*POST\s*\|\s*`\/oauth2\/revoke`\s*\|\s*✅/, "the /oauth2/revoke row is implemented (✅)"
    [revoke_row] = Regex.run(~r/^[^\n]*`\/oauth2\/revoke`[^\n]*$/m, scope)
    assert revoke_row =~ "RFC 7009"
    assert revoke_row =~ ~r/no client auth/i
    assert revoke_row =~ "`200 {}`" or revoke_row =~ "200 {}"
    assert revoke_row =~ ~r/rate limit/i
    assert revoke_row =~ ~r/disabled/i and revoke_row =~ "503"
    [logout_row] = Regex.run(~r/^\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/logout`[^\n]*$/m, scope)
    assert logout_row =~ ~r/OAuth/ and logout_row =~ ~r/current device/i and logout_row =~ ~r/legacy/i
    assert scope =~ ~r/\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/logout\/all`\s*\|\s*✅/
  end

  test "AC13 (story 4): follow-ups.md story-4 section with oauth_revoke and the gate rows (r), (s), (t)" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert f =~ ~r/^## .*oauth-token-revocation-logout/m
    [_, s4] = String.split(f, ~r/^## .*oauth-token-revocation-logout[^\n]*\n/m, parts: 2)
    s4 = s4 |> String.split(~r/^## /m, parts: 2) |> hd()
    assert s4 =~ "oauth_revoke", "(a) item 1 also covers {\"oauth_revoke\", ip}"
    assert f =~ ~r/^\|\s*r\s*\|[^\n]*\/logout/m, "gate row (r): legacy /logout user-wide wipe"
    assert f =~ ~r/^\|\s*s\s*\|[^\n]*device_lists/m, "row (s): device_lists.changed on device deletion"
    assert f =~ ~r/^\|\s*t\s*\|[^\n]*IdP/m, "row (t): optional IdP-side revocation"
  end

  # ── story oauth-legacy-coexistence (story 5), AC10 (RED until the docs step) ──

  defp story5_section(t) do
    assert t =~ ~r/^##+\s+Legacy coexistence \(story 5\)/m, "ADR-033 needs the section 'Legacy coexistence (story 5)'"
    [_, section] = String.split(t, ~r/^##+\s+Legacy coexistence \(story 5\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  test "AC10 (story 5): ADR section records C1-C20, the touchpoint table, the deprecation path and the C8 rationale", %{text: t} do
    section = story5_section(t)
    for n <- 1..20, do: assert(section =~ ~r/\bC#{n}\b/, "C#{n} missing in the story-5 ADR section")
    assert section =~ ~r/\|\s*Touchpoint\s*\|/, "the coexistence touchpoint table"
    assert section =~ "oauth_aware_preferred" and section =~ "org.matrix.msc3824.delegated_oidc_compatibility"
    assert section =~ "M_FORBIDDEN", "C8 rationale"
    assert section =~ ~r/deprecat/i, "C20 deprecation path"
    assert section =~ "legacy_login_enabled"
  end

  test "AC10 (story 5): R16 and legacy-to-legacy reuse stay recorded deviations; T25 sentence and gate paragraph updated", %{text: t} do
    assert t =~ ~r/not changed by story 5/i
    assert t =~ "(C14: kept; follow-up u)", "T25 sentence gets '(C14: kept; follow-up u)'"
    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert gates =~ "Story 5 update"
    assert gates =~ "legacy-logout-per-device"
    assert gates =~ "oauth_aware?/0"
    [_, impl] = String.split(t, ~r/^## Implications[^\n]*\n/m, parts: 2)
    impl = impl |> String.split(~r/^## /m, parts: 2) |> hd()
    assert impl =~ "C20", "the Implications section is rewritten to point at C20"
    assert impl =~ "auth_api"
  end

  test "AC10 (story 5): matrix-api-scope.md rows for GET /login, the SSO action, device deletion, keys/upload, absent endpoints" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    row = fn re -> case Regex.run(re, scope) do
      [r] -> r
      _ -> flunk("row #{inspect(re.source)} missing")
    end end

    assert row.(~r/^\|\s*GET\s*\|\s*`\/_matrix\/client\/v3\/login`[^\n]*$/m) =~ "oauth_aware_preferred"
    sso = row.(~r/^\|\s*GET\s*\|\s*`\/_matrix\/client\/v3\/login\/sso\/redirect`[^\n]*$/m)
    assert sso =~ "action" and sso =~ "org.matrix.msc3824.action" and sso =~ "prompt=create" and sso =~ ~r/Nebu extension/i
    for re <- [~r/^\|\s*DELETE\s*\|\s*`\/_matrix\/client\/v3\/devices\/\{deviceId\}`[^\n]*$/m, ~r/^\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/delete_devices`[^\n]*$/m] do
      r = row.(re)
      assert r =~ "403" and r =~ "M_FORBIDDEN" and r =~ ~r/OAuth/
    end

    assert row.(~r/^\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/keys\/upload`[^\n]*$/m) =~ ~r/OAuth/
    assert scope =~ ~r/account\/deactivate[^\n]*(deliberately absent|absent)[^\n]*M_UNRECOGNIZED|M_UNRECOGNIZED[^\n]*account\/deactivate/i,
           "a note that the account endpoints are deliberately absent (known deviation M_NOT_FOUND vs M_UNRECOGNIZED)"
  end

  test "AC10 (story 5): follow-ups.md story-5 section with rows (u)-(x) and the (r) closing run" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert f =~ ~r/^## .*oauth-legacy-coexistence/m
    [_, s5] = String.split(f, ~r/^## .*oauth-legacy-coexistence[^\n]*\n/m, parts: 2)
    s5 = s5 |> String.split(~r/^## /m, parts: 2) |> hd()
    assert s5 =~ "legacy-logout-per-device"
    assert s5 =~ ~r/RESOLVED/
    for {letter, word} <- [{"u", ~r/raw/i}, {"v", ~r/admin/i}, {"w", ~r/account/i}, {"x", ~r/rotate_tokens|lock/i}] do
      assert f =~ Regex.compile!("^\\|\\s*#{letter}\\s*\\|[^\\n]*" <> word.source, "mi"), "follow-ups row (#{letter})"
    end
  end

  # ── story oauth-account-management (story 6), AC14 (docs pins) ──

  defp story6_section(t) do
    assert t =~ ~r/^##+\s+Account management and `m\.oauth` \(story 6\)/m,
           "ADR-033 needs the section 'Account management and `m.oauth` (story 6)'"

    [_, section] = String.split(t, ~r/^##+\s+Account management and `m\.oauth` \(story 6\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  test "AC14 (story 6): ADR section records A1-A27, A17 as a deliberate deviation, legacy-only users served", %{text: t} do
    section = story6_section(t)
    for n <- 1..27, do: assert(section =~ ~r/\bA#{n}\b/, "A#{n} missing in the story-6 ADR section")
    lines = String.split(section, "\n")
    assert Enum.any?(lines, &(&1 =~ ~r/\bA17\b/ and &1 =~ ~r/deliberate deviation/i)), "A17 recorded as a deliberate deviation (oracle O7)"
    assert section =~ ~r/legacy-only/i, "the page serves legacy-only users (A13/A25)"
    assert section =~ "m.oauth" and section =~ "account_management_uri"
  end

  test "AC14 (story 6): gate paragraph Story 6 update", %{text: t} do
    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert gates =~ "Story 6 update"
    assert gates =~ ~r/gate \(w\) closed/i
    assert gates =~ ~r/\(m\) extended to `\/account`/
    assert gates =~ ~r/gate items 1, h, i, l, m, n, r, y\b/
  end

  test "AC14 (story 6): matrix-api-scope rows for /account, device_signing/upload (m.oauth + known deviation), auth_metadata fields" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    assert scope =~ ~r/^\|\s*GET\s*\|\s*`\/account`[^\n]*$/m
    [ds] = Regex.run(~r/^\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/keys\/device_signing\/upload`[^\n]*$/m, scope)
    assert ds =~ "m.oauth" and ds =~ ~r/known deviation/i and ds =~ "403"
    assert scope =~ "account_management_uri" and scope =~ "account_management_actions_supported"
  end

  test "AC14 (story 6): oauth-broker-spec section 8 auth_time sentence amended (A17)" do
    spec = File.read!(Path.expand("../../../../_bmad-output/planning-artifacts/oauth-broker-spec.md", __DIR__))
    refute spec =~ "`auth_time` muss auch bei OAuth-Sessions gesetzt werden (Login bzw. Re-Auth über die Account-Seite)"
    assert spec =~ "eine Re-Auth über die Account-Seite aktualisiert nur die Account-Sitzung, nicht die Token-Zeilen (Story 6, A17)"
  end

  test "AC14 (story 6): follow-ups.md story-6 section: (w) RESOLVED, (m) extended to /account, rows (y)-(ab), (y) BLOCKING" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert f =~ ~r/^## .*oauth-account-management/m
    [_, s6] = String.split(f, ~r/^## .*oauth-account-management[^\n]*\n/m, parts: 2)
    s6 = s6 |> String.split(~r/^## /m, parts: 2) |> hd()
    assert s6 =~ ~r/\(w\)[^\n]*RESOLVED/i
    assert s6 =~ "/account"
    assert f =~ ~r/^\|\s*y\s*\|[^\n]*auth_time[^\n]*BLOCKING/mi, "row (y): IdP without auth_time, BLOCKING"
    for {letter, word} <- [{"z", ~r/deactivat/i}, {"aa", ~r/per-source|cap/i}, {"ab", ~r/audit/i}] do
      assert f =~ Regex.compile!("^\\|\\s*#{letter}\\s*\\|[^\\n]*" <> word.source, "mi"), "follow-ups row (#{letter})"
    end
  end

  # ── story oauth-versions-switch (story 9), AC7/AC8 / Must #37, #50 (docs pins) ──

  defp story9_section(t) do
    assert t =~ ~r/^##+\s+`\/versions` switch and activation \(story 9\)/m,
           "ADR-033 needs the section '`/versions` switch and activation (story 9)'"

    [_, section] = String.split(t, ~r/^##+\s+`\/versions` switch and activation \(story 9\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  @s9_gates ~w(1 2 4 h i l m n r y ac ag)

  test "AC8 (story 9): ADR section with V1-V19, obligations + parity tables, Out of epic scope, rollback / purge rules", %{text: t} do
    section = story9_section(t)
    for n <- 1..19, do: assert(section =~ ~r/\bV#{n}\b/, "V#{n} missing in the story-9 ADR section")
    assert section =~ ~r/Out of epic scope/i
    assert section =~ "room_summary" and section =~ ~r/\(ac\)/
    assert section =~ ~r/\|\s*Surface\s*\|/, "parity table"
    assert section =~ ~r/\|\s*Ver\.\s*\|/, "obligations table"
    assert section =~ ~r/forced re-login/i, "rollback: OAuth sessions cannot move to legacy (O8)"
    assert section =~ ~r/pending/i and section =~ ~r/purge/i, "registration purge: pending only"
  end

  test "AC8 (story 9): gate paragraph 'Story 9 update' with the final gate list incl. ac", %{text: t} do
    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert gates =~ "Story 9 update"
    assert gates =~ "oauth_aware?/0"
    assert gates =~ ~r/dormant/i
    assert gates =~ ~r/gate items 1, 2, 4, h, i, l, m, n, r, y, ac, ag\b/
  end

  test "AC8/V16 (story 9): stale ADR statements resolved", %{text: t} do
    refute t =~ ~r/stays false because of gate items 1, h, i, l, m, n, r and stories 5, 6, 9/
    assert t =~ ~r/resolved: all advertised endpoints exist since story 4/
  end

  # Structured: precondition rows are TABLE ROWS (`| <gate> | ...`), checklist items are bullets / lines.
  defp deploy_section do
    d = File.read!(Path.expand("../../../../docs/architecture/07-deployment.md", __DIR__))
    assert d =~ ~r/^##+\s+Activating OAuth \(`oauth_enabled`\): preconditions, checklist, rollback/m
    [_, sec] = String.split(d, ~r/^##+\s+Activating OAuth \(`oauth_enabled`\)[^\n]*\n/m, parts: 2)
    sec |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  defp line?(text, res), do: text |> String.split("\n") |> Enum.any?(fn l -> Enum.all?(res, &Regex.match?(&1, l)) end)

  test "AC7 (story 9): preconditions table: one row per gate (incl. w closed), non-gating list, trusted-proxy note", %{text: _t} do
    sec = deploy_section()
    for g <- @s9_gates ++ ~w(w), do: assert(sec =~ Regex.compile!("^\\|\\s*#{g}\\s*\\|", "m"), "precondition table row for gate #{g}")
    assert line?(sec, [~r/^\|\s*1\s*\|/, ~r/NEBU_TRUSTED_PROXY_CIDRS/]),
           "item 1 row: names NEBU_TRUSTED_PROXY_CIDRS (story oauth-trusted-proxy-client-ip); the legacy NEBU_TRUSTED_PROXY is not read"
    # story oauth-authorize-freshness (P3) rewrote row y: the login no longer needs `auth_time` (consent on every authorization)
    assert line?(sec, [~r/^\|\s*y\s*\|/, ~r/auth_time/]), "gate y row names auth_time"
    assert line?(sec, [~r/^\|\s*ac\s*\|/, ~r/room_summary/]), "gate ac row names room_summary"
    assert line?(sec, [~r/^\|\s*w\s*\|/, ~r/closed|resolved/i]), "w closed by story 6"
    # bugfix legacy-logout-per-device: (x) is closed (LL9) and (s) became a gate item (table row s): both left the
    # non-gating list, see the AC11 (legacy-logout-per-device) pins at the end of this file
    # story oauth-hardening-hygiene (P8): (j)/(ah), (p), (am), (an) and story-3 (b) left the non-gating list (done);
    # (al), (t), (o) stay, marked "deferred (P8)" (see the AC13 (P8) pins at the end of this file)
    for g <- ~w(3 o t u v z aa ab al), do: assert(sec =~ Regex.compile!("\\(#{g}\\)|\\b#{g}\\b"), "non-gating item #{g} listed")
  end

  test "AC7 (story 9): reverse proxy, issuer, IdP and smoke-test content" do
    sec = deploy_section()
    for route <- ["/oauth2/", "/account", "/account/", "/.well-known/openid-configuration"], do: assert(sec =~ "`#{route}`", "route #{route}")
    assert line?(sec, [~r/strip/i, ~r/query/i, ~r/\(k\)|\bk\b/]), "strip query strings in access logs (k)"
    assert line?(sec, [~r/oauth_issuer_url/, ~r/empty path/i]) and sec =~ ~r/query|fragment|userinfo/i, "issuer constraints"
    assert sec =~ "matrix_oidc_refresh_mode" and sec =~ "oauth_idp_revalidation"
    assert sec =~ "prompt=create"
    for step <- [~r/auth_metadata/, ~r/\/versions[^\n]*v1\.15/, ~r/\/oauth2\/jwks/, ~r/\/admin\/oauth\/registrations/, ~r/second time|again/i, ~r/rollback rehearsal/i],
        do: assert(sec =~ step, "smoke step #{inspect(step.source)}")
  end

  test "AC7 (story 9): caches, kill switch, forced re-login" do
    sec = deploy_section()
    assert line?(sec, [~r/max-age=259200/, ~r/3 days|three days/i])
    assert sec =~ "max-age=600" and sec =~ "no-store"
    assert line?(sec, [~r/forced re-login/i]) and sec =~ ~r/drain/i
    assert sec =~ ~r/revoke/i and sec =~ ~r/\/logout/
  end

  test "AC7 (story 9): README points to the checklist" do
    r = File.read!(Path.expand("../../../../README.md", __DIR__))
    assert line?(r, [~r/v1\.15/, ~r/07-deployment/]) or (r =~ ~r/v1\.15/ and r =~ "07-deployment.md"), "one sentence linking the checklist"
  end

  test "AC8 (story 9): matrix-api-scope versions row and the G3 rows (must exist, 🔲, (ad))" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    [row] = Regex.run(~r/^\|\s*GET\s*\|\s*`\/_matrix\/client\/versions`[^\n]*$/m, scope)
    for part <- ["v1.15", "v1.11", "no-store", "msc2666", "auth_metadata"], do: assert(row =~ part, "versions row lacks #{part}")
    assert row =~ ~r/authenticat/i, "answer independent of authentication"

    for ep <- ["/user_directory/search", "/publicRooms", "/keys/claim"] do
      rows = Regex.scan(Regex.compile!("^\\|[^\\n]*`[^`]*" <> Regex.escape(ep) <> "`[^\\n]*$", "m"), scope) |> List.flatten()
      assert rows != [], "the scope doc must keep a row for #{ep}"
      for r <- rows, do: assert(r =~ "🔲" and r =~ "(ad)", "#{ep} row must be 🔲 with follow-up (ad): #{r}")
    end
  end

  test "AC8 (story 9): follow-ups story-9 section: rows ac-af, I-1 resolved, I-2 / I-12 / k / r notes" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert f =~ ~r/^## .*oauth-versions-switch/m
    [_, s9] = String.split(f, ~r/^## .*oauth-versions-switch[^\n]*\n/m, parts: 2)
    s9 = s9 |> String.split(~r/^## /m, parts: 2) |> hd()
    assert f =~ ~r/^\|\s*ac\s*\|[^\n]*room_summary[^\n]*GATE/mi
    assert f =~ ~r/^\|\s*ad\s*\|[^\n]*publicRooms/mi
    assert f =~ ~r/^\|\s*ae\s*\|[^\n]*v3\/versions/mi
    assert f =~ ~r/^\|\s*af\s*\|[^\n]*M_UNRECOGNIZED/mi
    assert line?(s9, [~r/I-1/, ~r/RESOLVED/])
    assert line?(s9, [~r/I-2/, ~r/07-deployment/])
    assert line?(s9, [~r/I-12/, ~r/\/versions/])
    assert line?(s9, [~r/\(r\)/, ~r/dormant/i])
  end

  test "AC8 (story 9): spec 3a lists room_summary among the preconditions with (ac) and the push gap with (ad)" do
    spec = File.read!(Path.expand("../../../../_bmad-output/planning-artifacts/oauth-broker-spec.md", __DIR__))
    [_, s3a] = String.split(spec, ~r/^#+\s*3a\b[^\n]*\n/m, parts: 2)
    s3a = s3a |> String.split(~r/^#+\s*\d+[a-z]?\b/m, parts: 2) |> hd()
    assert line?(s3a, [~r/room_summary/, ~r/\(ac\)/])
    assert line?(s3a, [~r/Push/, ~r/\(ad\)/])
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story oauth-trusted-proxy-client-ip (phase 2, P1): AC8 / AC9 / AC10 and security review cycle 1 (docs and doc pins)
  # ════════════════════════════════════════════════════════════════════════════

  @p1_headline ~r/^##+\s+Trusted-proxy client IP \(phase 2, story oauth-trusted-proxy-client-ip\)/m

  defp p1_section(t) do
    assert t =~ @p1_headline, "ADR-033 needs the section 'Trusted-proxy client IP (phase 2, story oauth-trusted-proxy-client-ip)'"
    [_, section] = String.split(t, ~r/^##+\s+Trusted-proxy client IP \(phase 2, story oauth-trusted-proxy-client-ip\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  test "AC10.1 (P1): ADR section records TP1-TP14 with the keyword pins of TP1, TP5, TP9", %{text: t} do
    section = p1_section(t)
    for n <- 1..14, do: assert(section =~ ~r/\bTP#{n}\b/, "TP#{n} missing in the P1 ADR section")
    assert section =~ "NEBU_TRUSTED_PROXY_CIDRS", "TP1: the config variable"
    assert section =~ ~r/fail[- ]closed/i, "TP2"
    assert section =~ ~r/right-to-left/i, "TP5: the walk"
    assert section =~ "X-Forwarded-For" and section =~ ~r/rightmost untrusted/i, "TP5"
    assert section =~ "nebu_client_ip" and section =~ "conn.private", "TP9: one resolution point, conn.remote_ip not overwritten"
    assert section =~ "Nebu.Web.ClientIP.get/1", "TP10: the helper"
    assert section =~ ~r/Forwarded/ and section =~ ~r/X-Real-IP/, "TP6: both ignored"
    assert section =~ ~r/\|\s*Deployment\s*\|/, "the topology table of the Manual verification section"
  end

  test "AC10.1 (P1): gate list item 1 is marked resolved in the server, activation needs the operator verification", %{text: t} do
    [_, gates] = String.split(t, ~r/^## Gate items before `oauth_enabled`[^\n]*\n/m, parts: 2)
    gates = gates |> String.split(~r/^## /m, parts: 2) |> hd()
    assert gates =~ ~r/resolved in the server by this story/i
    assert gates =~ ~r/operator verification/i
  end

  test "AC8.2 (P1): ADR 'Remaining weakness' no longer claims the IP is the directly connected peer unconditionally", %{text: t} do
    [para] = Regex.run(~r/Remaining weakness[^\n]*(?:\n[^\n]+)*/, t)
    assert para =~ "NEBU_TRUSTED_PROXY_CIDRS" or para =~ ~r/resolver|ClientIP/, "must reference the resolver"
    assert para =~ ~r/without (the )?configuration|unless|default/i, "states that without configuration it still is the peer"
  end

  test "AC8.1/AC8.2 (P1): RateLimit and OAuth.Http moduledocs describe the resolver, not the raw peer" do
    rl = File.read!(Path.expand("../../../lib/nebu/web/plugs/rate_limit.ex", __DIR__))
    assert rl =~ "Nebu.Web.ClientIP.get/1"
    assert rl =~ "NEBU_TRUSTED_PROXY_CIDRS"
    assert rl =~ ~r/rightmost untrusted/i
    assert rl =~ "ClientIP.bucket/1" and rl =~ "/64", "IPv6 rate-limit keys are the /64 network (cycle 1)"
    assert rl =~ ~r/evicted/i and rl =~ "RateLimitSweeper", "idle buckets are evicted (cycle 1)"
    refute rl =~ ~r/never evicted/i
    refute rl =~ "Uses `conn.remote_ip` (the directly-connected peer)"

    http = File.read!(Path.expand("../../../lib/nebu/oauth/http.ex", __DIR__))
    refute http =~ ~r/the "IP" is the directly connected peer \(`conn\.remote_ip`\)/
    assert http =~ ~r/ClientIP|NEBU_TRUSTED_PROXY_CIDRS/
  end

  defp p1_deploy_subsection do
    sec = deploy_section()

    assert sec =~ ~r/^###\s+Client IP behind a reverse proxy \(`NEBU_TRUSTED_PROXY_CIDRS`\)/m,
           "07-deployment.md needs the subsection 'Client IP behind a reverse proxy (`NEBU_TRUSTED_PROXY_CIDRS`)'"

    [_, sub] = String.split(sec, ~r/^###\s+Client IP behind a reverse proxy \(`NEBU_TRUSTED_PROXY_CIDRS`\)[^\n]*\n/m, parts: 2)
    sub |> String.split(~r/^### /m, parts: 2) |> hd()
  end

  test "AC9.1 (P1): 07-deployment subsection 'Client IP behind a reverse proxy' content" do
    sub = p1_deploy_subsection()
    assert sub =~ "10.0.0.0/8" or sub =~ "172.18.0.0/16", "format examples"
    assert sub =~ ~r/default[^\n]*(none|empty|no trusted)/i
    assert sub =~ "$proxy_add_x_forwarded_for", "append rule for intermediate hops"
    assert sub =~ "proxy_set_header X-Forwarded-For $remote_addr", "overwrite rule for the outermost proxy"
    assert sub =~ "`8008`" and sub =~ "`8080`", "published host ports must not be reachable from untrusted networks"
    assert sub =~ "0.0.0.0/0" and sub =~ "::/0", "catch-all danger"
    assert sub =~ "Forwarded" and sub =~ "X-Real-IP", "both ignored"
    assert sub =~ "last_seen_ip", "verification recipe"
    assert sub =~ ~r/never client networks|not client networks/i
  end

  test "Kassandra #1/#3 (P1 cycle 1): 07-deployment subsection: too-broad list warning, negative test, /32 pin, loopback ports, IPv6, privacy" do
    sub = p1_deploy_subsection()
    refute sub =~ ~r/wrong or empty list never allows spoofing/i
    assert sub =~ ~r/empty or invalid list never allows spoofing/i and sub =~ ~r/too-broad list does/i
    assert sub =~ "203.0.113.99", "negative verification test with a forged X-Forwarded-For"
    assert sub =~ ~r/NEGATIVE test/ and sub =~ ~r/over IPv4 AND over IPv6/ and sub =~ ~r/directly to `:8008` \/ `:8080`/
    assert sub =~ ~r/never show `203\.0\.113\.99`/
    assert sub =~ ~r/`\/32`/ and sub =~ ~r/NOT the whole compose subnet/, "trust the pinned nginx /32, not the compose subnet"
    assert sub =~ ~r/Bind the published host ports[^\n]*`127\.0\.0\.1`[^\n]*BEFORE trusting the Docker gateway/
    assert sub =~ ~r/default iptables DNAT[^\n]*keeps its own source/ and sub =~ ~r/rootless/ and sub =~ ~r/IPv6/
    assert sub =~ ~r/verified to APPEND/ and sub =~ ~r/LB-shared bucket/, "an LB is listed only when verified to append / overwrite"
    assert sub =~ ~r/Privacy and retention/ and sub =~ "personal data"
    assert sub =~ "/64", "IPv6 rate-limit keys"
  end

  test "Kassandra #1/#2/#3 (P1 cycle 1): ADR section: TP8 bucket/1 + /64 + sweeper, TP14 text, alb rows trust the LB only when verified" do
    t = File.read!(Path.expand("../../../../docs/architecture/adr/ADR-033-authorization-server-broker-model.md", __DIR__))
    section = p1_section(t)
    refute t =~ ~r/wrong\s+list stays fail closed/i
    refute section =~ ~r/Nebu cannot detect a wrong list\. Trusting/
    assert t =~ ~r/invalid\s+list stays fail closed/i and t =~ ~r/too-broad list is not safe/i
    [tp8] = Regex.run(~r/\*\*TP8[^\n]*(?:\n  [^\n]+)*/, section)
    assert tp8 =~ "ClientIP.bucket/1" and tp8 =~ "/64" and tp8 =~ "RateLimitSweeper" and tp8 =~ "last_seen_ip"
    [tp14] = Regex.run(~r/\*\*TP14[^\n]*(?:\n  [^\n]+)*/, section)
    assert tp14 =~ "/32" and tp14 =~ "127.0.0.1" and tp14 =~ ~r/rootless/ and tp14 =~ ~r/APPEND/ and tp14 =~ "ap4"

    for row <- Regex.scan(~r/^\|\s*(UpCloud `alb`|Stackit `alb`)[^\n]*$/m, section, capture: :first) |> List.flatten() do
      assert row =~ ~r/ONLY IF/ and row =~ ~r/APPEND/, "alb row must trust the LB only when verified to append: #{row}"
      refute row =~ ~r/adds \/ forwards/
    end

    assert section =~ "203.0.113.99" and section =~ ~r/NEGATIVE test/
    assert section =~ ~r/Stackit `acme`[^\n]*bound to `127\.0\.0\.1`/
  end

  test "Kassandra #4 (P1 cycle 1): follow-ups record ap4 (fallback bucket), ap5 (privacy) and the ETS sweeping part of (am) as done" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert line?(f, [~r/^\|\s*ap4\s*\|/, ~r/non-gating/, ~r/proxy/i, ~r/fallback/i])
    assert line?(f, [~r/^\|\s*ap5\s*\|/, ~r/last_seen_ip/, ~r/created_from_ip/])
    assert line?(f, [~r/^\|\s*am\s*\|/, ~r/ETS sweeping part DONE/, ~r/RateLimitSweeper/])
  end

  test "AC9.2 (P1): preconditions row 1 is closed in the server with operator verification, owner server / operator" do
    sec = deploy_section()
    assert line?(sec, [~r/^\|\s*1\s*\|/, ~r/Trusted-proxy client-IP resolution/, ~r/HARD GATE/])
    assert line?(sec, [~r/^\|\s*1\s*\|/, ~r/NEBU_TRUSTED_PROXY_CIDRS/, ~r/NEBU_TRUSTED_PROXY` is not read/])
    assert line?(sec, [~r/^\|\s*1\s*\|/, ~r/closed in the server/i, ~r/operator must configure and verify/i])
    assert line?(sec, [~r/^\|\s*1\s*\|/, ~r/server \/ operator/])
  end

  test "AC9.3 (P1): stale NEBU_TRUSTED_PROXY env line and the shared-bucket sentence are corrected" do
    d = File.read!(Path.expand("../../../../docs/architecture/07-deployment.md", __DIR__))
    refute d =~ ~r/NEBU_TRUSTED_PROXY\s+— For X-Forwarded-\* header handling via nginx/
    refute d =~ ~r/all browsers share one `\{"oauth_account", ip\}` bucket \(600\/h\) until the trusted-proxy gate \(item 1\) is implemented/
    assert d =~ ~r/NEBU_TRUSTED_PROXY_CIDRS[^\n]*not set by the templates yet[^\n]*gate m/i, "cloud variable lists name the new variable"
  end

  test "AC10.2 (P1): follow-ups.md marks item 1 resolved (server) and appends the new items" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert line?(f, [~r/^\|\s*1\s*\|/, ~r/resolved/i, ~r/oauth-trusted-proxy-client-ip/])
    assert f =~ ~r/oauth-trusted-proxy-client-ip/
    assert line?(f, [~r/NEBU_TRUSTED_PROXY_CIDRS/, ~r/cloud-init/i, ~r/127\.0\.0\.1/]), "P5 / gate m item: set the variable, bind ports to 127.0.0.1"
    assert line?(f, [~r/X-Forwarded-Proto/, ~r/TP12|non-gating/i]), "TP12 follow-up"
    assert line?(f, [~r/PROXY[- ]protocol/i, ~r/non-gating|TCP/i]), "PROXY protocol follow-up"
  end

  test "AC7 (P1): RequestScheme is untouched by the trusted-proxy set (TP12) and no migration mentions it" do
    scheme = File.read!(Path.expand("../../../lib/nebu/web/request_scheme.ex", __DIR__))
    refute scheme =~ ~r/ClientIP|trusted_proxy|TRUSTED_PROXY/
    migs = Path.wildcard(Path.expand("../../../priv/migrations/*.sql", __DIR__))
    assert migs != []
    refute Enum.any?(migs, &(File.read!(&1) =~ ~r/trusted_proxy|client_ip/i)), "story P1 adds no migration / server_config key"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story oauth-dcr-abuse-hardening (phase 2, P2): AC14 (docs and doc pins)
  # ════════════════════════════════════════════════════════════════════════════

  @p2_headline ~r/^##+\s+DCR and flow-state abuse hardening \(phase 2, story oauth-dcr-abuse-hardening\)/m

  defp p2_section(t) do
    assert t =~ @p2_headline, "ADR-033 needs the section 'DCR and flow-state abuse hardening (phase 2, story oauth-dcr-abuse-hardening)'"

    [_, section] =
      String.split(t, ~r/^##+\s+DCR and flow-state abuse hardening \(phase 2, story oauth-dcr-abuse-hardening\)[^\n]*\n/m, parts: 2)

    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  test "AC14.1 (P2): ADR section records AH1-AH17 with the keyword pins of AH1, AH3, AH4, AH8, AH9, AH10, AH12", %{text: t} do
    section = p2_section(t)
    for n <- 1..17, do: assert(section =~ ~r/\bAH#{n}\b/, "AH#{n} missing in the P2 ADR section")

    [ah1] = Regex.run(~r/\*\*AH1\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah1 =~ ~r/registrable domain/i and ah1 =~ ~r/source/i and ah1 =~ ~r/never evict|REFUSE/i
    assert ah1 =~ "oauth_pending_host_cap"

    [ah3] = Regex.run(~r/\*\*AH3\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah3 =~ "/64" and ah3 =~ "SHA-256" and ah3 =~ ~r/pseudonymous/i

    [ah4] = Regex.run(~r/\*\*AH4\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah4 =~ "github.io" and ah4 =~ "co.uk" and ah4 =~ ~r/no network/i and ah4 =~ ~r/longest/i

    [ah8] = Regex.run(~r/\*\*AH8\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah8 =~ "DELETE" and ah8 =~ ~r/Remove pending registrations/ and ah8 =~ ~r/final/i

    [ah9] = Regex.run(~r/\*\*AH9\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah9 =~ "oauth_clients_bulk_removed" and ah9 =~ "as_of" and ah9 =~ "500" and ah9 =~ ~r/SKIP LOCKED/

    [ah10] = Regex.run(~r/\*\*AH10\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah10 =~ "source_key" and ah10 =~ "300" and ah10 =~ ~r/never evict/i

    [ah12] = Regex.run(~r/\*\*AH12\b[^\n]*(?:\n  [^\n]+)*/, section)
    assert ah12 =~ ~r/small GLOBAL caps/i and ah12 =~ "NEBU_TRUSTED_PROXY_CIDRS"

    assert section =~ ~r/Manual verification/
    assert section =~ "co.uk" and section =~ "vercel.app" and section =~ ~r/Extending/i, "the suffix list and the extension rule"
  end

  test "AC14.1 (P2): 'Pending registrations' > 'Per-host cap' is rewritten for (registrable domain, source)", %{text: t} do
    [bullet] = Regex.run(~r/- \*\*Per-host cap\*\*[^\n]*(?:\n  [^\n]+)*/, t)
    assert bullet =~ ~r/registrable domain/i and bullet =~ ~r/source/i
    refute bullet =~ "The key is the exact host", "the exact-host sentence is obsolete (AH1)"
    refute bullet =~ ~r/follow-up, see "Gate\s+items"/
    assert bullet =~ "oauth_pending_host_cap"
  end

  test "AC14.1 (P2): the approval-page bullet no longer says 'No public-suffix check yet' and names the badges", %{text: t} do
    refute t =~ "No public-suffix check yet (gate item 3)"
    assert t =~ ~r/shared hosting/i and t =~ ~r/public suffix/i
  end

  test "AC14.1 (P2): gate list items 2, 3 and 4 are marked resolved by the story; the keywords of the old pins stay", %{text: t} do
    [_, gates] = String.split(t, ~r/^## Gate items before `oauth_enabled`[^\n]*\n/m, parts: 2)
    gates = gates |> String.split(~r/^## /m, parts: 2) |> hd()

    for {n, kw} <- [{2, "Bulk reject"}, {3, "Public-suffix"}, {4, "Per-host cap keyed on"}] do
      [item] = Regex.run(~r/^#{n}\. \*\*#{kw}[^\n]*(?:\n   [^\n]+)*/m, gates) || flunk("gate item #{n} (#{kw}) missing")
      assert item =~ ~r/resolved by story oauth-dcr-abuse-hardening/i, "gate item #{n} must be marked resolved"
    end
  end

  test "AC14.1 (P2): the story-2 'at most 10 000 live oauth_authz_requests rows' sentence mentions the per-source cap", %{text: t} do
    [d19] = Regex.run(~r/\*\*D19 Abuse bounds\.\*\*[^\n]*(?:\n  [^\n]+)*/, t)
    assert d19 =~ "10 000" and d19 =~ ~r/per[- ]source/i and d19 =~ "300"
  end

  test "AC14.2 (P2): moduledocs of ClientStore, AuthzStore, AccountStore, Registration, OAuth.Http and the controller" do
    lib = Path.expand("../../../lib/nebu", __DIR__)
    read = &File.read!(Path.join(lib, &1))

    cs = read.("oauth/client_store.ex")
    assert cs =~ ~r/bulk/i and cs =~ ~r/second\s+`?DELETE/i, "ClientStore: the bulk delete is the second DELETE"
    assert cs =~ ~r/source/i and cs =~ ~r/registrable domain/i
    refute cs =~ ~r/The ONLY\s+`DELETE` in this module is `purge_expired_pending/

    assert read.("oauth/authz_store.ex") =~ ~r/per[- ]source/i
    assert read.("oauth/account_store.ex") =~ ~r/per[- ]source/i

    reg = read.("oauth/registration.ex")
    refute reg =~ "No public-suffix check is done"
    assert reg =~ ~r/public suffix/i

    http = read.("oauth/http.ex")
    assert http =~ "SourceKey" and http =~ ~r/public suffix|per source/i

    ctl = read.("admin/oauth_registrations_controller.ex")
    assert ctl =~ "bulk-remove" and ctl =~ ~r/Remove pending registrations|bulk/i and ctl =~ "AH8"
  end

  test "AC14.3 (P2): 07-deployment: the oauth_pending_host_cap row, preconditions rows 2/3/4/h, checklist sentence" do
    d = File.read!(Path.expand("../../../../docs/architecture/07-deployment.md", __DIR__))
    [row] = Regex.run(~r/^\| `oauth_pending_host_cap`[^\n]*$/m, d)
    assert row =~ ~r/registrable domain/i and row =~ ~r/source/i and row =~ ~r/public suffix/i and row =~ "100"
    refute row =~ "GATE: before `oauth_enabled`, key on", "the GATE sentence is resolved"

    sec = deploy_section()
    assert line?(sec, [~r/^\|\s*2\s*\|/, ~r/Bulk removal of pending registrations/, ~r/closed \(story oauth-dcr-abuse-hardening\)/])
    assert line?(sec, [~r/^\|\s*3\s*\|/, ~r/Public-suffix check/, ~r/closed/, ~r/server/])
    assert line?(sec, [~r/^\|\s*4\s*\|/, ~r/registrable domain, client source/, ~r/closed \(story oauth-dcr-abuse-hardening\)/, ~r/item 1 configured/])
    assert line?(sec, [~r/^\|\s*h\s*\|/, ~r/300\s+per source/, ~r/oauth_account_login_requests/, ~r/closed \(story oauth-dcr-abuse-hardening\)|same status/])
    assert sec =~ ~r/two clients on different networks get independent per-source caps/
    assert sec =~ ~r/300 in-flight logins, 100 pending registrations/
  end

  test "AC14.3 (P2): follow-ups.md: items 2, 3, 4, h, aa resolved; new non-gating section with ao-ar" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    assert line?(f, [~r/^\|\s*2\s*\|/, ~r/RESOLVED by story oauth-dcr-abuse-hardening/, ~r/AH8/])
    assert line?(f, [~r/^\|\s*3\s*\|/, ~r/RESOLVED by story oauth-dcr-abuse-hardening/, ~r/AH4/])
    assert line?(f, [~r/^\|\s*4\s*\|/, ~r/RESOLVED by story oauth-dcr-abuse-hardening/, ~r/AH1/])
    assert line?(f, [~r/^\|\s*h\s*\|/, ~r/RESOLVED/, ~r/AH10/])
    assert line?(f, [~r/^\|\s*aa\s*\|/, ~r/RESOLVED/, ~r/AH11/, ~r/sessions/])
    assert f =~ ~r/From story oauth-dcr-abuse-hardening \(2026-10-12\)/

    for {id, kw} <- [{"ao", ~r/\/48/}, {"ap", ~r/\/64/}, {"aq", ~r/keyed/i}, {"ar", ~r/suffix/i}] do
      assert line?(f, [~r/^\|\s*#{id}\s*\|/, kw, ~r/non-gating/i]), "follow-up #{id} missing"
    end
  end
  # ════════════════════════════════════════════════════════════════════════════
  # Story oauth-authorize-freshness (phase 2, P3): AC17 (docs and doc pins)
  # ════════════════════════════════════════════════════════════════════════════

  @p3_headline ~r/^##+\s+Consent, freshness and refresh serialization \(story oauth-authorize-freshness\)/m

  defp p3_section(t) do
    assert t =~ @p3_headline, "ADR-033 needs the section 'Consent, freshness and refresh serialization (story oauth-authorize-freshness)'"

    [_, section] =
      String.split(t, ~r/^##+\s+Consent, freshness and refresh serialization \(story oauth-authorize-freshness\)[^\n]*\n/m, parts: 2)

    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  defp fr(section, n), do: Regex.run(~r/\*\*FR#{n}\b[^\n]*(?:\n  [^\n]+)*/, section) |> List.wrap() |> List.first() || flunk("FR#{n} missing in the P3 ADR section")

  test "AC17 (P3): ADR section records FR1-FR20 with the keyword pins", %{text: t} do
    section = p3_section(t)
    for n <- 1..20, do: assert(section =~ ~r/\bFR#{n}\b/, "FR#{n} missing in the P3 ADR section")

    fr1 = fr(section, 1)
    assert fr1 =~ ~r/every authorization/i and fr1 =~ "RFC 8252" and fr1 =~ "RFC 6749" and fr1 =~ ~r/remembered/i
    assert fr1 =~ "D5" and fr1 =~ "A26", "FR1 supersedes D5 and A26"

    fr3 = fr(section, 3)
    assert fr3 =~ "login_required" and fr3 =~ "prompt=none" and fr3 =~ "max_age"

    fr4 = fr(section, 4)
    assert fr4 =~ "iat" and fr4 =~ ~r/NULL/ and fr4 =~ ~r/raw/i

    fr6 = fr(section, 6)
    assert fr6 =~ "oauth_consent_requests" and fr6 =~ "10 000" and fr6 =~ "DELETE"

    fr8 = fr(section, 8)
    assert fr8 =~ "__Host-nebu_oauth_consent" and fr8 =~ "SameSite=Lax" and fr8 =~ "Sec-Fetch-Site"

    fr10 = fr(section, 10)
    assert fr10 =~ "form-action" and fr10 =~ "[::1]" and fr10 =~ ~r/scheme source/i and fr10 =~ "http:"

    fr11 = fr(section, 11)
    assert fr11 =~ ~r/stricter than the spec/i, "the cross-app refusal is a recorded Nebu policy (oracle correction 1)"
    assert fr11 =~ "RFC 9700 4.11" and fr11 =~ "RFC 6749 10.12"
    assert fr11 =~ "client_uri" and fr11 =~ "redirect_uris", "the deduped identity (correction 2)"

    fr13 = fr(section, 13)
    assert fr13 =~ "per_refresh" and fr13 =~ "server_error" and fr13 =~ ~r/before provisioning/i

    fr14 = fr(section, 14)
    assert fr14 =~ "freshness_unavailable" and fr14 =~ ~r/fail closed/i and fr14 =~ ~r/NULL/

    fr15 = fr(section, 15)
    assert fr15 =~ ~r/lease/i and fr15 =~ ~r/advisory/i and fr15 =~ "503" and fr15 =~ ~r/never (a )?revo/i

    fr16 = fr(section, 16)
    assert fr16 =~ "M_BAD_JSON" and fr16 =~ "M_MISSING_PARAM" and fr16 =~ "FOR UPDATE"

    fr20 = fr(section, 20)
    assert fr20 =~ "oauth_device_holder"

    assert section =~ ~r/Manual verification/ and section =~ "Dex"
    assert section =~ ~r/legacy `m\.login\.sso`[^\n]*(no|without) consent/i, "accepted risk until the legacy shutdown"
  end

  test "AC17 (P3): D5 and A26 are marked superseded by FR1; A7 and T28 and the story-3 auth_time rule are updated", %{text: t} do
    [d5] = Regex.run(~r/- \*\*D5\b[^\n]*(?:\n  [^\n]+)*/, t)
    assert d5 =~ ~r/Superseded by FR1/i

    [a26] = Regex.run(~r/- \*\*A26\b[^\n]*(?:\n  [^\n]+)*/, t)
    assert a26 =~ ~r/Superseded by FR1\/FR14/i

    [a7] = Regex.run(~r/- \*\*A7\b[^\n]*(?:\n  [^\n]+)*/, t)
    assert a7 =~ "NULL" and a7 =~ "FR14" and a7 =~ ~r/never fresh/i
    refute a7 =~ "accepted with the callback time", "the fail-open sentence is replaced (gate y)"

    [t28] = Regex.run(~r/- \*\*T28\b[^\n]*(?:\n  [^\n]+)*/, t)
    assert t28 =~ "FR15" and t28 =~ ~r/expired lease/i

    assert t =~ ~r/never `iat` \(FR4\)/, "story-3 auth_time: the raw claim or NULL, never iat"
  end

  test "AC17 (P3): gate list: i, y, l, n, ak(1) closed by the story; the legacy m.login.sso consent gap is an accepted risk", %{text: t} do
    [_, gates] = String.split(t, ~r/^## Gate items before `oauth_enabled`[^\n]*\n/m, parts: 2)
    gates = gates |> String.split(~r/^## /m, parts: 2) |> hd()
    assert gates =~ "oauth-authorize-freshness"
    assert gates =~ ~r/\bi\b[^\n]*\by\b[^\n]*\bl\b[^\n]*\bn\b/ or gates =~ ~r/closed by (story )?oauth-authorize-freshness/i
    assert gates =~ "ak(1)" or gates =~ ~r/\bak\b/
    assert gates =~ ~r/m\.login\.sso/ and gates =~ ~r/no consent|without consent/i
  end

  test "AC17 (P3): follow-ups.md marks the gate rows resolved and appends the new section with DISTINCT item ids" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))

    for id <- ~w(i y l n) do
      assert line?(f, [Regex.compile!("^\\|\\s*#{id}\\s*\\|"), ~r/RESOLVED by oauth-authorize-freshness/]), "row #{id} must be marked resolved"
    end

    assert line?(f, [~r/^\|\s*\(i\)\/\(y\) sharpened\s*\|/, ~r/RESOLVED by oauth-authorize-freshness/])
    assert line?(f, [~r/^- ak\b/, ~r/\(1\)-\(3\) RESOLVED \(FR16\)/, ~r/\(4\) open/])
    assert line?(f, [~r/^- \(b\)/, ~r/RESOLVED \(FR1\)/]) or f =~ ~r/\(b\)[^\n]*RESOLVED \(FR1\)/
    assert f =~ ~r/closed by FR1\/FR14/

    assert f =~ ~r/^## From story oauth-authorize-freshness \(2026-10-12\)/m
    [_, sec] = String.split(f, ~r/^## From story oauth-authorize-freshness \(2026-10-12\)[^\n]*\n/m, parts: 2)
    sec = sec |> String.split(~r/^## /m, parts: 2) |> hd()
    assert sec =~ "persist_single" and sec =~ ~r/compare-and-set/i, "the persist_single follow-up"
    assert sec =~ ~r/remembered consent/i, "optional remembered consent"
    assert sec =~ ~r/without (an )?IdP `auth_time`/i and sec =~ ~r/release note/i, "release note: no device deletion / reset approval without auth_time"
    assert sec =~ ~r/revoked/i and sec =~ ~r/consent rows/i, "P4 deletes the consent rows of a revoked client"

    # the item ids of the new section must not collide with ids of earlier sections (P2 already used ao-at)
    ids = fn text -> Regex.scan(~r/^\|\s*([a-z]{1,3}[0-9]?)\s*\|/m, text) |> Enum.map(&Enum.at(&1, 1)) end
    new_ids = ids.(sec)
    old_ids = ids.(String.replace(f, sec, ""))
    assert length(new_ids) >= 4, "four new follow-up rows expected, got #{inspect(new_ids)}"
    assert Enum.uniq(new_ids) == new_ids
    assert MapSet.disjoint?(MapSet.new(new_ids), MapSet.new(old_ids)), "follow-up ids collide with earlier sections: #{inspect(Enum.filter(new_ids, &(&1 in old_ids)))}"
  end

  test "AC17 (P3): 07-deployment preconditions table: rows i, l, n, ak(1), 'i / y (server-owned)' closed; row y rewritten; the IdP prerequisite sentence replaced" do
    sec = deploy_section()
    closed = ~r/closed \(story oauth-authorize-freshness\)/

    for g <- ["i", "l", "n"], do: assert(line?(sec, [Regex.compile!("^\\|\\s*#{g}\\s*\\|"), closed]), "row #{g} closed")
    assert line?(sec, [~r/^\|\s*ak\(1\)\s*\|/, closed])
    assert line?(sec, [~r/^\|\s*i \/ y \(server-owned\)\s*\|/, closed])

    assert line?(sec, [~r/^\|\s*y\s*\|/, ~r/Login no longer needs `auth_time`/, ~r/consent on every authorization/, ~r/fail closed/, ~r/aq/, ~r/server \(done\)/])

    refute sec =~ "The IdP must honour `max_age=0` and emit `auth_time` (gate y)"
    assert sec =~ ~r/An IdP that emits `auth_time` enables `\/account` device deletion and key-reset approval for OAuth users/
  end

  test "AC17 (P3): 07-deployment schema list names both new tables and the nullable auth_time; the checklist has the @oauth-consent run and the manual items" do
    d = File.read!(Path.expand("../../../../docs/architecture/07-deployment.md", __DIR__))
    assert d =~ "oauth_consent_requests" and d =~ "oauth_idp_refresh_leases"
    assert d =~ ~r/`oauth_account_sessions\.auth_time` nullable \(000045\)/

    sec = deploy_section()
    assert sec =~ "@oauth-consent"
    assert sec =~ ~r/Manual verification/i or sec =~ ~r/manual items 1-7/i
    assert sec =~ "Element Web" and sec =~ "FluffyChat" and sec =~ ~r/auth_time/
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Bugfix legacy-logout-per-device (gate r, follow-up x): AC11 doc pins (LL1-LL12)
  # ════════════════════════════════════════════════════════════════════════════

  @ll_headline ~r/^##+\s+Legacy logout per device \(bugfix legacy-logout-per-device\)/m

  defp ll_section(t) do
    assert t =~ @ll_headline, "ADR-033 needs the section 'Legacy logout per device (bugfix legacy-logout-per-device)'"
    [_, section] = String.split(t, ~r/^##+\s+Legacy logout per device \(bugfix legacy-logout-per-device\)[^\n]*\n/m, parts: 2)
    section |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  # The bullet of LLn (up to the next `- **LL` bullet): one bullet each, condensed (story Doc edits 1).
  defp ll_bullet(section, n) do
    case Regex.run(Regex.compile!("^- \\*\\*LL#{n}\\b.*?(?=^- \\*\\*LL|\\z)", "ms"), section) do
      [b] -> b
      _ -> flunk("LL#{n} must be one bullet `- **LL#{n} ...` of the ADR section")
    end
  end

  test "AC11 (LL): ADR section LL1-LL12 (one bullet each) before the gate items; LL3 / LL4 / LL5 / LL9 / LL10 / LL11 keywords", %{text: t} do
    section = ll_section(t)
    for n <- 1..12, do: ll_bullet(section, n)

    {ll_pos, _} = :binary.match(t, "Legacy logout per device (bugfix legacy-logout-per-device)")
    {gate_pos, _} = :binary.match(t, "## Gate items before")
    assert ll_pos < gate_pos, "the section sits before 'Gate items before ...'"

    assert ll_bullet(section, 3) =~ ~r/re-check/i and ll_bullet(section, 3) =~ ~r/devices/
    assert ll_bullet(section, 4) =~ ~r/denylist/i and ll_bullet(section, 4) =~ ":unknown"
    assert ll_bullet(section, 5) =~ ~r/unbound/i
    assert ll_bullet(section, 9) =~ "rotate_tokens" and ll_bullet(section, 9) =~ ~r/devices/ and ll_bullet(section, 9) =~ ~r/lock/i
    assert ll_bullet(section, 10) =~ "legacy_logout_device"
    assert ll_bullet(section, 11) =~ "/logout/all"
    assert ll_bullet(section, 12) =~ ~r/device_lists/
  end

  test "AC11 (LL, review cycle 1): L1 device-less row lock + lock_timeout in LL3, L2 uncached binding re-read in LL5, L3 static log message in LL12; the gate state is consistent",
       %{text: t} do
    section = ll_section(t)
    ll3 = ll_bullet(section, 3)
    assert ll3 =~ ~r/no `devices` row/i and ll3 =~ "matrix_sessions" and ll3 =~ "FOR UPDATE", "L1"
    assert ll3 =~ "lock_timeout" and ll3 =~ "2 s", "the bounded device lock wait"
    ll5 = ll_bullet(section, 5)
    assert ll5 =~ "lookup_fresh" and ll5 =~ ~r/never caches a database error/, "L2"
    ll12 = ll_bullet(section, 12)
    assert ll12 =~ ~r/STATIC message/i and ll12 =~ ~r/metadata/i, "L3"

    flat = String.replace(t, ~r/\s+/, " ")
    assert flat =~ "(r) is CLOSED and (s) `device_lists.changed` on every device deletion is a gate item", "story-9 update: current gate state"
    assert flat =~ "since the bugfix legacy-logout-per-device (r) is closed and (s)", "V13: current gate state"
  end

  test "AC11 (LL): R16 is RESOLVED (still one line with deviation and /logout), the R17 sentence is reworded, the story-9 update records the closure",
       %{text: t} do
    section = story4_section(t)

    assert line_with?(section, [~r/\bR16\b/, ~r/RESOLVED/, ~r/legacy-logout-per-device/, ~r/deviation/, ~r/\/logout/]),
           "R16 is resolved by the bugfix; one line keeps R16, deviation and /logout (the old pin)"

    flat = String.replace(section, ~r/\s+/, " ")
    assert flat =~ "The legacy part of `/logout/all` keeps its best-effort contract (LL11)."
    refute flat =~ "The legacy `/logout` keeps its best-effort contract (R16)."

    [_, gates] = String.split(t, "Gate items before `oauth_enabled`", parts: 2)
    assert String.replace(gates, ~r/\s+/, " ") =~ "Bugfix legacy-logout-per-device: gate item (r) closed (LL1-LL12); follow-up (x) closed (LL9)."
    assert gates =~ "Story 5 update" and gates =~ "legacy-logout-per-device", "the story-4/5 history paragraphs stay (old pins)"
  end

  test "AC11 (LL): follow-ups.md: rows r and x resolved + closed, (c) / story-9 bullets, I-14, row s is a gate item, the new section" do
    f = File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))
    closed = ~r/\|\s*\**closed\**\s*\|?\s*$/

    assert line_with?(f, [~r/^\|\s*r\s*\|/, ~r/RESOLVED by bugfix legacy-logout-per-device \(LL1-LL12\)/, closed]), "row r resolved, Gate column closed"
    assert line_with?(f, [~r/^\|\s*x\s*\|/, ~r/RESOLVED by bugfix legacy-logout-per-device \(LL9\)/, closed]), "row x resolved, Gate column closed"
    assert length(Regex.scan(~r/RESOLVED \(bugfix legacy-logout-per-device\)/, f)) >= 2, "story-5 bullet (c) and the story-9 bullet"
    assert line_with?(f, [~r/^- I-14\b/, ~r/\(r\) is done/, ~r/best effort/i, ~r/\(LL11\)/])

    assert line_with?(f, [~r/^\|\s*s\s*\|/, ~r/device_lists/, ~r/before `oauth_enabled`/]), "row s is a gate item now (oracle O2)"
    refute line_with?(f, [~r/^\|\s*s\s*\|/, ~r/non-gating, epic-end review/])

    assert f =~ ~r/^## From bugfix legacy-logout-per-device \(2026-10-12\)/m
    [_, sec] = String.split(f, ~r/^## From bugfix legacy-logout-per-device \(2026-10-12\)[^\n]*\n/m, parts: 2)
    sec = sec |> String.split(~r/^## /m, parts: 2) |> hd()
    assert sec =~ "Txn-id dedup" and sec =~ ":NebuTxnDedup" and sec =~ ~r/per user, not per\s+device/ and sec =~ ~r/O5/

    ids = fn text -> Regex.scan(~r/^\|\s*([a-z]{1,3}[0-9]?)\s*\|/m, text) |> Enum.map(&Enum.at(&1, 1)) end
    new_ids = ids.(sec)
    assert new_ids != [], "the new section has a table row with the next free item letter"
    old_ids = ids.(String.replace(f, sec, ""))
    assert MapSet.disjoint?(MapSet.new(new_ids), MapSet.new(old_ids)), "follow-up ids collide with earlier sections: #{inspect(Enum.filter(new_ids, &(&1 in old_ids)))}"
  end

  test "AC11 (LL): 07-deployment: row r closed, row s is a gate row, (x) and (s) left the non-gating list" do
    sec = deploy_section()
    assert line?(sec, [~r/^\|\s*r\s*\|/, ~r/Legacy `POST \/logout` per device/, ~r/closed by bugfix legacy-logout-per-device/, ~r/server/])
    refute line?(sec, [~r/^\|\s*r\s*\|/, ~r/today it wipes every session/])
    assert line?(sec, [~r/^\|\s*s\s*\|/, ~r/device_lists\.changed/, ~r/open/, ~r/server/])
    refute sec =~ "(x) legacy `rotate_tokens/1` lock,"
    refute sec =~ "(s) `device_lists.changed` on device deletion,"
  end

  test "AC11 (LL): matrix-api-scope.md: the logout row and the deviations paragraph describe the per-device legacy logout" do
    scope = File.read!(Path.expand("../../../../docs/matrix-api-scope.md", __DIR__))
    [row] = Regex.run(~r/^\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/logout`[^\n]*$/m, scope)
    assert row =~ "ONLY the presented credential's device", "legacy part of the row"
    assert row =~ "legacy-logout-per-device" and row =~ "500 M_UNKNOWN" and row =~ ~r/unbound raw JWT/i
    assert row =~ ~r/OAuth/ and row =~ ~r/current device/i, "the old row pin (OAuth part) stays"
    refute row =~ "user-wide"
    flat = String.replace(scope, ~r/\s+/, " ")
    assert flat =~ "Legacy `POST /_matrix/client/v3/logout` is per device since the bugfix legacy-logout-per-device (gate item r closed)."
    refute flat =~ ~r/is still the user-wide wipe/
  end

  # ════════════════════════════════════════════════════════════════════════════
  # story oauth-hardening-hygiene (phase 2, P8), AC13: the exact doc edits
  # ════════════════════════════════════════════════════════════════════════════

  defp deploy_doc, do: File.read!(Path.expand("../../../../docs/architecture/07-deployment.md", __DIR__))
  defp followups_doc, do: File.read!(Path.expand("../../../../docs/stories/oauth-broker/follow-ups.md", __DIR__))

  defp p8_section(text) do
    assert text =~ ~r/^##+ Hardening and hygiene \(story oauth-hardening-hygiene\)/m,
           "ADR-033 needs the section \"Hardening and hygiene (story oauth-hardening-hygiene)\""

    [_, sec] = String.split(text, ~r/^##+ Hardening and hygiene \(story oauth-hardening-hygiene\)[^\n]*\n/m, parts: 2)
    sec |> String.split(~r/^## /m, parts: 2) |> hd()
  end

  test "AC13 (P8): ADR section 'Hardening and hygiene (story oauth-hardening-hygiene)' records HY1-HY17, placed after the client revocation section", %{text: t} do
    sec = p8_section(t)
    for n <- 1..17, do: assert(sec =~ Regex.compile!("\\bHY#{n}\\b"), "HY#{n} is recorded")

    {revocation_at, _} = :binary.match(t, "## Client revocation and same-origin hardening (story oauth-client-revocation)")
    {hy_at, _} = :binary.match(t, "Hardening and hygiene (story oauth-hardening-hygiene)")
    assert hy_at > revocation_at, "the HY section comes after 'Client revocation and same-origin hardening'"
  end

  test "AC13 (P8): the HY section names the env var, the rotation functions, the ADR-020 bounded-staleness note, HY10 as deferred and the manual verification", %{text: t} do
    sec = p8_section(t)
    assert sec =~ "NEBU_OAUTH_CONFIG_CACHE_MS"
    assert sec =~ "rotate_oauth_signing_key"
    assert sec =~ "replace_oauth_signing_key"
    assert sec =~ "ADR-020" and sec =~ ~r/bounded staleness/i, "HY2: node-local state accepted as bounded staleness"
    assert line?(sec, [~r/HY10/, ~r/deferred/i]), "HY10 (rotated-row cap) is recorded as deferred"
    assert line?(sec, [~r/HY17/, ~r/deferred|DEFERRED/]), "HY17 (SecretBox v2) is a deferred design"
    assert sec =~ ~r/Manual verification/i
    assert sec =~ "__Host-nebu_oa_" and sec =~ "__Host-nebu_acct_"
    assert sec =~ "000047"
  end

  test "AC13 (P8): ADR-033 old 'no cache' sentences carry the HY1 note; the story-3 section points at HY12/HY13", %{text: t} do
    for id <- ["C2", "V2"] do
      [line] = t |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- **#{id} "))
      assert line =~ ~r/NEBU_OAUTH_CONFIG_CACHE_MS|\bHY1\b/, "#{id} says 'no cache': it must carry the HY1 note (cached per node for at most NEBU_OAUTH_CONFIG_CACHE_MS)"
    end

    [_, s3] = String.split(t, ~r/^## Token endpoint, sessions, refresh and id_token \(story 3\)[^\n]*\n/m, parts: 2)
    s3 = s3 |> String.split(~r/^## /m, parts: 2) |> hd()
    assert s3 =~ ~r/Rotation tooling: HY12\/HY13/
  end

  test "AC13 (P8): 07-deployment: heading, oauth_enabled row (gate sentence replaced), the env row and the cache wording" do
    d = deploy_doc()
    assert line?(d, [~r/^## OAuth 2\.0 Authorization Server Configuration/, ~r/oauth-hardening-hygiene/]), "heading names the story"

    [row] = Regex.run(~r/^\| `oauth_enabled` \|[^\n]*$/m, d)
    refute row =~ "GATE: before `oauth_enabled` can be true", "the stale GATE sentence is gone"
    refute row =~ "must be implemented"
    assert row =~ "Trusted-proxy client-IP resolution is implemented (`NEBU_TRUSTED_PROXY_CIDRS`)"
    assert row =~ "the operator verifies it before activation (gate item 1)"
    assert row =~ "within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s)"

    assert line?(d, [~r/NEBU_OAUTH_CONFIG_CACHE_MS/, ~r/0\.\.5000/, ~r/2000/, ~r/0 = off|`0`/]), "env row: range, default, 0 = off"

    refute d =~ "evaluated per request on every node, no cache"
    refute d =~ "It takes effect on the next request on every node"
    assert length(Regex.scan(~r/within `NEBU_OAUTH_CONFIG_CACHE_MS` \(default 2 s\) on every node/, d)) >= 2,
           "both former 'per request / next request on every node' sentences name the TTL"
  end

  test "AC13 (P8): 07-deployment: signing key table (next, one_next index, 900 s, 000047), binding cookies and the X-Forwarded-Proto note" do
    d = deploy_doc()
    [row] = Regex.run(~r/^- `oauth_signing_keys`[^\n]*$/m, d)
    assert row =~ ~r/`active`\|`next`\|`retired`/
    assert row =~ "oauth_signing_keys_one_next" and row =~ "900 s" and row =~ "000047"

    assert d =~ "__Host-nebu_acct_<16 hex>" and d =~ "__Host-nebu_oa_<16 hex>"
    assert line?(d, [~r/__Host-nebu_acct_/, ~r/Path=\/; Secure/]), "binding cookie attributes on https"
    assert line?(d, [~r/X-Forwarded-Proto/, ~r/consent/i, ~r/account/i, ~r/binding|nebu_oa_/]), "HY15: the proxy note covers all four cookies"
  end

  test "AC13 (P8): 07-deployment: the kill-switch section names the GET /login and openid-configuration rate limits" do
    d = deploy_doc()
    [_, after_heading] = String.split(d, ~r/Kill switch, caches and rollback/, parts: 2)
    window = String.slice(after_heading, 0, 6000)
    assert window =~ ~r/GET \/login|`GET \/_matrix\/client\/v3\/login`/
    assert window =~ ~r/rate limit/i and window =~ "openid-configuration"
  end

  test "AC13 (P8): 07-deployment: non-gating list drops (am), (an), (j)/(ah), (p), story-3 (b) and marks (al), (t), (o) 'deferred (P8)'" do
    d = deploy_doc()
    [line] = d |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Non-gating items to know about:"))
    for dropped <- ["(am)", "(an)", "(j)", "(ah)", "(p)", "story-3 (b)"], do: refute(line =~ dropped, "#{dropped} left the non-gating list")
    for kept <- ["(al)", "(t)", "(o)"], do: assert(line =~ kept, "#{kept} stays")
    assert length(Regex.scan(~r/deferred \(P8\)/, line)) >= 3, "(al), (t) and (o) are marked deferred (P8)"
  end

  test "AC13 (P8): 07-deployment: subsection 'Rotating the id_token signing key' after 'Revoking a client' with both commands and the secret-rotation note" do
    d = deploy_doc()
    assert d =~ ~r/^###+ Rotating the id_token signing key/m
    {rev_at, _} = :binary.match(d, "Revoking a client")
    [_, sec] = String.split(d, ~r/^###+ Rotating the id_token signing key[^\n]*\n/m, parts: 2)
    {rot_at, _} = :binary.match(d, "Rotating the id_token signing key")
    assert rot_at > rev_at
    sec = sec |> String.split(~r/^##+ /m, parts: 2) |> hd()

    assert sec =~ "bin/nebu rpc 'IO.inspect(Nebu.Release.rotate_oauth_signing_key())'"
    assert sec =~ ~r/15 min/ and sec =~ ~r/(again|second)/i
    assert sec =~ "replace_oauth_signing_key(:emergency)" and sec =~ ~r/10 min/
    assert sec =~ "NEBU_INTERNAL_SECRET" and sec =~ "per_refresh" and sec =~ ~r/\(al\)/
  end

  test "AC13 (P8): follow-ups.md: RESOLVED markers for j, ah, p, story-3 (b), I-10..I-13, am, an; (al), (t), (o) re-assessed" do
    f = followups_doc()
    assert line?(f, [~r/^\|\s*j\s*\|/, ~r/RESOLVED/, ~r/HY9/])
    assert line?(f, [~r/^\|\s*ah\s*\|/, ~r/RESOLVED/, ~r/HY9/, ~r/HY15/])
    assert line?(f, [~r/^\|\s*p\s*\|/, ~r/RESOLVED/, ~r/HY4/, ~r/HY13/, ~r/SecretBox part = \(al\), deferred/])
    assert line?(f, [~r/Signing-key rotation tooling/, ~r/RESOLVED/, ~r/HY11/, ~r/HY12/])
    assert line?(f, [~r/I-10/, ~r/RESOLVED/, ~r/HY6/])
    assert line?(f, [~r/I-11/, ~r/RESOLVED/, ~r/HY7/])
    assert line?(f, [~r/I-12/, ~r/RESOLVED/, ~r/HY1/])
    assert line?(f, [~r/I-13/, ~r/RESOLVED/, ~r/HY8/])
    assert line?(f, [~r/^\|\s*am\s*\|/, ~r/RESOLVED/, ~r/HY1/, ~r/HY3/, ~r/spec-unlimited discovery paths/, ~r/\(br\)/])
    assert line?(f, [~r/^\|\s*an\s*\|/, ~r/RESOLVED/, ~r/HY5/])
    assert line?(f, [~r/^\|\s*al\s*\|/, ~r/design in oauth-hardening-hygiene HY17; deferred \(two-release rollout\)/])
    assert line?(f, [~r/^\|\s*t\s*\|/, ~r/re-assessed in P8: deferred/])
    assert line?(f, [~r/^\|\s*o\s*\|/, ~r/re-assessed in P8: deferred/, ~r/\(bs\)/])
  end

  test "AC13 (P8): follow-ups.md: new section 'From story oauth-hardening-hygiene (phase 2, P8, 2026-10-13)' with bq, br, bs, bt" do
    f = followups_doc()
    assert f =~ ~r/^## From story oauth-hardening-hygiene \(phase 2, P8, 2026-10-13\)/m
    [_, sec] = String.split(f, ~r/^## From story oauth-hardening-hygiene[^\n]*\n/m, parts: 2)
    sec = sec |> String.split(~r/^## /m, parts: 2) |> hd()

    assert line?(sec, [~r/^\|\s*bq\s*\|/, ~r/Scheduled \/ UI signing-key rotation/, ~r/HY12/, ~r/non-gating/])
    assert line?(sec, [~r/^\|\s*br\s*\|/, ~r/Spec-unlimited discovery paths/, ~r/HY3/, ~r/non-gating/])
    assert line?(sec, [~r/^\|\s*bs\s*\|/, ~r/Rotated-row growth/, ~r/tombstone/, ~r/HY10/, ~r/non-gating/])
    assert line?(sec, [~r/^\|\s*bt\s*\|/, ~r/NEBU_OAUTH_CONFIG_CACHE_MS/, ~r/HY2/, ~r/operator note/])

    ids = fn text -> Regex.scan(~r/^\|\s*([a-z]{1,3}[0-9]?)\s*\|/m, text) |> Enum.map(&Enum.at(&1, 1)) end
    old_ids = ids.(String.replace(f, sec, ""))
    # ids bq-bt: bh-bl are taken by the room-summary section, bm-bo by the planned device-lists story
    for id <- ~w(bq br bs bt), do: refute(id in old_ids, "follow-up id #{id} collides with an earlier section")
  end
end
