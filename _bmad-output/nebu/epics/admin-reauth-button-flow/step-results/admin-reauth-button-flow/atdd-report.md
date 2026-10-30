# ATDD report: admin-reauth-button-flow

Branch `feature/admin-reauth-button-flow`, worktree `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat-admin-reauth`.
State at the end of this step: failing tests on today's code, `git diff --stat server/lib` empty (checked), reference implementation only as a diff.

## Result in one table

| | count |
|---|---|
| new ExUnit tests (7 files, 186 tests) | 170 fail on today's code, 16 pass (guards of unchanged behaviour: the 13 listed below plus the 3 filter tests of keys that are already masked) |
| amended / added tests in existing files | 14 fail on today's code (hint wording, notice wording, confirm-page hint), all others of those files still pass |
| same 546 tests with the reference implementation | 546 / 546 green |
| mutants (reference implementation, one behaviour changed at a time) | 53 / 53 killed, see `mutation-results.txt` |
| whole `.admin-ci/unit_nodb.sh` (warnings as errors) with the reference implementation | 6861 / 6862 green, the one failure is a timing test of the member slice gate (`member_slice_gate_test.exs:262`, throughput, unrelated) |

## Contract the tests pin (the dev implements against this)

Markup, per form, decided at render time by `Nebu.Admin.Auth.reauth_fresh(conn, <marker path>)`:

* STALE: INSIDE the form `<a href>` with class `btn`, exact text "Sign in again to save" ("... to approve", "... to revoke"), `href` exactly `Nebu.Admin.Auth.reauth_start_path(<marker path>)` (also with a request query string: never from request params), no `onclick`/`target`/`role=button`, `aria-label` absent or containing the visible text, `aria-describedby` resolving to existing unique ids (reauth hint; for claim and role mapping also the lock-out hint). NO submit control with the normal text; the only submit left is "Test Connection" on the storage form (`formaction=".../storage/test-connection"`). Inputs not `disabled`/`readonly`; hidden `_csrf_token` and `_click_proof[data-click-proof]` stay.
* FRESH: the normal submit button with its normal text and `aria-describedby` resolving to the same hint element(s); the hint element (same id as today in both states) holds the validity line: matches `valid`, the remaining whole minutes (`N minutes`, `1 minute` singular, `less than a minute` below 60 s; optional "more") and `one save` (on the confirm pages `one approval|decision|revocation`). No "Sign in again to ..." link inside the form.
* Stale hint reworded: no "If you are asked to sign in again", no "must enter your change again"; says to sign in FIRST (`/sign[ -]?in/` and `/\bfirst\b/`); the storage hint also keeps "access key", "secret key", "never".
* Approve / revoke: the existing `[data-role="reauth-state"]` element (+ `data-reauth="fresh|needed"`) is the hint and gets an `id`; the submit keeps `data-role="approve-confirm"` / `"revoke-confirm"` and (approve) the `aria-label` naming the client, in the FRESH state only; the stale link carries neither `data-role`.
* New read-only accessor `Nebu.Admin.Auth.reauth_remaining_minutes(conn, path) :: {:ok, 0..5} | :stale`: `{:ok, _}` exactly when `reauth_fresh/2` is `{:ok, _}`, value = floor of the remaining minutes of 300 s (`0` = less than a minute), capped at 5, never writes the session.
* Every render path of the pages must carry the state: GET, and the re-renders after a validation error, a refused audit row, the orphan-risk warning, Test Connection answers, the role mapping refusal (200 with the marker kept = fresh).
* Role mapping keeps the inline link "Sign in again, then enter the value once more" (in `p[role=alert][data-field=admin_group_claim]`, href `reauth_start_path(role page)`) next to the refusal error; the form itself is fresh there (marker kept).
* The post-return flash of `reauth_notice/2`: info flash may stay or be shortened; for the four config / media pages it still contains "Signed in again" and "5 minutes" (existing pin); it must not say "not saved yet" / "refused" / "enter it again" / "must enter" (no POST happened); no error flash.
* Server gates, 300 s rule, one marker per page path, consumption unchanged (asserted: expired POST = redirect to `reauth_start_path(page)`, nothing saved or audited, no value in Location or log).

## Tests per scenario and form

Helpers: `server/test/nebu/admin/reauth_button_flow_oauth_test_support.exs` (module `Nebu.Admin.ReauthButtonFlowSupport`; the file name ends in `oauth_test_support.exs` on purpose so that `mix.exs` `test_ignore_filters` ignores it, as for the other support files; loaded by one new line at the end of `server/test/test_helper.exs`).

