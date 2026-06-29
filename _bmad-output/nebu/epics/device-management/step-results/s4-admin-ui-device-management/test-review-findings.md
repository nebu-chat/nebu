# S4 Pre-Dev Test-Review — PASS (0 MAJOR)

All AC1-AC4 have >=1 test; AC5 = UX gate (out of scope here). Playwright/BDD present, real
OIDC login (no cookie forging), device created via real Matrix flow (no DB seeding).
All six security expectations covered as tests: XSS-escape (both directions), authz redirect
(+ refute side-effect), IDOR (route user_id forwarded to user-scoped facade), CSRF (real
protect_from_forgery on), audit-action registration (device_renamed/device_deleted), kill-switch
E2E (revoked token → 401 whoami). RED validity verified (router has no /users/:user_id; audit
actions absent today).

## Findings (dev should address)
- MINOR-1: E2E AC2/AC3 rely on page.waitForLoadState('networkidle') after a dead-view POST/redirect.
  networkidle is flaky under LiveView socket traffic — prefer asserting a post-condition (row count
  change / flash) instead.
- MINOR-2: AC1 "created" column is named in the AC but not asserted in either test. Render the
  created timestamp and add an assertion so the column has direct coverage. (Address before done.)
- MINOR-3: last_seen ts→display formatting untested (IP asserted, ts not). Assert a rendered
  date/time token so a missing ts still fails AC1.
- INFO-1: FakeAuditWriter intercepts via Application env :audit_writer seam — dev must route the
  rename/delete audit through a module resolving that seam (ADR-020 Nebu.Matrix facade path), not a
  direct AuditWriter.log/7 call, or the audit-row tests false-fail.
- INFO-2: empty-state E2E uses raw-URL nav to @nobody:localhost (intentional; no fixture needed).
- INFO-3: IDOR unit tests prove route-scoping (route user_id forwarded), not facade-level foreign
  device refusal — that belongs in a Nebu.Matrix-level test. Boundary noted for epic trace.
