---
story_id: gdpr-erasure-global-data
title: "GDPR erasure physically deletes ALL personal data of the user that lives in per-user tables (global account data, cross-signing keys, device keys and the other tables of the inventory), in the same transaction as step 4b; a schema guard test fails when a new per-user table is neither erased nor justified; an in-flight initial sync can no longer re-create sync token / cursor rows of an erased user (closes ck, erasure part of cj (a))"
type: bugfix
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
traceability_id: REQ-2026-005
created: 2026-10-27
branch: feature/migrate-to-oauth2
---

# Story: GDPR erasure covers every per-user table (follow-up `ck`)

## Story

**As** the operator (data controller) of a Nebu instance who executes a GDPR Art. 17 erasure for a user, **I want** the erasure to
physically delete every row of personal data that is stored under that user in the database (not only the private keys and the room
account data), and a test that fails when a future migration adds per-user data that the erasure does not know, **so that** an
erased user's secret-storage material, push rules, DM partner list, cross-signing keys, device keys and the other per-user rows are
really gone, the owner decision of 2026-10-27 ("fix ck") is met before `oauth_enabled` / the release, and the gap cannot silently
reopen.

Scope: code + tests + docs. Preferably NO migration (D6). Out of scope: admin deactivation (unchanged), events authored by the user
(retained by design, see the inventory), the `device_lists` follow-up `cm`, the device-teardown race `cj` (a) for logout.

## Premise check (2026-10-27, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `592cdf13`, read-only)

**What the erasure does today** (`Nebu.Compliance.UserDeletion.delete_user_keys/3`, called by `EventDispatcher.Server.delete_user_keys/2`):

- Guard outside the transaction (`check_user/1`: `:user_not_found`, `:conflict` when `deletion_status` is `deletion_in_progress` or
  `keys_deleted`, no attempted-audit for these). One `Repo.transaction`: step 2 `mark_in_progress` (atomic conditional UPDATE ... RETURNING,
  the TOCTOU guard), steps 3-4 `user_keys.private_key = NULL, deleted_at` (signing, encryption), step 4b `DELETE FROM user_room_account_data`,
  step 5 `deletion_status = 'keys_deleted', keys_deleted_at`. A DB error rolls everything back (including the in-progress marker) and
  writes a `user_keys_deletion_attempted` audit row in a separate transaction; success writes `user_keys_deleted` after the commit.
- The code comment at step 4b says it: "Known gap (separate bugfix): the legacy GLOBAL `account_data` rows are not deleted here."
- After the commit `end_sessions_after_erasure/1` (best effort, never raises, warnings carry no secrets): OAuth sessions with their
  devices (`Nebu.Matrix.oauth_end_user_sessions/1`: `devices` rows UNION `matrix_sessions` device ids, each torn down atomically,
  incl. `DeviceKeyStore.delete_device!/3` = `device_keys`, `device_one_time_keys`, `device_fallback_keys`), legacy opaque sessions
  (`MatrixSessionStore.delete_for_user/1`), `sessions` + `sync_tokens` (`session_supervisor.destroy_session/1`; `sync_room_cursors`
  cascades from `sync_tokens`).
- A second call returns `{:error, :conflict}` (-> `already_exists`) and changes nothing: that is today's "second erasure is a no-op".
- `users.deletion_status` is constrained to `NULL | 'deletion_in_progress' | 'keys_deleted'` (000001); the value `'active'` is accepted by
  `mark_in_progress` but never stored. "Not erased" therefore means `deletion_status IS NULL`. No code outside `user_deletion.ex` reads it.
- Entry points in this tree: only `UserDeletion.delete_user_keys/3` and the dispatcher function (tests, in-process / `bin/nebu rpc`). No
  HTTP or Admin route calls them (verified by grep); the `DELETE /api/v1/admin/users/{userId}` pipeline of `docs/compliance/gdpr-deletion-runbook.md`
  (Story 14.4, deactivate -> delete keys -> anonymise profile) is NOT in the Elixir server. See Open Questions (OQ-B).

