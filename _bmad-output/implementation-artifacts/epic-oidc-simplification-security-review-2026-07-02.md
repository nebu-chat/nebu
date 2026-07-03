# Epic oidc-simplification Security Review (SEC Gate 2) — 2026-07-02

## Scope
- Epic: oidc-simplification (mandatory epic-end SEC Gate 2)
- Base: dd4a5a90
- HEAD: 2e67f51a
- Diff range: `git diff dd4a5a90..HEAD`
- Reviewer: Kassandra (adversarial security review)
- Stories covered (landing order):
  1. centralize-claim-resolution (64bedc2a) — `Nebu.Web.OidcClaims` recursive claim-walker
  2. admin-liveview-session-refresh (5bfa2b63) — LiveView keepalive silent-refresh (shipped w/ HIGH, fixed same-day)
  3. centralize-scope-resolution (d259ebe5) — `Nebu.Web.OidcScopes` single scope source
  4. fix-bootstrap-admin-session-identity (2fc86222) — bootstrap login sets matrix_user_id via shared builder
  5. fix-matrix-login-missing-refresh-token (62db9f08) — diagnostic logging parity
  6. matrix-refresh-revalidates-with-idp (258e59fc) — `Nebu.Web.OidcTokenExchange` IdP re-validation (MAJOR fixed same-day)
  7. provision-matrix-identity-on-admin-login (e72165bf) — `Nebu.Matrix.provision_identity/2` facade
  8. scope-admin-claim-to-path (b62e346b) — path-scoped admin_group_claim gate (core security fix)

Each story passed its own SEC Gate 1 (all CLEAN in final state; findings fixed same-cycle). This
review re-verified every prior verdict AGAINST CODE (not trusted) and audited the cross-story surface.

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| A-1 | LOW | 8 (pre-existing) | admin/role_mapping_controller.ex:46 | Post-bootstrap `admin_group_claim` value edit writes value alone, never co-updating `admin_group_claim_path` → path/value decouple | Pre-existing, out of diff scope, fails CLOSED |

No CRITICAL, no HIGH, no MEDIUM, no NEW findings.

## Cross-Story Verification (this review's primary job)

### CS-1 — Stories 6 + 7 compose safely (both touch admin/auth.ex login + call Matrix facades) — CLEAN
- **No double-provisioning.** `provision_matrix_identity/1` (auth.ex:337) is called exactly ONCE from
  each of the two login-completion branches: `normal_callback/2` (auth.ex:582) and the bootstrap
  completion `true ->` branch (auth.ex:893). These branches are mutually exclusive (mode-gated in
  `do_callback/2`). The pre-expiry silent-refresh path `refresh_admin_session/1` (auth.ex:196)
  deliberately does NOT call provision (documented auth.ex:317-324) — re-provisioning on every
  refreshed request would be needless and is not a new login.
- **No session-identity divergence.** Both login paths mint via the single `put_current_user/2`
  builder (auth.ex:282), whose `matrix_user_id` is derived via `Nebu.Matrix.UserId.from_claims/2`
  (single source of truth). `provision_matrix_identity` derives the SAME matrix_user_id from the same
  claims. Story 4 fixed the historical gap where bootstrap-completion omitted matrix_user_id — now the
  bootstrap path stashes the full verified claims (`bootstrap_full_claims`) so its session is
  byte-identical to a subsequent normal re-login of the same operator.
- **No ordering-dependent bug.** Story 6 (OidcTokenExchange) lives on the REFRESH paths (admin
  `refresh_admin_session/1` + Matrix `do_refresh_with/2`); story 7 (provision_identity) lives on the
  LOGIN-COMPLETION paths. Disjoint code paths in auth.ex — no shared mutable state, no ordering
  coupling. Both refresh paths use the SAME shared `Nebu.Web.OidcTokenExchange.refresh/2`, each
  resolving its OWN client config (issuer/client_id/client_secret) — the module reads no
  domain-specific config or Application-env seam itself.

