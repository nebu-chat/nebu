# Epic e2ee-client-support Security Review — 2026-11-03 (SEC Gate 2)

## Scope
- Epic: e2ee-client-support (REQ-2026-013/014)
- Base: 5404d7d01ad4d5907e2667a74b65694d7ea70e29
- HEAD: 6cf8afb4 (branch feature/e2ee-client-support)
- Stories covered: server-side-key-backup (34145ef7), to-device-messaging (d41ec675, 68a582a0), device-key-directory (459186be), key-query-hardening (88622038)
- Excluded: 262e8dc3, 6e7ec21a (skills/** pipeline tooling only)
- Product surface reviewed: server/lib (53 files, +4916/-371), migrations 000058-000061, router (protected.ex), docs/architecture (04, 05, 07, 08, 11, ADR-011), docs/compliance/gdpr-deletion-runbook.md
- Per-story reports: docs/stories/e2ee-client-support/security-reports/ (7 reports, all story gates APPROVED after cycles)

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| 1 | HIGH | cross-story (to-device + device-key-directory + key-backup; ADR-011) | http_to_device.ex:27 (`@type_regex`, any type), to_device_store.ex (no audit hook), protected.ex:1821 (room `send` accepts `m.room.encrypted`), ADR-011 updates | Compliance-control bypass: the epic as a whole delivers a complete in-band, server-opaque E2EE stack (OTK claim + Olm transport + key backup) and a NON-ARCHIVED inter-user content channel, while the ADR-011 enforcement point is still only the `m.room.encryption` state-event denial | OPEN — follow-up story or owner sign-off |
| 2 | MEDIUM | all (migrations 000058-000061) | server/lib/nebu/release.ex:303 `select_pending/2`; branch bugfix/oauth-session-lifetime-and-consent (000056, 000057) | Migration gap: the runner applies only versions > the single recorded version (golang-migrate semantics). Any database that runs this branch before 000056/000057 are merged skips them silently forever (000056 = server_config RLS allowlist, 000057 = oauth_consent_grants) | OPEN — enforce merge order / renumber |
| 3 | MEDIUM | cross-story (resource budget) | room_keys parse/bulk read, to_device_store.ex:491 (delivery `Jason.decode!`), protected.ex:74 (sync tier per IP) | Aggregate per-account node memory has no node-wide admission: the individually accepted transient budgets add up (estimate one account ~400 MiB on the epic's own endpoints plus ~10-20 MB per concurrent sync carrying to-device content, sync concurrency bounded only by the per-IP sync tier); 2-3 colluding accounts reach the 2 GiB node limit | Accepted pieces (key-backup cycle2 #1, to-device #7/(9)); advisory |
| 4 | LOW | to-device + key-query-hardening (UserDeletion) | user_deletion.ex:308-325 (`delete_per_user_rows`, `run_delete_sent`, `run_delete_signed_on`) | Two concurrent erasures of users who messaged / signed each other deadlock (40P01): erasure A locks rows (B->A) via `user_id = A` then wants (A->B) via `sender = A`; erasure B the reverse (same for `cross_signing_user_signatures` user_id / target_user_id) | Advisory (fails closed, audited, retried) |
| 5 | LOW | device-key-directory | protected.ex:104-236 (`device_list_pre`), device_list_store.ex `changes/3`, `position/0` | `/sync` reaches the device-list stream scan with a client-chosen `.d<n>` (or none -> conservative answer + global lock 4760/60) under the sync tier (600/min, burst 100, per IP), bypassing the per-user `keys_changes` tier that closed device-key-directory LOW #3 | Advisory (bounded by table size; residuals (4)/(12)/(13)) |
| 6 | LOW | key-query-hardening (D11) | raw_body_reader.ex:122-128 `key_material_shape?/1` | `POST /keys/device_signing/upload` (cross-signing keys, signatures, UIA `auth`) is not in the key-material body exclusion, unlike `keys/upload|query|claim|signatures/upload`; debug capture is redacted, material is public | Advisory |

## Detail

**Finding #1 — The epic completes a server-opaque channel that ADR-011 does not cover** [HIGH]

Story by story every part was scoped correctly ("enables no E2EE room"), and `m.room.encryption` is still rejected (the diff touches none of the guards: protected.ex:3339, `@initial_state_forbidden_types`, `copy_state_events`). Only the epic as a whole shows the gap:

- `PUT /sendToDevice/{type}/{txn}` accepts ANY event type matching `^[a-zA-Z0-9._-]{1,255}$` with up to 64 KiB of opaque content to every joined co-member (with auto-join rooms: every user). The content is never logged (by design), never written to `events`, never audited (no `Nebu.Compliance` call in to_device_store / http_to_device), deleted once acknowledged, after 7 days, and on erasure. With plain curl, two users can talk in plaintext (`{"type":"com.x.chat","content":{"body":"..."}}`) outside the compliance archive. This is the first inter-user content path that is not retained (room events and media are retained).
- `POST /keys/claim` (OTKs) + to-device give a full in-band Olm session setup; `PUT /rooms/{id}/send/m.room.encrypted/{txn}` is NOT rejected (protected.ex:1821, no type check). A modified client or a bot (matrix-nio, rust-sdk with encryption forced) can send Megolm ciphertext into an "unencrypted" room and share the session keys over Olm; js-sdk-based clients decrypt `m.room.encrypted` timeline events regardless of the room state. Compliance search and export then see ciphertext only. Before this epic the same required an out-of-band key exchange; now it is in-band and standard tooling.
- `room_keys` stores the resulting Megolm keys server-side, encrypted to a client key the server never has (no escrow), so ADR-011 option 1 (escrow) does not apply either.

Exploitable with standard user credentials; impact: loss of the product's core compliance guarantee (managed decryption / complete archive), not a data breach to a third party. The to-device story review rated the transport INFO ("irrelevant while ADR-011 blocks E2EE rooms"); at epic level that premise does not hold, because ADR-011 blocks only the room flag, not encryption.

Remediation (any of a, b+c, or d):
- (a) closable now: reject `m.room.encrypted` on the room `send` path (403 M_FORBIDDEN), the fifth E2EE write path next to state PUT, initial_state, upgrade copy and `send_event` of `m.room.encryption`; test it.
- (b) restrict to-device event types to an allowlist of what the supported client flows need (`m.key.verification.*`, `m.secret.request`, `m.room_key_request`, `m.dummy`, `m.room.encrypted` for Olm-wrapped `m.secret.send`), 400 for anything else.
- (c) write a metadata-only audit row per send (sender, sender device, recipient user, event type, bytes, timestamp; never content) so the channel is at least visible to compliance.
- (d) or a formal accepted risk in ADR-011 and 11-risks, signed off by the owner, stating that to-device is a non-archived, server-opaque inter-user channel and that `m.room.encrypted` room events are accepted.

**Finding #2 — Migration gap 000056/000057** [MEDIUM]

`Nebu.Release.select_pending/2` keeps only `version > current`, and `schema_migrations` stores one row (the latest). This branch jumps 000055 -> 000058. Every database migrated from this branch first (dev, CI, staging, a preview deploy) records 61 and will never apply 000056 (`config_update_mutable` RLS policy plus `matrix_session_ttl_seconds`) or 000057 (`oauth_consent_grants`) once the OAuth branch lands. Both fail closed (RLS error on save, missing table -> 500), so no bypass, but silently and permanently. Remediation: merge the OAuth branch first (the integration-branch plan already says so), or renumber at integration; add a build or test check that the migration directory is contiguous 1..max, and make `migrate/0` refuse to run when the directory contains a version below `current` that it cannot prove was applied (or switch to recording every applied version). Reset every database that already ran 000058-000061 before the gap is filled.

**Finding #3 — No node-wide memory admission across the epic's heavy paths** [MEDIUM]

Each story bounded its own path, but nothing bounds their sum per node. One account at the same time: room_keys writes (burst 5 x 5 MiB parse ~ 125-200 MiB, cycle-2 MEDIUM #1 accepted), one bulk read (64 MiB budget, ~2-3x in memory), 4 to-device sends (64 KiB each, small), claim/query/signatures responses (low MB), plus every concurrent `/sync` that carries to-device content (up to 1 MiB stored JSON decoded with `Jason.decode!` and re-encoded, ~10-20 MB per request in the worst shape, concurrency limited only by the per-IP sync tier, burst 100). ETS stays bounded: claim per-target rows ~36k per account per node per hour (~10 MB), everything else is keyed by `{tier, user}`, `{"to_device_bytes", user}` or a SHA-256 digest; no request-derived sub-binary was found in any ETS key or gate state (the previous HIGH pattern does not recur). Remediation: the already listed follow-ups (Jason.Fragment for the to-device delivery, a node-wide parse gate for room_keys bodies), plus a per-user concurrency cap on syncs that carry to-device content, and one aggregate line in 07-deployment (per-account transient memory and per-account DB footprint: 64 MiB key backup + 16 MiB to-device sender total + in-flight + 32 MiB as recipient).

**Finding #4 — Concurrent erasures deadlock** [LOW]

The erasure deletes both directions of the two bidirectional tables in separate statements in a fixed per-user order (`user_id = A` first, `sender = A` / `target_user_id = A` later). Two erasures of users who exchanged to-device messages or signed each other's master key take the row locks in opposite order; PostgreSQL aborts one with 40P01. It fails closed (rolled back, audited) and a retry succeeds. Remediation: serialise erasures with one global advisory lock (erasures are rare), or retry 40P01 once automatically.

**Finding #5 — /sync side door to the device-list scan** [LOW]

`GET /keys/changes` got a per-user tier (60/min) to close the full-range scan; `/sync` runs the same `changes/3` with the client-chosen `.d<n>` and, for an old token or an initial sync, `position/0` (global advisory lock 4760/60, blocking) plus `shared_users/1`, at the sync tier (per IP). Bounded by the table size (users x memberships) and consistent with the accepted residuals; advisory: key the sync tier per user, or clamp a `.d` far below the client's last issued position.

**Finding #6 — device_signing/upload outside the key-material body exclusion** [LOW]

D11 states that the request logger captures no body of key routes; `keys/device_signing/upload` (master / self-signing / user-signing keys, signatures, UIA `auth`) still gets the redacted debug capture. Public material, debug level only; add it to `key_material_shape?/1` for consistency.

## Cross-Story Patterns

- **Lock order (one global order, no new cycle found).** Rows (`uia_sessions`, `cross_signing_keys` FOR UPDATE) -> `sync_global|<user>` (cross-user signatures take signer + target SORTED) -> `to_device_erasure|<user>` (erasure exclusive; sends take it shared as a TRY-lock) -> row writes (`device_keys` -> `devices` -> stream row `(user,'')`) -> at commit the deferred stamp under the global `(4760, 60)` lock. Every holder of `(4760, 60)` touches only rows it already holds (its own pending `device_list_changes` rows; `cross_signing_keys.changed_pos = -1` is never visible committed), so the commit lock cannot close a cycle. room_keys writers use `pg_try_advisory_xact_lock` (no waiter), to-device eviction / ack / stamp and the claim use `SKIP LOCKED`, the to-device phase-1 `FOR KEY SHARE` window is two indexed lookups + INSERT. Checked combinations: erasure vs key upload, vs sendToDevice (both directions), vs claim, vs signature upload (own and cross-user, both sort orders), vs key backup write: no cycle. Known residuals stay: the absent-then-present cross-signing window (40P01, pre-existing, documented) and Finding #4.
- **Shared sequences / sync token groups.** `sync_global_pos_seq` now feeds both the room stream and the `.d` device-list group (drawn at commit under the global lock; gap-tolerant prefix); the to-device group is an independent `delivery_seq` acknowledged with SKIP LOCKED. A forged `.d` or to-device position only changes the caller's own view (over-report or redelivery of its own queue); no position grants access to another user's rows.
- **Visibility predicate is consistent.** keys/query, keys/claim, signatures upload (c), sendToDevice and device_lists/changes all use the same "both sides `left_at IS NULL`" join on `room_members` (which holds joined members only; invites are not rows). room_keys is self-only. Unknown, unshared, deactivated and erased targets are handled identically per endpoint (silently absent / skipped / identical `:forbidden`); no new existence oracle beyond the documented timing residuals.
- **ADR-011.** `m.room.encryption` guards unchanged and intact on all four write paths; see Finding #1 for what they do not cover.
- **Logging.** All new Logger calls log a static text plus the error KIND (struct module or atom); counts only in the purge/eviction info lines. Bodies of room_keys, sendToDevice, keys/upload|query|claim|signatures/upload are excluded from capture; `/keys/changes` query logs names only; RouteNormalizer anchors sessionId/txnId/eventType. No key material, signature, token or message content found in any log path (Finding #6 is the one gap, debug + redacted).
- **GDPR erasure.** All six new tables are in `@erased_tables` (room_key_backup_sessions/versions, to_device_messages, to_device_txns, device_list_changes, cross_signing_user_signatures) plus the second keys (`to_device_messages.sender`, `cross_signing_user_signatures.target_user_id`); the new `device_fallback_keys.key_id` column lives in an erased table; the runbook has the matching verify and sweep SQL. Residual (documented): later `room_members` changes re-create `device_list_changes` rows for the erased id (periodic sweep).
- **Migrations / RLS / grants.** 000058-000061: every new table has explicit runtime-role grants, RLS ENABLE + FORCE with per-command `USING (true)` policies (accepted family pattern), sequences granted, no SECURITY DEFINER (stamp/member triggers run as invoker), additive only (one nullable column, one trigger on room_members), down migrations present. Contiguity: Finding #2.

## Accepted Risks
(carried, already documented in 11-risks / story reports; none of them is CRITICAL/HIGH)
- RLS `USING (true)` on all new tables (isolation by app predicates).
- Global advisory lock (4760, 60) at commit for key/membership writes (device-key-directory LOW #4).
- Cross-user acquisition of the target's `sync_global|` lock by signature uploads (key-query-hardening L3, 11-risks (6)).
- to-device residuals (1)-(15), key backup cycle-2 MEDIUM #1/#2, device-key-directory residuals (1)-(13).
- Finding #1 can be moved here only with written owner sign-off (option d).

## Follow-up Stories Required
1. **e2ee-compliance-channel-guard** (Finding #1, HIGH): reject `m.room.encrypted` on the room send path; allowlist to-device event types and/or audit to-device metadata; update ADR-011. Alternatively: owner sign-off on option (d).
2. Before merge: enforce the migration order (OAuth branch with 000056/000057 first or renumber), contiguity check (Finding #2).

## Summary
CRITICAL: 0 | HIGH: 1 | MEDIUM: 2 | LOW: 3

**Epic security gate:** BLOCKED — requires follow-up story (Finding #1) or a formal owner-signed accepted risk
