---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-quality-evaluation', 'step-04-generate-report']
lastStep: 'step-04-generate-report'
lastSaved: '2026-10-02'
inputDocuments:
  - _bmad-output/nebu/epics/sync-state-events-missing-fields/step-results/bugfix-sync-state-events-missing-fields/bug-context.md
  - .claude/skills/bmad-testarch-test-review/resources/knowledge/test-quality.md
  - .claude/skills/bmad-testarch-test-review/resources/knowledge/timing-debugging.md
  - .claude/skills/bmad-testarch-test-review/resources/knowledge/test-healing-patterns.md
  - server/lib/nebu/matrix/event_dispatcher/server.ex
  - server/lib/nebu/matrix/room/server.ex
  - server/lib/nebu/matrix/room/db.ex
  - server/lib/nebu/web/router/protected.ex
  - server/priv/migrations/000001_init.up.sql
reviewType: 're-review (round 4) of ATDD red-phase test scaffolds'
scope: 'single bug fix, 3 files'
---

# Test Review — bugfix/sync-state-events-missing-fields (RE-REVIEW, round 4)

**Scope:** staged diff of 3 ExUnit files (667 insertions), RED-phase ATDD coverage for a bug
fix not yet implemented in production. This is a re-review: round 1 found 2 MAJOR gaps
(no GenServer crash/restart identity test; AC4's "start-of-timeline" semantic untested).
Rounds 2–3 closed those gaps and then self-corrected a test-design issue the round-2 work
surfaced. This pass independently re-verifies all of it against the actual production source
(not the prior rounds' self-reports) and checks for new issues introduced along the way.

**Method:** Read `bug-context.md` in full (Oracle rulings, all ACs, dev notes). Read the full
staged diff of all 3 files. Independently traced every production-code claim the new tests and
their comments make — `dedup_member_state_events/2`, `fetch_delta_rooms/3`'s
`timeline_state_keys` exclusion, `build_state_events/2`, `Room.Server`'s `set_power_levels`/
`do_init`/`load_members`, `set_room_state`/`emit_state_event/5`, the `events` table schema,
`insert_event/1` — against the current `server/lib/` source, line by line, rather than trusting
the diff's own commentary. Verified all 3 files are syntactically valid Elixir
(`Code.string_to_quoted/1`). A full `mix compile` was attempted for an additional belt-and-braces
check but the local toolchain/dep versions didn't line up with the project's container build
(see Notes) — not a finding against the diff; the syntax check plus manual source cross-reference
already give strong confidence.

---

## Verdict

**No new MAJOR issues found.** Both previously-MAJOR gaps are genuinely closed and the round-3
self-correction is logically sound — independently re-derived, not just re-asserted. One
consistency MINOR and one precedent-backed MINOR noted below; everything else is INFO.

---

## AC-by-AC Coverage

| AC | Status | Where |
|---|---|---|
| AC1 core fix (real event_id/origin_server_ts for create/member/power_levels/name/canonical_alias/generic) | ✅ Covered | `matrix_client_compat_test.exs` "5 rooms" test + new describe block (both new tests + both gap-closure tests); `spaces_foundation_integration_test.exs` (create); `spaces_state_events_integration_test.exs` (m.space.child) |
| AC1 exception (member dedup conditional placement, strict reject-in-both) | ✅ Covered, strict | 5 distinct scenarios exercise both branches (deduped: "5 rooms", "initial sync"; not-deduped: "incremental sync (AC4)", MAJOR-1 crash test, MAJOR-2 mid-window test) — see detailed analysis below |
| AC2 schema widening (not independently black-box testable; forced indirectly) | ✅ Indirectly forced | every real-identity assertion in the suite fails until the proto + read-side threading exists |
| AC2 addendum (power_levels needs a backing event) | ✅ Forced + explicitly reasoned about | MAJOR-1 test requires `post_pl_event` to carry real, DB-matching identity after a GenServer restart — can only pass once `handle_call({:set_power_levels,...})` also persists an event |
| AC3 (unsigned.age, optional) | ✅ Covered | asserted alongside every state-event identity check |
| AC4 (regression guard; start-of-timeline not end) | ✅ Covered, genuinely | MAJOR-2 test changes a *tracked* key (m.room.name) mid-window and asserts (a) it's excluded from `state.events` per real `/sync` semantics, (b) all *other* state entries keep real, unperturbed identity. This is a true mid-window-change test, not a no-op/unrelated-event test. |
| AC5 (test coverage for create/member/power_levels/generic, both sync modes) | ✅ Covered | both initial and incremental paths hit all 4 required types; member uses the AC1-conditional assertion, not unconditional presence |

---

## Independent Verification of the Two Previously-MAJOR Gaps

### 1. GenServer crash/restart test (MAJOR-1, round 2) — genuinely meaningful

`matrix_client_compat_test.exs`, test `"Room GenServer crash+restart keeps real member/power_levels event identity (MAJOR-1, cluster-safety)"`.

- The crash/restart mechanics (`Horde.Registry.lookup` → `Horde.DynamicSupervisor.terminate_child`
  → `Process.exit(pid, :kill)` → `Process.sleep(100)` → `RoomSupervisor.start_room/1`) are not
  invented for this test — they are a byte-for-byte match of the existing, accepted
  `AT-CLUSTER-1` idiom in `test/nebu/matrix/room/room_server_clustering_test.exs` (same modules,
  same 100ms sleep, same explicit `start_room` call to avoid racing Horde's own async restart).
- The test's premise — that `Room.Server.do_init/1` (`server.ex:211-259`) rebuilds `members`/
  `power_levels` purely from `db_module().load_members/1`'s current 3-tuple contract
  (`{user_ids, created_at_ms, power_levels_json}`, confirmed at `room/db.ex:68`), with **no**
  per-member/per-field event identity in that contract — is accurate. I read `do_init/1` directly;
  it is exactly as described. This means the test *forces* the eventual fix to widen
  `load_members/1` (not just thread identity through the live `handle_call` mutation path), which
  is the real MAJOR-1 concern from round 1.
- Assertion strength: uses `assert_state_event_identity_real_and_db_matching/2`, which does
  `is_binary`/`is_integer` checks *and* an exact equality check against the real DB row
  (`ev["event_id"] == db_event_id`), not a weak not-nil check. Confirmed strict.
- `assert new_pid != pid` plus `Process.alive?(new_pid)` confirms a real restart actually
  happened, not a no-op.
- The test deliberately uses an *incremental* sync post-restart (not initial), with a documented,
  correct reason: `dedup_member_state_events/2` would otherwise strip `m.room.member` from
  `state.events` for a fresh room's initial sync (own join always inside the timeline window),
  making the MAJOR-1 assertion unreachable. I independently confirmed this reasoning against the
  real `dedup_member_state_events/2` (`server.ex:2736-2749`) — it matches by `state_key`, so a
  join captured by a *prior* sync (not in *this* delta's timeline) is correctly left undeduped.
  This is real, non-fragile test design, not a hopeful assumption.
- Confirmed `handle_call({:set_power_levels, ...})` (`room/server.ex:330-348`) truly never calls
  `insert_event` today (only `db_module().set_power_levels/2`) — the AC2 addendum's premise is
  accurate, and this test is the one that will catch a dev-story that only threads the read side
  without adding the write-side event.

### 2. Mid-window state-change test (MAJOR-2, round 2→3 self-correction) — re-derived independently, logic holds

`matrix_client_compat_test.exs`, test `"mid-window state change excluded from state.events; untouched keys keep real identity (MAJOR-2)"`.

I did not trust the test's own commentary about `fetch_delta_rooms/3`'s semantics — I read the
function directly (`server.ex:2657-2725`). Confirmed exactly as the test describes:

```elixir
timeline_state_keys =
  events
  |> Enum.filter(fn ev -> Map.has_key?(ev, "state_key") end)
  |> MapSet.new(fn ev -> {ev["event_type"] || "", ev["state_key"] || ""} end)

state_events =
  build_state_events(state, room_id)
  |> Enum.reject(fn ev -> MapSet.member?(timeline_state_keys, {ev.type, ev.state_key}) end)
```

This exclusion (not `dedup_member_state_events/2`, which is member-only) is exactly why a
mid-window `m.room.name` change must be **absent** from `state.events` in the test's assertion —
the production code strips any `{type, state_key}` already delivered via this delta's
`timeline.events`. The test's rename goes through `PUT /rooms/{roomId}/state/m.room.name` →
`set_room_state` (`server.ex:1939`, confirmed `m.room.name` is on `@writable_state_types`) →
`emit_state_event/5` (`server.ex:4635`), which genuinely persists a real, signed event with
`state_key` stored as `""` in the DB (confirmed `insert_event/1`'s explicit `"" ≠ nil` handling at
`room/db.ex:372-379`) — so the raw SQL `WHERE state_key = $3` lookup the tests use is valid.

The test's real proof point — `m.room.create`'s identity is unchanged by an *unrelated* tracked
key changing in the same window — is a legitimate "state reflects start, not end, of the window"
regression guard, independent of (and structurally different from) the earlier "unrelated
`m.room.message` between syncs" AC4 test, since `m.room.message` has no `state_key` at all and
never entered `timeline_state_keys` to begin with. This closes the original round-1 gap for real.

### 3. Round-3 member-placement correction — strict, not "present somewhere"

Checked explicitly per the task's ask: the `refute Enum.any?(state_events, fn ev -> ev["type"] ==
"m.room.member" && ev["state_key"] == user_id end)` guard, used whenever the join is found in
`timeline.events`, is a genuine **reject-if-in-both** check — it does not degrade to "present in at
least one place." A regression that (wrongly) left the member event in both `state.events` and
`timeline.events` would fail this `refute`. This same conditional logic is applied consistently
in: the "5 rooms" test (inlined), the shared `assert_real_state_event_fields/2` helper (used by
both the "initial sync" and "incremental sync (AC4)" tests). Both branches (deduped /
not-deduped) are exercised by different tests, not just assumed — confirmed via the differing
timeline-window conditions each test sets up (fresh small room vs. captured-`since`-before-crash).

---

## Findings

### MINOR-1 — Inconsistent DB-lookup safety between round-1 and round-3 helpers

`matrix_client_compat_test.exs`: the original helpers (`assert_real_state_event_fields/2`, used
by "initial sync"/"incremental sync", and the inlined loop in the "5 rooms" test) still do a bare
pattern match:

```elixir
{db_event_id, db_ts} = db_event_identity(room_id, ev["type"], ev["state_key"] || "")
```

whereas the round-3 gap-closure helper `assert_state_event_identity_real_and_db_matching/2`
(correctly) guards the same lookup with a `case ... :no_row -> flunk(...)`. Today this is inert —
the diff's own comment is right that `is_binary(ev["event_id"])` fails first for every type
(including `m.room.power_levels`, which has no backing DB row at all per the AC2 addendum), so the
bare match is never reached. But the moment the fix lands, if a future change ever gave
`m.room.power_levels` a non-empty-but-synthetic `event_id` (AC1 violation) without actually adding
the backing event (AC2 addendum unmet), the two original tests would die with a raw `MatchError`
instead of the clean, diagnostic `assert`/`flunk` messages used elsewhere for the identical risk.
The test would still fail (so this does **not** mask a wrong implementation), but the failure mode
is inconsistent and less diagnosable than the pattern the authors themselves adopted one test
later for the same scenario. Low-cost fix: reuse `assert_state_event_identity_real_and_db_matching/2`
style `case` in `assert_real_state_event_fields/2` and the "5 rooms" test too, for consistency.

### MINOR-2 — `Process.sleep(100)` hard wait in the crash/restart test

Per the generic "no hard waits" quality principle, this is nominally a smell. In practice it's not
a new anti-pattern: it's copied verbatim from the already-accepted `AT-CLUSTER-1` precedent
elsewhere in this suite (same sleep value, same justification — letting `terminate_child` +
`Process.exit(:kill)` settle before the explicit `start_room` call, since there's no message-based
signal for "Horde's bookkeeping finished"). Not blocking; flagging only because the task asked
specifically about hard waits and this is the one present.

### INFO — No other issues found

- No conditionals/try-catch used for test flow control; all new tests execute a single
  deterministic path given their fixture setup.
- Unique per-test identifiers (`:erlang.unique_integer/1`-suffixed user ids, fresh rooms per test)
  — consistent with the file's existing `async: false` sequential-execution convention, no new
  parallel-safety risk introduced.
- All new/changed test functions stay well under the 300-line guideline (longest new test,
  MAJOR-2, is ~95 lines).
- `spaces_state_events_integration_test.exs`'s addition asserts `child_event["event_id"] ==
  put_event_id` (the real id returned by the PUT) rather than a shape-only `is_binary` check —
  strong, non-synthesizable assertion. Same strict pattern in
  `spaces_foundation_integration_test.exs` for `m.room.create`, cross-checked against the real
  `events` table row.
- No assertions were weakened or removed anywhere in the staged diff — every hunk is additive.

---

## Notes

- A full `mix compile --warnings-as-errors` was attempted locally as an extra verification step
  beyond syntax-checking; the local toolchain (Elixir 1.20.4 / OTP 29) doesn't match what this
  project's `_build`/deps were last compiled against, and the run stalled partway through
  recompiling third-party deps (unrelated to the 3 files under review) before being interrupted.
  This is an environment mismatch with the project's Docker-based build (`make build-server`), not
  a finding about the diff. `Code.string_to_quoted/1` confirms all 3 files are syntactically valid
  Elixir, and every function/line reference the new test code's comments make was independently
  cross-checked against the actual current `server/lib/` source and found accurate.
- Per project convention, running the actual suite requires the full `make test-integration` stack
  (server + postgres + dex + minio); that step is for the CI gate / dev-story phase, not this
  test-quality review.
