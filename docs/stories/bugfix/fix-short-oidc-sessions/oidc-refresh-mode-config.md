---
story_id: oidc-refresh-mode-config
title: "Configurable OIDC refresh mode (online vs offline_access) — bootstrap + runtime, transparent"
type: feature
severity: medium
epic: fix-short-oidc-sessions
status: done
security_review: required
created: 2026-06-23
branch: feature/full-elixir-stack
matrix: true
ui: true
---

## Summary

Today the OIDC scope is hardcoded: Matrix SSO always requests `offline_access`
(`sso_login.ex:305`), and the admin client **force-adds** `offline_access`
(`auth.ex: admin_oidc_scope/0`). Forcing `offline_access` on the admin client is a
problem in orgs where granting offline access to an admin requires a special IdP
approval — it hurts accessibility. And `offline_access` is the more security-sensitive
scope (long-lived, logout-surviving refresh token), so whether to use it should be an
explicit, transparent operator choice, not a hardcoded default.

Make the refresh mode **configurable and transparent**, separately for the Matrix client
and the admin client, set at **bootstrap** and **changeable later at runtime** via the
Admin UI (e.g. switch to `offline_access` during testing). Surface a clear in-product
explanation of what each mode means and how Nebu implements it.

### Critical IdP fact to surface in the hints
**Dex only issues a refresh token when `offline_access` is requested** — it has no
"online" refresh token. So in `online` mode, refresh works on Keycloak (session-bound RT)
but is **disabled on Dex** (no RT → short JWT sessions, i.e. the original logout problem).
The hint text MUST state this so operators don't foot-gun themselves.

## Acceptance Criteria

**AC1 — Two server_config settings, with sane defaults:**
`server_config` holds `matrix_oidc_refresh_mode` and `admin_oidc_refresh_mode`, each one of
`offline` | `online`. When unset, defaults are **Matrix = `offline`** (refresh works on Dex
& Keycloak; preserves current behavior) and **Admin = `online`** (no forced `offline_access`
→ no special IdP approval needed).

**AC2 — Matrix scope honors the setting:**
`Nebu.Matrix.SsoLogin.scope_list/0` includes `offline_access` iff `matrix_oidc_refresh_mode
== offline`; otherwise it requests `openid profile email` (+ `NEBU_OIDC_EXTRA_SCOPES`) without
`offline_access`. Read live from `server_config` (a change applies to subsequent logins
without a redeploy).

**AC3 — Admin scope honors the setting; offline_access no longer forced:**
`admin_oidc_scope/0` includes `offline_access` iff `admin_oidc_refresh_mode == offline`.
Default (`online`) requests `openid profile email` only — `offline_access` is NOT force-added.
(`openid` stays mandatory.) On Keycloak this yields a session-bound refresh token → admin
silent refresh still works without special approval. Read live from `server_config`.

**AC4 — Set at bootstrap:**
The bootstrap wizard lets the operator choose each refresh mode (defaults as AC1), with
explanatory hint text (incl. the Dex caveat + how Nebu stores/uses the RT). The choice is
promoted into `server_config` on bootstrap completion (alongside the existing OIDC config /
admin_group_claim promotion).

**AC5 — Changeable later at runtime (Admin UI):**
After bootstrap, an admin can change both refresh modes from the Admin UI config surface
(`/admin/config`), persisted to `server_config` via the existing admin config write path.
The change takes effect for subsequent logins/refreshes with no redeploy. (E.g. switch
Matrix or admin to `offline` during a test.)

**AC6 — Transparency:**
Both the bootstrap step and the Admin config page show, per client, a concise explanation:
- `offline` → long-lived offline refresh token; survives IdP logout; works on Dex & Keycloak;
  Nebu stores the RT AES-256-GCM-encrypted (server-side for Matrix, in the signed cookie for
  admin) and caps its own session at 8h.
- `online` → session-bound refresh token; dies on IdP SSO logout; **not supported on Dex
  (no refresh token issued there) → use offline for Dex**.

**AC7 — No regression:**
Existing login/SSO/admin-refresh flows keep working. With Matrix default `offline`, the
`oidc-session-refresh` behavior is unchanged. With admin default `online`, admin silent
refresh continues to work on Keycloak (online RT); on Dex admin falls back to the 8h session
cap (documented). A `Logger.warning` (from the admin story) still fires when admin is near
expiry with no RT.

## Acceptance Tests

### Tests written FIRST:
1. **[AC2] ExUnit** — `scope_list/0` with `server_config.matrix_oidc_refresh_mode = offline`
   → includes `offline_access`; `= online` → excludes it; unset → defaults to `offline`
   (includes). Extra scopes still appended. (`server/test/nebu/matrix/sso_scope_mode_test.exs`)