| file (all in `server/test/nebu/admin/`) | tests | DB | covers |
|---|---|---|---|
| `admin_reauth_remaining_test.exs` | 16 | no | accessor contract (now part of the story Decisions): floors (30 s -> 4, 70 -> 3, 130 -> 2, 190 -> 1, 250 -> 0, 270 -> 0), cap, other page / subject / old shape / expired / far future = `:stale`, agrees with `reauth_fresh/2`, read only |
| `admin_reauth_button_flow_config_test.exs` | 39 | no | forms 1, 2, 3 (`/admin/config`, shared marker): scenarios 1 - 5, scopes and refresh mode plain in every state, consumption after SSO schemes / origins / OAuth switch saves through the real session cookie, re-renders (validation error, rejected scopes, bad refresh mode), expiry per form with canaries, query string never reaches the link, no values in links and logs |
| `admin_reauth_button_flow_mappings_test.exs` | 21 | no | forms 4, 5: stale / fresh / floors, both hints in describedby, validation error and refused audit re-render, role mapping inline link (not in token, marker without fingerprint, no link for empty / universal values), consumption, expiry with canaries |
| `admin_reauth_button_flow_media_test.exs` | 29 | no | forms 6, 7 (shared marker): stale / fresh / floors, consumption after policy and storage saves, re-renders (policy error, storage error, orphan warning), Test Connection plain submit with its formaction and its answer page in the state of the marker (no marker, fresh, foreign marker), storage hint keeps "secret key never filled", expiry with canaries (incl. secret_key), other markers |
| `admin_reauth_button_flow_cross_page_test.exs` | 47 | no | scenario 5 as a matrix: 4 pages x 11 marker paths (own = fresh, every other = stale), shared-marker pages change as one unit (3 forms / 2 forms), links always carry only their own page path |
| `admin_reauth_button_flow_confirm_test.exs` | 20 | yes (`@moduletag :integration`) | forms 8, 9: link / submit, hooks (`data-role`, `data-reauth`, `aria-label`, help ids), other client / action / page / subject / expired markers, floors, consumption (cookie without marker), wrong typed host keeps the marker and the next page is fresh, expiry with canaries (reason, host) |
| `admin_reauth_button_flow_filter_parameters_test.exs` | 14 | no | `config :phoenix, filter_parameters` masks every sensitive field name of the 9 forms (12 names) and still masks the existing keys, through `Phoenix.Logger.filter_values/2` with the real app config (failure message names `filter_parameters`); works for a deny-list and for `{:keep, ...}` |
| `admin_reauth_test.exs` (existing file, new describe) | +7 | no | notice after the return from the sign-in for the 4 config / media pages and the 2 confirm pages: no refusal wording, no error flash; 4 pages still say "Signed in again" / "5 minutes" |

Scenario map: 1 stale link = the "stale" describes of every file; 2 fresh button + line = the "fresh" describes; 3 link comes back = "consumption" describes (config, mappings, media, confirm); 4 expired = "expires" / "expiry" describes; 5 other page = scenario-5 describes and the cross-page matrix.

Passing on today's code (13, guards of behaviour that must not change): scopes / refresh mode plain submits (config), inputs editable (config and media storage), secret key never pre-filled, "no sign-in link on a fresh page" (2, only meaningful with the implementation), "rendering the page logs nothing", claim / role mapping lock-out warning and ids, approve / revoke hooks and typed-host inputs, approve / revoke consumption (2).

## Why each group fails on today's code

* `reauth_remaining_minutes/2` undefined: all 16 accessor tests.
* Stale tests (link): "exactly one link with the text ... inside the form (found 0)": today the page has the submit and the old hint.
* Fresh tests: the hint is the old sentence "Saving this setting needs a fresh sign-in. If you are asked to sign in again ...": "the line says the sign-in is valid" fails (no validity line, no minutes).
* Cross-page matrix, shared-marker and consumption tests: the same two reasons.
* Expiry tests: fail at their first step (the fresh render has no validity line). The refused POST itself (redirect, nothing saved) already behaves as required today.
* Notice tests (`admin_reauth_test.exs`): `reauth_notice/2` still says "Your change was not saved yet: enter it again ...".

## Existing tests and e2e files amended (minimal, no coverage deleted)

Server (each amendment renders the page with a fresh marker where the old test looked for the submit, or follows the new hint wording):

