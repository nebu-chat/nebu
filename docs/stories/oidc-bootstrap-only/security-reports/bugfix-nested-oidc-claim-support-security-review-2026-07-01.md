## Security Review — bugfix-nested-oidc-claim-support

**Diff scope:** staged diff — `server/lib/nebu/admin/auth.ex` (+71/-26) + `server/test/nebu/admin/admin_oidc_login_test.exs` (+101). Auth/claims-logic change: `admin_claim?/1` and the Bootstrap-Wizard claim-picker (`extract_discovered_claims/1`) upgraded from a flat top-level claim scan to a recursive scan/flatten over arbitrary nesting depth, so Keycloak-shaped nested role claims (`realm_access.roles`, `resource_access.<client>.roles`) are matched/surfaced the same way as flat Dex-style `groups`.
**Date:** 2026-07-01
**Reviewer:** Kassandra (SEC Gate 1 — --bug pipeline run, no formal story file)
**Base:** staged working tree on `bugfix/remove-default-scopes`

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM (pre-accepted, WIDENED — non-blocking) | `auth.ex:1108` `admin_claim?/1` → `claim_value_matches?/2` (`auth.ex:1113-1123`) | Key-agnostic admin-gate value scan now recurses at any nesting depth. A non-admin whose IdP lets them self-set a claim value equal to the `admin_group_claim` marker — at ANY depth — is misclassified as admin. | Track the claim KEY/path alongside the value; scope the gate to the operator-selected path only. Deferred to the centralize-OIDC-claim-resolution follow-up (same decision as prior fix). |
| 2 | LOW (informational) | `claim_value_matches?/2` / `flatten_discovered_claims/2` — non-tail recursion, no depth guard | Adversarially deep/wide claims tree could in theory drive stack/CPU. | None required — see Detail #2. Optional hardening: cap depth if a future path ever scans an unverified/untrusted claim source. |
| 3 | LOW (informational) | `extract_discovered_claims/1` claim-picker now surfaces nested values | Operator could pick a nested path that is more attacker-influenceable than a flat IdP-managed one; nested VALUES now visible in bootstrap UI. | None required — see Detail #3. |

### Detail

**Finding #1 — Widening the any-key value scan from flat to arbitrary depth [MEDIUM, pre-accepted, non-blocking]**

The prior same-day fix (`bugfix-unify-admin-matrix-oidc-identity`) already accepted (MEDIUM, 0 CRITICAL/HIGH) that `admin_claim?/1` scans ALL claim VALUES regardless of key, so a non-admin who can self-set a claim value equal to the marker at their IdP is misclassified as admin. This fix widens that same scan from flat top-level values to every value at every nesting depth via `claim_value_matches?/2`.

Assessment of whether the widening changes the risk profile: **it does not meaningfully change it.** This is a strictly-larger attack surface of the *same* class, not a new class. The determining factor for exploitability is unchanged: whether an ordinary, non-admin user can *self-service edit* a claim whose value reaches the marker string. At the IdPs in scope:

- Self-service-editable claims at Keycloak/Dex/Okta/Auth0 are the standard OIDC profile claims (`name`, `preferred_username`, `nickname`, `email`, `address.*`). These are overwhelmingly flat/top-level and were ALREADY in the accepted flat-scan surface. `address` is the one standard nested object, but its sub-fields (locality, region, formatted, street_address) are free-text location strings — setting one literally to `instance_admin` and having an operator have configured `instance_admin` as the marker is the same self-set-a-profile-field path already accepted, one level deeper. The new nested pin test (`profile.custom_role`) documents exactly this.
- The genuinely nested claims that motivated the fix — `realm_access.roles`, `resource_access.<client>.roles` (Keycloak), group/role claims generally — are IdP-managed / realm-admin-managed, NOT end-user self-service-editable. A user cannot grant themselves a realm role. So the marginal newly-reachable self-editable surface is small (essentially nested profile objects like `address`), and the high-value nested paths are not attacker-writable by an ordinary user.

Trust boundary is correctly scoped: `admin_claim?/1` is only ever reached with claims that passed `OidcPlug.verify_token/1` (signature/alg-allowlist/iss/aud/exp) — verified at `auth.ex:467` before `put_current_user` at 494/244. The claims tree is a signature-verified token from the operator-configured IdP, which is already the authentication trust anchor for the whole flow. An attacker cannot inject arbitrary claim STRUCTURE without either controlling the IdP or being able to self-set a claim through the IdP's normal self-service surface — the latter being precisely the accepted risk.

Conclusion: **the same "accepted, non-blocking" verdict holds.** The widening does not warrant escalation. The real fix (path-scoped gate + centralized claim resolution) remains the tracked follow-up; the SEC NOTE was correctly updated to describe the nested surface, and a nested-level pin test now guards the accepted behavior against silent change. This finding matches MEMORY pattern [[scope-widening-refeeds-claim-scanner]] — here the scan's TRAVERSAL widened rather than its INPUT feed, but the lesson (re-audit the key-agnostic matcher when its reachable claim set grows) is the same and was correctly applied by the author in the SEC NOTE + pin test.

