# UX review (cycle 0): session-lifetime-setting

Reviewer: nebu-ux-reviewer (read-only). 0 BLOCKING, 7 MINOR, 5 INFO. Faithful copy of the OAuth switch / SSO origins pattern; label, aria-invalid, role=alert placement, contrast, button flow, input type (text + inputmode numeric, no min/max) are fine.

## MINOR (suggested single change set M1-M5; no contract/route/validation change)
- M1 template 319-325: a refused save re-renders at the top; add `autofocus={@lifetime_error != nil}` on the input (precedent role_mapping/index.html.heex:33).
- M2 `aria-describedby` order: error first (`session-lifetime-error session-lifetime-help`) when there is an error.
- M3 help block too long and mixes two concerns: keep range/units/fallback in `#session-lifetime-help`; move the "existing sessions" paragraph out of the describedby block, `text-sm` (precedent OAuth section ~229-233).
- M4 seconds-only field: add a "Common values: 3600 (1 hour), 28800 (8 hours), 86400 (1 day), 604800 (7 days), 2592000 (30 days)" sentence. No unit selector in this story (follow-up).
- M5 reword the hint in short sentences: "A session ends this long after sign-in, even if it is still in use. Renewing the token does not make it longer. A change applies to new sign-ins only. Sessions created through the OAuth login keep the lifetime they started with. Sessions from the legacy login store no end date. They use the current setting when they are renewed, so a shorter value can end them earlier than before." The success flash must say "Existing OAuth sessions keep their lifetime." (legacy sessions follow the setting).
- M6 (optional) "Current lifetime" does not say whether default/env/saved.
- M7 Enter key in stale state posts and is refused by the gate: accepted (same as other gated forms), do not disable the field.

## INFO
I1 success flash is above the scrolled section (page-wide, separate story); I2 intro could link #session-lifetime; I3 add `break-words` to the help block (long env var in <code>); I4 lifetime_text fine; I5 heading hierarchy fine.
