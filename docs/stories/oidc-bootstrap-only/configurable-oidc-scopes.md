---
story_id: configurable-oidc-scopes
title: Konfigurierbare OIDC Scopes im Bootstrap Wizard
type: feature
severity: medium
epic: oidc-bootstrap-only
status: ready-for-dev
security_review: required
created: 2026-06-30
---

## Summary

Implement **operator-configurable OIDC scopes** in the Bootstrap Wizard via `server_config` fields (`matrix_oidc_extra_scopes`, `admin_oidc_extra_scopes`). Today, scopes are hardcoded in two places:

- `server/lib/nebu/matrix/sso_login.ex:431` — `@base_scopes ~w(openid profile email)` (fixed) + `offline_access` for offline mode
- `server/lib/nebu/admin/auth.ex:924-932` — `admin_oidc_scope/0` hardcodes `"openid profile email groups"` + `offline_access` for offline mode

**After this story:** The operator can set custom scopes via the bootstrap wizard (UI before the refresh-mode fieldset) and both code paths read from `server_config` at runtime. `openid` remains fixed (OIDC-mandatory), all others are customizable per client.

**ADR reference:** ADR-022 (OIDC Bootstrap-Only). Scope configuration is a direct extension of the operator-control pattern: via bootstrap wizard → server_config → runtime DB reads.

---

## Motivation

**OIDC Scope Problem:** Different IdPs release different claims under different scope names. Some providers require explicit `groups` scope for group claims; others include claims without request. The operator needs control over which scopes are requested without code changes or redeployment.

**Current state is fragile:** Hardcoding limits the server to one fixed scope set. If the operator's IdP does not honor the hardcoded scopes (e.g., groups claim missing without explicit scope), the bootstrap fails or critical fields are empty.

**Design is "operator-centric":** Bootstrap Wizard is now the single source of truth for OIDC config (ADR-022). Scopes follow the same pattern: editable fields → server_config → runtime reads via seams.

---

## Non-Goals

- **No dynamic scope addition via API** after bootstrap. Scope changes require editing via `/admin/config` (existing capability).
- **No scope request strategy** (e.g., incremental/optional scopes per claim). All requested scopes are in the scope string; the IdP decides what to grant.
- **No scope discovery/suggestion** (e.g., "probe what scopes this IdP supports"). The operator declares what they need.

---

## Acceptance Criteria

### AC1 — Database: RLS Policy erweitern

`server_config` ist ein Key-Value-Store (`key TEXT PRIMARY KEY, value TEXT, set_at BIGINT`). Neue Scope-Schlüssel werden als Zeilen gespeichert — kein Schema-Change nötig. ABER: die `config_update_mutable` RLS-Policy auf `server_config` erlaubt `UPDATE` nur für explizit gelistete Keys (Muster aus `000007_config_refresh_mode_mutable.up.sql`).

**Given** eine neue Migration `server/priv/migrations/000013_config_oidc_scopes_mutable.up.sql`,  
**When** sie ausgeführt wird,  
**Then** wird `config_update_mutable` neu erstellt (DROP + CREATE, idempotent) und enthält `'matrix_oidc_extra_scopes'` und `'admin_oidc_extra_scopes'` in der USING-Klausel.

Die korrespondierende `.down.sql` stellt die Policy ohne die neuen Keys wieder her.

(Die `complete_bootstrap/1`-Funktion in `auth.ex` wird die Werte via `INSERT INTO server_config` speichern — analog zu `matrix_oidc_refresh_mode` / `admin_oidc_refresh_mode`.)

---

### AC2 — Bootstrap Wizard UI

**Given** the Bootstrap Wizard Step 2 (OIDC config),  
**When** it renders,  
**Then** two new text input fields appear **immediately before** the "OIDC refresh mode" fieldset (line 504 of bootstrap_live.ex):

1. **"Matrix client scopes"** (name: `matrix_oidc_extra_scopes`)
   - Placeholder: `"profile email"` (the current default set minus `openid`)
   - Help text: "Space-separated scope names. `openid` is always included. Example: `profile email groups custom_scope`"
   - Validation: Allow `[a-zA-Z0-9_:.-]` characters only (no spaces within a scope name; spaces separate scopes). Reject any other characters with a user-facing error.
   - Default (pre-filled): `"profile email"`

