---
story_id: device-lists-changed-on-deletion
title: "Device-list change log: every device deletion (and every device / cross-signing key change) puts the user into `device_lists.changed` of the peers' and the user's own next `/sync` and into `GET /keys/changes` (gate s)"
type: feature
severity: medium
epic: oauth-broker
status: backlog
security_review: required
matrix: true
ui: false
created: 2026-10-13
branch: feature/migrate-to-oauth2
---

> **STATUS: BACKLOG (decision 2026-10-13, phase 2, gate (s) re-scoped).** Not implemented in this phase: Nebu refuses encrypted rooms (ADR-011), so no peer encrypts to a device, and the design (a new change-log table, a `/sync` token change) is risky. Gate (s) now reads "before encrypted rooms are allowed (ADR-011 lifted) and before any release that claims E2EE". Reserved follow-up ids: `bv`, `bw`, `bm`-`bo` (the former `bg` and `bl` collided with the room-summary section and were renamed `bv` / `bw`); migration number `000047` is TAKEN (oauth-hardening-hygiene), use the next free number when the story is picked up; re-run the story's "Doc edits" against the then-current follow-ups / 07-deployment rows.

## Summary

Phase-2 story P7 of epic `oauth-broker`. Closes `follow-ups.md` gate item **(s)** (row ~l.137, re-classified
as a gate before `oauth_enabled` by the oracle gate of bugfix legacy-logout-per-device, correction O2; ADR-033
LL12): deleting a device is a device-identity change. Users sharing a room with the owner and the owner's own
other devices must see the owner in `device_lists.changed` of their next incremental `/sync` and in
`GET /_matrix/client/v3/keys/changes`, otherwise their clients keep the deleted device cached (session lists,
"unverified session" warnings, encryption targets).

Verified state on HEAD 671ea2e8 (read before coding):

- `/sync` emits `device_lists` only from the consume-once `cross_signing_keys.cross_signing_changed` flag, and
  only the caller's OWN id (`protected.ex` `put_cross_signing_device_lists/3` ~l.228). Peers never learn
  anything; a second device of the same user can miss it (flag consumed per user). `left` is always `[]`.
- `/keys/upload` records nothing for new devices. `GET /keys/changes` is NOT routed (falls to `match _` =>
  404; `docs/matrix-api-scope.md` l.267 still lists a stale Go-era stub "Returns changed: [], left: []").
- `/sync` already returns `device_one_time_keys_count`, `device_unused_fallback_key_types` (user aggregate,
  follow-up bm) and `device_lists: {changed: [], left: []}` on every response (`Http.sync_response/3` l.136).
- `POST /keys/query` reads `device_keys JOIN devices`: a deleted device is already absent once its teardown
  committed (pinned by a test, no code change).
- Every device deletion ends in `DeviceKeyStore.delete_device!/3` (in-transaction) or `delete_device/2`
  (autocommit; only the self-delete preserve branch of `delete_one_device/3`).
- Nebu refuses `m.room.encryption` (ADR-011): no Megolm rooms; device directory and cross-signing are live and
  clients track device lists for verification state.

`oauth_enabled` stays OFF; nothing reads or changes it. Migration **000047** (`device_list_changes`).

## Story

As a Nebu user whose device is signed out (by me, an admin, a client revocation or the operator), **I want**
everyone I share a room with and my remaining sessions to learn it on their next sync, **so that** their
clients drop the deleted device without a reload.

## Decisions

- **DL1 One change log, fan-out at read time.** New table `device_list_changes` (000047, schema in Dev
  Notes): one row per (changed user, writing transaction), `UNIQUE (user_id, txid)` with `txid DEFAULT
  pg_current_xact_id()`. Writers `INSERT ... ON CONFLICT (user_id, txid) DO NOTHING`. No
  per-recipient rows (O(room members) per deletion). One row per user per teardown transaction, however many
  of the user's devices it deletes (revoking a client with 10 000 devices of one user = 1 row). Per-device
  transactions (`/logout/all`, operator revoke-all) write one row per device; the reader de-duplicates.
- **DL2 Commit-ordered positions (never skip a change).** A plain sequence is NOT a safe position: a client
  revocation (up to 120 s) holding id 10 can commit after a logout with id 11; a client at 11 skips 10 forever.
  Rows are inserted with `stream_id NULL` and a
  `DEFERRABLE INITIALLY DEFERRED` constraint trigger (`AFTER INSERT ... FOR EACH ROW`) assigns
  `stream_id = nextval('device_list_changes_stream_seq')` under `pg_advisory_xact_lock(4747, 47)` (two-int key
  space, unused elsewhere) at COMMIT, held only until the commit ends; a transaction becomes visible before it
  releases its locks, so visible stream ids are a gap-tolerant PREFIX: a reader at M never later sees a new row
  `<= M`. Readers ignore `stream_id IS NULL`; a rollback leaves no row (DL11).
