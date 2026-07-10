## Security Review — enhanced-logging/war-room-dedicated-page (SEC Gate 1)

**Diff scope:** staged diff (`git diff --staged`). Key surfaces: new dedicated War Room
LiveView `Nebu.Admin.LogsLive.WarRoom` (`server/lib/nebu/admin/logs_live/war_room.ex`,
list + detail + scoping form + copy-to-markdown export), `exclusive_scope` handling in
`Nebu.Web.LogStore.WarRoom.check/1` and `Nebu.Admin.WarRoomManager.start_session/1`,
migration `000021_war_room_exclusive_scope`, sidebar dot / topbar pill
(`war_room_indicator.ex` + `layouts.ex` + `WarRoomPill` hook in `app.js`), `:readonly`
mode on `TraceMapBubble`, router repoint.
**Date:** 2026-07-08
**Reviewer:** Kassandra
**Frameworks:** OWASP Top 10, ASVS L2, CWE Top 25, STRIDE.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `war_room_manager.ex:169-186` `validate_exclusive_scope/1` | Shape validation caps neither list length nor element length. A crafted WS `start_war_room` payload (bypassing the ~4-checkbox UI) can store an arbitrarily large `exclusive_scope` JSONB array of arbitrarily long strings; `WarRoom.check/1`'s `route in exclusive_scope` then runs a linear scan of that list on the hot logging path (`Handler.log/2`) for every log event during the session — the Oracle-gate path that "MUST NOT delay a /sync response". Authenticated-admin, self-scoped, session-bounded → low impact. | Bound the list in `validate_exclusive_scope/1`: reject when `length(list) > 50` and when any element exceeds e.g. 255 bytes. Defense-in-depth, mirrors the F-1 bounds precedent already in this module. |

### Detail

**Finding #1 — Unbounded exclusive_scope list on the hot logging path** [LOW]

`validate_exclusive_scope/1` accepts any list whose every element is a binary starting
with `/` (`valid_route_shape?/1`) — deliberately a shape check, not a closed allowlist,
per AC9's free-text "other" input. Correct as far as it goes, but it places no cap on the
number of elements or their length. The LiveView form only offers
`long_polling_endpoints/0` checkboxes plus one free-text field, so a normal operator
produces a tiny list; however, `start_session/1` is the real trust boundary (its own
moduledoc says so) and a raw crafted WebSocket `start_war_room` frame can submit
`exclusive_scope[]` with thousands of long entries. Once stored, every log event while
that session is active flows `Handler.log/2 -> WarRoom.check/1 -> matches? -> excluded?`,
and `excluded?/2` evaluates `route in exclusive_scope` — an O(n) linear scan — on a path
the module's own moduledoc flags as latency-sensitive ("MUST NOT delay a /sync
response"). Because triggering it requires admin privilege, affects only the
attacker-admin's own single active session, and is bounded by `max_entries`/duration, this
is a hardening opportunity rather than an exploitable DoS. Add a length/element cap to
`validate_exclusive_scope/1`.

### Focus-area verdicts (task-specified)

