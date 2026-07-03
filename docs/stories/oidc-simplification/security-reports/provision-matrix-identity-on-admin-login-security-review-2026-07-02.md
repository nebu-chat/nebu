## Security Review — provision-matrix-identity-on-admin-login (epic: oidc-simplification)

**Diff scope:** `git diff --staged`. Security-relevant code: `server/lib/nebu/matrix.ex` (new `provision_identity/2` facade + `repo_reachable?/0`/`maybe_upsert_profile/2` helpers), `server/lib/nebu/admin/auth.ex` (new `provision_matrix_identity/1`, wired into `normal_callback/2` and `bootstrap_confirm_claim/2`). Non-code: story file, arc42 `08-concepts.md`, test file `admin_oidc_login_test.exs`.
**Date:** 2026-07-02
**Reviewer:** Kassandra (nebu-agent-kassandra)

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No CRITICAL/HIGH/MEDIUM findings | — |
| 1 | LOW / INFO | `admin/auth.ex:582,811` (pre-existing) | Admin session mint is gated on the OIDC admin-group claim, NOT on the Matrix `users.is_active` flag. A deactivated Matrix identity that still carries the admin-group claim still gets an admin session; the new swallow of `{:error, :deactivated}` does not change this but makes it worth restating. | Optional hardening: if a `{:error, :deactivated}` is returned, treat the admin login as denied. Requires product decision — Matrix deactivation and admin-UI authorization are currently independent axes. Not introduced by this diff. |

### Detail

**SEC Consideration 1 — No privilege-escalation via provisioning.** VERIFIED SAFE. The admin path calls `Nebu.Matrix.provision_identity(user_id, display_name:, email:)` with no `system_role`, so it defaults to `"user"`. `TokenValidator.validate/4` only creates a row on first sight; role resolution flows through `BootstrapChecker.upsert_with_bootstrap/2`, whose upsert (`ON CONFLICT DO UPDATE SET last_seen_at = ...`) never rewrites `system_role` for an existing user, and resolves `instance_admin` ONLY when the genuine bootstrap condition holds (no `bootstrap_completed` row AND empty `users` table). A post-bootstrap admin-only login therefore provisions a plain `"user"` role. Provisioning grants no Matrix permissions beyond a regular first-time `/login`; room actions remain gated by membership/power-level checks. No escalation path.

**SEC Consideration 2 — ADR-020 compliance.** VERIFIED SAFE. `Nebu.Admin.Auth` reaches provisioning exclusively via `Nebu.Matrix.provision_identity/2` (the public facade). It does not call `Nebu.Matrix.Session.TokenValidator` or `Nebu.Matrix.Profile.DB` directly — those calls live inside `Nebu.Matrix`. Grep confirms no cross-domain submodule reference in the admin path.

**SEC Consideration 3 — AC2 auto-join info-leak avoidance.** VERIFIED SAFE by reading the actual call graph. `provision_identity/2` calls `TokenValidator.validate/4` then `maybe_upsert_profile/2` (→ `Profile.DB.upsert_profile/3`) and returns. It deliberately omits `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2`, which is the ONLY entry to `ensure_auto_join_memberships/1` on the login path (present in `http_public.ex:347`, absent here). The admin-only provisioning path can never trigger auto-join into `is_auto_join` rooms. The story's AC2 claim matches the implementation.

**SEC Consideration 4 — No DoS via repeated provisioning.** VERIFIED SAFE. Provisioning is idempotent: on an existing row `validate/4` takes the lookup/decrypt branch (a single indexed `SELECT` + decrypt, no writes beyond `last_seen_at`), and `upsert_profile/3` is a nil-safe `COALESCE` upsert (no write amplification, no row growth). Repeated admin logins produce at most one bounded `SELECT`+`UPDATE last_seen_at`+profile upsert. Login is rate-limited upstream. No unbounded resource consumption.

**Claims trust boundary.** VERIFIED SAFE. In `normal_callback/2`, `claims` originate from `exchange_and_verify → verify_id_token` (signature/alg/iss/aud/exp via `OidcPlug.verify_token`) plus `check_nonce/2`, all completed in `do_callback/2` before `normal_callback` runs. In `bootstrap_confirm_claim/2`, `claims` come from the draft's `bootstrap_full_claims` key, written ONLY by `bootstrap_callback/2` after the identical verification (Jason round-trip, string keys). No client-writable path into that draft key. `display_name`/`email` are attacker-influenceable only within the bounds of IdP-issued, signature-verified claims — the same trust level the real `/login` path accepts.

**Injection / safe derivation.** VERIFIED SAFE. `matrix_user_id` is derived via `Nebu.Matrix.UserId.from_claims/2` (single source of truth), which `sanitize/1`s the localpart to the Matrix grammar `[a-z0-9._=\-\/+]`, neutralizing any malicious claim value. `display_name`/`email` reach `Profile.DB.upsert_profile/3` and `UserProvisioner` via fully parameterized `Ecto.Adapters.SQL.query` (`$1,$2,$3`) — no SQL injection. Display name is stored PII-encrypted. The derivation is byte-identical to `put_current_user/2` (auth.ex:294) and `provision_and_respond/6` (http_public.ex:327), so no identity divergence.

**Error swallowing.** ANALYZED — not a new finding. `provision_matrix_identity/1` logs and returns `:ok` for any `{:error, reason}` (including `{:error, :deactivated}` and `{:error, :repo_not_started}`), so the admin session mint is never blocked. This does not hide a NEW security-relevant failure: the admin session was already, and remains, gated solely on the OIDC admin-group claim (`check_admin/1`), never on the Matrix `users.is_active` flag. A deactivated Matrix identity with the admin claim could already obtain an admin session before this change; the swallow neither introduces nor widens that. Restated as INFO finding #1 for the audit trail; hardening is a product decision, not a regression.

**`repo_reachable?/0` guard.** VERIFIED SAFE (matches accepted pattern: injectable seam is prod-safe iff never set outside tests). `validator_overridden_for_test?/0` reads `:session_manager, :validator_module`, which is set ONLY in `test/` — grep of `lib/` and `config/` shows the key is read but never written, and the default is `Postgres`. In production the override branch is dead, so `repo_reachable?/0` reduces to `Process.whereis(Nebu.Repo) != nil`. If Repo is briefly down, provisioning returns `{:error, :repo_not_started}` (swallowed) and the users-row is created on the next successful login — graceful degradation, not a security-sensitive bypass, since the admin session was never gated on the users-row.

**Audit trail / compliance parity.** VERIFIED SAFE. Neither the real `/login` provisioning path (`provision_and_respond/6` → `TokenValidator`/`UserProvisioner`) nor the new facade emits a `Nebu.Compliance` audit event for the provisioning step. The new path therefore does not bypass an audit requirement the login path satisfies — parity holds. (Whether provisioning SHOULD be audited is a separate epic-level question, unchanged by this diff.)

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW/INFO: 1 (pre-existing; admin session not gated on Matrix `is_active` — restated, not introduced)

**Verdict:** APPROVED — CLEAN. No commit-blocking findings. All four SEC-Gate-1 considerations and all independent checks verified against the actual call graph, not the story's claims alone.
