# test-review (pre-dev) admin-oauth-switch -- nebu-test-reviewer, 2026-10-14

4 MAJOR, 19 MINOR, 5 INFO; all MAJOR and the relevant MINOR fixed before the dev gate.

MAJOR: M1 atomicity (audit inside the tx / failing upsert rolls back) not provable -> in-transaction proof + trigger test added;
M2 kill-switch retry path: cache drop untested -> test added; M3 AC8 audit-log page half -> the page lists any action (no allowlist), AC reworded,
DB test reads the row; M4 asymmetry for OFF->OFF issuer change and a raising writer while OFF -> tests added.
MINOR (applied): m1/m2 message contracts aligned in story + tests; m3 issuer edge cases (255 boundary, ports, backslash, percent, IDN, IPv6, case)
-> form-only origin shape rule + tests; m4 stored ON with invalid issuer; m7 non-admin without marker; m8 other methods; m9 marker kept on redirect;
m10 audit contract `issuer_before == ""`; m11 status mutual exclusion; m12 ClientIP restore; m14 Safari AUS->AN; m15 titles; m16 docs pins limited to
sections; m17 nebu_app role; m18 over-strict cache test removed; m19 e2e hook kept (switches off through the form; documented).
Not applied (accepted): m5 HTTP effect of the live predicate (covered by existing metadata / versions suites), m6 concurrency (follow-up dc), m13.