### CS-2 — Story 8 path-scoped fix depends on story 1's OidcClaims; fallback does not reintroduce risk — CLEAN
- `admin_marker` decision lives in `admin_claim?/1` (auth.ex:1298), the ONLY admin-decision function.
  Grep-confirmed callers: exactly TWO — `put_current_user/2` (auth.ex:288, session mint for BOTH login
  paths) and `check_admin/1` (auth.ex:1017, callback gate + refresh re-check). No other admin decision
  exists in lib/.
- Path-scoped branch calls `Nebu.Web.OidcClaims.claim_at_path_matches?/3` (oidc_claims.ex:119), which
  resolves ONLY the operator-selected dot-path (`resolve_path/2` walks exact segments, `:error` on any
  miss → fails closed). The legacy any-key `claim_value_matches?/2` scan is now reachable ONLY via
  admin_claim?'s fallback branch (auth.ex:1311), and ONLY when `admin_group_claim_path` is unset —
  i.e. deployments bootstrapped before story 8 shipped (they have no path row and never will short of
  a manual re-run). A fresh bootstrap CANNOT land path-less: `is_nil(selected_path)` is refused before
  completion (auth.ex:822), bootstrap runs once (`bootstrap_completed?` guard).
- The final shape lives where story 1 intended: the recursive walkers are in `Nebu.Web.OidcClaims`
  (shared infra, ADR-020), and story 8 added the path-scoped matcher to the same module. No drift.

### CS-3 — Migration chain / RLS coverage — CLEAN
- Only ONE new migration in this epic: `000016_config_admin_group_claim_path`. (The scope keys
  `matrix_oidc_extra_scopes`/`admin_oidc_extra_scopes` come from pre-existing 000013; the refresh-mode
  keys from pre-existing 000007 — stories 3 and 6 REUSE those keys, they add no migration.)
- 000016 is a pure RLS widening: it re-creates `config_update_mutable` adding `admin_group_claim_path`
  to the `key IN (...)` allowlist while PRESERVING all prior keys (verified: all 000013/000007 keys
  present). UPDATE policy remains allowlist-scoped (pattern: permissive UPDATE without key-scope
  respected). server_config retains ENABLE + FORCE RLS (000001), `config_read_all` (SELECT),
  `config_insert_only` (INSERT WITH CHECK true — bootstrap writes the path via INSERT ON CONFLICT, so
  UPDATE-only widening is correct). Down migration cleanly reverts to the 000013 allowlist. No key
  missed, no RLS gap.

### CS-4 — Shared Nebu.Web modules called from both domains; ADR-020 holds — CLEAN
- New cross-domain reaches introduced by the epic (grep of added `+` lines): `Nebu.Matrix.provision_identity/2`
  (top-level Matrix facade — the ADR-020 entry point itself) and `Nebu.Matrix.UserId.from_claims/2`
  (shared identity value function, pre-existing usage). The scope-leak `Nebu.Matrix.matrix_oidc_extra_scopes/0`
  union call was DELETED by story 3.
- The three shared modules (`OidcClaims`, `OidcScopes`, `OidcTokenExchange`) all live under `Nebu.Web`
  (shared infra by ADR-020) and are pure/stateless (no process, no domain config). No domain reaches
  into another domain's SUBmodule directly in this diff.

### CS-5 — Accepted-risk staleness sweep — CLEAN
- The any-key claim-value scan risk (accepted TWICE on 2026-07-01: bugfix-unify-admin-matrix-oidc-identity
  + bugfix-nested-oidc-claim-support) is RESOLVED by story 8 and is no longer carried as open. It is the
  only accepted risk this epic touches.
- The sole standing formal Accepted Risk in the sanctum (audit_log FORCE RLS removal, Story 13.14,
  2026-05-18) is UNTOUCHED by this epic (grep of diff for audit_log/FORCE ROW/BYPASSRLS = zero
  attributable changes). No other accepted-risk entry is made stale by this epic's changes.

## Per-Story Re-Verification Against Code