2. **[AC3] ExUnit** — `admin_oidc_scope/0` with `admin_oidc_refresh_mode = offline` → includes
   `offline_access`; `= online` (and unset) → `openid profile email`, **no** `offline_access`;
   `openid` always present. (`server/test/nebu/admin/admin_scope_mode_test.exs`)
3. **[AC4] ExUnit** — bootstrap completion promotes the chosen modes into `server_config`
   (extend the bootstrap/confirm test).
4. **[AC5] ExUnit/LiveView** — `/admin/config` ConfigLive: changing each mode upserts
   `server_config` and the new value is read back; the scope builders reflect it on the next call.
5. **[AC6] e2e Gherkin** — bootstrap wizard + `/admin/config` render the mode selector with the
   hint text incl. the Dex caveat. (`e2e/features/admin/oidc-refresh-mode.feature`, may start `@pending`.)
6. **[AC7] ExUnit** — defaults unset → Matrix offline / Admin online; existing SSO + admin
   refresh tests still green.

## Dev Notes

### Where each piece goes (ADR-018 inline SQL, ADR-020 public-API rule)
- **server_config keys:** `matrix_oidc_refresh_mode`, `admin_oidc_refresh_mode` (values
  `offline`|`online`). `server_config` is the existing `(key, value, set_at)` table.
- **Read helpers:**
  - Matrix: `scope_list/0` reads `SELECT value FROM server_config WHERE key='matrix_oidc_refresh_mode'`
    via `Nebu.Repo`/`Postgrex` directly (ADR-018 — DB access, not a cross-domain module call).
    Login-start frequency is low, a direct read is fine; OR follow the cluster-aware
    `Nebu.Matrix.OidcClaimCache` (`persistent_term` + `:pg` invalidation) pattern if caching is
    wanted — direct read is acceptable for MVP, note the choice. Default `offline` when absent.
  - Admin: `admin_oidc_scope/0` reads `admin_oidc_refresh_mode` from `server_config` (reuse the
    admin server_config read path; default `online` when absent). **Remove the forced
    `["offline_access"]`** — only `openid` stays mandatory; add `offline_access` iff mode=offline.
- **Bootstrap (AC4):** `Nebu.Admin.BootstrapLive` — add the mode selectors (Matrix + Admin) to the
  OIDC step (or a small new sub-step), persist to `bootstrap_draft`, and have
  `Nebu.Admin.Auth.bootstrap_confirm_claim/2` promote them into `server_config` alongside the
  existing keys. Defaults preselected (Matrix offline / Admin online).
- **Runtime (AC5):** `Nebu.Admin.ConfigLive` (`/admin/config`) — add the two mode controls; write
  via the existing admin config write path (`Nebu.Admin.DB.upsert_server_config/1` or the
  EventDispatcher `update_server_config`). Show current value + hint.
