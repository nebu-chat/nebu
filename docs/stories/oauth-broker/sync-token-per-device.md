---
story_id: sync-token-per-device
title: "The /sync since token is stored per device and the global account data / own cross-signing change are delivered per device (with a wake-up on a global account data PUT): GET /sync passes the authenticated device id, so two clients of the same user no longer overwrite each other's token, fall back to a full initial sync, or consume each other's changes (closes fd)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
traceability_id: REQ-2026-002
created: 2026-10-26
branch: feature/migrate-to-oauth2
---

# Story: the `/sync` since token is per device (follow-up `fd`)

## Story

**As** a user with two or more Matrix clients (devices) at the same time, for example Element Web and Element on a phone, **I want**
each client's `/sync` to continue incrementally from its own `next_batch` and to receive every change of my global account data and
of my own cross-signing keys promptly, **so that** no client gets a full initial sync on every request (no long-poll, full payload, no
`rooms.leave`: a room I left stays listed on the other client) and no client misses, or waits 25 s for, a secret-storage /
cross-signing / push-rules change that another of my clients (or its own write) made.

Scope: (1) the storage key of the since token (the user id plus the device id of the authentication instead of the user id plus `''`);
(2) the two per-user consume-once delivery points on the same route (global `account_data` and the own user in `device_lists.changed`),
which would otherwise turn today's hidden fallbacks into a correctness regression (D9); (3) the own user in `device_lists.changed` of a
fallback response (D10); (4) a wake-up and a pending check for global account data (D11). The anchor model (one event id, timestamp
comparison) stays as it is: follow-up `fc` is a LATER story and is not solved here.

## Premise check (2026-10-26, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `03e33d7a`, read-only)

**How the since token works (stored / looked up / validated).**

- The core token is `new_since_token/2` (`event_dispatcher/server.ex` ~5389): `Base.encode64("<user_id>:<last_event_id>:<monotonic>")`.
  It is NOT opaque in the cryptographic sense (base64, readable, unsigned), but the server NEVER decodes it: it is a validation
  nonce. The anchor (`last_event_id`) that the delivery uses comes from the `sync_tokens` row, not from the token.
- `sync_delta/2` (~5886): looks up the row (`get_since_token(user_id, device_id)` if `device_id != ""`, else `get_since_token(user_id)`
  = the row with `device_id = ''`), then compares the client's token with the stored one (`client_since_token != stored_token` ->
  `fallback_to_initial_sync/2`); no row -> fallback; an anchor event that no longer exists -> fallback. Only an exact match runs the
  incremental build with the row's `last_event_id`. After the build the NEW token and anchor are upserted into the same key (~6021).
- Spec frame (Oracle gate, CS v1.18): `GET /sync` documents only `200`; for an unknown, stale or foreign `since` the spec defines no
  behaviour (v1.18 has no `M_UNKNOWN_POS` for `/sync` v3). Nebu's choice, kept by this story: never an error, a `200` with an
  initial-shaped response (an empty `since` counts as absent). `/sync` is "Rate-limited: No" in the spec; Nebu's `600/min` per IP is a
  Nebu choice.
- The HTTP route `do_sync/1` (`web/router/protected.ex` ~85-150) passes `device_id: ""` to `get_sync_delta/2` (l.131) and calls
  `get_initial_sync/2` with only `user_id` when there is no `since` (l.140). `Core.GetInitialSyncRequest` has no `device_id` field
  (`lib/pb/core.pb.ex`, `proto/core.proto` l.439); `Core.GetSyncDeltaRequest` has one (field 4, Story 9-22).
- `initial_sync/2` (~5211) ALWAYS persists through `persist_since_token/3` (key `''`).
- **What is lost when two devices alternate:** device A syncs -> row `(u, '')` = token A2; device B presents B1 -> mismatch -> full
  initial sync (fallback), row = B2; device A presents A2 -> mismatch -> full initial sync, and so on. Every request of every device
  of a multi-device user is a full initial sync: no long-poll (the request returns at once, so clients loop at full speed against
  Nebu's `/sync` limit of 600/min per IP), the full payload (every joined room's state + 20 events), and no `rooms.leave` (the fallback
  is an initial sync, `leave_rooms: []`): a room the user left / was kicked from / banned from stays listed on the other client. No
  event is "lost" beyond that: the snapshot delivers the newest 20 events per room, older ones in a gap are reachable through
  `/messages` (`limited` / `prev_batch` per room in the snapshot).
- **Latent bug in the per-device path (unused today):** `fallback_to_initial_sync/2` (~5957), when `device_id != ""`, persists the
  device row with `last_event_id = nil` (and `get_initial_sync` has already written the `''` row with the real anchor). A device row
  with a nil anchor is read by `resolve_since_ts(nil)` as `{:ok, 0}`: the next incremental sync of that device would re-deliver the
  last events of every joined room and treat every pending invitation as new (`invite_new?(entry, 0)`). Must be fixed together.

**Which credentials carry a device id** (`web/plugs/oidc_plug.ex`):

- Opaque Nebu tokens (`matrix_sessions`, legacy AND OAuth, `auth_api` "legacy" / "oauth"): `assign(:device_id, sess.device_id)` (l.126);
  always set.
- Raw IdP JWTs: `assign(:device_id, device_id)` from the server-side `DeviceBinding.lookup/1` (l.155-169). CORRECTION to the `fd` text
  ("raw IdP JWTs have none"): a JWT bound at login (S2 binding) HAS a device id; only an unbound JWT (minted before the binding existed,
  binding DB unavailable, or bound lazily later at `/keys/upload` via `maybe_bind_jwt_device/3`) has `nil`.
- The device id comes ONLY from the server-side session / binding, never from request input (same rule as `/keys/upload`, G1).
- Authentication runs BEFORE the route: a token of a deleted device is rejected by `OidcPlug` (`401 M_UNKNOWN_TOKEN`) and never reaches
  the `sync_tokens` lookup or upsert.

**Table, key, RLS, migration.** `sync_tokens` (`priv/migrations/000001_init.up.sql` l.246): `user_id TEXT NOT NULL REFERENCES users`,
`since_token`, `last_event_id`, `updated_at`, `device_id TEXT NOT NULL DEFAULT ''`, `PRIMARY KEY (user_id, device_id)`. No RLS on the
table. Both upserts (`/3` with `''`, `/4` with a device id) use `ON CONFLICT (user_id, device_id)`. The token key itself needs no
migration; D9 needs one (the last migration is `000051_events_redacts`, so `000052`).

**Retention / cleanup of `sync_tokens` rows** (all existing, verified):

- device delete (Matrix `DELETE /devices`, `/delete_devices`, Admin UI) -> `Nebu.Matrix.end_device_session/2` ->
  `OAuthSession.end_device_session/2` -> `after_commit/2` -> `SessionSupervisor.destroy_session(user, device)` ->
  `PgStore.invalidate_session/2` (`DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = $2`);
- legacy `POST /logout` -> `legacy_logout_device/1` -> `end_legacy_device/1` -> the same `after_commit/2`;
- OAuth token revocation / logout -> the same teardown;
- `POST /logout/all`, admin deactivation (`invalidate_user_sessions` with `device_id: ""`), GDPR erasure (`end_sessions_after_erasure/1`)
  -> `destroy_session/1` -> `DELETE FROM sync_tokens WHERE user_id = $1` (ALL rows of the user, the `''` row and every device row).
- Gap (new with this story, small, ACCEPTED by the owner 2026-10-26): a device that is deleted WHILE one of its `/sync` requests is in
  flight can get its row re-created by that request's final upsert (an orphan row, no content); follow-up `cj` (a).
- A device that never syncs again keeps its row until the device is deleted (bounded, see next point). No time-based expiry exists.

**Per-user cap.** Rows per user <= number of the user's devices that have synced + 1 (`''`), because the key comes only from the
server-side binding. There is no device cap per user in the code (only `@max_devices_rendered 500` in the account page); device
creation is bounded by the login / OAuth rate limits. No extra cap on `sync_tokens` is needed.

**Security premises (verified).**

- Token bound to the user: yes, implicitly. The lookup key is the AUTHENTICATED user (`conn.assigns[:current_user]`); the client token
  is only compared for equality with that user's stored row. A token of another user (or of another device of the same user, after
  this story) never matches -> initial sync of the CALLER. The user id inside the base64 is never read.
- "The delivery re-reads by the caller's partition": confirmed. `do_incremental_sync/6` builds from `sync_partition(user_id)` with the
  authenticated user id (~5991, and every rebuild through `consistent_delivery/3`); the row's `last_event_id` only bounds the time window
  (`since_ts`). The visibility filters (history visibility, partition, leave bound) apply to the caller. Even a foreign anchor could only
  shift the window of the caller's OWN visible events. No new disclosure.
- The comparison is not constant-time; acceptable because the since token is not a credential (it grants nothing beyond the caller's
  own delivery).

**Interaction with sync-wakeups-cluster-wide (D5) and the per-task wait.** Each `/sync` request runs its own sync Task that joins
`user:<id>` and its rooms' `room:<id>` groups; a wake-up reaches every Task of the user, each rebuilds from its OWN anchor. D5 keeps the
previous anchor (`last_event_id`) for an unresolvable room: it is written to the requesting key, so after this story it is per device
(device A's unresolved room does not pin device B's anchor). The wait loop (`wait_for_wakeup`, ~6125) already wakes on
`{:account_data_changed, _}` (sent today only by `RoomAccountDataStore.notify_sync/2`, cluster-wide `:pg.get_members/1`); D11 reuses it.
Consequence to note: today a multi-device user never long-polls (every request is a fallback); after this story every device holds a
long-poll Task (one per device, as for single-device users).

**Interaction with `fc`.** Unchanged anchor model. Today the permanent fallbacks of multi-device users mask `fc` losses (every request is
a full snapshot); after this story those users sync incrementally and are exposed to `fc` like single-device users. Not a regression of
`fc`, but `fc` becomes more visible.

**The per-user consume-once delivery points on the same route (in scope, D9).**

- Global account data: table `account_data` (`000015_account_data.up.sql`): `PRIMARY KEY (user_id, type)`, `content_json TEXT` (opaque,
  up to 1 MB per entry: `@global_account_data_max_bytes`, `protected.ex` l.932), `changed BOOLEAN` set TRUE by the only writer
  `AccountDataStore.put/3` (an upsert, no transaction, no lock, NO wake-up). `/sync` (`put_global_account_data/3`, `protected.ex` l.248):
  with a `since` (ANY `since`, also when the core fell back to an initial sync) `list_changed_and_clear/1` (`UPDATE ... SET changed =
  FALSE WHERE user_id = $1 AND changed = TRUE RETURNING`), without `since` `list_all_and_clear/1`. No row-count cap per user. No RLS, no
  grant in the migration. The pending pre-check that zeroes `timeout_ms` (`protected.ex` ~105) exists only for ROOM account data
  (`RoomAccountDataStore.pending?/2`).
- Own cross-signing change: table `cross_signing_keys` (`000014_cross_signing_keys.up.sql`): one row per user, `cross_signing_changed
  BOOLEAN` set TRUE only by `CrossSigningKeyStore.put_keys/2` (l.38-63; the signature merge l.226-245 does not set it). `/sync`
  (`put_cross_signing_device_lists/3`, l.267): only with a `since`, `consume_changed_flag/1` (`UPDATE ... RETURNING`) adds the own user
  to `device_lists.changed`. No RLS.
- Effect today: the first incremental sync of ANY client of the user consumes the flag; a second client never sees the change until its
  next initial sync. Hidden today because the second client always falls back; with the per-device token alone it would be a
  REGRESSION (Element's secret storage / cross-signing / push rules data missed on the second device).
- The pattern that already solves this for ROOM account data: `user_room_account_data.stream_pos` from a sequence, writers serialised
  per user with `pg_advisory_xact_lock(hashtextextended(user_id, 0))` (`room_account_data_store.ex` l.157) so that for one user the
  position order is the commit order, and the reader compares with a position (there carried in the token suffix `<core>.<pos>`).
- GDPR erasure of these two tables (verified, pre-existing, NOT in this story): `Nebu.Compliance.UserDeletion.delete_user_keys/3` deletes
  only `user_room_account_data` (its own comment at ~l.201 names the global `account_data` gap); no code deletes `account_data` or
  `cross_signing_keys` rows; the `users` row is never deleted (status `keys_deleted`) and neither table has a foreign key, so no cascade
  covers them. Recorded as follow-up `ck` (compliance severity HIGH, owner decision before `oauth_enabled` / release).
- Further pre-existing spec deviations found by the Oracle gate, NOT in this story: `device_unused_fallback_key_types` is per user
  (follow-up `cl`); `device_lists` only ever lists the own user and never fills `left` (follow-up `cm`).

**Pinned docs.** `sync_membership_partition_docs_test.exs` l.121 pins row `fd` (`per user`, `device`, `` `sync_tokens` ``, `fall`) and
l.233 asserts that `docs/architecture/07-deployment.md` contains `` `fd` `` (release note residual "`fd` multi-device fallbacks").
`docs/matrix-api-scope.md` (l.56) names `fd` twice as a residual and describes the global account data as "consume-once `changed` flag".
Eight docs suites pin `unused:[^.]*`gm` onward` on the follow-up id line: the new rows use the formerly unused ids `cj`-`cm` (recorded on
the id line, no re-pinning).

### Sizing

**Medium-large** (was small before D9-D11). One migration, four stores, the route, one proto field, one wake-up; no new table, no new
config, no API shape change.

- `server/priv/migrations/000052_sync_device_positions.{up,down}.sql` (number confirmed by the implementer at commit time): one sequence
  `sync_global_pos_seq`; `account_data.stream_pos BIGINT NOT NULL DEFAULT nextval(...)` (existing rows are stamped by the volatile
  default); `cross_signing_keys.changed_pos BIGINT NOT NULL DEFAULT 0`; `sync_tokens.account_data_pos BIGINT NOT NULL DEFAULT 0` and
  `sync_tokens.cross_signing_pos BIGINT NOT NULL DEFAULT 0`; index `account_data (user_id, stream_pos)`; grants as in 000039 if the
  deployment role needs them. Down: drop the index, the four columns, the sequence.
- `server/lib/nebu/matrix/account_data_store.ex`: `put/3` in a transaction with the per-user advisory lock (D9 key); the upsert sets
  `stream_pos = nextval('sync_global_pos_seq')` in BOTH the `INSERT` values AND the `ON CONFLICT DO UPDATE SET` branch (otherwise an
  overwrite keeps its old position and is never delivered); after the commit `notify_sync/1` (D11). New readers `list_since(user_id, pos)`
  -> `{latest_pos, entries}` (rows with `stream_pos > pos`; `pos = 0` = all) and `pending_since?(user_id, pos)` (`SELECT 1 ... LIMIT 1`);
  neither touches `changed`. The two flag readers stay for device-less requests.
- `server/lib/nebu/matrix/cross_signing_key_store.ex`: `put_keys/2` in a transaction with the same lock, stamps `changed_pos =
  nextval(...)` next to `cross_signing_changed = TRUE` (insert and update branch); new reader `changed_since?(user_id, pos)` ->
  `{changed_pos, boolean}`.
- `server/lib/nebu/matrix/session/pg_store.ex` (+ `postgres.ex`): `get_positions(user, device)` -> `{account_data_pos, cross_signing_pos}`
  and `advance_positions(user, device, token, ad_pos, cs_pos)` (`UPDATE sync_tokens SET account_data_pos = GREATEST(account_data_pos, $4),
  cross_signing_pos = GREATEST(cross_signing_pos, $5) WHERE user_id = $1 AND device_id = $2 AND since_token = $3`).
- `server/lib/nebu/web/router/protected.ex`: `do_sync/1` passes the device id (D1); for a device-bound request it reads the positions
  once before the core call, zeroes `timeout_ms` when `pending_since?` (D11), and `put_global_account_data/3` /
  `put_cross_signing_device_lists/3` branch: device-bound -> positions (D9), device-less -> today's flags; a fallback response to a request
  with a `since` lists the own user (D10).
- Contract fixed by the ATDD tests (do not rename): `AccountDataStore.list_since(user, pos) -> {latest_pos, [{type, content_map}]}`
  (oldest first, `{0, []}` without rows and on a failed read `{pos, []}`), `pending_since?/2`; `CrossSigningKeyStore.changed_since?(user,
  pos) -> {changed_pos, boolean}` (`{0, false}` without a row); `PgStore.get_positions(user, device) -> {ad, cs}` (`{0, 0}` without a
  row), `PgStore.advance_positions(user, device, token, ad, cs) -> :ok` where `token` is the CORE token (`sync.since_token`, without the
  `.<pos>` suffix, as stored in `sync_tokens.since_token`); wake message `{:account_data_changed, nil}`; the migration file is found by
  the name `*_sync_device_positions` (number >= 52); `nebu_app` needs `USAGE, SELECT` on the sequence. The two new `PgStore` callbacks
  are `@optional_callbacks` and the facade guards with `function_exported?` (the `@behaviour` fakes in `session_supervisor_test.exs` /
  `pg_store_test.exs` would otherwise warn under `--warnings-as-errors`).
- Existing tests re-pinned by the ATDD step (measurements of this design: +3 statements per `/sync`, D11 wait): `member_prev_content_http_test`
  initial sync 54 -> 57, `history_visibility_http_test` initial 45 -> 48 / incremental 48 -> 51, `sync_membership_partition_http_test`
  AC10 ignored-users wait `>= 150` -> `< 150` and the L-2 anchor test reads the user's only row. If the implementation needs another
  statement count, re-pin with a comment.
- `server/lib/pb/core.pb.ex` + `proto/core.proto` (parity doc): `GetInitialSyncRequest` gains `device_id: ""` (field 2).
- `server/lib/nebu/matrix/event_dispatcher/server.ex`: `initial_sync/2` persists under the request's key with the real anchor;
  `fallback_to_initial_sync/2` passes the device id and drops its own nil-anchor persist (D4); flow comments updated.
- Docs: row `fd` closed (D7); rows `cj`-`cm` exist (written with this story's definition, 2026-10-26); the `fd` residual sentences in
  `docs/architecture/07-deployment.md`, the account data / `fd` sentences in `docs/matrix-api-scope.md`, `06-runtime.md` if it describes
  the consume-once flag or the wake-ups.
- Tests: see "Test list (Oracle gate)" below.

## Decisions

- **D1 Key = (authenticated user, authenticated device).** The route passes `conn.assigns[:device_id]` (opaque sessions, bound JWTs;
  a non-binary or nil value is `""`); never a request parameter. All lookups and upserts of one request use the same key: incremental
  build, fallback, initial sync, the D9 positions.
- **D2 Request without a device id keeps the per-user `''` key and today's per-user behaviour (documented).** An unbound raw IdP JWT (or
  a binding lookup that returned `nil`) uses the `''` row and the consume-once flags exactly as today (several device-less clients of one
  user still overwrite each other and share the flags: accepted, they cannot be told apart; follow-up `cj` (c)). Device-bound requests
  NEVER read or write the `''` row and NEVER clear a flag, so a device-less client is not disturbed by device-bound ones. A JWT that
  becomes bound later (lazy binding at `/keys/upload`) switches to its device row and pays one initial-sync fallback. Spec note (Oracle):
  a credential without a device is a Nebu extension (Matrix access tokens belong to a device); it is tolerated, not endorsed by the spec.
  Only D10 (the own user on a fallback) and D11 (the wake-up) also apply to device-less requests: both are additive.
- **D3 Compat: a token stored under `''` before the change is NOT migrated; the first sync of a device-bound client falls back to an
  initial sync once (ACCEPTED by the owner 2026-10-26).** Justification: the fallback is the existing, tested recovery path that every
  multi-device user hits on every request today, so one more per device at rollout costs nothing new; reading the `''` row as a second
  lookup would have to stay in the hot path forever (tokens can be arbitrarily old) or be removed in a later release, and it would match
  only the device that wrote last. After the fallback the device has its own row and syncs incrementally (the fallback also sets its D9
  positions: it receives all global account data once). The release note says: "after the update each client does one full sync". Same
  residual as every fallback: that one response carries no `rooms.leave` (D10 adds the own user to `device_lists.changed`).
- **D4 The initial sync and the fallback persist the real anchor under the device key.** `initial_sync/2` takes the device id from
  the request and persists `(user, device, token, last_event_id)`; `fallback_to_initial_sync/2` no longer writes a second row with
  `last_event_id = nil` (that would re-deliver from timestamp 0). Exactly one token upsert per request.
- **D5 Retention unchanged, rows bounded by devices.** No cap, no expiry job: rows are deleted by the existing device teardown
  (`after_commit/2` -> `destroy_session/2`) and by every user-wide delete (logout/all, deactivation, GDPR erasure -> `destroy_session/1`).
  The D9 positions are columns of the same row, so they go with it. The in-flight-sync-vs-device-delete orphan row is ACCEPTED by the
  owner (no device-exists check on the write), follow-up `cj` (a).
- **D6 Out of scope, recorded as follow-up rows (written 2026-10-26, ids `cj`-`cm`, formerly unused, recorded on the id line):**
  `cj` (a) the orphan-row race of D5; `cj` (b) exactly one valid since token per device: a retry of the same `since` after a lost
  response (or a client restored from a cached token, or two concurrent requests of one device) falls back to an initial-shaped response
  without `rooms.leave`; spec impact: CS v1.18 defines no behaviour for an unknown / stale `since`, so the `200` initial-shaped response
  is conformant, but the client cannot know it was a fallback and keeps rooms it left listed; mitigation to be done with `fc`: keep the
  device's previous token / anchor valid for one generation; `cj` (c) device-less clients share the per-user token and flags (D2).
  `ck` the GDPR erasure gap of `account_data` / `cross_signing_keys` (compliance HIGH, owner decision before activation / release, NOT
  gating this story). `cl` `device_unused_fallback_key_types` per user instead of per device (Oracle F6). `cm` `device_lists` only ever
  lists the own user, `left` never filled (Oracle (g)).
- **D7 `fd` closure keeps the pinned strings.** The row becomes "**CLOSED by story sync-token-per-device (YYYY-MM-DD): ...**" followed by
  the original text (tokens `per user`, `device`, `` `sync_tokens` ``, `fall` stay); status column `closed`; the closure names the
  device-less exception (D2), the one-time rollout fallback (D3), the per-device delivery of global account data and the own
  cross-signing change (D9), the own user on a fallback (D10), the wake-up (D11) and the follow-ups `cj`-`cm`. `07-deployment.md` keeps
  `` `fd` `` (the residual becomes "`fd` closed by story sync-token-per-device: per device; device-less clients keep the per-user token,
  `cj`") and `matrix-api-scope.md` drops the "per user" residual and the "consume-once" description for device-bound clients.
- **D8 Security review required.** Token binding (user + device key), cross-user / cross-device use of a token, data retention of
  `sync_tokens` rows (device delete, erasure), and the delivery of client-encrypted secret-storage / cross-signing account data are
  touched. Expected outcome: no new disclosure (the delivery is built from the caller's partition and the caller's own account data
  rows, the token and the positions only select the caller's own row). The erasure gap `ck` is pre-existing and named for the review.
- **D9 Global account data and the own cross-signing change are delivered by two per-device POSITIONS stored in the device's
  `sync_tokens` row (option (a) of the owner's list; two columns per owner decision F3, 2026-10-26).**
  **Design.** (1) One sequence `sync_global_pos_seq`; every write that today sets a flag also stamps a position from it:
  `account_data.stream_pos` (every insert AND every update of a row: `nextval` in both branches of the upsert) and
  `cross_signing_keys.changed_pos` (only `put_keys/2`, exactly where `cross_signing_changed = TRUE` is set). (2) Both writers run in a
  transaction that first takes `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))` (one per-user key for BOTH tables,
  namespaced so it never serialises against room account data): for one user the position order of each table is its commit order, so a
  reader never sees position N+1 of a table while N of that table is still uncommitted (the reason the room account data store locks;
  without it a reader could pass a pending lower position and that change would be lost for good). (3) TWO columns on the device's row:
  `sync_tokens.account_data_pos` (the highest `account_data.stream_pos` this device has been sent) and `sync_tokens.cross_signing_pos`
  (the highest `changed_pos` it has been sent). Each column is advanced ONLY to the maximum position read from ITS OWN source in this
  request. One shared column would be wrong (Oracle F3): the two sources are read at different moments, so a cross-signing position read
  later could lift the shared marker past an `account_data` position that committed between the two reads, and that row would be
  skipped. (4) A device-bound `/sync` reads both positions of its row once, BEFORE the core call (the core's token upsert does not touch
  these columns); it sends the `account_data` rows with `stream_pos > account_data_pos` (all rows when the response is initial-shaped: no
  `since`, or `fallback_to_initial: true`) and the own user in `device_lists.changed` if `changed_pos > cross_signing_pos` (on a true
  incremental response; on a fallback see D10); then it advances both columns with `GREATEST` and `WHERE ... AND since_token = <the token
  of this response>`: if a concurrent request of the same device already replaced the token, the response's token is invalid anyway (the
  client falls back and gets everything again), so the positions are never advanced for a token the client can no longer use. (5) Flags
  stay and are still SET by the writers; only device-less requests clear them (D2). (6) `full_state=true` only widens the ROOM state
  (story sync-membership-partition D14); global account data and the cross-signing entry stay incremental by position.
  **Failure direction is always "deliver again", never "miss":** a failed position read is treated as 0 (all global account data once,
  bounded by the user's rows; the cross-signing entry is only a user id; code review cycle 0 m1: in an initial-shaped answer a FAILED
  read rewinds the device's `account_data_pos` to 0 (`AccountDataStore.list_since_checked/2` returns `:error`,
  `PgStore.rewind_account_data_position/4`, a plain SET guarded by the response's token, never an insert) so a client that reset its
  state gets every row with the next sync; in a true delta a failed read advances nothing), a failed advance re-delivers the same entries next time
  (account data is state: a repeat is harmless; a repeated own user id in `device_lists.changed` is spec-conformant, spurious entries are
  allowed). Both reads stay never-raising like today's store readers.
  **Own writes echo to the writing device:** a PUT through device A is delivered to device A's next sync too (Element waits for this echo,
  e.g. `setDefaultKeyId`), and the own user appears in `device_lists.changed` of every device of the user, the uploader included
  (spec-conformant, Oracle).
  **Requirements check.** No change missed by a second device (positions are per device and per source, nothing is consumed); no growth
  per user (columns on existing one-per-user / one-per-type rows, two columns on the per-device row, deleted with the device / session /
  erasure as in D5); cluster-safe (PostgreSQL only, the advisory lock is cluster-wide); device-less unchanged (D2); bounded SQL (index
  `(user_id, stream_pos)`, the reader returns at most the user's account data types, the same bound as today's initial sync; the
  cross-signing read is one row by primary key); migration `000052`.
  **Rejected.** (b) keying the flag rows by device: `account_data` flags would become one row per (user, type, device), growth types x
  devices and a fan-out write on every PUT to every device row (and devices created later would need all flags set); (c) delivering all
  global account data on every incremental sync: the spec does not define the incremental `account_data` explicitly, but clients treat
  it as a delta, and resending everything is unbounded here (entries up to 1 MB each, no row-count cap, a response every 25 s per
  device); carrying the positions in the token suffix like room account data (`<core>.<rpos>.<gpos>`): it would also change the
  device-less behaviour, needs a second token-format migration (`split_since_token/1` recognises one numeric suffix) and adds a
  client-controlled input; storing the positions in the server-side row of the already validated token is smaller and trusted.
  **Edge cases.** A device row created before this migration has both positions 0, but every device-bound client falls back once (D3),
  and a fallback sends everything and sets the positions. An account data row that is overwritten keeps one row with a NEW position: a
  device that missed the earlier version gets the newest content (state semantics, correct). Cross-signing `put_keys/2` with the same
  keys still draws a new position (today it also sets the flag).
- **D10 A fallback response to a request that carried a `since` ALWAYS lists the own user in `device_lists.changed` (owner decision F4,
  Oracle).** The client cannot know that the answer to its incremental request was initial-shaped, so it would miss a cross-signing
  change; listing the own user makes it re-query its own keys (spurious entries are allowed). Without a `since` (a real initial sync)
  there is no `device_lists` entry (as today). The own user is never put in `device_lists.left`. Applies to device-bound and device-less
  requests (additive; a device-less fallback still consumes the flag as today); a device-bound fallback also advances
  `cross_signing_pos` to the current `changed_pos`. (ATDD clarification: EVERY initial-shaped answer of a device-bound request, with
  or without a `since`, advances BOTH columns: `account_data_pos` to the highest delivered `stream_pos`, `cross_signing_pos` to the
  current `changed_pos`; otherwise the first delta of a fresh device lists the own user spuriously. `device_lists` of an initial-shaped
  answer stays `{"changed": [], "left": []}` as Nebu always sends the object. A user without any event has a nil anchor legitimately:
  "never an empty anchor" holds for users with events.)
- **D11 A global account data PUT wakes the user's waiting `/sync` and a pending change ends the wait at once (owner decision F5,
  Oracle).** (1) `AccountDataStore.put/3` sends `{:account_data_changed, nil}` to every member of `user:<id>` with `:pg.get_members/1`
  (cluster-wide, the `RoomAccountDataStore.notify_sync/2` pattern, never raising) AFTER its transaction committed; the existing wait loop
  already treats `{:account_data_changed, _}` as a wake. (2) A device-bound request with a `since` checks
  `AccountDataStore.pending_since?(user, account_data_pos)` before the core call and sets `timeout_ms = 0` when true, like the room
  account data pre-check (`protected.ex` ~105). Reason: Element's secret-storage setup waits for the echo of its own PUT; without both
  steps it waits up to 25 s (the wake covers the PUT during the wait, the pre-check the PUT between two requests). A device-less request
  is woken too (it then re-reads the flags, as today on its next response); it gets no pre-check (no position). A cross-signing upload
  gets no wake-up in this story (the own `device_lists.changed` entry is not awaited by clients; delivered with the next response).

## Acceptance Criteria

```gherkin
Feature: The /sync since token, the global account data and the own cross-signing change are per device

  Scenario: Two clients of the same user sync incrementally in alternation
    Given a user is logged in on device A and on device B (two opaque sessions) and both have done an initial /sync
    When A and B call /sync alternately, each with its own previous next_batch, once with timeout=0 and once with a timeout > 0
    Then every response is 200, incremental (no fallback to an initial sync) and carries a next_batch; the timeout=0 call returns at once and the timeout > 0 call long-polls until an event or the timeout
    And sync_tokens holds one row per device (user, A) and (user, B) and no row with device_id '' is written by these requests

  Scenario Outline: A leave, kick or ban reaches the user's other client
    Given device A and device B of the same user sync incrementally and the user is joined to a room
    When the user's membership ends by <cause>
    Then the next incremental /sync of device B carries the room in rooms.leave, bounded at the <cause> event

    Examples:
      | cause                          |
      | a leave through device A       |
      | a kick by another member       |
      | a ban by another member        |

  Scenario: Device B receives a global account data change that device A's incremental sync already received
    Given device A and device B of the same user sync incrementally
    When the user PUTs global account data (for example m.secret_storage.default_key) through device A
    Then device A's own next incremental /sync delivers the entry (the echo to the writer)
    And device B's next incremental /sync also delivers that entry with the new content, and a further incremental /sync of either device does not repeat it

  Scenario: Every device, the uploader included, receives the own cross-signing change once
    Given device A and device B of the same user sync incrementally
    When the user uploads new cross-signing keys through device A
    Then device A itself also lists the user in device_lists.changed of its next incremental /sync, and so does device B, each exactly once and never in device_lists.left

  Scenario: The two positions never skip an uncommitted write (interleaving)
    Given a device of a user syncs incrementally
    When a global account data write and a cross-signing upload of that user commit concurrently and interleaved with the device's position reads (an account data row commits between the account data read and the cross-signing read)
    Then account_data_pos only ever advances to the highest account data position read and cross_signing_pos only to the highest cross-signing position read, and every written entry is delivered by one of the device's following incremental syncs

  Scenario: A global account data PUT ends a waiting or a following long-poll at once
    Given device B of a user waits in an incremental /sync with timeout=25000 (on any cluster node)
    When the user PUTs global account data through device A
    Then device B's /sync returns at once with the entry, and a device whose since predates an already committed PUT gets an immediate answer instead of waiting

  Scenario: The initial sync and a fallback store the real anchor and positions under the device key
    Given device A of a user has no stored since token, or presents a token that does not match its row
    When device A calls /sync
    Then it receives a 200 initial-shaped response with all global account data, its row (user, A) stores the anchor of the newest delivered event (never an empty anchor) and the highest delivered positions
    And when its request carried a since, the own user is listed in device_lists.changed (never in device_lists.left); without a since there is no device_lists entry
    And its next incremental /sync with the returned next_batch delivers only newer events and account data changes, without repeating the snapshot

  Scenario: A request without a device id keeps the per-user behaviour
    Given a user authenticates with a raw IdP JWT that has no server-side device binding
    When the client calls /sync with its previous next_batch
    Then the token is looked up and stored under the per-user key (device_id '') and global account data / the cross-signing change are delivered by the consume-once flags exactly as before, and device-bound clients of the same user neither read nor overwrite that row nor clear those flags

  Scenario: A token issued before the change falls back once
    Given a device-bound client presents a next_batch that was stored under the per-user key before the update
    When it calls /sync
    Then it receives one 200 initial-shaped response and from then on syncs incrementally from its own device row

  Scenario: A since token of another device or another user, or a malformed one, is never accepted
    Given user X's device A holds a valid next_batch
    When user Y (or X's device B) calls /sync with that next_batch, or any client calls /sync with a malformed, an empty or an oversize since
    Then the answer is 200 with an initial-shaped response of the CALLER's own partition and own account data (an empty since counts as absent), containing no event or account data the caller does not own or see
    And the sync_tokens row of X's device A (and of every other user or device than the caller) stays byte-identical

  Scenario: The old token of a deleted device is rejected before any sync state is touched
    Given device A of a user has synced and is then deleted (or logged out)
    When a client calls /sync with device A's old access token and its last next_batch
    Then the answer is 401 M_UNKNOWN_TOKEN and no sync_tokens row is read or written for (user, A)

  Scenario: A re-created device id does not resume the deleted device's sync
    Given device A was deleted and a new login re-creates a device with the same device id
    When the new session calls /sync with a next_batch issued to the deleted device
    Then it receives a 200 initial-shaped response (fallback), never an incremental delta from the old anchor

  Scenario: Deleting a device or erasing the user removes its since tokens and positions
    Given a user has sync_tokens rows for devices A and B
    When device A is deleted (or logged out), and later the user is erased
    Then the row (user, A) is gone after the device teardown while (user, B) stays, and after the erasure no row of the user remains

  Scenario: Follow-up fd is closed
    Given docs/stories/oauth-broker/follow-ups.md
    When the story is done
    Then row fd is marked "CLOSED by story sync-token-per-device", names the device-less exception, the one-time rollout fallback, the per-device account data / cross-signing delivery, the own user on a fallback and the wake-up, keeps the original text, and its status column is closed
    And rows cj, ck, cl and cm exist once each with their status (ck: open, owner decision before activation / release) and the id line names them while keeping its gm onward text
```

## Test list (Oracle gate)

The condensed Oracle context (`_bmad-output/nebu/epics/oauth-broker/step-results/sync-token-per-device/oracle-context.md`) carries no
numbered section 6; the list below is its verified scenario list ("New scenarios" plus F2-F6), mapped to tests:

1. HTTP, two opaque sessions of one user (`sync_token_per_device_http_test.exs`, throwaway PG): alternating incremental syncs, `timeout=0`
   and `> 0`, `next_batch` always present, one row per device and no `''` row (Scenario 1); leave / kick / ban to the other device
   (Scenario 2); account data echo to the writer and to device B, no repeat (Scenario 3); cross-signing to both devices incl. the uploader,
   never in `left` (Scenario 4); the wake-up and the pending pre-check (Scenario 6); fallback with and without `since` (Scenario 7); an
   unbound JWT (Scenario 8); a pre-change `''` token (Scenario 9); a foreign / malformed / empty / oversize `since` with byte-identical
   other rows (Scenario 10); a deleted device's token -> `401 M_UNKNOWN_TOKEN`, no row (Scenario 11); a re-created device id (Scenario 12);
   device delete and erasure (Scenario 13).
2. Store tests on a throwaway PG: `stream_pos` drawn in both upsert branches; `changed_pos` only by `put_keys/2`; the advisory lock
   orders concurrent writers of one user (a reader never passes an uncommitted lower position); the interleaving of Scenario 5 with two
   columns (a shared column would fail it: keep a mutation of the store that advances one column from both sources as a negative control);
   `GREATEST` and the token-guarded advance; device-less flag readers unchanged; `notify_sync/1` uses `:pg.get_members/1` and runs after
   the commit (not on a rolled-back write).
3. Unit tests (`EventDispatcher.Server` with the fake PG store): the key choice per request (D1), the real anchor of the initial sync
   and of the fallback under the device key and no nil-anchor upsert (D4), the compat case (D3).
4. Migration `000052` up / down on a fresh and on a populated schema (existing `account_data` rows get distinct positions).
5. Docs test (`sync_token_per_device_docs_test.exs`): the `fd` closure tokens (D7), rows `cj`-`cm` unique with their status cells, the id
   line still matching `unused:[^.]*`gm` onward`, the `fd` text in `07-deployment.md` and `matrix-api-scope.md`.

## Definition of Done

- [x] All Gherkin scenarios have failing tests (ATDD)
- [x] All tests pass (green)
- [x] Migration `000052` (number confirmed at commit) applies and reverts on a throwaway PostgreSQL, on a fresh and on a populated schema
- [x] Code review clean (0 MAJOR)
- [x] Security review (if required) clean

## Open Questions

- ANSWERED (orchestrator, 2026-10-26): D9 / D11 transaction + per-user advisory lock per global account data PUT and cross-signing
  upload plus a cluster-wide `:pg` send are acceptable (the room account data writes already pay the same).
- ANSWERED (orchestrator, 2026-10-26): D10 applies to device-bound AND device-less requests (additive, spec-safe).
- Follow-up `ck` (GDPR erasure of `account_data` / `cross_signing_keys`, compliance HIGH) needs an owner decision before
  `oauth_enabled` / the release; it does not gate this story.
