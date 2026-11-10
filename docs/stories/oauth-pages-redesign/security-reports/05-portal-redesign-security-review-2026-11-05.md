## Security Review — oauth-pages-redesign / 05-portal-redesign

**Diff scope:** The account portal (`/account`, `/account/apps`) is redesigned on top of the shared `Nebu.Web.PageShell` (wide variant) and the `Nebu.Web.PageText` catalog (`acct.*`, EN/DE). `layout.html.eex` and `device_table.html.eex` are removed. Devices and apps are now cards, and the overview shows tiles with counts (the new consent-grant read in `Account`). The click-proof script now goes through `PageShell.render(script:)`. PageShell CSS has been extended. Tests and e2e steps are also in the diff.
**Date:** 2026-11-05

### Prescan candidates (verified, dismissed)
- `account_pages.ex:164` `Phoenix.HTML.raw(PageShell.status_icon())`: this is a compile-time constant SVG. It is not exploitable.
- `account_pages.ex:404` `Phoenix.HTML.raw(~s(<time ...>))`: it interpolates only `DateTime.to_iso8601/strftime` of an integer timestamp. It is not exploitable.

### Checks performed
- **Escaping of user- and app-claimed values.** Device display names, device IDs, app names (`client_name`), `client_host`, `client_id`, `last_seen_ip`, `keys_fingerprint`, `user_id` and `display_name` are all rendered through `<%= %>` in `Phoenix.HTML.Engine` templates, which auto-escape. `tf/3` does placeholder filling in ONE `Regex.replace` pass with a fn, so a value is never re-scanned, and it returns plain text that the engine escapes afterwards. This holds for the aria-labels (`acct.apps.withdraw_label`, `acct.device.sign_out_label`, `acct.reset.*_label`) too. Values assembled by hand are escaped with `PageShell.esc`: the `<h1>` (which includes the device name on the delete page), the `<title>` (escaped inside `PageShell.render`), the `data-action` value, the who line (`user_id`), the nav labels, the notice texts and the CSRF value in the logout form. The notice code is looked up in `@notices` (unknown code → nothing), and the error code is normalised against `@errors`. The catalog texts contain no markup.
- **CSP.** The style hash is computed from `PageShell.css()`, which is the same `@css` the shell emits in its single `<style>`. The script CSP still uses `ClickProofScript.csp_hash()`. The shell emits `<script>#{ClickProofScript.script()}</script>` byte-identically, now at the end of `<body>`, which still works with its `input[data-click-proof]` selector. `reset_script?/2` is unchanged: the script is only emitted with one request and `fresh`. `img-src 'none'` is still compatible because the icons and logo are inline SVG.
- **Headers.** `put_headers/2` is unchanged (flow headers, Referrer-Policy same-origin, CSP, XFO DENY, text/html).
- **CSRF, freshness, reauth.** Every POST form still carries `csrf_token`, and the approve form still has `_click_proof`. The `fresh` / `no_auth_time` / `reauth_href` gating in the delete and reset templates is unchanged. The server-side handlers in `account.ex` are untouched apart from the overview.
- **Cross-user leakage (new grant read).** `ConsentGrantStore.list_for_user(session.user_id)` is keyed to the authenticated session's user and runs inside the authenticated dispatch. No request-supplied ID is involved. Only the count is rendered on the overview. A storage error degrades to a tile without a count, with no error detail exposed.
- **Logging.** No Logger, IO or inspect calls were added.
- **Language.** `Locale.from_conn` maps to `:en | :de`. `Accept-Language` is never echoed, and `<html lang>` comes from the atom.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/lib/nebu/oauth/account_templates/apps.html.eex (`grants-details`), web/page_text.ex `acct.apps.details` | Safety fact hidden by the UX: "withdrawing an app does NOT sign out already signed-in devices" now sits only in a collapsed `<details>`. The visible note only says the apps may use the account without asking again. | Add one visible sentence about it to `acct.apps.note`, or show it as a success hint after a withdrawal. |

### Detail

**Finding #1 — Withdraw-does-not-sign-out caveat collapsed** [LOW]
A user who withdraws an app they distrust may believe the app has lost access. Its existing device sessions and tokens stay valid until the user signs the device out separately. Before this change, the sentence was visible on the page. Now it is inside a `<details>` element that is closed by default. There is no direct exploit, but it weakens the user's incident response (defense in depth). Fix: keep the caveat visible, for example by appending it to `acct.apps.note` or adding it to the `grant_withdrawn` notice.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory
LOW: 1 — advisory

**Verdict:** APPROVED
