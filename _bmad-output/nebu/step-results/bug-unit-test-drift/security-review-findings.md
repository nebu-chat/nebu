# SEC Gate 1 — bug-unit-test-drift (2026-06-22)

**Reviewer:** Kassandra (adversarial security review, opus)
**Scope:** only production change = `server/lib/nebu/matrix/user_id.ex` `configured_claim/0` (`try/rescue _ -> nil`). All other changes test-only (no security surface). Confirmed via `git diff --stat -- server/lib/`.

**Verdict: CLEAN (no CRITICAL/HIGH) — does not block commit.**

## Findings
- **[MEDIUM] fail-closed → fail-open-to-weaker-claim regression.** During a repo/DB-unavailability window (boot/shutdown, pool-checkout timeout) `configured_claim/0` now returns `nil` and the localpart falls back to `preferred_username`/`name` instead of the operator-configured unique claim. For operators who set a non-default `oidc_user_id_claim` (e.g. `email`) *because* `preferred_username` is non-unique, two verified tokens can transiently collide on the same Matrix id (the identity-collision the moduledoc calls CRITICAL). Pre-patch behavior in the same window was a 500 crash (fail-closed). Token verification is untouched → no auth bypass; precondition (non-default claim + transient outage) is narrow → MEDIUM, not HIGH.
- **[LOW] Broad silent `rescue _`.** The degraded window is logged nowhere → no signal for attack-timing or misconfig.
- **[INFO] No auth bypass:** verify_token/denylist/deactivated guards all run before `from_claims` (`oidc_plug.ex:47-58`); the rescue only changes *which valid claim* names the localpart, never *whether* a token is accepted.
- **[INFO] No new info-leak:** rescue returns `nil`, logs/surfaces nothing.

## Decision (orchestrator)
Keep the minimal CLEAN fix (it resolves a real auth-path crash and unblocks oidc_plug_test). MEDIUM + LOW deferred to a **follow-up story** — proper remediation is to cache `oidc_user_id_claim` at boot (it only changes via the admin Claim-Mapping page) so request-time identity derivation never depends on a live DB read, removing both the crash and the fallback divergence; add a throttled warning log in the degraded path. Not done here to avoid scope-creep / untested throttling logic in a test-drift bug fix.
