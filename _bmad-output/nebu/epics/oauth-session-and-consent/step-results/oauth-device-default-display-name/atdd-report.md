# ATDD report - oauth-device-default-display-name (epic oauth-session-and-consent, REQ-2026-004)

State left in the worktree: RED tests only (lib, migrations, docs, CHANGELOG reverted to the committed state; nothing committed). Kept: tests, test support,
`test_helper.exs` registration, the story `## Decisions` addendum, these step results. Proof of meaning: `reference-impl.diff` (throwaway: new module
`Nebu.OAuth.DeviceName`, 2 lines in `Nebu.OAuth.Token`, 17 lines in `OAuthSessionStore.insert_replacing_device/1`, a section in 08-concepts, a CHANGELOG entry; NOT applied)
turns everything green. `mutation-results.txt`: 45 mutants, 45 killed. No migration is needed (000058 stays reserved; no test pins the migration number, that would be a time bomb).
No e2e: the story is `ui: false` and has no browser-visible part of its own (the name shows in the client's device list and on the existing admin / account pages that already render `devices.display_name`).

## Numbers (after the test-review fix pass)

| run | red (no reference) | green (with reference) |
|---|---|---|
| 4 NEW story files, `--include integration` (62 tests) | 57 failed / 62 (5 pass: guards that hold without the feature: legacy login keeps / has no name, another user's device untouched, erasure, the log test) | 62 passed (reference diff unchanged) |
| `.session-ci/unit_nodb.sh` (full no-DB suite, warnings as errors, Elixir 1.20) | 26 failed / 7094, no warning | 7094 passed, 7 skipped, exit 0 |
| oauth, compliance, matrix/session, migration, device + login tests with the reference (run before the fix pass; the fix pass only changed the 4 story files) | - | 3882 passed, 0 failures |

## Fix pass after the test review (test-review-findings.md)

MINOR 1: the `n > 57` migration pin is dropped (000058 is reserved for another story; the story adds none and a diff cannot be tested); the erasure test no longer hard-codes the `devices` column list, the near-tautological refute is gone (the end-to-end erasure test stays). MINOR 2: the Matrix store source pin is only the `display_name IS NULL` substring (behaviour is pinned by the flow tests). MINOR 3: doc anchors reduced to the heading, `client_name`, `OAuth client`, `Nebu.OAuth.DeviceName`, `never overwrit`, and in the CHANGELOG the story id, REQ id and "display name". MINOR 4: the Logger check looks at code only (heredocs and comments stripped) and matches `Logger.<level>`. MINOR 5: the empty-name test clears the name with `PUT /devices` through the API. MINOR 6: new flow test "a name cleared through the API (PUT without display_name = NULL) gets the default again at the next login" (owner decision: accepted).

## Files (all new, under server/test)

`nebu/oauth/device_name_oauth_test_support.exs` (helpers; name ends in `oauth_test_support.exs`, required from `test_helper.exs`, no mix.exs change),
`nebu/oauth/device_name_test.exs` (pure `DeviceName.default_name/2` table, no DB: scenarios 1, 3, 4 and the rules; runs in the unit job),
`nebu/oauth/device_name_flow_test.exs` (scenarios 1-5 through the real flow + the Matrix device API; `for_client/2`; logs),
`nebu/oauth/device_name_erasure_test.exs` (GDPR through the dispatcher RPC), `nebu/oauth/device_name_docs_test.exs` (static: a few doc anchors, CHANGELOG, no Logger call, ADR-020, the IS NULL guard).

## Scenario / rule -> test mapping

1. New device gets name + suffix: flow "scenario 1" (story example, GET /devices and GET /devices/{id}, 10 char id, agreement with the pure function, nothing of the user in it, two logins distinguishable, structured ids, other client, two users with the same device id, token parameters cannot name the device, refresh leaves it).
2. Existing name kept: flow "scenario 2" (PUT then re-login x2, PUT after login wins and survives a refresh, legacy-named device, empty string kept, NULL name filled, other user's same device id untouched, other devices of the user untouched).
3. Sanitising: pure table + flow "scenario 3" (story example `EvilClient (ABCD1234)`, hostile spread, markup in the device id).
4. Bound: pure + flow "scenario 4" (500 ASCII, multi-byte, 255, code points vs graphemes, cut after sanitising, trim after the cut). Fallback `OAuth client`: absent / empty / blank / markup-only / control-only names, non-string, invalid UTF-8; revoked / pending / rejected / unknown client and unreadable DB via `for_client/2`.
5. Legacy: flow "scenario 5" (exact `Legacy laptop`, no name stays no name, mixed user, take-over keeps the name).
Rules: no tokens / credentials / user data in the name, no log line with the name (flow log test + static no-Logger), no PII of other users (list shows only the own device, scoped write), GDPR unchanged (erasure test, no new column / table), ADR-020 (static), never overwrite (flow + static guard + mutants M30, M33, M34).

## Design decisions (pinned; details and the open questions are in the story `## Decisions`)

Name built in the OAuth domain (`DeviceName.for_client/2` in `Token.issue_session/3`), handed to the Matrix domain, written with `UPDATE devices ... AND display_name IS NULL` in the issuance transaction; base = sanitised `client_name` of an approved client (max 64 code points, else `OAuth client`); suffix = last 8 safe characters of the device id (hex fallback); empty string is a chosen name; NULL-named existing device is filled at its next OAuth login; no backfill, no migration, no new log line.

## Commands

```
# no-DB (red: 26 failures; green after dev: exit 0)
.session-ci/unit_nodb.sh
# DB
.session-ci/quick.sh "mix test test/nebu/oauth/device_name_test.exs test/nebu/oauth/device_name_flow_test.exs test/nebu/oauth/device_name_erasure_test.exs test/nebu/oauth/device_name_docs_test.exs --include integration 2>&1 | tail -40"
```

## Cycle 1 (code review MINOR 2 / 3, Kassandra LOW 1): red tests against the STAGED dev tree

lib / docs / CHANGELOG are exactly the staged dev state (the cycle 1 reference was applied and reverted with `git checkout` from the index; `reference-impl-cycle1.diff` = the throwaway reference on top of it: `device_name.ex`, 08-concepts, CHANGELOG, new `follow-ups.md`).

| run | red vs staged | green with reference |
|---|---|---|
| 4 story files, `--include integration` (71 tests) | 9 failed / 71 (new tests only; the 62 earlier tests stay green) | 71 passed |
| `.session-ci/unit_nodb.sh` (warnings as errors) | 8 failed / 7102 (6 pure + 2 docs), no warning | not rerun after the last added test (a pure test); the 4 story files 71 / 71, the rest of the no-DB suite was 7101 passed with the reference |
| mutants C01-C19 | - | 19 / 19 killed (C07 first survived, test added) |

New pins: (1) invisible-but-not-empty characters U+3164, U+FFA0, U+115F, U+1160, U+2800, U+034F and the variation selectors U+FE00..U+FE0F are dropped; a name of only those (alone, repeated, with spaces, all together) or of combining marks without a base letter falls back to `OAuth client`; letters mixed with them are kept; a combining mark with no base letter (at the start or after a space) is dropped while a mark after a letter is kept (decomposed accents survive); invariant: the base always contains a visible character; one flow test with four client names. Not pinned on purpose: a variation selector right after an emoji. (2) docs: 08-concepts and the CHANGELOG entry must say "the new code does not log it", name the debug request logger's `GET /devices` capture, and no longer say "the name is not logged"; `docs/stories/oauth-session-and-consent/follow-ups.md` must exist with the three entries (redact device names in the debug request logger; thread client_name through authenticate/redeem to avoid the second client SELECT; confusable/mixed-script warning on approve_confirm). The dev creates the file.
Superseded assertions: none (all additions; no earlier assertion changed or removed).
