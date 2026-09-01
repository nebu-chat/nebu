# Test-Review (pre-dev) — 10d-scan-kill-switch

## Coverage check against AC1-AC9

| AC | Covered by |
|---|---|
| AC1 (config value + default + validation) | config_test.exs: invalid-value rejection, both-values-accepted, fresh-table-default |
| AC2 (migration extends RLS allowlist) | config_test.exs `@tag :integration` RLS block (excluded from unit run; verified at ci-gate) |
| AC3 (check before scan attempt) | kill_switch_test.exs Tests 1-3: `refute :storage_get/scan_binary in clamav_calls()` |
| AC4 (fail_open unhealthy → released unscanned) | Test 1 |
| AC5 (fail_closed unhealthy → quarantined/scan_failed) | Tests 2, 3 |
| AC6 (live policy change, no restart) | Test 5 (drives the REAL Nebu.Media.Config, not a fake) |
| AC7 (audit entry non-negotiable) | Test 1 + Test 5, plus audit_writer_media_actions_test.exs allowlist regression |
| AC8 (healthy → unaffected regardless of policy) | Test 4 |
| AC9 (no new audit for fail_closed path) | Test 2 (`audit_calls() == []`) |

## MINOR findings — found and fixed inline during this review (self-fix, no cycle needed)

1. **Weak "skip" assertions (Tests 1/2/3/5).** Initial draft only asserted
   `scan_binary/1` was never called on the kill-switch branches. The story's
   own Technical Requirements explicitly motivates checking health FIRST as
   avoiding "a wasted S3 round-trip" (`Storage.get/1`) — the original tests
   would have let a broken implementation that still fetches from storage
   before skipping only the scan step pass silently. **Fixed**: `FakeStorage`
   now logs a `:storage_get` tag into the shared call-log Agent, and Tests
   1/2/3/5 assert `refute :storage_get in clamav_calls()`.
2. **AC8 coverage gap (Test 4).** Original draft only exercised the `:clean`
   scan outcome under both policy values, not `:infected` — AC8's own text
   explicitly calls out both ("clean → `:released`, `:infected` on
   detection"). **Fixed**: Test 4 now parameterizes over
   `{policy, outcome} ∈ {fail_open, fail_closed} × {clean, infected}` (4
   sub-scenarios), plus a new assertion that no `media_unscanned_release`
   audit entry ever fires on the healthy path.

## Guardrail verification

- **Default MUST be fail_closed, never silently fail_open** — directly
  encoded: `config_test.exs`'s fresh-table-default test asserts
  `Config.get().scan_kill_switch == "fail_closed"` with an EMPTY override map
  (no admin action), and the shared `@default_catalog` fixture (used by 7
  other tests across the file, all of which are among the 10 correctly-RED
  failures right now) also pins `scan_kill_switch: "fail_closed"`. Any
  dev-story implementation that defaults to `"fail_open"` fails at least 8
  distinct assertions across 2 files.
- **AC7 audit non-negotiable** — Test 1 asserts exactly one audit call with
  all required metadata fields; Test 5 additionally proves the audit fires
  on the SECOND (post-upsert) invocation, not just in isolation; the
  dedicated allowlist regression test in `audit_writer_media_actions_test.exs`
  independently guards the `@known_actions` footgun this story's own Dev
  Agent Guardrails calls out by name.

## Re-verification after fixes

Re-ran `mix test --warnings-as-errors` full suite after applying the two
fixes above: 1938/1948 passed, 10 failed — same 10 tests, all still RED for
the correct branch-not-yet-implemented reason, 0 regressions, 0 new compiler
warnings.

## Verdict: CLEAN (0 MAJOR). Proceeding to dev-story.
