# Security Review — centralize-claim-resolution (epic oidc-simplification) — 2026-07-01

**Agent:** Kassandra
**Diff base:** `git diff --staged`
**Classification:** CLEAN
**Config:** `blocking_severity=CRITICAL`, `model=claude-opus-4-8[1m]`

## Executive Summary

Pure refactor. Two recursive claim-traversal helpers (`claim_value_matches?/2`,
`flatten_discovered_claims/2`) move from private clauses in `Nebu.Admin.Auth` into a new
shared-infra module `Nebu.Web.OidcClaims`, where they become public. I diffed the old and new
function bodies clause-by-clause: they are byte-identical except `defp`→`def` — zero recursion or
matching-semantics drift. No new attack surface, no info-leak surface, no ADR-020 boundary
violation. The pre-existing, already-accepted "any-key-scan" admin-elevation risk is unchanged in
behavior; its trust-boundary rationale was carried over verbatim (AC3). One INFO on the
centralization-of-risk question (item 4), which I judge adequately mitigated by the preserved SEC
NOTE — not a new finding.

## Findings

No CRITICAL, HIGH, MEDIUM or LOW findings. Detailed answers to the five scoped questions are
recorded below as INFO for the audit trail.

### [INFO] Semantic equivalence verified — zero drift on the move (question 3)

- **CWE / OWASP:** n/a (positive finding)
- **Datei:** `server/lib/nebu/web/oidc_claims.ex:50-88`, `server/lib/nebu/admin/auth.ex` (removed lines in staged diff)
- **Beschreibung:** I compared the removed private clauses in `auth.ex` against the new public
  clauses in `oidc_claims.ex`. For `claim_value_matches?/2`: all four clauses (binary-equals-target,
  is_map, is_list, catch-all) are identical in order, guards, and body — only `defp`→`def` differs.
  For `flatten_discovered_claims/2`: all four clauses (is_map, is_list, `is_binary and s != ""`,
  catch-all) are identical; the `dot_path/2` helper moved with it and correctly stayed private. The
  `is_binary and s != ""` empty-string exclusion and the list-membership shortcut
  (`target in list or ...`) are both preserved.
- **Impact:** None. Behavior is provably unchanged.
- **Empfehlung:** None.
- **Referenz:** OWASP ASVS V1.1.4 (verified security semantics on refactor).

### [INFO] No new callers; new public surface is generic but not currently misused (questions 1 & 2)

- **CWE / OWASP:** CWE-710 (informational — coding-standard/boundary observation)
- **Datei:** `server/lib/nebu/admin/auth.ex:1110`, `:1494`
- **Beschreibung:** Grep across `lib/` confirms the only two production callers are the same two that
  called the private originals: `admin_claim?/1` (line 1110) and `extract_discovered_claims/1`
  (line 1494). No third module invokes `Nebu.Web.OidcClaims` yet. The functions are now generic and
  callable from any domain, but `Nebu.Admin.Auth` already depends on five other `Nebu.Web.*`
  shared-infra modules (`JwksCache`, `OidcConfig`, `SecretBox`, `TokenDenylist`, `SessionConfig`),
  so the new cross-namespace call follows the established ADR-020 shared-infra pattern rather than
  breaching it. On the info-leak question: the module is a pure, stateless set of functions with no
  `Logger`, no `IO.inspect`, no Compliance/audit writes, no config or process state (verified). It
  returns only data derived from its own arguments to its caller — it cannot itself leak a claim to
  a log, a different domain, or an unprivileged surface. Any leak risk would live in a future
  caller's handling of the return value, not in this module.
- **Impact:** None today. The theoretical surface (a future dev calls the recursive matcher on an
  unexpected data shape) is inherent to any public utility and carries no exploit path here.
- **Empfehlung:** None required. If future callers appear, review them individually — the recursion
  has no depth guard (see next finding).
- **Referenz:** ADR-020 (Public-API rule); `.claude/rules/admin-conventions.md`.

### [INFO] Centralizing the accepted any-key-scan risk — preserved SEC NOTE is sufficient warning (question 4)

