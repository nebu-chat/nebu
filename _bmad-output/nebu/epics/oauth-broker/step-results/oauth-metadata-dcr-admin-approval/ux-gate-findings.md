# UX gate (headless a11y audit) — oauth-registrations admin page
Verdict: BLOCKED on V1 (trivial fix); rest advisory. Files under server/lib/nebu/admin/ (template templates/oauth_registrations/index.html.heex = T, oauth_registrations_html.ex = H, oauth_registrations_controller.ex = C, layouts.ex, router.ex = R).
Passes: HEEx escaping, https-only safe_link + rel noopener noreferrer, logo alt/referrerpolicy/size, table semantics, keyboard/SR, flash roles, nav, CSP scoped to /admin/oauth/registrations only.

## Violation (blocking)
V1. Unbounded client-supplied strings can push Approve/Reject out of view (name up to 255 chars registration.ex:43, client_uri up to 2048 registration.ex:42; DCR is unauthenticated). T:54 name cell lacks break-words; T:56-57 client-URI cell lacks break-all. Fix: break-words on name cell; break-all (+max-w) on client-URI cell/<a>/<span>; consider max-w + break-all on all three; consider leading Actions column.

## Advisories (apply the cheap ones in the fix cycle: A2, A3, A4, A5, A6, A8 partially)
A1. CSP img-src https: wider than needed (R:104-109): admin browser fetches registrant-controlled logo URLs when opening the page (leaks admin IP/UA to registrant, blind GET probe). Options: per-request img-src from exact pending logo origins; server-side logo proxy/cache; "Load logos" opt-in. At minimum document trade-off in ADR-033. -> SECURITY DECISION, hand to Kassandra / user, do not silently change.
A2. Redirect URIs comma-joined (T:59) — ambiguous; render <ul> with one <li class="font-mono break-all"> per URI.
A3. Empty logo cell has no text (add sr-only "No logo"); failed logo load alt text needs overflow-hidden.
A4. Client-name cell as <th scope="row">.
A5. New-tab link: add sr-only "(opens in new tab)"; show host prominently (IDN/userinfo lookalike).
A6. Reason input is placeholder-only: add visible helper text/label ("Reason (optional, max 500)").
A7. Flash generic + focus not managed (existing global gap; include client name in flash at least).
A8. Confirm text shows only name: append client_uri host. Check Registration.clean? strips RTL-override/zero-width/bidi characters from client_name (only redirect_uris confirmed).
A9. Nits: add table-zebra; redundant role="table" matches siblings.
A10. Empty-state/disabled notice OK.
