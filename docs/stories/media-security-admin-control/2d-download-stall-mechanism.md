---
story_id: 2d-download-stall-mechanism
title: "Async Upload Endpoints: Download-Stall Mechanism (?timeout_ms=N)"
epic: media-security-admin-control
status: done
security_review: optional
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 1c made the download handler (`/_matrix/media/v3/download/…` and
`/_matrix/client/v1/media/download/…`) the single enforcement point for the media state
machine: `:released` → `200`, every other state → the deny mapping from ADR-026 (451
`M_NOT_YET_UPLOADED` for `:reserved`/`:quarantined`/`:scanning`/`scan_failed`, 404/451 for the
permanent-deny states). That mapping is correct but pessimistic for the single most common
case in the new async-upload flow (Story 2a/2b): a client that calls `/create`, `PUT`s the
bytes, and immediately calls `/download` will, in the overwhelming majority of cases, hit
`:quarantined` or `:scanning` and get an immediate 451 — even though the ClamAV scan
(Story 3/4b) typically finishes within a couple of seconds.

This story adds an opt-in `?timeout_ms=N` query parameter — the spec's actual wire name for
this parameter on the media download endpoints (the mechanism historically called "MSC2246
stall" in the epic's state-machine notes — fully core-spec since Matrix v1.7, no `unstable`
flag; Oracle Gate corrected the parameter name from an earlier draft that used `?timeout=N`,
see "Accepted Spec Deviations" below) — that lets the download handler hold the request open
and wait, event-driven via `Phoenix.PubSub`, for the scan to reach `:released` before
answering, instead of returning the 451 deny response immediately. It is purely additive: the
handler's behavior when `?timeout_ms` is absent must remain byte-for-byte identical to
Story 1c.

## User Story

As a Matrix client fetching media immediately after an async upload, I want the download
request to wait briefly for scanning to finish rather than fail immediately with a retryable
error, so that I don't have to poll `/download` in a tight client-side retry loop during the
few seconds a scan normally takes.

## Acceptance Criteria

1. **`?timeout_ms=N` query parameter (milliseconds, integer) — this is the spec's actual
   parameter name for this endpoint (not `?timeout`; see "Accepted Spec Deviations").** When
   absent (or not a valid non-negative integer — see AC7), the handler's behavior is
   **exactly** Story 1c's: an immediate state check and immediate deny/success response, no
   `Phoenix.PubSub` subscription, no waiting. **Note this is a deliberate deviation from the
   spec's own default** (the spec says an absent `timeout_ms` should behave as if a 20000ms
   wait were requested); Nebu intentionally keeps "absent → immediate, no wait" to preserve
   Story 1c's byte-for-byte behavior for existing callers. Do not "fix" this to match the
   spec default without an explicit ADR — see "Accepted Spec Deviations."
2. **Explicit cap.** The effective wait duration is `min(N, max_stall_ms)`, where
   `max_stall_ms` defaults to **20000 (20s)** — the default already named in the epic's state
   machine section — and is read from config (see Technical Requirements → Config source). A
   client-requested `N` larger than the cap is silently clamped to the cap; it is not an
   error (matches the async-upload spec's stall semantics — the server, not the client, owns
   the ceiling).
3. **Stallable vs. non-stallable non-terminal states.** Only `:quarantined` and `:scanning`
   are "worth waiting on" — a scan is pending or actively running, so a `:released`
   broadcast may still arrive. `:reserved` (bytes not yet `PUT`) is **not** stalled on: no
   scan job exists yet for this media, so waiting would tie up a request slot for a event
   that Story 2d's scope does not produce (the client is expected to `PUT` first). `:reserved`
   with `?timeout_ms` present still returns the immediate 1c deny response.
4. **Event-driven wait.** When the current state is `:quarantined` or `:scanning` and a
   (clamped) timeout > 0 applies, the handler subscribes to the media's PubSub topic
   *before* re-checking state (to close the lost-wakeup race — see Technical Requirements),
   and then waits for one of:
   - a broadcast reporting the transition to `:released` → return `200` with the file body
     (identical success path to 1c), or
   - a broadcast reporting a transition to any permanent-deny state (`:infected`,
     `:admin_blocked`, `:deleted`, `:hard_deleted`, `scan_failed`) → return that state's 1c/
     ADR-026 deny response **immediately**, without waiting out the rest of the window, or
   - the clamped timeout elapsing with no terminal broadcast received → fall back to the
     1c deny response for whatever the state is *at that point* (re-read, don't assume it is
     still `:quarantined`/`:scanning`).
5. **No busy-polling.** The wait is a single `receive/after`-style blocking wait with a
   bound, not a sleep-and-re-query loop. No code path may re-query `media_files` state on a
   fixed interval while waiting.
6. **Concurrency guard.** A configurable ceiling on the number of simultaneously held stall
   requests (global counter; per-user/IP is an acceptable stronger variant) protects against
   a burst of long-held connections exhausting request-handling capacity. When the ceiling
   is exceeded, the request degrades gracefully to the no-stall (1c) response rather than
   erroring — a request that can't get a stall slot behaves as if `?timeout_ms` were absent.
7. **Malformed `?timeout_ms` is not a client error.** A non-integer, negative, or zero value is
   treated identically to "absent" (AC1) — immediate 1c behavior. This avoids adding a new
   400 error path to a handler whose only documented error surface (ADR-026) is the state
   → status-code table.

## Acceptance Tests

Proposed location: `server/test/nebu/media/media_download_stall_test.exs`, module
`Nebu.Web.MediaDownloadStallTest`, following the existing `Nebu.Web.MediaDownloadTest`
(`server/test/nebu/media/media_download_test.exs`) setup conventions (`Plug.Test`/`Plug.Conn`,
`Nebu.Web.MediaTestSupport`, `Nebu.Web.MediaFakes`) plus a `Phoenix.PubSub` test-supervision
block matching the pattern already used in `server/test/nebu/web/log_store_test.exs` /
`server/test/nebu/web/plugs/request_logger_test.exs` (`start_supervised!({Phoenix.PubSub, name:
Nebu.PubSub})` when not already running, then `assert_receive`-based assertions).

1. **`test "released within the timeout window returns 200 with the file body"`**
   Given: media in `:scanning`, request `?timeout_ms=5000`.
   When: a broadcast transitioning the media to `:released` is published on the media's
   topic ~200ms after the request starts (simulated via a manual `StateMachine` transition +
   broadcast, per the epic's note that 2d has no hard dependency on Story 4b for testing).
   Then: the response is `200` with the correct bytes, and the test asserts the response
   arrived well before the 5000ms window elapsed (bounded wall-clock assertion, e.g. < 1s).

2. **`test "timeout elapses while still scanning falls back to the 1c deny response"`**
   Given: media in `:scanning`, request `?timeout_ms=200`.
   When: no broadcast is published during the window.
   Then: after ~200ms (not 20000ms default, not instantly), the response is the 1c mapping
   for `:scanning` (451 `M_NOT_YET_UPLOADED`).

3. **`test "an infected-deny broadcast arriving mid-wait returns 404 promptly, not after the full timeout"`**
   Given: media in `:scanning`, request `?timeout_ms=20000` (long window).
   When: a broadcast transitioning the media to `:infected` is published ~150ms in.
   Then: the response is `404 M_NOT_FOUND` and the test asserts it arrived close to 150ms,
   not close to 20000ms — this is the regression this story must guard against once Story 4b
   exists (see Dependencies: 4b coordination).

4. **`test "admin_blocked broadcast arriving mid-wait returns the anonymized 451/M_NOT_FOUND promptly"`**
   Mirrors test 3 for the `:admin_blocked` → 451 + `M_NOT_FOUND` mapping (ADR-026), confirming
   the deny-state fast-path is not special-cased to `:infected` only.

5. **`test "no ?timeout_ms param behaves exactly like story 1c (no regression)"`**
   Parametrized over all states from 1c's table (`:reserved`, `:quarantined`, `:scanning`,
   `scan_failed`, `:admin_blocked`, `:infected`, `:deleted`, `:hard_deleted`, `:released`):
   asserts identical status code + errcode + body to a request without `?timeout_ms`, and
   asserts (via a PubSub-subscriber-count or a `Process.info` mailbox check on the handling
   process) that **no** subscription to the media topic was made.

6. **`test "malformed timeout_ms values (non-integer, negative, zero) behave like absent"`**
   Table-driven over `"?timeout_ms=abc"`, `"?timeout_ms=-5"`, `"?timeout_ms=0"`: each behaves
   like test 5 for a `:scanning` media (immediate 451, no subscribe).

7. **`test "requested timeout_ms above the cap is clamped, not honored verbatim"`**
   Given: `max_stall_ms` configured to e.g. `500` for the test, request `?timeout_ms=60000`.
   When: no broadcast arrives.
   Then: the deny response arrives at ~500ms, not ~60000ms (bounded wall-clock assertion) —
   proves the clamp, not just the config default.

8. **`test "reserved state is not stalled on even with ?timeout_ms present"`**
   Given: media in `:reserved`, request `?timeout_ms=5000`.
   Then: the immediate 1c deny response returns without subscribing (mirrors AC3), asserted
   via a fast wall-clock bound (e.g. < 50ms) rather than waiting to prove a negative over the
   full window.

9. **`test "exceeding the concurrent-stall ceiling degrades to the no-stall response"`**
   Given: `max_concurrent_stalls` configured to `1` for the test, one stall request already
   held open on a different `:scanning` media.
   When: a second stall request arrives (`?timeout_ms=5000`) for another `:scanning` media.
   Then: the second request returns the immediate 1c deny response rather than blocking,
   and the first request's stall is unaffected.

## Technical Requirements

### PubSub topic & payload — coordination point with Story 4b

Topic naming, per the epic text (state-machine section and Story 2d/4b scope):
`"media:#{media_id}"` on the application's main `Nebu.PubSub` registry (the same
`Phoenix.PubSub` instance already started in `Nebu.Application` and used by
`Nebu.Web.LogStore`/`Nebu.Admin.LogsLive` — **not** `Nebu.Admin.PubSub`, which is scoped to
the Admin LiveView UI). `media_id` is the same string identifier used in the `mxc://` URI /
`media_files` primary key.

**The epic does not currently pin down the broadcast payload shape or which transitions
Story 4b actually broadcasts on** — its scope (line 579 of the epic doc) only mandates a
broadcast on the `:clean` → `scanning → released` path ("PubSub-Broadcast auf
`"media:#{id}"`"), triggering this stall mechanism. It says nothing about broadcasting on
the `:infected` or `scan_failed` transitions. **This is a hard coordination requirement for
whichever story (4b or 4c) lands the broadcast wiring, flagged explicitly here:** if 4b only
broadcasts on the released path, this story's AC4/Acceptance-Test-3/4 (prompt deny-response
on `:infected`/`:admin_blocked` arriving mid-wait) cannot be satisfied by a pure PubSub
listener — the stalled request would sit out the full timeout window even though the file
became permanently unavailable early. The dev agent implementing this story must either:

- confirm/extend Story 4b (and any story that drives `:admin_blocked`/`:deleted`/
  `scan_failed` transitions, e.g. 6a/8a/13x) to broadcast on **every** terminal transition out
  of `:quarantined`/`:scanning`, not just `:released`; or
- if 4b is not yet implemented when this story is picked up, implement the broadcast call
  as part of `Nebu.Media.StateMachine`'s transition function itself (Story 1b) so that
  *every* caller of the state machine gets the broadcast for free, removing the need to
  coordinate broadcast placement per-caller. This is the recommended approach and should be
  raised with whoever owns 1b/4b if not already the same dev agent.

Recommended payload shape (subject to whatever 4b/1b's dev agent actually lands, but the
shapes must agree exactly since this story's subscriber pattern-matches on it):
`{:media_state_transition, media_id, new_state}` where `new_state` is the state atom.

### Timeout enforcement

Per the epic's explicit constraint ("Der Stall ist ein `receive`-Block mit Timeout in einem
Task, kein Polling-Loop"): the wait must be implemented as a `Task` that subscribes to the
PubSub topic and blocks on a `receive ... after clamped_timeout -> :timeout end`, with the
calling process bounding it via `Task.await/2` (or `Task.yield/2` + explicit shutdown) using
the *same* clamped timeout plus a small fixed buffer (e.g. `+50ms`) so `Task.await` itself
never races the inner `receive`'s own timeout.

**Race protection (subscribe-then-recheck):** subscribe to the topic first, *then* re-read
the current `media_files` state. If the state has already reached `:released` or a deny
state between the handler's first read and the subscribe call, resolve immediately using
that freshly-read state rather than entering the `receive` block — otherwise a transition
that happens in that narrow window is silently missed until the full timeout elapses.

### Max-timeout cap & concurrency-ceiling config source

Both values are runtime config, read the same way other epic-introduced media settings are
sourced (ADR-027 precedent), but Story 9's dedicated `media_config` table/`Nebu.Media.Config`
module is **not** a hard dependency of this story (2d depends only on 1c/2b). Read the values
via `Application.get_env(:nebu, Nebu.Media, [])` for now, with `config.exs` defaults:

```elixir
config :nebu, Nebu.Media,
  max_stall_ms: 20_000,
  max_concurrent_stalls: 500
```

Structure the read as a single small accessor (e.g. `Nebu.Media.max_stall_ms/0`,
`Nebu.Media.max_concurrent_stalls/0`) so that swapping the source to
`Nebu.Media.Config.get/0` once Story 9 lands is a one-line change inside that accessor, not a
call-site change throughout the download handler.

### Concurrency guard implementation

A simple global counter (e.g. an `:atomics` counter or an ETS-backed counter owned by
`Nebu.Media.Supervisor`, incremented on stall-entry and decremented in an `after`/`try` block
around the `Task.await`) is sufficient — no new GenServer is required. Must be
crash-safe: if the stalling process dies mid-wait (client disconnect), the counter must not
leak upward forever.

## Accepted Spec Deviations

Captured during the Oracle Gate (Step 1b) review of this story, before ATDD started. Both
items are intentional and must not be "corrected" back toward literal spec behavior by a
later story without an explicit ADR.

1. **Query parameter renamed `?timeout` → `?timeout_ms`.** An earlier draft of this story
   used `?timeout=N` throughout (title, ACs, Acceptance Tests, File List). The Matrix
   Client-Server API's actual parameter for this endpoint is `timeout_ms` — already recorded
   correctly in Story 1c's own Oracle Gate context
   (`_bmad-output/nebu/epics/media-security-admin-control/step-results/1c-download-gate-enforcement/oracle-context.md`).
   Had this shipped as `?timeout`, the stall feature would have been silently unreachable by
   every real Matrix client (they send `timeout_ms`), while this story's own test suite
   would still pass, since it tested against the same wrong name. Corrected before dev-story;
   see `_bmad-output/nebu/epics/media-security-admin-control/step-results/2d-download-stall-mechanism/oracle-context.md`
   for the full Oracle finding.

2. **Absent `timeout_ms` → immediate, no-wait (not the spec's default 20000ms wait).** The
   Matrix spec says an absent `timeout_ms` should be treated as if a 20000ms wait were
   requested. Nebu deliberately keeps AC1's "absent → immediate 1c behavior, no
   `Phoenix.PubSub` subscription" instead, to preserve Story 1c's exact byte-for-byte response
   shape for any caller that predates this story (including any client or internal caller
   that never sends the parameter at all). This mirrors the accepted-deviation pattern already
   established by Story 1c itself (451 vs. the spec's 504 for `M_NOT_YET_UPLOADED`, per
   ADR-026). A future story wanting spec-default-on-absent behavior needs its own ADR, not a
   silent fix inside this story's code path.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media.ex` | UPDATE | `download/3,4` reads `conn.query_params["timeout_ms"]`, applies the clamp, and — for `:quarantined`/`:scanning` only — delegates to the stall wait before falling back to the existing 1c state → response mapping. |
| `server/lib/nebu/media/download_stall.ex` (new, small module) | ADD | Houses the PubSub-subscribe-then-recheck, `Task`-bound `receive/after`, and concurrency-counter logic, kept separate from `Nebu.Media`'s existing request-handling code for testability (ADR-018: still no repository/service layer — this is a coherent single capability, not a domain abstraction). |
| `server/config/config.exs` | UPDATE | Add `config :nebu, Nebu.Media, max_stall_ms: 20_000, max_concurrent_stalls: 500` defaults. |
| `server/test/nebu/media/media_download_stall_test.exs` (new) | ADD | Acceptance tests 1–9 above. |
| `server/test/nebu/media/media_fakes.ex` / `media_test_support.exs` | UPDATE (if needed) | Extend shared test helpers only if the new tests need a broadcast-helper or state-transition helper not already present. |

## Dev Agent Guardrails

### Do Not Change

- Story 1c's no-`?timeout_ms` behavior must remain **identical** — same status codes, same
  errcodes, same response bodies, same absence of any `Phoenix.PubSub.subscribe/2` call.
  Acceptance Test 5 exists specifically to pin this down as a regression guard; do not modify
  or weaken it to make the stall feature easier to wire in.
- Do not turn the deny-state → status-code table itself (ADR-026) into something this story
  re-implements. The stall mechanism must call back into the exact same mapping function 1c
  uses, not a duplicated copy.
- Do not implement the stall as a sleep-and-poll loop under any circumstance, even as a
  "temporary" simplification — AC5 and the epic text are explicit about this being
  event-driven.

## Dependencies

- **1c — Download-Gate-Enforcement.** Hard dependency: this story extends 1c's response
  path and must not change its default behavior (see Guardrails).
- **2b — async upload `PUT` handler.** Hard dependency per the epic (produces the
  `:quarantined` records this story stalls on); already satisfied structurally by the
  existing state machine (1a/1b).
- **4b — `MediaScanWorker` scan-flow + PubSub broadcast.** **No hard build-order
  dependency** — the epic explicitly allows testing this story with a manual
  `Nebu.Media.StateMachine` transition + broadcast instead of a running scan worker. **But
  there is a hard *contract* dependency, flagged explicitly (see Technical Requirements →
  "coordination point with Story 4b"):** the topic name and broadcast payload shape must be
  agreed between whichever story lands first. If this story lands before 4b, the dev agent
  should either (a) land the broadcast call inside `Nebu.Media.StateMachine`'s transition
  function itself so every future caller — including 4b, 4c, 6a's admin actions, and 8a's
  cleanup worker — gets it for free, or (b) coordinate directly with 4b's dev agent/story
  before finalizing the payload shape, and update this story's File List/tests if the agreed
  shape differs from the one recommended above.

## Dev Agent Record

### Completion Notes

Implemented the download-side stall CONSUMER only (per the coordinator's scope
decision — no producer/broadcast wiring added anywhere; `StateMachine.transition/4`
and `ScanEnqueue` untouched).

- **`Nebu.Media.DownloadStall.await/4`** (new module) resolves the wait in a
  `Task` that: (1) `Phoenix.PubSub.subscribe/2`s to `"media:#{media_id}"` on
  `Nebu.PubSub` FIRST, then (2) re-reads state via the injected `recheck_fun` —
  if already non-stallable, returns `:resolved` without entering `receive`
  (closes the lost-wakeup race). Otherwise it enters `receive_loop/2`, a single
  deadline-bounded `receive ... after remaining -> :timeout end`. An intermediate
  non-terminal broadcast (e.g. `:quarantined -> :scanning`) recurses on the SAME
  `deadline` (no budget reset, no DB re-query — AC5). The caller bounds the Task
  with `Task.await(task, clamped + 50)` so `Task.await` never races the inner
  `after`. On Task exit, `Phoenix.PubSub` auto-unsubscribes the pid (Registry
  monitor), so no subscription leaks.
- **Concurrency ceiling (AC6)** is a single global signed `:atomics` counter
  stashed in `:persistent_term` (lazy-init, no supervisor dependency — the media
  supervisor is disabled in unit runs). `acquire_slot/1` does `add_get` then
  `sub` back if over the ceiling (`:full` → `await` returns `:no_slot`).
  `release_slot/0` runs in an `after` block around the wait, so a normal exit or
  a raised exception never leaks the count. Signed atomics avoid an unsigned
  underflow wedging the ceiling closed.
- **`Nebu.Media.download/4`** now `fetch_query_params`, parses/validates/clamps
  `?timeout_ms` (`clamped_stall_ms/1`: nil/non-integer/negative/zero → `0` =
  no-stall, exactly 1c/AC1/AC7; `> cap` → clamped, AC2), and for a clamped
  timeout `> 0` on a `:quarantined`/`:scanning` row (AC3) delegates to
  `DownloadStall.await/4` BEFORE falling through to the UNCHANGED
  `with_authorised_media` → `download_gate/1` → `gate_message/1` /
  `serve_bytes/4` path. That path re-reads the (now possibly changed) row and
  applies the SAME ADR-026 mapping — so `:resolved`-via-`:released` serves 200,
  `:resolved`-via-a-deny-state returns that state's 1c response, and `:timeout`
  falls back to the re-read state's 1c response. The stall's return value is
  advisory; correctness comes entirely from re-running the 1c path. No
  duplication of the deny-state → status-code table.
- **`Nebu.Media.max_stall_ms/0` / `max_concurrent_stalls/0`** are thin public
  accessors over `Application.get_env(:nebu, Nebu.Media, [])` (config defaults
  20_000 / 500), isolated so a Story 9 `Nebu.Media.Config.get/0` swap is a
  one-line change.

**Design deviations from the story's Technical Requirements:** none. Both
"Accepted Spec Deviations" (param name `timeout_ms`; absent → immediate no-wait)
are honored. The known-gap white-box test of subscribe-then-recheck ordering
(flagged in the ATDD file's moduledoc) is covered structurally by the ordering
in `run_wait/3` but not independently unit-tested (reliably winning that race in
a test is impractical); recommended as an optional follow-up, as the story notes.

**Test result:** 10/10 story acceptance tests green
(`test/nebu/media/media_download_stall_test.exs`), plus the 20 pre-existing 1c
download/gate tests still green (regression proof), all under
`--warnings-as-errors`. Full unit suite: the only failures are 123 pre-existing
Admin LiveView tests (TraceMap/WarRoom/Bootstrap) that fail identically with
this story's changes reverted — verified against baseline (90 failures in
`test/nebu/admin/logs_live/` alone with the diff stashed). Zero media failures,
zero new compiler warnings.

### File List

| File | Change |
|---|---|
| `server/lib/nebu/media/download_stall.ex` | ADD — PubSub-subscribe-then-recheck + Task-bound `receive/after` + crash-safe `:atomics` concurrency counter. |
| `server/lib/nebu/media.ex` | UPDATE — `download/4` reads/clamps `?timeout_ms` and delegates to `DownloadStall` for `:quarantined`/`:scanning`; added `max_stall_ms/0`, `max_concurrent_stalls/0`, and private `clamped_stall_ms/1`, `maybe_await_stall/3`, `current_state/2`, `media_config/2`. |
| `server/config/config.exs` | UPDATE — `config :nebu, Nebu.Media, max_stall_ms: 20_000, max_concurrent_stalls: 500`. |

### Change Log

- 2026-07-14 — Implemented Story 2d download-stall mechanism (AC1-AC7). New
  `Nebu.Media.DownloadStall` consumer module, `download/4` `?timeout_ms` wiring,
  config defaults. 10/10 acceptance tests green; no 1c regression.
