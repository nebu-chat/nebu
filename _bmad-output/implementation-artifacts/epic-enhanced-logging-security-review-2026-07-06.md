# Epic `enhanced-logging` — Cross-Story Security Review (SEC GATE 2)

**Date:** 2026-07-06
**Reviewer:** Kassandra (nebu-agent-kassandra)
**Gate:** Mandatory epic-level SEC GATE 2 — run AFTER all 5 stories were individually reviewed & approved. Scope here is CROSS-STORY composition/interaction only, not re-litigation of closed per-story findings.

## Scope

- Epic: `enhanced-logging`
- Base: `94399f39` (scaffold commit, pre-story-1)
- HEAD: `68fc3539` (branch `feature/enhanced-logging`)
- Diff size: 105 files, ~19,658 insertions
- Command: `git diff 94399f39..HEAD`
- Stories covered:
  1. matrix-payload-debug-logging (RequestLogger DEBUG payload + PayloadRedactor)
  2. operational-log-store (`operational_logs` table, central `:logger` Handler, batching Writer, RouteNormalizer, 5 retention keys)
  3. admin-logs-monitoring-view (`/admin/logs` LiveView, trace-map, live stream)
  4. admin-logs-retention-settings (`/admin/logs/config`, retention policy, 90-day WARN/ERROR safety-net TTL)
  5. war-room-mode (`war_room_sessions`, `WarRoom` GenServer, bounded elevated-logging sessions)

## Findings

| # | Severity | Story interaction | Location | Vulnerability | Status |
|---|----------|-------------------|----------|---------------|--------|
| X1 | MEDIUM | war-room-mode × admin-logs-retention-settings | `server/lib/nebu/web/log_store/retention.ex:50-62` | War-room-persisted INFO/DEBUG rows escape ALL retention pruning when their level's TTL is unset — the 90-day safety net covers only `warning`/`error` | NEW (cross-story) |

All other cross-story concerns examined: CLEAN or previously-accepted-and-still-accurate (see below).

## Detail

### Finding X1 — War-room override persists INFO/DEBUG rows that no retention policy prunes  [MEDIUM]

**The composition.** `Handler.log/2` (`handler.ex:51`) persists any war-room-tagged entry
REGARDLESS of the ambient collection policy:

```elixir
if LogStore.should_persist?(entry.level) or not is_nil(entry[:war_room_id]) do
  safe_write(entry)
end
```

This is correct and intentional for AC4 of war-room-mode. The problem is what happens to
those rows AFTERWARD. `Retention.prune_operational_logs/0` (`retention.ex:50-62`) prunes
exclusively **by level**:

- `prune_ttl("info", policy.log_retention_info_days)` / `prune_ttl("debug", ...)`
- `prune_max_count("info"/"debug", ...)`
- `prune_ttl("warning", 90)` / `prune_ttl("error", 90)`  ← the hardcoded safety-net

A war room is used precisely BECAUSE normal collection is off (`log_collect_info`/
`log_collect_debug` = false — the common case). When collection is off, an operator has no
reason to have set that level's retention, so `log_retention_info_days` /
`log_retention_debug_days` / their `max_count` siblings all default to `nil`
(`policy_cache.ex:37-44`, `log_store.ex:178`). With a `nil` TTL, `prune_ttl(_level, nil)`
is a no-op (`retention.ex:64`). The 90-day safety-net that admin-logs-retention-settings
added to close exactly this "always-collected-but-never-bounded" gap only fires for
`"warning"` / `"error"`.

**Net effect:** war-room-tagged rows at level `info` or `debug` (the /sync base INFO line
carries `user_id`/`device_id` metadata; the DEBUG line carries the redacted payload) are
persisted while collection is off and then **never pruned by anything** — indefinite
retention. This is bounded in VOLUME per session (`max_entries` ≤ 10 000, `max_duration_s`
≤ 3 600, enforced at the `WarRoomManager` trust boundary), so it is NOT a disk-exhaustion
DoS. But across sessions over time it is a genuine **GDPR storage-limitation** violation
for the very data most likely to contain fine-grained per-user diagnostic traces, and those
rows sit outside the crypto-shredding erasure scope (`Nebu.Compliance.UserDeletion` never
touches `operational_logs`).

