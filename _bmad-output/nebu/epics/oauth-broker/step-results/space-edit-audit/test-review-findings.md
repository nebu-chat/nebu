# test-review space-edit-audit (pre-dev, nebu-test-reviewer, 2026-10-15)
0 MAJOR, 7 MINOR, INFO. Applied before dev: MINOR-1 time based refute / assert (150-600 ms) -> `assert_received` / `refute_received` (the audit call is synchronous in the caller); MINOR-2 the raising writer raises `ArgumentError`
(not RuntimeError, which AuditWriter.do_log already rescues) + an `exit(:timeout)` writer; MINOR-3 AC4 integration test also checks the `events` rows; MINOR-4 AC3 non-member test checks status 200 and the error text;
MINOR-5 / 6 doc pins: vacuous words replaced, case-insensitive regexes, ADR "Not decided here" refute; MINOR-7 the ineffective refute of the AC7 seam guard removed. Question 1 (a raising writer must not change `{:ok, event_id}`): yes, story AC4 / D3 sharpened
(exception and exit too). Question 2 (AC6 audit view enumerations): none exist (`audit_log_live` shows `action` raw), AC6 reduced to `@known_actions`.
