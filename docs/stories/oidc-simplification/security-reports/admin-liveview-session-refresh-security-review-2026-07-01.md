## Security Review — admin-liveview-session-refresh (epic: oidc-simplification)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** `git diff --staged` — new `Nebu.Admin.KeepaliveController` (`GET /admin/keepalive`),
router route, `SessionKeepalive` JS phx-hook (`app.js`), keepalive div in `layouts.ex`, and the
`on_mount/4` change in `Nebu.Admin.Auth` (`refreshable?/1` + extracted `mount_admin/3`). Plus tests
and doc/architecture note.
**Date:** 2026-07-01
**Story flags:** `security_review: required`, `severity: high` — Session/Auth trust-boundary path.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | HIGH | `server/lib/nebu/admin/auth.ex:1158` (`on_mount` `or refreshable?(session)`) + `:1242` (`refreshable?/1`) | Revoked/de-privileged admin retains LiveView (Dashboard + AuditLog) read access with NO IdP revalidation and NO outer time bound when the JS heartbeat is severed. `refreshable?/1` is decrypt-gated, not validity-gated; a decryptable RT blob never stops decrypting, and it OR's away the only server-side `session_exp` enforcement (`session_live?`). The admin session cookie has no `max_age`, so nothing else bounds it. | On the socket path, cap the grace with a bound INDEPENDENT of the RT blob (e.g. a separate `refresh_grace_exp` written into the session at login/HTTP-refresh time; `on_mount` proceeds only while `now < refresh_grace_exp`). OR set `max_age` on the admin session cookie so the transport enforces an outer expiry. OR do a cheap IdP-independent staleness bound on `on_mount`. Do NOT rely solely on the heartbeat for revocation enforcement. |
| 2 | LOW | `server/lib/nebu/admin/router.ex:207` + `KeepaliveController` | Keepalive endpoint has no per-endpoint rate limit; 60s client interval is not server-enforced. Non-issue today (auth-gated, 204, no body, no business logic) but if the interval ever becomes configurable or the endpoint is scripted, no server-side floor exists. | Advisory: if a configurable interval lands, add a server-side lower bound / cheap per-session rate limit. Matches the story's own security note. |

### Detail

**Finding #1 — Decrypt-only grace grants revoked-admin LiveView access with no outer bound** [HIGH]

Trace (verified against code, not the SEC NOTE's own framing):

- `session_expiry/1` (auth.ex:288) caps `session_exp = min(id_token.exp, now + admin_session_ttl)`;
  default admin TTL is 8h (`session_config.ex:17`). This cap was the sole server-side outer bound on
  an admin session.
- Pre-change, `on_mount` halted+redirected once `session_live?/1` was false (i.e. `now >= session_exp`).
  `session_live?` is the ONLY place `session_exp` is enforced on the socket path (`require_admin` on
  HTTP checks only `current_user["admin"]`, not exp).
- New `on_mount` (auth.ex:1158): `if session_live?(user) or refreshable?(session)`. `refreshable?/1`
  (auth.ex:1242) returns true iff `SecretBox.decrypt(enc_rt)` succeeds — it performs NO token-endpoint
  exchange and NO IdP validity/revocation/expiry check. A refresh token that was legitimately encrypted
  by this server at login decrypts forever, regardless of whether the IdP has since revoked it or the
  operator has been removed from the admin group / deactivated.
- Consequence: once `session_exp` elapses, the `session_live?` branch is false but the `refreshable?`
  branch is true indefinitely. The 8h cap and the `id_token.exp` cap are both OR'd away for the socket
  reconnect path.

The happy-path mitigation is the client JS heartbeat: every 60s `app.js` `SessionKeepalive` fires
`GET /admin/keepalive`, which rides the `:browser` pipeline → `fetch_current_user/2` →
`maybe_refresh_session/2`. For an already-past-exp session, `exp - now <= @refresh_window` is true, so
with a stored RT it performs the real `grant_type=refresh_token` exchange (`refresh_admin_session/1`);
a revoked/expired RT (or lost admin claim via `check_admin`) → `configure_session(drop: true)` + halt
+ redirect. So WHEN THE HEARTBEAT RUNS, revocation is enforced within ~60s. That part is sound.

The exposure is the severed-heartbeat case, and my independent judgment diverges from the SEC NOTE on
the BOUND. The SEC NOTE frames the widened exposure as "the lifetime of the LiveView socket." I
confirmed there is effectively NO independent outer bound:

1. The RT blob decrypts forever (no time component in SecretBox) → `refreshable?` never flips to false.
2. The admin session cookie (`endpoint.ex:30`) sets NO `max_age` → it is a browser-session cookie with
   no server-enforced expiry envelope (Plug cookie store only expires when `max_age` is set).
3. `session_exp` — the only remaining bound — is exactly what the `or refreshable?` clause bypasses.

So a socket reconnect (routine: network blip, longpoll cycle, server redeploy, tab wake) re-runs
`on_mount` against the frozen connect-time session and re-grants access purely on "the RT blob still
decrypts," for as long as the tab stays open. The bound is tab-close or `secret_key_base`/internal-
secret rotation — NOT any expiry the operator's revocation triggered. The AC1 test (admin_token_
refresh_test.exs:468-499) directly encodes this: it drives `on_mount` with `session_exp = now - 1` and
asserts `{:cont, _}`.

