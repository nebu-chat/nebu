# Test Review — admin-forms-http-controller

**Verdict:** 3 MAJOR, 6 MINOR, 4 INFO

## MAJOR Findings

**MAJOR-1 — AC9 POST /admin/config/refresh-mode has no test**
Valid POST + invalid-value POST both untested.

**MAJOR-2 — AC12 Router: live/3 replaced by HTTP routes — no programmatic test**
No test checks `Nebu.Admin.Router.__routes__()` to verify no live/3 routes remain for converted paths.
Suggested: `Enum.filter(routes, fn r -> r.kind == :live end)` and refute converted paths are in the list.

**MAJOR-3 — AC19 CSP tightened: no test**
`content-security-policy` header is completely unverified. At minimum assert the header is present and contains `connect-src`.

## MINOR Findings

MINOR-1: AC3 — rooms list test doesn't verify `<form method="get">` or absence of `phx-change`
MINOR-2: AC8 — Spaces write mutations (auto-join POST, add member) untested
MINOR-3: AC14 — longpoll introspection brittle against Phoenix version changes
MINOR-4: AC7 — remove-member test missing redirect location assertion
MINOR-5: AC6 — archive test doesn't assert flash message text ("Room archived")
MINOR-6: seam cleanup note (acceptable, no action required)

## INFO

INFO-1: AC15 is CI gate, not unit test — OK
INFO-2: AC18 is structural constraint — OK
INFO-3: AC10 Role Mapping tests missing (treat as MINOR)
INFO-4: AC6 Unarchive untested (treat as MINOR)