2. **"Admin client scopes"** (name: `admin_oidc_extra_scopes`)
   - Placeholder: `"profile email groups"` (current default minus `openid`)
   - Help text: "Space-separated scope names. `openid` is always included. Example: `profile email groups`"
   - Validation: Same character whitelist + rejection rule
   - Default (pre-filled): `"profile email groups"`

**And** both fields are always editable (no env-locked mode, per ADR-022).

---

### AC3 — Scope Value Sanitization

**Given** an operator enters scope text in the wizard,  
**When** the form is submitted,  
**Then** each scope string is validated to contain **only** characters matching `[a-zA-Z0-9_:.-]` (alphanumeric, underscore, colon, period, dash). Any scope with other characters is rejected with error message: `"Scope '<name>' contains invalid characters. Only alphanumeric, underscore, colon, period, and dash are allowed."` No form submission proceeds until all scopes pass.

(This prevents injection of spaces or special shell characters that could cause issues downstream.)

---

### AC4 — Runtime Scope Resolution — Matrix Client

**Given** `server/lib/nebu/matrix/sso_login.ex` function `scope_list/0`,  
**When** it is called to build the scope string for a login redirect,  
**Then** it:

1. Reads `matrix_oidc_extra_scopes` from `server_config` (via the existing `:matrix_oidc_refresh_mode_reader` seam pattern, or a new `:matrix_oidc_extra_scopes_reader` seam)
2. Always includes `"openid"` (OIDC-mandatory)
3. Appends the extra scopes from server_config (or the hardcoded default `"profile email"` if the DB value is NULL/empty)
4. Adds `"offline_access"` if and only if `matrix_refresh_mode() == "offline"`
5. Returns the space-separated, de-duplicated, filtered string

**Test seam:** Mirror the existing `:matrix_oidc_refresh_mode_reader` pattern — a 0-arity fun under `:matrix_oidc_extra_scopes_reader` injects custom scope string for unit tests; default reads `server_config`.

---

### AC5 — Runtime Scope Resolution — Admin Client

**Given** `server/lib/nebu/admin/auth.ex` function `admin_oidc_scope/0`,  
**When** it is called to build the scope string for the operator login redirect,  
**Then** it:

1. Reads `admin_oidc_extra_scopes` from `server_config` (via a new `:admin_oidc_extra_scopes_reader` seam, mirroring the matrix pattern)
2. Always includes `"openid"` (OIDC-mandatory)
3. Appends the extra scopes from server_config (or the hardcoded default `"profile email groups"` if the DB value is NULL/empty)
4. Adds `"offline_access"` **only** if `admin_refresh_mode() == "offline"`
5. Returns the space-separated, de-duplicated, filtered string

**Critical:** The `groups` scope must be included in the default (`"profile email groups"`) and remain in the operator's requested scopes for the `admin_group_claim` feature to work (AC3 of prior bugfix-oidc-bootstrap-only-e2e-regressions story). Do not silently drop `groups` — if the operator removes it, they must be aware they lose group-based admin claim mapping.

**Test seam:** New `:admin_oidc_extra_scopes_reader` 0-arity fun.

---

### AC6 — Persistence in bootstrap_live.ex

**Given** the Bootstrap Wizard Step 2 save handler (`save_oidc/2`),  
**When** it completes (after issuer, client_id, client_secret, audience, jwks_uri validation),  
**Then** it also validates and stores `matrix_oidc_extra_scopes` and `admin_oidc_extra_scopes`:

1. Read the input values from `params["matrix_oidc_extra_scopes"]` and `params["admin_oidc_extra_scopes"]`
2. Strip whitespace from each
3. **Validate:** For each scope in the space-separated list, ensure it matches `[a-zA-Z0-9_:.-]+` (no other characters). If any scope fails, return error and do not proceed (same error form as AC3)
4. Store the (validated, trimmed) strings in the draft via `put_draft/2`

---

### AC7 — Admin Config-Seite zeigt Scopes

**Given** der Admin öffnet `GET /admin/config` (HTML),  
**When** die Seite gerendert wird,  
**Then** zeigt sie die aktuellen Werte für `matrix_oidc_extra_scopes` und `admin_oidc_extra_scopes` aus `server_config`. Pattern: identisch zur bestehenden Refresh-Mode-Anzeige in `server/lib/nebu/admin/templates/config/index.html.heex`.

---

### AC8 — Admin Config-Seite aktualisiert Scopes post-Bootstrap

