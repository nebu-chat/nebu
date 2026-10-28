# Security Review: admin-config-audit-atomic (SEC Gate 1), 2026-10-15

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator (condensed from the agent's hand-back).
Scope: `git diff --staged`: `Nebu.Admin.DB.save_config_audited/2` (value and audit row in one transaction) for the six privileged `server_config` forms, the policy when the audit row cannot be written, `SsoStore.peek_confirm/1` reading the ETS table directly, docs.

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 0 MEDIUM, 4 LOW, 5 INFO). Approved. The policy (mappings refused; lists and scopes refused for a widening and applied for a subset; refresh mode) is sound under the Kill-Switch principle.**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| L-1 | LOW | The subset test compared raw tokens, the runtime drops tokens that fail its parser: a dead stored token (hand-edited) could be activated unaudited by a later "narrowing". | FIXED: the stored list counts as the runtime reads it (origins through the Matrix normalizer, schemes through the validator); a value the validator refuses as a whole is the empty set (fail closed). |
| L-2 | LOW | A refresh mode change online -> offline is a widening (`offline_access`: a refresh token that outlives the IdP session) applied unaudited. | FIXED: unaudited only when every changed key goes to `online` or stays as stored; `offline` needs its row (D2, ADR-033, 07-deployment). |
| L-3 | LOW | The stored value is read outside the transaction: a concurrent narrowing plus a stale "subset" save can re-add a token unaudited. | FIXED: the retry without the audit function re-checks the narrowing inside its transaction under `SELECT ... FOR UPDATE` (`:narrowing` option). |
| L-4 | LOW | The ERROR line of an unaudited save did not name the form. | FIXED: form and changed key names (never values or the actor). |
| I-1 | INFO | Claim mapping cannot be changed while the audit table is broken (SQL only; role mapping has `reset_admin_group_claim/1`). | accepted, documented (11-risks). |
| I-2 | INFO | A narrowing can remove authority without a row (clearing the scope that carries the admin group claim demotes admins). | accepted under the Kill-Switch principle; flash + ERROR line are the trace. |
| I-3 | INFO | `AuditWriter.log` still logs the actor and the reason on a failed write (pre-existing). | recorded. |
| I-4 | INFO | `peek_confirm` no longer deletes an expired entry (sweep / pop do); they count toward the 10 000 cap until then. | accepted. |
| I-5 | INFO | SIEM: watch `oauth_switch_changed` together with `sso_redirect_origins_changed`. | in 07-deployment. |

Checked and fine: nested AuditWriter transaction, rollback, one retry only after an audit failure, caches refreshed after the commit once, parameterized SQL, no value or actor in the new logs, all seams compile-guarded, six actions in `@known_actions`; `peek_confirm`: single use unchanged (the POST consumes through `pop_confirm`), no new leak (the table is `:protected`, node-local, keys are SHA-256 digests), a flood of random cookies is now one cheap lookup per request.
