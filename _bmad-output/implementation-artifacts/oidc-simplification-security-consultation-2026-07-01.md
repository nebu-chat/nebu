# Security Consultation — Epic "oidc-simplification" (pre-design)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Date:** 2026-07-01
**Type:** Consultation (pre-implementation, epic design input) — not a code review, no diff to gate.
**Requested by:** Phil — "OIDC-Implementierung konsolidieren, so dass Matrix und Admin dieselbe Logik für Claims und Scope nutzen."

This is input for `/bmad-agent-architect` to design the epic against. Scope of this document is
security implications and invariants — not the architecture itself (that's the architect's call).

## Why this epic is not speculative

Two live bugs shipped **today** on `bugfix/remove-default-scopes` because Admin and Matrix OIDC
logic are independently implemented:

- `81155881` **bugfix-unify-admin-matrix-oidc-identity** — same person got two different Matrix
  `user_id`s because `admin_oidc_extra_scopes` and `matrix_oidc_extra_scopes` are independently
  configurable, so the two flows released different claim sets, and `UserId.from_claims/2`'s
  claim-priority fallback landed on different values. Fixed by a one-directional scope union — an
  accepted MEDIUM was created in the process (see below) and the commit message and the arc42 update
  both explicitly say: *"centralize OIDC scope/claim resolution ... tracked as a follow-up
  architecture item"* → **this epic**.
- `83ea6e69` **bugfix-nested-oidc-claim-support** — `admin_claim?/1` and the bootstrap claim-picker
  only scanned flat claims, so no one could ever get the admin role on Keycloak (nested
  `realm_access.roles`). Widened the same accepted risk from flat→nested. Commit message again:
  *"proper fix ... deferred to the planned OIDC-centralization epic."*

Both are on today's `pipeline-state.yaml`. The pattern predicted this in general terms already
(project memory "OIDC Scopes Law": the same hardcoded-scope regression happened 2-3 times before
because the logic is duplicated). This epic is closing a gap that has already caused two production
bugs, not doing preventive tidying.

## Current state (grounded in code, 2026-07-01)

OIDC claims/scope logic lives in **3 independent per-domain implementations** that read/write the
same `server_config` rows through separate code paths:

| Concern | Matrix (`Nebu.Matrix.SsoLogin`) | Admin (`Nebu.Admin.Auth`) |
|---|---|---|
| Extra scopes read | `matrix_extra_scopes/0` (sso_login.ex:446) | `default_admin_extra_scopes/0` (auth.ex:992) — **plus** unions in Matrix's via the `Nebu.Matrix` facade (auth.ex:959-976) |
| Refresh mode read | `matrix_refresh_mode/0` (sso_login.ex:474), default **offline** | `admin_refresh_mode/0` (auth.ex:1010), default **online** — intentional (Dex only issues RT on `offline_access`; admin doesn't need silent refresh pressure) but undocumented-as-intentional in code, only in arc42 |
| Scope string validation | — (Matrix has no operator-facing scope write path) | TWO separate validators: `bootstrap_controller.ex:230-245` (`validate_scope_string/1`) and `admin/auth.ex:~1476` (bootstrap-completion promotion) — same regex (`^[a-zA-Z0-9_:.\-]+\z`), duplicated, not shared |
| Claim → Matrix user_id | `Nebu.Matrix.UserId.from_claims/2` (user_id.ex:17-54) | same function (Admin calls it too) — **this one is already correctly centralized** |
| Admin-group-claim gate | n/a | `admin_claim?/1` (auth.ex:1108-1134) — any-key, recursive value scan, no claim-path scoping |
| Config source-of-truth | `server_config` table (ADR-022) | same table, but **6 separate inline-SQL readers** across the two modules, no shared cache (Matrix's `oidc_user_id_claim` is the one exception — cached in `Nebu.Matrix.OidcClaimCache` with `:pg` cluster invalidation) |

**Already correctly shared / do not regress these:**
- `Nebu.Matrix.UserId.from_claims/2` — single mapper, both flows call it. Keep it the one identity function.
- `Nebu.Web.Plugs.OidcPlug.verify_token/2` — single token-verification function (sig/alg-allowlist/iss/aud/exp), both admin and Matrix paths route through it.
- `Nebu.Web.OidcConfig` + `Nebu.Web.JwksCache` — ETS-cached, `:pg`-invalidated, already living in the **shared-infra namespace** (`Nebu.Web`), not owned by either domain. This is the precedent to extend, not a green field.
- Scope-string whitelist regex is byte-identical in both write boundaries (just not shared as code).

## Non-negotiable invariants (any design MUST preserve)

1. **OIDC Scopes Law** (project memory, enforced 2-3 times already): hardcoded default extra-scope
   is `""` — the wire default is `openid` alone. Extra scopes ONLY from operator config
   (Bootstrap Wizard / `/admin/config`), never a source-code literal like `"profile email"`.
2. **`\z` anchor, not `$`**, on every scope-token validator (MEMORY pattern: `$` passes a trailing
   `\n` in Elixir regex). If validation logic is consolidated into one function, this is trivially
   preserved — but must be asserted with an explicit trailing-`\n` regression test, since the
   existing regression suite only pins the embedded-newline case.
3. **ADR-020 (public-API facade rule) — do not recreate the bug that was just fixed.** Code-review
   already caught and fixed a MAJOR today (`81155881` cycle 1): `Nebu.Admin.Auth` called
   `Nebu.Matrix.SsoLogin` directly instead of through the `Nebu.Matrix` facade. **A consolidation
   that puts the shared module inside `Nebu.Matrix` or `Nebu.Admin` and has the other domain call
   into it directly reproduces this exact violation.** See recommendation below.
4. **ADR-022 (bootstrap-only config)** — no `NEBU_OIDC_*`/`NEBU_ADMIN_OIDC_*` env var may reappear as
   a config source. `server_config` stays the only source of truth.
5. **Fail-closed on empty/unset config** — every reader must default to `""`/safe values, never to a
   hardcoded scope or a permissive claim key. This holds today; a consolidated cache must preserve it
   per-key, not just in aggregate.
6. **Cluster-wide cache coherency** — if extra `server_config` OIDC keys move into a shared cache
   (recommended, see Opportunity below), it MUST follow the existing `:pg`-broadcast invalidation
   pattern already used by `OidcConfig` and `OidcClaimCache` — a node-local-only cache would
   reintroduce a stale-config-after-admin-edit bug across a cluster.
7. **Test-seam isolation** — the `:{matrix,admin}_oidc_{extra_scopes,refresh_mode}_reader/writer`
   `Application.put_env` seams must remain provably test-only (confirmed clean today via grep — no
   `server/lib/**` sets them). Any refactor must re-verify this, since it's the thing standing
   between "test isolation" and "production override backdoor."
8. **CSRF + `require_admin` on every write boundary** — both existing scope-write routes
   (`/admin/config/scopes`, bootstrap step 3) are inside `protect_from_forgery` + admin/pre-auth
   gates. A unified write path must not accidentally widen this (e.g. a new shared config-write
   helper reachable from an unauthenticated route).

## What this epic should actually fix (the two deferred items — treat as MUST, not nice-to-have)

Both were explicitly deferred to "the OIDC-centralization epic" in today's commits — this epic
should close them, not just refactor around them:

1. **`admin_claim?/1` any-key value scan → path-scoped gate.** Today it matches the configured
   marker value against *every* claim value at *any* nesting depth, regardless of which claim key it
   appeared under. Accepted twice today (MEDIUM, flat→nested widening) specifically because closing
   it properly requires the bootstrap wizard to track the *claim key/path* the operator selected, not
   just the value — which is naturally in scope once claim resolution is centralized. Design
   requirement: the Bootstrap Wizard claim-picker (`extract_discovered_claims/1`, already dot-path
   aware for nested claims) already surfaces the key — persist it, and change `admin_claim?/1` (or
   its successor) to check `get_in(claims, path) == marker` / `marker in get_in(claims, path)`
   instead of a full-tree scan.
2. **`union_scopes/2` folding `offline_access` from Matrix's config into Admin's request.** LOW, but
   free to close for free while touching this code: filter refresh-mode-gated scopes
   (`offline_access`) out of whatever gets unioned/shared between the two flows; refresh capability
   should stay governed solely by each domain's own `{admin,matrix}_oidc_refresh_mode`.

## Architectural flag for `/bmad-agent-architect` (not prescribing the design, flagging the constraint)

Given invariant #3: the natural home for a consolidated "OIDC claims + scope resolution" module is
**`Nebu.Web`**, not `Nebu.Matrix` or `Nebu.Admin`. `Nebu.Web.OidcConfig` and `Nebu.Web.JwksCache`
already live there as shared infra per the project's own module structure (`Nebu.Web` = shared
infra, per CLAUDE.md). Putting the new shared module in a domain-owned namespace forces the other
domain to reach across a domain boundary — exactly the pattern that was a MAJOR finding a few hours
ago. Recommend the architect evaluate a `Nebu.Web.Oidc*` (or similarly-scoped shared-infra) module
as the target, with `Nebu.Matrix`/`Nebu.Admin` as thin call sites, over centralizing inside either
domain with a facade delegate from the other.

## Known limitation to scope explicitly (functional, but has an audit/compliance angle)

`81155881`'s fix prevents new identity divergence going forward; it does **not** merge identities
that already split under the old drift (room memberships, devices, and audit-log actor rows tied to
a stray opaque-`sub` user_id on any deployment that already hit this). Whether the epic needs a
detection/reconciliation story (at minimum: a report for the compliance officer of divergent
`sub`↔`user_id` pairs) is a product decision, not mine to make — but I'm flagging it because
un-merged duplicate identities is an audit-trail integrity concern (`Nebu.Compliance` correctness
depends on one person = one actor row), not purely a UX nuisance. Recommend the architect explicitly
accept-or-scope this rather than let it fall out silently.

## Security process for this epic

- **SEC Gate 1 (per story)** required on every story — this epic touches the live auth trust
  boundary for both Matrix and Admin. No `security_review: skipped` stories in this epic.
- **SEC Gate 2 (epic-end, mandatory)** — re-verify the full diff, with explicit focus on: (a) both
  deferred items above actually closed, not just moved; (b) no ADR-020 facade violation introduced by
  the new shared module; (c) OIDC Scopes Law regression check (grep for hardcoded scope literals);
  (d) cluster cache invalidation coverage for any newly-cached `server_config` key; (e) existing
  regression suite below still green, extended for the two MUST-FIX items.
- **Carry forward test files** (do not let a refactor silently drop coverage) —
  `bootstrap_scope_promotion_test.exs`, `config_scopes_test.exs`, `admin_bootstrap_groups_scope_test.exs`,
  `sso_login_scope_test.exs`, `admin_scope_mode_test.exs`, `migration_oidc_scopes_mutable_test.exs`,
  `oidc_claim_cache_test.exs`, `user_id_name_claim_test.exs`, `sso_login_configured_claim_device_test.exs`,
  `admin_oidc_login_test.exs`, `auth_test.exs`, `auth_bootstrap_gate_test.exs`, `bootstrap_oidc_flow_test.exs`,
  `bootstrap_oidc_audience_test.exs`, `oidc_plug_test.exs`, `oidc_bootstrap_only_test.exs`,
  `oidc_bootstrap_verify_test.exs`.

## No accepted-risk changes proposed here

This document does not modify or supersede the existing accepted-risk entries in
`_bmad/memory/nebu-agent-kassandra/BOND.md` / `MEMORY.md`. If the epic closes the `admin_claim?/1`
any-key-scan risk as designed above, that accepted-risk entry should be marked resolved at epic-end
review, not carried forward again.