- **CWE / OWASP:** CWE-863 (Incorrect Authorization) — pre-existing, accepted, out of scope
- **Datei:** `server/lib/nebu/web/oidc_claims.ex:28-45` (carried-over SEC NOTE), `server/lib/nebu/admin/auth.ex:1079-1097` (admin-specific SEC NOTE retained)
- **Beschreibung:** The already-accepted "any-key-scan" risk — `admin_claim?/1` matching the admin
  marker anywhere in the claims tree regardless of key/depth, tracked for real fix in follow-up
  `scope-admin-claim-to-path` — is not modified by this story. The fair question this refactor
  raises is whether *centralizing* the recursive walker into a reusable public utility makes it
  *easier* for a future admin-like feature to reuse it and unknowingly inherit the same
  trust-boundary assumption (target must be non-attacker-controlled; depth is bounded only because
  the token is signature-verified). Two mitigations are present and, in my judgment, adequate: (1)
  the full rationale comment was carried over verbatim into `oidc_claims.ex:28-45`, sitting directly
  above the two walkers, explicitly stating the "target is always a binary — never
  attacker-controlled" and "depth bounded by trusted IdP token" assumptions; (2) the
  admin-elevation-specific SEC NOTE (with its Kassandra-MEDIUM history and follow-up pointer)
  remains at the actual authorization decision point in `auth.ex:1079-1097`, which is where a future
  reviewer of an admin feature would look. The trust-boundary assumption travels with the code.
- **Impact:** No change to the current risk posture. Centralization does not worsen the accepted
  risk; the warning documentation moved with the logic.
- **Empfehlung:** None for this story. When `scope-admin-claim-to-path` lands, update the SEC NOTE in
  `oidc_claims.ex` accordingly. I explicitly considered and rejected raising this as a new MEDIUM/LOW
  specific to the centralization choice: the exploit path is identical to the pre-existing accepted
  finding, no new caller has been introduced, and the guiding comment is co-located with the code —
  raising a duplicate finding would be over-triage.
- **Referenz:** follow-up story `scope-admin-claim-to-path`; prior reviews
  `bugfix-unify-admin-matrix-oidc-identity`, `bugfix-nested-oidc-claim-support` (2026-07-01).

### [INFO] OWASP/CWE/STRIDE pass over the diff (question 5)

- **CWE / OWASP:** n/a
- **Datei:** whole staged diff
- **Beschreibung:** No injection surface (no SQL, no shell, no interpolation into markup — the
  `esc/1` HTML-escape helper in `auth.ex` is untouched). No secrets, no crypto, no TLS config, no
  new external input, no deserialization, no logging change. STRIDE: no change to Spoofing (auth
  target still `admin_group_claim/0`, DB-guarded), Tampering, Repudiation (no audit path touched),
  Information Disclosure (pure functions, no output sink), DoS (recursion depth-guard status
  unchanged from the accepted-risk baseline — input remains a signature-verified IdP token),
  Elevation of Privilege (matching semantics identical). Test file adds 34 pure unit tests pinning
  the extracted behavior (flat, nested Keycloak-shaped, list-of-maps, empty-string exclusion,
  deep-nesting, non-dedup) — a net positive for the security property.
- **Impact:** None.
- **Empfehlung:** None.
- **Referenz:** OWASP Top 10 2021 (A01, A03, A09 reviewed, all n/a).

## Nebu Invariants Check

| Invariant                                   | Status |
|---------------------------------------------|:------:|
| Compliance RSP coverage                     | ✅ (no DB/table change) |
| `reason` field on compliance access         | ✅ (no compliance access path touched) |
| Audit-log immutability                      | ✅ (no audit path touched) |
| `instance_admin` notification (if in-scope) | ✅ (not in scope) |
| OIDC token validation (`iss`/`aud`/`exp`)   | ✅ (validation upstream, unchanged; this code runs on already-verified claims) |
| Matrix Power Level checks                   | ✅ (not in scope) |
| No hardcoded secrets                        | ✅ |
| TLS 1.3 enforcement                         | ✅ (not in scope) |
| AES-256-GCM correctness                     | ✅ (not in scope) |
| Ed25519 verify-before-accept                | ✅ (not in scope) |
| No secrets in logs / error messages         | ✅ (module has no logging; verified) |

## Overall Risk

| Severity  | Count |
|-----------|:-----:|
| CRITICAL  | 0 |
| HIGH      | 0 |
| MEDIUM    | 0 |
| LOW       | 0 |
| INFO      | 4 |

## Pipeline Decision

- **CLEAN** — no CRITICAL / HIGH findings. Pipeline may proceed. The pre-existing any-key-scan risk
  remains tracked in follow-up `scope-admin-claim-to-path`; this refactor neither introduces nor
  worsens it.

---

*Generated by Kassandra — BMAD Security Review Agent. This report is an immutable audit artifact — do not edit retrospectively; create a new review if re-analysis is required.*
