# Pre-dev test review: safari-fetch-metadata-compat (nebu-test-reviewer, read-only)

Result: 3 MAJOR, 12 MINOR, 6 INFO. AC1-AC6, D1-D5 covered; no false-red tests; no test name > 254 chars; no warnings.

MAJOR (all resolved before dev)
1. Existing test config_sso_trust_hardening_test.exs pins the 403 sentence "If you used a script or an embedded page ..." -> kept; the 403 page only ADDS a sentence naming current Chrome / Firefox / Safari; new test refutes nothing, asserts both; AC2 reworded.
2. oauth_account_hardening_test.exs M8 `refute body =~ "<script"` would fail on the reset page (pinned inline script) -> test changed to refute the attacker string `<script>alert`; named in AC5 of the story.
3. AC8 (docs) had no test -> static docs test added after the doc edit (safari_docs_test.exs).

MINOR resolved: 1 (script hygiene: closing tag, <!--, CR, ?., ??, ...), 5 (Firefox/Chromium tokens effective on their own, lower-case token, WKWebView UA), 6 (marker bound to the page, not just non-nil), 7 (account: CSRF / Origin order without proof), 9 (AC7 helper list), 10 (AC9 wording, tag @safari-click-proof), 11 (Promise.all in the e2e step), 12 (case-insensitive text pins).
MINOR accepted: 2 (app.js reachability: covered by the e2e scenario and the byte-equality test; the script is placed before the boot guard), 3 (node harness skipped in the node-less CI image; run once on the host, see the dev record), 4 (names pinned by the tests now listed in the story), 8 (@several page without approve form: renders no script by construction, the approve form and the script share one condition), INFO 4 (a query-string proof is accepted as a merged param: cross-site fails on Sec-Fetch-Site anyway).
