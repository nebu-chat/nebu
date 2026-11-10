## Security Review — oauth-pages-redesign / 02-page-shell-and-i18n

**Diff scope:** staged diff under server/ and e2e/: `Nebu.OAuth.Pages` refactor onto the new
`Nebu.Web.PageShell` (frame, single inline style, CSP), `Nebu.Web.PageText` (en/de catalog),
`Nebu.Web.Locale` (Accept-Language parsing), plus unit and E2E tests.
**Date:** 2026-11-05

### Findings

No security issues found.

### Verified areas

- **Accept-Language parsing (DoS/ReDoS):** the joined header values are cut to 1 KiB and the
  partial last entry is dropped before splitting, then capped at 50 entries. Bandit already bounds
  each header. `@tag_re` (`[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*`) has a literal `-` at the start of
  each repetition, so it cannot backtrack catastrophically. `@q_re` is anchored and bounded. Invalid
  UTF-8 does not raise (checked: `String.trim`/`String.split` on non-UTF-8 bytes return normally).
  `String.to_integer` only receives `[01]` and at most 3 ASCII digits. Any parse failure falls back
  to `:en`, so nothing can crash.
- **No echo:** the parser returns only the atoms `:en` or `:de`. Only that atom reaches
  `<html lang="…">`. No header value goes into the body, the headers or a log.
- **Request-derived host:** `client_host` is only rendered for `client_pending` and
  `client_rejected`, and it passes through `PageShell.esc/1` (`Plug.HTML.html_escape`) inside a text
  node. Catalog texts and `<title>` are escaped too. Before this change, the action texts were
  inserted unescaped, so this is a small hardening.
- **Attribute injection:** an unknown `error_code` is normalised to `server_error` before
  `data-error` is built, so `main_attrs` only ever holds compile-time map keys.
- **CSP:** same structure as before: `default-src 'none'`, one `style-src` SHA-256 computed at
  compile time over exactly the bytes in `<style>`, `base-uri`/`form-action`/`frame-ancestors 'none'`.
  There are no external resources, no webfont fetch (the font stack falls back to local fonts), no
  `style=` attributes and no scripts. The SVGs are inline. The policy is no looser than before.
- **Header handling:** `put_flow_headers/1` is unchanged (no-store, no-cache, no-referrer, CORS
  headers removed). `X-Frame-Options: DENY` is kept. `retry-after` and `allow` come from server
  options, not from the request. There is no `Vary: Accept-Language`, which is harmless because
  responses are `no-store`.
- **Catalog integrity:** a missing key in either language fails at compile time, so a page can
  never render blank. `fetch!/2` raises only on keys hard-coded in the code, never on request data.
- **E2E/test files:** test-only code with no production attack surface.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED
