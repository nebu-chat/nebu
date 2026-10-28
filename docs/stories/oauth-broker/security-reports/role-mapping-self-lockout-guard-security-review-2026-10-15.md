# Security Review: role-mapping-self-lockout-guard (SEC Gate 1), 2026-10-15

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator (condensed from the agent's hand-back).
Scope: `git diff --staged`: claims fingerprint in the re-authentication marker of the role mapping page, `Auth.reauth_role_check/2`, `OidcClaims.string_values_at/2`, controller, template, docs.

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 1 MEDIUM (pre-existing, not created by the guard), 2 LOW, 4 INFO). Approved. D5 (no override): Kassandra agrees and would not accept an override in the web UI (the operator keeps it through rpc).**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| M-1 | MEDIUM | Without a stored claim path the fingerprint covered the whole token: values present in every token (Keycloak `typ` "ID", `acr`) passed the guard and the X2-1 denylist and would make every user an administrator. | FIXED: without a stored path the protocol and identity claims are left out of the fingerprint (such a value is `:not_in_token`); the page and docs say so. |
| L-1 | LOW | A value only the saver holds (`sub`, email, a personal group) locks the co-admins out. | FIXED for the identity claims without a path (same change as M-1); the personal group with a stored path is accepted (audited, rpc recovery), 11-risks. |
| L-2 | LOW | The cookie-size test understated the real response (flash, CSRF, a 1100-byte token); above 4096 bytes Plug raises. | FIXED: realistic test (2 KB refresh token blob, flash, CSRF): 3871 bytes measured; cap lowered from 64 to 32 values; the overflow for refresh tokens of 3 KB or more exists with or without the guard (docs). |
| I-1 | INFO | Unkeyed 48-bit prefix: a second preimage (~2^42) is feasible only for someone who can read their own cookie (already the admin). | accepted, documented (ADR-033 SO10 addendum). |
| I-2 | INFO | The fingerprint was not bound to the claim path. | FIXED: `claims_fp_path`, a mismatch is `:unknown`. |
| I-3 | INFO | Rolling deploy: an old node accepts a marker with a fingerprint without the guard (and a new node refuses an old marker without one: correct). | accepted, documented. |
| I-4 | INFO | The template hint was outdated ("database access only"). | FIXED. |

Checked and fine: order (gate, empty, universal, guard) with the guard only able to refuse; the marker binding (sub, path, TTL) and `reauth_fresh` first; equivalence with the admin predicate; hashes only in the signed cookie (http_only, so no script of the shared origin reads them); fail closed for every malformed state; HEEx escaping, the link is built from a constant, no value in logs or flash.
