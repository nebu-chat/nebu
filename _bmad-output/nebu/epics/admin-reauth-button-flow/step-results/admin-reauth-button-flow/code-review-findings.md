# Code review (cycle 0): admin-reauth-button-flow

Reviewer: nebu-code-reviewer (read-only). 0 MAJOR, 4 MINOR, 8 INFO. All 5 Gherkin scenarios covered, server gates unchanged in behaviour.

Verified correct: all 9 forms on 7 pages assign `@reauth` on every render path; no leftover `@reauth_fresh` / `@page_reauth` / `@reauth_link` in lib/ or templates; gate/3, reauth_fresh/2, consume_reauth/1, reauth_role_check/2 untouched; role-mapping refactor behaviour-neutral; `reauth_remaining_minutes/2` correct (floor, cap, malformed marker, no session write); href only from server-side path; HEEx escaping; aria-describedby ids resolve and are unique; filter_parameters deny-list (substring match, recursive, old keys kept).

## MINOR
- MINOR-1 docs/architecture/07-deployment.md:23: Enter-key sentence names only SSO schemes/origins; the OAuth switch (issuer) and role mapping (admin_group_claim) also have exactly one text field and submit implicitly when stale. List all or say "forms with one text field".
- MINOR-2 07-deployment.md:23 and story AC4 overclaim the log masking: storage endpoint/iam_endpoint/sts_endpoint/bucket/archive_bucket/region/s3_key_prefix_template/confirm_orphan_risk/use_ssl, media numeric limits, oauth_enabled/oauth_activation_ack stay unmasked. Config, not secrets, but an endpoint with URL userinfo would leak; no userinfo rejection found. Check deliberately; soften the wording or mask specific names.
- MINOR-3 reauth_components.ex:20-26: the "access key and secret key are never filled in ... Test Connection needs no new sign-in" sentence is rendered only in the STALE branch; render it in both.
- MINOR-4 the stale hint does not say typed input is lost; add a clause and pin it.

## INFO
1. approve stale link has no aria-label naming the client (by design).
2. revoke stale link uses btn-error; neutral class preferable for the stale state.
3. Stale prose: role_mapping_self_lockout_test.exs:515 old flash text fixture; admin_reauth_button_flow_confirm_test.exs:4 moduledoc mentions @reauth_fresh; story lines ~27 and ~86 still say @page_reauth.
4. auth.ex:112-119 / :125-132 near-identical reauth_notice clauses (not worth a cycle).
5. Role mapping renders fresh for a marker without fingerprint, the save is refused again with the inline link (pinned).
6. Enter on single-input stale forms still POSTs and is refused (accepted trade-off).
7. reauth_components.ex clean.
8. Post-sign-in flash and validity line say nearly the same (acceptable).

Side effect: the reviewer wrote a memory file under the main checkout `.claude/agent-memory/` (git-ignored, harmless).
