---
story_id: html-error-page-for-rejected-sso-redirect-scheme
title: "HTML error page for rejected SSO redirect scheme"
epic: sso-redirect-error-page
status: done
security_review: required
matrix: true
ui: true
created: 2026-07-03
---

# Story: HTML error page for rejected SSO redirect scheme

## Story

**As** a user attempting to log in via SSO with an unsupported deep-link scheme,
**I want** to see a human-readable HTML error page instead of a JSON error blob,
**so that** I understand why my login failed and can contact the server administrator to request support for my app's scheme.

---

## Background / Motivation

The Matrix SSO redirect endpoints (`GET /_matrix/client/v3/login/sso/redirect` and `.../sso/redirect/{idpId}`)
always open in a real browser (Matrix spec: client opens the OS browser, waits for a deep-link callback).
When the client's `redirectUrl` scheme is not allowlisted (per Story 5.24: SSO Redirect Scheme Allowlist),
the current implementation returns a JSON error:

```json
{"errcode":"M_INVALID_PARAM","error":"redirectUrl scheme is not permitted"}
```

This is a poor user experience — the browser displays raw JSON with no actionable next step. A minimal HTML
error page would be far more user-friendly and still maintain security (no echoing of the full URL, only
the parsed scheme via safe template escaping).

---

## Acceptance Criteria

1. **AC1 — Content negotiation based on Accept header.** On a rejected-scheme request to
   `GET /_matrix/client/v3/login/sso/redirect` or `GET /_matrix/client/v3/login/sso/redirect/{idpId}`:
   - If the `Accept` header clearly prefers `text/html` (e.g. contains `text/html` or `application/xhtml+xml`
     without explicit higher-priority `application/json`), render and return an HTML error page, HTTP 400.
   - Otherwise (missing Accept, `Accept: application/json`, bare `Accept: */*`, or ambiguous preference),
     return the EXACT pre-existing JSON error unchanged, HTTP 400. This is the default/fallback.

2. **AC2 — JSON fallback regression.** The JSON error path (`Accept: application/json` or no Accept header)
   returns EXACT pre-existing JSON body unchanged:
   ```json
   {"errcode":"M_INVALID_PARAM","error":"redirectUrl scheme is not permitted"}
   ```
   HTTP 400. Regression test required — must byte-for-byte match current behavior to prevent accidental changes.

3. **AC3 — HTML output uses safe auto-escaping.** The HTML error page is rendered via a proper auto-escaping
   mechanism. The rejected scheme (the parsed `uri.scheme` token) is the ONLY user-controlled value rendered.
   It must be explicitly HTML-entity-escaped via `Plug.HTML.html_escape/1` or equivalent before interpolation.
   Regression test: construct a directly-rendered template fragment with a hostile string (e.g. `<script>alert(1)</script>`)
   and confirm output contains HTML-entity-escaped form (`&lt;`, `&gt;`, etc.), never raw executable markup.

4. **AC4 — Only scheme echoed, never full URL.** The HTML page displays ONLY the rejected scheme (e.g. `im.fluffychat.auth`),
   never the full `redirectUrl`, host, path, or query parameters. Test with a rejected `redirectUrl` containing
   suspicious host/path/query (e.g. `evilscheme://attacker.example/path?token=x`) and confirm resulting HTML
   contains ONLY the scheme string, never any other substring.

5. **AC5 — Response headers include CSP and nosniff.** The HTML response includes:
   - `Content-Security-Policy: default-src 'none'` (minimalist inline policy)
   - `X-Content-Type-Options: nosniff` (already set globally by `Nebu.Web.Router.security_headers`, confirmed via test)

6. **AC6 — Allowlist logic untouched.** The scheme validation logic (`redirect_url_allowed?/1`) is completely
   unaffected by this story. The story changes ONLY the rejection response format (JSON → HTML based on Accept header),
   never the allow/deny decision. Existing unit tests in `sso_login_test.exs` for allowlist behavior must still pass
   unmodified as a regression gate.

7. **AC7 — UIA fallback and OIDC callback out of scope.** The `uia_fallback/1` endpoint (story s3-matrix-device-endpoints,
   UIA m.login.sso auth step) and the OIDC callback (`GET .../sso/redirect/oidc`) are unmodified by this story.
   No test changes to their existing behavior.

