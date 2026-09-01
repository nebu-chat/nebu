---
story_id: 10e-trace-map-war-room-integration
title: "Scan Health & Alerts Dashboard: Trace-Map & War-Room Integration of the Scan Pipeline"
epic: media-security-admin-control
status: done
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

The Trace-Map/"Leitstand" and War Room features already exist, fully merged from the
`enhanced-logging` epic (commit `a3c03cce`, "Enhanced Logging without extra infrastructure"). They
are NOT an abstract future concept — they are concrete, working code today:

- **`Nebu.Web.LogStore`** (`server/lib/nebu/web/log_store.ex`) is the public API for the
  `operational_logs` store. A single `:logger` handler
  (`Nebu.Web.LogStore.Handler`, `server/lib/nebu/web/log_store/handler.ex`) intercepts **every**
  `Logger.*` call app-wide, parses `route_template`/`request_id` from the log event's `meta`
  field (nowhere else), and persists WARN/ERROR always, INFO/DEBUG per an admin-configurable
  policy.
- **`Nebu.Admin.LogsLive.TraceMap`** (`/admin/logs/trace-map`, the "Leitstand") renders a radial
  map of observed endpoints. **`Nebu.Admin.LogsLive.TraceMapTree.domain_for_endpoint/1`**
  (`server/lib/nebu/admin/logs_live/trace_map_tree.ex`) is the canonical grouping heuristic: a
  route template of the shape `"/<segment>/..."` groups under domain `"/<segment>"` (e.g.
  `/_matrix/client/v3/sync` → `/_matrix/client`, `/admin/users` → `/admin`). **This heuristic is
  purely string-prefix-based — it has no awareness of Media at all today**, and it requires a
  **leading `/` with `/`-separated segments** to group correctly (a dotted synthetic name like
  `media.clamav` would NOT group with `media.scan_worker` — each would fall through to the
  "no recognized domain prefix" catch-all and become its own singleton domain). This matters
  because the epic's Review 9 prose illustrates route names as `media.clamav`/`media.scan_worker`
  (dot-separated) — this story uses slash-separated names instead (`/media/clamav`,
  `/media/scan_worker`) specifically so `domain_for_endpoint/1`'s existing, unmodified heuristic
  actually groups them under one new `"/media"` domain, exactly as intended.
- **`Nebu.Admin.WarRoomManager`** (`server/lib/nebu/admin/war_room_manager.ex`) is the public API
  for War Room session lifecycle: `start_session/1` (required: `started_by`, `reason`,
  `max_entries` 10–10,000, `max_duration_s` 10–3,600; optional: `scope`, `filter`,
  `exclusive_scope`), `stop_session/1`, `status/0`. Sessions are bounded and self-terminating
  (budget or duration expiry).
- **`Nebu.Web.LogStore.WarRoom`** (`server/lib/nebu/web/log_store/war_room.ex`) is the hot-path
  matcher: `scope_matches?/2` (private, called via `matches?/2`) accepts **only** `nil`, `"all"`,
  or **one exact route-template string** — there is no list/prefix form today. `filter` matches
  metadata key/value pairs (AND-across-fields) against `entry[:metadata]` — **not** against
  `entry[:request_id]`, which is a separate top-level field entirely excluded from `:metadata`
  (see `Handler`'s `@drop_meta_keys`). This means a War Room session cannot, today, be scoped to
  "everything under `/media`" in one shot, nor can it be scoped to "only this one `media_id`'s
  events" via `filter` — these are real, code-verified gaps this story must close narrowly (see
  Technical Requirements), not invent a parallel mechanism around.
- **`/admin/logs?war_room_id=<id>`** (`Nebu.Admin.LogsLive`, `war_room_id_param/1`,
  `initial_entries/1` → `LogStore.get_logs(%{war_room_id: war_room_id})`) is the **existing,
  already-shipped** bookmarkable "jump straight into this incident's captured entries" pattern
  (`enhanced-logging/war-room-mode`, AC12). This is the exact mechanism Story 10c's "jump to
  war-room" link reuses — there is no new URL scheme to invent.
