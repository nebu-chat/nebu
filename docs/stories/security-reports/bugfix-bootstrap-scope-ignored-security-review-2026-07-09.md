## Security Review — bugfix-bootstrap-scope-ignored (SEC Gate 1)

**Diff scope:** `git diff --staged`. Production code in scope: `server/lib/nebu/web/oidc_scopes.ex` (extracted `compose_scope/2`, new public `resolve_scope_with_extra/2`) and `server/lib/nebu/admin/auth.ex` (`oidc_config("bootstrap")` now sources extra scopes from the in-progress `bootstrap_draft["admin_oidc_extra_scopes"]` instead of `server_config`). Remaining staged files (`trace-map-zoom-pan` `.feature`/`.steps.ts`/`_test.exs`/story `.md`, `pipeline-state.yaml`) are test/doc/e2e only — no `server/lib` production change — so they add no production attack surface (see Observation O-1).
**Pipeline:** legacy bug-fix (no epic). OIDC authorization-request scope composition on the pre-authentication first-admin bootstrap path.
**Date:** 2026-07-09
**Reviewer:** Kassandra (independent STRIDE/OWASP/CWE pass)

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | oidc_scopes.ex:102-104 (`resolve_scope_with_extra/2`) | Read-path performs no independent validation of the extra-scopes value; safety relies entirely on the single-writer invariant (`save_step3/2`) + the outbound encoder. Defense-in-depth gap (CWE-20). | Have `resolve_scope_with_extra/2` fail-closed: run `validate_scope_string/1` on `extra` (reject/drop on failure), or add a pinning test asserting the draft value is validated before this call. Make composition safe-by-construction, independent of caller. |
| 2 | LOW | oidc_scopes.ex:101-104 (new public API) | `resolve_scope_with_extra/2` is a new PUBLIC function that accepts an arbitrary caller-supplied string, deliberately bypassing the reader-seam/`server_config` trust boundary that `resolve_scope/1` enforces. Today's sole caller is safe; the API now lets any future caller compose a scope from untrusted input without validation (CWE-710, attack-surface widening). | Same fail-closed validation inside the function (covers #1 and #2 together), or narrow visibility / add an explicit `@doc` contract that the caller MUST pass a write-validated value. |

### Detail

**Finding #1 — Read-path trusts the single-writer invariant instead of re-validating** [LOW]
`resolve_scope_with_extra(:admin, draft["admin_oidc_extra_scopes"])` composes the outbound `scope=` value from the draft field without re-validating it. Today the value is validated at write time in `bootstrap_controller.ex#save_step3/2` via `OidcScopes.validate_scope_string/1` (whitelist `~r/^[a-zA-Z0-9_:.\-]+\z/` per space-split token, `\z` rejecting trailing newline). If a FUTURE code path (direct-DB write, a migration seeding the draft, or a wizard-POST race/replay) ever populates the draft without going through `save_step3/2`, this read path would forward whatever is stored into the authorize request.

Impact is bounded to LOW, not higher, by three independent factors:
1. **Outbound encoding neutralizes injection.** `auth.ex:437-450` builds the query via `URI.encode_query(%{... "scope" => cfg.scope ...})`, which percent-encodes the entire value. A malformed value containing `&`, `=`, `#`, spaces, or newlines cannot break out of the `scope` parameter or smuggle additional query params — this is the primary reason the regex answer to task-Q1 is "sufficient, and belt-and-suspenders even if it weren't." Space-within-a-token smuggling is also blocked: the per-token regex forbids interior whitespace, and `compose_scope/2` splits/re-joins on a single space.
2. **No cross-boundary privilege gain.** The scope is requested for the operator's OWN bootstrap session token. The wizard actor is already the highest-trust pre-auth context (they are becoming the first admin). Widening scopes only enriches claims in their own token — there is no other principal whose permissions could be escalated.
3. **IdP still gates.** The IdP applies its own client-scope policy/consent; a requested scope is not a granted scope.

Remediation makes it safe-by-construction rather than by-convention: validate inside `resolve_scope_with_extra/2`.

**Finding #2 — New public API drops the trust boundary `resolve_scope/1` enforced** [LOW]
`resolve_scope/1` can only ever read validated, operator-controlled values through the reader seam / `server_config`. The new `resolve_scope_with_extra/2` intentionally removes that seam so bootstrap can source from the draft — correct for the fix, but it converts scope-composition into a function that will compose from ANY string a caller hands it. This is the task-Q2 concern answered directly: yes, the explicit-argument API widens surface for careless future callers even though today's single call site is safe. Same remediation as #1 (fail-closed validation inside the function is the cleanest fix, since it covers every present and future caller at once).

### Answers to directed questions

- **Q1 (malformed draft value widening scope / regex sufficiency):** No exploitable injection. `URI.encode_query` percent-encodes the whole `scope` value, so no `&`/`=`/`#`/space/newline can break the query string or add params; the write-time regex additionally blocks interior-whitespace token smuggling. Even a bypass of the single-writer invariant only enriches the operator's own token (see #1). Residual concern is the defense-in-depth gap in #1 (LOW).
- **Q2 (public API callable with untrusted value):** Confirmed as Finding #2 (LOW). It does widen surface; recommend fail-closed validation in the function.
- **Q3 (session-fixation / CSRF / open-redirect):** None introduced. Only the SOURCE of the `scope` value changed. `redirect_uri` is server-derived (`redirect_uri()`), not user input — no open-redirect vector. `state` is signed and the `mode` is bound INTO the signed login state (auth.ex:430-435) so it cannot be tampered via the callback query string — no fixation via mode/state. `nonce` present; PKCE `code_challenge_method=S256`. Unchanged by this diff. Confirmed, not assumed.
- **Q4 (write trust boundary unchanged):** Confirmed. `bootstrap_controller.ex` is NOT in the staged diff (`git diff --staged --name-only` shows zero bootstrap_controller hits). The write path for `bootstrap_draft.admin_oidc_extra_scopes` remains the authenticated-wizard-session-only `save_step3/2` path, unaffected by this change.

### Observations (non-findings)

- **O-1 — Staged diff scope mismatch.** The staged diff bundles unrelated `trace-map-zoom-pan` work alongside this bugfix. All of it is test/doc/e2e (`.feature`, `.steps.ts`, `_test.exs`, story `.md`, `pipeline-state.yaml`); there is NO `server/lib` production change for trace-map in this staging. Scanned the staged test/e2e for backdoor patterns (raw SQL, `endpoint[]`/`route_template` seeding, auth-forge/bypass helpers, `eval`/`innerHTML`) — none present. No production impact. Flagged only so the split is intentional and the commit boundary is understood.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 2 — advisory hardening (single fail-closed validation in `resolve_scope_with_extra/2` closes both)

**Verdict:** APPROVED — no commit-blocking findings. Classification: CLEAN.