- **Story 2 (HIGH fixed):** `refreshable?/2` (auth.ex:1459) now requires BOTH decryptability AND
  `now <= refresh_grace_exp` (server-written independent bound, set in `put_current_user/2` at login
  and every successful HTTP-path refresh, NEVER advanced by a socket reconnect). The decrypt-gated
  grace window with no independent time bound is CLOSED. Bootstrap-completion path stores no RT →
  refreshable? returns false → no indefinite grace. Client keepalive (app.js) is same-origin GET,
  no response read, no eval/innerHTML/postMessage — its severability is exactly why the server-side
  bound is the enforcement.
- **Story 6 (MAJOR fixed):** `check_still_active/2` (http_public.ex:644) derives display_name/email
  from FRESH IdP claims (not hardcoded "") so the `signing_key_id IS NULL` backfill branch never
  blanks a not-yet-backfilled user's PII or spuriously regenerates keypairs. Confirmed-vs-transient
  fail-close is SAFE: identical `deny_soft_logout` 401 envelope on both; hard-delete
  (`delete_for_user_device/2`) ONLY on confirmed `:deactivated`/IdP-rejection; transient DB failure
  (`{:transient_check_failed, _}`) leaves the session row intact; transient path mints nothing.
- **Story 6 OidcTokenExchange:** TLS peer verification present for https token endpoints
  (`verify_peer` + cacerts + hostname match) — the `:httpc` empty-ssl-opts gap (recurring pattern,
  struck 3x historically) is NOT reintroduced. Fail-closed on every error branch; no local fallback.
- **Story 7 provision_identity:** reuses TokenValidator.validate/4 + nil-safe COALESCE upsert_profile
  (blank display_name → nil → never clobbers). Deliberately omits `run_post_login_provisioning`
  (no auto-join) — the omitted step is the sole entry to the auto-join risk; the shared upsert never
  rewrites role/privilege columns (system_role defaults "user", upsert touches display_name only).
- **Stories 1, 3, 4, 5:** re-confirmed matching their SEC Gate 1 verdicts (OidcClaims pure/self-contained;
  OidcScopes `\z`-anchored single validator + union-scope leak deleted; bootstrap identity via shared
  builder; diagnostic logging carries no token/secret/RT value — grep clean).

## Detail — A-1 (LOW, pre-existing, out of diff scope)
`RoleMappingController.update/2` (role_mapping_controller.ex:46) writes the `admin_group_claim` VALUE
alone and never co-updates `admin_group_claim_path`. After a post-bootstrap value edit, `admin_claim?/1`
resolves the still-configured path, finds the OLD value there, and the NEW target value is absent from
that path → returns false. This FAILS CLOSED: an admin using this editor can only lock out
themselves/legit admins, NEVER elevate a non-admin. The file is not part of the epic diff; this is the
pre-existing advisory recorded at story 8's SEC Gate 1. Recommended follow-up (non-blocking): co-edit
or re-validate the path alongside the value in that editor.

## Cross-Story Patterns
No systemic weakness. On the contrary, this epic is a net security IMPROVEMENT: it centralizes three
previously-duplicated OIDC surfaces (claims/scopes/token-exchange) into single audited `Nebu.Web`
sources, deletes a cross-client scope-leak (story 3), closes a decrypt-gated grace window (story 2),
adds IdP re-validation to Matrix /refresh (story 6), and closes the twice-accepted any-key
claim-value-scan privilege-elevation risk (story 8).

## Accepted Risks
None newly accepted. The previously twice-accepted any-key-scan risk is now RESOLVED (not carried).

## Follow-up Stories Required
None (blocking). Optional hardening: co-edit `admin_group_claim_path` in RoleMappingController (A-1).

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 1 (pre-existing, out of scope, fails closed)
Follow-up stories required: 0
Accepted risks: 0 new (1 prior any-key-scan risk RESOLVED by this epic)

**Epic security gate: PASS / CLEAN** — safe to mark epic done / merge feature/oidc-simplification.