**Why the two tables survive** (follow-up `ck`, re-verified): `account_data` (000015) and `cross_signing_keys` (000014) have no foreign key
to `users`, and the `users` row is never deleted (it only moves to `keys_deleted`), so an `ON DELETE CASCADE` would not fire even where
it exists. This also holds for `forgotten_rooms` (FK `ON DELETE CASCADE` from `users`) and for `user_room_account_data`: cascade is not
an erasure mechanism in this schema, only explicit DELETEs (or cascades from rows the erasure really deletes, like `sync_tokens`) are.
What the rows hold: `account_data` = Element's client-encrypted secret storage (`m.secret_storage.*`, `m.cross_signing.*`), push rules,
`m.direct` (user ids of DM partners), `m.ignored_user_list`, tags of the legacy path; `cross_signing_keys` = the user's public master /
self-signing / user-signing key objects (with `signatures` maps) and the consume-once / position flags.

**What the server serves for an erased user today.** `/keys/query` -> `CrossSigningKeyStore.query_cross_signing/1` reads the
`cross_signing_keys` row and `DeviceKeyStore` the device tables; `/sync` delivers `account_data` (rows by `stream_pos`) and the own
cross-signing change. With the rows gone nothing is served; a peer's `/keys/query` for the erased user returns the user without
cross-signing keys / devices (the same shape as a user who never uploaded). The erased user's sessions are already dead (R19), so no
`/sync` of the user exists afterwards (an in-flight one: D5).

**Writer lock.** `AccountDataStore.put/3` and `CrossSigningKeyStore.put_keys/2` serialise per user with
`pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))` (one key for both tables).

**Initial sync persist** (`Nebu.Matrix.Session.PgStore.Postgres.write_token_row/4`, mode `:initial`): `@upsert_initial_sync_token_sql` is an
unconditional `INSERT ... ON CONFLICT (user_id, device_id) DO UPDATE` into `sync_tokens`, followed by `write_cursor_rows/6`
(`sync_room_cursors`, FK to `sync_tokens` ON DELETE CASCADE). `:delta` mode only UPDATEs an existing token row (never inserts). So only the
initial / fallback path can re-create rows (`cj` (a), the accepted residual, security review cycle 0 LOW-2 of sync-stream-position).

**Compliance model for events (stated, not invented).** `docs/architecture/08-concepts.md` ("GDPR Article 17 ... Room history preservation",
"Three PII tiers") and the runbook ("Room History Preservation"): messages in room timelines are NOT deleted (legitimate archive
interest, immutable signed event log); the sender is pseudonymous (user id) and the profile is anonymised; the audit log stays intact
(7 years). Sensitive PII (`users.email_*`, display name / avatar ciphertext) is crypto-shredded by deleting the private keys (step 3-4).
This story follows that model: events, the room-state mirrors of events, audit and compliance rows are retained; everything else keyed
by the user is deleted.

## Inventory (D2): every table that stores per-user data

Method: every `CREATE TABLE` of `server/priv/migrations/*.up.sql` was scanned for `user_id`, `*_user_id`, `sender`, `inviter_id`,
`invitee_id`, `granted_by`, `started_by`, `actor_*`, `requester_*`, `owner`, FKs to `users`; writers were checked with grep over
`server/lib`. Not tables (no row to erase): typing (ETS / process state), presence (none), `to_device` queues (none), `filters` (none),
`user_directory` (reads `profiles`), third-party ids (none), `room_tags` (rows of `user_room_account_data`, type `m.tag`), ignored users
(`account_data`, type `m.ignored_user_list`). The dev agent re-runs the scan against HEAD, verifies every line and extends the list;
the list below is the contract the guard test (D3) is built from.

