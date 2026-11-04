# Test review (pre-dev): persistent-consent-grants

Reviewer: nebu-test-reviewer (read-only, static; red/green and 68/68 mutants taken from the ATDD report). Verdict: strong suite, all 9 scenarios covered, 1 MAJOR, 7 MINOR.

## MAJOR
1. Missing security negative: deactivated (not erased) user with a live grant. Add: allow_new!, set users.is_active=false (privileged), G.login must give an access_denied redirect, no code, no consent cookie, no consent row, grant row untouched. Mutant: move skip_consent? ahead of the user gate.

## MINOR
2. oauth_test_support.exs:1041-1062 (finish_consent) silently accepts a skip for every caller, so a first login that skips without a grant goes unnoticed in hundreds of existing tests. Accept the skip only if a grant row exists for (sub, client), or opt in with `allow_skip: true`.
3. flow:268-275 pins "freshness verdict does not matter" (open owner/security decision). Story text says "freshness rules still apply".
4. Scenario 3 as worded is unobservable (parser drops profile/email). Addendum is honest; amend the Gherkin of scenario 3 in the story file; scope_test:89 comment should point to the parser decision.
5. Weak assertions: flow:144 `log =~ "[warning]"` (assert the specific message); account_test:312 `status in [500, 503]` (pin 503); account_test:160 `... or ...` makes the strict alternative optional; flow:290 loose error list (acceptable); flow:537-544 documents rather than tests (INFO).
6. Brittle: store_test:186-201 and flow:326-342 match SQL text on [:nebu,:repo,:query] telemetry (intentional, pins the one-statement revoke-race fix); migration_test:63-67 refutes any mention of the table in 0000[0-5]*.sql (breaks on a later legitimate migration touching it); migration_test:60 hard-requires the 000056 file name.
7. Shared-state: with_table_unreadable renames a real table and block_code_inserts! creates a trigger (cleanup present, async false, OK); reapprove! uses a future timestamp (artificial, harmless).
8. e2e: one-shot DB read `countOAuthConsentGrants` after UI steps races if the write ever becomes async: use expect.poll. dexLogin `.catch(() => 'none')` acceptable.

## INFO
ui:true Playwright coverage present for scenarios 1, 2, 9 (a11y, h1, 320px); e2e not executed. Security negatives all present (other user, other client, other redirect, scope widening, revoked/pending/rejected clients, prompt=consent variants, CSRF/Origin/fetch-metadata on withdraw, escaped name, erasure + rollback, logs canaries). Fail-closed at every layer. Not covered (optional): concurrent revoke between skip read and code insert.
