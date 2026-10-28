# ATDD report: sync-token-per-device (red phase), 2026-10-26

Worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `03e33d7a`. Nothing committed. Only `server/test/` changed (no `server/lib`, no `server/priv`).

## Files and test counts

New (145 tests, all names < 200 chars incl. describe; checked with a stricter variant of `.oauth-ci/namelen.py`):

| file | tests | red in the worktree | what it pins |
|---|---|---|---|
| `server/test/nebu/migration/000052_sync_device_positions_test.exs` | 19 | 18 (1 guard: earlier migrations untouched) | static SQL (file found by NAME `*_sync_device_positions.{up,down}.sql`, number >= 52): sequence `sync_global_pos_seq`, 4 columns BIGINT NOT NULL + defaults, index `(user_id, stream_pos)`, `GRANT USAGE, SELECT ON SEQUENCE ... TO nebu_app`, DDL only, transaction-safe, down order; integration: information_schema introspection as the runtime role, nextval as nebu_app, down/up round trip (privileged, rolled back) on the fresh schema AND on a populated schema (120+ existing `account_data` rows get distinct positive `stream_pos`, sync_tokens / cross_signing rows start at 0, a down keeps all data) |
| `server/test/nebu/matrix/sync_token_per_device_store_test.exs` | 41 | 35 (6 regression guards) | `AccountDataStore.put/3` (stream_pos in INSERT and ON CONFLICT branch, identical content, flag still set, opaque bytes, concurrent distinct positions), `list_since/2`, `pending_since?/2` (read-only, cross-user isolation), flag readers unchanged; `CrossSigningKeyStore.put_keys/2` + `changed_since?/2` (shared sequence, merge_signatures / consume_changed_flag never touch `changed_pos`); per-user advisory lock (pg_locks check of the exact key `'sync_global|' \|\| user_id`, NOT the room key; second writer blocks until commit; same lock for cross-signing; other user not blocked); wake-up `{:account_data_changed, nil}` to all `user:<id>` members, AFTER commit (deferred slow commit trigger), none on a failed write, none for cross-signing; static `:pg.get_members` / no `get_local_members`; `PgStore.get_positions/2`, `advance_positions/5` (GREATEST per column, token guard, never inserts, never touches other rows, upsert leaves columns alone, teardown); interleaving (row commits between the two reads: two columns) + a concurrent writers/poller stress test |
| `server/test/nebu/matrix/sync_token_per_device_dispatcher_test.exs` | 15 | 12 (3 pass as guards: proto keeps user_id=1, delta device_id=4, ...) | spy over the real `PgStore.Postgres` on the `:event_dispatcher, :pg_store_module` seam: D1 key choice (device vs `''`), D4 exactly ONE token upsert with the real anchor for initial / fallback / not_found / anchor-missing (no nil-anchor upsert, nothing under `''`), D3 no `''` compat read, D2 device-less 3-arity functions, replay check after fallback; HTTP + spy: authenticated device only (device_id request param ignored), unbound JWT -> `''`, bound JWT -> device; proto parity (pb struct `device_id`, `proto/core.proto` field 2) |
| `server/test/nebu/matrix/sync_token_per_device_http_test.exs` | 53 | 43 (10 controls) | Scenarios 1-13 over the real stack, see mapping below |
| `server/test/nebu/matrix/sync_token_per_device_docs_test.exs` | 17 | 9 | fd closure (D7), cj/ck/cl/cm rows (these 8 are GREEN already: the owner wrote the rows with the story), id line, 07-deployment, matrix-api-scope, code docs |