* `config_sso_trust_hardening_test.exs` AC4: page rendered with a marker; hint match `Your fresh sign-in is valid for` instead of the old sentence.
* `config_controller_sso_origins_test.exs`: helper `get_config/1` puts a marker bound to `/admin/config` (button "Save SSO origins" exists only fresh).
* `config_privileged_forms_sweep_test.exs` AC4 (claim and role mapping): `with_marker(path)`; hint match `Your fresh sign-in is valid for`.
* `config_oauth_switch_test.exs`: new helper `fresh_page/1` for the two tests that look at `button[type=submit]`; hint match as above.
* `admin_media_settings_gate_test.exs` UX B1: checks BOTH states (stale: link, "sign in again first", "secret key"; fresh: button, "valid for").
* `oauth/oauth_admin_clients_test.exs`: approve page test and revoke confirm page test use `fresh_admin_conn`; revoke "re-auth notice" test: text pin relaxed to `type the host and the reason`, Cancel-before-submit order checked on the fresh page.
* `admin_reauth_test.exs`: 3 notice tests changed from "Your change was not saved yet / enter it again / secret key" to "Signed in again", refute the old wording (the "secret key" statement moved to the storage hint, pinned in the media test), "5 minutes" kept.

E2E (static only, cannot run here): `bddgen` (generates all features, no missing / duplicate steps) and `tsc --noEmit` run clean on a copy of `e2e/` in a `node:20-alpine` container (`npm ci`; nothing written to the worktree).

* `e2e/fixtures/oauth-admin.ts`: new `signInAgainLink(scope, action)`; `submitWithAdminReauth` (approve / revoke), `saveConfigFormWithAdminReauth` (SSO origins, schemes, legacy-SSO steps) and `saveMappingFormWithAdminReauth` (claim mapping, role mapping, media settings) now click the "Sign in again to ..." link first, sign in at Dex, come back, type the form, then press the submit. The old "POST refused, redirect to the sign-in" round trip stays as a fallback (marker expired meanwhile). `revokeThroughConfirmPage` types AFTER the sign-in.
* `e2e/step-definitions/admin/oauth-switch.steps.ts`: `saveWithAdminReauth` (also used by the After hook) with the link first; the "section shows ... button" step accepts the button or the link; 4 new steps for the new scenario.
* `e2e/step-definitions/admin/sso-redirect-origins.steps.ts`: step "the {string} button is described by the fresh sign-in hint" replaced by "the {string} form control is described by the sign-in hint" (button or link; maps the three save buttons to their forms). Features `sso_redirect_origins.feature` (2 lines) and `oauth-switch.feature` (1 line) renamed accordingly.
* `e2e/step-definitions/admin/oauth-client-revocation.steps.ts`: keyboard-only revoke: Tab to the link, Enter, sign in, then type host and reason and Enter in the form.
* New cheap scenario `@reauth-button` in `e2e/features/admin/oauth-switch.feature` (OAuth switch on `/admin/config`: link with href and describedby, follow it and sign in, button appears, validity line).
* Not touched: `e2e/step-definitions/oauth/oauth-account-management.steps.ts` (the OAuth ACCOUNT pages under `/account`, a different re-auth flow, no marker-gated admin form) and `claim-mapping.steps.ts`, `role-mapping.steps.ts`, `media-settings-gate.steps.ts`, `media-config-damaged.steps.ts`, `sso-schemes.steps.ts`, `legacy-sso-redirect-confirmation.steps.ts`, `oauth-client-approvals.steps.ts` (they go through the shared helpers above).
* CI gate must run: `@oauth-switch` (incl. `@reauth-button`), claim-mapping, role-mapping, media-settings-gate, media-config-damaged, sso_schemes, sso_redirect_origins, legacy-sso-redirect-confirmation, oauth-client-approvals, oauth-client-revocation (keyboard scenario).

## Reference implementation (throwaway, not left in the tree)

