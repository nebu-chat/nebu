---
story_id: 5b-live-updates-nav-badges
title: "Admin Media Overview: Live Row Updates + Nav Attention Badges"
epic: media-security-admin-control
status: ready-for-dev
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 5a delivers `/admin/media`, a Phoenix LiveView table with filters, pagination, and
multi-select. Its rows are a point-in-time snapshot from mount/patch — nothing updates them
once a scan completes elsewhere. This story adds the two PubSub-driven realtime pieces the
epic scopes separately from 5a: (1) in-place row updates on the media table when a file's
state changes (no full LiveView re-render, no page reload), and (2) an admin-nav "attention"
badge showing a live count of files in states that need an admin's action.

**Design choice, stated explicitly (per epic Story 5b scope + coordination note in
`2d-download-stall-mechanism.md`):** Story 2d/4b's PubSub topic is scoped **per file**
(`"media:#{media_id}"`, one topic per `media_id`) — correct for a download handler that only
ever cares about one file at a time. The admin media table shows up to 50 rows per page and
the nav badge must reflect **every** file in the system regardless of which page is open, so
subscribing the admin LiveView to one `"media:#{media_id}"` topic per visible row (up to 50+
subscriptions per connected admin, none of them cleaned up correctly without per-row
`unsubscribe` bookkeeping on every re-page/filter change) does not scale and is explicitly
disallowed by this story's guardrails. Instead, this story introduces a **second, broader
topic** — `"media:admin"` — that every media state transition broadcasts on *in addition to*
the existing per-`media_id` topic. The admin LiveView subscribes to this **one** topic, once,
for its entire lifetime, and uses the payload's `media_id` to find-and-patch the right row (or
ignore it, if that row isn't in the current page/filter) and to run the badge delta
arithmetic.

**Second design choice, stated explicitly:** true "no full reload" liveness is only possible
inside a LiveView's own process (`handle_info/2`), because only a LiveView has a persistent
process that can receive a PubSub message.

**Correction (2026-07-18, dev-story — verified against the actual `server/lib/nebu/admin/router.ex`
before implementation, per this story's own Dependencies/Guardrails instruction to check 5a's
reality first):** an earlier draft of this story asserted "only 3 LiveViews currently exist
under the admin `live_session`" (`LogsLive` + its `TraceMap`/`WarRoom` sub-pages). That is
stale relative to the live router: `live_session :admin` (router.ex line ~225) actually
declares **5** pre-existing LiveViews — `Nebu.Admin.DashboardLive`, `Nebu.Admin.AuditLogLive`,
`Nebu.Admin.LogsLive`, `Nebu.Admin.LogsLive.TraceMap`, `Nebu.Admin.LogsLive.WarRoom` — not 3.
`Nebu.Admin.WarRoomIndicator` (the shared-helper precedent this story's Technical Requirements
section explicitly names as the pattern to mirror) is already wired into all 5, per its own
moduledoc ("every remaining admin LiveView"). Users/Rooms/Spaces/Config are correctly
identified as dead-render controllers — that part of the original premise was right, only the
LiveView count was wrong. This story therefore wires the attention badge into all **6** LiveViews
(the 5 pre-existing ones plus 5a's new `MediaLive`), not 4 — closing a gap where Dashboard/
AuditLog would otherwise show no live badge at all while Logs/TraceMap/WarRoom/Media did,
which would be a visible, page-dependent inconsistency rather than a deliberate scope boundary.
The two-tier split below is otherwise unchanged and still correct:

- On any LiveView page (all 6: Dashboard, AuditLog, Logs, TraceMap, WarRoom, Media), the badge
  updates live, in place, as `"media:admin"` broadcasts arrive — the epic's literal "kein
  Full-Reload" requirement.
- On controller-rendered pages (Users/Rooms/Spaces/Config), the badge is computed fresh
  (cheap inline `COUNT`) on every page request via the existing `Nebu.Admin.Auth.require_admin`
  plug pipeline, so it is never more than one navigation stale — but it cannot tick up/down
  mid-view on those pages, since there is no process there to patch. This is a platform
  constraint of Nebu's mixed LiveView/dead-controller admin UI, not a gap in this story.

## User Story

As an admin operator, I want the `/admin/media` table to update rows live as scans complete
and a nav badge to show me, from anywhere in the admin UI, how many files currently need my
attention, so that I don't have to manually refresh the page or click into Media just to
discover a new `:infected`/`:scan_failed` file.

## Acceptance Criteria

1. **Live row update, no full reload.** When a media file visible in the current page/filter
   of the `/admin/media` table (5a) transitions state, the LiveView receives a
   `"media:admin"` broadcast and patches **only that row** (state badge, `scanned_at`,
   ClamAV signature if present) via a LiveView stream update — the rest of the table (other
   rows, current filters, current pagination cursor, and 5a's multi-select selection state)
   is untouched. A row for a `media_id` not present in the current page/filter is ignored (no
   row is inserted out of pagination order).
2. **Attention-badge state set, defined exactly.** The nav badge counts files whose current
   state is one of exactly `:quarantined`, `scan_failed`, or `:infected` — the three states
   named in the epic's Story 5b scope. Explicitly **excluded**: `:reserved`/`:scanning`
   (nothing actionable yet — bytes not uploaded, or a scan actively running), `:admin_blocked`
   (already a deliberate, visible admin action, not something needing *further* attention),
   and the terminal states `:released`/`:deleted`/`:hard_deleted` (resolved). `:quarantined`
   is included even though most quarantined files clear within seconds (Story 2d's stall
   window) — the DB cannot distinguish "just arrived, scan pending" from "scan job silently
   never got enqueued/stuck," so the conservative choice is to count it and let the admin
   judge from the table's `uploaded_at` column, rather than have a stuck file invisible.
3. **Badge is visible without a page refresh** on any of the 6 LiveView pages (5a's Admin
   Media table + the 5 pre-existing LiveViews — Dashboard, AuditLog, Logs, TraceMap, WarRoom;
   corrected 2026-07-18, see Summary) — updates arrive via the `"media:admin"` subscription's
   `handle_info/2`, not via polling.
4. **Badge accuracy under concurrent updates (no stale-count drift).** Two admins with
   `/admin/media` open in separate browser tabs/sessions, each with their own LiveView
   process, must independently converge on the same count after the same sequence of
   broadcasts — no shared mutable counter that one session's read/write could race against
   another's. A **fresh page load/reconnect always re-derives the count from the DB** (a cheap
   `COUNT` query, not an inherited/cached value) — so drift, if a broadcast is ever missed
   (e.g. brief PubSub/network hiccup), is bounded to the remaining lifetime of that one
   LiveView process and self-heals on next navigation or LiveView remount, rather than
   accumulating indefinitely.

## Acceptance Tests

Proposed location: `server/test/nebu/admin/media_live_test.exs` (extends 5a's test module,
`Nebu.Admin.MediaLiveTest`) for the row-update tests, plus a new
`server/test/nebu/admin/media_attention_badge_test.exs` (`Nebu.Admin.MediaAttentionBadgeTest`)
for the badge-count unit/LiveView tests. Follows the `Phoenix.LiveViewTest`
subscribe-and-`assert_receive`/`render` conventions already established in
`server/test/nebu/admin/logs_live_test.exs` (a `safe_broadcast/1` helper that no-ops if
`Nebu.PubSub` isn't running, `Phoenix.PubSub.broadcast(Nebu.PubSub, @topic, payload)` directly
in tests rather than going through a real Oban/ClamAV pipeline).

1. **`test "a media_id visible in the current page gets its row patched in place on a state-transition broadcast"`**
   Given: the table mounted showing a `:scanning` row for `media_id`. When:
   `Phoenix.PubSub.broadcast(Nebu.PubSub, "media:admin", {:media_state_transition, media_id, :scanning, :released})`.
   Then: `render(view)` shows the `:released` badge for that row's `data-testid`, and no other
   row's markup changed (assert via a stable snapshot of the other rows' HTML, or a stream
   `:updated_at`/version marker if the LiveView tracks one).

2. **`test "a broadcast for a media_id not in the current page/filter is ignored, no phantom row appears"`**
   Given: the table mounted with an active filter that excludes `media_id_x`. When: a
   broadcast arrives for `media_id_x`. Then: the rendered row count is unchanged and no row
   for `media_id_x` appears.