**Given** der Admin ist auf `GET /admin/config`,  
**When** er neue Scope-Werte in die Felder eingibt und `POST /admin/config/scopes` absendet,  
**Then** werden die Werte validiert (Zeichenwhitelist wie AC3) und in `server_config` gespeichert. `ConfigController` bekommt einen neuen Action-Handler `save_scopes/2` (analog zu `save_refresh_mode/2`).

---

### AC9 — Runtime Behavior — Scope Injection Works

**Given** bootstrap is complete and `matrix_oidc_extra_scopes = "profile email groups"` in server_config,  
**When** a user triggers OIDC login (Matrix SSO),  
**Then** the scope string sent to the IdP includes `"openid profile email groups"` (plus `offline_access` if offline mode is on).

**And given** `admin_oidc_extra_scopes = "profile email"` (groups intentionally removed),  
**When** the operator logs in to `/admin`,  
**Then** the scope string sent to the IdP includes `"openid profile email"` (no `groups`).

(Consequence: admin login will not receive a `groups` claim, so admin_group_claim-based admin assignment will not work — this is expected and the operator is responsible for correct configuration.)

---

### AC10 — Dev Stack Defaults

**Given** the `docker-compose.yml` and `dex/config.yaml`,  
**When** `make dev` runs,  
**Then** the single `nebu-gateway` client (from oidc-bootstrap-only-config story) has no OIDC scope env vars set (scopes are configured only via the wizard, not via compose env). On fresh bootstrap in dev:

1. Bootstrap wizard Step 2 pre-fills the scope fields with defaults
2. Developer can change them in the wizard
3. After bootstrap, `server_config` holds the chosen scopes
4. `scope_list()` and `admin_oidc_scope()` read from server_config
5. OIDC requests to Dex include the custom scopes

---

### AC11 — ExUnit Unit Tests

**Given** ExUnit tests in `server/test/nebu/matrix/sso_login_test.exs` and `server/test/nebu/admin/auth_test.exs`,  
**When** they run,  
**Then** the following cases pass (written FIRST, before implementation):

#### Matrix SsoLogin Tests

1. **`test_scope_list_with_profile_email_default`** — No extra scopes in server_config; should return `"openin profile email"` (or with offline_access if offline mode)
2. **`test_scope_list_with_custom_scopes`** — `:matrix_oidc_extra_scopes_reader` seam returns `"profile email groups"`; should return `"openid profile email groups"`
3. **`test_scope_list_offline_adds_offline_access`** — With offline mode on and extra scopes `"profile email"`; should return `"openid profile email offline_access"`
4. **`test_scope_list_deduplicates`** — Extra scopes include duplicate `"profile"`; result has no duplicate

#### Admin Auth Tests

5. **`test_admin_oidc_scope_default`** — No extra scopes in server_config; should return `"openid profile email groups"`
6. **`test_admin_oidc_scope_custom`** — `:admin_oidc_extra_scopes_reader` seam returns `"profile email"` (groups removed); should return `"openid profile email"` (note: no groups)
7. **`test_admin_oidc_scope_offline_adds_offline_access`** — With offline mode and extra scopes `"profile email groups"`; should return `"openid offline_access profile email groups"`
8. **`test_admin_oidc_scope_deduplicates`** — Prefixes include `"openid"`; extra scopes also include `"openid"`; result has no duplicate

---

### AC12 — Bootstrap LiveView Tests

**Given** ExUnit LiveView tests in `server/test/nebu/admin/bootstrap_live_test.exs`,  
**When** they run,  
**Then** the following cases pass:

1. **`test_scope_fields_rendered_before_refresh_mode`** — Step 2 form contains `matrix_oidc_extra_scopes` and `admin_oidc_extra_scopes` text inputs, and they appear before the refresh-mode fieldset
2. **`test_default_scopes_prefilled`** — On mount, fields are pre-filled with defaults: Matrix = `"profile email"`, Admin = `"profile email groups"`
3. **`test_scope_validation_accepts_valid_characters`** — Submitting `"profile email custom_scope groups:role"` passes validation
4. **`test_scope_validation_rejects_invalid_characters`** — Submitting `"profile email; DROP TABLE"` returns error without storing
5. **`test_scope_validation_rejects_with_newlines`** — Submitting `"profile\nemail"` returns error
6. **`test_saved_scopes_carried_forward_in_draft`** — After save_oidc, the draft contains the entered scope values; they survive step navigation

---

### AC13 — Integration Test (Godog)

**Given** a Godog scenario in `e2e/features/admin/bootstrap_scopes.feature`,  
**When** `make test-integration` runs,  
**Then** the following scenario passes:

```gherkin
Scenario: Bootstrap wizard sets custom OIDC scopes
  Given the bootstrap wizard is on Step 2
  When the operator enters Matrix scopes "profile email groups"
  And enters Admin scopes "profile email custom_admin_role"
  And clicks "Connect with OIDC"
  Then the draft is updated with the custom scopes
  And the OIDC login redirect includes scope "profile email groups"
  And the admin login includes scope "profile email custom_admin_role"
```

(Full browser E2E is not required; the smoke test in AC9 by the operator is sufficient. Godog validates the wizard form and draft persistence.)

---

### AC14 — Security Review Scope

**Classification:** `security_review: required`

**Scope:** Scope strings are operator-provided values that are sent to the IdP in the authorization request. Injection vectors:

1. **Scope injection via `params["matrix_oidc_extra_scopes"]`** — An attacker cannot control form params in the browser (CSRF token + form submission). But ensure the server-side validation (character whitelist) is enforced before any use of the value.
2. **SSRF via scope injection** — Scope names are not URLs; they do not cause HTTP requests.
3. **Replay via cached scopes** — Scopes are read from `server_config` on each request; no caching of the scope list itself (only the JWKS keys are cached). Risk: low.
4. **Scope elevation** — The operator chooses the scopes; they can only request what the IdP allows. No elevation risk.

**Reviewer focus:**
- Validate that the character whitelist (`[a-zA-Z0-9_:.-]`) is applied consistently in wizard form save and PATCH endpoint.
- Confirm scope strings from server_config are never logged or exposed in error messages in a way that could leak OIDC metadata.
- Verify the default scopes (especially `groups` for admin) are not silently dropped.

---

## Implementation Map

### Files to Modify

1. **`server/priv/migrations/000013_config_oidc_scopes_mutable.up.sql`** + `.down.sql` (neu)
   - `config_update_mutable` RLS-Policy um `'matrix_oidc_extra_scopes'` und `'admin_oidc_extra_scopes'` erweitern
   - Pattern: identisch zu `000007_config_refresh_mode_mutable.up.sql`
   - Kein Schema-Change: server_config ist Key-Value, neue Werte = neue Zeilen

2. **`server/lib/nebu/matrix/sso_login.ex`**
   - Remove `@base_scopes` constant
   - Update `scope_list/0` to read extra scopes from server_config via `:matrix_oidc_extra_scopes_reader` seam
   - Merge hardcoded `"openid"` + extra scopes + conditional `"offline_access"`

3. **`server/lib/nebu/admin/auth.ex`**
   - Update `admin_oidc_scope/0` to read extra scopes from server_config via `:admin_oidc_extra_scopes_reader` seam
   - Merge hardcoded `"openid"` + extra scopes + conditional `"offline_access"`
   - Keep `groups` in the default

4. **`server/lib/nebu/admin/bootstrap_live.ex`**
   - Add `@scope_defaults` map (Matrix = `"profile email"`, Admin = `"profile email groups"`)
   - Update template to render two new text input fields before the refresh-mode fieldset
   - Update `save_oidc/2` to validate and store scope values (character whitelist: `[a-zA-Z0-9_:.-]`)
   - Update `save_claim_mapping/1` to persist scope defaults (analog to refresh-mode defaults at line 179)
   - Update HTML form to include the new fields

5. **`server/lib/nebu/admin/config_controller.ex`**
   - Neuer Handler `save_scopes/2` (analog zu `save_refresh_mode/2`) für `POST /admin/config/scopes`
   - Scope-Werte aus params validieren (Zeichenwhitelist) und via `Nebu.Admin.DB.upsert_server_config/1` persistieren
   - `@scope_keys` für die erlaubten Keys: `["matrix_oidc_extra_scopes", "admin_oidc_extra_scopes"]`

6. **`server/lib/nebu/admin/templates/config/index.html.heex`**
   - Neues Scope-Formular hinzufügen (analog zum Refresh-Mode-Formular), action `POST /admin/config/scopes`

7. **`server/config/runtime.exs`**
   - (Keine Änderungen nötig — Scopes sind nicht env-konfiguriert)

6. **Tests:**
   - `server/test/nebu/matrix/sso_login_test.exs` — 4 new tests (AC11)
   - `server/test/nebu/admin/auth_test.exs` — 4 new tests (AC11)
   - `server/test/nebu/admin/bootstrap_live_test.exs` — 6 new tests (AC12)
   - `e2e/features/admin/bootstrap_scopes.feature` — 1 Godog scenario (AC13)