1. **Detail-view historical log exposure — CLEAN.** `/admin/logs/war-room/{room_id}`
   renders `entry.message`/`level`/`source`/`route_template`/`inserted_at` only, read via
   the same `Nebu.Web.LogStore.get_logs/1` used everywhere else. `operational_logs.message`
   is redacted **at write time** in `Nebu.Web.Plugs.RequestLogger`, upstream of
   `Handler.log/2` (`handler.ex:16-23` "SECURITY LAW — never a second unredacted leak
   path"; war-room capture overrides only the persist/retention gate, never redaction).
   The detail view therefore reads an already-redacted value and, notably, renders *fewer*
   fields than the existing `DetailPanel` — it omits the `<details>` `{inspect(metadata)}`
   block (`detail_panel.ex:84-86`). No new exposure path; amendment 7(b) satisfied.

2. **Copy-to-markdown export — CLEAN.** The handler lives in `LogsLive.WarRoom`, mounted
   only via `live "/logs/war-room/:room_id"` inside the `live_session :admin,
   on_mount: {Nebu.Admin.Auth, :require_admin}` block (`router.ex:216-238`) — admin gate
   applies. The markdown template (`markdown_text/2`, `markdown_entry_line/1`) emits only
   fields already visible on the page (session metadata + the same redacted `entry.message`
   per row); it adds no field the page does not already show. `data-copy-text` is an
   ordinary HEEx-interpolated attribute → auto-escaped.

3. **exclusive_scope shape-validation bypass — CLEAN (matching logic), LOW (unbounded
   length, Finding #1).** `excluded?/2` in `log_store/war_room.ex:246-249` uses
   `route in exclusive_scope` — exact Elixir list membership, no regex, no SQL `LIKE`, no
   pattern compilation anywhere. Unicode/regex-special/long strings cannot alter matching
   semantics (they simply never equal a real `route_template`). `scope_matches?/2` is
   likewise exact `==`. Rendering of `exclusive_scope` (via `scope_label/1`, markdown) is
   auto-escaped. The only residue is unbounded list size → Finding #1.

4. **Migration 000021 RLS posture — CLEAN.** `ALTER TABLE war_room_sessions ADD COLUMN
   ... exclusive_scope JSONB` — RLS in Postgres is table-level, so the new column inherits
   `war_room_sessions`' existing posture with no column-specific policy possible or needed.
   `war_room_sessions` was created in 000019 with **no** RLS (consistent with the
   single-role `nebu_app`-owner deployment model and the `audit_log` FORCE-RLS accepted
   risk); this diff does not change that posture. Unlike 000020 (which modified the
   `config_update_mutable` *policy* on `server_config`, a policy-guarded table), 000021
   touches a non-policy table and needs no policy edit. Informational only.

5. **Admin authz on new routes + handle_event clauses — CLEAN.** Both `/logs/war-room`
   and `/logs/war-room/:room_id` are inside the `live_session :admin` block. All
   `handle_event` clauses (`start_war_room`, `stop_war_room`, `scope_changed`,
   `copy_to_markdown`) are methods of that admin-gated LiveView; `started_by` is
   server-derived from the session (`admin_id_from_session/1`, `current_user.sub`), never
   client-supplied. No per-session ownership model exists (War Room is an admin-global
   feature), so any admin viewing any session is by-design, not IDOR.

6. **Empty-exclusive-scope MINOR fix — CLEAN, real, not bypassable.** `start_war_room`
   (`war_room.ex:205-218`) rejects `scope == "exclusive"` with `merge_exclusive_scope/1
   == nil` server-side, before any DB write, surfacing `@start_error` and starting no
   session. The guard runs on the server regardless of client payload; a crafted frame
   cannot skip it (submitting `scope: "all"` directly is a legitimate, pre-existing option,
   not a bypass of this specific degradation). Robust.

### Other dimensions checked (no findings)

- **XSS (CWE-79):** every admin/operator-supplied field — `reason`, `exclusive_other`,
  custom routes, `filter` values, `started_by` — rendered via HEEx `{...}` auto-escaping,
  including inside `data-copy-text`, `data-room-id`, `title`, `data-started-at`. No `raw/1`
  / `Phoenix.HTML.raw` / `safe_html` anywhere in the new module (pinned by an XSS-shaped
  test per code-review). `WarRoomPill` hook reads a numeric `data-started-at` and writes
  `textContent` (not `innerHTML`).
- **SQL injection (CWE-89):** all queries parameterized (`$1..$7`). `@session_columns` is a
  compile-time string constant, not user input. `load_session/1` casts `room_id` through
  `Ecto.UUID.cast |> dump` to a bound 16-byte binary and rescues malformed input to a 404.
- **STRIDE / DoS:** hot-path linear scan of unbounded `exclusive_scope` → Finding #1
  (LOW). `max_entries`/`max_duration_s` flooding bounds enforced server-side at the trust
  boundary (`validate_bounds/1`, F-1 precedent) — not client-only.
- **CSP:** copy-to-markdown reuses the existing document-level `nebu:copy-thread` listener;
  `WarRoomPill` is a registered hook reading a data attribute — no inline JS.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 1 — advisory (unbounded `exclusive_scope` list on the hot logging path)

**Verdict:** APPROVED — no commit-blocking findings. Classification: **CLEAN**. The single
LOW is a defense-in-depth hardening suggestion, not an exploitable path.
