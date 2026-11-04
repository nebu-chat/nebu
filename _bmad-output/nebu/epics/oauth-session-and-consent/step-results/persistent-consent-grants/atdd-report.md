# ATDD report - persistent-consent-grants (epic oauth-session-and-consent, REQ-2026-003)

State left in the worktree: RED tests only (lib, migrations, config, docs, CHANGELOG reverted to the committed state; nothing committed). Kept: tests, test support,
e2e feature + steps + `e2e/fixtures/db.ts`, the story file `## Decisions` addendum, these step results.
Proof of meaning: `reference-impl.diff` (throwaway: migration 000057, store, authorize / consent / account / revocation / erasure changes, docs; NOT applied) turns everything green;
`mutation-results.txt`: 68 mutants, 68 killed (one test gap found and closed: ADR pointer).

## Numbers

| run | red (no reference) | green (with reference) |
|---|---|---|
| 8 NEW story files, `--include integration` (fresh DB without 000057) | 168 failed / 171 (3 pass: static "earlier migrations untouched" style guards) | 171 passed |
| 6 MODIFIED/affected compliance + consent-flow files | 58 failed / 176 | 272 passed (with the whole compliance dir) |
| `.session-ci/unit_nodb.sh` (full no-DB suite, warnings as errors, Elixir 1.20) | 49 failed / 7049, no warning, no compile abort | 7049 passed, 7 skipped, exit 0 |
| `test/nebu/{oauth,compliance,migration,admin,web,matrix/session}` `--include integration`, with reference | - | 6111 of 6135; the 24 failures are the known unrelated families (rooms fallback, temporary capture, log retention, trace map, war room, admin oidc login), identical without the story. One of three full runs also showed 4 extra failures (2 of the new account tests that sign in through the real IdP stub, plus `OAuthAccountReviewTest`, `OAuthTokenCodeGrantTest`); they passed in isolation (6 seeds) and in the next full run: load flake, tell the dev to watch it |

## Files

