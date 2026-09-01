# Security Review — media-security-admin-control / 10e-trace-map-war-room-integration

**Reviewer:** Kassandra (nebu-agent-kassandra, adversarial security review)
**Diff scope:** `git diff --staged` — Trace-Map/War-Room instrumentation of the media-scan
pipeline plus the "Live-Diagnose starten" dashboard jump-off point:
- `server/lib/nebu/media/clamav.ex` — `route_template: "/media/clamav"` metadata on the
  healthy-transition (`Logger.info/2`, transition-gated) and unreachable (`Logger.warning/2`) log calls
- `server/lib/nebu/workers/media_scan_worker.ex` — scan-start / released / infected / error
  log calls with `route_template: "/media/scan_worker"`, `request_id: media_id`
- `server/lib/nebu/admin/media_live.ex` — `log_admin_media_action/2` (`Logger.info/2`) alongside
  each Block/Unblock/Delete/Rescan/Infected-Override handler
- `server/lib/nebu/web/log_store/war_room.ex` — additive list-form `scope_matches?/2` clause +
  `decode_scope/1`
- `server/lib/nebu/admin/war_room_manager.ex` — `validate_scope/1`, `encode_scope/1`/`decode_scope/1`,
  `row_to_session/1` string-`id` conversion, `stop_session/1` UUID cast/dump normalization
- `server/lib/nebu/admin/logs_live/war_room.ex` — disambiguating comment only
- `server/lib/nebu/admin/media_health_live.ex` — `handle_event("start_media_diagnosis", ...)`,
  `actor_id/1`, conflict-error assign + template
- test files (not security-load-bearing; reviewed for negative-path coverage)

**Date:** 2026-07-20
**Verdict:** **APPROVED — CLEAN** (0 CRITICAL, 0 HIGH, 0 MEDIUM; 2 LOW advisory)

---

## Method

Every claim was re-derived against live source, not the diff hunks alone. The six
security-relevant angles the story flagged were each walked to ground:

- Read `media_health_live.ex` end-to-end (mount → assigns → the new `handle_event`) and
  traced the route `/media/health` to its `live_session :admin, on_mount:
  {Nebu.Admin.Auth, :require_admin}` block (`server/lib/nebu/admin/router.ex:225,257`).
- Read `WarRoomManager` end-to-end: `start_session/1` → `validate_required/1` →
  `validate_bounds/1` → `validate_scope/1`; `insert_session/1` (parameterized SQL);
  `stop_session/1`'s new `uuid_dump(Ecto.UUID.cast(id))` path; `row_to_session/1`'s
  `Ecto.UUID.load!/1`; `encode_scope/1`/`decode_scope/1` and `same_session?/1` round-trip.
- Read `Nebu.Web.LogStore.WarRoom.scope_matches?/2` (all clauses) and its `decode_scope/1`,
  plus `LogStore.get_logs/1` / `build_where/1` / `normalize_filter_value/1` for the
  bookmarkable `?war_room_id=` path this story makes the normal jump-off target.
- Confirmed no `AuditWriter`/`@known_actions` change anywhere in the staged diff.
- Checked `MEMORY.md` accepted-risks — none of the below re-flags a formally accepted risk.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `war_room_manager.ex` `validate_scope/1` | List-shaped `scope` has no length/element-length bound; a direct programmatic admin caller could set a very large list, adding O(n) per-entry cost to the hot-path matcher. Not reachable via the media-health UI (3-element literal). | Optionally cap list length (e.g. ≤ 64) in `validate_scope/1`, mirroring a future bound on `validate_exclusive_scope/1`. Defense-in-depth only. |
| 2 | LOW (pre-existing watch-flag) | `web/log_store.ex:260-265` `normalize_filter_value("war_room_id", …)` | A malformed `?war_room_id=<garbage>` URL param fails `Ecto.UUID.cast/1`, falls through `:error -> v`, and the raw non-UUID string is bound to the native `uuid` column via `query!` → Postgrex encode error → LiveView mount crash. Pre-existing `enhanced-logging` code (not in this diff), admin-authenticated, self-inflicted. This story makes that URL the normal jump-off path, raising its visibility. | On cast failure, short-circuit to an empty result (return `{:ok, []}`) instead of binding an invalid value into a `uuid`-typed parameter. Track for the enhanced-logging owner. |

---

## Detail

### The six flagged angles — resolution

**1. No new PII / sensitive-data leak path — HOLDS.**
Every new `Logger.*` call carries only bare identifiers as metadata:
`route_template` (a static string literal), `request_id: media_id` (a UUID),
`clamav_signature` (a virus-signature name, e.g. `Eicar-Test-Signature` — an identifier,
not file content), and `reason: inspect(reason)` (an error term). The rendered `message`
strings are static or contain only `media_id` / the clamd `address` (config, not user
data). No filename (the worker has only `storage_key`/`media_id`, never the original
filename — per Story 1a/4b), no uploader identity beyond the pre-existing `user_id`
precedent, and no Matrix room/event content appears in any call site in `clamav.ex`,
`media_scan_worker.ex`, or `media_live.ex`. This matches AC6 and the `RequestLogger`
`user_id`/`device_id` precedent exactly; `PayloadRedactor` correctly remains untouched
(these calls carry no HTTP body to redact).