| Table | State today | This story |
|---|---|---|
| `user_keys` | private key `NULL` + `deleted_at` (steps 3-4); public key row stays | retained on purpose: the public keys keep retained event signatures verifiable (08-concepts "GDPR Right-to-be-Forgotten") |
| `users` | PII columns crypto-shredded by the key deletion; `deletion_status`, `keys_deleted_at` set; row stays | retained on purpose: the pseudonymous identity row referenced by events / membership / FKs; set `anonymized_at` with the profile step (below) |
| `user_room_account_data` | deleted (step 4b) | unchanged |
| `account_data` | NOT erased (`ck`) | DELETE all rows of the user (D1) |
| `cross_signing_keys` | NOT erased (`ck`) | DELETE the user's row (D1) |
| `device_keys`, `device_one_time_keys`, `device_fallback_keys` | deleted per device by the post-commit teardown (best effort, only for device ids found in `devices` / `matrix_sessions`) | DELETE all rows of the user in the transaction as well (independent of the best-effort teardown; covers device ids without a `devices` / session row; idempotent with the teardown) |
| `devices` | deleted by the post-commit teardown | unchanged (the teardown also denylists JWTs; it stays outside the transaction) |
| `matrix_sessions` (legacy + OAuth), `jwt_device_bindings`, `sessions`, `oauth_idp_refresh_leases` (cascade from `devices`) | ended post commit (R19, best effort) | unchanged |
| `sync_tokens`, `sync_room_cursors` (cascade from `sync_tokens`) | deleted post commit by `destroy_session/1`; re-creatable by an in-flight initial sync (`cj` (a)) | unchanged delete + the persist guard (D5) |
| `profiles` | NOT touched in the Elixir server (plain `displayname`, `avatar_url`); documented policy (Story 14.4 / 5.8) is "overwrite with `Deleted User`, avatar `NULL`, `users.anonymized_at`" | anonymise in the transaction per the documented policy (OQ-B asks for confirmation); the row stays (FK from the user, `/profile` of an erased user shows `Deleted User`) |
| `forgotten_rooms`, `auto_join_opt_outs`, `read_receipts` | NOT erased (the `forgotten_rooms` FK cascade never fires) | DELETE all rows of the user (personal preferences / activity) |
| `uia_sessions`, `oauth_account_sessions`, `oauth_consent_requests`, `oauth_codes` (has `idp_rt_enc`, an IdP refresh token ciphertext) | short TTL rows (<= 5 min / 1 h / code TTL), swept by TTL only | DELETE all rows of the user (a pending code of an erased user must not be redeemable); dev verifies the code-reuse revocation (T8) does not depend on the deleted rows |
| `room_members`, `room_invitations` (`inviter_id`, `invitee_id`), `rooms.creator_user_id`, `events.sender` | not erased | retained on purpose: mirrors / columns of retained signed events (room history preservation, recital 65 per the runbook); the user id is the pseudonym |
| `media_files.uploader_user_id`, `media_state_transitions.actor_id` | not erased | retained on purpose: media referenced by retained events, lifecycle per ADR-030 (media erasure is a separate topic: orphan detection report only, `MediaOrphanDetectionWorker`) |
| `audit_log`, `compliance_requests`, `compliance_sessions` | not erased | retained on purpose: accountability / legal obligation (audit retention 7 years, append-only) |
| `war_room_sessions`, `admin_temporary_captures` (`started_by`), `role_overrides` (`user_id`, `granted_by`; dormant) | not erased | retained on purpose: admin accountability records; dev verifies the dormant table has no writer |
| `push_rules`, `pushers`, `notifications`, `room_account_data` (legacy), `admin_sessions`, `message_buffer`, `message_dead_letter` | FORCE RLS tables and tables without a writer in `server/lib` (verified by grep: dormant, no row can exist) | retained / allow-listed as "dormant, no writer" with that reason; the guard keeps them visible so a writer cannot be added silently |
| `invalidated_tokens`, `operational_logs`, `oban_*`, `server_config`, ... | no user column (token hashes / logs without user id, retention-pruned) | out of the guard (no per-user column); the "no personal data in logs" law applies to the new code |

