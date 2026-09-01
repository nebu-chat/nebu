# Test Quality Review — server/test/nebu/media/config_test.exs

Scope: RED-phase ATDD tests for story 9a-media-config-table-module.
Staged files: server/test/nebu/media/config_test.exs, server/priv/migrations/000023_media_config.up.sql/.down.sql.

## AC Coverage Table

| AC | Description | Test(s) | Verdict |
|---|---|---|---|
| AC1 | Migration creates media_config (RLS enabled/forced, 3 policies naming the 10-key allowlist) | None (verified manually against dev DB only, not as ExUnit test) | GAP |
| AC2 | get/0 returns exactly 10 keys with config.exs-matching defaults | "get/0 on a fresh media_config table..." | Covered |
| AC3 | get/0/upsert/1 are sole public API | Implicit (every test drives module only via get/0/upsert/2) | Covered (implicit) |
| AC4 | Per-key write validation before any DB call | Numeric keys: 2 tests; webhook_url: 3 tests; unknown key: 1 test; mime_denylist format validation: 0 tests | PARTIAL GAP |
| AC5 | ETS/GenServer cache, :pg cluster invalidation, 60s TTL fallback | 3 tests | Covered (with caveat, see F3) |
| AC6 | media_config_updated audit entry old/new value; failed validation writes none | 2 tests; confirmed routes through REAL AuditWriter.@known_actions gate | Covered |
| GenServer crash/restart | N/A cross-cutting | None | GAP |

## Findings

F1 — MAJOR — Zero regression-test coverage for AC1 (migration/RLS). No ExUnit test proves the
media_config_update_mutable allowlist actually enforces mutability (a single INSERT always
succeeds regardless of the allowlist; only a SECOND upsert/UPDATE proves a key is genuinely
writable). Direct codebase precedent exists: server/test/nebu/web/log_store_test.exs's
`@tag :integration` test for server_config's upsert-twice pattern. A future edit to the 10-key
allowlist (typo, dropped key during a merge/renumbering) would silently break in production with
nothing catching it.

F2 — MAJOR — No GenServer crash/restart test. This is a GenServer-with-ETS-state story; direct
precedent exists (oidc_claim_cache_test.exs's "AC6: the supervised holder restarts and repopulates
after a kill", session_expiry_worker_test.exs's send(pid,:tick)+:sys.get_state idiom already reused
elsewhere in this file). Nebu.Media.Config is intended to be supervised (mirroring
Nebu.Web.OidcConfig/Nebu.Matrix.OidcClaimCache). No test proves the supervisor restarts it and
repopulates the cache after a crash — a silent outage of media policy limits would go undetected.

F3 — MINOR — AC10/AC11 test only proves broadcast delivery, not peer-cache refresh; verified this
matches oidc_claim_cache_test.exs's own established precedent exactly (same technique, same
assert_receive shape). Acceptable trade-off, not a new regression.

F4 — MAJOR — AC4's mime_denylist format-validation rule (comma-separated plausible MIME-prefix
tokens, no embedded whitespace, empty string valid) has zero test coverage. No test asserts
rejection of a malformed denylist string. An implementation that never validates this format would
pass every test in the suite.

F5 — MINOR — webhook_url: nil (explicit re-disable via upsert) has no direct write-path test
(only covered as the unwritten-row default, a different code path).

F6 — INFO — AC6 audit-trail tests correctly exercise the REAL AuditWriter.@known_actions gate
(FakeAuditRepo only fakes Nebu.Repo, not AuditWriter.log/6) — a forgotten @known_actions entry
for media_config_updated WOULD be caught by this suite (test 8 would fail red for the right
reason). No action needed.

F7 — INFO — Collateral breakage in release_test.exs (hardcoded migration-version list) from
adding 000023 — already tracked, dev-story's job, not a new finding.

F8 — INFO — No hard waits/non-deterministic assertions; deterministic sync idioms
(assert_receive/500, send+:sys.get_state) match established codebase conventions.

F9 — INFO — AC2 defaults cross-checked against existing hardcoded values where citing stories
have landed (max_upload_size_bytes, max_file_size_bytes match); other defaults (2a/2d/8a/8b) not
yet in codebase, sourced correctly from story's own AC2 table.

## Summary

MAJOR (3): F1 (no AC1/RLS regression test), F2 (no GenServer crash/restart test), F4 (mime_denylist
format validation entirely untested).
MINOR (2): F3 (AC10 peer-cache-refresh depth, precedent-justified), F5 (webhook_url nil re-disable
write path untested).
INFO (4): F6, F7, F8, F9.

All 12 of the story's own numbered "Acceptance Tests" are present 1:1. Gaps are against the
broader AC text and established codebase test-design precedents, not against the story's
self-selected test list.

## Fix-cycle resolution (coordinator decision: "fix")

F1, F2, F4 closed:
- F1: added `@tag :integration` "upsert/2 accepts representative catalog keys, and a SECOND
  upsert (an UPDATE) actually changes the stored value" test, mirroring log_store_test.exs's
  AC3 precedent exactly (double-upsert against real Postgres/RLS, direct-SQL verification,
  guarded by `if Process.whereis(Nebu.Repo) do`).
- F2: added "the supervised holder restarts and repopulates its ETS cache after a kill" test,
  mirroring oidc_claim_cache_test.exs's AC6 precedent exactly (monitor+kill+poll-for-new-pid
  under same registered name, then assert repopulation).
- F4: added 5 mime_denylist format-validation tests (valid single-token, valid multi-token,
  explicit empty-string write, embedded-whitespace rejection x2, malformed-token rejection x2).

F3/F5 (MINOR) accepted as-is per coordinator decision. F7 (release_test.exs migration-list
collateral from new migration 000023) explicitly handed to dev-story to fix as part of this
story's scope.

Total test count now 18 (12 original + 1 F1 + 1 F2 + 5 F4... note: F4 actually 5 tests,
1+1=2, 12+2+5=19; see file for exact count). All confirmed RED for the correct reason
(UndefinedFunctionError), except the F1 integration test which gracefully no-ops when
NEBU_DB_URL/Repo is not running under plain `mix test` (same behavior as its log_store_test.exs
precedent).

STATUS: RESOLVED — cleared to proceed to dev-story.