- **Hints (AC6):** concise copy in both BootstrapLive and ConfigLive templates. Include the Dex
  caveat verbatim ("Dex issues a refresh token only with offline_access; online mode disables
  refresh on Dex") and the at-rest/8h-cap note.

### Security
- This is an auth-scope/config change → `security_review: required`. No new secret handling
  (the RT storage/crypto already exists from the prior two stories). Kassandra focus: ensure the
  mode value is validated to the `offline`|`online` enum (no scope injection via server_config),
  the admin config write is admin-gated + CSRF-protected, and that switching to `online` cannot
  be abused to silently weaken/skip verification (it only changes the requested scope; token
  verification is unchanged). Confirm de-forcing admin `offline_access` doesn't break admin
  refresh on Keycloak (online RT) and that the Dex consequence is clearly surfaced, not silent.

### File List (expected)
**Modified:** `server/lib/nebu/matrix/sso_login.ex` (scope_list reads mode),
`server/lib/nebu/admin/auth.ex` (admin_oidc_scope reads mode, de-force offline_access; bootstrap
promotion), `server/lib/nebu/admin/bootstrap_live.ex` (+ template) (mode selectors + hints),
`server/lib/nebu/admin/config_live.ex` (+ template) (runtime mode controls + hints).
**New tests:** `server/test/nebu/matrix/sso_scope_mode_test.exs`,
`server/test/nebu/admin/admin_scope_mode_test.exs`, ConfigLive test, e2e feature.

### Known limitation
`online` mode on Dex = no refresh (Dex requires offline_access). Surfaced in the hint, not
silently degraded. No migration (server_config is an existing key/value table).

## Dev Agent Record

### Completion Notes (Amelia / Dev, 2026-06-23)

Implemented the configurable, transparent OIDC refresh mode (Matrix + Admin), bootstrap +
runtime, with enum-validated writes. All previously-red unit tests pass; full unit suite green.

**How each AC is satisfied**
- **AC1/AC7 (defaults):** Matrix `matrix_refresh_mode/0` defaults to `offline` when absent;
  Admin `admin_refresh_mode/0` defaults to `online` when absent. Existing SSO/admin tests green.
- **AC2 (Matrix scope):** `sso_login.ex` `scope_list/0` now appends `offline_access` only when
  mode == `offline`. Base `openid profile email` + `NEBU_OIDC_EXTRA_SCOPES` always kept. Reader
  seam `:matrix_oidc_refresh_mode_reader`; default reads `server_config` live (ADR-018 inline SQL).
- **AC3 (Admin scope):** `auth.ex` `admin_oidc_scope/0` STOPPED force-adding `offline_access`.
  `openid` stays mandatory; configured `:admin_oidc_scope` honored; `offline_access` added only when
  mode == `offline`. Reader seam `:admin_oidc_refresh_mode_reader`; default reads `server_config`.
- **AC4 (bootstrap promote):** `do_complete_bootstrap/2` promotes `matrix_oidc_refresh_mode` +
  `admin_oidc_refresh_mode` with an enum guard (only `offline`|`online` written, else not promoted).
  `BootstrapLive` step 3 adds two native `<select>`s (Matrix offline / Admin online preselected),
  persisted to the draft in `save_claim_mapping/1` via `put_draft/2`, with hint text.
- **AC5 (runtime):** `ConfigLive` (`/admin/config`) adds two native `<select>`s in a
  `phx-change="save_refresh_mode"` form routing through `Nebu.Admin.DB.upsert_server_config/1`;
  current value reflected via `get_server_config/0`; selected option re-read after save.
- **AC6 (transparency):** Hint text in BOTH BootstrapLive and ConfigLive contains `Dex`,
  `offline_access`, `refresh token`, plus the at-rest-encrypted + 8h-cap note.
- **SECURITY (enum validation):** Both write paths (ConfigLive `save_refresh_mode`, bootstrap
  promotion) and both read defaults validate to exactly `offline`|`online`; anything else collapses
  to the client's default — no scope injection via `server_config`. New unit test asserts junk-value
  rejection in bootstrap promotion (`bootstrap_refresh_mode_promotion_test.exs`).

**Tests:** `make test-unit-elixir` → 777 passed, 2 skipped, 120 excluded; clean under
`--warnings-as-errors`. The targeted red tests (sso_scope_mode 14 incl. siblings, admin_scope_mode,
bootstrap_refresh_mode_promotion, config_live render) are green. `:integration` round-trips
(live-Repo `upsert_server_config/1`) NOT run locally (no DB stack up) → run via `make test-integration`.

**Deviation (justified, not a test-weakening):** `admin_token_refresh_test.exs:153` `[AC1]` asserted
the *prior* story's behavior (admin login ALWAYS force-requests `offline_access`). This story (AC3)
deliberately reverses that default to `online`. Updated that single assertion to pin the NEW default
(`openid` present, `offline_access` absent in default/online mode), with a comment marking it
superseded. The mode-driven offline behavior is covered by the new `admin_scope_mode_test.exs`.

### File List

**Modified (implementation):**
- `server/lib/nebu/matrix/sso_login.ex` — `scope_list/0` reads mode via `:matrix_oidc_refresh_mode_reader` seam (default `offline`); added `matrix_refresh_mode/0` + `default_matrix_refresh_mode/0`.
- `server/lib/nebu/admin/auth.ex` — `admin_oidc_scope/0` de-forces `offline_access`, reads mode via `:admin_oidc_refresh_mode_reader` seam (default `online`); added `admin_refresh_mode/0` + `default_admin_refresh_mode/0`; `do_complete_bootstrap/2` promotes the two mode keys with enum guard.
- `server/lib/nebu/admin/bootstrap_live.ex` — two `<select>` mode controls + hint on step 3; `save_claim_mapping/1` persists modes (enum-validated) to draft.
- `server/lib/nebu/admin/config_live.ex` — two `<select>` mode controls + Dex hint; `save_refresh_mode` handler (enum-validated) routes through `upsert_server_config/1`; reflects current value.

**Modified (test, superseded assertion):**
- `server/test/nebu/admin/admin_token_refresh_test.exs` — `[AC1]` assertion updated to the new admin default (online → no forced `offline_access`).

**Added (test):**
- `server/test/nebu/admin/bootstrap_refresh_mode_promotion_test.exs` — junk-value rejection test + `install_store/1` override arg (the ATDD red test file).

### Change Log
- 2026-06-23: Implemented oidc-refresh-mode-config (AC1–AC7). Configurable Matrix/Admin OIDC refresh
  mode, bootstrap + runtime, enum-validated writes. Unit suite green (777). (Amelia)
