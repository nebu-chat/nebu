# CI Gate Analysis — Story 10e

`make test-integration`: 2582 tests, 31 failures, 3 skipped (full stack, real Postgres, no per-test
sandbox rollback — this run's failures and any state a test leaves behind persist for the rest of
the suite). No Step 1d baseline was run for this story per the caller's explicit step list
(1c→1b→2→3→4→5→5b→6→7→8→9), so there is no this-run baseline log to diff against; comparison below
is against this session's own investigation of each failure plus the ~30-32 pre-existing/flaky
count previously logged by sibling stories 10a-10d in this same epic (see pipeline-state.yaml log
lines for 10b/10c/10d, all in the 30-32 range).

## Genuine new failure directly caused by this story's dev-story code

**Test #26** — `test 10e AC8/AC9: Live-Diagnose starten jump-off point AC8: ... redirects to
/admin/logs (Nebu.Admin.MediaHealthLiveTest)` (server/test/nebu/admin/media_health_live_test.exs:561)

```
** (EXIT from #PID<0.21893.0>) an exception was raised:
    ** (ArgumentError) unsafe characters detected for push_navigate/2 in URL
    <<47, 97, 100, 109, 105, 110, 47, 108, 111, 103, 115, 63, 119, 97, 114, 95,
      114, 111, 111, 109, 95, 105, 100, 61, 40, 33, 216, 240, 140, 92, 74, 138,
      161, 29, 35, 201, 174, 70, 132, 58>>
        (phoenix_live_view 1.2.3) lib/phoenix_live_view.ex:1217: Phoenix.LiveView.validate_local_url!/2
        (nebu 0.1.0) lib/nebu/admin/media_health_live.ex:126: Nebu.Admin.MediaHealthLive.handle_event/3
```

**Root cause:** `Nebu.Admin.WarRoomManager.row_to_session/1` (server/lib/nebu/admin/war_room_manager.ex:376)
returns `id` as the **raw 16-byte binary** Postgrex hands back for a native `uuid` column — it never
converts it to the canonical hex-dash string. `media_health_live.ex`'s new `handle_event("start_media_diagnosis", ...)`
(added by this story) does `push_navigate(socket, to: "/admin/logs?war_room_id=\#{session.id}")`,
interpolating that raw binary directly into a URL, which Phoenix's `validate_local_url!/2` correctly
rejects as unsafe.

This exact gap already exists in `WarRoomManager`'s public API today (pre-dates this story) — but no
prior caller of `start_session/1`/`status/0` ever interpolated `.id` into a URL/string directly. The
sibling module `Nebu.Admin.LogsLive.WarRoom` (server/lib/nebu/admin/logs_live/war_room.ex:471) has
its own **separate, duplicated** `row_to_session/1` that already does this correctly:
```elixir
# `id` is a native Postgres `uuid` column — a raw Ecto.Adapters.SQL.query!/3
# ... returns it as a 16-byte BINARY, not the canonical hex-dash STRING ...
id: Ecto.UUID.load!(id),
```
This story's new caller is the first to hit the gap in `WarRoomManager`'s own copy.

**Fix options** (either is minimal and in-scope, both touch a file this story already modifies):
1. Fix centrally in `WarRoomManager.row_to_session/1` — add `id: Ecto.UUID.load!(id)` there,
   matching the sibling module's own established pattern. Benefits every future caller of the public
   API, not just this one.
2. Fix locally at the call site in `media_health_live.ex` — `Ecto.UUID.load!(session.id)` before
   interpolating.

Option 1 seems more correct (fixes the public API's own latent bug once, at its source) but changes
the return shape of `WarRoomManager.start_session/1`/`status/0` for ALL callers — needs a check that
no existing caller relies on the raw-binary form (a quick grep of existing callers is warranted
before choosing).

## Cascading side effect — 4 further failures, same root cause

Because the crash happens **after** `WarRoomManager.start_session/1` already committed a session row
to the shared, non-sandboxed integration Postgres (this repo's `make test-integration` runs a full
stack with a real DB, not per-test transactional rollback), the session is never stopped and lingers
for the rest of the suite run. This pollutes `Nebu.Admin.LogsLive.WarRoomTest`
(server/test/nebu/admin/logs_live/war_room_test.exs — a file this story did NOT touch):

- **#16** "an empty session list shows the placeholder message with zero sessions" — fails because a
  session now IS active (leftover from #26's crash).
- **#17**, **#18** "broad/noisy-scope warnings are shown on the dedicated page" — the rendered page
  shows an unrelated, unexpected active "War Room recording" session (visible in the captured HTML:
  `data-testid="topbar-war-room-pill"`, `data-started-at="1784526649"`) instead of the test's own
  controlled fixture state.
- **#19** "3 sessions render... active first, most-recent-first" — ordering assertion fails,
  consistent with an extra, untracked session row from #26 shifted into the result set.

## Remaining ~26 failures — pre-existing/unrelated (not investigated line-by-line here, but match
categories already logged as known-flaky by sibling stories 10a-10d in this same epic's pipeline
log: `Nebu.Admin.LogsLive.TraceMapNodeControlsTest`, `Nebu.Matrix.SsoLoginTest`,
`Nebu.Matrix.MatrixSsoTest`, `Nebu.Web.AdminOidcLoginTest`, `Nebu.Admin.AdminStaleRoomsTest`,
`Nebu.Admin.ConfigControllerTest`, `Nebu.Web.RegressionSyncLoadTest`,
`Nebu.Admin.LogsLive.TraceMapTest`, `Nebu.Admin.TemporaryCaptureManagerTest` — none touch media,
scan-worker, ClamAV, or WarRoomManager code paths this story changed).

## Verdict

5 of 31 failures (test #26 + its 4 cascading victims) are a genuine, story-caused regression — a
real UUID-encoding bug in the new `start_media_diagnosis` handler exposing a pre-existing latent gap
in `WarRoomManager.row_to_session/1`, compounded by this story's crash leaving a live session
uncleaned in shared integration-test Postgres state. This is NOT cleanly attributable to
pre-existing/unrelated flakiness — it requires a dev-story fix-cycle before CI gate can pass.