---

## Previous Story Context (Learnings from oidc-bootstrap-only-config)

The **oidc-bootstrap-only-config** story (merged 2026-06-28) removed all `NEBU_OIDC_*` env vars and established the bootstrap-only pattern. Key learnings:

1. **Seams matter:** The `:matrix_oidc_refresh_mode_reader` and `:admin_oidc_refresh_mode_reader` patterns (0-arity funs for dependency injection in tests) work well. Mirror this for scope reading.
2. **Fail-closed is critical:** When server_config has no OIDC config, the server must reject all OIDC operations (401 M_UNKNOWN_TOKEN). This story follows the same fail-closed pattern — if scopes are nil, use defaults.
3. **Admin `groups` scope is not optional:** AC3 of the prior story required `groups` scope for admin claim mapping. Keep it in the default; document that removing it breaks admin_group_claim feature.
4. **Draft → server_config persistence:** The wizard draft is the staging area; `complete_bootstrap/1` promotes the draft to server_config. Scope values follow the same path.

---

## Git Intelligence (Recent Commits)

From the most recent commits:

- **e7b9177e** (feat: pipeline): native subagents, Install-Infrastruktur — pipeline/infrastructure work
- **bfe41cde** (Merge: bugfix/bootstrap-post-form into main) — bootstrap form improvements
- **762077e2** (Fix bootstrap) — bootstrap-related fix
- **5ad11106** (Merge: feature/device-management into main) — device management
- **2c4c8976** (Device Management) — device management feature

**Pattern observed:** Bootstrap wizard has been a focus; form handling and validation patterns are in place. This story extends existing form patterns with new fields and validation.

---

## Testing Strategy (ATDD First)

### Test Artifacts (write these FIRST, before implementation)

1. **`server/test/nebu/matrix/sso_login_test.exs`** — 4 ExUnit tests
   - Test matrix scope list with/without custom scopes
   - Test offline_access conditional inclusion
   - Test deduplication

2. **`server/test/nebu/admin/auth_test.exs`** — 4 ExUnit tests
   - Test admin scope list with/without custom scopes
   - Test offline_access conditional inclusion
   - Test deduplication
   - **Critical:** Verify `groups` is always in the default

3. **`server/test/nebu/admin/bootstrap_live_test.exs`** — 6 LiveView tests
   - Test form field rendering and order (before refresh-mode)
   - Test default pre-fill
   - Test validation (character whitelist)
   - Test error messages for invalid characters

4. **`gateway/features/bootstrap_scopes.feature`** — 1 Godog scenario
   - End-to-end bootstrap with custom scopes
   - Verify scope string reaches the OIDC authorization request

### Test Execution Order

1. **Run tests RED** — Verify they fail before implementation
2. **Implement code** — Make tests green
3. **Regression check** — Ensure existing tests (refresh-mode, default claim mapping) still pass
4. **Security review** — Character whitelist validation is applied consistently

---

## Scope Defaults Decision

**Matrix:** `"profile email"` (current hardcoded, minus `openid`)  
**Admin:** `"profile email groups"` (current hardcoded, minus `openid`)

The `groups` scope is **not optional** for admin. If the operator removes it, `admin_group_claim`-based admin assignment stops working. This is by design (operator control) but must be documented.

---

## Security Considerations

1. **Scope injection vector:** Scopes are operator-provided and sent to the IdP. Character whitelist (`[a-zA-Z0-9_:.-]`) prevents shell injection or multi-line injection.
2. **Scope elevation:** The IdP grants scopes; the server cannot request scopes the IdP does not recognize. No elevation risk.
3. **Logging:** Scope values must not appear in debug logs or error messages that could expose OIDC metadata.
4. **Backward compatibility:** Nil/empty scope values in `server_config` fall back to hardcoded defaults; existing deployments continue to work.

---

## Definition of Done

- [x] Migration file created and validates
- [x] `scope_list/0` reads from server_config with seam
- [x] `admin_oidc_scope/0` reads from server_config with seam
- [x] Bootstrap wizard renders two new scope input fields (before refresh-mode)
- [x] Scope validation (character whitelist) applied consistently
- [x] Default values pre-fill in wizard
- [x] Draft persistence for scope values
- [x] Admin config API includes scope fields (GET + POST)
- [x] Unit tests written first and passing
- [ ] Integration test scenario passing (out of scope for unit-test run)
- [ ] Security review completed (Kassandra)
- [ ] Arc42 documentation updated (if needed)
- [x] This story file is comprehensive and developer-ready

