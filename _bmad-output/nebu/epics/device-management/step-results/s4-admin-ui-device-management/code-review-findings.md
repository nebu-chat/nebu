# S4 Code-Review (cycle 1) — PASS, 0 MAJOR/CRITICAL. 2 MINOR + 4 INFO.

ADR-020 facade boundary CLEAN; authz/IDOR/CSRF/XSS/audit/kill-switch all verified PASS.
Dev's test edits (FakeAuditWriter moved above setup; on_exit restoring :admin_csrf_bypass=true;
strengthened AC3 confirm + E2E dialog assertion) all sound — no assertions weakened.

## MINOR-1 (fix before done) — AC1 created/last-seen-ts not asserted (test gap)
The AC1 unit test supplies created_ts (1_699_000_000_000) and last_seen_ts (1_700_000_000_000)
in the fixture but only asserts device_id, display name, and IP. The template renders both the
created cell and a formatted last-seen ts (format_ts/1 exists), so AC1 works, but the "created"
column and the ts→display formatting have ZERO direct coverage — a regression dropping the created
column or breaking format_ts would not fail any test. Pre-dev review asked for these ("address
before done"). FIX: add an assertion that the rendered body contains the created token (e.g. the
formatted date for that epoch) AND a formatted last-seen timestamp token, in the AC1 list test.

## MINOR-2 (fix) — narrow the rescue in AuditWriter.do_log
server/lib/nebu/compliance/audit_writer.ex (~line 117): the added `rescue e ->` catches EVERY
exception, not just the documented RuntimeError from Ecto.Repo.Registry.lookup on an unstarted
Repo. It would also swallow a future FunctionClauseError/ArgumentError as a generic audit-write
failure. Not an audit-integrity hole (failures are Logger.error'd + returned as {:error,
:audit_write_failed}), hence MINOR. FIX: narrow to `rescue e in [RuntimeError] ->` to match the
documented never-raise intent, so genuine logic bugs still surface.

## INFO (no action required, noted)
- INFO-1: `:ok = do_delete_device(...)` hard-match — facade always returns :ok; let-it-crash policy. OK.
- INFO-2: audit-failure-path resilience (write_audit ignores return → action doesn't crash) is by
  design but untested. Optional hardening test.
- INFO-3: audit routed through :audit_writer env seam — verified correct.
- INFO-4: E2E waitForLoadState('networkidle') after dead-view POSTs unchanged (pre-dev MINOR-1).
  Less flaky on a dead render (no LiveView socket); asserting a post-condition would be more robust.
  Non-blocking.
