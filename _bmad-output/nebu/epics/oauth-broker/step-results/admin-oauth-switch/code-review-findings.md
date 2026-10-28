# code-review cycle 0 admin-oauth-switch -- nebu-code-reviewer, 2026-10-14

0 CRITICAL, 0 MAJOR, 6 MINOR, 9 INFO. Answers to the targeted questions: (a) no path flips the switch without gate / audit / ack; (b) marker consumed after a
successful write only; (c) no unescaped user input; (d) Repo missing fails closed.
MINOR (all applied in cycle 1): M1 regex /u before String.valid? raises on invalid UTF-8 (reorder + test); M2 failed save not logged (value-free ERROR);
M3 asymmetry never tested against a really failing audit insert (trigger test on audit_log); M4 Repo-missing branch of run_tx_db untested (no_repo test);
M5 no_actor branch + HTML escape of the issuer untested, misleading test title; M6 refresh-mode status text imprecise (logins are refused when the IdP issues
no refresh token).
INFO: I1-I9 (port :443 string, read/write race = follow-up dc, seams, e2e hook, historical story doc, docs consistent).