**Why no single per-story review caught it:** operational-log-store flagged the
always-collected-but-unbounded tier and deferred it; admin-logs-retention-settings closed
that deferral with the 90-day net — but at that point war-room-mode's "persist INFO/DEBUG
regardless of policy" path did not yet exist. war-room-mode's own review confirmed the cap
sits at the write boundary and that redaction holds, but did not observe that its new
persist-override produces INFO/DEBUG rows the retention net does not reach. The gap only
exists in the COMPOSITION of the last two stories.

**Remediation (backend-only, no UI, mirrors the existing safety-net pattern):** in
`Retention.prune_operational_logs/0`, add a war-room-aware safety-net prune that is
level-independent, e.g.:

```elixir
safe_query(
  "DELETE FROM operational_logs WHERE war_room_id IS NOT NULL AND inserted_at < now() - ($1 || ' days')::interval",
  [to_string(@warn_error_safety_net_days)]
)
```

(Reuse the same 90-day constant — the `operational_logs_war_room_id_idx` from migration
000019 already supports this scan.) This bounds war-room row retention regardless of the
per-level TTL, exactly as the WARN/ERROR net bounds the always-collected tier.

## Cross-Story Concerns Examined — Confirmations

**1. Redaction LAW end-to-end through the full current pipeline — CLEAN.**
Traced a chat-message body via a Matrix write-path endpoint: `RequestLogger`
(`request_logger.ex:224-228`) applies `PayloadRedactor.redact_payload(params, in_content?: true)`
for send/state routes BEFORE building the `Logger.debug(fn -> ... end)` closure → the closure
returns already-redacted `Jason.encode!`-ed JSON → `Handler.parse_log_event/1` renders that
`{:string, ...}` msg UNCHANGED (`handler.ex:148`, moduledoc SECURITY LAW) → `maybe_tag_war_room/1`
delegates to `WarRoom.check/1`, which reads ONLY `route_template` + `metadata["user_id"/"device_id"]`
and writes back a `war_room_id` — it never reads or re-derives `message`/content
(`war_room.ex:56-62, 233-259`) → Writer persists the same entry → LogsLive renders via HEEx
(auto-escaped). Redaction holds at EVERY hop including the new war-room interception point.
The war-room persist-override (`handler.ex:51`) bypasses ONLY the `should_persist?/1`
collection-policy toggle — there is no other drop between that gate and `safe_write/1`, and
redaction happens entirely upstream (inside the `Logger.debug` closure), so the override
cannot bypass redaction. Confirms sanctum note `safety_cap_at_consumer_not_api` (correct shape).

**2. Admin-email PII leak fix (war-room MAJOR-1) complete across every auth shape — CLEAN.**
`extract_user_id/1` (`request_logger.ex:208-216`) is fail-closed: binary → passthrough
(Matrix/`OidcPlug` sets `current_user` to the `"@sub:server"` STRING, `oidc_plug.ex:111,144`);
map → prefers `"matrix_user_id"`, else `"sub"`, NEVER `"email"`, NEVER the whole map (Admin/
`Nebu.Admin.Auth` sets a map via `put_current_user`/`get_session "current_user"`,
`auth.ex:157,313`); ANY other shape → `nil`. The bootstrap flow mints the session through the
SAME `put_current_user/2` path (`auth.ex:585,632`) → same map shape → handled. Because the
catch-all clause returns `nil`, even an unanticipated third/future shape fails closed with
no leak. `device_id` is an opaque device identifier, not PII/content.

**3. `config_update_mutable` RLS allowlist final state — CLEAN.**
Latest migration touching the policy is 000018 (000019 creates `war_room_sessions`, does NOT
touch `server_config` policies). Diffed 000018's key list against 000017 key-by-key: the 19
pre-log keys are byte-identical; 000018 = 000017 + `log_retention_info_max_count`. All 6
policy keys managed by `LogStore.policy_keys/0` are present:
`log_collect_info`, `log_retention_info_days`, `log_retention_info_max_count`,
`log_collect_debug`, `log_retention_debug_days`, `log_retention_debug_max_count`. No earlier
key dropped by the later migration. Confirms sanctum note `server_config_rls_allowlist`.

**4a. WARN/ERROR 90-day safety-net still wired & not bypassed by war-room — CONFIRMED wired;
war-room rows NOT exempted from it.** `prune_ttl("warning"/"error", @warn_error_safety_net_days=90)`
is in `prune_operational_logs/0`'s call path (`retention.ex:58-59`). Pruning is by `level` +
`inserted_at` with NO `war_room_id` exemption, so a war-room-tagged WARN/ERROR row IS pruned
by the net (no unbounded-retention loophole for warn/error). BUT see Finding X1: the net does
NOT cover war-room-tagged INFO/DEBUG rows.