`reference-impl.diff` (applies cleanly with `git apply` on today's code; 22 files, 478 lines, unchanged by the fix pass): `Auth.reauth_remaining_minutes/2`, `OAuthAdminHelpers.assign_reauth/2` (assign `:reauth` = `%{fresh?, minutes, href}`), new function component module `Nebu.Admin.ReauthComponents` (`reauth_hint`, `reauth_control`), the pipe in every render path of the 6 controllers, the 6 templates, `reauth_notice/2` wording, and `config/config.exs` (`filter_parameters`, see open point 1). `mutation-results.txt`: 53 mutants (link text, href, always link, always submit, link and submit, wrong marker path on each page, missing assign on a re-render path, validity line, one save, singular, floor vs ceil, off by one, consumption missing, scopes / refresh / Test Connection turned into links, id removed, describedby removed from link and from submit, lock-out hint dropped, old hint wording, any-marker-unlocks, href from request params, `data-role` on the link, inline role link removed, accessor returns a number for stale, `aria-label` / `data-role` / `data-reauth` / id removed, readonly inputs, no `btn` class, click proof field dropped, old notice text, plus the fix-pass mutants listed in the section below), all killed.

## How to run

```
cd /Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat-admin-reauth
.admin-ci/quick.sh "mix test --include integration \
  test/nebu/admin/admin_reauth_remaining_test.exs test/nebu/admin/admin_reauth_button_flow_config_test.exs \
  test/nebu/admin/admin_reauth_button_flow_mappings_test.exs test/nebu/admin/admin_reauth_button_flow_media_test.exs \
  test/nebu/admin/admin_reauth_button_flow_cross_page_test.exs test/nebu/admin/admin_reauth_button_flow_confirm_test.exs \
  test/nebu/admin/admin_reauth_test.exs test/nebu/admin/config_sso_trust_hardening_test.exs \
  test/nebu/admin/config_controller_sso_origins_test.exs test/nebu/admin/config_privileged_forms_sweep_test.exs \
  test/nebu/admin/config_oauth_switch_test.exs test/nebu/admin/admin_media_settings_gate_test.exs \
  test/nebu/oauth/oauth_admin_clients_test.exs"
```
(only the confirm file needs the DB, the rest runs in `.admin-ci/unit_nodb.sh`). Test names stay below 200 characters (checked by script, also for `for`-generated names by hand). To use the reference: `git apply <this dir>/reference-impl.diff`.

## Open points for the dev

1. **(now a story Decision, tested directly) Form values reach the DEBUG log today (Kassandra-relevant).** `Phoenix.Logger` prints `Parameters: %{...}` of every controller action at `:debug`, even when the gate halts; `config :phoenix, filter_parameters` only lists `password, reason, confirm_host, _csrf_token, csrf_token`. So the SSO schemes / origins, OAuth issuer URL, claim names, the role mapping value, the media webhook URL and the storage `access_key` / `secret_key` are logged in clear at `:debug` (dev and any instance run at debug). The expiry and "no value in logs" tests capture at `:debug` as the task demands and will only go green once these keys are filtered. The reference diff extends the list in `server/config/config.exs` (`access_key, secret_key, webhook_url, sso_extra_redirect_schemes, sso_redirect_allowed_origins, oauth_issuer_url, oidc_user_id_claim, oidc_displayname_claim, oidc_email_claim, admin_group_claim`); a `{:keep, [...]}` list would be safer against future fields.
2. Stale state and the Enter key: the SSO origins and SSO schemes forms have ONE text input, so a browser still submits the form on Enter without any submit button; on the storage form the first submit button is "Test Connection", so Enter there runs a test connection (a `:click` gate form) instead of saving. Server gates are unchanged (the POST is refused and redirected to the sign-in, nothing is replayed), so this is a UX question for the UX review, not pinned by a test.
3. Approve / revoke: the `reauth-state` element needs an `id` and, fresh, the validity line; the reference uses `id="reauth-state"` and keeps `@reauth_fresh` next to the new `@reauth` assign.
4. Role mapping: the story says the existing `reauth_link` assign is unified with the new pattern; the tests only pin the markup (inline link in the refusal alert + primary state), the reference leaves `@reauth_link` as is.
5. Every render path must assign the state (6 controllers, 9 render sites: media has one `render_settings/3`, config one `render_config/1`, claim mapping 3, role mapping 2, approve / revoke 1 each); the tests cover GET, validation re-renders, refused-audit re-renders, orphan warning, Test Connection answers and the role refusal.
6. `reauth_notice/2` wording: the reference uses "Signed in again. You can now enter your change and press Save. Your sign-in is valid for 5 minutes and for one save." (media / config pages) and "... stays valid for 5 minutes." (claim / role).
7. The hint wording is pinned by key phrases only (see contract); the dev may reword freely inside them.
8. Docs: the deployment guide and the e2e feature comments still describe the old "POST refused, redirect, enter again" flow in places (not tested, `docs/architecture/07-deployment.md` "Admin configuration forms and their protection").
9. Unrelated failures seen when running whole `test/nebu/admin` + `test/nebu/oauth` against the shared throwaway DB (identical on today's code, verified): `TemporaryCaptureManagerTest` (2), `TraceMapNodeControlsTest` (1), `RoomsFallbackNameTest` (12), `WarRoomTest` (2). Not caused by this story.
10. The throwaway container `nebu-reauth-pg` was removed at the end of this step (`docker rm -fv`); `quick.sh` recreates and migrates it on the next run (about 10 s more).

## Fix pass after the test review (0 MAJOR, 12 MINOR, all addressed)

| finding | change |
|---|---|
| m-A no replay / prefill | new helper `assert_no_replay!/4` (support): after every refused expired-marker POST (config x3, claim, role, media x2, approve, revoke) the session and flash hold no canary, the next page (followed through the cookie when the refusal set one) renders no canary and no flash about a refused change. Mutants M50 (form stored in the session) and M51 (refusal flash) |
| m-B keyboard / visibility | `assert_stale!` refutes `tabindex="-1"`, `aria-disabled`, `hidden` and hidden / `sr-only` / `invisible` classes on the link; `assert_fresh_hint!` refutes a hidden validity line. Mutants M46, M47, M48 |
| M5 orphan test | asserts the real warning (`div.alert-error` with "does not migrate existing objects" and the count) and the acknowledgement checkbox, then both forms fresh. Mutant M43 (orphan render path without state) |
| M6 over-pinned wording | `\bvalid\b` instead of "Your fresh sign-in is valid for" in the 4 amended tests; "first" OR "before" in the helper and the media gate test |
| M7 accessor | kept (16 tests), now in the story Decisions |
| M8 `assert_plain_submit!` | checks for the absence of `[id$=-reauth-hint]` / `[data-role=reauth-state]` elements instead of whole-form text. Mutant M53 |
| M9 isolation | `T.put_env_scoped(:admin_csrf_bypass, true)` in all 5 new files (prior value restored); the stale `delete_env` lists lost the key |
| M10 confirm hint | `assert_stale_hint!` for approve / revoke: says to sign in first (first|before) and refutes `type ... again`; `oauth_admin_clients_test` revoke notice now asserts `\bfirst\b` and refutes `type ... again` (replaces the relaxed pin). Mutants M49, M52 |
| M14 canaries / filter | claim mapping canaries in all three fields (also in the log and the no-replay check); direct filter test file (above). Reference keeps the DENY-LIST (a `{:keep}` list would blank every other Phoenix controller's debug parameters, e.g. the media and room forms, for no gain here); mutants M44, M45 |
| INFO 290 s | the "less than a minute" checks use 270 s (accessor, config, media) |

E2E (static; `tsc --noEmit` and `bddgen` clean on a container copy):

* M11: `SubmitOutcome.viaLink`; `fixtures/oauth-admin.ts` keeps a per-page record of known fresh markers (`markerKnown` / `rememberMarker` / `forgetMarker`, set by a sign-in through the link, cleared by a consuming save). Without a known marker the three helpers FAIL when the link is missing, and a refused POST right after a sign-in through the link fails; the redirect fallback is only taken when a marker was known. The steps `claim-mapping`, `role-mapping`, `media-settings-gate` and the approve step of `oauth-client-revocation` assert `viaLink`; the OAuth switch save (`oauth-switch.steps.ts`) enforces the same, the `@oauth-switch` After hook is tolerant (state unknown after a failure). The keyboard-only revoke now REQUIRES the link (and no submit before the sign-in).
* M12: new `@reauth-button` scenarios: approve confirm page and revoke confirm page (link, href, describedby, then button + validity line + `data-reauth=fresh`) in `oauth-client-revocation.feature`; "after a successful save the link comes back" and "a fresh sign-in for another page does not unlock the OAuth form (scopes / refresh mode plain)" in `oauth-switch.feature`. New steps in `oauth-client-revocation.steps.ts` and `oauth-switch.steps.ts`.
* M13: the shared hint step tells the states apart (link: hint says first / before and no submit; submit: hint says valid and the minutes).

Files amended in this pass: `reauth_button_flow_oauth_test_support.exs`, `admin_reauth_remaining_test.exs`, `admin_reauth_button_flow_{config,mappings,media,cross_page,confirm}_test.exs`, new `admin_reauth_button_flow_filter_parameters_test.exs`, `config_sso_trust_hardening_test.exs`, `config_privileged_forms_sweep_test.exs`, `config_oauth_switch_test.exs`, `admin_media_settings_gate_test.exs`, `oauth/oauth_admin_clients_test.exs`, `admin_reauth_test.exs` (shorter names); e2e `fixtures/oauth-admin.ts`, `step-definitions/admin/{claim-mapping,role-mapping,media-settings-gate,oauth-client-revocation,oauth-switch,sso-redirect-origins}.steps.ts`, `features/admin/{oauth-client-revocation,oauth-switch}.feature`.
