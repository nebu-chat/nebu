---
name: with-extra-variant-drops-trust-boundary
description: A refactor that extracts a *_with_extra/N variant taking a caller-supplied value drops the reader-seam/server_config trust boundary the original enforced; safe by single call site, but widens surface — check it fail-closes rather than trusting the writer
metadata:
  type: feedback
---

Pattern seen in bugfix-bootstrap-scope-ignored: `OidcScopes.resolve_scope/1` could only read operator-controlled, write-validated values through the reader seam / `server_config`. The fix added a public `resolve_scope_with_extra/2` that takes the extra-scopes value as an explicit argument (so bootstrap can source it from the in-progress `bootstrap_draft`, which `server_config` doesn't have yet mid-wizard). Correct for the fix, but the new function will now compose from ANY string a caller passes.

**Why:** These `*_with_extra` variants are safe today only because their single call site passes a value that was validated at WRITE time (here: `bootstrap_controller.ex#save_step3/2` -> `validate_scope_string/1`). Safety-by-convention, not by-construction. A future direct-DB write, migration, or careless caller re-opens the input-validation gap the seam used to close (CWE-20 / CWE-710).

**How to apply:** When a diff introduces a `_with_extra`/`_with_override`/explicit-arg twin of a function that previously read from a validated seam/config, flag it. Grade LOW when (a) the outbound boundary neutralizes injection AND (b) the value only affects the actor's own token/no cross-boundary escalation. Recommended remediation is fail-closed validation INSIDE the new function (covers all present+future callers at once), not just a test on today's call site. See also [[safety_cap_at_consumer_not_api]] (same shape: protection enforced at one consumer, not the shared boundary) and [[oidc_scopes_law_note]] if present.

**Adjacent reassurance for OIDC scope specifically:** the outbound authorize URL is built with `URI.encode_query` (auth.ex), which percent-encodes the whole `scope=` value — no `&`/`=`/`#`/space/newline query-string smuggling is possible regardless of upstream validation. So scope-composition injection findings are almost always LOW/defense-in-depth, not HIGH.
