# war-room-mode — Design Decisions (resolved against ACTUAL shipped sibling code)

Written upfront, before ATDD/dev-story, per coordinator instruction. Every item below
is a real mismatch between the story's own text (written before any sibling story
shipped) and what `operational-log-store` / `admin-logs-monitoring-view` /
`admin-logs-retention-settings` actually shipped. Resolves each before tests/code.

## 1. Real module names (story's File List is aspirational, not actual)

| Story's guess | Actual shipped |
|---|---|
| `Nebu.Compliance.OperationalLogWriter` | `Nebu.Web.LogStore.Writer` (`server/lib/nebu/web/log_store/writer.ex`) |
| (implied generic handler) | `Nebu.Web.LogStore.Handler` (`.../log_store/handler.ex`) — the `:logger` handler callback |
| (implied) | `Nebu.Web.LogStore` (`server/lib/nebu/web/log_store.ex`) — public API (`should_persist?/1`, `get_policy/0`, `get_logs/1`) |
| (implied) | `Nebu.Web.LogStore.PolicyCache` — `persistent_term`-backed cache, refreshed every 2s, avoids live DB reads from the hot `Handler.log/2` path |
| (implied) | `Nebu.Web.LogStore.RouteNormalizer` — produces `route_template` (used for AC3/AC8 scope matching) |
| `server/lib/nebu/web/controllers/admin/war_room_controller.ex` | **Not created** — see §4 below (LiveView `handle_event`, not a Controller) |
| `server/lib/nebu/admin/war_room_manager.ex` | Kept as designed — `Nebu.Admin.WarRoomManager` (Admin-domain public API + inline SQL, ADR-018/020) |

All lib-file changes target the REAL paths above, not the story's guesses.

## 2. `war_room_id` column: already exists — AC10's "fallback" is a no-op

Migration `000017_operational_logs.up.sql` (operational-log-store) already added:
```sql
war_room_id UUID  -- nullable, no FK constraint yet
```
with an explicit code comment: *"an extension seam for the later war-room-mode
story... assigned by the Writer before INSERT."* So AC10 ("verify at migration time
... if missing, add as fallback") never triggers in practice. This story's migration
still includes an idempotent `ADD COLUMN IF NOT EXISTS war_room_id UUID` guard (cheap,
harmless, keeps AC10's literal test meaningful/defensive for any future
drop-and-recreate drift) but ALSO adds the FK constraint
(`REFERENCES war_room_sessions(id)`) that migration 000017 deliberately deferred
(couldn't reference a table that didn't exist yet). AT13 is adapted: instead of
"given a table WITHOUT the column," it verifies the column already exists (idempotent
add is a no-op) AND that the FK constraint gets added.

`Nebu.Web.LogStore.get_logs/1` **already SELECTs `war_room_id`** and returns it in
`row_to_log/1` — but its `@allowed_filter_keys` list
(`~w(level source route_template request_id)`) does **not** include it, so AC12's
"filter the stream by war_room_id" is currently impossible even though the column and
SELECT already support it. Fix: add `"war_room_id"` to `@allowed_filter_keys` in
`Nebu.Web.LogStore` — a 1-line, safe change (parameterized, same code path as the
other filter keys).

`Nebu.Web.LogStore.Writer`'s `@columns` list for the batched INSERT
(`~w(level source route_template request_id message metadata)a`) does **not**
include `war_room_id` — extend it to `~w(level source route_template request_id message metadata war_room_id)a`
and extend `row_values/1` to read `Map.get(entry, :war_room_id)`.

## 3. Writer's own moduledoc suggestion ("tag in `flush_buffer/1`") is wrong for correctness — tagging must happen at cast-time, not at flush-time

`Writer`'s moduledoc says war-room tagging is "intended to attach here, in
`flush_buffer/1`, before the INSERT." This does not work for AC4/AC9 correctness:

- `Writer` batches up to 100 entries OR flushes every 5s, whichever comes first.
- AT9 requires: "when the 5th matching log entry is written [with max_entries=5],
  **that entry** is persisted and tagged... session is atomically marked ended... the
  6th matching entry written after this is NOT tagged." This is single-entry
  granularity. If the match/tag/budget-check happened at `flush_buffer/1` time
  (batch of up to 100), a burst of 20 matching entries arriving inside one flush
  window would either all get tagged (blowing straight through `max_entries=5` to
  20) or require re-deriving order within a batch — fragile and still racy against
  concurrent callers appending to the SAME in-memory buffer list.
- **Bigger problem:** `Handler.log/2` only calls `Writer.write_async/1` at all when
  `LogStore.should_persist?(entry.level)` is already `true`. AC4 requires war-room
  entries to be persisted **"regardless of the ambient per-level retention
  policy"** — e.g. a DEBUG entry when `log_collect_debug = false` globally. If the
  war-room check lived inside `Writer`, such an entry would never even reach
  `Writer.write_async/1` — `Handler.log/2` would have already discarded it before
  the Writer ever sees it.

**Resolution:** the match/tag/budget-check/auto-terminate decision must happen
**synchronously, per-entry, at `Handler.log/2`'s level**, BEFORE the
`should_persist?` gate — not deferred into `Writer.flush_buffer/1`. Concretely:

```elixir
# Nebu.Web.LogStore.Handler.log/2 (modified)
entry = parse_log_event(log_event)
entry = maybe_tag_war_room(entry)          # NEW: sync check against WarRoom cache
safe_broadcast(entry)                       # broadcast now also carries war_room_id
if LogStore.should_persist?(entry.level) or entry.war_room_id do
  safe_write(entry)
end
```

`maybe_tag_war_room/1` delegates to a new module, `Nebu.Web.LogStore.WarRoom` (see
§4), which is a GenServer mirroring `PolicyCache`'s already-established pattern
(hot-path-safe, never blocks Handler.log/2 when no war room is active) but — unlike
PolicyCache, which is read-only — also performs the increment-and-maybe-terminate
write, serialized through one process (see below). This is a deliberate
deviation from the story's own Dev Notes ("no new process needed — just additional
logic in the existing writer's handle_cast/handle_call") because the Writer's
batching semantics are fundamentally incompatible with AC4's real-time,
single-entry budget enforcement and AC4's "regardless of ambient policy" override,
both of which require intercepting the decision upstream of Writer, at Handler
level.

## 4. New module: `Nebu.Web.LogStore.WarRoom` (GenServer, cache + atomicity boundary)

Lives at `server/lib/nebu/web/log_store/war_room.ex`, sibling to
`policy_cache.ex`/`writer.ex`/`route_normalizer.ex`/`retention.ex`. Holds the single
active session's state in-memory (or `nil`):

```elixir
%{id: uuid, started_by:, reason:, scope:, filter:, max_entries:, max_duration_s:,
  started_at:, entries_collected:}
```