New (server/test): `oauth/consent_grant_oauth_test_support.exs` (helpers; name ends in `oauth_test_support.exs`, required from `test_helper.exs`, no mix.exs change),
`oauth/consent_grant_scope_test.exs` (pure: `normalize_scope/1`, `covers?/2`, `AuthorizeRequest.validate` `force_consent`), `oauth/consent_grant_store_test.exs` (upsert, skip statement, list, withdraw, concurrency, unreadable table),
`oauth/consent_grant_flow_test.exs` (scenarios 1-5, 7 through the real flow incl. token redemption, code binding, hardening, logs), `oauth/consent_grant_revocation_test.exs` (scenario 6),
`oauth/consent_grant_account_test.exs` (scenario 9, page, withdraw, CSRF), `oauth/consent_grant_erasure_test.exs` (scenario 8), `oauth/consent_grant_docs_test.exs`, `migration/000057_oauth_consent_grants_test.exs`.
New (e2e): `features/oauth/oauth-consent-grants.feature` (3 scenarios: 1, 2, 9; tag `@oauth-consent-grants`), `step-definitions/oauth/oauth-consent-grants.steps.ts`; `fixtures/db.ts` (+2 helpers). Statically checked in a scratch copy: `bddgen --tags @oauth-consent-grants` exit 0 (spec generated, every step resolved), `tsc --noEmit` exit 0 (needs the https compose stack with Dex to run).
Modified existing tests (extension, nothing weakened): `user_deletion_oauth_test_support.exs` (+`oauth_consent_grants` in `@expected_erased`, a seeded grant), `user_deletion_global_data_test.exs`, `user_deletion_test.exs` (inventory lists), `oauth_test_support.exs` (`finish_allow/3` returns the callback's own code redirect when the user is not asked again, so `flow_code!/4` / `session!/4` keep working for a second login of the same user and client), `oauth_consent_flow_test.exs` (3 holder tests that need the screen use `prompt=consent`), `test_helper.exs`.
Docs the dev must write (pinned by `consent_grant_docs_test.exs`, `user_deletion_sweep_test.exs`, `user_deletion_docs_test.exs`): 07-deployment (section "Remembered consent grants", GDPR paragraph, sweep SQL), `docs/compliance/gdpr-deletion-runbook.md` (verification query + sweep SQL), 08-concepts erased list, 05-building-blocks, ADR-033 (FR1 pointer + section "Remembered consent"), CHANGELOG.

## Scenario -> test mapping

1. First login asks: flow "scenario 1", e2e @scenario-1. 2. Second login skips: flow "scenario 2" (code row = same shape as after Allow, PKCE / state / nonce / device / redirect binding, token redemption, single use, device holder, gate l, IdP errors, freshness, no consent traffic), e2e @scenario-2.
3. Broader scope: flow "scenario 3", pure scope tests. 4. Redirect URI: flow "scenario 4" (also loopback port). 5. Another user: flow "scenario 5". 6. Revocation + re-approval: revocation test file. 7. prompt=consent: flow "scenario 7" + pure parser tests + authz row flag.
8. Erasure: erasure test + the generic erasure suites. 9. Withdrawal: account test, e2e @scenario-9.

## Design decisions (pinned; dev may deviate only with a story Decisions note, the story file already lists them)

1. Decision point = the IdP callback, after all existing gates (user known there). Skip mints through `Consent.issue_remembered/4` (Consent stays the only `CodeStore.insert` caller: the old static test stays green); response `302|303` to the client, no consent row / cookie, no grant write.
2. Remembered scope has NO device token (new device id per login) and is compared literally otherwise (prefix is part of the token). `covers?` = subset, empty request never covered.
3. Scenario 3 as worded is NOT observable: `profile`/`email` are dropped by the scope parser. Pinned: "openid profile email" after "openid" skips; a grant without `openid` asks again for `openid`; the skip never widens the code's scope.
4. Allow REPLACES scope and redirect URI (narrower Allow narrows, other URI moves the grant: one URI per grant). Deny stores nothing and leaves an existing grant. Write after the code exists; a failing write never fails the Allow.
5. "Same client": a revocation is final (guard trigger, DCR dedup), re-approval only by owner override; grants deleted in the revoke transaction (fail closed) AND bound by `client_approved_at` (= `oauth_clients.approved_at`), so a surviving row does not match a re-approved client.
6. Skip = ONE statement joining the client row (status approved, binding, redirect, user) + `covers?`; unreadable table => consent screen. `prompt` token `consent` (case sensitive, also "login consent") forces the screen; carried as `oauth_authz_requests.force_consent`.
7. Table / privileges / RLS: see `000057_oauth_consent_grants_test.exs` (PK (user_id, client_id), FK cascade, column-level UPDATE only for scope, redirect_uri, client_approved_at, granted_at, RLS forced, 4 open policies, size CHECKs).
8. Withdrawal: `GET /account/apps` + `POST /account/apps/withdraw`, nav "Apps", own grants of approved clients only, escaped names, notices `grant_withdrawn` / `grant_not_found`, CSRF + lenient BrowserPost, NOT freshness-gated, does NOT end existing sessions (page text says so).
9. GDPR: `oauth_consent_grants` added to `UserDeletion.erased_tables/0`. Logs: ids only (`OAuth consent: allowed|remembered client_id=.. user_id=.. device_id=..`), no scope / redirect / code / state. Rate limits, cluster safety (DB only) unchanged.

## Open questions / notes

- SECURITY (owner / Kassandra): the skip applies whatever the freshness verdict is. Today a stale / absent `auth_time` only produces a notice on the consent screen, so "login stays, consent skipped" holds, but with an active IdP SSO session the app now gets a code without any click. Pinned as decision (test "freshness verdict does not matter"); if the owner wants "skip only when login_fresh", it is a one-line change plus that test.
- One redirect URI per grant (alternating URIs ask every time); a grant never expires (docs test pins the statement). Withdrawal does not revoke sessions (decided per the story text); say so if the owner wants it.
- `Allow` remembering is best effort by design (failure => asked again); the revoke transaction is fail closed.
- The e2e Dex flow was not runnable here; step reuse of `oauth-authorize.steps.ts` assumes Dex re-prompts for the password on every authorize (as the existing consent feature does).

## Commands

```
# no-DB (red: 49 failures; green after dev: exit 0)
.session-ci/unit_nodb.sh
# DB (after adding migration 000057 run `.session-ci/quick.sh --migrate`; the container nebu-osess-pg was removed: the next call recreates it)
.session-ci/quick.sh "mix test test/nebu/oauth/consent_grant_scope_test.exs test/nebu/oauth/consent_grant_docs_test.exs test/nebu/migration/000057_oauth_consent_grants_test.exs test/nebu/oauth/consent_grant_store_test.exs test/nebu/oauth/consent_grant_flow_test.exs test/nebu/oauth/consent_grant_revocation_test.exs test/nebu/oauth/consent_grant_account_test.exs test/nebu/oauth/consent_grant_erasure_test.exs test/nebu/oauth/oauth_consent_flow_test.exs test/nebu/compliance --include integration 2>&1 | tail -40"
```

## Fix pass after the test review (test-review-findings.md)

Reference unchanged (reference-impl.diff identical). Numbers: 8 story files red 169 failed / 172 (3 static pass), green 172 passed (with consent-flow + compliance dir: 444 passed; oauth+compliance+migration dirs 3452 passed); no-DB job red 49 failed / 7049 (no warning), green 7049 passed.
- MAJOR-1: test "a DEACTIVATED user with a live grant ..." in consent_grant_flow_test.exs; mutant M69 (skip decided before the user gate) KILLED (69/69 mutants).
- MINOR-2: `finish_consent` accepts a skip only if a grant row exists for (sub, client) or `allow_skip: true`; no caller broke.
- MINOR-4: story Gherkin scenario 3 amended (+ new scenario "Unknown scope tokens do not widen the scope"); scope_test comment fixed. Owner decisions recorded in the story Decisions (freshness skip = deliberate choice under Kassandra review with the one-line alternative; one redirect URI per grant, no expiry, withdrawal keeps sessions = accepted limits).
- MINOR-5: warning message pinned, account 503 only, the `or` removed. MINOR-6: migration test uses the number sequence (highest earlier migration == 56) and only checks migrations numbered below 57. MINOR-8: e2e grant-count steps use `expect.poll` (bddgen exit 0, tsc exit 0 in a scratch copy).

## Cycle 1 (code review, Kassandra, UX review): red tests against the STAGED dev tree

lib / migrations / docs are exactly the staged dev state (the reference was applied and reverted with `git checkout`; `reference-impl-cycle1.diff` = the throwaway reference on top of it, 15 files). Only tests, test support, e2e, story, step-results changed.

| run | red vs staged | green with reference |
|---|---|---|
| 8 story files + oauth_consent_flow_test + compliance dir (`--include integration`) | 31 failed / 478 (new tests only) | 478 passed |
| oauth + migration + admin + web dirs with reference | - | 5701 / 5720, the 19 failures are the known unrelated families |
| `.session-ci/unit_nodb.sh` (warnings as errors) | 18 failed / 7068 (10 docs, 6 scope, 1 migration static, 1 unrelated `RateLimitTakeAllTest` teardown flake), no warning | 7068 passed |
| mutants | - | C01-C22: 22 / 22 killed (91 / 91 in total) |

New pins (all red against staged): (1) device state: a login whose device would REPLACE another session (legacy session or device row on the requested id) shows the consent screen, after the Allow the same device skips again (3 flow tests); (2) `prompt=login` (also in lists, `create login`) forces the screen through the existing `force_consent` flag, no new column; `none login` stays invalid_request; (3) rollout / deploy-window text in 07-deployment + CHANGELOG; (4) Website column = stored `client_host`, claimed `client_uri` host never shown, "unknown website" fallback; (5) static pins: Consent / Authorize moduledocs, ClientStore revoke doc, 06-runtime callback + revoke lines, 05-building-blocks row, 07-deployment gate rows i / y / i/y, Account moduledoc routes; (6) return target: the sign-in started at `/account/apps` ends there; (7) UX exact strings (button name `Withdraw the permission of <name> (<host>)`, intro, empty state, title = h1 = "Apps you have allowed"); (8) e2e scenario 9: button by role + name, `nav a[aria-current=page]`, notice role status, explanation + Devices link, axe + 320 px again after the withdrawal (notice + empty state).

NEEDS A MIGRATION CHANGE (tell the dev): the return target needs `return_action = 'apps'`, but `oauth_account_login_requests_action_check` (000043) allows only the five advertised actions. The reference widens it inside 000057 (up: drop + add with 'apps'; down: delete the 'apps' rows, restore the five) and `000057_oauth_consent_grants_test.exs` pins it (static + runtime role). The alternative (a known limit, Code review MINOR 5 "or note it") is not taken: the owner asked for the target.

Superseded assertions (nothing weakened, each replaced by a stricter or changed contract):
- `consent_grant_scope_test.exs` force_consent table: `{"login", false}` -> `{"login", true}` (prompt=login forces the screen, Kassandra LOW #2).
- `consent_grant_flow_test.exs`: `flag.("login") == false` -> `true`; the list of prompt values that do NOT force the screen lost `"login"` (it moved to the forcing list, plus "select_account login", "create login").
- `consent_grant_account_test.exs`: `body =~ "app.example.com"` (host from the claimed client_uri) -> the `<td data-label="Website">` cell shows the STORED client_host (the test sets it); title "Allowed apps" -> "Apps you have allowed"; intro "allowed to sign you in" -> "allowed to use your Matrix account"; the withdraw aria-label gained `(<host>)` (the old regex `aria-label="[^"]*Grant Test App[^"]*"` still holds).
- `consent_grant_docs_test.exs` FR1 pointer and CHANGELOG pins unchanged; the CHANGELOG `prompt=login` pin now needs "no `prompt=login`" (mutant C22).
- Test support: `set_client_host!/2` (privileged, trigger disabled for one transaction, like `reapprove!/1`); the e2e withdraw step now finds the button by role + name instead of `data-role`.