**Finding #2 — Unbounded recursion in the claim walkers [LOW, informational]**

`claim_value_matches?/2` and `flatten_discovered_claims/2` are non-tail-recursive with no explicit depth guard. This is acceptable and correctly documented in the code comment:

- `target` (from `admin_group_claim/0`, `auth.ex:1256`) is always a binary — DB-guarded (`is_binary(value) and value != ""`) or the literal `@default_admin_group_claim`. Never attacker-controlled. The scalar-equality base clause (`claim_value_matches?(target, target)`) cannot be tricked into non-termination.
- Recursion depth is bounded by the JSON structure of a signature-verified token. To send an adversarially deep/wide tree, an attacker must first control the IdP (or a signing key) — at which point they own the auth flow outright and DoS via deep JSON is not the interesting capability. The BEAM has a large per-process heap and grows the stack on the heap (no fixed C stack limit), so a pathological but validly-signed token would allocate rather than smash the stack; the token also had to survive JSON parse + JWKS signature verify first, each of which is itself bounded work on the same input.

No change required. Flagged only so that IF a future change ever routes an *unverified* or otherwise less-trusted claim source through these walkers, a depth cap should be added at that point.

**Finding #3 — Nested claim paths in the Bootstrap-Wizard claim-picker [LOW, informational]**

`extract_discovered_claims/1` now surfaces nested values as `dot_path`-keyed options (e.g. `realm_access.roles`), rendered by `select_claim_html/1`.

- Information disclosure: BOTH the dot-path key and the value are HTML-escaped via `esc/1` (`auth.ex:1552-1553`), and only non-empty string leaves are surfaced (`flatten_discovered_claims/2` binary clause). No new XSS. On disclosure of nested VALUES: the picker only ever runs on the operator's OWN freshly-verified token during first-run bootstrap, rendered back to that same operator — it is not a cross-user view. Any nested string values now shown (that the old flat scanner skipped) belong to the authenticating operator and are shown only to them. This is not a meaningful information-disclosure escalation. (Note: opaque/structured secrets like nested access tokens are not string leaves the operator would typically see, and standard ID tokens do not embed such secrets; no realistic sensitive-value exposure identified.)
- "Operator tricked into picking an attacker-influenceable nested path": the picker is a first-run, single-operator setup step; the operator deliberately selects the marker. The dot-path display (`realm_access.roles`) actually IMPROVES safety over a bare key by showing provenance, helping the operator pick an IdP-managed role path over a free-text profile field. Net-neutral-to-positive.
- Anti-forgery integrity preserved: `bootstrap_confirm_claim/2` validates the POSTed `admin_group_claim` against `discovered_claim_values/2`, a VALUE-only MapSet (`auth.ex:561` unpacks `[_k, v]`, keys discarded). The dot-path keys are display-only and never gate anything, so the accepted cosmetic dot-path key-collision (code-review cycle-0 MINOR) has no security impact — confirmed. Confirm still fails CLOSED on absent/malformed stash.

### Backward compatibility (Q4 — confirmed no regression)

Flat Dex-style claims resolve identically: `flatten_discovered_claims(_, prefix=nil)` on a top-level scalar returns `{bare_key, value}` via `dot_path(nil, key) => key` — original bare key preserved. List-of-strings leaves flatten to `{key, item}` as before. `admin_claim?/1`'s list clause still short-circuits on `target in list` before recursing. Tests explicitly pin both flat `groups` list-match and bare top-level string-match as unchanged. Verified against diff + `extract_discovered_claims/1` code.

### ADR compliance (Q5 — confirmed unaffected)

ADR-018 (no domain model): only pre-existing inline SQL touched; new code is pure in-process helpers. ADR-019/021 (single OTP app / pure Elixir): pure-function additions, no new processes/deps. ADR-020 (public-API rule): no new cross-domain calls (`Nebu.Matrix.UserId.from_claims/2` call site unchanged). ADR-022 (OIDC bootstrap-only): claim resolution stays inside the Bootstrap-Wizard / `server_config` path; no `NEBU_OIDC_*` env introduced. No new endpoints, routes, or migrations. No new injection/XSS/CSRF/secret-handling surface.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 1 — pre-accepted risk (any-key claim-value scan), WIDENED flat→nested, same class, same non-blocking verdict; real fix tracked as centralize-claim-resolution follow-up
LOW: 2 — both informational, no action required

**Verdict: APPROVED / CLEAN (no CRITICAL/HIGH).** The widening does not change the accepted-risk verdict of the prior fix. Classification: **CLEAN**.