Amended existing tests (DELIBERATE, found by running the ref implementation over the existing suites; comments in the files):
- `sync_membership_partition_http_test.exs` AC10 ignored-users test: `assert ms >= 150` became `assert ms < 150` (D11: the PUT of `m.ignored_user_list` is pending global account data, the next sync returns at once; red today); the L-2 anchor test read `sync_tokens ... device_id = ''`, now reads the user's only row (green before and after).
- `member_prev_content_http_test.exs` `@baseline_initial_sync_statements` 54 -> 57 and `history_visibility_http_test.exs` `@baseline` initial_sync 45 -> 48, incremental_sync 48 -> 51 (statement-count pins; +3 = get_positions, advance_positions, and the pending_since? pre-check of a delta / the cs read; list_since / changed_since? replace the flag readers 1:1). Red today. If the dev's implementation uses a different number of statements these pins must be re-pinned again (they are measurements of the story design, not of the spec).

### HTTP scenario mapping (`sync_token_per_device_http_test.exs`)
1 alternating A/B, timeout=0 and >0 (>= 250 ms for timeout 300, wake for an event), one row per device, no `''` row, six alternating rounds, next_batch always present, rows bounded by devices; 2 leave / kick / ban to both devices (rooms.leave, window ends at the event, once); 3 echo to writer + B once, overwrite, identical-content PUT, missed versions, flags NOT cleared by bound devices, initial = all then delta, full_state=true stays incremental, writer's stored position, two columns independent, oversize PUT 413 writes nothing / no position / no wake, cross-user marker never delivered; 4 cross-signing on A (uploader) and B exactly once, never in left, every further change again, flag not cleared, initial sync no entry; 5 route-level concurrent writers vs polling device; 6 wake-up of waiting B / of the writer's own wait / pending pre-check (immediate, not spinning), device-less woken; 7 initial + fallback: real anchor (never nil/empty), highest positions, D10 own user on fallback with since (never `left`), none without since, nil-anchor replay at HTTP level, cs position advanced by a fallback; 8 unbound JWT -> `''` row + flags (account data, cross-signing, D10, D11), bound JWT / legacy session -> device row, bound devices never touch the `''` row; 9 pre-change `''` token falls back once; 10 SECURITY: B uses A's token, new device uses A's token, user Y uses X's token (nothing of X in the body, X rows byte-identical), malformed / empty / oversize (100 kB) since => 200 initial-shaped, other rows byte-identical, device_id request parameters ignored, forged position suffix cannot suppress account data, retry of the same since falls back (cj (b)); 11 logout / DELETE devices => 401 M_UNKNOWN_TOKEN, no row re-created; 12 re-created device id => initial-shaped; 13 DELETE /devices, POST /delete_devices, GDPR erasure, `POST /logout/all`, admin deactivation remove the rows (incl. `''`), other users' rows untouched; failure direction (position columns renamed away by the privileged role => 200, entry and own user delivered again); rate behaviour (`/sync` per-IP limit unchanged, a 429 writes nothing).