Blast radius / likelihood calibration (why HIGH, not CRITICAL):
- Precondition: an ALREADY-authenticated admin whose access is subsequently revoked at the IdP (group
  removal / account disable) with heartbeat severed. Not unauthenticated, not standard-user → not
  CRITICAL by the severity rubric.
- Exposed surface is READ-ONLY: only the two remaining LiveViews (DashboardLive, AuditLogLive).
  ALL state-mutating admin actions are HTTP controllers gated by `require_admin` on a fresh HTTP
  round-trip, which forces the RT exchange for expired sessions → a revoked admin is logged out on any
  mutation attempt. No privilege escalation, no write path.
- BUT: the revoked insider can DELIBERATELY and trivially sever their own heartbeat (block
  `/admin/keepalive` in devtools, disable JS, background-throttle the tab) and thereby keep their
  AuditLog + Dashboard LiveView alive across reconnects INDEFINITELY, continuing to read compliance /
  audit-log data after their admin rights were revoked. That is a self-serviceable, unbounded,
  revoked-credential-still-grants-access bypass of admin de-provisioning for the read views. For a
  compliance-native product whose AuditLog is a sensitive surface, an indefinite post-revocation read
  window is a genuine HIGH.

Admin de-provisioning note: deactivation deletes `matrix_sessions` (pattern #64/#75) but the admin
Phoenix session is a signed cookie + IdP RT — it is NOT dropped by deactivation. The ONLY thing that
strips a de-privileged admin's session is the RT-exchange `check_admin` re-verification, which runs
exclusively on the HTTP path this hole removes. So the heartbeat is not merely a nicety here — it is
the sole revocation-enforcement mechanism for the socket views, and the change makes correctness depend
on a client-controlled, trivially-defeatable timer.

Remediation (any one closes the unbounded-ness; first is preferred):
- Write an independent server-side grace bound into the session (e.g. `refresh_grace_exp = session_exp
  + N` at login and on each successful HTTP refresh) and gate `refreshable?` on `now < refresh_grace_exp`.
  This keeps the UX win (idle tab survives id_token.exp) while restoring a hard outer cap that no
  client behaviour can extend.
- And/or set `max_age` on the admin session cookie for a transport-layer backstop.
- And/or a cheap IdP-independent staleness check in `on_mount`.

**Finding #2 — No server-side floor on heartbeat frequency** [LOW]

`GET /admin/keepalive` (router.ex:207) is auth-gated, returns bare 204, no body, triggers only the
existing `fetch_current_user/2` leg — no new business logic, no PII/token in response or logs (AC4
met). At the fixed 60s interval this is harmless. Advisory only: if the interval is ever made
configurable (the story's own note anticipates this), add a server-side lower bound. No action
required now.

### Positive verifications (checked, clean)

- **Auth gate / no bypass (AC4):** `KeepaliveController` carries `plug Nebu.Admin.Auth, :require_admin`
  AND sits inside the `:browser` scope (`pipe_through :browser`, router.ex:124) so `fetch_current_user`
  runs first — same gate chain as every other admin route. No bypass. (Pattern #65 confirmed: gate on
  both static render and socket connect; here it's a plain HTTP controller so the plug is authoritative.)
- **CSP compliance (AC / pattern #74):** the hook is an EXTERNAL `app.js` function (no inline handler),
  allowed by `script-src 'self'`. The `fetch('/admin/keepalive')` is same-origin → satisfied by
  `connect-src 'self' ws: wss:` (router.ex:86). No `unsafe-inline`/`unsafe-eval` introduced. The
  keepalive `<div>` uses `phx-hook` attribute only, no inline JS.
- **Info leak (AC):** 204 empty body; no sub/email/token/PII in the response or in any log line on
  this path.
- **online-mode (no RT) (AC4/AC6):** with no stored RT, `maybe_refresh_session` warns once and returns
  the conn unchanged (does not raise, does not drop) → keepalive returns 204 normally; normal expiry
  behaviour preserved. On the socket path, `refreshable?` returns false (no RT) so online-mode sessions
  still hard-expire at `session_exp` — online mode is NOT affected by Finding #1 (the bug is scoped to
  offline mode where an RT is present).
- **HTTP-path non-regression (AC5):** `fetch_current_user`/`maybe_refresh_session`/`refresh_admin_
  session` are byte-unchanged; the fix adds a second trigger path (heartbeat) + the `on_mount` grace,
  not a replacement. Existing refresh tests untouched.
- **No new injection / secret / crypto surface:** no SQL, no user-controlled path/command, no new
  secret handling; SecretBox (AES-256-GCM) reused unchanged; RT never logged/plaintext.
- **CSRF:** GET keepalive is non-state-changing; no CSRF concern. `protect_from_forgery` remains in the
  pipeline for the POST routes (unchanged).

### Summary

CRITICAL: 0
HIGH: 1 — block commit (Finding #1)
MEDIUM: 0
LOW: 1 — advisory (Finding #2)

**Verdict: BLOCKED** — Finding #1 (HIGH) must be addressed before this story merges. The fix does not
need to abandon the UX goal; it needs an outer bound on the socket-side grace that is independent of
the client heartbeat and of RT-blob decryptability (a server-written `refresh_grace_exp` and/or cookie
`max_age`). The pre-flagged seam is a real revoked-credential-still-grants-access issue for the
read-only Admin LiveViews, and — contrary to the "~60s / socket-lifetime" framing — is unbounded in
the deliberately-severed-heartbeat case because no server-side expiry survives the `or refreshable?`
clause.

---

## Re-review (post-HIGH-fix) — admin-liveview-session-refresh

**Reviewer:** Kassandra (nebu-agent-kassandra) — independent re-verification, not a rubber-stamp of the code-review sign-off
**Diff scope:** `git diff --staged` (same story, fix + comment-correction pass)
**Date:** 2026-07-01
**Trigger:** Finding #1 (HIGH) was fixed rather than accepted; re-verifying the fix independently.

### Verdict

**Finding #1 (HIGH): CLOSED.** **Classification: CLEAN.** Verdict flips BLOCKED → APPROVED.

### What was verified (independently, from the actual staged code)

**1. `refresh_grace_exp` is tamper-proof.** It is a key inside `session["current_user"]`, which is the
signed Plug session cookie (integrity-protected by `secret_key_base`). `on_mount/4` reads it from the
signed session (`session["current_user"]`), and `refreshable?/2` reads `user["refresh_grace_exp"]` from
that same map. There is no path by which a client can set or forge this value — it never comes from
request params, body, or an unsigned source.

**2. `refresh_grace_exp` is non-bypassable on the read-only socket path.** Grepped every writer:
exactly three, all server-side and all bounded —
  - `put_current_user/2` (auth.ex:301): `exp + @refresh_grace_seconds`, where `exp = session_expiry(claims)`
    is capped at `min(id_token.exp, now + admin_session_ttl)` (≤ 8h). Shared by the login callback AND
    the success branch of `refresh_admin_session/1` (auth.ex:205), exactly as claimed.
  - Bootstrap-completion mint (auth.ex:678): `bootstrap_exp + @refresh_grace_seconds`, `bootstrap_exp = now + admin_session_ttl`.
  `on_mount/4` and `refreshable?/2` only ever READ the value; no socket-lifecycle path writes it. A
  reconnect cannot extend the bound. Ceiling on any written value is `now + 8h + 180s` — no far-future
  or attacker-favorable value is writable anywhere.

**3. Fail-closed on missing/malformed grace.** `within_grace = is_integer(grace_exp) and now <= grace_exp`.
A `nil` (stale pre-fix cookie) or non-integer `grace_exp` yields `false` → `refreshable?/2` returns
`false` → `on_mount` falls through to `session_live?`-only, i.e. hard-expires at `session_exp`. Stale
pre-fix sessions therefore fail closed and are STRICTER than before (they can't use the grace at all) —
no downgrade window is introduced.

**4. My original exploit is closed.** Regression test `[SEC-HIGH] on_mount denies access once
refresh_grace_exp has elapsed, even with a decryptable RT` (admin_token_refresh_test.exs:587-639)
models the exact severed-heartbeat scenario: `session_exp = now - 200`, `refresh_grace_exp = now - 1`,
RT blob still decrypts cleanly — and asserts `{:halt, _}` + redirect to `/admin/login`, plus asserts
the refresh override is NOT invoked on the socket path. This is a genuine encoding of my Finding #1,
not a tautology. A revoked/de-provisioned admin who severs the heartbeat is now denied within a
BOUNDED window (≤ `@refresh_grace_seconds` = 180s past the last successful refresh) instead of
indefinitely.

**5. Timing arithmetic re-checked; happy path (AC2) still works.** The keepalive fires every 60s;
`maybe_refresh_session/2` only performs a real refresh when `session_exp - now <= @refresh_window`
(120s), and on success re-writes `refresh_grace_exp = new_session_exp + 180`. Under a healthy
heartbeat the refresh fires inside the 120s pre-expiry window, pushing `session_exp` (hence
`refresh_grace_exp`) far forward before the old bound could lapse — so `session_live?` covers the
steady state and the 180s grace is only the binding constraint in the narrow interval right around
expiry, giving ~3 missed/delayed beats of slack (proportionate to the 60s interval and 120s window).
The grace can never lapse while the heartbeat is healthy, so AC2's indefinite idle-tab survival is
preserved. `@refresh_grace_seconds = 180` is a sound choice for these constants.

**6. No NEW vulnerability introduced by the fix.**
  - *Session fixation:* `put_current_user/2` still calls `configure_session(renew: true)` — grace is
    written into a freshly-rotated session id at every privilege (re-)establishment; a pre-login
    planted session id cannot carry a forged grace forward.
  - *Login-time grace write:* granting `session_exp + 180` at login creates no early window —
    `session_live?` is true for the whole session lifetime, so the grace is only consulted AFTER
    `session_exp` passes. In online mode (no RT stored), `refreshable?/2` short-circuits `false` on the
    RT-decrypt branch regardless of grace, so a long initial grace is inert without an RT. Confirmed
    exactly as hypothesized.
  - *Stale-cached-session replay:* the value ceiling (≤ now+8h+180s at write time) plus fail-closed
    reading means a stale session cannot survive a legitimate revocation beyond the bounded grace.
  - *Refactor equivalence:* the extracted `mount_admin/3` reproduces the prior inline bootstrap-gate
    logic byte-for-behavior; the gate `if session_live?(user) or refreshable?(session, user)` preserves
    the original `{:cont}`/`{:halt}` decision structure.

**7. Comment-arity correction verified, not blindly trusted.** The two `refreshable?/1` references
deliberately left in place (auth.ex:70 and auth.ex:1287) both describe the REMOVED single-arity
function's historical pre-fix behavior in past tense ("used to grant", "never flipped to false") — they
correctly refer to the old code, not the current `/2` function. All other references were updated to
`/2`. The distinction was made correctly.

**8. `max_age` cookie skip (accepted, not a finding).** My original report listed three remediation
options as alternatives ("any one closes the unbounded-ness"); the implemented one (independent
`refresh_grace_exp` bound) was my stated preference and fully closes the finding on its own. The
reasoned decision to skip `max_age` (it would fight `configure_session(renew: true)` and AC2's
indefinite-healthy-survival UX) is sound. No action required.

### Finding #2 (LOW) — re-checked, unchanged

Nothing in this diff touches the keepalive endpoint's rate-limiting posture. `GET /admin/keepalive`
remains auth-gated, bare 204, no body, no per-endpoint rate floor. Still LOW / advisory only, exactly
as before.

### Fresh look at the full staged diff (beyond the narrow HIGH scope)

- `app.js` `SessionKeepalive` hook, `keepalive_controller.ex`, router route, `layouts.ex` div: all
  byte-consistent with the original review's understanding; no new surface. The layout div is guarded by
  `is_map_key(assigns, :__changed__)` so it only renders in a LiveView (socket) context, not on dead
  HTTP renders — correct.
- `docs/architecture/08-concepts.md`: accurate. Minor documentation-completeness nit (not a finding):
  the prose describes the `on_mount` grace as gated on a "still-decryptable stored refresh token"
  without also naming the `refresh_grace_exp` bound; the code and its inline comments are precise, so no
  security impact.
- No unrelated changes crept in across the fix + comment pass.

### Summary (re-review)

CRITICAL: 0
HIGH: 0 — Finding #1 CLOSED
MEDIUM: 0
LOW: 1 — Finding #2 unchanged, advisory only

**Verdict: APPROVED.** Finding #1 is independently confirmed CLOSED. The fix restores a hard,
server-enforced, client-un-extendable outer bound on the socket-side grace while preserving the AC2 UX
goal. No new vulnerability was introduced by the fix or the comment-correction pass.