- `check(entry) :: nil | uuid` — fast path: if no session cached, returns `nil`
  immediately (no GenServer round-trip needed — a `persistent_term` boolean flag
  gates whether there's even an active session at all, exactly mirroring
  `PolicyCache`'s "never touch the DB / never block on this hot path when
  inactive" philosophy). If a session IS cached, this **is** a `GenServer.call/2`
  (needs to be synchronous+serialized for the increment-and-maybe-terminate
  atomicity — see below) that evaluates scope+filter match; on match, increments
  `entries_collected` in-memory AND issues one small, single-row `UPDATE
  war_room_sessions SET entries_collected = entries_collected + 1[, ended_at =
  now(), ended_reason = 'budget_exhausted'] WHERE id = $1` (single SQL statement,
  conditionally setting the end columns in the SAME statement when the new count
  reaches `max_entries` — genuinely atomic, no read-then-write race). Because
  every `check/1` call for the active session is serialized through the SAME
  GenServer, there is no cross-process race on the counter — the GenServer itself
  is the atomicity boundary; AT9's "the 6th matching entry is NOT tagged" holds
  because the in-memory session flips to inactive in the very same `handle_call`
  that incremented past the budget, before the call returns.
- `load_active/0` — called from `init/1` (on app boot) and after every
  `WarRoomManager.start_session/1` / `stop_session/1` write, reloading the single
  active row (`ended_at IS NULL`) from the DB into the cache. Boot-time load also
  handles the case where the process was down past `max_duration_s` — if the
  loaded session is already past its deadline, it is immediately ended as
  `duration_exceeded` on load (AC5 applies even across a restart).
- Duration timer: on `load_active/0` (whether at boot or after a fresh
  `start_session/1`), schedules `Process.send_after(self(), {:check_timeout, id},
  remaining_ms)`. `handle_info({:check_timeout, id}, state)` only acts if `id`
  still matches the CURRENTLY cached session (guards a stale timer message from a
  since-replaced session — relevant because "exactly one active" is enforced at
  the DB layer, but a fast stop+immediate-restart could theoretically leave an
  old timer message in flight).
- `Handler.log/2` never touches `Nebu.Repo` directly for this — it calls
  `Nebu.Web.LogStore.WarRoom.check/1`, which is the ONLY thing doing the (small,
  single-row) DB write, and only when a session is actually active AND the entry
  actually matches (bounded by design — a war room's own `max_entries` cap, ≤
  10,000, keeps this bounded exactly like the feature's own safety goal).

This mirrors the codebase's own already-established precedent of
`Nebu.Web.LogStore` (shared infra) calling directly into `Nebu.Admin.DB`
(`read_server_config/0` → `Nebu.Admin.DB.get_server_config/0`) — so `WarRoom`
calling into `Nebu.Admin.WarRoomManager`'s SQL helpers (or vice versa: `WarRoom`
owns its own inline SQL directly, ADR-018-compliant, same as `Retention`/
`RouteNormalizer` already do in the same directory) is architecturally consistent.
**Decision: `Nebu.Web.LogStore.WarRoom` owns its own inline SQL** for the
load/increment/timeout paths (simplest, avoids a circular-feeling dependency where
shared infra calls out to Admin just to call back into shared infra); `WarRoomManager`
owns the SQL for admin-initiated create/stop/status (the "front door" operations),
and calls `Nebu.Web.LogStore.WarRoom.load_active/0` after every write — exactly
mirroring `Nebu.Admin.DB.upsert_server_config/1` → `Nebu.Web.LogStore.refresh_policy_cache/0`.

Supervision: add `Nebu.Web.LogStore.WarRoom` to `Nebu.Application.repo_children/0`'s
list, alongside `Writer`/`PolicyCache` (same gating — nothing to track without a DB).

## 5. AC9's `user_id`/`device_id` filter fields do not exist ANYWHERE in the current metadata pipeline — must be added to `RequestLogger`

Grepped the entire request/logging pipeline: **no code path currently puts
`user_id` or `device_id` into `Logger.metadata/1` or the persisted `metadata`
JSONB column.** `Nebu.Web.Plugs.RequestLogger`'s `base_fields` only carries
`method/path/status/duration_ms/request_id/route_template`. Without this, AC9's
filter (`{"user_id": "@alice:localhost", "device_id": "..."}`) has nothing to match
against — it would silently never match anything.

Fix (in scope for this story — unambiguous, minimal, reuses already-available
data): `Nebu.Web.Plugs.RequestLogger`'s `before_send` callback already runs AFTER
the entire plug pipeline (including `Nebu.Web.Plugs.OidcPlug`, which — for
authenticated Matrix routes — assigns `conn.assigns.current_user` and
`conn.assigns.device_id`). `register_before_send/2`'s callback receives the FINAL
conn at send-time, so these assigns are already populated regardless of plug
ordering. Add, alongside the existing
`Logger.metadata(method: ..., status: ..., duration_ms: ...)` call:

```elixir
Logger.metadata(user_id: conn.assigns[:current_user], device_id: conn.assigns[:device_id])
```

`Handler.safe_metadata/1`'s `@drop_meta_keys` list does not include `:user_id`/
`:device_id`, so they flow through automatically into `entry.metadata["user_id"]`/
`entry.metadata["device_id"]` — exactly the shape `WarRoom`'s filter-matching logic
needs, with zero changes to `Handler` itself. For unauthenticated/public routes
these assigns are simply absent → `nil` → never matches a filter that requires
them (correct — a filter is "AND across present fields," never satisfied by `nil`
on either side per AC9's literal semantics).

This is not scope creep — it is a required, unambiguous, minimal fix to make an
explicitly-specified AC (AC9) technically possible at all; flagged here rather than
discovered mid-dev-story.

**Security note (relevant to Kassandra's review):** logging `user_id`/`device_id`
is an *identifier*, not chat message content or a credential — same category
already accepted elsewhere (e.g. `Nebu.Compliance.AuditLogEntry.actor_user_id`
already stores user_id in plaintext for accountability). Consistent with the
project's "No Sensitive Data in Logs" LAW (which concerns tokens/credentials AND
message content, not identifiers used for legitimate operational
scoping/accountability).

## 6. War Room start/stop/status: LiveView `handle_event`, not a separate Controller+HTTP-API

The story's Dev Notes assume a JSON-ish HTTP API (`POST /admin/war-room/start`
returns 409/session-id JSON) served by a new `war_room_controller.ex`. This
predates `admin-logs-monitoring-view` shipping. In reality:

- `/admin/logs` is `Nebu.Admin.LogsLive` — a **LiveView**, not a Controller.
- The admin app's `:browser` pipeline is `plug :accepts, ["html"]` only — there is
  no JSON API convention anywhere under `/admin` today (every admin mutation is
  either a LiveView `handle_event` round-trip, e.g. `open_detail`/
  `pause_live_updates`/`resume_live_updates` already in `LogsLive`, or a plain HTML
  `<form>` POST + redirect + flash, e.g. `LogsController.save_retention`).
- A separate Controller-based War Room endpoint would force a full page
  reload/redirect cycle to reflect state that the story explicitly wants to show
  *live* (budget countdown, entries-collected ticking) — directly at odds with
  AC11's "live status bar."

**Decision:** implement War Room start/stop directly as `handle_event/3` clauses in
`Nebu.Admin.LogsLive` (`handle_event("start_war_room", params, socket)` /
`handle_event("stop_war_room", params, socket)`), mirroring the file's own
established "real server round-trip" pattern already used for
`open_detail`/`pause_live_updates`/`resume_live_updates` (as opposed to the
Trace-Map-filter bubbles, which are deliberately client-side-only per AC3 of the
sibling story — War Room is NOT that category; it is a genuine state mutation).
Panel markup/logic is factored into a new
`Nebu.Admin.LogsLive.WarRoomPanel` component module, mirroring the existing
`TraceMapBubble`/`DetailPanel` "LogsLive.XxxPanel" sub-module convention. No new
router routes, no new Controller, no `war_room_controller.ex` file.
CSRF is not a separate concern here — LiveView `phx-submit`/`handle_event` traffic
rides the already-authenticated LiveView socket (same as every other mutating
event in this module), unlike the plain-HTML-form `LogsController` pattern which
needs an explicit `_csrf_token` hidden field.

`Nebu.Admin.WarRoomManager` (`server/lib/nebu/admin/war_room_manager.ex`) is kept
exactly as the story's own File List specifies — it is the Admin-domain public API
+ inline-SQL module (ADR-018/020) that `LogsLive`'s `handle_event` clauses call
into: `start_session/1`, `stop_session/1`, `status/0`. It has **no** HTTP-layer
knowledge (no `Plug.Conn`, no controller behaviour) — purely functional, which also
makes it directly unit-testable without an HTTP round trip.

**Acceptance-test framing adaptation:** AT2–AT11 and AT14 describe "the API
returns 409" / "POST /admin/war-room/start" / "an admin navigates to /admin/logs."
These are reinterpreted, consistent with how `admin-logs-monitoring-view` and
`admin-logs-retention-settings` both already adapted literal AC framing to their
real shipped architecture:
- "the API returns 409 Conflict with message X" → `WarRoomManager.start_session/1`
  returns `{:error, :conflict, "War Room already active, ..."}`.
- "the API returns the session id" → `{:ok, %{id: uuid, ...}}`.
- "an admin navigates to /admin/logs ... panel visible" → `LogsLive` mount/render
  test asserting the panel's presence (Phoenix.LiveViewTest, same tooling already
  used by `logs_live_test.exs`).