**4b. GDPR crypto-shred scope for `operational_logs`/`war_room_sessions` — no NEW escalation.**
The filter JSONB stores only `user_id`/`device_id` matrix identifiers (war_room_panel form
fields, `war_room_panel.ex:141-147`; `WarRoomManager` inserts them verbatim,
`war_room_manager.ex:61,211`). A matrix user_id in `filter` is a user identifier the design
explicitly anticipated (same category as `started_by TEXT`) — it does not introduce an email
or a new class of identifier the original erasure-scope risk didn't already cover. Still an
accepted, documented risk (unchanged), not a new escalation. `reason` is admin-entered free
text stored only in `war_room_sessions.reason` and is NOT emitted to any `Logger.*` call
(no Logger usage in any new admin module — verified) so it never reaches `operational_logs`.

**5. Access-control composition uniform across the whole epic surface — CLEAN.**
`/admin/logs/config` + `/admin/logs/config/retention`: `plug Nebu.Admin.Auth, :require_admin`
in `LogsController` (`logs_controller.ex:68`). `/admin/logs` LiveView: inside
`live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin}` (`router.ex:216-222`).
LogsLive's `mount/3` (with its PubSub subscribe, `logs_live.ex:90-91`) runs AFTER the
on_mount gate, and `handle_event("start_war_room"/"stop_war_room", ...)`
(`logs_live.ex:273,290`) fire only on a socket that already passed that gate. `WarRoomManager`
deliberately exposes NO HTTP route (design-decisions #6). No route or event handler reachable
without the admin gate.

**6. No NEW user-generated-text field of the N1/N2 class introduced by later stories — CLEAN.**
admin-logs-retention-settings' write endpoint carries only numeric/boolean retention values
(no user text). war-room-mode's inputs are `scope` (dropdown), `user_id`/`device_id`
(identifiers), `max_entries`/`max_duration_s` (numeric) and `reason` (admin text, never
logged). None is an end-user-generated-text field flowing through `PayloadRedactor`'s
field-name list. The pre-existing N1/N2 gaps (`search_term` in `/search`, `status_msg` in
`/presence`) remain the previously-accepted follow-up and were not widened. Confirms sanctum
note `redaction_wrapper_assumption` point 4 (enumeration complete for the new routes).

## Standard-Pass Notes (OWASP/ASVS/CWE/STRIDE)

- SQL: all new inline SQL uses parameterized `Ecto.Adapters.SQL.query!/3`
  (`war_room.ex`, `war_room_manager.ex`, `log_store.ex`, `retention.ex`). `get_logs/1` builds
  WHERE only from an allowlist of column names (`log_store.ex:197-211`) — no injection.
- XSS: all new admin views are HEEx (`{ }` auto-escaping); redacted message/metadata rendered
  escaped. Admin CSP present (`router.ex:86-92`).
- CSRF: `protect_from_forgery` in the `:browser` pipeline; the config POST is a real form.
- Handler never raises (rescue → `:ok`) so a malformed log event cannot crash arbitrary
  callers or the request path; WarRoom `check/1` is fail-open-to-nil on GenServer exit.
- Cache re-entrancy (PolicyCache `persistent_term`, WarRoom `persistent_term` fast-path)
  correctly avoids re-entering the `Nebu.Repo` pool from inside `Handler.log/2`.

## Accepted Risks (pre-existing, still accurate)

- `operational_logs` / `war_room_sessions` rows bearing `user_id`/`device_id`/`started_by`
  are outside the crypto-shredding erasure flow (`Nebu.Compliance.UserDeletion`). Documented,
  accepted; Finding X1's remediation reduces its blast radius by bounding war-room retention.
- N1/N2 (`search_term`, `status_msg`) redactor field-name-list gap at DEBUG — accepted
  follow-up, not widened by this epic.

## Follow-up Stories Required

None mandatory (no CRITICAL/HIGH). Finding X1 (MEDIUM) is advisory — recommend addressing
before the epic ships, ideally folded into a retention hardening follow-up, given it is a
compliance (storage-limitation) gap on user-identifier-bearing rows.

## Summary

CRITICAL: 0 | HIGH: 0 | MEDIUM: 1 | LOW: 0
New cross-story findings: 1 (X1)
Follow-up stories required: 0
Accepted risks reaffirmed: 2

**Epic security gate: PASS** (no CRITICAL/HIGH; one MEDIUM advisory to address before ship).