- **Redaction is scoped to HTTP payload capture, not universal.** `Handler`'s own moduledoc is
  explicit: *"This is a GENERIC handler — it has no awareness of HTTP requests, Matrix events, or
  `PayloadRedactor`... this handler does no redaction of its own and needs none."* Only
  `Nebu.Web.Plugs.RequestLogger` calls `PayloadRedactor.redact_payload/1,2` — and only on the
  HTTP request/response **body** it captures at DEBUG level. Arbitrary `Logger.metadata`
  key/values (like the existing `user_id`/`device_id` fields `RequestLogger` already sets) are
  never redacted; they are simply expected to be **identifiers, never content** ("No Sensitive
  Data in Logs" LAW: credentials/message content are forbidden, accountability identifiers are
  the established, already-shipped precedent). This story's scan-pipeline log calls follow that
  exact precedent — never a new redaction call, never new PII in a rendered `message`.

The scan pipeline (`Nebu.Media.ClamAV`, Story 3; `Nebu.Workers.MediaScanWorker`, Story 4b; the
admin actions in `Nebu.Admin.MediaLive`, Stories 6a/6c) currently has **no `Logger.*` calls with
`route_template`/`request_id` metadata at all** — Story 3 only documents a bare
`Logger.warning/1` on an unreachable clamd at boot, and Story 4b's worker only broadcasts on
`Nebu.PubSub` and writes `media_state_transitions` rows; neither sets the metadata shape
`Handler.parse_log_event/1` needs to make these events show up in `operational_logs`/Trace-Map at
all. This story adds that instrumentation and wires up one new War-Room jump-off point — it adds
**zero** new tables, workers, or visualization components.

## User Story

As an admin investigating a media-scan incident (a flagged/infected file, a ClamAV outage, a
scan-error spike), I want the scan pipeline's operational events (upload → scan start → scan
result, and admin overrides) to show up in the same Trace-Map/War-Room tooling I already use for
every other part of Nebu, and I want a one-click way to jump from a critical alert on the media
health dashboard straight into a live, bounded diagnostic session scoped to the media domain, so
that I do not have to `grep` container logs or build a second, parallel observability surface
just for media.

## Acceptance Criteria

1. **AC1 — ClamAV GenServer events carry Trace-Map metadata.** `Nebu.Media.ClamAV`
   (`server/lib/nebu/media/clamav.ex`, Story 3) logs connect, disconnect, and health-check-state
   transitions via ordinary `Logger.warning/2` / `Logger.info/2` calls, passing
   `route_template: "/media/clamav"` (and `request_id: nil` — these are pipeline-wide events, not
   tied to one file) as call-site metadata (the `Logger.info(message, metadata)` 2-arity form —
   **not** `Logger.metadata/1`, since a GenServer's own process persists across many unrelated
   calls and must not leak stale metadata across them). No new module, no new persistence — this
   is purely additive metadata on log calls this story adds to Story 3's existing (documented but
   not yet metadata-tagged) `Logger.warning/1` call and its counterpart reconnect/health-check
   log lines.
2. **AC2 — MediaScanWorker events carry Trace-Map metadata, correlated by `media_id`.**
   `Nebu.Workers.MediaScanWorker` (`server/lib/nebu/workers/media_scan_worker.ex`, Story 4b) logs
   scan-start (entry into `:scanning`), scan-result (`:released`/`:infected`/`scan_failed`), and
   scan-error-retry events via `Logger.info/2` / `Logger.warning/2` calls with
   `route_template: "/media/scan_worker"` **and** `request_id: media_id` (the media UUID reused
   AS the correlation key — see Technical Requirements for why this, not a fresh UUID, is the
   correct reuse of the existing `request_id` column/mechanism for a non-HTTP-originated event
   stream). Only identifiers (`media_id`, `clamav_signature` when infected, `reason` atom/inspect
   string when erroring) go into metadata — never the file's bytes, its original filename (not
   available to this worker at all — see Story 1a/4b: only `storage_key`/`media_id` are), or any
   Matrix room/event content.
3. **AC3 — Admin actions (6a/6c) carry Trace-Map metadata, same correlation key.**
   `Nebu.Admin.MediaLive`'s `handle_event/3` clauses for Block/Unblock/Delete/Rescan (Story 6a)
   and Infected-Override (Story 6c) each additionally call `Logger.info/2` with
   `route_template: "/admin/media"` (the page's own real, already-router-mounted route — these
   are genuine admin actions on that page, so they group under the pre-existing `"/admin"`
   Trace-Map domain, not a new one) and `request_id: media_id`, in addition to (never instead of)
   the existing `Nebu.Compliance.AuditWriter.log/6` call those stories already specify. This is a
   second, independent visibility channel (operational/diagnostic) alongside the immutable
   compliance audit trail — not a replacement for it, and not a new compliance-audit action
   (no `AuditWriter.@known_actions` change is needed by this story).