3. **`test "multi-select selection survives a live row update for an unrelated row"`**
   Given: 5a's checkboxes — rows A and B selected. When: row C (unselected, visible)
   transitions via broadcast. Then: A and B remain checked after the patch (regression guard
   tying 5b's design explicitly to 5a's "PubSub darf die Selektion nicht leeren" AC).

4. **`test "badge count reflects DB state on initial mount, derived from a fresh COUNT, not a cached value"`**
   Given: `media_files` seeded directly (bypassing PubSub) with 2 `:quarantined`, 1
   `scan_failed`, 1 `:infected`, 3 `:released`. When: any admin LiveView (parametrize over
   `MediaLive`, `DashboardLive`, `AuditLogLive`, and one of the Logs LiveViews — corrected
   2026-07-18, see Summary: 6 LiveViews total, not 4) is mounted fresh. Then: the assigned
   badge count is `4`.

5. **`test "badge count increments when a file transitions into an attention state"`**
   Given: badge count `N` after mount. When: a broadcast
   `{:media_state_transition, media_id, :scanning, :infected}` arrives. Then: badge count is
   `N + 1`. Parametrize the "into" transitions: `:scanning → :infected`,
   `:scanning → scan_failed`, `:reserved → :quarantined`.

6. **`test "badge count decrements when a file transitions out of an attention state"`**
   Mirrors test 5 for "out" transitions: `:quarantined → :released` (admin override/rescan
   clean), `:infected → :deleted` (admin deletes an infected file), `scan_failed → :scanning`
   (manual rescan re-enters, per 6a — still not in the counted set, so this should NOT double
   count; assert count is unchanged only if `:scanning` truly isn't counted, see AC2).

7. **`test "transitions entirely outside the attention set never move the badge"`**
   Table-driven: `:released → :deleted`, `:reserved → :quarantined → :scanning` chain that
   ends outside the set relative to where it started counted, `:admin_blocked → :released`.
   Each asserts the badge count is unchanged by that specific broadcast.

8. **`test "no per-media_id subscription is created by the admin LiveView — only the broad media:admin topic"`**
   Given: the Admin Media LiveView mounted with a full page of 50 rows across many distinct
   `media_id`s. Then: assert (via `Registry`/`Phoenix.PubSub`'s internal subscriber
   introspection, or a test-only counter shim on a wrapped `subscribe/2`) that exactly **one**
   subscription was made by that LiveView process, and it is to `"media:admin"` — not 50
   subscriptions to 50 `"media:#{media_id}"` topics. This is the regression guard for the
   scaling concern in Summary/Guardrails.

9. **`test "two independently mounted LiveView sessions converge on the same badge count from the same broadcast sequence"`**
   Given: two separate `live/2` test connections (simulating two admin browser tabs), both
   showing badge count `N`. When: the same sequence of 3 broadcasts is published once (a
   single `Phoenix.PubSub.broadcast/3` call reaches both subscribers, it is not re-published
   per session). Then: both sessions' assigns show the identical final count — proves there is
   no shared mutable counter one session could race against the other on (each LiveView keeps
   its own `socket.assigns` copy, arithmetic is purely a function of the broadcasts it
   personally received).

## Technical Requirements

### Broadcast topic & payload — extends, does not replace, 2d/4b's per-`media_id` topic

- New topic: `"media:admin"` on the same `Nebu.PubSub` registry already used for
  `"media:#{media_id}"` (2d) and `"operational_logs"` (`Nebu.Admin.LogsLive`) — i.e. the
  application-wide `Nebu.PubSub`, not a separate `Nebu.Admin.PubSub`.
- Payload: `{:media_state_transition, media_id, old_state, new_state}` — **note this extends
  the shape 2d recommended** (`{:media_state_transition, media_id, new_state}`, no
  `old_state`). 5b's badge-delta arithmetic (AC4/Acceptance Tests 5–7) needs to know what
  state a file is *leaving*, not just what it's entering, to decide +1/−1/0 — a payload
  without `old_state` cannot distinguish "entering `:infected` from `:scanning`" (attention +1)
  from "re-entering `:infected` from `:infected`" (no-op, shouldn't happen but must not
  double-count if it did) or classify an exit correctly.
- **Cross-story coordination requirement, flagged explicitly (mirrors 2d's own flag on
  4b):** whichever story lands the actual broadcast call site — ideally
  `Nebu.Media.StateMachine`'s transition function itself (1b), per 2d's own recommendation,
  so every caller (4b's scan worker, 6a's admin actions, 8a's cleanup worker, 13x's lifecycle
  jobs) gets both broadcasts for free — must emit **both** topics from that one call site with
  the **4-tuple** shape (`old_state` included), not the 3-tuple 2d wrote down in isolation. If
  2d/4b land first with the 3-tuple already wired into `"media:#{media_id}"`, this story's dev
  agent must either (a) extend that single call site to also emit the 4-tuple on
  `"media:admin"`, or (b) if the call site can't cheaply be extended to know `old_state`,
  broadcast the 4-tuple from `Nebu.Media.StateMachine.transition/3` itself (it always has both
  the prior and new state in hand) and treat 2d's 3-tuple on `"media:#{media_id}"` as a
  separate, narrower broadcast — but a single call site emitting both is strongly preferred to
  avoid two payload shapes for the same event.

### Badge count: cheap inline `COUNT`, not a maintained counter — justified

Two candidate designs; this story picks the first:

1. **Inline SQL `COUNT` at mount/reconnect, deltas via in-process arithmetic thereafter**
   (chosen). `Nebu.Admin.MediaAttentionBadge.initial_count/0` runs one query —
   `SELECT count(*) FROM media_files WHERE state = ANY($1)` with the 3-element state array —
   assigned once per LiveView mount. Every subsequent `"media:admin"` broadcast adjusts the
   in-`socket.assigns` integer by `classify(new_state) - classify(old_state)` (where
   `classify/1` is `1` if the state is in the attention set, else `0`) — no DB round-trip per
   broadcast.
2. **Maintained counter** (e.g. a `media_attention_counts` row/column updated
   transactionally alongside every `media_state_transitions` insert) — rejected: it is a
   second source of truth for a value that is trivially derivable via `COUNT`, needs its own
   transactional consistency guarantee against the append-only `media_state_transitions`
   table (ADR-031), and ADR-018 (no domain model) already discourages new persistent
   aggregate structures where a query suffices. `media_files.state` should already carry (or
   gain, if 1a doesn't have one) a plain B-tree/partial index usable by this `COUNT`; table
   volumes in a self-hosted compliance deployment (this epic's target audience — German
   Kommunen/Behörden, not hyperscale SaaS) do not warrant a maintained counter's added
   complexity.

The "one query per mount, zero queries per broadcast" split is what keeps this cheap even
with several admins' browser tabs open simultaneously — the query load scales with concurrent
*admin sessions*, not with media *event volume*.

### LiveView wiring — shared helper module, mirroring the existing `WarRoomIndicator` precedent

`server/lib/nebu/admin/war_room_indicator.ex` is already the pattern for "a small stateless
helper module that multiple LiveViews call from their own `mount/3` and `handle_info/2` to
avoid duplicating a cross-cutting concern" (see `WarRoomIndicator.assign_status/2`, used from
`Nebu.Admin.LogsLive`, `.TraceMap`, and `.WarRoom`). This story introduces the analogous
`Nebu.Admin.MediaAttentionBadge`:

```elixir
Nebu.Admin.MediaAttentionBadge.subscribe()            # Phoenix.PubSub.subscribe(Nebu.PubSub, "media:admin")
Nebu.Admin.MediaAttentionBadge.initial_count()        # the COUNT query, for mount/3
Nebu.Admin.MediaAttentionBadge.apply_transition(socket, old_state, new_state)
  # -> socket with :media_attention_count adjusted by the classify/1 delta; assign_new-safe
```

- On_mount: because `on_mount` hooks execute inside the target LiveView module's own process
  but cannot inject a `handle_info/2` clause into a *different* module, this story does **not**
  try to make the badge fully automatic via the existing `{Nebu.Admin.Auth, :require_admin}`
  hook. Instead: each of the **6** LiveViews under `live_session :admin`
  (`Nebu.Admin.DashboardLive`, `.AuditLogLive`, `.LogsLive`, `.LogsLive.TraceMap`,
  `.LogsLive.WarRoom`, and 5a's new `.MediaLive` — corrected 2026-07-18, see Summary) calls
  `MediaAttentionBadge.subscribe()` + assigns `initial_count()` in its own `mount/3` (one line
  each, same shape as the existing `WarRoomIndicator.assign_status/2` call, already present in
  all 6 of these exact modules), and adds one `handle_info` clause delegating to
  `MediaAttentionBadge.apply_transition/3` — matching how `Nebu.Admin.LogsLive`'s existing
  `handle_info(%{...} = entry, socket)` clauses are already one-per-message-shape in that
  module.
- `Nebu.Admin.Layouts.live/1` gains an `assign_new(:media_attention_count, fn -> nil end)`
  (LiveView path) / `Map.put_new(..., nil)` (dead-render path) fallback, mirroring the existing
  `war_room_active` pattern exactly, and renders the count as a small numeric badge next to
  the "Medien" nav item. **Correction (2026-07-18, dev-story):** the story draft assumed a
  nested "Medien" parent nav item exists ("introduced by Review 9's IA change") — it does not.
  `server/lib/nebu/admin/layouts.ex`'s own inline comments (from 9b/5a) confirm no such Story 0
  "Medien parent" has landed; `key="media"` is still a plain top-level `<.nav_item>` leaf
  (mirrors the Dashboard/Compliance leaves). The badge attaches to that existing flat leaf's
  `inner_block` instead — functionally identical placement, no invented IA. `nil` (dead-render/
  controller pages that haven't been updated to pass a live-derived count) renders no badge —
  controller pages instead pass a freshly-queried `MediaAttentionBadge.initial_count()` result
  computed once per request in their existing plug pipeline (satisfies AC3's "visible without a
  page refresh" only in the sense of "correct as of this page load"; see Summary's two-tier note
  for the LiveView-only true-live behavior). **This story does not modify the controller files**
  to wire that fresh-COUNT pass-through — no AC requires it (AC3 is scoped exactly to the 6
  LiveView pages) and it is not in this story's File List; `nil`/no-badge on controller pages is
  the correct, in-scope behavior for this story.
- Row-patch mechanism for AC1: 5a's table must be backed by a `Phoenix.LiveView.stream/3` (not
  a plain assign of a list) so that `stream_insert/3` can patch a single row's fields without
  Phoenix re-diffing/re-rendering the other 49 rows — verify 5a actually used `stream/3`
  before building on it; if 5a used a plain list assign, this story must convert it to a
  stream as part of wiring in the row-patch handler (flag this as a possible scope creep into
  5a's file if that conversion turns out to be non-trivial, and coordinate rather than
  silently expanding 5a's already-`ready-for-dev`/in-progress scope).

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/admin/media_attention_badge.ex` (new) | ADD | `subscribe/0`, `initial_count/0` (inline `COUNT` SQL over the 3-state attention set), `apply_transition/3` (delta arithmetic), `classify/1`. |
| `server/lib/nebu/media/state_machine.ex` | UPDATE | **Corrected 2026-07-18 (dev-story):** 4b already landed and broadcasts the 3-tuple `{:media_state_transition, media_id, new_state}` on `"media:#{media_id}"` from `Nebu.Workers.MediaScanWorker`'s own private `broadcast/2`, consumed by 2d's `Nebu.Media.DownloadStall` via a strict 3-tuple `receive` pattern match. Changing that existing broadcast to a 4-tuple would silently stop matching in `DownloadStall` (no crash — the message would simply never satisfy the `receive` clause, degrading every stall to a timeout). Per this story's own prescribed fallback, `transition/4`'s `write_transition/6` (which always has both `from_state`/`to_state` in hand) ADDS a **new, separate** broadcast of the 4-tuple `{:media_state_transition, media_id, old_state, new_state}` on `"media:admin"` **only** — the existing 3-tuple broadcast on `"media:#{media_id}"` in `media_scan_worker.ex` is left completely unchanged. |
| `server/lib/nebu/admin/media_live.ex` (5a's module, confirmed already `stream/3`-backed) | UPDATE | Add `MediaAttentionBadge.subscribe/0` + initial-count assign in `mount/3`; add `handle_info/2` for row-patch (`stream_insert/3` when `media_id` is in the current page, no-op otherwise) + badge delta. |
| `server/lib/nebu/admin/logs_live.ex` | UPDATE | One-line `MediaAttentionBadge.subscribe/0` + initial-count assign in `mount/3`; one `handle_info` clause delegating to `apply_transition/3`. |
| `server/lib/nebu/admin/logs_live/trace_map.ex` | UPDATE | Same one-line wiring as `logs_live.ex`. |
| `server/lib/nebu/admin/logs_live/war_room.ex` | UPDATE | Same one-line wiring as `logs_live.ex`. |
| `server/lib/nebu/admin/dashboard_live.ex` | UPDATE | **Added 2026-07-18 (dev-story, Option B correction — see Summary):** same one-line wiring as `logs_live.ex`; already carries the identical `WarRoomIndicator` precedent. |
| `server/lib/nebu/admin/audit_log_live.ex` | UPDATE | **Added 2026-07-18 (dev-story, Option B correction — see Summary):** same one-line wiring as `logs_live.ex`; already carries the identical `WarRoomIndicator` precedent. |
| `server/lib/nebu/admin/layouts.ex` | UPDATE | `assign_new(:media_attention_count, fn -> nil end)` / `Map.put_new` fallback (mirrors `war_room_active`); render the numeric badge next to the existing flat "Medien" `<.nav_item>` leaf (no nested parent exists — see correction above) when `media_attention_count` is a non-nil, positive integer. |
| `server/test/nebu/admin/media_live_test.exs` | UPDATE | Acceptance Tests 1–3, 8. |
| `server/test/nebu/admin/media_attention_badge_test.exs` (new) | ADD | Acceptance Tests 4–7, 9 (parametrized over all 6 LiveViews). |

## Dev Agent Guardrails

### Do Not Change

- **Do not subscribe the admin media LiveView to one `"media:#{media_id}"` topic per visible
  row.** This is the core anti-pattern this story exists to avoid (see Summary/Acceptance Test
  8) — it does not scale past a handful of rows, requires exact `unsubscribe` bookkeeping on
  every filter/page change (easy to leak), and duplicates the topic Story 2d already owns for
  a different purpose (a single download request waiting on a single file). Use the one broad
  `"media:admin"` topic instead.
- Do not make the badge count a second persistent data structure (a counter column/table) —
  see Technical Requirements' justification for the inline-`COUNT`-plus-in-process-delta
  design. If a future story needs this to scale further, that is a deliberate follow-up
  decision, not something to pre-empt here.
- Do not have controller-rendered admin pages (Users/Rooms/Spaces/Config) attempt PubSub-driven
  live updates — they have no persistent process to receive them. A fresh per-request `COUNT`
  is the correct, honest scope for those pages (see Summary's two-tier note); do not invent a
  polling/AJAX mechanism to fake liveness there, that is out of scope for this S-story.
- Do not weaken or duplicate 5a's multi-select-survives-PubSub-update contract — Acceptance
  Test 3 exists specifically to guard the interaction between 5a's selection state and 5b's
  row patches.

## Dependencies

- **5a — `/admin/media` LiveView table.** Hard dependency: this story extends 5a's LiveView
  module with the row-patch `handle_info` and the `stream/3`-backed row storage it requires.
  **Coordination note:** at the time this story was written, 5a had not yet been implemented
  (no file exists under `server/lib/nebu/admin/` for it) — the exact module name/path and
  whether it already uses `Phoenix.LiveView.stream/3` are unconfirmed. The dev agent picking up
  5b must verify 5a's actual implementation first and adjust the File List's row-patch
  integration point (and, if 5a used a plain list assign instead of a stream, either convert it
  or flag the gap back to 5a rather than silently redesigning 5a's storage model as a side
  effect of this story).
- **4b — `MediaScanWorker` scan-flow + PubSub broadcast.** Source of the state transitions this
  story reacts to. **Coordination note, flagged explicitly (mirrors 2d's identical flag):** at
  the time this story was written, 4b also had not yet been implemented. The broadcast payload
  shape this story needs (a 4-tuple including `old_state`, emitted on **both**
  `"media:#{media_id}"` and `"media:admin"`) is a superset of what 2d assumed in isolation (a
  3-tuple, `"media:#{media_id}"` only). Whichever of 1b/2d/4b/5b lands first must NOT finalize
  a payload shape without checking this story's requirement — the recommended resolution
  (stated identically in 2d and here) is to land the broadcast call once, inside
  `Nebu.Media.StateMachine`'s transition function (1b), emitting the 4-tuple on both topics, so
  no per-caller (4b, 6a, 8a, 13x) broadcast wiring is needed anywhere else.