---

## Implementation Notes (Non-Binding)

### Scope Validation Function

Create a helper function (e.g., `validate_scopes/1`) that:
1. Takes a space-separated string
2. Returns `:ok` or `{:error, message}` if any scope contains invalid characters
3. Used in both `save_oidc/2` (wizard) and the PATCH endpoint

```elixir
defp validate_scopes(scope_string) do
  scope_string
  |> String.split(" ", trim: true)
  |> Enum.find_index(&(!String.match?(&1, ~r/^[a-zA-Z0-9_:.-]+$/)))
  |> case do
    nil -> :ok
    idx -> {:error, "Scope '#{Enum.at(String.split(scope_string), idx)}' contains invalid characters..."}
  end
end
```

### Seam Pattern (Test Injection)

```elixir
# In sso_login.ex
defp get_extra_scopes do
  case Application.get_env(:nebu, :matrix_oidc_extra_scopes_reader) do
    fun when is_function(fun, 0) -> fun.()
    nil -> read_extra_scopes_from_db()
  end
end

# In tests
setup do
  Application.put_env(:nebu, :matrix_oidc_extra_scopes_reader, fn -> "profile email groups" end)
  on_exit(fn -> Application.delete_env(:nebu, :matrix_oidc_extra_scopes_reader) end)
  :ok
end
```

### UI Validation Feedback

In the form, display validation errors inline (DaisyUI `error` class on label/input) when invalid characters are detected. This prevents submission without feedback.

---

## Dev Agent Record

### Completion Notes

Implemented all unit-testable ACs (AC1–AC8, AC11, AC12). 1009/1009 unit tests pass, 0 failures, no compiler warnings.

Key implementation decisions:
- Mirrored `:matrix_oidc_refresh_mode_reader` seam pattern exactly for both `:matrix_oidc_extra_scopes_reader` and `:admin_oidc_extra_scopes_reader`.
- `do_complete_bootstrap/2` promotes scope keys only when all tokens pass the `[a-zA-Z0-9_:.-]` whitelist; invalid values are silently skipped (security-guard pattern from refresh modes).
- `ConfigController.load_config/0` checks `:admin_server_config_reader` seam before the Repo path (test-review F1).
- `ConfigController.save_scopes/2` returns 200 re-render (not 422) on invalid input (test-review F2/F3).
- `release_test.exs` updated to expect 13 migrations (was 12).

### File List

- `server/priv/migrations/000013_config_oidc_scopes_mutable.up.sql` (new)
- `server/priv/migrations/000013_config_oidc_scopes_mutable.down.sql` (new)
- `server/lib/nebu/matrix/sso_login.ex` (modified)
- `server/lib/nebu/admin/auth.ex` (modified)
- `server/lib/nebu/admin/bootstrap_controller.ex` (modified)
- `server/lib/nebu/admin/templates/bootstrap/index.html.heex` (modified)
- `server/lib/nebu/admin/config_controller.ex` (modified)
- `server/lib/nebu/admin/config_html.ex` (modified)
- `server/lib/nebu/admin/templates/config/index.html.heex` (modified)
- `server/lib/nebu/admin/router.ex` (modified)
- `server/test/nebu/release_test.exs` (modified — migration count 12→13)

---

### Review Findings

- [ ] [Review][Patch] Regex `*` → `+` in `save_scopes/2` validation [server/lib/nebu/admin/config_controller.ex:68]
- [ ] [Review][Patch] `save_scopes/2` persistiert `""` statt Default — "Scopes saved" Flash ist irreführend [server/lib/nebu/admin/config_controller.ex:72-76]
- [ ] [Review][Patch] `do_complete_bootstrap` dropped scope silently ohne `Logger.warning` [server/lib/nebu/admin/auth.ex:1403-1404]
- [x] [Review][Defer] Two DB queries per scope read per login — pre-existing performance concern [server/lib/nebu/admin/auth.ex] — deferred, pre-existing
- [x] [Review][Defer] Wizard pre-fill `||` operator doesn't handle empty string from DB — low-priority UX edge [server/lib/nebu/admin/templates/bootstrap/index.html.heex] — deferred, low-impact

---

## Status

**Current Status:** in-progress
**Last Updated:** 2026-06-30
**Epic:** oidc-bootstrap-only
**Branch:** bugfix/scopes-and-better-pipeline
