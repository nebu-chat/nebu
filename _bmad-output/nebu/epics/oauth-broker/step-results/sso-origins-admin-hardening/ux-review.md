# UX gate: sso-origins-admin-hardening (nebu-ux-reviewer, static, 2026-10-14)

1 BLOCKING, 5 NON-BLOCKING.
BLOCKING
- B1 After the re-authentication round trip the admin lands on `/admin/config` with the stored value and NO message: the save did not happen, the typed text is gone and nothing says so (WCAG 3.3.1 / 3.3.4 / 4.1.3 in spirit). Fix: info flash for `return_to == "/admin/config"` only ("Signed in again. Your change was not saved yet: enter it again and press Save. ..."), and a specific hint sentence in both forms ("Saving this setting needs a fresh sign-in. If you are asked to sign in again, you return to this page and must enter your change again.").
NON-BLOCKING: N2 the 403 page text talked about a "confirmation page" / a CLI revoke (config has none): neutral wording, CLI sentence only for `/admin/oauth` back paths; N3 the sidebar highlighted "OAuth" on a refusal of `/admin/config` (use `config-general`); N4 aria-describedby wiring correct, styling nit only; N5 focus / announcement after the redirect same as existing pattern (no regression); N6 the back link cannot keep typed text (covered by the hint).
Applied in cycle 1: B1, N2, N3 (plus the log prefix `admin:` instead of `OAuth admin:`); N4-N6 left.
