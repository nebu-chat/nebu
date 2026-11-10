## Security Review — oauth-pages-redesign/04-sso-confirm-and-result-pages

**Diff scope:** staged `server/` diff: `Nebu.Matrix.SsoConfirmPage` (confirm, cancelled, error pages moved onto `PageShell`/`PageText`), `Nebu.Matrix.SsoLogin` (`render_html_error/2`, new `send_uia_result/2` for the UIA "Authentication complete" / "did not match" pages), `Nebu.Web.PageShell` (`csp_with_script/1`, CSS additions), `Nebu.Web.PageText` (new `sso.*`, `err.*`, `uia.*`, `unsupported.*` keys), plus tests.
**Date:** 2026-11-05
**Prescan:** `sec-candidates.md`: 0 candidates.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/lib/nebu/matrix/sso_confirm_page.ex `details/2` | The signed-in user id and the redirect path moved from the visible body into a closed `<details>`. This weakens defense in depth slightly. | Optional: show the path next to the origin. Accepted per design 5.2. |

### Detail

**Finding #1: Confirm-page facts collapsed** [LOW]
The target origin, the warning notice and the IDN note are still visible above the buttons, and `aria-describedby` still points at the origin and the notice. So the main anti-phishing fact (where the token goes) is not hidden. Only the account id and the path are collapsed now. There is no exploit path. It is a small loss in how easy the page is to check, the same pattern as story 03.

### Verified (no finding)

- **CSP of the UIA "Authentication complete" page:** `PageShell.csp_with_script(@uia_script)` gives `default-src 'none'; style-src 'sha256-<shell css>'; script-src 'sha256-<uia script>'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`. It has no `unsafe-inline` and no nonce. Both hashes are computed at compile time from the exact strings that `PageShell.render/2` emits (`<script>#{js}</script>`, `<style>#{@css}</style>`), so the hash pinning is consistent. This is stricter than before, when the page had no CSP. The mismatch page uses the strict `PageShell.csp()` and has no script.
- **No reflection:** the UIA complete and mismatch pages, the cancelled page and the error pages render only catalog texts, which are escaped by `t/2` / `PageShell.esc`. `data-error` is a code from a fixed map (`Map.fetch!` fails closed). `<title>` is escaped in `PageShell.render/2`. `lang` comes from `Locale.from_conn/1`, which returns only `:en`/`:de` (guarded in `render/2`), and the header input is bounded.
- **XSS via scheme, host, path or user id:** the scheme in `render_html_error/2` is `PageShell.esc`'d. It is then put into the escaped catalog text with `Regex.replace/3` and a function replacement: one pass, no backreference interpretation, and the value is not scanned again. The host is validated by `SsoRedirect.valid_https_host?/1` and escaped. The path (truncated) and the user id are escaped. The csrf token in the attribute is escaped.
- **Headers unchanged:** the confirm page keeps `page_csp(source)` with `form-action 'self' https://<validated host[:port]>`, `script-src` pinned to the ArmScript hash, `referrer-policy: same-origin` and the flow headers. No COOP was added to the UIA popup pages (`window.opener` is still available), and the doc comment states this. `cache-control: no-store` is kept on the UIA pages.
- **Logging:** no new `Logger` calls in the diff. `send_uia_result/2` logs nothing.
- **CSRF / redirect / auth logic:** unchanged. The form post, csrf token and decision flow are untouched, the UIA identity-match branch logic is unchanged, and only the rendering moved.

### Note: `postMessage("authDone", "*")` (story Decision)

This is still relevant as an informational item and needs no change in this story. The script is unchanged byte for byte. The wildcard target origin means any page that opened the popup gets the constant string `"authDone"`. The message carries no token, session id or user data, and the UIA completion is bound server-side to the session the user authenticated for. The leak is therefore limited to the fact "an SSO UIA step finished". This is the Matrix UIA fallback convention, because the server cannot know the client's origin. It is not counted as a finding. Revisit it only if the message ever carries data.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory
LOW: 1 — advisory

**Verdict:** APPROVED