- **DL3 ONE hook in the common teardown seam.** `DeviceKeyStore.delete_device!/3`, after its four DELETEs,
  calls `Nebu.Matrix.DeviceListChanges.record!(repo, user_id)` on the SAME repo (so on the transaction's
  connection) IF the `device_keys` or the `devices` DELETE removed a row. This covers, without touching the
  callers: `/oauth2/revoke` + OAuth `/logout` (`end_session_for_token/1`), legacy `/logout`
  (`end_legacy_device/5`), `end_device/3` (= `end_device_session/2`: `DELETE /devices/{id}` of another device,
  `/delete_devices`, account page, Admin UI `delete_user_device/2`, GDPR erasure's OAuth part, `/logout/all`
  steps 1 and 3, operator `Nebu.Release.revoke_all_oauth_sessions/0`) and client revocation
  (`end_client_devices/2` inside `ClientStore.revoke/3`, the nested transactions join the outer one, so DL1
  de-duplicates per user over the whole batch). `DeviceKeyStore.delete_device/2` becomes
  `repo.transaction(fn -> delete_device!(user_id, device_id, repo) end)` (all-or-nothing; never raises;
  `:ok | {:error, reason}`; its only caller keeps `_ =`).
- **DL4 What counts as a deletion.** A device that had a `devices` or `device_keys` row (spec "removed an
  existing device with identity keys"; recording a keyless device is an allowed over-report and keeps the rule
  simple). Deleting an absent device records nothing (idempotent). Session-only removals delete no device and
  record nothing: OAuth take-over `delete_device_oauth/2`, T7 re-login, `MatrixSessionStore.delete_for_user/1`,
  admin deactivation (legacy devices of deactivated / erased users stay, pre-existing, unchanged).
