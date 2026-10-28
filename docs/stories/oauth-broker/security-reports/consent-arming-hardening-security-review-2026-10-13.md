# Security Review: consent-arming-hardening (epic SEC gate 3 finding G3-5), 2026-10-13

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator. Scope: staged diff of the story (the OAuth consent page uses the shared hash-pinned `Nebu.Web.ArmScript`; Allow `disabled` -> `aria-disabled` + `data-arm` + `form="oauth-consent-armed"`; notices get ids; the script derives the button name from its text).

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 LOW, 3 INFO). Approved.**

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| 1 | LOW | docs said G3-5 is "closed for mouse / pen": too strong. The travel rule stops a lure where the pointer stays parked on Allow; a moving-target "click game" (a click on target A opens the consent popup sized so that Allow sits where target B will be; the victim's hand is already moving, so only the 600 ms dwell remains) still works | fixed: wording is "reduced, closed for parked-pointer double-click and multi-gesture lures"; the moving-target lure is an accepted residual (ADR-033 FR21, 07-deployment group C, follow-up `cp`) |
| 2 | INFO | Allow is now focusable (`id="allow"`): an inherited `#allow` fragment can focus it on load; neutralised (focus before arming does not count, `arm()` resets `focused`, Enter needs a new focus event, COOP stops opener re-navigation) | regression test added |
| 3 | INFO | hint says "scroll", the script no longer arms on scroll alone (wheel / keydown / touch still do): no security impact | hint reworded |
| 4 | INFO | COOP `same-origin` kept: popup-based OAuth web clients lose `window.opener` (function, not security) | follow-up `cr`, group C |

Verified: no path to the server while Allow is unarmed (no form owner, capture-phase `preventDefault`, no text input for implicit submission, Deny is the first submit button); CSP script hash computed from the same bytes that are embedded, no inline handlers; the button name is a static literal flowing only into `textContent`; CSRF, cookie, single use, fetch metadata and headers are not in the diff; same-origin scripted `.click()` / `requestSubmit` remains the accepted SO7 residual; docs state the touch, keyboard-with-pauses and popup residuals.
