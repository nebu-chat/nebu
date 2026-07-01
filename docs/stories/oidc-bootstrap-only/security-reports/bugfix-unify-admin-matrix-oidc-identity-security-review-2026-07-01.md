## Security Review — bugfix-unify-admin-matrix-oidc-identity

**Diff scope:** staged diff (`git diff --staged`) — OIDC scope unification between the Admin SSO login flow and the Matrix SSO login flow. Files:
- `server/lib/nebu/admin/auth.ex` (+42/-1) — `admin_oidc_scope/0` now unions Matrix extra scopes into the admin authorize request; new `union_scopes/2`; doc updates.
- `server/lib/nebu/matrix.ex` (+13) — new Public-API facade `matrix_oidc_extra_scopes/0` (ADR-020) delegating to `Nebu.Matrix.SsoLogin.matrix_extra_scopes/0`.
- `server/lib/nebu/matrix/sso_login.ex` (+7/-1) — `matrix_extra_scopes/0` visibility `defp` → `def` (`@doc false`).
- `server/test/nebu/admin/admin_matrix_identity_unification_test.exs` (+312, new) — 7 regression tests.

**Date:** 2026-07-01
**Reviewer:** Kassandra (nebu-agent-kassandra)
**Pipeline:** `--bug` run, no formal story file. Prior: 2 code-review cycles both CLEAN; full integration + unit suites green.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/admin/auth.ex:1083` (`admin_claim?/1`) reached via widened claim surface from `:960` | Admin-gate check matches the configured `admin_group_claim` value against EVERY claim value regardless of key. Folding Matrix scopes into the admin request now delivers additional claims (e.g. `name`, `preferred_username` from `profile`) into the admin ID token that were previously absent, widening the input surface `admin_claim?/1` scans. A non-admin whose IdP releases a folded-scope claim whose value literally equals the admin-group marker (e.g. a display `name` of `instance_admin`) could be classified admin. | Constrain `admin_claim?/1` to the specific claim key intended to carry group membership (e.g. the configured group claim key such as `groups`/`roles`), not an any-key value scan. Tracked as pre-existing design weakness now measurably widened — address at admin-auth hardening, not necessarily blocking this bugfix. |
| 2 | LOW | `server/lib/nebu/admin/auth.ex:972` (`union_scopes/2`) | If an operator manually types `offline_access` (or another privileged scope) into the `matrix_oidc_extra_scopes` server_config field, `union_scopes/2` folds it into the admin authorize request even when `admin_oidc_refresh_mode` is `online`, granting the admin session an offline refresh token it would not otherwise request. Config-driven, requires operator misconfiguration. | Optionally filter `offline_access` (and any refresh-mode-gated scope) out of the folded Matrix scopes so only claim-releasing scopes are unioned; refresh behaviour stays governed by `admin_refresh_mode` alone. |

### Detail

**Finding #1 — Admin-gate claim scan surface widened by scope union** [MEDIUM]

`admin_claim?/1` (auth.ex:1083–1093) iterates over ALL claim key/value pairs and returns `true` if ANY value equals the configured `admin_group_claim` (default `instance_admin`), or if any list-valued claim contains it. It is key-agnostic — it does not require the marker to appear under a specific `groups`/`roles` claim.

Before this fix, the admin authorize request carried only the scopes in `admin_oidc_extra_scopes`. After the fix (`admin_oidc_scope/0`, line 960: `extra = union_scopes(admin_extra_scopes(), Nebu.Matrix.matrix_oidc_extra_scopes())`), the admin ID token becomes a claim-SUPERSET: admin scopes ∪ Matrix scopes. Claims released only by Matrix-side scopes (e.g. `profile` → `name`, `preferred_username`) now arrive in the admin token and are scanned by `admin_claim?/1`.

Exploit path (narrow, IdP- and config-dependent): a non-admin user whose IdP emits a claim, newly present due to a folded Matrix scope, whose value literally equals the configured admin-group marker string, would be misclassified as admin. Realistic instance: `admin_group_claim = "instance_admin"`, Matrix flow requests `profile`, and a user sets their profile display `name` to `instance_admin`. Pre-fix that `name` claim was absent from the admin token; post-fix it is present and scanned.

The root weakness (any-key value scan) is PRE-EXISTING and out of this diff's authorship, but this change materially expands the set of attacker-influenceable claims fed to that scan for the admin gate. Correct behaviour cannot regress a real admin (their group scope is in `admin_extra_scopes`, preserved by the union), so the risk is one-directional false-positive elevation. Recommend hardening `admin_claim?/1` to a keyed lookup; not treated as blocking given the narrow preconditions and pre-existing nature.

**Finding #2 — Manual `offline_access` in matrix_oidc_extra_scopes folds into admin request** [LOW]

`offline_access` for the Matrix flow is appended separately by `SsoLogin.scope_list/0` based on `matrix_refresh_mode` (sso_login.ex:432) and is NOT part of `matrix_extra_scopes/0`, which the facade delegates to. So the normal offline path does NOT leak into the admin request — good, this neutralizes the primary concern of focus item #2. However, an operator who manually enters `offline_access` into the `matrix_oidc_extra_scopes` server_config value would have it unioned into the admin authorize request even when `admin_oidc_refresh_mode = online`, because `union_scopes/2` is content-agnostic. Effect: the admin session obtains a refresh token it would not otherwise request. Requires operator misconfiguration; low impact.

### Focus-Item Trace (requested by owner)

1. **Scope-union direction / leakage** — CONFIRMED one-directional. `union_scopes(admin_extra_scopes(), Nebu.Matrix.matrix_oidc_extra_scopes())` at auth.ex:960 flows Matrix scopes INTO the admin request only. `SsoLogin.scope_list/0` (sso_login.ex:429) is UNCHANGED and never reads admin scopes. An admin-only scope like `groups` is never requested by the Matrix client flow. No reverse leak. CLEAN.

2. **Widening admin scope / consent surface / offline_access** — `offline_access` is appended by refresh-mode logic in BOTH flows independently, not carried in the extra-scopes strings, and the facade delegates to `matrix_extra_scopes/0` (extra-only), so refresh-token capability is NOT folded in by normal config. Admin refresh remains gated by `admin_refresh_mode` (auth.ex:961, 1010 — any non-"offline" value collapses to "online"). See Finding #2 for the manual-misconfig edge. Otherwise CLEAN.

3. **Identity confusion / admin misclassification** — See Finding #1. The union makes the admin token a claim-superset, and `admin_claim?/1` scans all claim values; this widens the admin-gate input surface. MEDIUM.

4. **Session/token confusion (matrix_user_id trust boundary)** — `put_current_user/2` (auth.ex:248,254) sets `"admin" => admin_claim?(claims)` and `"matrix_user_id" => Nebu.Matrix.UserId.from_claims(claims, server_name())`. The fix does not change how `matrix_user_id` is trusted or how power-level-100 operator writes are attributed; it changes only which claims are present, driving the intended convergence of the two flows onto ONE user_id. No new trust boundary is created. The `admin` flag and `matrix_user_id` are derived independently from the same claims — a mismatched/attacker-influenced claim affecting `matrix_user_id` does NOT grant additional privilege beyond what the existing `from_claims/2` priority chain already allowed. CLEAN for this diff (the `admin_claim?` concern is captured separately in Finding #1).

5. **OIDC Scopes Law regression** — NO regression. `admin_extra_scopes/0` (auth.ex:978) and `matrix_extra_scopes/0` (sso_login.ex:446) both default to `""` when server_config is unset/Repo down. With both keys empty, `union_scopes("", "")` yields `""`, and `admin_oidc_scope/0` produces `openid`-only (plus `offline_access` iff refresh mode offline). The `defdelegate` target reads the same `""`-defaulting reader. Law preserved.

6. **`matrix_extra_scopes/0` visibility change (`defp` → `def`)** — The function reads only the `matrix_oidc_extra_scopes` server_config value (a scope string), NOT secrets. It is `@doc false`. It is reachable only from the ADR-020 facade `Nebu.Matrix.matrix_oidc_extra_scopes/0`; grep confirms the sole cross-domain caller is `admin_oidc_scope/0` (a `defp`, itself reachable only from the authenticated admin login-initiation path). No unauthenticated route reaches it, and it exposes no secret material. CLEAN.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 1 — advisory, address at admin-auth hardening (pre-existing `admin_claim?` design weakness, widened by this change; narrow IdP+config preconditions)
LOW: 1 — advisory (operator-misconfig edge)

**Verdict:** APPROVED — no CRITICAL/HIGH findings; commit is not blocked. Finding #1 (MEDIUM) and Finding #2 (LOW) are advisory. Finding #1 warrants a follow-up to key-scope the admin-group-claim match, as the pre-existing any-key value scan is now fed a wider, more attacker-influenceable claim set.
