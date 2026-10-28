# Security Review: admin-config-privileged-forms-sweep (SEC Gate 1), 2026-10-14

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator (condensed from the agent's hand-back).
Scope: `git diff --staged` (38 files): claim / role mapping behind `gate(:marker, <page>)`, scopes / refresh mode behind `gate(:click)`, audit actions, `Auth.reauth_return_to/1`,
router unframed rule, templates, **migration 000049** (`admin_group_claim` into the `config_update_mutable` allowlist), docs, tests.

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 1 MEDIUM, 3 LOW, 6 INFO). Approved.**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| M-1 | MEDIUM (docs) | The SQL recovery for `oidc_user_id_claim` bypasses the per-node `OidcClaimCache` invalidation (only `upsert_server_config` invalidates it): after a SQL correction the wrong mapping stays active until a restart; "the next sign-in reads the new value" was wrong for that key. | FIXED in 07-deployment: restart the nodes (rolling) or save the corrected value once on the claim mapping page; the claim-mapping lock-out wording corrected (administrators stay administrators). |
| L-1 | LOW | The Role mapping page is mislabeled (claim NAME vs the group VALUE under `admin_group_claim_path`, fallback "groups" instead of `instance_admin`); since 000049 the save works for the first time, a wrong value locks all admins out at the next refresh and an open session cannot undo it ("keep the session open" was misleading for this form). | FIXED: label "Admin group value", text names the claim path as read-only bootstrap setting, default `instance_admin`, warning corrected. A self-lock-out guard (new value must match the saving admin's fresh claims) recorded as follow-up `dg`. |
| L-2 | LOW | The audit of the two mapping saves is written after the save, not atomically (the OAuth switch is atomic). | Accepted, follow-up `dh`. |
| L-3 | LOW | Scopes / refresh mode are not audited although they change the claim set and the token lifetime; "grant nothing" overstated. | FIXED: audit rows `oidc_scopes_changed` / `oidc_refresh_mode_changed`; SO10 wording corrected. "No marker" for them judged acceptable (the lock-out argument is right). |
| I-1 | INFO | Migration 000049: minimal (one key), rollback- and rolling-deploy-safe, the pre-existing RLS bug proven; it hardly widens the runtime role (it could already change `admin_group_claim_path`, `oidc_user_id_claim`, INSERT any key). | OWNER DECISION recorded: accepted. |
| I-2..I-6 | INFO | SO7 residual (a script that locks a real click on a same-origin popup; the marker raises the bar), no bootstrap / other bypass of the locked keys, marker binding / regex / body parameters correct, headers / XSS / logging / seams fine, no charset check of the claim values (admin-only, escaped, jsonb). | accepted |