Other users' rows that merely mention the erased user (a DM entry in someone else's `m.direct`, `m.ignored_user_list`, a signature of the
erased user's user-signing key inside another user's `master_key_json` `signatures`) are those users' data, not the erased user's: untouched
(D7), documented as retained.

## Decisions

- **D1 (owner decision 2026-10-27, "fix ck").** The erasure deletes, in the SAME transaction as step 4b, all rows of the user in
  `account_data` and in `cross_signing_keys`, taking the per-user `sync_global` advisory lock first so a concurrent PUT / key upload
  serialises with it. Admin deactivation is unchanged: it keeps them, as it keeps room account data (reversible).
- **D2 (inventory, premise check).** The table above is the decision record. After the dev agent verifies / extends it, the erasure
  transaction deletes the rows of EVERY table marked "DELETE" (and anonymises `profiles`), and every table marked "retained on purpose"
  carries its reason in the docs (D6). Events authored by the user are not erased and not redacted (existing compliance model, no new policy).
- **D3 (recurrence guard).** A test enumerates the schema from `information_schema` / `pg_catalog` (every table with a column named
  `user_id`, `*_user_id`, or a known user-reference column such as `sender`, `inviter_id`, `invitee_id`, `granted_by`, `started_by`, or a
  foreign key to `users`) and fails when such a table is neither on the module-attribute list "erased by `UserDeletion`" nor on an explicit
  "retained on purpose" allow-list with a reason string per entry. The test must also fail when a listed table no longer exists. A new
  migration with per-user data therefore breaks the build until its author decides erase or retain.
- **D4 (idempotent, atomic).** One transaction (existing semantics kept): any failing step rolls back everything including the
  `deletion_in_progress` marker, and writes the `user_keys_deletion_attempted` audit row in a separate transaction. A second erasure
  returns `:conflict` and changes no row (the existing semantics; every DELETE is also naturally a no-op on empty tables). After the
  commit nothing is served for the user: `/keys/query` returns no cross-signing key and no device, `/sync` of the user cannot run
  (sessions ended). `cm` (`device_lists` of other users) stays out of scope.
- **D5 (in-flight initial sync, erasure only).** The initial / fallback persist must not create `sync_tokens` / `sync_room_cursors` rows for
  a user whose `deletion_status` is not NULL. The guard lives inside the same persist transaction and the same statement as the token upsert
  (an `INSERT ... SELECT ... WHERE EXISTS (SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NULL ...)` form), so the normal
  case costs no extra round trip. Required semantics under READ COMMITTED: the guard must take a row lock on the `users` row that conflicts
  with the erasure's UPDATE (`FOR SHARE`; `FOR KEY SHARE` does not conflict with a non-key UPDATE), so an initial sync that races the
  erasure waits for its commit and then sees the new status; without the lock the statement could still insert after the post-commit
  `destroy_session/1`. When the guard rejects, the cursor write is skipped (no FK error), no error is logged with personal data, and the
  caller's response is not made worse than today. Device teardown (logout, device delete) stays the accepted residual `cj` (a).
- **D6 (docs).** `docs/architecture/08-concepts.md` erasure section (and the "Erasure / deactivation, known limitations" paragraph: remove
  limitation (a)) gains the inventory with the retained-on-purpose reasons and the guard; `docs/stories/oauth-broker/follow-ups.md`: `ck`
  closed with the usual `**CLOSED by story ... (date)**` format, `cj` (a) note updated for the erasure part, the id line / the gate table
  row for the owner flag updated; `docs/architecture/06-runtime.md` erasure paragraph; `docs/compliance/gdpr-deletion-runbook.md` gets the
  verification queries for the newly covered tables. Preferably NO migration (none is needed: code + tests + docs), so a release note in
  `07-deployment.md` is a short behaviour note only (and the one-off sweep for already erased users if OQ-A is confirmed); if the dev
  agent finds a migration necessary (e.g. an index for a per-user DELETE on a large table), the number is the next free one and the note
  follows the existing format.
