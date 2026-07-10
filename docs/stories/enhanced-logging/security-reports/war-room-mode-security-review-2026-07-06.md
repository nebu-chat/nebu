## Security Review — war-room-mode (enhanced-logging, SEC Gate 1 — story-level)

**Diff scope:** `git diff --staged` — War Room Mode: bounded, tagged, self-terminating
elevated-logging sessions. New `war_room_sessions` table (mig 000019) + FK/partial-unique-index
on `operational_logs`; new `Nebu.Web.LogStore.WarRoom` GenServer (cache + atomicity boundary);
new `Nebu.Admin.WarRoomManager` (Admin-domain public API, inline SQL); new
`Nebu.Admin.LogsLive.WarRoomPanel` component; `LogsLive` `start_war_room`/`stop_war_room`
`handle_event` + `war_room_id` mount param; `Handler.log/2` `maybe_tag_war_room/1`;
`LogStore.get_logs/1` `war_room_id` filter + UUID normalization; `Writer` `war_room_id` column;
`RequestLogger` `user_id`/`device_id` metadata (+ cycle-1 `extract_user_id/1` PII fix); `app.js`
`wireWarRoomPanel()`.
**Date:** 2026-07-06
**Base story:** docs/stories/enhanced-logging/war-room-mode.md
**Classification:** MEDIUM/LOW-only — **APPROVED / not blocking** (0 CRITICAL, 0 HIGH)

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `war_room_manager.ex` `start_session/1` / `validate_required/1` | The flooding-safety invariant (the story's entire raison d'être — bound `max_entries`/`max_duration_s` so a `/sync`-scoped session cannot fill the DB) is enforced ONLY in the `LogsLive` UI (`parse_int_bounded/5`, 10..10 000 / 10..3 600). The public-API trust boundary (`WarRoomManager.start_session/1`) validates only presence, not numeric range — any direct caller can create an unbounded session. | Enforce `max_entries`/`max_duration_s` numeric bounds in `validate_required/1` (or a new `validate_bounds/1`) at the manager, so the invariant lives at the persistence boundary, not the consumer form. |
| F-2 | LOW | `war_room_manager.ex` (start/stop) | War Room start/stop is NOT recorded in the tamper-evident `Nebu.Compliance.AuditLog`; the sole accountability record is the mutable `war_room_sessions` row (`entries_collected`/`ended_at` are UPDATEd; `started_by` alterable with DB access). | Optionally emit an `audit_log` entry (`war_room_started`/`war_room_stopped`) registered in `@known_actions` for a durable actor trail. Acceptable as-is given the operational (non-compliance) nature of the store. |
| F-3 | LOW/INFO | `war_room.ex` `check/1` + `handler.ex` `maybe_tag_war_room/1` | While a session is active, EVERY app-wide `Logger.*` call funnels a `GenServer.call/2` through the single `WarRoom` process (the atomicity boundary). | No action — fails safe: non-matching entries are fast in-memory; matching writes are DB-bounded by `max_entries`; `check/1` catches `:exit` (overwhelmed/timed-out GenServer → entry untagged, logging proceeds). Bounded + admin-initiated + self-terminating + graceful degradation. |

### Detail

