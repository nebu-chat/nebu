# Security Review (short check): sso-confirm-bucket-order (follow-up cv, SEC delta gate X-3), 2026-10-14

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator (condensed). Scope: `Nebu.Matrix.SsoConfirm.handle/1` counting by the binding cookie (ADR-033 L9), tests, docs.

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW, 4 INFO). Approved.**

Checked: brute force / guessing of the 256-bit binding and the cookie-derived CSRF token (not weakened; fewer CSRF guesses per binding than before), HIT / MISS answer difference (no enumeration of live bindings), anonymous flood and the G3-2
collapse (a flood without cookie charges nothing, random cookies only drain the miss bucket which cannot deny a live binding; a party with its own binding cannot charge a foreign bucket: key = hex(SHA-256) of a secret 256-bit value),
memory (per-binding rows only for live entries), logging law, cookie-clear behaviour.

| # | Sev | Finding | Resolution |
|---|---|---|---|
| L-1 | LOW | A cross-site top-level POST carries no `SameSite=Lax` cookie; its (now cookie-first) `invalid_state` answer cleared the user's live `__Host-` cookie (before it ended in the Origin check with 403 and kept the cookie). | FIXED: a missing cookie answers 400 without a clearing cookie, a malformed one is cleared; tests. |
| L-2 | LOW | The miss bucket does not limit the node-local `SsoStore` lookup (it runs first); the residual doc implied it did; stale follow-up id `df` in the moduledoc. | Doc corrected (the bucket throttles the answer; an unreachable store is a miss), id `di`; stateless MAC cookie = follow-up `di`. |
| I-1..I-4 | INFO | same-site subresources can drain a binding bucket (comparable to before, lower threshold); bucket key equals the store key in hex (optional domain separation); replication lag counts as miss (unchanged); `config_controller.ex` `_params` drive-by without effect. | accepted |