**2. War Room session-start authorization — SOUND, no `started_by` spoof.**
`/media/health` is registered inside `live_session :admin, on_mount:
{Nebu.Admin.Auth, :require_admin}` (`router.ex:225,257`), so both `mount/3` and every
subsequent `handle_event/3` are gated by the admin `on_mount` hook — an unauthenticated or
non-admin socket never reaches `start_media_diagnosis`. The client event payload is only
`%{"reason" => reason}`; `started_by` is set server-side from
`socket.assigns.current_admin_id`, itself derived in `mount/3` via
`actor_id(socket.assigns.current_user)` from the on_mount-populated `current_user`. There
is no path for the client to supply or override `started_by`. If `actor_id/1` ever returns
`nil`, `validate_required/1` rejects with `{:error, :invalid_params, …}` (blank check) and
the dashboard renders the error — no crash, no anonymous session.

**3. Scope list injection / DoS — attacker-uncontrolled in this story's flow.**
The scope in `start_media_diagnosis` is a hardcoded 3-element literal
(`["/media/clamav", "/media/scan_worker", "/admin/media"]`); the only user-supplied field
is `reason` (free text, parameterized into SQL, HEEx-escaped on render). The list therefore
never carries attacker input via the media-health UI. `validate_scope/1` adds
defense-in-depth shape validation (every element a string starting with `/`). The residual
concern — an unbounded list from a *direct* programmatic admin caller inflating the
hot-path `route in scope` cost — is admin-only origin and identical to the pre-existing
unbounded `exclusive_scope`; captured as **Finding #1 (LOW)**. `decode_scope/1` runs on
cache load (`load_active/0`), not per log entry, so list decoding is not a per-entry cost.

**4. UUID handling under adversarial input — `stop_session/1` is safe.**
`stop_session/1`'s new `uuid_dump(Ecto.UUID.cast(id))` cleanly rejects any
malformed/non-UUID `id`: `Ecto.UUID.cast/1` returns `:error`, `uuid_dump(:error)` returns
`:error`, and the function returns `{:error, :not_found}` — no crash, no raw-string binding
to the `uuid` column. `row_to_session/1`'s `Ecto.UUID.load!/1` operates only on the DB's
own 16-byte `uuid` values (never attacker input) and yields a canonical string, so
`push_navigate(to: "/admin/logs?war_room_id=#{session.id}")` always interpolates a
well-formed UUID — no open-redirect or injection surface in the produced URL. The one
rough edge is on the *consuming* side (`LogStore.get_logs/1`), a pre-existing enhanced-logging
path this story merely makes more prominent — captured as **Finding #2 (LOW watch-flag)**.

**5. Audit-trail completeness — AC3 is genuinely additive.**
The staged diff contains no `AuditWriter` edit and no `@known_actions` entry (confirmed by
`grep` over the full staged diff). `log_admin_media_action/2` is a new, independent
`Logger.info/2` call placed *after* the successful action in each handler; the existing
`AuditWriter.log/6` write lives in `Nebu.Media`'s `write_admin_audit/4` and is untouched.
The project's "Audit allowlist merge gotcha" is respected — this operational log does not
add or displace a compliance action.

**6. Compliance vs. operational-log distinction — preserved.**
The new channel is plain `operational_logs` (mutable, policy-gated) and is documented in
code as a *second, independent* visibility channel, never a substitute for the immutable
compliance audit trail. No downstream code path was introduced that reads the operational
log in place of the audit trail. The MAJOR-1 cycle-2 fix (transition-gating the ClamAV
"healthy" log so it no longer writes an unbounded WARN/ERROR row on every poll) was
verified present in `clamav.ex` (`was_healthy? = state.healthy` compared against
`new_state.healthy`, log only on the `false -> true` flip), and MAJOR-2's severity
correction (`:info` on routine/success paths, `:warning` retained on infected/error) is
in place at every call site.

### Backward-compatibility of `encode_scope`/`decode_scope` — verified

`decode_scope/1` only substitutes when `Jason.decode/1` yields a *list*; every pre-existing
scalar form (`nil`, `"all"`, an exact `route_template` string beginning with `/`, or a bare
value like `"123"`) either fails JSON decoding or decodes to a non-list and is returned
unchanged. `same_session?/1`'s idempotent-restart comparison holds because both
`existing.scope` (decoded list) and `params.scope` (list) are compared in the same shape.

### XSS / output encoding — clean

`alert.message`, `alert.media_id`, and `@diagnosis_error` are all DB/server-sourced and
rendered through HEEx (`{…}` and attribute interpolation), which auto-escapes. The
`role="alert"` error paragraph and the pre-filled `value={alert.message}` input introduce
no unescaped sink.

---

## Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 2 — advisory (Finding #1 defense-in-depth list bound; Finding #2 pre-existing
`war_room_id` filter watch-flag, not introduced by this story)

**Verdict:** **APPROVED — CLEAN.** No CRITICAL/HIGH/MEDIUM findings; nothing blocks the
commit. The two LOW items are hardening advisories, both admin-authenticated and
self-inflicted at worst, one of which is pre-existing to the enhanced-logging epic.
