## Security Review — bugfix-bootstrap-trailing-newline (epic: oidc-bootstrap-only)

**Diff scope:** Staged diff. Functional change: `server/lib/nebu/admin/bootstrap_controller.ex` — `save_step3/2` no longer calls `String.trim/1` on `matrix_oidc_extra_scopes` / `admin_oidc_extra_scopes` before `validate_scope_string/1`. Two pipeline step-result notes (code-review, test-review) also staged (docs, no runtime impact).
**Reviewer:** Kassandra
**Date:** 2026-06-30

### Verdict: CLEAN — APPROVED

No CRITICAL or HIGH findings. The fix is correct and complete. One LOW (defense-in-depth / consistency) and one INFO recorded below.

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `bootstrap_controller.ex:233`, `config_controller.ex:69`, `auth.ex:1402` | `String.split(value, " ", trim: true)` splits only on the literal `0x20` space, not the whitespace class. Defense-in-depth gap, not exploitable (see Detail). | Optional: split on `~r/\s+/` OR document that the `\z` regex is the sole newline gate. No change required for this fix. |
| 2 | INFO | `bootstrap_controller.ex:165-169` | The fix itself — validate raw, trim only on persist — is correct. | None. |

---

### Detail

**Finding #1 — `String.split` on literal space relies entirely on the `\z` regex** [LOW]

All three scope boundaries tokenize with `String.split(value, " ", trim: true)`. A space split does NOT separate on `\n`, `\r`, or `\t`. So `"profile email\n"` becomes `["profile", "email\n"]`, and the trailing-newline token is caught *only* by the regex's `\z` anchor. This is exactly the historical weakness recorded in agent memory (`regex-anchor-newline`): when the regex used `$` instead of `\z`, `"email\n"` PASSED, because `$` in PCRE/Elixir matches immediately before a single trailing `\n`.

The regex is now `~r/^[a-zA-Z0-9_:.\-]+\z/` in all three locations (confirmed below), so the trailing-newline token is correctly rejected. This is therefore a defense-in-depth observation, not an exploit: the whitelist is the real gate, and it now holds. Splitting on `\s+` would make the design intent explicit and remove the dependency on a single regex metacharacter, but is not required.

**Finding #2 — Fix correctness** [INFO]

`save_step3/2` previously trimmed the raw input before validation, which silently stripped trailing `\n`/`\r`/`\t` so the `\z` anchor never saw them — the trim *bypassed* the very anchor that the prior security review hardened. The fix passes the raw param straight into `validate_scope_string/1`. Persistence-time trimming (`save_claim_mapping/1` line 225) is preserved and is safe normalization because it runs only AFTER validation has passed.

---

### Answers to the three security questions

**1. Bypass analysis — is the fix complete? Other paths in `save_step3/2` / `save_claim_mapping/1`?**

Complete. There is no remaining path in `save_step3/2` by which an invalid character reaches storage:

- `save_step3/2` (line 164-170): both scope params are read raw (lines 165-166) and gated by `validate_scope_string/1` (lines 168-169) BEFORE `save_claim_mapping/1` is ever reached. On `{:error, _}` it re-renders step 3 with HTTP 200 and never persists.
- `save_claim_mapping/1` (line 211-228) is invoked only inside the `with ... do` success branch, i.e. only after both scope strings validated. Its own `String.trim` (line 225) is post-validation normalization, not a gate, so it cannot re-admit a value the validator rejected.
- The non-scope keys persisted in `save_claim_mapping/1` (`@default_claim_mapping` line 212-215, `@refresh_mode_defaults` line 217-220) are claim-mapping / refresh-mode fields, NOT scope strings. They were never in scope for the `\z` regex; refresh modes are enum-whitelisted (`v in ["offline","online"]`). No newline-injection sink there.

Residual note (out of scope, pre-existing): `validate_scope_string/1` accepts an empty string as `:ok` (the `Enum.find` returns nil for `[]`). That is intended — empty means "fall back to defaults" — and is not a bypass.

**2. Consistency — are all three boundaries protected against newline injection?**

Yes, all three are now consistent and correct:

| Boundary | Regex anchor | Trim-vs-validate order | Status |
|---|---|---|---|
| `bootstrap_controller.ex` `save_step3/2` → `validate_scope_string/1:237` | `\z` | validate raw, trim on persist (THIS FIX) | CORRECT |
| `config_controller.ex` `save_scopes/2:72` | `\z` | validates `params[key]` raw (line 68), trims only inside the `errors == []` persist branch (line 80) | CORRECT |
| `auth.ex` `do_complete_bootstrap/2:1403` | `\z` | reads `draft[key]` and validates without trimming; never trims (promotes raw `v`) | CORRECT |

Before this fix `bootstrap_controller` was the odd one out: its regex was already `\z`, but the pre-validation `String.trim` neutralized the anchor. The two siblings already followed validate-raw-then-trim. This fix brings `bootstrap_controller` into line, so the three write boundaries are now uniform. (CWE-20 Improper Input Validation — closed at all three.)

**3. Scope-injection worst-case impact / original severity**

Worst case had an attacker been able to land a trailing `\n` (or `\r`, `\t`) in a persisted scope value:

- **Sink:** the stored scope flows into the OIDC authorization request via `URI.encode_query/1` (auth.ex:341, matrix/sso_login.ex:123) and into the `scope` query parameter. `URI.encode_query/1` percent-encodes control characters, so `\n` becomes `%0A`. There is therefore NO live CRLF / HTTP-header / request-splitting injection at the live sink (rules out CWE-93 CRLF Injection in practice).
- **Realistic impact:** a malformed `scope=...%0A` parameter sent to the IdP, which the IdP rejects or ignores — at most a self-inflicted broken-login (availability nuisance for the operator who typed it), plus a polluted `server_config` row.
- **Reachability:** the only actor who can submit step-3 scopes is the bootstrap operator (pre-auth bootstrap flow, but bootstrap is single-use and operator-driven). This is not an anonymous-attacker-controlled value in normal operation; it is operator self-injection.

**Original severity: MEDIUM.** Rationale: a real input-validation defect (CWE-20) that bypassed the intended whitelist, but the downstream sink percent-encodes the payload, so it never becomes a header/URL injection. This matches the ceiling recorded in agent memory for this exact pattern: "If the sink is `URI.encode_query` or equivalent, MEDIUM." Had any sink built a header or URL by raw string concatenation without encoding, this would escalate to HIGH (live CRLF). It does not, so MEDIUM is the correct original rating — and the staged fix closes it.

OWASP: A03:2021 Injection (boundary), A04:2021 Insecure Design (validation bypass via pre-normalization). STRIDE: Tampering. CWE: CWE-20 (Improper Input Validation), CWE-93 considered and excluded due to percent-encoding at the sink.

---

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 1 — advisory (split-on-literal-space, defense-in-depth)
INFO: 1

**Verdict: APPROVED.** The fix correctly removes the pre-validation trim that was silently bypassing the `\z` anchor in `bootstrap_controller.ex`, restoring consistency with the two sibling boundaries. The previously-identified trailing-newline weakness is now closed at all three write boundaries. No new vulnerabilities introduced. Regression test `bootstrap_live_test.exs:329` covers the trailing-newline case.