- **DL5 Additions and key changes use the same log** (spec `GET /keys/changes`: "added new device identity
  keys or removed an existing device"; `DeviceLists.changed`: "updated their device identity or cross-signing
  keys"). (a) `DeviceKeyStore.put_device_keys/4` records when the stored `device_keys_json` is new or different
  (first upload of a device, a re-keyed device id, a signature merge through `/keys/signatures/upload` on a
  device key), in one transaction with the `device_keys` upsert; an identical re-upload records nothing.
  (b) `CrossSigningKeyStore.put_keys/2` records in one transaction with its upsert (peers learn about an
  identity reset, including the story-6 `m.oauth` approved replacement). OTK / fallback uploads never record.
  The `cross_signing_changed` flag and `put_cross_signing_device_lists/3` stay as they are (merged with
  `Enum.uniq`). Cross-signing signature merges (`put_keys_no_flag/2`) do not record (follow-up bo).
- **DL6 Recipients (read time).** A change of user U is reported to caller C iff `U == C` (C's other devices;
  the deleted device itself is gone) or C and U currently BOTH have a `room_members` row with `left_at IS NULL`
  in at least one common room (joined; invited-only, left and never-shared users are never told: no leak of
  device activity). Membership is evaluated at read time (spec `/keys/changes`: "currently share a room").
  "Any joined room" is the safe superset of the spec's "encrypted room" (Nebu has none).
- **DL7 Position in the sync token.** `next_batch` = `<core>.<adpos>.<dlpos>`. New pure module
  `Nebu.Matrix.SyncToken`: `parse/1` tries `\A(.+)\.([0-9]+)\.([0-9]+)\z`, then today's
  `\A(.+)\.([0-9]+)\z` (dlpos 0), else the whole token is the core (adpos 0, dlpos 0); both positions follow
  today's bound rule (more than 19 digits or above int8 max => 0). `format/3` builds the token. dlpos 0 = "from
  the start of the log": correct for every token issued before 000047 (the table starts empty). A dlpos above
  the current position is clamped (next_batch echoes the current one).
- **DL8 Sync algorithm.** `upto = DeviceListChanges.position()` (max visible `stream_id`, 0 when empty) is
  read BEFORE the long-poll. Incremental request (a `since` is present, including the fallback-to-initial
  case): `changed` = DL6-filtered DISTINCT users with `stream_id` in `(dlpos, upto]`, merged (`Enum.uniq`)
  with the cross-signing flag result; if non-empty the long-poll runs with `timeout_ms = 0` (answer at once).
  Initial sync: nothing computed, next_batch carries `upto`. Changes committed during the long-poll are
  `> upto` and reach the next sync. A read failure (database error, exit, no repo in unit runs): `changed`
  without log entries, next_batch carries the SINCE dlpos (no advance, nothing lost), one static WARNING
  "device list read failed" with the error TYPE only. `left` stays `[]` (follow-up bw). No wake-up of an
  already parked long-poll (follow-up bn; latency bounded by the client timeout, capped at 25 s).
- **DL9 Bounded read.** At most `:device_list_scan_cap` (app env, default 10 000) log rows in `(dlpos, upto]`
  are scanned. More rows (a client offline for a long time) => over-report: C plus every user currently
  sharing a joined room with C (spec allows over-reporting: "a server may add Alice to changed"). No pruning in
  this story (follow-up bv); this over-report rule is the contract a later pruning relies on.
- **DL10 `GET /_matrix/client/v3/keys/changes`.** New `Protected` route before `match _`,
  authenticated (both APIs), not rate limited (spec; DL9 bounds the work). `from` required (absent / empty =>
  `400 M_MISSING_PARAM` "from is required"); `to` optional (absent => current); both via `SyncToken.parse/1`
  (no position => 0, never an error); `to` clamped; `from >= to` => empty. `200 {"changed": [...], "left":
  []}`, DL6 recipients. v3 only (no `r0` alias).
- **DL11 Failure semantics: atomic with the teardown.** `record!/2` raises on a database error, so the
  surrounding teardown rolls back and its EXISTING error answer applies (`500 M_UNKNOWN`, admin flash,
  revoke 503 / failure audit): never a deleted device without its change row, never a change row without a
  deletion. For DL5 a failing record rolls back the key write (today a failed upsert already raises => 500).
- **DL12 Architecture.** `Nebu.Matrix.DeviceListChanges`: plain module, inline SQL (ADR-018), `repo`
  parameter for writes (the `:oauth_session_repo` seam keeps working), `Application.get_env(:nebu,
  :device_list_changes_repo, Nebu.Repo)` for reads (test seam). Called only inside `Nebu.Matrix`; other domains
  reach it via existing facades (ADR-020). No node-local state (cluster safe).
- **DL13 Database hardening (000040 pattern).** RLS `ENABLE` + `FORCE`; policies for `nebu_app`: SELECT
  all; INSERT `WITH CHECK (stream_id IS NULL)`; UPDATE `USING (stream_id IS NULL) WITH CHECK (stream_id IS NOT
  NULL)`; no DELETE policy. Grants: `SELECT`, `INSERT (user_id, created_at)`, `UPDATE (stream_id)` on the
  table, `USAGE` on `device_list_changes_stream_seq`. The trigger function is NOT `SECURITY DEFINER`.
- **DL14 Logging.** No new INFO lines; MXIDs only, never tokens, hashes or content (Law). `/keys/changes`
  query values are positions (no redactor change).
- **DL15 Out of scope (recorded as follow-ups bv, bw, bm-bo).** Retention / GDPR of the log; membership
  driven `changed` / `left`; per-device fallback-key types; long-poll wake-up; cross-signing signature merges.
  Ids: `bf`-`bl` are taken by the room-summary story and `bq`-`bu` by oauth-hardening-hygiene, so the first draft's
  `bg` and `bl` are renamed `bv` and `bw`; `bm`-`bo` stay (free).

## Acceptance Criteria

Fixture for AC3-AC13 (integration): Alice with devices A1, A2 (+ keys via `seed_device_keys!`), Bob and
Alice joined to room R; Carol with no shared room; Dave only INVITED to R; Erin joined R and left before the
deletion. "Bob sees Alice" = Alice in `device_lists.changed` of Bob's incremental `/sync` from his last
`next_batch` AND in `GET /keys/changes?from=<that token>`.

### AC1 Migration 000047 and the store (DL1, DL2, DL13)
1. Up creates table, sequence, trigger function and constraint trigger, RLS and grants; down drops them;
   up/down/up is clean; `MigrationsGrantTest` passes.
2. `record!/2` twice for the same user in one transaction => one row; two users => two rows.
3. Inside an open transaction the row has `stream_id NULL` and `position/0` from another connection does not
   include it; after COMMIT it has a stream id `>` every previously visible one.
4. Order: transaction T1 records first, T2 records and commits first, T1 commits => T2's stream id < T1's; a
   reader at T2's position later reads T1's row (no skip).
5. Rollback after `record!/2` => no row.
6. As `nebu_app`: DELETE, UPDATE of `user_id` and INSERT of `stream_id` / `txid` are permission errors;
   re-setting `stream_id` of a sealed row affects 0 rows (RLS).

### AC2 Sync token (DL7, unit)
`SyncToken.parse/1` / `format/3`: `c.5.7` => `{c, 5, 7}`; `c.5` => `{c, 5, 0}`; `c` => `{c, 0, 0}`;
`c.+5`, `c.-1`, `c.a.b`, `c..5x`, `c.` => whole token is the core; positions of 20+ digits or above int8 max
=> 0; `format(parse(t)) == t` for well-formed tokens. A `/sync` response's `next_batch` has three parts.

### AC3 Every deletion path notifies (gate s core; DL3)
For each path Bob sees Alice, Alice's surviving device sees Alice, and the deleted device is gone from Bob's
`/keys/query` and Alice's `GET /devices`: (a) OAuth `POST /logout`; (b) `POST /oauth2/revoke` with the access
token and, separately, with the refresh token; (c) legacy `POST /logout` with an opaque token and with a bound
raw IdP JWT; (d) `POST /logout/all` (all devices: Bob sees Alice; Alice has no device left); (e) `DELETE
/devices/{A2}` from A1; (f) A1 deletes ITSELF after a fresh UIA (preserve branch, `delete_device/2`);
(g) `POST /delete_devices` with A2 and a third device => Alice listed once; (h) account page device deletion;
(i) Admin UI `DELETE /admin/users/:user_id/devices/:device_id`; (j) client revocation (`Nebu.OAuth.revoke_client/3`);
(k) `Nebu.Release.revoke_all_oauth_sessions/0`; (l) GDPR erasure (`delete_user_keys` OAuth part).

### AC4 Batch bound (DL1)
Revoking a client whose sessions are 3 devices of Alice and 2 of Frank (Frank in R too) writes exactly one row
for Alice and one for Frank; Bob's next sync lists each once. `/logout/all` with 3 devices: Bob's `changed`
contains Alice exactly once.

### AC5 Recipients, no leak (DL6)
Carol, Dave and Erin do NOT see Alice (sync and `/keys/changes`), for every path of AC3 exercised in AC5's test
(at least a, c, j). Alice's other device sees Alice. A user who joins R after the deletion and syncs from an
older token may see Alice (allowed over-report; asserted not to crash, not asserted either way).

### AC6 Lazy peer and tokens
1. Bob does not sync during the deletion; hours later (simulated) his sync from the old token lists Alice;
   `/keys/changes?from=<old>&to=<new next_batch>` lists Alice.
2. The next sync from the new `next_batch` does not list Alice again; a retry with the SAME old `since`
   lists Alice again (retry-safe, nothing consumed).
3. A pre-000047 token `<core>.<adpos>` (no dlpos) lists Alice (dlpos 0).
4. A forged dlpos far above the current position lists nothing and `next_batch` carries the current position;
   a later deletion is then reported.
5. Initial sync (no `since`) carries the current dlpos in `next_batch` and `device_lists.changed == []`.

### AC7 Idempotency (DL4)
Deleting an already deleted / unknown device (`DELETE /devices/{x}` 200 no-op, second revoke) writes no row.
A keyless device deletion writes a row. A session-only take-over (T26) writes no row.

### AC8 Rollback leaves nothing (DL11)
1. A failing teardown of A2 (`block_deletes!("devices", alice)`) => the path's existing error answer, A2 and
   its keys intact, no row for Alice, Bob does not see Alice.
2. A failing `device_list_changes` INSERT (test trigger blocking inserts for Alice) => the teardown rolls
   back: A2 still exists, its tokens still work, `500 M_UNKNOWN` (a, c, e) / failure flash (i).
3. Client revocation where Frank's device teardown fails => no row for Alice either (one transaction).

### AC9 Concurrency (DL2)
A revocation transaction that recorded Alice and is held open (barrier) while Bob syncs and a short logout of
Frank commits: Bob's sync lists Frank, not Alice; after the revocation commits, Bob's next sync from the
returned token lists Alice.

### AC10 Long-poll (DL8)
With a pending change, Bob's `/sync?timeout=10000&since=...` answers in under 2 s with Alice. Without one it
still long-polls (existing behaviour).

### AC11 `GET /keys/changes` contract (DL10)
No token => 401; `from` missing or empty => `400 M_MISSING_PARAM`; `to` absent => up to now; `from >= to`
=> `{"changed": [], "left": []}`; non-token `from` => treated as 0 (200); legacy and OAuth callers both work;
`left` is always `[]`; JSON content type.

### AC12 `/keys/query` and E2E fields after deletion (DL14)
Bob's `/keys/query` for Alice no longer returns A2 but still returns A1; Alice's cross-signing keys unchanged;
every `/sync` still carries `device_one_time_keys_count`, `device_unused_fallback_key_types` and
`device_lists.{changed,left}` as arrays / objects (existing tests green).

### AC13 Additions and key changes (DL5)
First `/keys/upload` with `device_keys` of a new device of Alice => Bob sees Alice; identical re-upload =>
no row; OTK-only / fallback-only upload => no row; `/keys/signatures/upload` merging a signature into A1's
device key => row; `/keys/device_signing/upload` (first upload and approved replacement) => Bob sees Alice;
Alice's own next sync still lists Alice (flag path unchanged).

### AC14 Bounded read (DL9)
With `:device_list_scan_cap` set to 3 (scoped env) and 5 unrelated rows after Bob's token, Bob's `changed`
is Bob plus every user sharing a joined room with him (incl. Alice), never Carol.

### AC15 Read failure (DL8)
With the read seam failing, `/sync` answers 200, `changed` has no log entries, `next_batch` keeps the since
dlpos; the next sync with a working store reports Alice. The WARNING carries no user id list and no token.

### AC16 Logging (Law)
`refute_secrets_in_log` over AC3 (a), (c) and AC11: no token, hash, jti or message content.

### AC17 Documentation
The exact edits of "Doc edits"; ADR-033 section pinned by `adr_033_test.exs`.

## Acceptance Tests

- NEW `server/test/nebu/matrix/sync_token_test.exs` (unit, async): AC2.
- NEW `server/test/nebu/matrix/device_list_changes_test.exs` (`@moduletag :integration`, `async: false`):
  AC1.2-AC1.5, AC9 (two connections via `Task` + barrier), AC14, AC15, recipient SQL (AC5 at store level).
- NEW `server/test/nebu/migration/000047_device_list_changes_test.exs` (pattern of
  `000046_oauth_client_revocation_test.exs`): AC1.1, AC1.6.
- NEW `server/test/nebu/oauth/device_lists_on_deletion_test.exs` (`@moduletag :integration`, `async:
  false`, `alias Nebu.OAuth.TestSupport, as: T`; setup like `legacy_logout_per_device_test.exs`; room
  helpers copied from `matrix/matrix_mutual_rooms_test.exs` l.481-505 createRoom / invite / join): AC3-AC8,
  AC10-AC13, AC16. Positions are RELATIVE (other tests leave rows): never assume position 0.
- CHANGED `server/test/nebu/matrix/room_account_data_hardening_test.exs` §4 (~l.334-376): its three tests
  split `next_batch` into two parts; adapt to `<core>.<adpos>.<dlpos>`, same adpos assertions.
- CHANGED `server/test/nebu/oauth/adr_033_test.exs`: pins for the new section headline and DL2 / DL3 / DL6
  keywords; LL12 pin must stay satisfiable.
- Regression, green unchanged: `matrix/{cross_signing,device_keys,device_endpoints,sync_concurrent,
  regression_sync_load}_test.exs`, `oauth/{oauth_device_teardown,oauth_client_revocation*,
  legacy_logout_per_device,oauth_logout,oauth_account_*}_test.exs`.
- Gherkin (written, `tsc --noEmit` + `bddgen` only): NEW `e2e/features/element/device-lists-on-deletion.feature`,
  tag `@device-lists-on-deletion`: alex in browser contexts A and B, bob in context C, alex and bob share a
  room; alex signs out in B; within 30 s and WITHOUT a reload bob's user-info panel for alex lists one session
  and alex's context A session list no longer contains B.

Must be test-covered (CS v1.18 "Tracking the device list", `DeviceLists`, `/keys/changes`): AC3 a-l, AC4,
AC5, AC6, AC8, AC9, AC12.

## Manual verification (operator / tester, before `oauth_enabled`; record results, fail closed)

Record each result in this story's step-results; a failed step keeps gate (s) open in `07-deployment.md`.

1. alex in Element (A) and FluffyChat (B); bob (Element) shares a room and opens alex's user info. alex logs
   out B. Within one sync, no reload: bob's panel drops B, no "unverified session" warning for alex; alex's
   A (Settings > Sessions, "unverified sessions" nag) no longer shows B.
2. Repeat 1 with the deletion done from the account page (`/account`), the Admin UI and an OAuth client
   revocation (one client of alex).
3. alex resets cross-signing (account page approved reset): bob's Element shows the identity-changed notice
   on his next sync.
4. UTD: no encrypted rooms exist (ADR-011); confirm no "Unable to decrypt" after step 1, record "n/a".
5. Restart bob's client after step 1 (it calls `/keys/changes` with its stored token): no stale session.

## Dev Notes

### Current state (read before coding; line numbers ~, room-summary work is shifting `protected.ex`)

- `protected.ex`: `do_sync/1` l.86-166 (`split_since_token/1` l.193, token assembly l.159,
  `put_cross_signing_device_lists/3` l.228), keys routes l.571-655, `DELETE /devices` l.738, `/delete_devices`
  l.772, `delete_one_device/3` l.2323, `match _` l.2138.
- `device_key_store.ex`: `@device_tables` l.19 (OTK, fallback, `device_keys`, `devices`), `put_device_keys/4`
  l.63 (no transaction), `query_devices/1` l.225, `delete_device/2` l.355, `delete_device!/3` l.377.
- `oauth_session_store.ex`: `end_session_for_token/1` l.486, `end_device/3` l.528, `end_legacy_device/5`
  l.585, `end_client_devices/2` l.642, `delete_device_rows!/3` l.871; `oauth_session.ex` l.630-730
  (`end_all_*`, batches of 500, per-device transactions).
- `cross_signing_key_store.ex`: `put_keys/2` l.38, `put_keys_no_flag/2` l.229, `consume_changed_flag/1` l.265.
- `room_members` (000001 l.199): PK `(room_id, user_id)`, `left_at` NULL = joined, index on `user_id`; no
  rows for invites. Advisory locks in use are single-bigint keys only (`uia.ex`, `room_account_data_store.ex`,
  bootstrap checker).
- Tests run WITHOUT the Ecto sandbox (real commits: the deferred trigger fires). Unit runs have no
  `Nebu.Repo`: every read in the `/sync` path must survive an exit (DL8).

### Implementation sketch

1. Migration `server/priv/migrations/000047_device_list_changes.up.sql` (+ `.down.sql`), idempotent,
   no explicit transaction, header comment citing this story and DL1/DL2/DL13:

   ```sql
   CREATE SEQUENCE IF NOT EXISTS device_list_changes_stream_seq;
   CREATE TABLE IF NOT EXISTS device_list_changes (
       id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
       stream_id  BIGINT UNIQUE,
       user_id    TEXT   NOT NULL,
       txid       XID8   NOT NULL DEFAULT pg_current_xact_id(),
       created_at BIGINT NOT NULL,
       CONSTRAINT device_list_changes_user_txid_key UNIQUE (user_id, txid)
   );
   CREATE OR REPLACE FUNCTION device_list_changes_seal() RETURNS trigger AS $$
   BEGIN
       PERFORM pg_advisory_xact_lock(4747, 47);
       UPDATE device_list_changes SET stream_id = nextval('device_list_changes_stream_seq')
        WHERE id = NEW.id AND stream_id IS NULL;
       RETURN NULL;
   END $$ LANGUAGE plpgsql;
   DROP TRIGGER IF EXISTS device_list_changes_seal ON device_list_changes;
   CREATE CONSTRAINT TRIGGER device_list_changes_seal AFTER INSERT ON device_list_changes
       DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION device_list_changes_seal();
   -- RLS ENABLE + FORCE, policies and grants per DL13
   ```
   Down: drop trigger, function, table, sequence (revert the code with it; old code treats a 3-part token
   as an unknown core => initial sync).
2. NEW `server/lib/nebu/matrix/device_list_changes.ex` (moduledoc: DL1-DL9):
   - `record!(repo, user_id)`: `INSERT INTO device_list_changes (user_id, created_at) VALUES ($1, $2) ON
     CONFLICT (user_id, txid) DO NOTHING`; `{:error, e}` => `raise e`.
   - `position/0` => `{:ok, n} | {:error, reason}`: `SELECT COALESCE(max(stream_id), 0) FROM
     device_list_changes`.
   - `changed_for/3 (caller, from, upto)` => `{:ok, [user_id]} | {:error, reason}`: `from >= upto` =>
     `{:ok, []}`; count `SELECT count(*) FROM (SELECT 1 FROM device_list_changes WHERE stream_id > $1 AND
     stream_id <= $2 LIMIT $3) s` with `$3 = cap + 1`; above cap => full set (`SELECT DISTINCT b.user_id
     FROM room_members a JOIN room_members b ON b.room_id = a.room_id WHERE a.user_id = $1 AND a.left_at IS
     NULL AND b.left_at IS NULL` plus caller); else
     ```sql
     SELECT DISTINCT c.user_id FROM device_list_changes c
      WHERE c.stream_id > $2 AND c.stream_id <= $3
        AND (c.user_id = $1 OR EXISTS (
             SELECT 1 FROM room_members a JOIN room_members b ON b.room_id = a.room_id
              WHERE a.user_id = $1 AND a.left_at IS NULL
                AND b.user_id = c.user_id AND b.left_at IS NULL))
     ```
     Reads never raise (rescue + `catch :exit`).
3. NEW `server/lib/nebu/matrix/sync_token.ex` (pure, DL7): `parse/1`, `format/3`; `protected.ex` replaces
   `split_since_token/1` with it (keep its comment block, extended).
4. `DeviceKeyStore.delete_device!/3`: keep table order; collect `num_rows` of the `device_keys` and `devices`
   DELETEs; if `> 0` => `DeviceListChanges.record!(repo, user_id)`. `delete_device/2` => transaction (DL3).
5. `DeviceKeyStore.put_device_keys/4`: keep the devices upsert first; wrap the `device_keys` upsert + record
   in `Nebu.Repo.transaction/1`; detect change with
   `WITH old AS (SELECT device_keys_json FROM device_keys WHERE user_id = $1 AND device_id = $2) INSERT ...
   RETURNING (SELECT device_keys_json FROM old) IS DISTINCT FROM device_keys.device_keys_json`.
6. `CrossSigningKeyStore.put_keys/2`: upsert + `record!(Nebu.Repo, user_id)` in one transaction (joins the
   caller's transaction where one exists, e.g. the approved replacement ~protected.ex l.2479).
7. `protected.ex` `do_sync/1`: parse with `SyncToken`; read `upto` and (incremental) `changed` BEFORE
   `get_sync_delta`; `timeout_ms = 0` when `changed != []`; `put_device_lists/3` (replaces the body of
   `put_cross_signing_device_lists/3`: log result ++ flag result, `Enum.uniq`); next_batch via
   `SyncToken.format(core, latest_pos, dl_next)` where `dl_next = upto` on success, the since dlpos on a read
   failure, `upto` on initial sync.
8. `protected.ex` new `get "/client/v3/keys/changes"` next to the keys routes (DL10).

### Files

- Create: the migration pair, `device_list_changes.ex`, `sync_token.ex`, the four test files, the feature file.
- Modify: `protected.ex`, `device_key_store.ex`, `cross_signing_key_store.ex`, `test/.../room_account_data_hardening_test.exs`,
  `test/.../adr_033_test.exs`, docs below. NOT modified: `oauth_session_store.ex`, `oauth_session.ex`,
  `client_store.ex`, `release.ex`, `users_controller.ex`, `account.ex` (the hook sits below them; DL3).

### What must be preserved

- Teardown lock order (`oauth_clients -> devices -> matrix_sessions`) and the `devices FOR UPDATE` first
  statement; the hook is the LAST statement of `delete_device!/3`, the advisory lock is taken only at commit.
- All existing answers of every deletion path (200 bodies, 500 texts, revoke 503, audits); `/logout/all`
  point-in-time semantics; LL3 re-check outcomes (`{:ok, :unknown}` deletes nothing => records nothing).
- `next_batch` adpos semantics (room account data per device, clamp, bound rule); fallback-to-initial.
- `/sync` body shape, the cross-signing flag; `/keys/query` / `/keys/upload` answers, G1 / C11 guards, caps.

### Traps

1. A sequence/identity as stream position without DL2 silently skips changes under concurrency (AC9).
2. Recording per device instead of per (user, transaction) makes a 10k-device revocation write 10k rows of one
   user; recording in a post-commit step loses it on a crash and breaks AC8.
3. The advisory lock inside `record!/2` (not the deferred trigger) would serialize all teardowns for 120 s.
4. `txid` is always the DEFAULT (never passed by the app), else per-transaction de-duplication breaks.
5. A `since` without dlpos must mean 0, not "now" (a pre-000047 token would miss the deploy window).
6. Unit runs: `position/0` without a Repo must return `{:error, _}`, not crash the sync tests.
7. `put_device_keys/4` is also the signature-merge writer: keep its `:ok` contract.
8. The room-summary story (gates ac/af) rewrites `match _` to `M_UNRECOGNIZED` and probes clauses for 405:
   add the `/keys/changes` route as a normal clause before `match _`; rebase on it if committed first.

### Doc edits (exact)

1. `docs/stories/oauth-broker/follow-ups.md`: row (s) (~l.137): prefix the Item with "**CLOSED by story
   device-lists-changed-on-deletion (DL1-DL15).**" and set Gate to "**CLOSED** (every deletion path records a
   change in its teardown transaction; peers and own devices see the user in `device_lists.changed` and
   `GET /keys/changes`)". Append a section `## From story device-lists-changed-on-deletion (2026-10-13)` with
   "Design context: ADR-033 \"Device-list changes (story device-lists-changed-on-deletion)\" (DL1-DL15).
   Closes (s)." and the table rows:
   - `bv` | **Retention of `device_list_changes`.** No pruning; rows (MXIDs, timestamps) also survive a GDPR
     erasure. A pruning job may delete rows older than N days; DL9's over-report covers tokens below the
     horizon. | DL9 | non-gating
   - `bw` | **Membership-driven device lists.** Nebu never adds a user to `changed` when two users start
     sharing a room, and `left` is always `[]` (spec "Tracking the device list for a user"). Harmless while
     encrypted rooms are refused (ADR-011); required before E2EE is allowed. | DL6, DL8 | non-gating
     (gate for any E2EE enablement)
   - `bm` | **`device_unused_fallback_key_types` is a per-USER aggregate** (`unused_fallback_key_types_for_user/1`),
     the spec defines it per device; a device without a fallback key is told it has one. Also the raw-JWT OTK
     count aggregate. Pre-existing. | DL14 | non-gating
   - `bn` | **No wake-up of a parked `/sync` long-poll on a device-list change**; latency up to the client
     timeout (25 s cap). A `:pg` notify after commit would fix it. | DL8 | non-gating
   - `bo` | **Cross-signing signature merges** (`put_keys_no_flag/2`, e.g. a user-signing signature of a
     peer's master key) record no change; spec-wise only the signer's own devices need it. | DL5 | non-gating
2. `docs/architecture/07-deployment.md` gate table row `s` (l.209): Status = "closed (story
   device-lists-changed-on-deletion; Manual verification in ADR-033 pending)", What unchanged; the
   non-gating list (l.218): append "(bv) device-list log retention, (bw) membership-driven `changed`/`left`
   (gate for E2EE), (bm) per-user fallback-key types, (bn) no long-poll wake-up, (bo) cross-signing signature
   merges".
3. `docs/matrix-api-scope.md`: delete the stub row `GET /_matrix/client/v3/keys/changes` (l.267); add after the
   `keys/signatures/upload` row (l.251): `| GET | /_matrix/client/v3/keys/changes | ✅ | Users whose device
   list changed between two sync tokens (`from` required, `to` optional): device deletions on every path,
   new / changed device keys, cross-signing uploads; only the caller and users currently sharing a joined room;
   `left` always `[]` (follow-up bw); not rate limited, bounded scan (ADR-033 DL1-DL15) |`; replace the
   paragraph l.253-255 by: "Device deletions, new / changed device keys and cross-signing uploads are recorded
   in `device_list_changes` (000047) in the writing transaction; the user then appears in
   `device_lists.changed` of the next incremental `/sync` of their own devices and of every user sharing a
   joined room (`next_batch` = `<core>.<adpos>.<dlpos>`) and in `GET /keys/changes`."; `/sync` row (l.54): append
   "`device_lists.changed` from the device-list log (ADR-033 DL6-DL9); `left` always `[]`".
4. `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`: new section after "## Legacy logout
   per device" (before "## Gate items ..."): `## Device-list changes (story device-lists-changed-on-deletion)`
   with one intro line ("Closes gate item (s); Matrix CS v1.18 'Tracking the device list for a user', `GET
   /keys/changes`.") and DL1-DL15 as one bullet each (bold title + 1-2 sentences), then `### Manual
   verification (before oauth_enabled)` with the 5 steps above. In LL12 append " Closed by DL1-DL15
   (story device-lists-changed-on-deletion)."

## Open questions (safe defaults applied, confirm at review)

1. DL5 widens the gate from deletions to additions and cross-signing uploads (same hook, one line each);
   without it `/keys/changes` would be half a spec. Accept, or split into a follow-up?
2. bw is non-gating because encrypted rooms are refused (ADR-011); it MUST become a gate if E2EE is enabled.
3. DL9's cap (10 000 rows) and DL2's lock key `(4747, 47)` are conventions; change them only together with
   the tests.
