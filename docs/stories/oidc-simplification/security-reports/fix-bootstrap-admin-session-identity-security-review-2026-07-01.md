## Security Review — fix-bootstrap-admin-session-identity (epic oidc-simplification)

**Diff scope:** `git diff --staged` — `server/lib/nebu/admin/auth.ex` (+97/-19),
`server/test/nebu/admin/admin_create_room_test.exs` (+138), and new
`server/test/nebu/admin/bootstrap_admin_session_identity_test.exs` (+468).
Trust-boundary bug fix in the admin bootstrap-completion login path.
**Reviewer:** Kassandra (adversarial security review, SEC Gate 1)
**Date:** 2026-07-01
**Story classification:** security_review: required, severity: high

### Findings

No security issues found. Zero CRITICAL, zero HIGH, zero MEDIUM, zero LOW.

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | (none) | — |

### Verification against the story's SEC Gate 1 checklist

**(a) matrix_user_id equivalence with normal_callback/2 — VERIFIED, guaranteed at code level.**
`bootstrap_confirm_claim/2` (auth.ex:766) now mints the session via `put_current_user(claims)` —
byte-for-byte the same builder `normal_callback/2` calls (auth.ex:541). `put_current_user/2`
(auth.ex:294) derives `matrix_user_id` solely via `Nebu.Matrix.UserId.from_claims(claims, server_name())`.
Because both paths pass the SAME full verified claims map through the SAME single-source-of-truth
mapper, divergence is structurally impossible — not a test-fixture coincidence. The claims passed to
the bootstrap mint (`bootstrap_claims(draft)` → decoded `bootstrap_full_claims`) are the identical
`claims` a subsequent normal re-login of the same person would carry. The AC1 equality test
(bootstrap_admin_session_identity_test.exs:223-243) independently drives BOTH paths and asserts
`bootstrap_user["matrix_user_id"] == normal_user["matrix_user_id"]`. This closes the prior
`bugfix-unify-admin-matrix-oidc-identity` divergence class with no new divergence case.

**(b) No unverified claims enter the session — VERIFIED, no new attack surface.**
`bootstrap_full_claims` is written exactly once, at auth.ex:592, from the `claims` parameter that
already passed `verify_id_token/3` → `Nebu.Web.Plugs.OidcPlug.verify_token/2` (full alg-allowlist,
JWKS signature, fail-closed iss/aud/exp/sub — identical to the Matrix bearer path) inside
`exchange_and_verify/3` (auth.ex:485-497), BEFORE this story's diff begins. The `bootstrap_draft`
table is server-side DB storage; the only client-reachable writer is `Nebu.Admin.BootstrapLive`,
which writes ONLY config-shape keys (instance_name, oidc_issuer/client_id/secret/audience/jwks_uri,
claim mappings) — never `bootstrap_full_claims`, `bootstrap_sub`, `bootstrap_email`, or
`bootstrap_claims`. There is no pre-authentication path by which an attacker can inject a crafted
claims map that would later be trusted as verified. Round-tripping the already-verified claims
through a Jason JSON blob opens no new surface — same trust boundary as the pre-existing
`bootstrap_claims` stash.

**(c) Guard-ordering (match?(:error, bootstrap_claims(draft))) — VERIFIED correct.**
The new guard sits at auth.ex:736 as the 4th `cond` clause, strictly BEFORE the `true ->` branch
(auth.ex:745) that runs `complete_bootstrap/2` (which sets `bootstrap_completed = "true"` and writes
`server_config`). If `bootstrap_claims(draft)` returns `:error`, the request halts with a redirect
and no config write, no completion, no session mint. Ordering is also correct relative to the
Kassandra C1 defense (clause 3, auth.ex:724): the C1 discovered-value check runs first and is
unchanged; the new claims-usability guard is purely additive. No bricking or state-divergence path:
completion and session mint both consume the same `bootstrap_claims(draft)` result, so
`bootstrap_completed` can never be set true from a state that would fail the session mint.

**(d) reconstruct_claims_from_flattened/1 — VERIFIED, no injection / claim-confusion risk.**
`Jason.decode/1` is used with default STRING keys throughout (auth.ex:647, 660). No
`String.to_atom`/`String.to_existing_atom`/`keys: :atoms` anywhere in the file — no atom-exhaustion
or atom-injection vector, and string keys match `UserId.from_claims/2`'s flat string-key lookups.
The comprehension (auth.ex:663) restricts to bare (non-dot-path) binary keys with binary values
only, folding repeats into lists; it operates on `bootstrap_claims`, itself written from the
verified token. It reconstructs a strict SUBSET of already-verified data — it cannot manufacture a
claim value the verified token did not contain. `Map.put_new_lazy` for sub/email only fills gaps and
cannot override a decoded value. Fails closed (`:error`) when neither stash is decodable.

**(e) Removed actor_id/1 fallback — VERIFIED genuinely gone; residual is bounded and self-healing.**
`git diff --staged server/lib/nebu/admin/rooms_controller.ex server/lib/nebu/admin/users_controller.ex`
is EMPTY — both controllers are byte-for-byte their pre-story form. The dropped defense-in-depth
fallback (flagged MAJOR in cycle 0 for silent mis-attribution under a non-default
`oidc_user_id_claim` plus ADR-020 scope creep) is not present under any renamed form. The shipping
`actor_id/1` retains its original behavior (fall back to raw `sub` only when `matrix_user_id` is
absent). The residual exposure is limited to STALE sessions minted before this fix deploys: those
lack `matrix_user_id` until the operator next logs in. This is bounded (admin sessions are TTL-capped
via `session_expiry/1` at min(idToken.exp, now+8h)) and self-healing (every fresh login now sets
`matrix_user_id`). No new or worse exposure than before this story — the fix strictly shrinks the
window in which a bootstrap-completion session lacks `matrix_user_id` from "always" to "never".

**(f) Adversarial sweep (fixation / replay / claim spoofing / C1 defense) — no new weakness.**
- Session fixation: `put_current_user/2` calls `configure_session(renew: true)` (auth.ex:312),
  rotating the session id on privilege elevation — the fixation defense is inherited, not weakened
  (the old hand-rolled path also renewed).
- Replay / state: `callback/2` still enforces state (`validate_state`) and nonce (`check_nonce`)
  before any bootstrap branch; unchanged by this diff.
- Kassandra C1 (claim-value injection): the `discovered_claim_values(draft)` gate (auth.ex:724)
  requiring the chosen `admin_group_claim` to be one of the verified token's discovered values is
  unchanged and still runs before the new guard and before completion. This story does not touch the
  admin-gate logic; admin status is still determined by `admin_claim?` reading `admin_group_claim()`
  from `server_config`. The reconstruction fallback exposes only a bare-key subset of the verified
  token to that scanner — no scope/claim WIDENING (cf. prior scope-widening findings), so the
  key-agnostic recursive `claim_value_matches?` scan receives no new input surface.
- Session_exp behavior change: routing through `put_current_user/2` now floors `session_exp` by
  `claims["exp"]` (session_expiry/1), where the old hand-rolled path used only now+TTL. This is a
  security IMPROVEMENT (session can no longer outlive the ID token) and is explicitly pinned by test.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED — CLEAN. The change consolidates the bootstrap-completion session mint onto the
single verified `put_current_user/2` builder, eliminating a real trust-boundary mis-attribution bug
while opening no new attack surface. All six SEC Gate 1 checkpoints pass. Controllers confirmed
reverted. The known stale-session residual is bounded, self-healing, and no worse than pre-story.
