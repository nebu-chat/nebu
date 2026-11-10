# Epic oauth-pages-redesign Security Review — 2026-11-05

## Scope
- Epic: oauth-pages-redesign (Nebu look for the OAuth, SSO and account portal pages, German/English)
- Base: 697e2cd9378aa4b0367cbd5216399d64ed3c6395
- HEAD: 70b0adf3
- Stories covered: 01-device-naming-chain (595cbfd6), 02-page-shell-and-i18n (b26affeb), 03-consent-page-redesign (95ea37e6), 04-sso-confirm-and-result-pages (8e09a3d1), 05-portal-redesign (5bc13e52), 06-portal-rename-device (70b0adf3)
- Server diff: 48 files (+5366/-880). Main parts: `Nebu.Web.{Locale,PageShell,PageText}`, `Nebu.OAuth.{ConsentPage,Consent,Pages,DeviceName,Authorize,CodeStore,FormPost,TokenRequest,Token}`, account templates, `Nebu.Matrix.{SsoConfirmPage,SsoLogin}`, migration 000062.
- Per-story reports: `docs/stories/oauth-pages-redesign/security-reports/0[1-6]-*-2026-11-05.md` (all APPROVED, 0 CRITICAL/HIGH)

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| 1 | LOW | 01 | server/priv/migrations/000062_oauth_codes_device_display_name.up.sql:7 | No DB-level length bound on `oauth_codes.device_display_name` (the 64-character limit exists only in `DeviceName`) | Open (advisory) |
| 2 | LOW | 03 | server/lib/nebu/oauth/consent_page.ex `details/4` | The "Nebu cannot check which app receives this" caveat for loopback/private-scheme redirects is now only in a collapsed `<details>` | Accepted per design 5.1 |
| 3 | LOW | 04 | server/lib/nebu/matrix/sso_confirm_page.ex `details/2` | The signed-in user id and the redirect path are now only in a collapsed `<details>` | Accepted per design 5.2 |
| 4 | LOW | 05 | account_templates/apps.html.eex, page_text.ex `acct.apps.details` | "Withdrawing an app does not sign out devices" is now only in a collapsed `<details>` | Open (advisory) |
| 5 | LOW | 02/04 | server/lib/nebu/matrix/sso_login.ex `reject_redirect/2` (and every `Locale.from_conn` page) | The response language depends on `Accept-Language`, but no response sends `Vary: Accept-Language`. Every page that can be cached is `no-store`, except the HTML 400 rejection of `reject_redirect`, which has no `Cache-Control`. A shared cache could serve that page in the wrong language. There is no security impact beyond that (constant text, strict CSP with `frame-ancestors 'none'`). | New, advisory: add `cache-control: no-store` to `reject_redirect`'s HTML branch (or `Vary: Accept-Language`) |

## Cross-Story Patterns

- **Free-text form fields (01 → 03 → 06):** `FormPost.parse/2`'s `free_text` list lets control characters through only for exactly `device_name`, and only on two routes: `POST /oauth2/consent` and `POST /account/devices/rename`, which is selected by an exact path match in `account.ex:801`. All other params still pass `clean?/1`. Both consumers go through `DeviceName.typed/1`, which applies a 512-character raw cut, then strips `\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cs}` (this includes the bidi overrides), then a 64-character cut. On the consent route the typed name is bound to the code only when `DeviceName.plan/3 == :ask`, so a forged `device_name` next to a derivable name is dropped. There is no bypass across the stories.
- **Rendering (02 → 06):** all six stories follow one escaping model. The plain-string pages use `PageShell.esc`, and `{placeholder}` filling is a single `Regex.replace` pass with a fn. The account templates use Phoenix.HTML EEx auto-escape, with `tf/3` returning plain text. The CSP hashes are computed from the exact emitted CSS and script. The device names typed in 01 and 06 are shown only through these escaped paths (portal device cards, consent page) and go to Matrix clients as `display_name`. No unescaped sink was found.
- **Authorization (01, 05, 06):** the remembered-consent change in `Authorize.remembered?/3` makes the check stricter: it now also requires a named or derivable device, and it fails closed on an unreadable client. The portal writes are scoped by `session.user_id`, freshness is checked before ownership, and the notice is the same for foreign and unknown device ids. The new routes sit behind the existing `/account*` rate limit.
- **Hidden safety facts (03, 04, 05):** this is systemic. The redesign moves defense-in-depth facts into collapsed `<details>` on three page types: the redirect caveat, the user id and redirect path, and the fact that withdrawing an app does not sign out devices. Each case is LOW, and two are accepted by design. Recommendation for the owner: settle a design rule on which safety facts must stay visible, so later pages don't keep moving them.
- **Locale (02):** `Accept-Language` is bounded (1 KiB, 50 entries) and parsed with anchored regexes. It is never echoed, and there is no cookie or query switch. There is no injection or atom risk, because the result is an enumerated `:de` / `:en` value.

## Migration chain
- 000062 adds a single nullable `TEXT` column to `oauth_codes`. It needs no FK or index (rows are looked up by code hash). The existing table grants and row policies (000041/000055) cover it, and the down migration is symmetric. The column holds user-typed plain text with a 24 h retention, the same as the rest of the code row, and it is not sensitive (it is a device label). See finding #1 for the missing length CHECK.

## Accepted Risks
None required (there are no CRITICAL/HIGH findings). Findings #2 and #3 are LOW and were accepted under design sections 5.1 and 5.2 in the story gates.

## Follow-up Stories Required
None. Optional hardening backlog: #1 (CHECK constraint), #4 (visible withdraw sentence), #5 (`no-store` on the `reject_redirect` HTML branch).

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 5

**Epic security gate:** PASS
