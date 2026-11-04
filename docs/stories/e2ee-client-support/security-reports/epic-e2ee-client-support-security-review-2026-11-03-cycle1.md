# Epic e2ee-client-support Security Review — 2026-11-03 cycle 1 (SEC Gate 2, delta re-run)

## Scope
- Epic: e2ee-client-support (REQ-2026-013/014/015)
- Base: 5404d7d01ad4d5907e2667a74b65694d7ea70e29
- HEAD: c7d28161 (branch feature/e2ee-client-support)
- Stories covered: server-side-key-backup (34145ef7), to-device-messaging (d41ec675, 68a582a0), device-key-directory (459186be), key-query-hardening (88622038), e2ee-compliance-channel-guard (fce36bf5, c7d28161; follow-up of the epic gate)
- Excluded: 262e8dc3, 6e7ec21a (skills/** pipeline tooling only)
- Delta reviewed in depth: fce36bf5 product files (event_dispatcher/server.ex, http_to_device.ex, raw_body_reader.ex, router/protected.ex), ADR-011 update 2026-11-03, 11-risks, 07-deployment, 08-concepts, matrix-api-scope; re-verification of every room write path and of the migration runner / ReleaseTest guard against current code
- Previous epic report: epic-e2ee-client-support-security-review-2026-11-03.md (HIGH 1, MEDIUM 2, LOW 3, BLOCKED)

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| 1 | (was HIGH) | cross-story | protected.ex:1835, :3350; event_dispatcher/server.ex:176, :976, :9318, :9374; http_to_device.ex:42-56, protected.ex:794-797 | Opaque non-archived channel / in-band covert E2EE | CLOSED — options (a)+(b) implemented, residual accepted by owner (d) in ADR-011 / 11-risks / 07-deployment |
| 2 | MEDIUM | all (migrations 000058-000061) | release.ex:303 `select_pending/2`; release_test.exs:171-172 | Migration gap 000056/000057 | MITIGATED — release precondition documented, enforced at merge by the (red) ReleaseTest contiguity assertion in the CI `test-unit-elixir` jobs; no extra check required before merge (see detail) |
| 3 | MEDIUM | cross-story | room_keys parse/bulk read, to_device_store delivery decode, sync tier | Aggregate per-account node memory | ACCEPTED — 11-risks row "E2EE epic aggregate memory" |
| 4 | LOW | to-device + key-query-hardening | user_deletion.ex | Concurrent erasures deadlock (40P01, fails closed) | ACCEPTED — 11-risks |
| 5 | LOW | device-key-directory | protected.ex `device_list_pre` | /sync side door to device-list scan under per-IP sync tier | ACCEPTED — 11-risks |
| 6 | (was LOW) | key-query-hardening | raw_body_reader.ex:126 | device_signing/upload outside key-material body exclusion | CLOSED — clause added |
| 7 | LOW (new) | all (migrations) | 07-deployment.md "release preconditions"; release.ex `migrate/0` | No recovery instruction for databases that ALREADY applied 000058-000061 (local dev stack after `make redeploy`, any preview DB); `migrate/0` itself does not refuse a gap at runtime | Advisory |

## Detail

**Finding #1 — closed.** Verified against current code:
- Room writes. Every client write of a room event funnels through (i) `PUT /rooms/{id}/send/{type}/{txn}` (protected.ex:1823; refuses `encrypted_room_event?/1` as the FIRST cond clause, before JSON/size checks, room lookup and txn-dedup; the type is the path param already decoded once by `Plug.Router.Utils.decode_path_info!`, so `m.room.%65ncrypted` is caught, and a double-encoded spelling is stored as a different literal type that no client interprets as encrypted — tested), (ii) the two state PUT routes (both go through `set_room_state_request/4`, refusal right after the `m.room.encryption` clause), (iii) `EventDispatcher.Server.send_event/2` (new first clause raises 403 for `event_type: "m.room.encrypted"`; the only caller of `Room.Server.send_event/6` is this dispatcher), (iv) createRoom `initial_state` (`@initial_state_forbidden_types` now includes the type), (v) the `emit_state_event_at/6` funnel (presets, name/topic/alias, Admin Space form, upgrade copies) now checks `check_not_encrypted_event/1` first, and the upgrade `copy_state_events` exclusion list skips legacy rows. `write_state/5` (Room.Server, PUT state) is reachable only after the router refusal. `/redact` writes `m.room.redaction` only. No other INSERT INTO events path takes a client type. Exact string match, no case-folding issue (Matrix types are case-sensitive; `M.room.encrypted` is not interpreted by any client).
- To-device. `@allowed_event_types` is an exact MapSet (13 types) with `is_binary` guard; `refuse_unlisted_type/2` runs right after the `:authenticate` plug and before the rate limit, send slot, body read, budgets and recipients; fixed 400 text, no echo, recipient independent. `check_type/1` is also first inside `send_to_device/3`. Bypassing the limiter for refused types adds no surface: the refused path costs one MapSet lookup after authentication, the same as the already unthrottled `GET /account/whoami`.
- Residual documentation is truthful: ADR-011 update 2026-11-03 point (3) names to-device as a non-archived, server-opaque user-to-user channel for the allowlisted types, says explicitly "type filter, not content filter" with the types under which arbitrary content passes, states "no per-send audit", names key-backup blobs and cross-signing signatures as opaque client data, and records owner acceptance at the epic gate; 11-risks carries the matching Accepted-risk row; 07-deployment names the allowlist, the change process (reviewed one-line change) and the Element Call exclusion. The remaining risk (bounded by 64 KiB/request, 50 recipients, queue and sender budgets, 7-day TTL, rate limits; exploitable only by cooperating authenticated users who could equally exchange data out of band) is acceptable as documented for a compliance product whose guarantee is "rooms are archived and server-readable", which now holds for every room write path.
- INFO (no finding): ciphertext under a custom room event type (e.g. `org.x.encrypted`) or inside `m.room.message.body` is still storable; it IS archived (sender, room, timestamp, bytes) and no standard client decrypts it automatically, so it needs modified clients on both ends — equivalent to out-of-band encryption, outside what any server can filter. Consistent with the "type filter, not content filter" wording.

**Finding #2 — mitigated, documentation + existing CI guard suffices for the merge gate.** `release_test.exs:171-172` asserts versions == 1..N; on this branch (…55, 58…61) it fails, so `test-unit-elixir` / `test-unit-elixir-1-19` (CI, `--warnings-as-errors`) are red on every pipeline of this branch and of any merge result that lacks 000056/000057. That is an enforced, automated check at exactly the point that matters (a merge to main or into the integration branch cannot go green without the OAuth migrations). 11-risks and 07-deployment state the precondition and the reason. I do not require an additional check before merge. The residual is deployment of an intermediate build (see #7).

**Finding #7 — no recovery note for databases that already took 000058-000061** [LOW]
CLAUDE.md mandates `make redeploy` after code commits, so the local dev database of this worktree has very likely recorded version 61 already; once the OAuth branch lands it will silently never get 000056 (server_config RLS allowlist) / 000057 (`oauth_consent_grants`), failing closed (RLS error on save, 500 on consent). 07-deployment says "never deploy a build of this epic on a database that has not yet applied the OAuth migrations" but not what to do if it happened. Remediation: one sentence in 07-deployment ("reset / re-create every database that already applied 000058-000061 before 000056/000057, or apply 000056/000057 manually and verify"), and as hardening make `migrate/0` refuse to start when the directory contains a version <= current that is absent from a recorded applied set (or record every applied version). Dev/preview only, no bypass, fail closed.

## Cross-Story Patterns

- **New code vs epic invariants (re-checked).** The guard adds no lock, no advisory key, no ETS table, no global budget and no new DB statement; the refused to-device path allocates no limiter bucket and no slot (keyed state unchanged). The dispatcher's new `send_event/2` clause raises before any room process call, so it cannot interact with the room-process serialization or the sync_global / 4760-60 lock order documented in the previous report. Lock-order summary of the previous report stands unchanged.
- **Funnel placement.** The room refusal sits in the shared funnel (`emit_state_event_at/6`) plus the upstream routes, so future state writers inherit it; the upgrade copy path (a formerly-open legacy source) is excluded explicitly. Same pattern as the `m.room.encryption` guards.
- **Logging.** `keys/device_signing/upload` now joins the key-material body exclusion; refusal texts are fixed literals, no type/content echoed or logged. No new Logger call in the delta.
- **Compatibility as security property.** Already queued to-device messages of now-refused types are still delivered until ack/TTL (7 days) — harmless; legacy `m.room.encrypted` room rows remain readable and archived.

## Accepted Risks
- Finding #1 residual: to-device stays a non-archived, server-opaque channel for 13 allowlisted types; type filter, not content filter; no per-send audit; key-backup blobs and cross-signing signatures opaque — owner-accepted at the epic gate 2026-11-03 (ADR-011 update 2026-11-03, 11-risks).
- Finding #3 (aggregate memory), #4 (erasure deadlock), #5 (/sync device-list scan tier) — 11-risks rows of 2026-11-03.
- Carried: RLS `USING (true)` family pattern, global advisory lock (4760, 60), cross-user `sync_global` acquisition, to-device residuals (1)-(15), key backup cycle-2 MEDIUM #1/#2, device-key-directory residuals (1)-(13).

## Follow-up Stories Required
None blocking. Release precondition (not a story): merge the OAuth branch (000056/000057) before this branch reaches any database; ReleaseTest must be green on the merge result. Advisory: Finding #7 doc sentence + runtime gap refusal in `migrate/0`.

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 2 (#2 mitigated by CI guard + precondition, #3 accepted) | LOW: 3 (#4, #5 accepted; #7 new advisory)

**Epic security gate:** PASS — HIGH #1 closed (code + owner-accepted residual), no CRITICAL/HIGH open
