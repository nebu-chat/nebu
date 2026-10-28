# Dev report: sync-token-per-device, fix cycle 1 (after code-review cycle 0), 2026-10-26

Scope: the 6 MINOR findings (m1-m6) plus i6 from `code-review-findings.md`. Not done, as instructed: i3, i5, i8, i9, and no new follow-up rows. Nothing is committed. All changes are re-staged with `git add docs proto server`. No existing assertion was weakened. Tests were only added or tightened.

## m1: failed account data read in an initial-shaped answer (real fix)

**Design (the smaller of the two options):** the device's `account_data_pos` is set back to 0 only when the read FAILED in an initial-shaped answer. A successful read keeps `GREATEST`.
- `AccountDataStore.list_since_checked/2` is new and public. It returns `{:ok, latest_pos, entries}` or `:error`. It never raises on a database error.
- `list_since/2` keeps its contract (`{pos, []}` on a failed read) and now delegates to `list_since_checked/2`, so the existing tests are untouched.
- `PgStore.rewind_account_data_position/4` is a new optional callback, with a facade guarded by `function_exported?` like the other two. `Postgres` implements it as:

  ```sql
  UPDATE sync_tokens
     SET account_data_pos = 0,
         cross_signing_pos = GREATEST(cross_signing_pos, $4)
   WHERE user_id = $1 AND device_id = $2 AND since_token = $3
  ```

  It is a plain SET, uses the same token guard and never inserts a row.
- In `protected.ex`, `put_global_deliveries/6` picks one of three cases:
  - **read ok:** `advance_positions` as before.
  - **`:error` in an initial-shaped answer:** `rewind_account_data_position` (that answer delivered nothing, and its client may have reset its state).
  - **`:error` in a true delta:** `advance_positions` with the unchanged `ad_pos`. The client still holds the older rows, so the newer ones come with the next sync.

