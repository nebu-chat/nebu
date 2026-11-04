# UX/a11y review: persistent-consent-grants (`/account/apps`)

Reviewer: nebu-ux-reviewer (static, no browser/axe run). No blocking violations, 4 MINOR, 6 INFO. T = server/lib/nebu/oauth/account_templates, P = server/lib/nebu/oauth/account_pages.ex.

Verified: one h1; header/nav/main landmarks; table caption + th scope col/row; Withdraw accessible name starts with its visible text (2.5.3); nav aria-current="page"; CSRF field, no-JS; names/host escaped (host plain text, not a link); no tokens/scopes/redirect URIs in markup; focus/contrast/reflow inherited (3px outline, danger #b3261e ~6.5:1, 44px buttons, table stacks <= 40rem); notice roles correct (grant_withdrawn status, grant_not_found alert).

## MINOR
1. T/apps.html.eex:26 Withdraw accessible name not unique when two grants share an app name; add the host: `Withdraw the permission of X (host)`. e2e grantRow filters by name only (steps.ts:135): same ambiguity.
2. T/apps.html.eex:1 wording differs from the consent screen ("Allow this app to use your Matrix account?", consent_page.ex:213); say "apps you have allowed to use your Matrix account".
3. T/apps.html.eex:3 empty state terse; suggest "There are no allowed apps on your account. An app appears here after you allow it when you sign in."
4. P:~153 / P:~307 `<title>` "Allowed apps" vs h1 "Apps you have allowed": make both read "Apps you have allowed".

## INFO
Explanation that withdrawal does not end sessions is plain, always visible, links to Devices; no confirmation step is right; danger styling copies sign-out (defensible); success notice does not name the app (code-keyed notices; same as Devices); consent_grant_store.ex:46 LIMIT 500 truncates silently (Devices prints "N more not shown"); refresh tokens staying valid is not said (accepted limit).

## e2e gaps (MINOR)
Scenario 9 audits axe + 320 px only on the populated list; not checked: Withdraw accessible name, nav aria-current, notice role, explanation note + Devices link, state after withdrawal (notice + empty state) under axe, an already signed-in device staying signed in. Suggest assertions: getByRole('button', {name: /Withdraw the permission of Grant Test App/}), `nav a[aria-current=page]` = "Apps", axe re-run after withdrawal.