- **D7 (acceptance + logs).** Acceptance in Gherkin below. No personal data is written to logs or error terms by the new code: no user
  ids' content (account data, key material, display names) in `Logger` calls, `inspect/1` of rows or the attempted-audit `error` field
  beyond what the existing code already emits (law: no sensitive data in logs, tokens, credentials AND chat / account content).

## Acceptance Criteria

```gherkin
Feature: GDPR erasure deletes all personal per-user data

  Scenario: The erasure removes global account data, secret storage, cross-signing keys and legacy device keys
    Given user A has global account data (m.secret_storage.default_key, m.secret_storage.key.<id>, m.cross_signing.master, m.push_rules, m.direct, m.ignored_user_list), a cross-signing key row, legacy device keys, one-time keys and fallback keys, and user B has the same kinds of rows
    When the erasure of user A runs
    Then no row of user A remains in account_data, cross_signing_keys, device_keys, device_one_time_keys, device_fallback_keys and user_room_account_data, and user B's rows are byte-identical to before

  Scenario: The erasure removes the other per-user tables of the inventory and anonymises the profile
    Given user A has rows in forgotten_rooms, auto_join_opt_outs, read_receipts, uia_sessions, oauth_account_sessions, oauth_consent_requests, oauth_codes and a profile with a display name and avatar, and user B has rows in the same tables
    When the erasure of user A runs
    Then user A has no row in those tables, the profile reads "Deleted User" with no avatar and users.anonymized_at is set, user B's rows are untouched, and user A's events, room_members, audit rows and the public user_keys rows are still present

  Scenario: Nothing is served for an erased user and the erased user's sessions are dead
    Given user A is erased and user B holds a valid session
    When user B queries /keys/query for user A and user B syncs
    Then the answer holds no cross-signing key and no device of user A, no global account data of user A reaches any client, and user A's tokens are rejected

  Scenario: A second erasure is a no-op
    Given user A was erased successfully
    When the erasure of user A runs again
    Then it is answered with the existing conflict result, no row of any table changes and no second user_keys_deleted audit row is written

  Scenario: A failing step rolls the whole erasure back
    Given the deletion of one of the new tables fails (forced, e.g. a trigger that raises on that table)
    When the erasure of user A runs
    Then the transaction rolls back (deletion_status is not deletion_in_progress, every row of user A is still present, including the room account data), a user_keys_deletion_attempted audit row is written, and a retry after removing the fault succeeds

  Scenario: Deactivation without erasure keeps the data as before
    Given user A has global account data, cross-signing keys, device keys and room account data
    When an administrator deactivates user A without erasure
    Then none of these rows is deleted and the data is still there after reactivation

  Scenario: An in-flight initial sync cannot re-create token or cursor rows after the erasure
    Given user A's initial sync has read its rooms and has not yet persisted its token, and the erasure of user A commits meanwhile (also: the erasure holds the users row lock while the persist statement starts)
    When the initial sync persists its sync token
    Then no sync_tokens row and no sync_room_cursors row exists for user A, and an initial sync of an active user (deletion_status NULL) persists its token and cursor rows exactly as before, in the same number of statements

  Scenario: A new per-user table cannot appear silently
    Given the recurrence guard test enumerates every table with a user_id column, a *_user_id column, a known user-reference column or a foreign key to users
    When a table is neither in the "erased by UserDeletion" list nor in the "retained on purpose" allow-list (with a reason), or a listed table no longer exists
    Then the test fails naming the table, and on HEAD it passes with every inventory table classified

  Scenario: The erasure writes no personal data to logs
    Given an erasure of a user with account data, key material and a display name, run once successfully and once with a forced failure, with logging captured at debug level
    When the captured log and the attempted-audit row are inspected
    Then they contain no account data content, no key material, no display name, no token and no credential
```

## Test list (ATDD)