**Why it is safe:**
- The write is guarded by `since_token = <this response's core token>`. Only the single response that carries that token can write, so lowering the column races with no other writer (the reviewer's point).
- The rewind direction is "deliver again". Its worst case is one response with all of the user's rows.
- Statement count is unchanged: the rewind REPLACES the advance, so the +3 pins still hold.

**Why not "write the read value without GREATEST on every initial-shaped answer":**
- It would change the success path too, which is otherwise identical.
- It still needs a special value for the failed read.

## m2: migration comment and release note

- **Migration comment** (`000052_*.up.sql` header): the wrong "rolling deploy" claim is replaced. The comment now states:
  - the volatile `DEFAULT nextval` rewrites `account_data` (TOAST included) under ACCESS EXCLUSIVE;
  - the index is built non-concurrently in the same transaction;
  - the other three columns are catalog-only;
  - old nodes do not crash but are not correct writers: an overwrite keeps the old `stream_pos`, `put_keys` stamps no `changed_pos` and takes no lock;
  - deploy without a mixed-version window, or accept that.
- **Release note** (`07-deployment.md`, release note (3a)): new sentences "*Migration 000052, locks and duration:* ..." and "*No mixed-version window:* ...", in the style of the 000051 note (maintenance window, every global account data read and write waits, no lock timeout).

## m3: logging in the cross-signing error branches

- The first-upload branch logs `cross-signing key write failed: <kind>`.
- The m.oauth replacement branch logs `m.oauth cross-signing key write failed: <kind>`.
- Both use `error_kind/1`: the struct module or an atom, never a message, key material or content.

## m4: tests for the error branches (blocked-trigger technique)

- **HTTP**, `sync_token_per_device_http_test.exs`, describe "failed writes answer 500 M_UNKNOWN and log only the error kind":
  - Global account data PUT blocked:
    - `500 M_UNKNOWN`, the response body does not contain the content.
    - The `capture_log` output contains `global account data write failed: Postgrex.Error`, and contains neither the content nor the error message ("write blocked").
    - No row and no `{:account_data_changed, _}` is written or sent.
    - Once the trigger is removed, the PUT works and the sync delivers the entry.
  - First cross-signing upload blocked:
    - `500 M_UNKNOWN`, the log has the kind and no key material or message.
    - Nothing is stored and the own user is not listed.
    - It works after removal.
- **Replacement path**, a new test in `server/test/nebu/oauth/oauth_account_cross_signing_test.exs` next to Must #26, using `T.block_cross_signing_writes!`:
  - `500 M_UNKNOWN`, the log has `m.oauth cross-signing key write failed: Postgrex.Error` and no key material or message.
  - The keys are unchanged and `changed_pos` is unchanged (`changed_since?/2`).
  - The approval is not consumed (`T.uia_row(sid)["consumed"] == false`), and the same approved session gives 200 after the trigger is removed.
- **Store test tightened:** the "failed write sends NO wake-up" test now asserts `{:error, _} = outcome` (was `refute outcome == :ok`).
- **m1 tests:**
  - HTTP, two variants (no-since initial sync and stale-since fallback):
    - `stream_pos` is hidden with `with_hidden_columns!`; the answer is 200 with no `account_data`.
    - The row's `account_data_pos` becomes 0 and holds that answer's token.
    - With the column back, the next delta delivers EVERY row, and the delta after that delivers nothing.
  - HTTP control test: a failed read in a TRUE delta keeps `account_data_pos`.
  - Store tests:
    - `list_since_checked` returns ok, `:error` while the column is hidden, and works again afterwards.
    - `rewind` with a foreign token changes nothing; with its own token it is a plain SET to 0 and `cross_signing_pos` is never lowered (GREATEST).
    - `rewind` never inserts a row and never touches another device, the `''` row or another user.
    - `rewind` returns `{:error, _}` (never raises) while the columns are hidden.

## m5: docs drift

- `08-concepts.md` (Incremental /sync per device): the core token is stored per authenticated device; per user only for device-less clients.
- `06-runtime.md` (cross-signing replacement sequence): the write sets the flag and, under the `sync_global|` lock, a new `changed_pos`, so every device lists the OWN user once. The wrong "peers" wording is gone.
- `05-building-blocks.md`:
  - The global account data note names `put_global_deliveries/6` (was `put_global_account_data/3`) and limits the flag description to DEVICE-LESS requests.
  - The cross-signing note gets the same qualification.
  - The story note lists `list_since_checked/2` and `rewind_account_data_position/4`.

## m6: test prose

- "RED-phase acceptance tests" now reads "Acceptance tests" in the headers of all 4 files (store, dispatcher, http, migration).
- The `apply/3` indirection in the store test is replaced by direct calls, and its comment now just says what the helpers are.

## i6

The `@doc` of `put/3` now says it must NOT be called inside a surrounding transaction, and why: the wake-up would precede the outer commit, and the lock would be held until that commit.

## Test evidence

- **Targeted run**, Elixir 1.20, `--warnings-as-errors --include integration`: the 5 new files, the 3 amended files and `oauth_account_cross_signing_test.exs`. Result: **333 passed**.
  - That is the 284 from cycle 0 + 11 new in the story files + the oauth file. Migration up/down round trip included.
  - One intermediate run passed but aborted on a type warning in my new test (`since == :none`). Fixed by using `nil`, and the rerun was clean.
- **Unit job**, Elixir 1.19-alpine (`unit_nodb.sh 1.19-alpine`): **6576 tests, 0 failures**, 7 skipped.
- **namelen:** no name of the touched files is at or above 230 characters.
  - I also checked the `test "...", ctx do` form, which `namelen.py` does not match: the new oauth test name is 204 characters.
- **Full suite**, 1.20, DB reused: **10807/10832 passed, 25 failed:**

  | Count | Test module | Family |
  |---|---|---|
  | 12 | RoomsFallbackName | known flaky |
  | 3 | TraceMapNodeControls | known flaky |
  | 1 | WarRoom | known flaky |
  | 2 | TemporaryCapture | known flaky |
  | 1 | AdminStaleRooms | known flaky |
  | 1 | LogStore.RetentionTest | known flaky (LogStore) |
  | 1 | OidcPlugTest denylist | known flaky (reused DB) |
  | 1 | MatrixSsoTest | known flaky (MatrixSso/SsoLogin) |
  | 1 | SsoLoginTest | known flaky (MatrixSso/SsoLogin) |
  | 1 | RegressionSyncLoadTest | parked, fails on HEAD too |
  | 1 | MemberSliceGateTest | see below |

  - **MemberSliceGateTest** "throughput sanity: 500 readers ... at least 60 % of the ideal" failed with "completed 251 reads in 1 s, ideal 434". This is a wall-clock throughput test under full-suite load, and the slice gate is untouched by this story. **Rerun alone: 13 passed.**
  - The cycle-0 AC20 fixture flake did not recur in this run.

## Notes for the reviewer

- The new optional callback is the third one on `PgStore`. The Spy of the dispatcher test does not implement it, so the facade answers `:ok`. That is fine: the dispatcher tests do not cover position semantics.
- The fd row in `follow-ups.md` was not changed in this cycle (no new rows, as instructed).