- "POST /admin/war-room/W/stop" → `handle_event("stop_war_room", %{"id" => w},
  socket)` exercised via `Phoenix.LiveViewTest.render_click/2` (or a direct
  `WarRoomManager.stop_session/1` call for the pure-logic unit tests).

## 7. AC12 stream filtering: server-side `mount/3` param, not a client-side bubble

`LogsLive.mount/3` currently ignores its `_params` argument entirely — all Trace Map
filtering (AC3 of the sibling story) is 100% client-side DOM show/hide over the
already-loaded ≤200-row window. That client-side-only approach cannot satisfy AC12's
real goal — "pull up a **completed** war room session and see **all** of its
logs" — because:
1. A completed session's entries may span well beyond the live view's 200-row
   initial-load cap (a war room's own budget can be up to 10,000 entries).
2. The whole point is a **historical**, bookmarkable slice, not "whatever happens
   to still be in this LiveView process's memory since page mount."

**Decision:** `mount/3` reads `params["war_room_id"]`. If present, `initial_entries/0`
calls `Nebu.Web.LogStore.get_logs(%{war_room_id: id})` (now supported per §2's
`@allowed_filter_keys` fix) instead of the default `get_logs(%{})` capped at 200,
and the page renders a small "Viewing War Room session `<id>`" banner with a link
back to the unfiltered `/admin/logs`. This is an additive `mount/3` branch and one
new `get_logs/1` filter key — not a reimplementation of the stream component, per
the Dev Notes' own explicit caution.

## 8. "Exactly one active" (AC2) — DB-level guarantee, not just app-level check

To make "exactly one active session, ever" a genuine invariant (not just an
app-level SELECT-then-INSERT race), the migration adds a **partial unique index**:

```sql
CREATE UNIQUE INDEX war_room_sessions_single_active_idx
    ON war_room_sessions ((1)) WHERE ended_at IS NULL;
```

`WarRoomManager.start_session/1` still does the app-level "is one active?" check
first (to return a friendly 409 message with the existing session's details, per
AC2's literal message format), but the unique index is the actual correctness
backstop against a genuine race (two concurrent start requests) — if the app-level
check ever races, the second `INSERT` fails on the unique index and is mapped to the
same `{:error, :conflict, ...}` tuple. Idempotent-restart (AC2, same admin/same
params) is handled by matching the existing active row's params to the new
request's params before attempting insert — if they match, return `{:ok,
existing_session}` without a second insert attempt at all.

## 9. Everything else from the story stands as written

- Session lifecycle schema (AC1/AC3) as specified.
- Scope/filter matching semantics (AC3/AC9's AND semantics, exact-string route
  match) as specified — `RouteNormalizer.normalize_route/1` passes `/sync`'s path
  through unchanged (no ID-shaped segments to replace), confirming
  `"/_matrix/client/v3/sync"` is exactly the string that will appear in
  `route_template` for that endpoint, matching AC8's literal scope value.
- UI warnings (AC7/AC8) and form bounds (AC9/AC11) — implemented in the new
  `WarRoomPanel` component + `app.js`, following the exact pattern
  `LogsController`'s retention page already established
  (`wireLogsConfigToggles()`-style vanilla-JS, CSP-`script-src 'self'`-compliant,
  no inline `<script>`).
- Redaction guarantee: `WarRoom`'s matching/tagging never touches
  `entry.message`/`entry.metadata`'s *content* — it only reads already-redacted
  fields (`route_template`, `metadata["user_id"]`, `metadata["device_id"]`) and
  writes back `war_room_id`. No new leak path; the two-category redaction from
  `matrix-payload-debug-logging` continues to apply upstream, unchanged, even
  during an active War Room session (this is the exact invariant Kassandra's
  review must independently confirm).
