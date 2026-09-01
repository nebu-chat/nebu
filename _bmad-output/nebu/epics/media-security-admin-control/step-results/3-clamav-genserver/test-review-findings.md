## Test Review: Story 3-clamav-genserver (pre-dev RED-phase gate)

**Files reviewed:** `docs/stories/media-security-admin-control/3-clamav-genserver.md`, `server/test/nebu/media/clamav_test.exs`, `server/test/nebu/media/clamav_fake_server.exs`

**Overall verdict: 3 MAJOR findings**

### MAJOR-1 — AC9 (no PII/content in logs) has zero test coverage
Neither the story's own "Acceptance Tests" list nor the actual suite contains any test capturing logs during a `scan_binary/1` call and asserting the scanned binary's content is absent. Given ADR-024's explicit DSGVO rationale ("no file content or hash ever leaves the deployment"), this is a compliance-relevant AC left completely unverified — a dev-story implementation that logs the raw binary at any level would violate AC9 undetected.
**Fix:** add a test that runs `capture_log` around `scan_binary/1` with a payload containing a unique marker (e.g. random bytes or a distinctive string) and asserts the captured log does NOT contain it — only size/outcome/signature should appear.

### MAJOR-2 — AC7 health_check/0 "healthy" path is never asserted
Test 8 only verifies `health_check/0` reports unhealthy when clamd is unreachable at init. No test ever asserts `health_check/0` returns a healthy/true state after a successful connection (e.g. after test 1's clean round trip). A stub implementation that hardcodes `health_check/0` to always return `false` would pass all 9 current tests.
**Fix:** add an assertion (in test 1 or a new test) that `health_check()` reflects healthy after a successful scan.

### MAJOR-3 — Tests 5 & 6 under-assert against the story's own documented error shapes
The Technical Requirements section pins exact tagged reasons: recv timeout/closed → `{:error, :timeout}` / `{:error, :connection_closed}`; unrecognized response → `{:error, {:clamd_error, message}}`. Tests 5 (recv timeout) and 6 (malformed response) only assert the generic `{:error, _reason}` pattern, so a dev-story implementation returning an inconsistent/undocumented atom for either case would still pass — risking a contract mismatch with Story 4b, which will pattern-match on these values. (Test 4's connect-refused case has no documented atom, so its looseness is fine.)
**Fix:** tighten to `assert {:error, :timeout} = result` (test 5) and `assert {:error, {:clamd_error, _msg}} = ...` (test 6).

### MINOR / INFO
- **MINOR-1:** `recv_timeout_ms` is a test-author assumption (self-documented in the moduledoc), not specified in the story. If dev-story picks a different key name it must edit this RED-phase test — atypical for this pipeline's convention. Recommend fixing the canonical key name now rather than leaving it open.
- **MINOR-2:** Test 2 (infected) doesn't assert `FakeClamd.received_bytes/2` the way test 1 does — nothing proves the client actually sent a well-formed INSTREAM request for this case; a pathological implementation could special-case the literal EICAR string. Low practical risk since test 9 already pins framing generically, but cheap to close by adding a reassembly check or using a non-EICAR payload.
- **MINOR-3:** `ClamAVFakeServer.accept_loop/4` spawns per-connection handlers via unlinked `Task.start/1`; `stop/1` only kills `accept_pid`, not spawned tasks. Test 5's `Process.sleep(:infinity)` handler therefore leaks an orphaned process + open socket for the BEAM's lifetime. Non-blocking for a single CI run; fix via `Task.start_link` inside `accept_pid` or explicit pid tracking in `stop/1`.
- **INFO:** AC1's full supervision wiring (`Nebu.Media.Supervisor` in `media_children/0`) and AC8's "short backoff, no hot-loop" have no dedicated unit test — consistent with the story's own Acceptance Tests scope, deferred to baseline-integration/CI boot checks. Not a novel gap introduced here.

No Do-Not-Change/Guardrail violations found: no `scan_file/1`, no disk paths, no Mox, no connection pooling. Wire-framing test (9) and the fake server's `recv_full_instream`/`recv_chunks` correctly mirror the INSTREAM spec (10-byte `zINSTREAM\0` greeting, `<<len::32,chunk::binary>>` frames, `<<0::32>>` terminator) — no bug found there. `async: false` is correctly required given the singleton-named GenServer.

**3 MAJOR found: AC9 log-redaction untested, AC7 healthy-path untested, AC6 documented error atoms under-asserted (tests 5/6). 3 MINOR, 1 INFO — non-blocking.**

---

## RESOLUTION (fix cycle, same day)

All 3 MAJOR + 3 MINOR findings fixed in `server/test/nebu/media/clamav_test.exs` and
`server/test/nebu/media/clamav_fake_server.exs` (test suite is now 10 tests, was 9):

- **MAJOR-1 (AC9) → FIXED:** new test `"scan_binary/1 never logs the scanned binary's content"` —
  embeds a random marker in the payload, wraps `scan_binary/1` in `capture_log`, asserts the
  marker never appears in log output.
- **MAJOR-2 (AC7) → FIXED:** test 1 (clean-scan round trip) now also asserts
  `Nebu.Media.ClamAV.health_check()` is truthy after a successful scan — closes the "always
  return unhealthy" stub loophole.
- **MAJOR-3 (AC6) → FIXED:** test 5 tightened to `assert {:error, :timeout} = result`; test 6
  tightened to `assert {:error, {:clamd_error, _message}} = ...`. Test 4 (connect refused)
  intentionally left generic — no documented exact atom for that case.
- **MINOR-1 → FIXED:** moduledoc now states `connect_timeout_ms` / `recv_timeout_ms` as the
  CANONICAL config key names dev-story must implement, not an open question.
- **MINOR-2 → FIXED:** test 2 (infected/EICAR) now also asserts the reassembled wire payload
  matches the exact EICAR string sent, guarding against a special-cased implementation.
- **MINOR-3 → FIXED:** `ClamAVFakeServer` now tracks `handler_pids` and `stop/1` kills every
  spawned per-connection handler task, not just `accept_pid` — no more orphaned
  `Process.sleep(:infinity)` processes/sockets leaking past a test.

Re-verified: all 10 tests still fail with the correct RED-phase reason (`Nebu.Media.ClamAV`
module/function undefined), not a new compile error or test-authoring bug. Independently
re-read and confirmed correct by the pipeline coordinator.

**Final status: CLEAN — 0 open MAJOR. Proceeding to dev-story.**
