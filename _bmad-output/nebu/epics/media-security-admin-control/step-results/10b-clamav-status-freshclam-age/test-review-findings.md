# Pre-dev test-review — Story 10b (clamav-status-freshclam-age)

## Verification of ATDD's AT5 boundary-math flag
CONFIRMED accurate: story's own "Threshold comparison" pseudocode (hour-truncated
DateTime.diff) does NOT distinguish 48h-1s from 48h+1s (both truncate such that
`48 > 48` is false in both cases under the literal formula) — a naive hour-truncated
implementation FAILS the AT5 test as written (172801s -> 48 whole hours -> `48>48`=false
but test expects true), while a correct second-precision implementation
(`DateTime.diff(now, built_at, :second) > signature_max_age_hours * 3600`) passes. The
pin is real, not toothless. dev-story MUST use second-level precision, not the story's
literal Technical Requirements pseudocode formula.

## MAJOR
1. AT6's own stated requirement ("dashboard renders a clear 'Alter unbekannt' state") is
   never verified against RENDERED output. clamav_status_indicator_test.exs's AT6 only
   checks socket.assigns (`clamav_signature_age == :unknown`, `clamav_signature_stale? ==
   false`) — no HTML assertion. media_health_live_test.exs has NO malformed-VERSION-reply
   case at all (only AT1-4 covered there). A template that mishandles :unknown (crash,
   blank, or silently falls into fresh/stale branch) would NOT be caught, even though
   AT3/AT4 already establish the pattern of asserting literal rendered copy. Needs one
   more LiveView-level test case.

## MINOR
2. AT1 (status/0 connected case) pattern-matches signature_age only by type
   ({:ok, %DateTime{}}), not value — a status/0 that hardcodes DateTime.utc_now() instead
   of calling signature_info/0 would still pass this test in isolation (mitigated by
   AT3/AT4 at the LiveView level).
3. AT2 (helper level, disconnected) leaves signature_age fully unconstrained in its
   partial map match — should assert some {:error, _} shape.
4. "GenServer not running" guard test only asserts %{healthy: false} partial match,
   never piped through assign_status/2 — if status/0's not-running branch omits
   changed_at/signature_age keys, assign_status/2's pattern match would raise, exactly
   the crash the Technical Requirements explicitly says this guard must avoid. No test
   proves the full guard->assign pipeline handles it end to end.
5. Neither assign_status/2 test touches :clamav_healthy/:clamav_down_since directly —
   only indirectly via LiveView-rendered HTML. Worth one helper-level case asserting all
   4 documented assigns from one representative status map.
6. Story-level (not test) issue: story's own "Technical Requirements > Threshold
   comparison" section still states the flawed hour-truncated formula verbatim,
   uncorrected — risk of a wasted dev-story cycle if someone implements literally from
   that section without reading the test's inline comment. Worth correcting the story
   text itself.

## INFO
7. clamav_fake_server.exs's zVERSION dispatch reads byte-by-byte to the NUL terminator
   then branches on the full command string — correctly distinguishes zINSTREAM\0 (10B)
   vs zVERSION\0 (9B) regardless of TCP segmentation.
8. Fake's default VERSION reply + format_asctime/1 exactly match the real verified
   protocol capture (clamav-version-protocol-verification.md) — faithful to ground truth.
9. socket_with/1 bare %Phoenix.LiveView.Socket{} pattern verified against existing
   media_attention_badge_test.exs precedent (socket_with_count/1) — legitimate.
10. Good split: helper tests avoid Postgres/@moduletag :integration; LiveView tests carry
    it. No redundant coverage; deliberate double-coverage explained inline for AT1/AT2.
11. async: false correctly used given the shared named-GenServer singleton and
    Application.put_env mutation.
12. Two short Process.sleep(20) calls are pre-existing Story-3 pattern for real time-gap
    ordering checks — not flaky (only needs "definitely later," not exact duration).

## Verdict
1 MAJOR (AT6 rendered-output coverage gap), 5 MINOR, 6 INFO. Per pipeline policy, MAJOR
findings at the pre-dev test-review gate are escalated to the user rather than
auto-fixed by this orchestrator.