4. **AC4 — `/media` becomes its own Trace-Map domain group, for free.**
   With AC1/AC2 landed, `Nebu.Admin.LogsLive.TraceMap`'s existing, **unmodified**
   `domain_for_endpoint/1` groups `/media/clamav` and `/media/scan_worker` under a new `"/media"`
   domain, rendered as its own disclosure group alongside the pre-existing `/_matrix/client`,
   `/admin`, `/health` groups — no change to `TraceMapTree`/`TraceMap` itself is required or
   permitted (see Dev Agent Guardrails).
5. **AC5 — A media file's whole operational story groups into one Trace-Map row.**
   Because `Nebu.Admin.LogsLive` already groups the request-stream by `request_id`
   (`entries_by_request`), and AC2/AC3 both set `request_id: media_id`, every scan-worker and
   admin-action log line for one file lands in the **same** grouped row when an operator is
   inside a War Room session that captured them — this is a direct, unmodified consequence of the
   existing grouping logic, not a new feature added to `LogsLive`.
6. **AC6 — Redaction unchanged, no new leak path.** These log calls never place `filename`,
   uploader identity beyond the existing `user_id` precedent, or any Matrix event content into
   the rendered log `message` — only into `metadata`, and only as bare identifiers (`media_id`,
   `clamav_signature`, `reason`), matching the existing `user_id`/`device_id` precedent in
   `RequestLogger`. No change to `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` and no new call
   into it from the scan pipeline — that module redacts HTTP **request/response bodies** only,
   and none of AC1–AC3's log calls carry one.
7. **AC7 — `Nebu.Web.LogStore.WarRoom.scope_matches?/2` is extended, additively, to accept a
   list of route templates as `scope`** (in addition to the existing `nil`/`"all"`/single-string
   forms, unchanged): `scope` may now also be a list, matched as "route is a member of the list"
   (OR-semantics). This is the minimal, backward-compatible change needed to make "scope this War
   Room session to the media domain" (`["/media/clamav", "/media/scan_worker", "/admin/media"]`)
   possible at all — today's exact-single-string-only `scope_matches?/2` cannot express "these
   three routes." Every existing single-string/`"all"`/`nil` test continues to pass unmodified.
