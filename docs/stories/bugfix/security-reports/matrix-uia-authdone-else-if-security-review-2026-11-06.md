## Security Review — matrix-uia-authdone-else-if

**Diff scope:** `server/lib/nebu/matrix/sso_login.ex` (`@uia_script` is now the Matrix v1.18 UIA fallback script in the spec's `if … else if …` form, plus a docstring update). Also: unit tests (`uia_authdone_else_if_test.exs`, `sso_confirm_and_result_pages_test.exs`), the e2e feature and steps, and the story file.
**Date:** 2026-11-06

### Findings

No security issues found.

### Review notes

- **Script/CSP integrity:** `@uia_script` is a compile-time module attribute made only of literals. `@uia_csp = PageShell.csp_with_script(@uia_script)` hashes the same text at compile time. `PageShell.render/2` puts that exact text between `<script>` tags, so the hash always matches what is rendered. Nothing from the request reaches the script or the CSP: `send_uia_result/2` uses only the catalog texts (escaped with `esc/1`) and the locale from the conn.
- **Else-if and UIA flow:** `complete_uia/3` runs `Nebu.Matrix.Uia.complete/2` before it renders anything, and the `:complete` page is only rendered on `{:ok, _}`. The page script only tells the client that the step is done; it does not decide anything. Firing exactly one notification path (`onAuthDone` when the client defines it, otherwise `postMessage`) cannot skip, repeat or weaken the server-side stage completion. The mismatch path is unchanged: 403, no script, strict CSP.
- **postMessage("authDone", "*"):** the spec prescribes this, the payload is a constant with no secret in it, and the receiving client checks `ev.origin`. This was accepted before and is unchanged.
- **Headers:** `frame-ancestors 'none'`, `no-store` and no COOP (popup clients need `window.opener`) are unchanged.
- **Prescan:** 0 candidates; no path trigger.
- **Logging:** no new log calls; the existing mismatch warning has no PII.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED
