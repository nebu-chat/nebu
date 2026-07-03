## Security Review — bugfix-jwt-soft-logout

**Diff scope:** staged diff — `server/lib/nebu/web/plugs/oidc_plug.ex` (+14/-4) plus two test files
(`oidc_plug_expired_test.exs`, `oidc_plug_test.exs`). Auth middleware. The single production-code
change flips `call_jwt/2`'s `{:error, :expired}` branch from `deny/3` to `deny_soft_logout/3`, adding
`"soft_logout": true` to the 401 body for a cryptographically-valid-but-time-expired raw OIDC JWT.
Mirrors `call_opaque/1`'s existing expiry handling. Docstring + comment edits only otherwise.
**Date:** 2026-07-03
**Reviewer:** Kassandra (nebu-agent-kassandra)

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No security issues found | — |

### Detail

This is a response-shape-only change on one 401 branch of the JWT auth path. I verified the four
threat vectors called out in the story context and ran the standard OWASP/STRIDE/CWE pass. All clear.

**1 — Authorization decision is unchanged (STRIDE: Elevation of Privilege — negative).**
`deny/3` (oidc_plug.ex:517) and `deny_soft_logout/3` (oidc_plug.ex:532) are byte-identical except for
the JSON body: both `put_resp_content_type("application/json") |> send_resp(401, body) |> halt()`.
The expired token is still denied (401) and the conn is still halted in every case. Zero change to
who is authenticated, what is assigned, or whether the request proceeds. `assign(:current_user, ...)`
is reached only on the `{:ok, ...}` success path, which the `:expired` branch never enters. CLEAN.

**2 — No new information leak to an attacker holding the expired JWT (STRIDE: Information Disclosure —
negative).** The `:expired` branch is reachable ONLY for a token that has already passed `check_alg`,
`select_key`, and `assent_verify(verified?: true)` inside `verify_token/2` — i.e. the attacker already
holds a token they know is genuinely-signed and merely past `exp` (verify_token.ex order: alg → key →
signature → `check_exp` at line 385). `soft_logout: true` asserts only "the underlying session record
may still be recoverable via refresh." That fact is (a) already inferable — a validly-signed token
that fails solely on `exp` is definitionally a mere time-expiry, and (b) already exposed by the
sibling `call_opaque/1` expiry branch (oidc_plug.ex:88) in this same file for months. The boolean
grants no capability: recovery still requires a valid, non-revoked refresh token the attacker does not
have. No new server-state fact is disclosed. CLEAN.

**3 — No regression on any OTHER call_jwt/2 branch (the important one).** The diff changes exactly one
line. I confirmed against source that every other rejection still uses plain `deny/3` (NO soft_logout):
- revoked/denylisted → oidc_plug.ex:163 `deny(... "Access token has been revoked")`
- missing token → :150 `deny(... M_MISSING_TOKEN)`
- bad signature / iss / aud / kid / alg / malformed / missing_exp / missing subject → all fall through
  to the catch-all `{:error, reason}` → :166 `deny(...)`
- deactivated account (JWT path) → :131 `deny(... "Account has been deactivated")` — HARD logout, correct.

Crucially, a **revoked-but-not-yet-expired** token still routes to `:revoked` (plain `deny`), because
`check_denylist/2` runs only after `verify_token/2` succeeds, which for a non-expired token it does.
The new test at `oidc_plug_test.exs:~640` pins this precisely (denylisted token minted with
`future_exp()` → asserts `soft_logout` key ABSENT). A revoked token becoming falsely "soft" is
therefore NOT possible for the case that matters (a live, denylisted token). CLEAN.

  Edge note (benign): `check_exp` runs BEFORE `check_denylist` in `verify_token/2`, so a token that is
  BOTH expired AND denylisted hits the `:expired` branch and now carries `soft_logout: true`. This is
  harmless — the token is already past `exp` and rejected 401; `soft_logout` is advisory only, and if
  the whole session/refresh chain was revoked at logout the client cannot actually refresh. No
  authorization is granted. Not a finding.

**4 — Intentional opaque-vs-JWT deactivation asymmetry (pre-existing, not introduced here).**
`call_opaque/1`'s deactivated re-check (oidc_plug.ex:100) uses `deny_soft_logout`, while the JWT path's
deactivated clause (oidc_plug.ex:131) uses plain `deny`. The diff correctly leaves line 131 as a HARD
logout and the `deny_soft_logout/3` docstring (:526-531) accurately enumerates its three callers
(opaque-expiry, opaque-deactivated re-check, JWT-expiry) — it does NOT claim JWT-deactivated. The JWT
path taking the more-conservative HARD-logout stance for a deactivated account is the safer choice and
is explicitly pinned by the new deactivation test (`oidc_plug_test.exs:~560`). Not a finding.

**OWASP / CWE pass:** No injection sink (static Jason-encoded literals, no user input in body). No new
route, endpoint, or auth gate. No secret/token value logged or echoed (the 401 body contains only a
static errcode/error string + a boolean). No crypto, no migration, no header change. CWE-287
(improper authentication) reviewed — verify_token ordering is sound; expired cannot mask bad-signature.
CWE-613 (insufficient session expiration) reviewed — the token is still rejected; soft_logout does not
extend any lifetime. Clean across all applicable categories.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED — response-shape-only change on one 401 branch, zero authorization-logic delta,
no new information disclosure, no regression on revoked/bad-sig/deactivated branches (all still HARD).
