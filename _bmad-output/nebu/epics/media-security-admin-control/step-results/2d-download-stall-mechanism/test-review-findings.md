# Test Quality Review — `server/test/nebu/media/media_download_stall_test.exs`

**Scope:** RED-phase ATDD file, 10 tests, `Nebu.Web.MediaDownloadStallTest`, story `media-security-admin-control/2d-download-stall-mechanism`. Pre-dev-story gate.

**RESOLVED (coordinator decision: "fix"):** the MAJOR finding below has already been fixed in
the test file, before dev-story started. Added `elapsed < 100ms` wall-clock bounds to test 5
(the deny-table loop AND its separate `:released` counterpart) and test 6 (malformed-values
loop), so "the stall branch was never entered" is directly observable rather than inferred
from a post-hoc `Registry.lookup` check alone. Also folded in the cheap MINORs: tightened
AT2's upper bound to `<1_000` (was `<20_000`), AT3/AT4 to `<750` (was `<2_000`), AT7 to
`<1_500` (was `<5_000`), loosened AT8 from `<50` to `<150` (flakiness risk), and made
`state_agent` explicitly `Agent.stop/1`'d in `on_exit` (was previously unsupervised). Re-ran
the file after the fix: still 4/10 pass (the regression pins, now with the added bound
making them a real regression guard)/6 RED with identical failure reasons — confirms the fix
did not change the RED-phase status, only strengthened the pins. MINOR-5 (no test pins the
actual default `max_stall_ms` value) was left as dev-story cleanup material, per the
coordinator's explicit instruction, since it would require a real ~20s wait to test cheaply.

**Original verdict (superseded by the fix above): NOT CLEAN — 1 MAJOR finding.** Everything
else is MINOR/INFO. Coverage of the 9 acceptance-test scenarios is complete (test 5's story
scenario is split into two tests: deny-table loop + `:released`), house style matches
`media_download_test.exs`/`media_download_gate_test.exs` closely, and `async: false` is
correctly required (the file mutates global `Application` env keys shared with the sibling
files, exactly like they do).

---

## MAJOR

**1. The "no PubSub subscription" regression pins for AC1 (test 5) and AC7 (test 6) cannot actually catch the regression they exist to guard against — unlike test 8, they have no compensating wall-clock bound.**

- File: `server/test/nebu/media/media_download_stall_test.exs`
- Lines: test 5 `339–362` (loop + `Registry.lookup` at `357–360`), test 6 `381–401` (`Registry.lookup` at `398–400`); contrast with test 8 `434–454` (has both `elapsed < 50` at line 448 **and** the same `Registry.lookup` check at `452–453`).
- Summary: `Registry.lookup(Nebu.PubSub, topic)` is a sound, verified mechanism (see below) for detecting a *currently live* subscriber — but it is checked only *after* `get(...)` has already returned. Since `get/2` is a fully synchronous call, any subscription made while handling that request must, by construction, already have ended (Task exited / process died / explicit unsubscribe) by the time the HTTP response is produced and control returns to the assertion. This is true regardless of implementation strategy — it's not a Task-specific quirk, it's inherent to asserting-after-a-synchronous-call-returns. So `Registry.lookup(...) == []` will be empty **both** when the correct no-stall path ran (never subscribed) **and** when a buggy implementation incorrectly entered the stall/subscribe path and then resolved (subscribed, then cleaned up before returning) — it cannot distinguish the two.
- Failure scenario: suppose a future refactor breaks AC1/AC7 gating so that an absent or malformed `?timeout_ms` incorrectly falls into the stallable branch for `:quarantined`/`:scanning` media (e.g., a guard condition inverted). If the erroneous wait is short (the state doesn't change, so it resolves to the same 451/M_NOT_YET_UPLOADED after some clamped wait), tests 5 and 6 as written have **zero signal**: status/errcode/error still match (same terminal state, just reached slower), and `Registry.lookup` is empty post-hoc regardless. The only way this bug becomes visible is if the erroneous wait is long enough to trip ExUnit's own test timeout (an opaque hang, not a clear assertion failure) — and even then, only if it's close to `max_stall_ms` (20s default), not for anything shorter.
- Contrast: test 8 (`:reserved`) *does* have `assert elapsed < 50` (line 448), so the exact same class of regression on AC3 would be caught immediately and clearly there.
- Fix (cheap, ~2 lines per test): add a wall-clock upper bound to test 5's loop and test 6's loop, mirroring test 8's pattern (e.g. `elapsed < 50` or similar per iteration), so "did we take the stall branch at all" is asserted directly instead of relying on a check that's structurally incapable of it.
- This should block dev-story: without it, dev-story could plausibly break AC1/AC7 in exactly the way these two tests are supposed to pin, and CI would stay green.

**Mechanism verification (requested explicitly):** `Registry.lookup(Nebu.PubSub, topic)` *is* the correct way to inspect Phoenix.PubSub's local subscriber set — confirmed by reading `deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex` (the `Registry` child is started with `name: name`, i.e. the same atom passed to `{Phoenix.PubSub, name: Nebu.PubSub}`) and `deps/phoenix_pubsub/lib/phoenix/pubsub.ex:205` (`subscribe/3` calls `Registry.register(pubsub, topic, opts[:metadata])`). So the mechanism itself is sound; the problem above is purely about *when* it's checked, not *what* it checks.

---

## MINOR

1. **AT2 upper bound too loose** (line `276–277`, `assert elapsed < 20_000`) — for a `timeout_ms=200` request, a bound of 20s only catches the one specific "fell back to spec's absent-default 20000ms" bug near its exact boundary; a hardcoded wrong wait of, say, 5–15s would slip through undetected. Tighten to something like `< 1_000`.
2. **AT3/AT4 upper bounds loose relative to the event** (lines `302–304`, `332–334`, `assert elapsed < 2_000` for a broadcast at ~150ms) — generous enough that a regression to coarse periodic polling (which AC5 explicitly forbids) could still pass. Consider tightening to ~500–750ms; still ample CI margin.
3. **AT7 clamp bound very loose** (lines `421–428`, target ~500ms clamped, upper bound `< 5_000`) — a 10x margin; a smaller multiplier (e.g. `< 1_500`) would still be CI-safe while catching grosser clamp-math errors.
4. **AT8's `elapsed < 50` bound (line 448) is the tightest in the file and a real CI-flakiness risk**, as flagged for review — every other timing test in the file uses ≥500ms margins; this one relies on RSA/JWT verification + BEAM scheduling completing in <50ms under CI load. Recommend loosening to ~150–200ms to match the file's own margin discipline elsewhere, without weakening the "must not stall" intent.
5. **No acceptance test pins the actual default `max_stall_ms` (20000ms)** — tests 1–4 all use timeouts ≤ 20000 without exceeding it, and test 7 explicitly overrides the cap to 500. A wrong default in `config.exs` (or a future off-by-order-of-magnitude bug in the accessor) would not be caught by anything in this file.
6. **`state_agent` (line 107, `Agent.start_link`) is not `start_supervised!`'d or explicitly stopped in `on_exit`.** Since an ExUnit test process that finishes normally exits with reason `:normal`, which does not propagate a kill signal to non-trapping linked processes, these Agents are not guaranteed to terminate at test end — a small (~10 processes for this file) but real leak, and inconsistent with the file's own more careful `ensure_pubsub_started!`/`start_supervised!` treatment of `Nebu.PubSub`.

## INFO

1. **`@deny_table` (lines 91–100) is a second hand-maintained copy of ADR-026's status/errcode/error mapping** — `media_download_gate_test.exs` itself doesn't centralize this table either (it inlines expected values per test), so this is consistent with existing house style, not a new problem, but it is a drift risk if ADR-026's mapping ever changes and only one of the two files gets updated. Consider extracting a single shared constant in a later cleanup story, not blocking.
2. **Lost-wakeup race (subscribe-before-recheck) is not independently exercised at acceptance level**, as the ATDD author already flagged (moduledoc lines 63–75). Agreed this is impractical to test black-box without an internal hook to pause the handler mid-flow. Non-blocking: recommend dev-story (or a fast test-review-of-implementation follow-up) add a white-box/unit test of `Nebu.Media.DownloadStall`'s internal subscribe-then-recheck ordering once that module exists — but this should not block dev-story from starting now.
3. Test 9 doesn't verify a third request can acquire a slot once the first holder's slot is released — not required by the story's Acceptance Tests, optional nice-to-have.

---

## Summary for the pipeline

- Coverage: complete (all 9 story ATs represented across 10 tests).
- House style: consistent with `media_download_test.exs`/`media_download_gate_test.exs`.
- `async: false`: correct and necessary.
- PubSub "no subscribe" mechanism: technically sound, but misapplied in tests 5 & 6 (MAJOR — recommend fixing before dev-story starts, cheap fix).
- Timing margins: workable but uneven — one bound too tight (test 8), several too loose (tests 2, 3, 4, 7) — all MINOR, non-blocking but worth tightening/loosening for consistency.
- The 4b-not-landed simulation and the "vacuous until stall exists" posture for tests 5/6/8 are correctly-scoped decisions per the story, not treated as defects here — except that the *strength* of two of those three pins (5 and 6) is insufficient, which is the MAJOR finding above.
