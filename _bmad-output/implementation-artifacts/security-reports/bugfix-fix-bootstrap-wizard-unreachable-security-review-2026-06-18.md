# Security Review (SEC Gate 1) — bugfix-fix-bootstrap-wizard-unreachable — 2026-06-18
Reviewer: Kassandra (nebu-agent-kassandra)
Scope: staged diff of core/lib/nebu/admin/auth.ex (on_mount(:require_admin) restructure + bootstrap_completed?/0 seam wiring) + core/test/nebu/admin/auth_bootstrap_gate_test.exs

## Findings

### HIGH-1 — bootstrap_completed?/0 failed OPEN on DB query error (FIXED in this story)
The pre-existing `_ -> false` collapsed BOTH "no row (fresh)" AND "{:error,_} (DB fault)" to `false`.
Harmless before this fix (unauth always → /admin/login). But this fix makes the Bootstrap Wizard
world-reachable AND completable whenever `bootstrap_completed?()==false`. So on a *completed* instance,
a transient `SELECT bootstrap_completed` error (pool exhaustion, failover) — or a missing row — would
re-open the unauthenticated wizard, enabling takeover of OIDC config + admin_group_claim (the wizard's
finish guard reads the same false). Exploitability is conditioned on a DB fault where reads of this key
fail but writes still succeed (narrow), but fail-open on an auth gate is unacceptable.
FIX APPLIED: explicit match — `{:ok, %{rows: [["true"]]}} -> true`; `{:ok, _} -> false` (genuinely
fresh, no/!="true" row); `{:error, _} -> true` (fail CLOSED — assume completed, keep wizard gated).
Verified: auth_bootstrap_gate_test.exs 8/8 green; fresh instance still reaches {:ok,_}->false so a real
bootstrap is never stranded.
Note: the `{:error,_}->true` path is only reachable when Nebu.Repo is up but the query errors; the unit
seam bypasses the SQL branch, so a deterministic unit test of this exact arm is impractical without a
fault-injecting DB. Documented as a code-level invariant with a loud comment.

## Confirmed safe (no finding)
- AC3 re-gate airtight: the catch-all `cond` evaluates `completed -> /admin/login` FIRST; the {:cont}
  escape for BootstrapLive is reachable only when completed==false. No post-bootstrap unauthenticated
  reconfiguration path.
- `:admin_bootstrap_store` seam is set via Application.put_env ONLY in test files; production code only
  reads it. No env-var / external-input path → NOT attacker-flippable in production.
- ADR-018 (inline SQL), let-it-crash, ADR-020 honoured.

## Verdict
HIGH-1 found and FIXED within this story. No remaining CRITICAL/HIGH. CLEARED to commit.