1. Real-database erasure test (new file, e.g. `server/test/nebu/compliance/user_deletion_global_data_test.exs`, async: false, real `Nebu.Repo`,
   helpers as in `oauth/oauth_logout_test.exs` / `room_account_data_test.exs`): scenarios 1-3, 5-6; seed rows through the real writers
   (`AccountDataStore.put/3`, `CrossSigningKeyStore.put_keys/2`, `DeviceKeyStore`, the HTTP PUTs where cheap) and compare a snapshot of a
   second user's rows before / after. The forced failure of scenario 5 uses a temporary trigger in a rolled-back test transaction or the
   existing FakeRepo seam; the test must prove the rollback of the EARLIER steps (4b room account data included).
2. `server/test/nebu/compliance/user_deletion_test.exs` (FakeRepo, SQL log): re-pin the statement sequence for the new steps deliberately,
   with a comment; the `:conflict` / `:user_not_found` / attempted-audit cases stay as they are.
3. Dispatcher level: `oauth/oauth_logout_test.exs` erasure test stays green (response unchanged, sessions ended); the best-effort
   branch is untouched.
4. Concurrency test for D5 (two connections, no sandbox transaction around them, like `room/events_room_position_db_test.exs`): the persist
   waits on the erasure's `users` row lock and writes nothing after it; the normal case writes the same rows as before. Plus a unit-level
   statement-count pin for the active-user path.
5. Recurrence guard (scenario 8): `server/test/nebu/compliance/user_deletion_schema_guard_test.exs`, reads `information_schema.columns` /
   `pg_constraint`; the "erased" list is derived from (or asserted equal to) the tables the `UserDeletion` code deletes from, so the two
   cannot drift.
6. Log law (scenario 9): `ExUnit.CaptureLog` plus the audit-row inspection, with the secret / content canaries of the existing tests
   (`refute_secrets_in_log`).
7. Docs test: the erasure section of `08-concepts.md` names every table of the inventory and `follow-ups.md` marks `ck` closed (as the
   existing `*_docs_test.exs` files do); deletion statements for newly covered tables are asserted by the real-database test, not by grep.

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Inventory verified against HEAD by the dev agent; every "retained on purpose" table has its reason in `08-concepts.md`
- [ ] No migration, or the migration applies and reverts on a throwaway PostgreSQL with the release note in `07-deployment.md`
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Open questions answered by the orchestrator

- **D1-D7 above are decisions of the orchestrator (2026-10-27), on the owner decision "fix ck" (the user, 2026-10-27).** They are not open:
  D1 erasure deletes `account_data` + `cross_signing_keys` in the step-4b transaction, deactivation unchanged; D2 inventory first, the
  verified list is the delete list, events retained per the existing model; D3 schema recurrence guard test; D4 atomic + idempotent, nothing
  served afterwards; D5 in-flight initial sync guarded for erased users only (logout residual `cj` (a) accepted); D6 docs and follow-ups
  (preferably no migration); D7 Gherkin acceptance incl. the no-personal-data-in-logs criterion.

## Orchestrator decisions on the open questions (2026-10-27)

- **D8 (OQ-A, already erased users): YES.** A one-off, idempotent operator step (SQL in the `07-deployment.md` release note and the runbook, built from the same
  table list as the erasure, for users with `deletion_status = 'keys_deleted'`) deletes the leftover rows; a real-database test proves it deletes exactly those
  rows of erased users and nothing of active users, and running it twice is a no-op. Not a migration (a data fix the operator runs once, after the deploy).
- **D9 (OQ-B, profile anonymisation): IN this story.** The erasure transaction anonymises `profiles` (`displayname = 'Deleted User'`, `avatar_url = NULL`) and sets
  `users.anonymized_at`, per the documented policy (Story 14.4 / 5.8 / 08-concepts). The missing admin route / the stale runbook text of the
  `DELETE /api/v1/admin/users/{userId}` pipeline is NOT part of this story: the dev agent records it as a new follow-up row (next free id after `cq`'s items; use the id
  convention of the file, the id line must stay intact) and fixes only the runbook sentences that become wrong through this story.