---

## Acceptance Tests

### Tests written FIRST (ATDD gate):

1. **HTML negotiation: text/html preference** — ExUnit integration (`Plug.Test` style)
   - Given: a client POSTs `GET /_matrix/client/v3/login/sso/redirect?redirectUrl=<not-allowlisted-scheme>://host`
     with `Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` (realistic browser header)
   - When: the request is dispatched
   - Then: HTTP 400, `Content-Type: text/html`, body is HTML (contains `<!doctype html` or equivalent),
     and response contains the parsed scheme string (e.g. `im.fluffychat.auth`) in human-readable form.

2. **JSON fallback: Accept: application/json** — ExUnit integration
   - Given: same rejected-scheme request with `Accept: application/json`
   - When: the request is dispatched
   - Then: HTTP 400, `Content-Type: application/json`, body is exactly:
     ```json
     {"errcode":"M_INVALID_PARAM","error":"redirectUrl scheme is not permitted"}
     ```
     (byte-for-byte match required).

3. **JSON fallback: no Accept header** — ExUnit integration
   - Given: same rejected-scheme request with NO `Accept` header
   - When: the request is dispatched
   - Then: HTTP 400, body is exactly the same JSON as test 2 (fallback when Accept is absent).

4. **HTML content: scheme-only echo** — ExUnit integration + unit test
   - **Integration**: POST `GET /_matrix/client/v3/login/sso/redirect?redirectUrl=evilscheme://attacker.example:9999/secret/path?token=admin&<script>=1`
     with `Accept: text/html`, where `evilscheme` is a valid URI scheme (no HTML metacharacters)
     and not allowlisted.
   - **When**: the request is dispatched
   - **Then**: HTTP 400, HTML body contains the scheme `evilscheme` but does NOT contain the string `attacker.example`,
     `/secret/path`, `token=admin`, or any other substring beyond the scheme.
   - **Unit test** (direct template render, independent of HTTP): Call the template-rendering helper with a
     directly-injected hostile string `<script>alert(1)</script>` and confirm output contains `&lt;script&gt;alert(1)&lt;/script&gt;`,
     proving the escaping function works correctly even if such a string could not reach it via HTTP (due to URI.parse strictness).

5. **HTML content: security headers present** — ExUnit integration
   - Given: a rejected-scheme request with `Accept: text/html`
   - When: the response is received
   - Then: response headers include `Content-Security-Policy: default-src 'none'` AND `X-Content-Type-Options: nosniff`.

6. **HTML content: actionable text referencing admin UI** — ExUnit integration
   - Given: a rejected-scheme request with `Accept: text/html`
   - When: the response is received
   - Then: HTML body contains text that directs the user to contact the server administrator and references
     the Admin UI configuration location (e.g. "ask your administrator to add this scheme under Configuration → SSO redirect schemes"
     or similar, pointing to `/admin/config`).

7. **Allowlist logic regression** — ExUnit unit
   - Run existing `sso_login_test.exs` test suite (all tests for `redirect_url_allowed?/1` and scheme categorization)
     with no modifications — all tests must pass.

8. **Accept header heuristic edge cases** — ExUnit integration
   - `Accept: application/json, text/html;q=0.8` (json higher priority) → JSON response
   - `Accept: */*, text/html` (explicit html without q-value, comes after wildcard) → HTML response
   - `Accept: text/html;q=0.1, application/json;q=0.9` (json higher priority) → JSON response
   - Confirms the heuristic is conservative and defaults to JSON when ambiguous.

---

## Implementation Notes

### Content Negotiation Heuristic

**The heuristic must be simple and conservative — default to JSON when in doubt.** Suggested logic:

```
html_preferred(accept_header) =
  - If accept_header is nil/empty/missing → false (default to JSON)
  - If accept_header contains "application/json" with explicit q-value >= 0.9 → false
  - If accept_header contains "text/html" or "application/xhtml+xml" AND no "application/json" → true
  - Otherwise → false (default to JSON)
```

Keep the implementation in `Nebu.Matrix.SsoLogin` as a small private helper function `html_accepted?/1` that inspects
`get_req_header(conn, "accept")` — no dependency on Phoenix's `plug :accepts` (this is a plain Plug module, not a controller).

