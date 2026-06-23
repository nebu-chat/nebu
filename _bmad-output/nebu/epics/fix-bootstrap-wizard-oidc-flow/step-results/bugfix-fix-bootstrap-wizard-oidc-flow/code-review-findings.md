# Code-review — fix-bootstrap-wizard-oidc-flow — cycle 0
Verdict: BLOCKED — 1 CRITICAL.

## C1 (CRITICAL) — claim-value injection on confirm
auth.ex ~331-333: `selected = params["admin_group_claim"]` is written verbatim to server_config.admin_group_claim (the org-wide admin gate) WITHOUT validating it against the discovered claims of the verified token. bootstrap_callback stashes only bootstrap_sub/bootstrap_email, NOT the discovered claim values, so confirm has nothing to validate against and doesn't try. An operator/anyone driving the POST while bootstrap incomplete can set the admin gate to any string. No test covers rejecting an out-of-token value during incomplete bootstrap.
FIX: in bootstrap_callback, stash the verified token's discovered claim values server-side (e.g. put_draft("bootstrap_claims", Jason.encode!(extract_discovered_claims(claims)))). In bootstrap_confirm_claim, reject (→/admin/login?error=auth_failed or 400) any `selected` not in that stashed set. Add a test: incomplete bootstrap + out-of-token admin_group_claim value → rejected, no config write. Mirror Go ClaimSelectionHandler (select from discovered list, not free-form).

## Passed (do not regress): AC5 inert-after-complete (4 entry points fail-closed), token verify shared (no weaker path), seams test-only, XSS-escaped, CSRF, no open redirect, secret encrypted at rest.

## MINOR
M1: complete_bootstrap does N sequential upserts, not a single tx (docstring/story say "single tx"). Wrap in Ecto.Adapters.SQL.transaction or soften wording.
M2: select_claim_page docstring about admin gate re-applying is misleading (route is outside live_session; self-redirect at :381 is correct).