- **D10 (OQ-C, in-flight writes of the erased user): follow-up unless cheap.** If a `deletion_status IS NULL` check inside the existing transactions of
  `AccountDataStore.put/3` and `CrossSigningKeyStore.put_keys/2` (they already hold the `sync_global` advisory lock) costs no extra statement beyond one added
  predicate and breaks no staged test, do it here with a test; otherwise record a follow-up row with the exact scenario. State which way in the dev report.

### Orchestrator decisions after the ATDD report (2026-10-27, gaps G1-G11)

- **D11 (G1, `oauth_codes`): physical deletion, so a migration IS in scope.** Migration `000055_oauth_codes_erasure_delete` (policy only, up adds a second
  DELETE policy branch for users with `deletion_status IS NOT NULL`; down restores the 000041 policy; the policy must NOT allow deleting an active user's
  unexpired code). "Preferably no migration" is withdrawn. Marking the code used is rejected: the `idp_rt_enc` ciphertext would stay up to 24 h. 07-deployment
  release note says "migration 000055" (policy only, no table rewrite, no lock beyond the policy DDL).
- **D12 (G2, legacy devices):** the post-commit teardown also ends legacy devices (`Nebu.Matrix.end_all_user_devices/1`, best effort, guarded like the rest),
  so no `devices` row of the erased user (display name, last seen IP) remains. The inventory states this for `devices`. The story's earlier premise about
  legacy devices is corrected.
- **D13 (G3, sweep scope):** the D8 sweep additionally deletes `devices` of already erased users (`deletion_status = 'keys_deleted'`); the ATDD fix pass pins
  it. The other teardown tables are not swept (sessions already invalid, short-lived; stated in the release note).
- **D14 (G4, pre-existing bug):** the loser of two concurrent erasures must return `{:error, :conflict}` with no second success audit row:
  `UserDeletion` unwraps `{:ok, {:error, reason}}` of `Repo.transaction` (no `rollback/1`, the fakes lack it).
- **D15 (G5, G6, G7, G9):** a rejected persist for an erased user answers `:ok` (as pinned). D10 is DONE here (one predicate, `{:error, :user_erased}`; the
  reference shows it is cheap; keep `user_deletion_late_writes_test.exs`). The retained allow-list lives in the test support (`retained_reasons/0`), the erased
  list is `UserDeletion.erased_tables/0`. The new follow-up row for the missing admin route uses id `cn`.

### Orchestrator decisions after review cycle 0 (2026-10-27: code review 0 MAJOR / 8 MINOR, Kassandra NOT APPROVED: 2 HIGH, 1 MEDIUM)

- **D16 (Kassandra HIGH-1): the `users` PII columns are NOT crypto-shredded.** `display_name_encrypted/_nonce` and `avatar_url_encrypted/_nonce` are encrypted with the
  server-wide `:pii_encryption_key`. The erasure transaction (step 5) and the sweep NULL them (and `email_encrypted/_nonce/_ephemeral_pub` as defence in depth).
  Every reader of those columns (`TokenValidator.Postgres.decrypt_and_return/1` etc.) must be NULL-safe or unreachable for an erased user. 08-concepts "Three PII
  Tiers" and the inventory `users` line are corrected (no false "crypto-shredded" claim). Real-DB assertions for erasure and sweep.
- **D17 (Kassandra HIGH-2): erasure is terminal for authentication.** Step 5 also sets `is_active = false` and `deactivated_at = COALESCE(deactivated_at, now)`.
  Every auth gate (`TokenValidator.Postgres` lookup, `OAuthSessionStore.user_active/1`, `Nebu.Matrix.active?/1`, and any other `is_active` gate the dev finds) treats
  `deletion_status IS NOT NULL` as deactivated, so an admin reactivation cannot revive an erased user. `Profile.DB.upsert_profile/3` is guarded (no write for an erased
  user) so a login attempt can never revert `Deleted User`. The sweep also sets `is_active = false` for `keys_deleted` users. Tests: after the erasure a freshly
  IdP-signed JWT (OidcPlug path), SSO `/login` and OAuth `issue/1` are refused, profile still reads `Deleted User`; staged tests that assume a session CREATED AFTER the
  erasure is valid (e.g. the `m.direct` 404 case) are amended deliberately (old -> new, with a comment). The scenario "deactivation + reactivation keeps data" (Gherkin 6)
  stays for NON-erased users. 08-concepts limitation (f): window = one in-flight request, tokens are dead for real now.
