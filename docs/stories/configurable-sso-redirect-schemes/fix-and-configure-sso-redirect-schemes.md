---
story_id: fix-and-configure-sso-redirect-schemes
title: Bugfix + Feature — SSO Redirect Scheme Allowlist Fix and Runtime Configuration
type: bugfix-and-feature
severity: high
epic: configurable-sso-redirect-schemes
status: done
security_review: required
ui: true
created: 2026-07-03
---

## Summary

This story combines a **bugfix** and a **feature** into one coherent change to the SSO redirect-URL allowlist subsystem in `Nebu.Matrix.SsoLogin.redirect_url_allowed?/1`. They are inseparable: the bugfix corrects hardcoded client schemes, and the feature makes the allowlist runtime-configurable so the operator can add trusted schemes without code changes or redeploy.

**Bugfix:** The hardcoded `@default_deep_link_schemes` list contains TWO inaccurate entries:
- `"io.element.fluffychat"` — does not exist (FluffyChat's real scheme is `"im.fluffychat.auth"`)
- `"fluffychat"` — does not exist (SchildiChat uses `"schildichat"`)

These are removed, and the correct schemes are added: `"im.fluffychat.auth"` (FluffyChat) and `"schildichat"` (SchildiChat).

**Feature:** The operator can now manage **additional** trusted SSO redirect schemes via the Admin UI (`/admin/config`), stored in `server_config` and read via a cluster-aware cache (mirroring the OIDC config pattern). The environment variable `NEBU_SSO_REDIRECT_SCHEMES` is removed; all configuration is bootstrap-only, consistent with ADR-022.

---

## Motivation

### Bugfix Rationale

The current hardcoded list was derived from Go upstream but contains scheme names that don't match any real Matrix client's registered URI schemes. This means:
- FluffyChat users cannot SSO-login because `io.element.fluffychat` is not registered with their OS and does not match the client's real scheme `im.fluffychat.auth`.
- SchildiChat users cannot SSO-login similarly.
- The allowlist is silently ineffective for these real clients, creating a false sense of allowed-scheme coverage.

### Feature Rationale

Different deployments may have custom Matrix clients or intermediary services with bespoke URI schemes (e.g., `myorg-matrix://`). The operator needs the ability to allowlist these without:
1. Code changes
2. Redeploy
3. Knowledge of Elixir/Erlang

The bootstrap-only pattern (ADR-022) is the operator-control interface; sso_redirect_schemes follow the same pattern as OIDC scopes: admin-editable, server_config-backed, cache-invalidated on write.

---

## Non-Goals

1. **Do NOT switch to pattern/wildcard/heuristic scheme matching.** Exact-string allowlist membership only (RFC 8252 §8.6 scheme-squatting risk — defend against this).
2. **Do NOT touch `callback_url/1`** or any upstream-IdP-facing redirect_uri logic. That is a fully separate, independent redirect leg.
3. **No migration/compatibility shim for env var removal.** This is pre-1.0 software (ADR-018: no unnecessary abstraction). Just remove `NEBU_SSO_REDIRECT_SCHEMES` and document the breaking change.
4. **Follow ADR-018 (no domain model, raw SQL inline) and ADR-021 (pure Elixir)** — no new dependencies.
5. **No new ADR is required.** The upstream IdP relationship is untouched; this is a client-facing redirect URL validation gate only.

---

## Acceptance Criteria

### AC1 — Bugfix: Correct Hardcoded Deep-Link Schemes

**Given** `server/lib/nebu/matrix/sso_login.ex:57` — the `@default_deep_link_schemes` constant,  
**When** it is evaluated at module load,  
**Then** it contains exactly:
- `"element"` (Element, unchanged)
- `"schildichat"` (SchildiChat, replaces fake `"io.element.fluffychat"`)
- `"im.fluffychat.auth"` (FluffyChat, replaces fake `"fluffychat"`)

**Regression tests** (extended from story 5-24):
1. **`test_redirect_allows_im_fluffychat_auth_scheme`** — `"im.fluffychat.auth://open?loginToken=abc"` is allowed
2. **`test_redirect_allows_schildichat_scheme`** — `"schildichat://open?loginToken=xyz"` is allowed
3. **`test_redirect_rejects_old_io_element_fluffychat_scheme`** — `"io.element.fluffychat://..."` is rejected (no longer in allowlist)
4. **`test_redirect_rejects_old_fluffychat_bare_scheme`** — `"fluffychat://..."` is rejected (no longer in allowlist)

---

### AC2 — Denylist Remains Unchanged

**Given** `@scheme_denylist` at line 54 of `sso_login.ex`,  
**When** `redirect_url_allowed?/1` evaluates a URL,  
**Then** schemes in the denylist (`javascript`, `data`, `file`, `vbscript`, `blob`) are ALWAYS rejected, even if an operator accidentally allowlists them via server_config.

**Existing tests** (from story 5-24, preserved):
- All existing denylist tests pass unchanged
- Denylist wins over any custom allowlist entry

---

### AC3 — Environment Variable Removal

**Given** `server/config/runtime.exs:41` — `sso_redirect_schemes: System.get_env("NEBU_SSO_REDIRECT_SCHEMES", "")`,  
**When** a grep is performed on the entire codebase:
```bash
grep -r "NEBU_SSO_REDIRECT_SCHEMES" /path/to/server
```

**Then** the only matches are in:
1. `.deprecated/` or history docs (not executed code)
2. This story's documentation (reference only)

**Before the implementation removes it**, a developer must verify:
- Not referenced in `docker-compose.yml`, `Dockerfile`, or other deploy config
- Not referenced in e2e feature files (`.feature` files)
- Not referenced elsewhere in the codebase with a full grep

**After removal:**
- Add a `CHANGELOG.md` entry under `### Removed` or `### Changed` with the breaking-change note:
  - **SSO Redirect Schemes — no longer via env var**: `NEBU_SSO_REDIRECT_SCHEMES` has been removed. Configure additional trusted SSO redirect schemes via the Admin UI at `/admin/config` after bootstrap. The hardcoded default now correctly lists `element`, `schildichat`, and `im.fluffychat.auth`.

---

### AC4 — Runtime Configuration Storage

**Given** a new database key `sso_extra_redirect_schemes` in `server_config` (no migration needed — Key-Value store),  
**When** the operator enters a comma-separated list of scheme names via the Admin UI,  
**Then** the value is stored as a single TEXT string (e.g., `"myorg-matrix, custom-app"`) — comma-separated, not space-separated (schemes do NOT contain spaces; comma is the natural separator).

**Storage format:**
- Empty/NULL in DB → operator has not set custom schemes → only defaults are allowed
- Non-empty string → operator-provided custom schemes (space-trimmed, deduplicated by UI validation, never blank tokens)

---

### AC5 — Admin UI Input Validation

**Given** an operator submits a custom scheme string at `/admin/config` (new form field or update to existing),  
**When** the form is submitted,  
**Then** each scheme token is validated to:

1. **Syntax (RFC 3986 scheme token):** Must be `[A-Za-z][A-Za-z0-9+.-]*` (starts with a letter, followed by zero or more alphanumeric/plus/dash/dot). Reject any token that violates this with error message: `"Scheme '<token>' is not a valid RFC 3986 scheme. Must start with a letter and contain only alphanumeric, plus, dash, or dot characters."`

2. **Denylist check (case-insensitive):** The hardcoded denylist (`javascript`, `data`, `file`, `vbscript`, `blob`) cannot be allowlisted. If an operator submits one, reject with error: `"Scheme '<token>' is blocked. Cannot allow javascript, data, file, vbscript, or blob."`

3. **Empty tokens:** Any blank/whitespace-only token in the list is rejected with error: `"Found an empty scheme. All schemes must be non-empty and valid."`

**Validation happens server-side** (before any DB write) in the ConfigController handler, mirroring the existing scope-validation pattern. An operator must not be able to accidentally or be tricked into allowlisting a dangerous scheme.

---

### AC6 — Cache Pattern: Exact Mirror of OIDC Config

**Given** the sso_extra_redirect_schemes value needs to be read on every `redirect_url_allowed?/1` call,  
**When** a request flows through `Nebu.Matrix.SsoLogin.redirect_url_allowed?/1`,  
**Then** the extra schemes are fetched from a CACHE (NOT a live DB query per request), following the EXACT same pattern as `Nebu.Web.OidcConfig`:

1. **ETS table**: Reuse or extend the existing `:nebu_http_oidc_config` table (or create a separate `:nebu_http_sso_schemes` if separation is clearer). Store the sso_extra_redirect_schemes string.

2. **GenServer refresh**: The same `Nebu.Web.OidcConfig` GenServer that reads issuer/audience/jwks_uri ALSO reads `sso_extra_redirect_schemes` on each `refresh/0` call and updates the ETS entry. (Alternative: create a separate `Nebu.Web.SsoSchemesConfig` GenServer that mirrors the pattern exactly.)

3. **Cluster invalidation**: When `Nebu.Admin.DB.upsert_server_config/1` writes a change that touches `sso_extra_redirect_schemes`, it calls the cache's `refresh/0` method, which broadcasts invalidation via `:pg` to peer nodes (ADR-020, M-3). No per-request DB call; changes take effect immediately cluster-wide.

4. **Extension to `@scope_cache_keys`**: Add `"sso_extra_redirect_schemes"` to the `@scope_cache_keys` list in `Nebu.Admin.DB` (line 24-27) so the conditional refresh at line 756-758 picks it up automatically. Developer's choice: extend the existing list or create a separate `@sso_cache_keys` list — either is acceptable; state the choice clearly in implementation notes.

**Developer decision point:** Reuse `OidcConfig`'s table/GenServer or create a new `SsoSchemesConfig`? The rubric: if the extra schemes are closely coupled to OIDC (e.g., both are "client-facing SSO config"), reuse. If they're conceptually separate, create a new module. **Recommendation:** reuse — they're both SSO-path reads on the hot request path, both bootstrap-only, both infrequently changed. Keep them together in the ETS cache. If future stories separate them, that's a refactor.

---

### AC7 — extra_redirect_schemes/0 Function Update

**Given** `server/lib/nebu/matrix/sso_login.ex:319-325` — the `extra_redirect_schemes/0` function currently reads from `Application.get_env(:nebu_http, :sso_redirect_schemes)`,  
**When** it is called after the cache is wired,  
**Then** it:

1. Checks if `:nebu_http, :sso_redirect_schemes_reader` seam is set (0-arity fun for unit tests) — if yes, call it; if no, proceed to cache read.
2. Reads the sso_extra_redirect_schemes value from the cache (not an env var).
3. Parses the comma-separated string (trim whitespace around each token, split on `,`, deduplicate).
4. Returns a list of downcase'd scheme strings.

**Implementation:**
```elixir
defp extra_redirect_schemes do
  case Application.get_env(:nebu_http, :sso_redirect_schemes_reader) do
    fun when is_function(fun, 0) ->
      fun.()  # Test seam returns [downcase'd schemes] or []

    _ ->
      case cache_extra_redirect_schemes() do  # Reads from ETS cache
        str when is_binary(str) and str != "" ->
          str
          |> String.split(",", trim: true)
          |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
          |> Enum.uniq()

        _ ->
          []
      end
  end
end
```

(Exact implementation depends on cache choice; this is the shape.)

---

### AC8 — Admin UI Form Field

**Given** the Admin UI at `GET /admin/config`,  
**When** it renders,  
**Then** a new form field appears in a dedicated section (before or after the scopes form, up to developer preference, but CLEARLY labeled):

**Form field ("SSO Redirect Schemes"):**
- Label: `"Additional SSO redirect schemes"`
- Input: Text input (single line, accept comma-separated list)
- Name: `"sso_extra_redirect_schemes"`
- Placeholder: `"myorg-matrix, custom-app"`
- Help text: `"Comma-separated scheme names (case-insensitive, alphanumeric + dash/dot/plus only). Examples: element, schildichat, im.fluffychat.auth, myorg-matrix. Hardcoded denylist (javascript, data, file, vbscript, blob) cannot be overridden."`
- Value: Current value from config or empty string
- Button: `"Save SSO schemes"` (or reuse button from scopes form if both are in the same form — design choice)

**UI Pattern:** Mirror the existing `oidc-scopes-form` pattern in `/admin/config` (lines 10-45 of `index.html.heex`) — same form markup, same validation/error display style, same "Save" button.

---

### AC9 — Admin Config Controller Handler

**Given** `POST /admin/config/sso-schemes` (or same form as AC8 if combined),  
**When** an operator submits the form with a comma-separated scheme string,  
**Then** `Nebu.Admin.ConfigController`:

1. **Validates** each scheme token via a helper (see AC5 rules: RFC 3986 syntax + denylist check).
2. **Rejects invalid input** with error message displayed to the user; re-renders the config page (HTTP 200, no DB write).
3. **On success**, trims whitespace, deduplicates (optional — validation should have prevented dupes), and upserts to `server_config` via `Nebu.Admin.DB.upsert_server_config(%{"sso_extra_redirect_schemes" => trimmed_string})`.
4. **Flash message**: `"SSO schemes saved"` on success, `"Failed to save SSO schemes"` on error.

**Code pattern** (mirrors `save_scopes/2` at line 59-99):
```elixir
def save_sso_schemes(conn, params) do
  value = params["sso_extra_redirect_schemes"] || ""
  case validate_sso_schemes(value) do
    :ok ->
      changes = %{"sso_extra_redirect_schemes" => String.trim(value)}
      case persist_sso_schemes(changes) do
        :ok -> conn |> put_flash(:info, "SSO schemes saved") |> redirect(to: "/admin/config")
        _ -> conn |> put_flash(:error, "Failed to save SSO schemes") |> redirect(to: "/admin/config")
      end
    {:error, msg} ->
      conn |> put_status(200) |> put_flash(:error, msg) |> render_config()
  end
end

defp validate_sso_schemes(str) do
  # AC5 logic: each token must match RFC 3986, not in denylist, non-empty
  str
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.find(&invalid_scheme?/1)
  |> case do
    nil -> :ok
    invalid_token -> {:error, "Scheme '#{invalid_token}' is invalid..."}
  end
end
```

---

### AC10 — Regression: callback_url/1 Untouched & Independent

**Given** `Nebu.Matrix.SsoLogin.callback_url/1` (lines 536-550) — the redirect_uri registered with the upstream IdP,  
**When** the story implementation is complete,  
**Then** `callback_url/1` is:

1. **Explicitly unchanged** (no code changes to this function).
2. **Confirmed independent** by an explicit test or code comment asserting the two redirect legs never couple:
   - Client-facing leg: `redirect_url_allowed?/1` validates the client's requested `redirectUrl` parameter against the allowlist.
   - IdP-facing leg: `callback_url/1` computes Nebu's own fixed callback URI (scheme + host from request) and registers it with the IdP.
   - These two legs use completely different inputs (one from user params, one from request headers) and feed different flows (client redirect vs. IdP callback). They MUST remain independent.

**Test (write FIRST):** A regression test in `sso_login_test.exs`:
```elixir
test "callback_url is independent from client redirectUrl validation" do
  # callback_url MUST NOT be affected by allowlist changes
  conn = conn(:get, "/_matrix/client/v3/login/sso/redirect/oidc")
         |> put_req_header("host", "example.com")
  url = SsoLogin.callback_url(conn)
  assert String.starts_with?(url, "https://example.com/") or String.starts_with?(url, "http://example.com/")
  
  # Even if allowlist blocks all schemes, callback_url still returns Nebu's own URL
  # (not exercising redirect_url_allowed? at all)
  assert url == "https://example.com/_matrix/client/v3/login/sso/redirect/oidc"
end
```

---

### AC11 — Dev Stack Defaults

**Given** `docker-compose.yml` and `dex/config.yaml` in dev setup,  
**When** `make dev` runs with a fresh bootstrap,  
**Then**:

1. No `NEBU_SSO_REDIRECT_SCHEMES` env var is set (it is removed entirely).
2. The single `nebu-gateway` client in bootstrap has no sso_redirect_schemes env config.
3. On fresh bootstrap in dev:
   - Bootstrap wizard Step 2 is complete (OIDC issuer/client set).
   - Admin navigates to `/admin/config` post-bootstrap.
   - The SSO schemes form shows only defaults (element, schildichat, im.fluffychat.auth).
   - Developer can edit the field to add custom schemes (e.g., `"mytest-scheme"`).
   - Save persists to `server_config`.
   - Next SSO login request uses the custom allowlist.

---

### AC12 — ExUnit Unit Tests

**Given** ExUnit tests in `server/test/nebu/matrix/sso_login_test.exs`,  
**When** they run,  
**Then** the following cases pass (write FIRST, before implementation):

#### AC12.1 — Bugfix Regression Tests

1. **`test_redirect_url_allowed_im_fluffychat_auth`** — `"im.fluffychat.auth://open?loginToken=abc"` → **allowed** (new real scheme)
2. **`test_redirect_url_allowed_schildichat`** — `"schildichat://open?loginToken=xyz"` → **allowed** (new real scheme)
3. **`test_redirect_url_not_allowed_io_element_fluffychat`** — `"io.element.fluffychat://..."` → **rejected** (fake scheme, removed)
4. **`test_redirect_url_not_allowed_bare_fluffychat`** — `"fluffychat://..."` → **rejected** (fake scheme, removed)
5. **`test_redirect_url_allowed_element`** — `"element://..."` → **allowed** (unchanged default)

#### AC12.2 — Feature Tests (Cache + Extra Schemes)

6. **`test_extra_redirect_schemes_empty_when_not_set`** — Cache returns `[]` when `sso_extra_redirect_schemes` is not in server_config
7. **`test_extra_redirect_schemes_from_cache`** — When `:sso_redirect_schemes_reader` seam returns `["myorg-matrix"]`, `extra_redirect_schemes/0` returns downcase'd list `["myorg-matrix"]`
8. **`test_extra_redirect_schemes_case_insensitive`** — When seam returns `"MyOrg-Matrix, Custom-App"`, the list is deduplicated and downcase'd: `["myorg-matrix", "custom-app"]`
9. **`test_redirect_url_allowed_custom_scheme_from_cache`** — When seam provides `["myorg-matrix"]`, URL `"myorg-matrix://login?token=x"` is allowed
10. **`test_redirect_url_rejected_custom_scheme_not_in_cache`** — URL with unknown scheme `"unknown-scheme://..."` is rejected

#### AC12.3 — Denylist (Existing, Preserved)

11. **`test_redirect_url_denied_javascript`** — `"javascript:alert(1)"` → **rejected** (denylist)
12. **`test_redirect_url_denied_data`** — `"data:text/html,..."` → **rejected** (denylist)
13. **`test_redirect_url_denied_file`** — `"file:///etc/passwd"` → **rejected** (denylist)
14. **`test_redirect_url_denied_vbscript`** — `"vbscript:..."` → **rejected** (denylist)
15. **`test_redirect_url_denied_blob`** — `"blob:..."` → **rejected** (denylist)

#### AC12.4 — Denylist Wins Over Custom Allowlist

16. **`test_redirect_url_denied_javascript_even_if_custom_allows_it`** — Even if operator allowlists `"javascript"`, the URL `"javascript:..."` is **rejected** (denylist wins)

---

### AC13 — Integration Test (Godog)

**Given** a Godog scenario in `e2e/features/admin/sso_schemes.feature`,  
**When** `make test-integration` runs,  
**Then** the following scenario passes:

```gherkin
Scenario: Admin configures custom SSO redirect schemes
  Given the bootstrap wizard is complete
  And the admin is on the configuration page
  When the admin enters "myorg-matrix, custom-app" in the "Additional SSO redirect schemes" field
  And clicks "Save SSO schemes"
  Then a success message appears: "SSO schemes saved"
  And the configuration table shows sso_extra_redirect_schemes with value "myorg-matrix, custom-app"

Scenario: Admin cannot allowlist a blocked scheme
  Given the bootstrap wizard is complete
  And the admin is on the configuration page
  When the admin enters "javascript" in the "Additional SSO redirect schemes" field
  And clicks "Save SSO schemes"
  Then an error message appears: "Scheme 'javascript' is blocked..."
  And the value is not saved to the database
```

---

### AC14 — Security Review Scope

**Classification:** `security_review: required`

**Scope:** The allowlist is a critical open-redirect-protection gate. Any flaw directly impacts client security.

**Reviewer checklist:**

1. **Exact-string matching only:** Confirm the allowlist uses strict `scheme in list` equality (no pattern/wildcard/heuristic matching). RFC 8252 §8.6 scheme-squatting mitigation depends on this.

2. **Denylist enforcement:** Verify that the hardcoded denylist (javascript, data, file, vbscript, blob) is applied AFTER the custom allowlist check (denylist wins). Test that an operator cannot override it.

3. **Input validation:** Confirm server-side validation of scheme tokens:
   - RFC 3986 syntax (letter start, alphanumeric + dash/dot/plus)
   - Non-empty tokens only
   - Denylist check at form-submission time

4. **Cache invalidation:** Verify that a write via `upsert_server_config/1` invalidates the cache/ETS and triggers `:pg` broadcast so the new allowlist is visible on the NEXT request (no staleness window).

5. **Two redirect legs independence:** Confirm `callback_url/1` (IdP-facing) is completely separate from `redirect_url_allowed?/1` (client-facing). They must never couple.

6. **Logging:** Ensure rejected redirects log a warning (existing behavior, line 75) WITHOUT echoing the scheme/URL (no reflected-XSS / info leak). Confirm no other logs expose the allowlist or scheme values.

---

## Implementation Map

### Files to Modify

1. **`server/lib/nebu/matrix/sso_login.ex`** (AC1, AC7)
   - Update `@default_deep_link_schemes` at line 57: replace `["element", "io.element.fluffychat", "fluffychat"]` with `["element", "schildichat", "im.fluffychat.auth"]`
   - Update `extra_redirect_schemes/0` (lines 319-325) to:
     - Check `:sso_redirect_schemes_reader` seam (0-arity fun for tests)
     - Read from cache (not env var)
     - Parse comma-separated list, trim, deduplicate, downcase

2. **`server/lib/nebu/web/oidc_config.ex`** OR new `server/lib/nebu/web/sso_schemes_config.ex`** (AC6)
   - **Choice:** Extend `OidcConfig` to include `sso_extra_redirect_schemes` in the ETS table + `load_from_db/0` SQL query, OR create a parallel `SsoSchemesConfig` GenServer.
   - If extending: Add `sso_extra_redirect_schemes` to `@empty_config` map, add to SQL query, add to `load_from_db/0`, add getter function `get_sso_schemes/0`.
   - If new module: Mirror `OidcConfig` exactly (ETS, GenServer, `:pg` broadcast, same refresh pattern).
   - **Developer decision point:** State clearly in implementation notes which approach was chosen and why.

3. **`server/lib/nebu/admin/config_controller.ex`** (AC9, AC5)
   - Add `@sso_scheme_keys ["sso_extra_redirect_schemes"]` constant (or extend existing lists)
   - New handler `save_sso_schemes/2` (mirrors `save_scopes/2`):
     - Validate via `validate_sso_schemes/1` helper
     - On error: return HTTP 200 + re-render + flash error
     - On success: call `persist_sso_schemes/1` + redirect + flash success
   - New helper `validate_sso_schemes/1`:
     - Split on comma, trim whitespace
     - Check each token: RFC 3986 syntax (letter start, alphanumeric + dash/dot/plus)
     - Check each token: not in denylist (javascript, data, file, vbscript, blob) — case-insensitive
     - Return `:ok` or `{:error, message}`
   - New helper `persist_sso_schemes/1` (test seam + DB path, mirrors `persist_scopes/1`)

4. **`server/lib/nebu/admin/config_html.ex`** (AC8 UI helpers)
   - New helper `sso_schemes_value(config, key)` (mirrors `scope_value/2`) — returns config value or ""
   - May need to normalize denylist constant if extending from multiple modules

5. **`server/lib/nebu/admin/templates/config/index.html.heex`** (AC8 UI form)
   - New form section (before or after scopes form) with:
     - Label "Additional SSO redirect schemes"
     - Text input name `"sso_extra_redirect_schemes"`
     - Placeholder "myorg-matrix, custom-app"
     - Help text with examples and denylist warning
     - Button "Save SSO schemes"
     - Mirrors `oidc-scopes-form` markup (lines 10-45)

6. **`server/lib/nebu/admin/db.ex`** (AC6 cache invalidation)
   - Add `"sso_extra_redirect_schemes"` to `@scope_cache_keys` list (line 24-27), OR create separate `@sso_cache_keys` list
   - The conditional at line 756-758 automatically picks it up (no code change needed if added to existing list)

7. **`server/lib/nebu/admin/router.ex`**
   - Add route `post "/config/sso-schemes", ConfigController, :save_sso_schemes` (if new route)
   - OR update existing route if combining with another form

8. **`server/config/runtime.exs`** (AC3 — removal)
   - Remove line 41: `sso_redirect_schemes: System.get_env("NEBU_SSO_REDIRECT_SCHEMES", ""),`
   - Pre-removal: grep entire codebase to confirm no other references
   - Document in CHANGELOG.md under `### Removed` or `### Changed`

9. **`CHANGELOG.md`** (AC3 — breaking change note)
   - Add entry under `### Removed` (or `### Changed` if preferred):
   ```
   - **SSO Redirect Schemes — bootstrap-only config**: `NEBU_SSO_REDIRECT_SCHEMES` environment variable has been removed. All SSO redirect scheme configuration is now bootstrap-only: configure additional trusted schemes via the Admin UI at `/admin/config` after bootstrap. The hardcoded default now correctly lists `element`, `schildichat`, and `im.fluffychat.auth` (previously included inaccurate scheme names).
   ```

10. **Tests:**
    - `server/test/nebu/matrix/sso_login_test.exs` — 16 new tests (AC12.1–AC12.4)
    - `server/test/nebu/admin/config_controller_test.exs` — 6 new tests for save_sso_schemes/2 and validation
    - `e2e/features/admin/sso_schemes.feature` — 2 Godog scenarios (AC13)

---

## Previous Story Context (Learnings from configurable-oidc-scopes)

The **configurable-oidc-scopes** story (2026-06-30) established the pattern this story mirrors:

1. **Seams for tests:** The `:matrix_oidc_extra_scopes_reader` and `:admin_oidc_extra_scopes_reader` patterns (0-arity funs for dependency injection) work well. Apply the same pattern here with `:sso_redirect_schemes_reader`.

2. **Cache invalidation via upsert_server_config:** When `Nebu.Admin.DB.upsert_server_config/1` writes a key that touches a cache, call the cache's `refresh/0` method (which broadcasts via `:pg`). This story extends that pattern to `sso_extra_redirect_schemes`.

3. **Input validation before DB write:** The scope-validation helper (`validate_scopes/1`) is called before any persistence. Mirror this exactly for scheme validation — fail early with user-facing error, never persist invalid data.

4. **Operator control, fail-closed:** When a key is absent from server_config, fall back to sensible defaults (hardcoded allowlist for this story, like scopes). An operator cannot break SSO by editing the field.

---

## Security Considerations

1. **Scheme-squatting (RFC 8252 §8.6):** The allowlist must be exact-string matching only, never regex/pattern/heuristic. This story enforces that.

2. **Denylist enforcement:** The hardcoded denylist (javascript, data, file, vbscript, blob) must take precedence over any custom allowlist. Code ensures this (denylist check happens after custom allowlist check).

3. **Input validation:** All operator input is validated server-side BEFORE any use:
   - RFC 3986 scheme syntax (letter start, alphanumeric + dash/dot/plus)
   - Denylist membership (case-insensitive)
   - Non-empty tokens only

4. **Logging & info leaks:** Rejected redirects log a warning (existing line 75) WITHOUT echoing the scheme or URL. No other logs expose the allowlist or scheme values.

5. **Cache consistency:** An operator's change to `sso_extra_redirect_schemes` via `/admin/config` triggers cache refresh on the SAME node and broadcasts invalidation to peer nodes via `:pg`. No staleness window where different cluster nodes have different allowlists.

---

## Definition of Done

- [ ] `@default_deep_link_schemes` is corrected to `["element", "schildichat", "im.fluffychat.auth"]`
- [ ] All bugfix regression tests pass (AC12.1–AC12.5)
- [ ] `NEBU_SSO_REDIRECT_SCHEMES` env var is removed from `runtime.exs`
- [ ] Full grep confirms no other env var references in codebase
- [ ] Cache pattern is wired (ETS + GenServer refresh + `:pg` broadcast, either extended OidcConfig or new SsoSchemesConfig)
- [ ] `extra_redirect_schemes/0` reads from cache, honors `:sso_redirect_schemes_reader` seam
- [ ] Admin UI form field renders at `/admin/config` with correct labels, placeholders, help text
- [ ] ConfigController `save_sso_schemes/2` handler validates input and persists
- [ ] Validation helper enforces RFC 3986 syntax + denylist check
- [ ] All unit tests pass (AC12 — 16 tests)
- [ ] All config controller tests pass (6 new tests)
- [ ] Godog integration test passes (AC13 — 2 scenarios)
- [ ] Regression test confirms `callback_url/1` is unchanged and independent
- [ ] CHANGELOG.md updated with breaking-change note
- [ ] Code comments explain the denylist-wins-over-allowlist logic
- [ ] No new dependencies added (ADR-021 compliance)
- [ ] Security review checklist items completed

---

## Testing Strategy (ATDD First)

### Test Artifacts (write FIRST, before implementation)

1. **`server/test/nebu/matrix/sso_login_test.exs`** — 16 ExUnit tests
   - AC12.1–AC12.4 (5 bugfix + 5 feature + 5 denylist + 1 denylist-wins tests)

2. **`server/test/nebu/admin/config_controller_test.exs`** — 6 tests
   - Valid scheme submission
   - Invalid RFC 3986 syntax rejection
   - Denylist rejection
   - Empty token rejection
   - Case-insensitive denylist check
   - DB write + cache refresh verification (if testable)

3. **`e2e/features/admin/sso_schemes.feature`** — 2 Godog scenarios (AC13)
   - Happy path: submit valid schemes, verify save
   - Error path: submit blocked scheme, verify rejection

### Test Execution Order

1. **Run tests RED** — Verify all new tests fail before implementation
2. **Implement code** — Make tests green
3. **Regression check** — Ensure existing sso_login tests (denylist, https, http loopback) still pass
4. **Security review** — Verify denylist enforcement, validation, logging

---

## Implementation Notes (Non-Binding)

### Scheme Validation Helper

A helper to validate a comma-separated scheme string (mirrors `validate_scopes/1` from scopes story):

```elixir
defp validate_sso_schemes(str) do
  denylist = ~w(javascript data file vbscript blob)
  
  str
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.find_map(fn token ->
    cond do
      not String.match?(token, ~r/^[a-zA-Z][a-zA-Z0-9+.-]*$/) ->
        {:error, "Scheme '#{token}' is not a valid RFC 3986 scheme. Must start with a letter and contain only alphanumeric, plus, dash, or dot characters."}
      String.downcase(token) in denylist ->
        {:error, "Scheme '#{token}' is blocked. Cannot allow javascript, data, file, vbscript, or blob."}
      true ->
        nil
    end
  end)
  |> case do
    nil -> :ok
    error -> error
  end
end
```

### Denylist Constant

Define in `sso_login.ex` for clarity:

```elixir
@scheme_denylist ~w(javascript data file vbscript blob)
```

(Already exists; reuse in validation code.)

### Cache Module Choice

**Rationale for extending OidcConfig:**
- Both `sso_extra_redirect_schemes` and OIDC config (issuer/audience/jwks_uri) are operator-provided, bootstrap-only settings.
- Both read on hot request paths (OIDC reads on token validation, SSO reads on redirect).
- Both are infrequently changed (no per-request DB cost is critical).
- Using the SAME ETS table and GenServer reduces code duplication and cluster-broadcast overhead.

**Alternative: New SsoSchemesConfig:**
- If future stories require independent cache management or faster refresh cycles, a separate module is cleaner.
- For MVP, reuse is justified.

### Seam Pattern for Testing

```elixir
# In sso_login.ex
defp extra_redirect_schemes do
  case Application.get_env(:nebu_http, :sso_redirect_schemes_reader) do
    fun when is_function(fun, 0) ->
      fun.()  # Test seam returns ["myorg-matrix", ...] or []
    _ ->
      # Read from cache (OidcConfig.get_sso_schemes() or similar)
  end
end

# In tests
setup do
  Application.put_env(:nebu_http, :sso_redirect_schemes_reader, fn -> ["myorg-matrix"] end)
  on_exit(fn -> Application.delete_env(:nebu_http, :sso_redirect_schemes_reader) end)
  :ok
end
```

---

## Git Intelligence (Recent Commits)

Recent work on OIDC and scope configuration:
- **d02c31f6** (docs: OAuth2 spec-compliance framework)
- **d1594a57** (chore: scaffold epic directory)
- **378f7b1f** (Merge: feature/oidc-simplification into main)
- **063de99f** (unify the oidc implementation and fix other security issues)

**Pattern observed:** Bootstrap-wizard and config-management changes are in flight. This story follows the established pattern.

---

## Dev Agent Record

### Pre-Implementation Checklist

- [ ] Read the entire `Nebu.Matrix.SsoLogin` module
- [ ] Confirm `@default_deep_link_schemes` line 57
- [ ] Confirm `@scheme_denylist` line 54
- [ ] Confirm `extra_redirect_schemes/0` lines 319-325
- [ ] Confirm `redirect_url_allowed?/1` logic (lines 296-318)
- [ ] Understand the cache pattern in `Nebu.Web.OidcConfig`
- [ ] Understand the `@scope_cache_keys` pattern in `Nebu.Admin.DB`
- [ ] Review the ConfigController patterns in `config_controller.ex`
- [ ] Review the UI form pattern in `config/index.html.heex`
- [ ] Grep the entire codebase for `NEBU_SSO_REDIRECT_SCHEMES` references (should find only config/runtime.exs)
- [ ] Verify no other files reference the env var
- [ ] Check if `docker-compose.yml` sets the env var (it shouldn't)
- [ ] Confirm bootstrap-only pattern is already established (scopes story did this)

### Implementation Order

1. **Bugfix first (AC1):** Update `@default_deep_link_schemes` → write regression tests → green
2. **Cache wiring (AC6):** Extend or create cache module → update `extra_redirect_schemes/0` → test with seam
3. **Admin UI (AC8-AC9):** Form field + controller handler + validation helper
4. **Environment cleanup (AC3):** Remove env var → grep confirm → CHANGELOG
5. **Tests:** Complete all unit + integration tests
6. **Security review:** Manual code review per checklist

---

## Status

**Current Status:** done  
**Created:** 2026-07-03  
**Completed:** 2026-07-03  
**Epic:** configurable-sso-redirect-schemes  
**Security Review:** required — Kassandra CLEAN (0 CRITICAL/HIGH/MEDIUM/LOW/INFO), plus a
post-review addendum (same day): `@scheme_regex` was found to reintroduce an already-fixed
codebase anti-pattern (`$` anchor instead of `\z`, matching `Nebu.Web.OidcScopes`'s established
pattern) — found, root-caused (an adjacent `String.trim/1` was also masking the same class of
bug), fixed, and regression-tested; see
`security-reports/fix-and-configure-sso-redirect-schemes-security-review-2026-07-03.md`  
**Code Review:** 1 cycle — 1 MAJOR (missing AC13 BDD feature) + 1 MINOR (persist-trim
normalization, non-security) found and fixed; plus the post-review regex-anchor fix above  
**CI Gate:** unit suite 1235 passed / 2 skipped / 0 failed; integration-suite Docker/ephemeral
-container path has a pre-existing, environment-only failure unrelated to this story (confirmed
byte-identical to the pre-change baseline)