**Finding #1 — Bounded-collection invariant not enforced at the public-API trust boundary** [MEDIUM]
The story exists specifically to prevent DB flooding (AC7/AC8: `/sync` "1000s of entries per
second"). `Nebu.Admin.WarRoomManager` is an explicit "public API" module (ADR-020). Its
`start_session/1` only checks that `started_by`/`reason`/`max_entries`/`max_duration_s` are
present (`validate_required/1` → `blank?/1`) — it never bounds the two budget integers. The
10..10 000 / 10..3 600 caps live exclusively in the consumer (`LogsLive.parse_int_bounded/5`).
Today the only caller is the admin-gated LiveView form, so the practical exposure requires an
authenticated admin bypassing their own UI (crafted `phx-submit`, or a future direct caller —
another story, a console, a test). Absurd values largely fail safe (`max_duration_s`≤0 or
`max_entries`≤0 → immediate termination on load/first entry; a `max_duration_s` above Erlang's
~49.7-day `Process.send_after` ceiling raises inside `schedule_timeout/1`, caught by
`do_load_active/1`'s `rescue` → the row stays active-but-timerless-and-not-collecting, blocking
future sessions until manual stop). But a large finite `max_entries` (e.g. 10^9) with `scope="all"`
would collect until that budget — defeating the very flooding protection the story ships. This is
the recurring "validate at the persistence boundary, not only at the consumer" pattern
(Epic 14 lazy-validation; Epic 11 DB-module trust-boundary). No data leak → MEDIUM, not HIGH.

**Finding #2 — Lifecycle not in the immutable audit trail** [LOW]
`war_room_sessions` captures `started_by`/`reason`/`started_at`/`ended_at`/`ended_reason` — a
genuine accountability record, and `started_by` is server-derived (see below), so this is
adequate for v1. It is, however, a mutable diagnostics table, not the tamper-evident
`Compliance.AuditLog`. Recording the enable/disable of elevated logging in the compliance trail
would harden accountability. Consistent with the store's deliberately operational (not compliance)
posture — advisory.

**Finding #3 — Single-GenServer serialization of all logging during an active session** [LOW/INFO]
See table. Design-reviewed (Oracle gate), fails safe. Advisory only.

### Targeted-verification results (coordinator's 7 mandated checks)

1. **Redaction LAW holds during an ACTIVE war room — BOTH halves — VERIFIED CLEAN.** The war-room
   override changes ONLY the persist decision (`Handler.log/2`: `should_persist?(level) or not
   is_nil(war_room_id)`), never message content. `maybe_tag_war_room/1` → `WarRoom.check/1` reads
   ONLY `route_template` + `metadata["user_id"/"device_id"]` and writes back `war_room_id` — it
   never touches `entry.message`. Redaction (credentials via `redact_auth_header`/
   `redacted_query_string`/`PayloadRedactor`; chat content via `PayloadRedactor.redact_payload`
   with route-aware `in_content?`) happens entirely upstream in `RequestLogger` INSIDE the
   `Logger.debug(fn -> ... end)` closure, before the event ever reaches `Handler`. An entry
   persisted via the war-room `should_persist?` bypass is the SAME already-redacted entry. War Room
   does not even elevate `Logger.level()` — it only overrides the LogStore persist gate — so it
   introduces no new capture path, hence no new leak path.
2. **Self-termination reliability — VERIFIED.** (a) Cross-restart: `init/1` → `do_load_active/1`
   ends an already-past-deadline session immediately as `duration_exceeded`, else schedules
   `remaining_ms` — a restart cannot silently forget an expired session. (b) Budget: single atomic
   `UPDATE ... SET entries_collected+1, ended_at=CASE WHEN entries_collected+1 >= max_entries ...`
   (single statement, no read-then-write race); all `check/1` calls serialize through one GenServer,
   in-memory session flips to `nil` in the same `handle_call` that crosses the budget → the N+1th
   entry hits the `%{session: nil}` clause and is not tagged, and the DB counter stops at
   `max_entries` (`>=`, no off-by-one). (c) 0/negative budgets fail safe (immediate end); huge
   values — see F-1.
3. **Scoping/tagging — VERIFIED CLEAN.** `war_room_id` derives from the single cached session id;
   "exactly one active" is DB-enforced (partial unique index) so there is no ambiguity. After a
   session ends, `active_flag=false` → `check/1` returns `nil` → entries between session A end and
   session B start are untagged (never mis-attributed). AC12 `get_logs(%{war_room_id: id})` filter
   works (allowlist + UUID binary/string normalization).
4. **Access control + audit — VERIFIED.** `LogsLive` is inside `live_session :admin, on_mount:
   {Nebu.Admin.Auth, :require_admin}` — the hook runs on BOTH static render and socket connect
   (pattern #65), so `start_war_room`/`stop_war_room` `handle_event` clauses are gated, not just
   mount. `started_by` = `socket.assigns.current_admin_id`, set at mount from
   `admin_id_from_session(session)` (signed session cookie's `current_user.sub`/`matrix_user_id`) —
   NEVER from client params → not spoofable. (Audit-trail durability: F-2.)
5. **MAJOR-1 PII fix (`extract_user_id/1`) — INDEPENDENTLY VERIFIED COMPLETE.** Handles every
   real `conn.assigns.current_user` shape: Matrix routes assign a bare string (oidc_plug.ex:111,144
   — `sess.user_id`/`user_id`) → passes through; admin routes assign a map (auth.ex:287-294 with
   `"sub"`/`"email"`/`"admin"`/`"matrix_user_id"`) → yields `matrix_user_id` (non-empty binary) else
   `sub`, NEVER `email`, never the whole map; any other shape → `nil`. `device_id` confirmed always a
   plain string or `nil` (oidc_plug.ex:112,146 are the only assign sites — `sess.device_id` /
   `DeviceBinding.get_device/1`; admin routes never assign it → `nil`). No other conn.assigns shape
   reaches `Logger.metadata`.
6. **AC9 filter/scope injection & DoS — VERIFIED CLEAN.** `scope` stored parameterized ($3), matched
   in Elixir by exact `==` (no regex → no ReDoS). `filter` stored as JSONB parameterized ($4),
   matched by in-Elixir `Enum.all?/Map.get ==` (never interpolated into SQL). `get_logs/1`
   `build_where/1` interpolates ONLY allowlisted column names (`@allowed_filter_keys`), all values
   parameterized. No SQL fragment injection via scope or JSONB filter.
7. **DB partial-unique-index backstop — VERIFIED GENUINE.** `war_room_sessions_single_active_idx ON
   ((1)) WHERE ended_at IS NULL`. The ONLY INSERT path is `insert_session/1`, which maps a
   `:unique_violation` to the friendly `{:error, :conflict, ...}` tuple (re-fetches the existing
   session; no raw SQL error / stacktrace leaked to the UI); non-unique errors are `reraise`d.
   `WarRoom` only ever UPDATEs. No direct-insert bypass.

Additional: WarRoomPanel renders `started_by`/`started_at`/`reason` via HEEx `{...}` auto-escape,
no `raw/1` anywhere (XSS-safe on admin-supplied free text). Writer INSERT uses hardcoded `@columns`
+ parameterized values ($N) — `war_room_id` parameterized. Down migration leaves the
`operational_logs.war_room_id` column (owned by 000017), CASCADE-drops the FK/table — benign.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 1 (F-1 — advisory, address before epic end; not blocking)
LOW: 2 (F-2 audit-trail durability; F-3 serialization — both advisory)

**Verdict:** APPROVED. The just-fixed MAJOR-1 PII leak is complete and correct; the redaction LAW
holds in both categories during an active session; self-termination, scoping, access control, and
the injection/DoS surfaces are all sound. The one MEDIUM (F-1) is a defense-in-depth hardening of
the story's own core safety invariant at the public-API boundary — recommended as a small follow-up,
not a merge blocker.