8. **AC8 — "Live-Diagnose starten" jump-off point on the media health dashboard.** An unresolved
   `critical` row in `media_alerts` (Story 10c, e.g. "ClamAV unreachable > 5 min") on
   `/admin/media/health` (Story 10a/10b/10c's dashboard route) renders a
   "Live-Diagnose starten" action. Clicking it calls
   `Nebu.Admin.WarRoomManager.start_session/1` with `scope: ["/media/clamav",
   "/media/scan_worker", "/admin/media"]` (AC7), `reason` pre-filled from the alert's `message`
   (editable), `started_by` the current admin, and the same operator-adjustable
   `max_entries`/`max_duration_s` bounds every other War Room session uses (10–10,000 /
   10–3,600s — no special-cased bounds for media). On `{:ok, session}`, the admin is redirected to
   `/admin/logs?war_room_id=#{session.id}` — the **existing** AC12 bookmarkable pattern, reused
   verbatim, not a new page. On `{:error, :conflict, message}` (a session is already active,
   started by someone else), the dashboard shows that conflict message rather than silently
   failing — the same behavior `start_session/1` already documents for every other caller.
9. **AC9 — Alert-to-file correlation, when available.** When the triggering `media_alerts` row
   has a non-null `media_id` (Story 10c: `media_id` is nullable — pipeline-wide alerts like a
   ClamAV outage have none), the dashboard additionally surfaces that `media_id` next to the
   "Live-Diagnose starten" action so the operator knows which grouped row (AC5) to look for once
   inside the War Room session — this is a text hint, not a new filter mechanism (no
   `request_id` query-param filter is added to `/admin/logs`; `LogsLive`'s existing per-request
   grouping already does the work once the operator is looking at the stream).
10. **AC10 — No new data holding, no ACs moved out of 10a/10c.** `media_scan_stats` (hourly
    rollups) and `media_alerts` (business alerts with `resolved_at`) remain exactly as specified
    in 10a/10c — this story adds **only** log-call metadata (AC1–AC3), one additive matcher
    extension (AC7), and one dashboard action + redirect (AC8/AC9). No new migration, no new
    Ecto/inline-SQL table, no change to `operational_logs`' schema.

## Acceptance Tests

Test files extend the existing modules' own test suites — no new test file per se for AC1–AC6
beyond extending each story's own worker/GenServer/LiveView test file; AC7 and AC8 get dedicated
new tests in the existing War-Room/media-health test files.

1. `test "connect/disconnect/health-check log lines carry route_template \"/media/clamav\""`
   (`server/test/nebu/media/clamav_test.exs`, extends Story 3's suite) — asserts, via
   `ExUnit.CaptureLog`/a subscribed `Nebu.Web.LogStore.Handler`-equivalent capture (mirroring how
   `request_logger_test.exs` asserts on `Logger.metadata`), that the boot-time unreachable-clamd
   warning and a later reconnect both carry `route_template: "/media/clamav"` and no
   `request_id`.
2. `test "scan-start/result/error log lines carry route_template \"/media/scan_worker\" and
   request_id equal to the media_id"` (`server/test/nebu/workers/media_scan_worker_test.exs`,
   extends Story 4b's suite) — for each of the clean/infected/exhausted-retry branches, asserts a
   log call fired with `route_template: "/media/scan_worker"` and `request_id: media_id`
   (matching value, not just presence).
3. `test "admin block/unblock/delete/rescan and infected-override each log an operational entry
   with route_template \"/admin/media\" and request_id equal to the acted-on media_id, in
   addition to (not instead of) the existing AuditWriter call"` (`server/test/nebu/admin/
   media_live_test.exs`, extends Stories 6a/6c's suite) — asserts both the pre-existing
   `AuditWriter.log/6` call AND the new `Logger.info/2` call fire for the same action.
4. `test "domain_for_endpoint groups /media/clamav and /media/scan_worker under a new \"/media\"
   domain, unmodified heuristic"` (`server/test/nebu/admin/logs_live/trace_map_tree_test.exs`,
   extends the existing suite) — a pure-function regression test:
   `TraceMapTree.domain_for_endpoint("/media/clamav") == "/media"` and
   `TraceMapTree.domain_for_endpoint("/media/scan_worker") == "/media"`; a second test asserts
   `group_endpoints_by_domain(["/media/clamav", "/media/scan_worker", "/admin/users"])` produces
   two groups, `"/media"` (2 leaves) and `"/admin"` (1 leaf) — proving no `TraceMapTree` code
   change was needed for this grouping to work.
5. `test "scope_matches?/2 accepts a list of route templates, OR-matched, alongside the existing
   nil/\"all\"/single-string forms"` (`server/test/nebu/web/log_store/war_room_test.exs`, extends
   the existing suite) — table-driven: a session with `scope: ["/media/clamav",
   "/media/scan_worker"]` matches an entry with `route_template: "/media/clamav"` and one with
   `"/media/scan_worker"`, but NOT one with `"/admin/media"` (not in the list); the existing
   `scope: "all"`, `scope: nil`, and `scope: "/_matrix/client/v3/sync"` (single-string exact
   match) cases from the pre-existing suite are re-asserted unchanged in the same file to pin the
   backward-compatibility guarantee.
6. `test "start_session/1 accepts a list scope and persists/round-trips it"`
   (`server/test/nebu/admin/war_room_manager_test.exs`, extends the existing suite) — asserts
   `start_session(%{started_by: ..., reason: ..., max_entries: 100, max_duration_s: 300, scope:
   ["/media/clamav", "/media/scan_worker", "/admin/media"]})` returns `{:ok, session}` with
   `session.scope` round-tripping as the same list (the `scope` column already accepts arbitrary
   JSON-able values per the existing single-string case — no migration needed, see Technical
   Requirements).
7. `test "an unresolved critical media_alerts row renders a Live-Diagnose starten action that
   starts a media-domain-scoped War Room session and redirects to /admin/logs?war_room_id=..."`
   (`server/test/nebu/admin/media_health_live_test.exs`, Story 10a/10b/10c's LiveView test file —
   new test in that suite once it exists) — seeds a `critical`, unresolved `media_alerts` row;
   simulates the click; asserts `Nebu.Admin.WarRoomManager.status/0` now shows an active session
   with `scope == ["/media/clamav", "/media/scan_worker", "/admin/media"]`; asserts the LiveView
   redirects (`assert_redirect`/`assert_patch`) to `/admin/logs?war_room_id=#{session.id}`.
8. `test "a conflicting active War Room session (started by someone else) surfaces the conflict
   message on the media health dashboard instead of silently failing"`
   (`server/test/nebu/admin/media_health_live_test.exs`) — pre-starts an unrelated session via
   `WarRoomManager.start_session/1`, then clicks "Live-Diagnose starten"; asserts the
   `{:error, :conflict, message}` path renders that message and does NOT redirect.
9. `test "media_alerts row with a non-null media_id surfaces it as a text hint next to the
   jump-off action; a pipeline-wide alert (media_id nil) shows no such hint"`
   (`server/test/nebu/admin/media_health_live_test.exs`) — two seeded alerts, one with
   `media_id` set, one `nil`; asserts the rendered markup differs accordingly (AC9 — no filter
   mechanism asserted, just the hint's presence/absence).

## Technical Requirements

### Hook points into 3/4b/6a/6c (exact call sites, additive only)

- **`server/lib/nebu/media/clamav.ex` (Story 3):** at the existing (per Story 3's own AC/Dev
  Notes) boot-time unreachable-clamd `Logger.warning/1` call site, and at the reconnect/health-
  check-transition point the GenServer already needs (Story 3's own "reconnect on the next call"
  behavior), add `route_template: "/media/clamav"` as call-site metadata:
  ```elixir
  Logger.warning("ClamAV unreachable at boot, will retry lazily", route_template: "/media/clamav")
  ```
  Use the `Logger.warning/info(message, metadata)` 2-arity form at each call site — **not**
  `Logger.metadata/1` — because this GenServer's process is long-lived and serves many unrelated
  calls; setting process-dictionary metadata once would leak stale `route_template` onto whatever
  the GenServer logs next for a different reason.
- **`server/lib/nebu/workers/media_scan_worker.ex` (Story 4b):** at `scan_and_transition/3`'s
  entry (scan start), and inside `release/2`/`infect/2`/`scan_error/4` (scan result/error), add a
  `Logger.info/2` (or `Logger.warning/2` for the error/retry path) call with
  `route_template: "/media/scan_worker", request_id: media_id`:
  ```elixir
  Logger.info("media scan started", route_template: "/media/scan_worker", request_id: media_id)
  # ...
  Logger.info("media scan result: released", route_template: "/media/scan_worker", request_id: media_id)
  Logger.warning("media scan result: infected", route_template: "/media/scan_worker", request_id: media_id, clamav_signature: signature)
  Logger.warning("media scan error, retrying", route_template: "/media/scan_worker", request_id: media_id, reason: inspect(reason))
  ```
  These are ADDED to, not a replacement for, the `Phoenix.PubSub.broadcast/3` and
  `Nebu.Media.StateMachine.transition/4` calls Story 4b already specifies — this story never
  touches the transition/broadcast logic itself (see Dev Agent Guardrails).
- **`server/lib/nebu/admin/media_live.ex` (Stories 6a/6c):** immediately alongside (never instead
  of) each existing `Nebu.Compliance.AuditWriter.log/6` call in the Block/Unblock/Delete/Rescan/
  Infected-Override `handle_event/3` clauses, add:
  ```elixir
  Logger.info("admin media action: #{action}", route_template: "/admin/media", request_id: media_id)
  ```
  where `action` is the same action string already passed to `AuditWriter.log/6` (e.g.
  `"media_blocked"`, `"media_infected_override"`) — reuse that variable, do not introduce a second
  naming scheme for the same concept.

### Correlation mechanism — reuse `request_id`, do not invent a new column/concept

`operational_logs.request_id` is a plain, free-text column, already filterable via
`Nebu.Web.LogStore.get_logs/1`'s `filters` map and already the grouping key
`Nebu.Admin.LogsLive` uses to render "one row per request." For an HTTP request, its value is the
`x-request-id` header (`Nebu.Web.Plugs.RequestId`, a UUIDv4) — but nothing about the column or the
grouping logic requires that shape. This story's events are **not** HTTP-request-scoped (a
background Oban job, a GenServer callback, a LiveView `handle_event` over an existing websocket)
— there is no meaningful per-HTTP-request ID to inherit for them. Using the media's own UUID
(`media_id`, already a stable, unique per-file identifier minted at `POST .../media/v1/create`,
Story 2a) AS the `request_id` value is the correct, minimal reuse of the **existing** mechanism:
it costs nothing new, and it is exactly the value that groups every event about ONE file into one
Trace-Map row for free (AC5), which an HTTP-request-scoped ID could never do (a file's upload,
scan, and later admin override are, correctly, three separate HTTP requests days apart — only
`media_id` is stable across all of them).

### `Nebu.Web.LogStore.WarRoom.scope_matches?/2` — the one required, additive extension

Today (verified in `server/lib/nebu/web/log_store/war_room.ex`):
```elixir
defp scope_matches?(nil, _route), do: true
defp scope_matches?("all", _route), do: true
defp scope_matches?(scope, route) when is_binary(scope), do: scope == route
defp scope_matches?(_scope, _route), do: false
```
Add one clause, before the final catch-all, so a list of route templates OR-matches:
```elixir
defp scope_matches?(scope, route) when is_list(scope), do: route in scope
```
No other change to `WarRoom`/`WarRoomManager` is needed: `insert_session/1` already writes
`scope` as an opaque, JSON-able parameter value (the same column already stores a bare string
today; Postgrex/Ecto encode a list of strings into the same `jsonb`/`text[]`-shaped column
without a migration — verify the exact column type in the `war_room_sessions` migration before
implementing, and if it is a plain `text` column rather than `jsonb`, encode/decode the list with
`Jason.encode!/1`/`Jason.decode!/1` at the `insert_session/1`/`row_to_session/1` boundary rather
than changing the column type). `WarRoomManager.validate_exclusive_scope/1`'s existing shape
validation pattern (`String.starts_with?(value, "/")` per element) is a reasonable model for a
symmetrical `validate_scope/1` if `start_session/1`'s defense-in-depth validation should also
cover a list-shaped `scope` — add this alongside the existing `validate_exclusive_scope/1`, not as
a divergent second validation style.

### Dashboard jump-off point (AC8/AC9)

On `/admin/media/health` (Story 10a/10b/10c's route — this story does not create that route, it
adds one action to it once 10c lands), the "Live-Diagnose starten" button's `handle_event/3`
clause:
```elixir
def handle_event("start_media_diagnosis", %{"reason" => reason}, socket) do
  case Nebu.Admin.WarRoomManager.start_session(%{
         started_by: socket.assigns.current_admin_id,
         reason: reason,
         scope: ["/media/clamav", "/media/scan_worker", "/admin/media"],
         max_entries: 1_000,
         max_duration_s: 900
       }) do
    {:ok, session} ->
      {:noreply, push_navigate(socket, to: "/admin/logs?war_room_id=#{session.id}")}

    {:error, :conflict, message} ->
      {:noreply, put_flash(socket, :error, message)}

    {:error, :invalid_params, message} ->
      {:noreply, put_flash(socket, :error, message)}
  end
end
```
`max_entries`/`max_duration_s` defaults above (1,000 / 900s = 15 min) are illustrative starting
points, operator-adjustable in the form exactly like every other War Room start, per AC8 — not a
new, media-specific bound in `WarRoomManager` itself (the existing 10–10,000 / 10–3,600s bounds
already apply and are not widened or narrowed for this caller).

## File List

| File | Change Type |
|---|---|
| `server/lib/nebu/media/clamav.ex` | UPDATE — add `route_template: "/media/clamav"` metadata to existing/Story-3 `Logger.warning/2` calls |
| `server/lib/nebu/workers/media_scan_worker.ex` | UPDATE — add `Logger.info/2`/`Logger.warning/2` calls with `route_template: "/media/scan_worker"`, `request_id: media_id` at scan-start/result/error points |
| `server/lib/nebu/admin/media_live.ex` | UPDATE — add `Logger.info/2` calls alongside each existing `AuditWriter.log/6` call in the Block/Unblock/Delete/Rescan/Infected-Override handlers |
| `server/lib/nebu/web/log_store/war_room.ex` | UPDATE — add the list-form `scope_matches?/2` clause |
| `server/lib/nebu/admin/war_room_manager.ex` | UPDATE (optional, if list-shape validation is added) — symmetrical `validate_scope/1` alongside `validate_exclusive_scope/1` |
| `server/lib/nebu/admin/media_health_live.ex` (Story 10a/10b/10c's module — name per that story) | UPDATE — add the "Live-Diagnose starten" action/handler once 10c lands |
| `server/test/nebu/media/clamav_test.exs` | UPDATE |
| `server/test/nebu/workers/media_scan_worker_test.exs` | UPDATE |
| `server/test/nebu/admin/media_live_test.exs` | UPDATE |
| `server/test/nebu/admin/logs_live/trace_map_tree_test.exs` | UPDATE |
| `server/test/nebu/web/log_store/war_room_test.exs` | UPDATE |
| `server/test/nebu/admin/war_room_manager_test.exs` | UPDATE |
| `server/test/nebu/admin/media_health_live_test.exs` (10c's test file) | UPDATE |
| `server/test/nebu/web/log_store/handler_test.exs` (`enhanced-logging` epic's own test file) | UPDATE — code-review cycle-1 ripple: `Nebu.Admin.WarRoomManager.row_to_session/1` (this story's own AC8/AC9 work) started returning `session.id` as the canonical hex-dash STRING (needed so `MediaHealthLive`'s `push_navigate(to: "/admin/logs?war_room_id=#{session.id}")` interpolates a real UUID, not raw binary). This file's own war-room tests bind `session.id` straight into a raw-SQL `$1` against `operational_logs.war_room_id` (a native `uuid` column), so every such site needed the same `Ecto.UUID.dump!/1` normalization back to binary — see the Dev Agent Record below for the full ripple and why it was kept rather than reverted in cycle 2. |

## Dev Agent Record

### Cycle 2 code-review fixes (2026-07-20)

- **MAJOR-1** (`clamav.ex`): the "clamd connection healthy" log fired
  unconditionally on every `health_check/0` call in the `{:ok, new_state}`
  branch, not only on a real unhealthy → healthy transition — since WARN/ERROR
  entries are always persisted by `LogStore.Handler` (never policy-gated like
  INFO/DEBUG), this wrote an unbounded row to `operational_logs` on every
  clean poll (every scan job, the periodic alerts-checker worker, every
  dashboard render). Fixed by comparing `state.healthy` (before
  `ensure_connected/1`) against the returned state's `healthy` (after) and
  only logging on the `false -> true` flip — reusing the exact transition
  concept `put_healthy/2` already tracks via `changed_at`. `clamav_test.exs`'s
  "10e AC1" describe block now asserts two consecutive `health_check/0` calls
  against a reachable fake clamd produce exactly ONE "/media/clamav" log
  entry, not two.
- **MAJOR-2** (`clamav.ex`, `media_scan_worker.ex`, `media_live.ex`): the
  previous cycle had substituted `Logger.warning/2` for the AC-specified
  `Logger.info/2` at several call sites purely to route around
  `config/test.exs`'s primary Logger level (`:warning`, which silently drops
  `:info` calls before they reach any `:logger` handler) instead of fixing the
  test-visibility gap itself. Reverted to `Logger.info/2` at every
  routine/success-path call site (ClamAV healthy-transition; scan-start and
  scan-result:released in `MediaScanWorker`; the admin-action log in
  `MediaLive`) — the infected/error-retry paths correctly stay at
  `Logger.warning/2`, unchanged. Fixed the actual test-visibility gap instead:
  `clamav_test.exs`'s "10e AC1", `media_scan_worker_test.exs`'s "10e AC2", and
  `media_live_test.exs`'s "10e AC3" describe blocks each add a `setup` that
  raises `Logger.level()` to `:info` for the duration of that describe
  block's own tests only (restored via `on_exit`), mirroring
  `request_logger_test.exs`'s own established `Logger.configure(level:
  :info)` idiom.
- **MINOR-1 decision — kept `row_to_session/1`'s string-`id` shape (did not
  revert to raw binary + a single call-site conversion):** the code-reviewer
  offered a choice between (a) reverting `Nebu.Admin.WarRoomManager.
  row_to_session/1` back to raw-binary `id` and doing one surgical
  `Ecto.UUID.load!/1` conversion only at `media_health_live.ex`'s
  `push_navigate` call site, shrinking the diff, or (b) keeping the current,
  already-consistent, already-fully-tested string-`id` approach. Chose (b):
  the revert would touch `war_room_manager.ex` (`row_to_session/1`,
  `stop_session/1`, the `uuid_dump/1` helper), `war_room_manager_test.exs`
  (3 call sites + a rewritten shape assertion), and
  `handler_test.exs` (5 call sites, belonging to a DIFFERENT, already-merged
  `enhanced-logging` epic) — a non-trivial, cross-epic surface to re-verify
  for a pure diff-size reduction with no correctness benefit (both approaches
  are equally correct and equally tested). The current approach's cost is
  fully paid already (every touched file's tests pass); reverting would only
  re-introduce that same cost as risk. Documented instead (this section, plus
  the File List row above) so a future maintainer has the full ripple
  explained in one place.
- **MINOR-3 — disambiguating comment:** since MINOR-1 was kept-as-is (not
  reverted), there are now two `row_to_session/1` functions that return `id`
  as a canonical STRING (`Nebu.Admin.WarRoomManager.row_to_session/1`, this
  story; `Nebu.Admin.LogsLive.WarRoom.row_to_session/1`, pre-existing from
  `enhanced-logging/war-room-dedicated-page`) and one that deliberately stays
  BINARY (`Nebu.Web.LogStore.WarRoom.row_to_session/1`, the hot-path cache —
  never rendered into a URL/markup, so no conversion is needed there).
  Cross-referencing comments noting the other two functions' existence and
  `id` shape were added at each of the three `row_to_session/1` definitions.

## Dev Agent Guardrails

### Do Not Change

- **Reuse the existing Trace-Map/War-Room correlation mechanism exactly as implemented — do not
  build a parallel logging system for media events.** Concretely: do not add a second `:logger`
  handler, a second PubSub topic for media logs, a second "operational log" table, or a bespoke
  media-only trace viewer. Every media scan/admin event MUST flow through the SAME
  `Nebu.Web.LogStore.Handler` every other `Logger.*` call in the app already flows through — this
  story's entire scope is picking the right `route_template`/`request_id` values at existing
  call sites (AC1–AC3), plus the one narrowly-scoped `scope_matches?/2` list-form extension (AC7)
  that the existing mechanism genuinely lacks today.
- **Do not modify `Nebu.Admin.LogsLive.TraceMapTree.domain_for_endpoint/1` or
  `group_endpoints_by_domain/1`.** AC4 is satisfied by choosing slash-prefixed route-template
  strings (`/media/clamav`, `/media/scan_worker`), not by changing the grouping heuristic itself —
  see AC4's regression test (Acceptance Test 4), which pins that no `TraceMapTree` code change is
  needed or wanted.
- **Do not touch `Nebu.Web.Plugs.RequestLogger` or `PayloadRedactor`.** Neither module is in this
  story's scope — the scan pipeline's log calls never carry an HTTP request/response body, so
  there is nothing for `PayloadRedactor` to redact, and no reason to route these calls through it.
- **Do not add a new `AuditWriter.@known_actions` entry.** This story's admin-action logging
  (AC3) is a second, independent, operational-visibility channel alongside the EXISTING
  `AuditWriter.log/6` calls Stories 6a/6c already specify — it does not add a new compliance-audit
  action, and must not touch `@known_actions` (see the project's own "Audit allowlist merge
  gotcha" — this is exactly the kind of change that has silently broken the audit trail before by
  conflating a new operational log call with a new compliance action).
- **Do not widen `Nebu.Admin.WarRoomManager`'s `max_entries`/`max_duration_s` bounds (10–10,000 /
  10–3,600s) for the media jump-off point.** AC8's illustrative defaults (1,000/900s) are a
  starting form value, not a new bound — the existing `validate_bounds/1` enforcement in
  `WarRoomManager` applies unchanged to this caller like every other.
- **`media_scan_stats` and `media_alerts` (10a/10c) stay exactly as those stories specify** — this
  story adds one dashboard action and reads `media_alerts` rows for AC8/AC9; it does not add
  columns, does not move any 10a/10c AC here, and does not change either table's schema.
- **Do not change the `war_room_sessions` migration's `scope` column type** without first
  verifying its actual current type (see Technical Requirements) — prefer application-level
  JSON encode/decode over a schema change if the column is `text` rather than `jsonb`.

## Dependencies

- **Depends on:**
  - **4b — `Nebu.Workers.MediaScanWorker`** — the exact scan-start/result/error call sites this
    story adds `Logger.*` metadata to.
  - **6a — Routine State Actions** — the Block/Unblock/Delete/Rescan `handle_event/3` clauses in
    `Nebu.Admin.MediaLive` this story adds `Logger.info/2` calls alongside.
  - **6c — Infected Override** — the Infected-Override `handle_event/3` clause, same treatment.
  - **10c — `media_alerts` + Trigger + Auto-Resolve** — the unresolved-`critical`-alert source and
    the `/admin/media/health` dashboard route this story's "Live-Diagnose starten" action is
    added to. This story cannot be meaningfully completed before 10c's table/route exist.
  - **3 — `Nebu.Media.ClamAV` GenServer** — the connect/disconnect/health-check log call sites
    this story adds `route_template: "/media/clamav"` metadata to.
  - (Transitively, already merged, not part of this epic) **`Nebu.Web.LogStore`,
    `Nebu.Admin.WarRoomManager`, `Nebu.Admin.LogsLive.TraceMap`/`TraceMapTree`,
    `Nebu.Web.LogStore.WarRoom`** — the Enhanced-Logging foundation this story integrates with
    rather than duplicates.
- **Enables:** nothing further in this epic — this is the last of the 10a–10e sub-stories
  (Intra-Split-Reihenfolge 5 von 5) and a leaf node in the epic's dependency graph.