## Red evidence (worktree, throwaway PG `nebu-oauth-pg` via `.oauth-ci/quick.sh`, Elixir 1.20, `--warnings-as-errors`, compiles clean)
Final red run of the 5 new + 3 amended files: `Result: 160/280 passed, 120 failed` (new: 18+9+43+35+12 = 117 red; amended: 3 red). Reasons, sampled for every group: missing migration files / columns (`column "account_data_pos" does not exist`, `no *_sync_device_positions.up.sql`), `UndefinedFunctionError` (`list_since`, `pending_since?`, `changed_since?`, `get_positions`, `advance_positions`), `Core.GetInitialSyncRequest has no device_id`, spy shows a 3-arity `''` persist instead of the 4-arity device persist, the second device falls back (`a delta does not repeat the room from its creation`), no `rooms.leave` on device B, 15 s / 10 s waits instead of an immediate answer, no advisory lock (second writer not blocked), docs rows not closed. The static tests also run (red) without a DB in the unit job; the new functions are called through `apply/3` in the store test so the red suite COMPILES under `--warnings-as-errors` (a missing function is the test's `UndefinedFunctionError`, not a compile error).

## Green evidence (throwaway reference implementation, copy `.../scratchpad/ref-fd/`)
- Elixir 1.20.4: the 5 new files `145 passed`; plus the 3 amended files 135/135; the wider run (docs suites, account data, cross-signing, room account data/tags, session, sync, partition, wake-up cluster unit, legacy logout, device teardown, oauth logout) green except files that need repo files outside my partial copy (later copied) .
- Elixir 1.19.x (`elixir:1.19-alpine`, `--warnings-as-errors`): `145 tests, 0 failures`.
- Full server suite on the copy (1.20, `--include integration`, `regression_sync_load_test.exs` parked): `10790/10817 passed, 27 failed`; 21 of the 27 are the known flaky families (WarRoom, TemporaryCapture, AdminOidcLogin, LogStore retention, RoomsFallbackName, TraceMap), the other 6 were the 2 statement-count pins + the 2 sync_membership_partition tests described above (amended in the worktree, then 135/135 green) plus nothing else.

## Mutation check (reference copy, 3 files: http + store + dispatcher; every mutant killed)
| mutant | killed by (count) |
|---|---|
| M01 nextval only on insert (ON CONFLICT branch without stream_pos) | 6 (store overwrite / identical / list_since / pending; HTTP overwrite) |
| M02 single shared position for both columns | 2 (HTTP two-columns-independent, HTTP first-sync positions) |
| M03 flag cleared by a bound device | 3 |
| M04 `''` row used by a bound device (core called with `""`) | 36 |
| M05 no wake-up | 5 (store x3, HTTP wake-up x2) |
| M06 no own user on a fallback | 8+ |
| M07 nil-anchor write in the fallback | 6+ (spy x3, HTTP) |
| M08 no advisory lock | 4 (lock key, serialisation, shared lock) |
| M09 no pending check | 2 (HTTP immediate answer, no spin) |
| M10 advance without token guard / M11 advance inserts an orphan row / M12 advance without GREATEST / M13 token upsert resets positions | 1 / 1 / 1 / 2 (store `PgStore` tests; M13 also the failure-direction HTTP test) |
| M14 wake-up sent before the commit | 1 (deferred commit trigger test) |
| M15 list_since ignores pos | 31 |
| M16 fallback does not read all account data | 1 |
| M17 client position suffix trusted for the account data position | 1 (forged suffix) |
| M18 put_keys update branch without a new changed_pos | 2 |
| M19 lock key is the room store key | 2 |
| M20 / M21 cross_signing_pos / account_data_pos never advanced | 6 / 12 |
| M22 device-less path reads by position instead of the flags | 1 |
| M23 pending check always true (timeout always 0) | 4 |
| M24 own user also put in `device_lists.left` | 4 |
| M25 initial sync ignores the device id | 49 |
Mutation logs: `.../scratchpad/mut_*.log`, driver `.../scratchpad/mutate.py`.

## Reference implementation (throwaway, NOT for commit)
Lives in `/private/tmp/claude-501/-Users-philippbeyerlein-dev-01-gitlab-1200-philippb-open-chat/03948291-8a7d-43d3-8355-51b78b3be62a/scratchpad/ref-fd/`; the diff against the worktree (lib, priv, proto, 3 docs) is `reference-impl.diff` next to this report: 684 diff lines, +298 / -103, 13 files (migration 000052 up/down; `AccountDataStore`, `CrossSigningKeyStore`, `PgStore` + `Postgres`, `protected.ex` `do_sync` / `finish_sync` / `put_global_deliveries`, `server.ex` `initial_sync` + `fallback_to_initial_sync`, `core.pb.ex`, `core.proto`, follow-ups `fd` row, 07-deployment, matrix-api-scope). Ref specifics the dev can reuse: the two new `PgStore` callbacks are `@optional_callbacks` and the facade guards with `function_exported?` (the fakes in `session_supervisor_test.exs` / `pg_store_test.exs` use `@behaviour` and would warn under `--warnings-as-errors` otherwise); `put/3` and `put_keys/2` raise on a failed write (as before: MatchError).

## Contract choices the tests pin (taken literally from the story; the dev may not rename)
`AccountDataStore.list_since(user, pos) -> {latest_pos, [{type, content_map}]}` (oldest first; `{0, []}` without rows), `pending_since?/2`; `CrossSigningKeyStore.changed_since?(user, pos) -> {changed_pos, boolean}` (`{0, false}` without a row); `PgStore.get_positions(user, device) -> {ad, cs}` (bare tuple, `{0, 0}` without a row), `PgStore.advance_positions(user, device, token, ad, cs) -> :ok`; lock key `hashtextextended('sync_global|' || user_id, 0)`; wake message `{:account_data_changed, nil}`; sequence `sync_global_pos_seq`; migration found by name `*_sync_device_positions` (number >= 52).

## Story gaps / ambiguities and proposed amendments
1. **Initial sync (no `since`) and `cross_signing_pos`.** D9/D10 only say "a device-bound fallback also advances cross_signing_pos". The tests pin that EVERY initial-shaped answer (also a real initial sync) sets `cross_signing_pos = current changed_pos` and `account_data_pos = highest delivered` (otherwise the first delta of a fresh device lists the own user spuriously). Amend D9 (4) / D10: "an initial-shaped response, with or without a since, advances both columns".
2. **`advance_positions` token.** The guard token is the CORE token (`sync.since_token`, without the `.<pos>` suffix), which is what `sync_tokens.since_token` holds. State it in D9 (4).
3. **Return shapes** (`{ad, cs}`, `:ok`, `{pos, []}` on a failed read, `{0, false}`): the story names only the first. Amend the Sizing text with the shapes above.
4. **Statement-count pins** of two existing suites (+3 per `/sync`) and one existing wait assertion (D11) change: add them to "Sizing" / DoD so the dev does not meet them as a surprise (amended here, see above).
5. **Behaviour callbacks.** New `@callback`s on `Nebu.Matrix.Session.PgStore` break the `@behaviour` fakes under `--warnings-as-errors`: use `@optional_callbacks` (or extend the two fakes). Add to Sizing.
6. **`device_lists` for an initial sync** is `{"changed": [], "left": []}` (Nebu always sends the object); the story says "no device_lists entry". The tests assert the empty arrays.
7. **User without any event** (nil anchor is legitimate): Scenario 7 "never an empty anchor" holds only for users with events; tests only cover users with rooms. Clarify.
8. **D10 for device-less requests** (open question in the story): pinned as ADDITIVE for both (a device-less fallback with since lists the own user AND still consumes the flag). If the owner restricts D10 to bound devices, change `Scenario 8` tests "D10 device-less fallback" and the HTTP fallback test of the unbound JWT.
9. **Open question on the lock/transaction cost** (story "Open Questions"): pinned as acceptable (lock + transaction per PUT / cross-signing upload, one key for both tables).
10. `regression_sync_load_test.exs` (parked in CI runs) syncs with legacy sessions: with this story every device long-polls / holds a row; not run here.
11. The in-flight orphan row (cj (a), accepted) is not tested; only `advance_positions` never inserting a row is pinned (so the orphan can only come from the core's token upsert).
12. A device that is removed by the 000052 down migration loses only the new columns (tested on a populated schema); the story's "grants as in 000039 if the role needs them": the tests require `USAGE` on the sequence for `nebu_app` (the writer draws as `nebu_app`).

## Operational notes
- The throwaway `nebu-oauth-pg` container (`.oauth-ci/quick.sh`) is still running and migrated WITHOUT 000052 (red state). After the dev adds the migration: `docker rm -f nebu-oauth-pg` so it is re-created (as every migration test header says). `.oauth-ci` was not touched; my own reference containers (`atdd-fd-pg`, network `atdd-fd-net`) are removed.
- Pre-existing flaky families seen in the full run on the copy: see above (not related to this story).