**Document the heuristic** in the helper's docstring so future developers understand the intentional conservative bias.

### Template Rendering

Since `Nebu.Matrix.SsoLogin` is a plain Plug module (not Phoenix), use **`EEx.eval_string/2` with explicit `Plug.HTML.html_escape/1` escaping**:

```elixir
defp render_html_error(scheme) do
  escaped_scheme = Plug.HTML.html_escape(scheme)
  template = """
  <!doctype html>
  <html>
  <head>
    <meta charset="utf-8">
    <title>Login Not Supported</title>
    <style>
      body { font-family: sans-serif; margin: 2em; }
      code { background: #f0f0f0; padding: 2px 4px; }
    </style>
  </head>
  <body>
    <h1>Login Method Not Supported</h1>
    <p>The login app's scheme <code><%= scheme %></code> is not yet enabled on this server.</p>
    <p>Please contact your server administrator to add support for this scheme. Go to the Admin UI Configuration page → "SSO redirect schemes" section.</p>
  </body>
  </html>
  """
  EEx.eval_string(template, assigns: [scheme: escaped_scheme])
end
```

**Important note on Elixir/EEx:** Raw `EEx.eval_string` does NOT auto-escape by default (that's a Phoenix.HTML/HEEx feature).
The escaping MUST be explicit via `Plug.HTML.html_escape/1` on the variable BEFORE passing it into the template,
or via a raw-string injection pattern documented in the story's dev notes. The story's regression test MUST verify
the escaping actually happens at the output level (not rely on EEx's default behavior, since there is none).

### Response Modification in SsoLogin

Modify the `redirect/1` function's rejection branch:

```elixir
not redirect_url_allowed?(redirect_url) ->
  Logger.warning("matrix SSO: redirectUrl rejected by allowlist")
  reject_redirect(conn, redirect_url)
```

Add a private function:

```elixir
defp reject_redirect(conn, redirect_url) do
  uri = URI.parse(redirect_url)
  scheme = uri.scheme && String.downcase(uri.scheme)
  
  if html_accepted?(conn) do
    # Render HTML error page
    conn
    |> put_resp_header("content-security-policy", "default-src 'none'")
    |> put_resp_content_type("text/html")
    |> send_resp(400, render_html_error(scheme))
  else
    # Fall back to JSON
    error(conn, 400, "M_INVALID_PARAM", "redirectUrl scheme is not permitted")
  end
end
```

### Admin UI Reference

The HTML error page must reference the ACTUAL Admin UI location where operators manage SSO schemes:
- Path: `/admin/config`
- Section heading: "SSO redirect schemes"
- Form action: `POST /admin/config/sso-schemes`

(Already verified in `server/lib/nebu/admin/templates/config/index.html.heex` lines 54–60.)

### Experimental Fact: URI.parse Strictness (Defense in Depth)

**This is not a reason to skip escaping — it is defense-in-depth #1.**

Elixir's `URI.parse/1` is strict about RFC 3986 scheme grammar. A scheme can only be non-nil if it matches
`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` — i.e. only letters, digits, `+`, `-`, `.`, and must start with a letter.
Any HTML metacharacter (`<`, `>`, `"`, `/`, space), underscore, leading digit, control character, or percent-encoding
in the scheme position causes `uri.scheme` to be `nil` entirely (not a malicious string).

Verified examples:
- `URI.parse("<img src=x onerror=alert(1)>://foo").scheme` → `nil`
- `URI.parse("a<b:c").scheme` → `nil`
- `URI.parse("a_b://x").scheme` → `nil`
- `URI.parse("1abc://x").scheme` → `nil`
- Valid: `URI.parse("a.b+c-d://x").scheme` → `"a.b+c-d"`

**Implication:** The attack scenario ("HTML metacharacters in the scheme") cannot literally occur via the HTTP request path,
because any such input gets nilled out by URI.parse, so it never reaches the template render. This is belt-and-suspenders
defense-in-depth: URI.parse is layer 1 (the strict grammar), and template escaping is layer 2 (the failsafe if a hostile
string somehow made it through). Both layers together ensure safety; skipping layer 2 would be unjustified even though
layer 1 already prevents the specific attack.

**The regression test should reflect this:** An integration test with a valid-grammar but hostile-shaped scheme (if possible —
e.g. a scheme like `a0onerror` that parses successfully but contains attack-shaped substrings) should pass through and be
confirmed as escaped. If no such valid-grammar example exists, a unit test directly calling the render function with a
hostile string proves layer 2 independently.

---

## Dev Notes

### Security Review Notes

- **XSS surface:** This story echoes the parsed `uri.scheme` (a user-controlled input token) into an HTML response on a
  public, unauthenticated endpoint. This is a real XSS-adjacent surface requiring explicit security sign-off.
- **Mitigations:**
  1. URI.parse strictness — scheme grammar is RFC 3986 strict, rejects HTML metacharacters at the URI parsing layer.
  2. Explicit HTML escaping — the scheme is passed through `Plug.HTML.html_escape/1` before template interpolation,
     and the template is rendered via `EEx.eval_string` (not a Phoenix HEEx auto-escaping context), so escaping is
     explicit and testable.
  3. No external assets, no JavaScript, no interactivity — minimalist HTML reduces attack surface.
  4. CSP: `default-src 'none'` — blocks any inline script/style leakage.
- **Test coverage:**
  - Integration test confirms that a rejected URL with suspicious host/path/query renders HTML containing ONLY the scheme.
  - Unit test of the render function directly injects a hostile string and confirms HTML-entity escaping in output.
  - Regression test confirms the JSON path is byte-identical, preventing unintended changes to the fallback.

### Admin UI Classification Note

The frontmatter includes `ui: true` because this story produces user-facing HTML output (even though it's not part of
the Admin UI proper — it's a user-facing HTML error page from the Matrix API surface). The classification step (`classify_story.py`)
should flag this for UX consideration if the pipeline supports `ui:true` for non-Admin-UI HTML. Basic HTML correctness
and semantic markup still apply, but interactive/accessibility checks specific to the Admin UI may not be fully applicable
(no forms, no interactive elements).

### X-Content-Type-Options: nosniff Already Global

The header `X-Content-Type-Options: nosniff` is ALREADY set globally for every response by `Nebu.Web.Router.security_headers`
(line ~181–185 of `router.ex`), via a `before_send` callback. The HTML response will get this header for free. The regression
test should assert its presence (belt and suspenders — confirm it's there even though the global middleware should add it)
to ensure no future refactoring accidentally removes it from this specific response.

### Naming & File Placement

- Epic directory: `docs/stories/sso-redirect-error-page/`
- Story file: `html-error-page-for-rejected-sso-redirect-scheme.md` (describes the feature — what's added)
- Module: `Nebu.Matrix.SsoLogin` (existing, no new module)
- No new test file — add to existing `server/test/nebu/matrix/sso_login_test.exs`

---

## Tasks / Subtasks

- [x] AC1 — Implement `prefers_html?/1` helper to inspect Accept header with conservative heuristic (q-value aware; named `prefers_html?/1` instead of `html_accepted?/1` from the Implementation Notes — same responsibility, see Dev Agent Record)
- [x] AC1 — Implement `reject_redirect/2` to dispatch based on content negotiation
- [x] AC2 — JSON fallback path returns exact pre-existing body unchanged
- [x] AC3 — Implement `render_html_error/1` using an explicit `Plug.HTML.html_escape/1`-escaped, pre-escaped-interpolation static template (no `EEx.eval_string`, see Dev Agent Record)
- [x] AC4 — HTML page displays ONLY the scheme, never full URL/host/path/query
- [x] AC5 — Add `Content-Security-Policy: default-src 'none'` header; confirm `X-Content-Type-Options: nosniff` via test
- [x] AC6 — Confirm existing allowlist tests pass unmodified (regression gate)
- [x] AC7 — Confirm `uia_fallback/1` and OIDC callback are unmodified
- [x] Test 1 — HTML negotiation: text/html browser Accept header → HTML 400
- [x] Test 2 — JSON fallback: `Accept: application/json` → exact JSON 400
- [x] Test 3 — JSON fallback: no Accept header → exact JSON 400
- [x] Test 4 — HTML scheme-only echo + unit test of render escaping
- [x] Test 5 — HTML security headers (CSP + nosniff)
- [x] Test 6 — HTML actionable text with admin UI reference (tightened to require BOTH `/admin/config` AND "SSO redirect schemes")
- [x] Test 7 — Allowlist logic regression (existing tests pass)
- [x] Test 8 — Accept header edge cases (q-value priority) + added explicit bare `Accept: */*` case (test-review finding #4)

---

## Dev Agent Record

### Implementation Plan

- `redirect/1`'s rejection branch (`not redirect_url_allowed?(redirect_url)`) now calls a new private
  `reject_redirect/2` instead of calling `Nebu.Matrix.Http.error/4` directly. `reject_redirect/2` is the ONLY
  place that decides HTML vs JSON, and it is reached only from the rejection branch — the allow path
  (`do_redirect/2`), `uia_fallback/1`, and the OIDC callback (`callback/1`/`do_callback/1`) are untouched
  (AC6/AC7, Oracle N1).
- Content negotiation: `prefers_html?/1` parses `get_req_header(conn, "accept")` into `{media_type, q}` pairs
  via `parse_accept_header/1` + `parse_media_range/1` (q defaults to 1.0 per RFC 7231 §5.3.2 when absent), then
  compares the best HTML-ish q-value (`text/html` or `application/xhtml+xml`, via `best_q/2`) against the best
  `application/json` q-value. HTML wins only if an HTML-ish entry exists and its q is strictly greater than
  JSON's (ties and "no HTML-ish entry at all" both fall back to JSON — the guaranteed default, AC2/Oracle N2).
  Named `prefers_html?/1` rather than the story's suggested `html_accepted?/1` — same single-purpose private
  helper, clearer name for what it returns (a boolean preference decision, not an accept/reject verdict).
- Rendering: `render_html_error/1` (public, `@doc false`) takes the raw scheme string (or `nil`), escapes it via
  `Plug.HTML.html_escape/1`, and interpolates the ALREADY-escaped value into a static heredoc template — no
  `EEx.eval_string/2`. Deviates from the story's Implementation Notes suggestion (`EEx.eval_string` with
  `Plug.HTML.html_escape/1`) per the task's explicit guidance: a plain pre-escaped string template is simpler,
  equally safe, and avoids the unnecessary `EEx.eval_string` dependency for a single interpolation point.
  Public visibility (not `defp`) is required so the ATDD unit test (Test 4b) can call it directly via
  `apply(SsoLogin, :render_html_error, [hostile])`, independent of the HTTP/Plug.Conn path.
- HTML page copy explicitly includes BOTH the Admin UI path (`/admin/config`) and the section name
  ("SSO redirect schemes") so they co-occur in the rendered text (test-review finding #2), matching the
  now-tightened Test 6 assertion (`body =~ "/admin/config"` AND `body =~ "SSO redirect schemes"`, two separate
  assertions rather than the original `or`).
- `Content-Security-Policy: default-src 'none'` is set explicitly via `put_resp_header/3` in `reject_redirect/2`
  on the HTML path only — `SsoLogin` is a plain Plug module with no access to `Nebu.Admin.Router`'s
  Phoenix-router-scoped `admin_csp` plug, so a small local header set is correct here rather than attempting
  to share the Admin CSP plug across the pipeline boundary. `X-Content-Type-Options: nosniff` is NOT duplicated
  — it is already set globally by `Nebu.Web.Router`'s `security_headers/2` `before_send` callback; Test 5 only
  asserts its presence.
- HTTP status stays 400 on both the HTML and JSON paths — unchanged.
- `redirect_url_allowed?/1` and its helpers (`extra_redirect_schemes/0`, `@scheme_denylist`,
  `@default_deep_link_schemes`) are byte-for-byte unchanged (AC6) — confirmed by running the full
  pre-existing `sso_login_test.exs` suite unmodified (28/28 pass).

### Test-review findings addressed

1. Test 1's scheme-echo assertion left as-is (Test 4a already covers the negative case properly) — no change,
   per the review's own recommendation.
2. Test 6 tightened to require BOTH `/admin/config` and `"SSO redirect schemes"` as two separate assertions
   (previously an `or`); the rendered HTML copy was written to include both, so this passes meaningfully rather
   than vacuously.
3. Test 4b's describe-label cosmetically renamed from "hostile scheme-shaped string" to "hostile string".
4. Added an explicit test case for bare `Accept: */*` (no `text/html` token at all) → JSON, in Test 8's describe
   block, per AC1's explicit enumeration of this case.

### Code-review findings addressed (cycle 1)

1. **M1 (documentation)** — the Accept-header decision logic implemented in `prefers_html?/1`/`best_q/2`
   is a generalization of the story's suggested if/else pseudocode (which special-cased
   `application/json` at `q>=0.9`): the actual rule is "HTML wins only if its best q-value is
   strictly greater than JSON's best q-value; ties or an absent HTML-ish entry both default to
   JSON." This is behaviorally equivalent on every case in the story and the ATDD tests (verified
   by code-review hand-trace) and is documented here for anyone comparing the code against the
   story's Implementation Notes verbatim.
2. **M2 (robustness)** — `parse_media_range/1` now trims whitespace around the `=` in a `;q=` parameter
   (e.g. tolerates `q = 0.9`, not just `q=0.9`), for full RFC 7231 §5.3.1 OWS tolerance. No real browser
   emits this shape and there was no security impact either way (safe fallback to q=1.0), but the parser
   is now stricter about matching the actual grammar.
3. **M3 (robustness)** — `parse_media_range/1`'s q-value parse now requires the ENTIRE value to be a valid
   float (`Float.parse/1` must consume the whole string, i.e. return `{q, ""}`) rather than silently
   accepting trailing garbage (e.g. `q=0.8abc` previously parsed as `0.8`; it now falls back to the
   default `q=1.0` instead, treating the malformed value as absent).

### Completion Notes

- All 13 tests in `server/test/nebu/matrix/sso_login_html_error_page_test.exs` pass (12 original + 1 added
  `Accept: */*` case).
- All 28 tests in `server/test/nebu/matrix/sso_login_test.exs` pass, unmodified — AC6 regression gate satisfied.
- Full `server/test/nebu/matrix/` suite: 719 passed, 2 skipped, 229 excluded, 0 failures — no regressions in
  sibling SSO-related test files (`sso_login_scope_test.exs`, `sso_login_configured_claim_device_test.exs`,
  `sso_login_oidc_config_db_fallback_test.exs`, `sso_login_bootstrap_credentials_test.exs`, etc.).
- `mix format` applied to both changed files; `mix compile --warnings-as-errors` is clean.
- No new dependencies (pure Elixir, ADR-021); no domain model / repository layer introduced (ADR-018 — this is
  response formatting, not persistence).

## File List

- `server/lib/nebu/matrix/sso_login.ex` (modified — `redirect/1`'s rejection branch now calls `reject_redirect/2`;
  added `reject_redirect/2`, `prefers_html?/1`, `best_q/2`, `parse_accept_header/1`, `parse_media_range/1`, `render_html_error/1`)
- `server/test/nebu/matrix/sso_login_html_error_page_test.exs` (modified — added explicit bare `Accept: */*` test case
  per test-review finding #4; tightened Test 6 to require both `/admin/config` and "SSO redirect schemes" per finding #2;
  cosmetic describe-label rename per finding #3)

---

## Change Log

- 2026-07-03 — Story created: HTML error page for rejected SSO redirect scheme. Content negotiation on Accept header,
  safe template-based rendering with explicit escaping, CSP header, admin UI reference. (Claude)
- 2026-07-03 — Implemented. `redirect/1`'s rejection branch now dispatches to `reject_redirect/2`, which negotiates
  HTML vs JSON via `prefers_html?/1` (q-value-aware, conservative/JSON-biased Accept-header parsing) and renders a
  minimal, explicitly-escaped HTML error page (`render_html_error/1`) with `Content-Security-Policy: default-src 'none'`
  when HTML is preferred; JSON stays the exact byte-for-byte default fallback otherwise. `redirect_url_allowed?/1` and
  the OIDC callback/UIA-fallback paths are untouched. All 13 ATDD tests, all 28 pre-existing `sso_login_test.exs` tests,
  and the full `test/nebu/matrix/` suite (719 passed, 2 skipped, 229 excluded, 0 failures) pass. `mix compile
  --warnings-as-errors` is clean. (Claude)