- **D18 (Kassandra MEDIUM-3 + review MINOR 1, 2, 4, 5):** (a) the sweep also deletes the teardown tables for `keys_deleted` users (`matrix_sessions`, `sessions`,
  `jwt_device_bindings`, `sync_tokens`, `sync_room_cursors`, `oauth_idp_refresh_leases`, `devices`) and is documented as the retry path of a failed post-commit teardown.
  (b) `put_keys_no_flag` (signature-merge writer) gets the same D10 predicate (and the advisory lock if it can take it without breaking its callers' lock order; analyse).
  (c) a `:user_erased` refusal is answered `403 M_USER_DEACTIVATED`-style (a permanent condition, not 500), logged at info with the error kind only, no `Logger.error`.
  (d) the erasure names the failing step in the attempted-audit `error_detail` and the log (a step atom only, never data), instead of a bare `:rollback`; note that
  `cross_signing_keys` / `account_data` have no explicit GRANT in 000014/000015 (verify the runtime role can DELETE; add a GRANT to migration 000055 only if needed, keeping it small).
  (e) fail closed on a missing 000055: after the `oauth_codes` delete the erasure counts remaining `oauth_codes` rows of the user and aborts (rollback, step atom `oauth_codes_not_erased`)
  if any remain; the sweep header states "after migration 000055".
- **D19 (rest):** the `read_receipts` full scan stays (no new index; the erasure is rare; state it in the runbook, no migration change). Kassandra LOW-5 (backup retention bound,
  restore must re-run erasure/sweep) goes into the runbook as a paragraph. Kassandra LOW-6 (avatar media object retained) and LOW-4 (unguarded in-flight writers) are
  recorded as follow-up rows with free ids (read the id line and its convention; pick the next free ids; the id line stays valid for the eight pinning suites). Docs
  consistency (review MINOR 7, 8): the `ck` row uses the file convention `Original item:` (adapt the pin in `user_deletion_docs_test.exs` deliberately); 06-runtime and
  08-concepts describe the step and lock order exactly as the code does.

## Open Questions

Raised by the story author from the premise check; none blocks the story (the defaults below are what the contract above already says).

- **OQ-A: users already erased before this release.** Their `account_data` / `cross_signing_keys` / device-key rows stay after the code fix
  (the second erasure answers `:conflict`). Default: ship a one-off, idempotent operator step (release note SQL in `07-deployment.md` plus the
  runbook, built from the same table list, for users with `deletion_status = 'keys_deleted'`) and test that it deletes exactly those rows.
  Orchestrator / owner to confirm; without it the owner flag stays only half closed for existing data.
- **OQ-B: profile anonymisation and the missing admin route.** The documented erasure pipeline (Story 14.4: deactivate -> `DeleteUserKeys` ->
  `profiles.displayname = 'Deleted User'`, `avatar_url = NULL`, `users.anonymized_at`) is not implemented in the Elixir server: no code writes
  `Deleted User` / `anonymized_at`, and no HTTP / admin route calls `delete_user_keys`. Default in this story: the anonymisation is part of the
  erasure transaction (the plain `profiles.displayname` is personal data in a per-user table). Whether the missing admin route (and the stale
  runbook text) is a separate story is for the orchestrator.
- **OQ-C: in-flight WRITES of the user being erased** (a `PUT account_data` or a key upload authenticated before the commit) can insert a row
  after the erasure transaction because those stores do not check `deletion_status` (same class as D5, other writers). The erasure takes the
  shared advisory lock, which makes the window the length of one request; closing it needs a `deletion_status` check in the two stores'
  transactions. Default: record it as a new follow-up row (next free id) unless the dev agent finds the check cheap, then do it here.
