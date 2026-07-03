## Security Review — bugfix-remove-unused-confirm-default

**Diff scope:** Two staged files. (1) `server/test/nebu/admin/bootstrap_admin_session_identity_test.exs` — removed an unused default parameter value on a test helper (`defp confirm(claim \\ "instance_admin")` → `defp confirm(claim)`). (2) `server/lib/nebu/matrix/event_dispatcher/server.ex` — removed a compiler-flagged dead `{:error, reason} -> Logger.warning(...)` branch from `run_post_login_provisioning/2`, replacing `case Task.start(fn -> ... end) do ... end` with a bare `Task.start(fn -> ... end)`. Fire-and-forget post-login provisioning path (personal-room creation + auto-join of flagged rooms/spaces for new users).
**Date:** 2026-07-03
**Reviewer:** Kassandra (SEC Gate 1, legacy/no-epic bug-mode run)

### Findings

No security issues found.

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | None | — |

### Detail

The review targeted two specific questions raised in the security context, plus a full OWASP Top 10 / STRIDE / CWE Top 25 pass scoped to the diff.

**Q1 — Does removing the `{:error, reason}` branch have any security-relevant behavioral implication (could a starved/failed `Task.start` silently mask a security-relevant provisioning failure — e.g. a room ACL or auto-join membership never applied — in a way an attacker could exploit)?**

No. Verified from the staged source at `server.ex:2938-2949`:

- All provisioning work — `ensure_personal_room/1`, `ensure_auto_join_memberships/1`, `ensure_auto_join_space_memberships/1` — executes *inside* the spawned closure `Task.start(fn -> ... end)`. It was inside the closure before the change and remains inside it after. The change touched only the `case` scaffolding around `Task.start`, not the closure body.
- The removed `{:error, reason}` branch contained **exactly one statement: `Logger.warning(...)`.** It performed no provisioning, no retry, no inline fallback, and no ACL/membership application. Its removal therefore cannot cause any room ACL or auto-join membership to be skipped that would otherwise have been applied.
- Behavioral equivalence across the (impossible) failure case: `Task.start/1` has typespec `dynamic({:ok, pid()})` and cannot return `{:error, _}` — confirmed by the Elixir 1.20 set-theoretic type checker that flagged the branch as "will never match." But even in the hypothetical where spawn fails at the VM level, the semantics are identical before and after: provisioning does not run in *either* version (the work lives in the un-spawned closure, not the branch), and the function still returns its trailing `:ok`. The old code merely emitted a log line in that impossible path; the new code does not. This is a strict superset-of-behavior removal on an unreachable branch — no security-relevant delta.
- The concern is therefore confined entirely to lost telemetry on an impossible path — which is exactly the observability point already dispositioned in the prior code-review cycle (1 MINOR, resolved; the MINOR was comment wording). No *new* security-relevant dimension distinct from that telemetry concern exists. This is not an attacker-exploitable condition: an attacker cannot induce a state where the new code applies fewer memberships/ACLs than the old code, because the two apply identical memberships/ACLs in all reachable states.

Call-site check (all three discard the return value; none branch on it): `server.ex:1651` (`validate_token/2`, no production caller), `http_public.ex:347` (real `POST /_matrix/client/v3/login`), `server.ex:5010` (`bulk_import_users/2`, wrapped in `Enum.each`). In every case the value is used for side effects only; the login/import response is constructed independently, so removing a branch that only ever returned the same `:ok`/`{:ok, pid}` scaffolding is invisible to callers. `@spec ... :: :ok` is unchanged and remains accurate.

STRIDE note (Repudiation): the only genuine effect is the loss of a warning log line in the impossible-spawn-failure case. Since that branch was provably unreachable, no real audit/telemetry signal is lost in any state the system can actually enter. Not a finding.

**Q2 — Does removing the default parameter weaken any test oracle?**

No. Verified all 11 call sites of `confirm/1` (lines 195, 221, 241, 274, 292, 318, 344, 365, 395, 415, 460) — every one passes `"instance_admin"` explicitly. No caller relied on the default, so no assertion path silently changes which claim is confirmed. The helper's argument only populates the `admin_group_claim_choice` value submitted to `/admin/bootstrap/select-claim`; assertions independently seed claims (`groups => ["instance_admin"]` via `seed_draft_from_callback`) and assert on minted-session identity (`matrix_user_id`, redirect to `/admin/dashboard`, `UserId.from_claims/2` equality). None of these oracles depend on the default value. The change is strictly *stricter*: had any caller relied on the default, the compiler would now raise an arity error rather than silently proceed. No oracle weakening.

**Full-scope pass (diff-scoped):** No SQL/Ecto changes, no path/command construction, no HTML rendering or template output, no new routes or middleware, no auth/authz decision changed (no `verify_token`, scope, role, or claim-mapping logic touched), no secret handling / comparison / logging of tokens, no crypto, no migration, no request-body/rate-limit surface, no redirect/`return_to` handling. No previously-dead code is woken and no reachability changes (mirror-inverse of the woken-dead-code pattern: this removes an unreachable branch rather than newly reaching one). Identity derivation (`UserId.from_claims/2`) is untouched.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

**Classification:** CLEAN
**Verdict:** APPROVED — does not block commit.
