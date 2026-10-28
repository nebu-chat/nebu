# ATDD fix pass: sync-token-per-device (after test-review-findings.md), 2026-10-26

Only `server/test/` changed (no lib / priv, docker only through `.oauth-ci/quick.sh` and my own throwaway ref containers, which are removed again; no `Node.start`). Nothing committed.

## Fixed findings

| finding | fix |
|---|---|
| M1 (`sync_membership_partition_http_test.exs`, AC22 503 test, vacuous after the implementation) | `stored` reads `sync_tokens` by `user_id` only; added `assert [_] = before` (precondition, so it cannot go vacuous again) |
| M2 (AC10 timing margin) | `timeout: 5_000`, `assert ms < 2_500` (comment says why) |
| m1 | `wait_polling/1` budget 3_000 -> 10_000 |
| m2 | Scenario 2 (leave / kick / ban): after the cause one more message by the room owner; on both devices the message is NOT in the leave timeline, the member event of the user is the LAST event of the window, `rooms.join` does not carry the room |
| m3 | store test: static greps reduced to `refute get_local_members` in both store sources (plus a "source was read" control); docs test "code docs" reduced to `stream_pos` / `changed_pos` present in the stores (route-layout regex and `list_since` grep dropped); migration test: header pin only names story + sequence, index regex tolerates `public.` and `USING btree` |
| m4 | dispatcher test: new helper `assert_lookups_only_under/2`: every lookup is `{:get, 2, [uid, dev]}` (device-bound) or `{:get, 1, [uid]}` (device-less), no `{:get, 1, _}` / `{:persist, 3, _}` for devices (no `{:get, 2, _}` / `{:persist, 4, _}` for device-less); "exactly one get" no longer pinned (a control asserts at least one lookup happened); D4 "exactly one persist" kept; the ETS table is created in `setup_all` (owned by the module process) and `Spy.log/1` rescues `ArgumentError` |
| m5 | 413 test also asserts `errcode == "M_TOO_LARGE"` |
| m6 | failure-direction coverage extended: HTTP: `sync_tokens` position columns (existing), `account_data.stream_pos` and `cross_signing_keys.changed_pos` hidden (200, nothing read, and the entry / own user arrives with the next sync after the column is back); store: `list_since` is `{pos, []}` and `pending_since?` false, `changed_since?` does not raise and reports no change, `get_positions` `{0, 0}` and `advance_positions` returns instead of raising, each with a "works again afterwards" control. The rename helper `with_hidden_columns!/2` (HTTP + store) restores in `after` AND in `on_exit`, checks via `information_schema` whether the hidden name still exists and re-raises when the restore fails (no `rescue _ -> :ok` any more). Verified: after the red run no `fd_hidden_*` column is left in the throwaway DB |
| m7 | HTTP Scenario 5 describe renamed ("... (stochastic)"), comment and moduledoc say the deterministic interleaving test lives in the store test (it replays the route's read / advance order against the store primitives) and that the route wiring is caught by the position VALUE assertions |
| m8 | comments of the statement-count re-pins corrected (initial: `get_positions` + `changed_since?` (new, the flag was only read with a since) + `advance_positions`; incremental: `get_positions` + `pending_since?` + `advance_positions`, `changed_since?` / `list_since` replace `consume_changed_flag` / `list_changed_and_clear` 1:1); the `member_prev_content_http_test.exs` assertion message no longer says "baseline of the code before the story: 57" |
| optional | new HTTP test "two users with the SAME device id string keep separate rows and tokens" (describe "the key is user + device") |
| m9 / INFO | nothing (as agreed) |

## Counts
New suite: 145 -> 152 tests (HTTP 53 -> 57: +2 failure-direction, +1 same-device-id, one existing failure test reworked; store 41 -> 44: +3 failure-direction tests, 2 static tests merged into 1; dispatcher 15; docs 17 -> 16; migration 19). All names < 200 chars incl. describe (max 199; checked with a stricter variant of namelen).

## Evidence
- Reference implementation (scratchpad `ref-fd`, unchanged lib): Elixir 1.20, `--warnings-as-errors`, `--include integration`, the 5 new + 3 amended files: `Result: 284 passed`.
- Worktree (red), same files, `--warnings-as-errors` (compiles, 0 warnings): `Result: 161/284 passed, 123 failed` = migration 18, docs 8, dispatcher 12, HTTP 46, store 36, plus the 3 amended existing tests (AC10 D11, member_prev statement count, history_visibility statement counts). The reds are the story's missing features (missing migration / columns, undefined functions, `device_id` field, per-user key instead of device key, no wake-up, ...). The AC22 503 test (M1) stays green before and after by design (it is the vacuity fix with a precondition, meaningful in both states).
- Mutants (reference copy, http + store + dispatcher files), all killed: M04 `''` row used by a bound device 74/114 passed (40 killers); M06 no own user on a fallback 106/114; M07 nil-anchor write in the fallback 107/114; M22 device-less path by position instead of flags 113/114 (1 killer); NEW M26 `list_since` raises on a failed read 112/114, M27 `changed_since?` raises 112/114, M28 `pending_since?` raises on a non-ok result 112/114 (the new failure-direction tests). Earlier M01-M25 results in `atdd-report.md` remain valid for the unchanged killers.

## Notes
- `nebu-oauth-pg` (the `.oauth-ci/quick.sh` throwaway DB) is still running and migrated WITHOUT 000052; `docker rm -f nebu-oauth-pg` after the migration is added.
- The `with_hidden_columns!` tests take an ACCESS EXCLUSIVE lock briefly on `sync_tokens` / `account_data` / `cross_signing_keys` on the shared test database: they are in `async: false` modules, like the rest of the suite.
