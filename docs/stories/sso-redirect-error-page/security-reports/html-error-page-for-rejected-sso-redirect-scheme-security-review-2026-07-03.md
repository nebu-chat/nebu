# Security Review — html-error-page-for-rejected-sso-redirect-scheme

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Epic:** sso-redirect-error-page
**Story:** html-error-page-for-rejected-sso-redirect-scheme
**Diff scope:** staged diff — `server/lib/nebu/matrix/sso_login.ex` (+161/-6), new test file `server/test/nebu/matrix/sso_login_html_error_page_test.exs` (13 tests). Plus story/pipeline docs (non-code).
**Date:** 2026-07-03
**Classification:** required (public, unauthenticated endpoint echoing parsed user-controlled input into HTML)

---

## Executive Verdict

**CLEAN — APPROVED. No CRITICAL, HIGH, or MEDIUM findings. Pipeline is NOT blocked.**

The intentional reversal of Story 5.24's "do not echo the scheme" decision (AC4 of `docs/stories/mvp/epic-5/5-24-sso-redirect-scheme-allowlist.md`) is **confirmed safe** on this diff. See Finding C1 below — the load-bearing judgment call this review was commissioned to make.

---

## Findings

| # | Severity | Location | Vulnerability / Topic | Verdict |
|---|----------|----------|-----------------------|---------|
| C1 | CONFIRMATION | `sso_login.ex:213-231` (`render_html_error/1`) | Reflected-XSS reversal (the load-bearing question) | SAFE — two independent defense layers, both verified |
| C2 | CONFIRMATION | `sso_login.ex:131-192` (`prefers_html?/1` + parsers) | Content-negotiation as a correctness/availability boundary | SAFE — JSON is the enforced default in code, not just comment |
| C3 | CONFIRMATION | `sso_login.ex:102-104` | CSP header correctness & scope | SAFE — HTML path only, minimal policy correct for a script-free page |
| C4 | CONFIRMATION | `router.ex:181-185` | `X-Content-Type-Options: nosniff` global | CONFIRMED global, not duplicated |
| C5 | CONFIRMATION | full diff | Allowlist (`redirect_url_allowed?/1`) regression | CONFIRMED byte-for-byte unchanged |
| C6 | CONFIRMATION | full diff | `uia_fallback/1` / OIDC callback hardened-path boundary | CONFIRMED untouched (pattern #73 respected) |
| C7 | CONFIRMATION | `sso_login.ex:161-192` + Bandit config | DoS via pathological Accept header | MITIGATED upstream (Bandit default header caps) |
| I1 | INFO | `sso_login.ex:225` | Minor hardening opportunity (advisory only) | Optional |

---

## Detail

### C1 — The XSS reversal itself [CONFIRMATION — SAFE] (load-bearing)

**This is the explicit, first-class judgment this review was commissioned to make.**

Story 5.24 deliberately did NOT echo the scheme "to avoid this exact risk." This story reverses that. I do **not** accept that reversal on the strength of the prior sign-off or the code reviewer — I verified it independently. It is safe, for two reasons that both hold:

**Sole interpolation point.** I read `render_html_error/1` in full. The ONLY user-controlled value interpolated is the pre-escaped `escaped_scheme` at line 225 (`<code>#{escaped_scheme}</code>`). I grepped the entire new template region for `#{`, `<script`, `<style`, `src=`, `href=`, `url(`, `onerror`, `onload` — there is exactly one interpolation (`escaped_scheme`), no inline scripts, no external resource references, no event handlers. The full `redirectUrl`, host, path, and query are never rendered (Test 4a asserts this: `refute body =~ "attacker.example" / "/secret/path" / "token=admin"`). The `<script>` at `sso_login.ex:428` is in the pre-existing OIDC-callback success page — a different function, not on this rejection branch, not in this diff.

**Escaping is explicit, not assumed.** The scheme is passed through `Plug.HTML.html_escape/1` (line 214) BEFORE interpolation into a plain heredoc. The dev correctly avoided `EEx.eval_string` (no auto-escape in EEx) and `Phoenix.HTML.raw/1`. I independently ran `Plug.HTML.html_escape/1` in this repo's build: it escapes all five dangerous characters — `< > & " '` → `&lt; &gt; &amp; &quot; &#39;`. This is layer 2.

**Layer 1 (URI.parse) verified, but NOT used to excuse layer 2.** I ran Elixir's actual `URI.parse/1` against hostile inputs in this repo's toolchain:
- `"<script>alert(1)</script>://foo"` → `scheme = nil`
- `"a<b:c"` → `nil`; `"a_b://x"` → `nil`; `"1abc://x"` → `nil`; `"\"onload=x"` → `nil`; `"a\"b://x"` → `nil`
- Valid grammar preserved: `"a.b+c-d://x"` → `"a.b+c-d"`; `"im.fluffychat.auth://x"` → `"im.fluffychat.auth"`

RFC 3986 scheme grammar (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`) is enforced by `URI.parse`, so any HTML metacharacter in the scheme position yields `nil` and never reaches the template via the HTTP path. This narrows the attack surface but is treated as belt, not the only strap — the escaping (layer 2) is independently correct and would hold even if a hostile string reached it.

**The escaping test is real, not vacuous.** Test 4b (`sso_login_html_error_page_test.exs:199-229`) calls `render_html_error/1` directly with `"<script>alert(1)</script>"` and asserts BOTH the escaped form present (`output =~ "&lt;script&gt;alert(1)&lt;/script&gt;"`) AND raw markup absent (`refute output =~ "<script>alert(1)</script>"`). If the `Plug.HTML.html_escape/1` call were removed, this test would fail on both assertions. Non-vacuous. Confirmed.

**Verdict: the reversal is safe.** Both defense layers hold independently and are individually tested.

### C2 — Content negotiation as a security/correctness boundary [CONFIRMATION — SAFE]

Concern: could a JSON-parsing Matrix client accidentally receive HTML and break its error handling? I traced `prefers_html?/1` → `best_q/2` → `parse_accept_header/1` → `parse_media_range/1`. The "default to JSON" behavior is **enforced by code**, not merely claimed:
- `prefers_html?/1` (lines 140-144) returns HTML only when an HTML-ish entry (`text/html`/`application/xhtml+xml`, NOT wildcards) exists AND its q strictly exceeds JSON's q. `{nil, _} -> false` (no HTML token → JSON). Ties → JSON (`html_q > json_q` is strict). No Accept header → empty list → both nil → false → JSON.
- Real Matrix client libraries send `Accept: application/json` (or nothing), which deterministically yields JSON (Test 2, Test 3, Test 8). A browser's realistic `text/html,...,*/*;q=0.8` yields HTML (Test 1). The two populations do not collide.
- The JSON body is byte-for-byte identical to the pre-existing error (Test 2/3 assert `== @rejected_json`), preserving `{errcode, error}` for programmatic clients.

No availability/correctness regression for JSON API clients.

### C3 — CSP header correctness and scope [CONFIRMATION — SAFE]

`Content-Security-Policy: default-src 'none'` (line 103) is set only inside the `if prefers_html?(conn)` branch of `reject_redirect/2` — it cannot leak onto the JSON path (the `else` branch calls `error/4` with no CSP). The rendered page has zero scripts, styles, images, or external references, so `default-src 'none'` needs no carve-out and is the correct minimal policy. Test 5 asserts CSP presence on the HTML path.

### C4 — X-Content-Type-Options: nosniff [CONFIRMATION]

Verified in `server/lib/nebu/web/router.ex:181-185`: `security_headers/2` registers a `before_send` callback setting `x-content-type-options: nosniff` on **every** response. Not duplicated in the new code (correct — DRY, and Test 5 asserts it flows through). Confirmed, not merely trusted from the story text.

### C5 — Allowlist regression / blast radius [CONFIRMATION]

`redirect_url_allowed?/1`, `extra_redirect_schemes/0`, `@scheme_denylist`, `@default_deep_link_schemes` do NOT appear as changed lines anywhere in the staged diff (only a comment references `redirect_url_allowed?/1`). The allow/deny decision (denylist, https-always, http-loopback-only, admin extra schemes) is byte-for-byte unchanged. The story changes only the rejection *representation*. The 28-test `sso_login_test.exs` allowlist suite is unmodified and passes (Dev Agent Record). Confirmed.

### C6 — uia_fallback / OIDC callback boundary [CONFIRMATION]

The diff has exactly 4 hunks: (1) the new rejection branch + all new functions; (2) a `mix format` reflow of the `SsoStore.put_state` map arg inside `do_redirect/2` (allow path); (3-4) `mix format` reflows of `normalize_exchange`/`exchange_code` clauses. Hunks 2-4 are pure whitespace/line-wrap with no logic change. No added line touches `callback/1`, `do_callback/1`, `uia_fallback/1`, the UIA identity-binding UPDATE, `max_age`, `auth_time`, `id_token`, or `refresh_token` handling.

This matters because my sanctum MEMORY (patterns #69/#73) records a prior BLOCKING HIGH fix on exactly this UIA step-up path — identity-binding of the freshly-verified `sub` to the session owner. That hardened re-authentication flow is **genuinely untouched** by this diff. Boundary respected, not just claimed.

### C7 — DoS via pathological Accept header [CONFIRMATION — MITIGATED]

`parse_accept_header/1`/`parse_media_range/1` do linear `String.split` work with no regex backtracking and no quadratic behavior — cost is O(header length). The endpoint is unauthenticated, so upstream input bounding matters. The HTTP server is **Bandit ~> 1.5** (`application.ex:83`), started with only `plug:`/`port:` — no custom `http_1_options` — so Bandit's default caps apply: max ~10 KB per header line and 50 headers. A pathological Accept header is truncated/rejected by Bandit before reaching this parser. Worst case within the 10 KB cap is a few thousand trivial comma entries parsed linearly — negligible CPU/memory. Mitigated upstream; not a gap in this code. (Advisory: if a future change raises Bandit's header limits, re-evaluate this parser.)

### I1 — INFO (advisory, non-blocking)

The interpolation sits inside a `<code>` element in HTML text-content context, which is the correct low-risk context for the escaping applied (`html_escape` covers `< > & " '`, sufficient for both element-text and double/single-quoted attribute contexts). No attribute-context interpolation exists, so no additional hardening is required. Noted only for completeness — no action needed.

---

## Nebu-Specific Invariants Checklist

- **Compliance / audit-log immutability:** N/A — no audit-log or compliance record writes on this path. The rejection logs a static `Logger.warning("matrix SSO: redirectUrl rejected by allowlist")` with NO user input interpolated (no log-injection vector). Confirmed.
- **OIDC / token handling:** N/A — no OIDC token, id_token, PKCE, or session-token handling changed (see C6).
- **Crypto:** N/A — no crypto primitives, no comparisons of secrets, no key material.
- **SQL / persistence (ADR-018):** N/A — pure response formatting, no DB access on this branch (rejection happens before any `SsoStore`/OIDC read).
- **ADR-021 (pure Elixir):** upheld — no new deps.
- **Secrets in errors/logs:** none — the HTML/JSON error bodies and the log line contain no secrets; only the parsed scheme (escaped) is echoed.

---

## Prior Gate Context (independently spot-checked, not blindly trusted)

- Oracle Matrix-spec gate CLEAR — the endpoint stays HTTP 400 on both representations; JSON body byte-identical to spec-shaped `{errcode, error}` envelope. Consistent with what I observed.
- Code-review M1/M2/M3 (Accept-header doc, OWS whitespace tolerance, strict float q-parse) — I read the current code: `parse_media_range/1` trims around `=` and requires `Float.parse` to return `{q, ""}` (rejects `0.8abc`). Present in the reviewed code. These are robustness, not security; no security impact either way (safe fallback to q=1.0).

---

## Summary

- CRITICAL: 0 — no commit block
- HIGH: 0 — no commit block
- MEDIUM: 0
- LOW: 0
- INFO: 1 (advisory only, no action required)
- CONFIRMATIONS: 7 (all SAFE / respected)

**Verdict: CLEAN — APPROVED.** The intentional reflected-XSS reversal (C1) is confirmed safe by two independently-verified defense layers (RFC 3986 scheme grammar via `URI.parse`, and explicit `Plug.HTML.html_escape/1`), with a real non-vacuous escaping test. No CRITICAL or HIGH findings. Pipeline is not blocked.
