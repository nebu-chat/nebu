# Code review: sync-stream-position, cycle 0 (2026-10-27)

Scope: staged diff in worktree open-chat-oauth (HEAD e066d6f3), production files + the two re-pinned test files. Read-only; no test was run (no docker). Reviewed against D1-D21, the dev report (section 2 deviations, section 5 notes), ADR-018/020, cluster-safety, no-sensitive-data-in-logs law.

Verdict: 1 MAJOR, 5 MINOR, 8 INFO.

Verified clean (no finding): migration 000054 (idempotent IF NOT EXISTS, FK to the (user_id, device_id) PK with ON DELETE CASCADE, constant defaults = catalog-only, grant, down order table-then-columns, no events lock); `room_heads/3` (one statement, caller's key only, `[]` = no statement); `fetch_visible_events_in_range/5` (hv predicate per row, `room_pos` range, NULL positions excluded, hidden rows do not count, `limit + 1`); `leave_window_events/5` (placeholder order matches the caller, positions strict, clock bounds only shrink, nothing at/after L); token `s2_` (strong_rand_bytes(16), compared only with the authenticated key's row, never reaches SQL unless it equals the current/previous token); guarded UPDATE semantics (READ COMMITTED re-check = D7 guard, no INSERT, D20(4)); `write_sync_cursors_sql` (DELETE and upsert touch disjoint rows, empty arrays fine); no tokens/cursor values/ids/content in the new log lines; `visible_page!` head bound param numbering; proto/pb parity. The dev's deviation 2.3 (base value instead of stored value for kept rooms on a previous-token request) is CORRECT: on a retry the lost response's position must not become the new base; with the base value both a current-token request (base == stored, no write) and a retry (stored position of the lost generation replaced by the base, `gen == generation` re-base) deliver everything the client never received; the only cost is a repeat of events the client provably never got. I found no lost event and no duplicate caused by it. Agree it is untested; see MINOR-5.

---------------------------------------------------------------------------------------------------------------------------------

## MAJOR

### MAJOR-1  A second request built from the same base token can silently replace the first one's token and lose the events the first one advanced the cursors past (cj (b) residual is silent LOSS, not "fallback")

Files: `server/lib/nebu/matrix/session/pg_store/postgres.ex:64-77` (guard `WHERE ... (since_token = $3 OR prev_since_token = $3)`), `server/lib/nebu/matrix/event_dispatcher/server.ex:5963-5972` (`ctx` is captured ONCE before the long poll: `base`, `generation`), `:6129-6149` (`cursor_base/2`, `write_cursor?/3`), `:6158-6196` (`build_delta/3` reads the cursor rows fresh on every build but interprets them with the stale `ctx`).

Failure scenario (the "client retries while the abandoned request is still alive behind the proxy" case D8 exists for):
1. Device holds T (generation g). R1 (token T) is long-polling. The client's connection drops, the client retries: R2 (token T). Both are alive on the server; R2's `get_since_token` ran while the row still held T, so `ctx.base = :current`.
2. Event E lands in room B (cursor 5, head 8). R1 builds, delivers 6-8, commits: token T1 (prev = T), cursor B = 8, gen g+1. R1's response goes nowhere.
3. R2 rebuilds after the wake (or its first build runs after R1's commit): `room_heads` returns the cursor row written by R1 (B = 8). `cursor_base` answers its CURRENT values (the `:previous` branch needs `ctx.base == :previous`) -> base 8 -> `head > base` is false -> nothing delivered for B, no cursor write for B (value == stored). R2 returns at once (a woken build returns whatever it has) with an empty response.
4. R2's persist: guard `prev_since_token = T` matches (R1's write left T as previous), the row becomes T2 (prev = T). The client receives R2's response with T2 and continues from cursors that already moved past 6-8. Events 6-8 are never delivered. No fallback, no error, no log line.

The old timestamp design re-read from the same anchor in R2 and delivered E again; this is a regression for a (narrow but realistic: ALB in front, 25 s polls, mobile networks) concurrent-retry path and it is exactly the "lost events across consecutive syncs" class the story closes. D21(5) accepts "the second request replaces the first one's token" but describes the outcome as the first one's token becoming unknown; the real outcome is the second one's response being built from cursors the first one advanced. The story text, `follow-ups.md` `cj` note ("only one token survives the guarded write, the other one falls back") and 06-runtime ("otherwise nothing is written and the next request falls back") all promise a fallback, not a loss.

Suggested fix (either is small):
 (a) Make the guard compare-and-set on what the request was built from: pass `ctx.generation` into the spec and require `generation = $expected` in `@advance_sync_generation_sql`. A concurrent winner makes the second `:stale` (nothing written, response sent, token unknown -> the client's next request is the one-time fallback, never a loss). Keeps D8 (sequential retry: generation unchanged between read and write) and the concurrency test (`>= 1` valid token).
 (b) Re-evaluate the base per build: fold `t.generation`, `t.since_token`, `t.prev_since_token` into the `room_heads` statement (or re-read the token row per build) and recompute `:current` vs `:previous` from it; then R2 above becomes a `:previous` request (the row's current token is no longer T), uses `prev_*` values and redelivers E. Costs one join per build, avoids the full-sync cost of (a).
Whichever is chosen: update D21(5), the `cj` note, the 06-runtime sentence and the concurrency test (see MINOR-4). If the owner prefers to keep D21(5) as accepted, the docs must say "may lose" instead of "falls back". Owner decision.

---------------------------------------------------------------------------------------------------------------------------------

## MINOR

### MINOR-1  Initial sync / fallback writes a cursor row at `head` for join rooms that were NOT delivered (killed 10 s task, `:exit` -> `[]`)

`server/lib/nebu/matrix/event_dispatcher/server.ex:5242-5245` (`rows` built from `delivery.partition`, every class != :none), against `initial_join_rooms/3` (:5324-5415) whose `on_timeout: :kill_task` / `catch :exit, _ -> []` drop a room from the response ("they re-appear on the next incremental sync", comment at :5331).
Scenario: a room whose fetch is killed after 10 s is missing from the initial response but its cursor is `{head, "join"}`. The next incremental sync only reads `(head, newhead]`: the room stays invisible to the client until something new happens in it (and then arrives without its earlier history); the comment's promise is false. The old design had the same gap for events older than the anchor, so this is not a regression, but D12 makes it trivially fixable.
Fix: build the join rows only for rooms present in `delivery.rooms` (a join room without a row is "base absent" next time: newest 20 from 0 plus `newly_joined_room_ids`, which is the re-appearance the comment promises). Add a dispatcher test with a killed room.

### MINOR-2  Dead map key `unresolved:` in `build_delta/3`
`server.ex:6192` (`unresolved: length(unresolved)`): nothing reads `delivery.unresolved` any more (the only consumer, the global "keep the anchor" branch, is gone; `grep unresolved` shows only the local variable and the log line). Remove the key.

### MINOR-3  Stale anchor prose that contradicts the new design (comment/doc drift)
- `server.ex:5939` "Step 3: Resolve last_event_id from the since_token.": the core no longer reads `last_event_id`.
- `server.ex:6023-6025` (`fallback_to_initial_sync/2` comment: "persists the fresh token ... with the real anchor"), `:5447` ("a row-only invitation never moves the anchor"), helper names `timeline_anchors/1`, `invite_anchors/1` (they now only feed the informational `last_event_id`).
- `server/lib/nebu/matrix/session/pg_store.ex` `@doc` of `get_since_token/1,2` (~line 115: "Returns `{:ok, %{since_token: t, last_event_id: id}}`") omits the three new keys the core reads; `persist_since_token/3,4` (facade + Postgres + callbacks) have NO production caller any more (only fakes/tests); the doc still calls the token "opaque base64".
- `docs/architecture/06-runtime.md:68` ("does not move the since-token anchor") and `:76` ("keeps the anchor pinned") are only half corrected by the new paragraph at :78-97; `:311-313` (blockquote) still describes the anchor semantics with a note below it.
- `server/lib/nebu/matrix/room/server.ex:529` and `:1099` ("detects the join via fetch_events_since" / "GetSyncDelta / fetch_events_since can detect the membership change"): untouched by the diff but now false.
Fix: one comment pass over these locations.

### MINOR-4  The concurrency test encodes the MAJOR-1 hole and is racy by construction
`server/test/nebu/matrix/sync_stream_position_concurrency_test.exs:318-340`: "every response carries the news" for two simultaneous same-token requests only holds if both read the cursor rows before either commits; if R1's persist wins the race to R2's `room_heads`, R2 legitimately returns no news (MAJOR-1) and the test fails (flake) or, after a fix, must change. The final assertion checks only the surviving token, not that nothing was lost between the two responses. After MAJOR-1 is decided: assert "the union of what the responses delivered covers the news" for a sequence that forces R2's cursor read after R1's commit (hold R1's persist with a second connection), and keep the `>= 1 valid token` assertion.

### MINOR-5  Contradictory pin comments in the two re-pinned test files; deviation 2.3 has no test
- `server/test/nebu/matrix/history_visibility_http_test.exs:~869-880`: the pin keeps the ATDD "reference design" block ("MEASURED on the reference implementation ... 48 -> 51, 51 -> 54 ... the implementer re-pins them if the statement shape differs") directly above the dev's block ("51 -> 50, 54 -> {30, 0}"); a reader sees two sets of "measured" numbers and a retired design. Delete the reference-design block, keep one old -> new line (original 48/51 -> final 50/{30, 0}).
- `server/test/nebu/matrix/member_prev_content_http_test.exs:52-57`: same pattern (57 -> 60 reference, then 60 -> 59). One line: 57 -> 59.
- The keyword-list reorder in `history_visibility_http_test.exs` is correct and valuable (the old incremental pins were fallback counts); `Enum.take(-20)` and the `v1_` prev_batch assertions match `encode_token/2`. The test rebuilds the token by hand instead of asserting a round trip through `/messages`; the new http suite covers the round trip, so acceptable.
- Deviation 2.3 (dev report section 5) is untested. A dispatcher test (fake db with an unresolvable joined room, retry with the previous token after a generation that advanced that room) would pin it; recommended given its subtlety.

---------------------------------------------------------------------------------------------------------------------------------

## INFO

1. **Head is read after the partition (invite / leave classes).** `build_delta/3` and `initial_sync/2` take `heads` after `sync_partition/1`; for an invite or leave row the cursor becomes `{head, class}` where `head` may include member events committed in that gap (e.g. the user's own join). The next sync is then "newly joined" with a range above that head: the join event itself is missing from the timeline (state still carries it, `newly_joined_room_ids` still fires). Benign, but worth one sentence in `cq` (a).
2. **The cursor statement runs on every sync, also a no-op.** `persist_sync_position/3` always executes `@write_sync_cursors_sql` (a DELETE probe plus an empty upsert). Skipping it when `rows == []` and `keep` equals the stored room set would save one statement per quiet long-poll. Not required by the story (D14 counts it).
3. **Range read scans the hidden stretch.** `fetch_visible_events_in_range/5` filters `@sql_hv_visible` per row in `room_pos DESC` order; a rejoin into a `joined`-visibility room (class change, range from the old leave position) with fewer than 21 visible events scans the whole hidden range once. The page reads were deliberately segment-driven to avoid that (`gk`). One-time per class change, no statement timeout on `/sync` reads by design (`gk` (4)); consider noting it under `cq`/`gk`.
4. **Legacy events never in an incremental range.** A newly joined room (base absent) of a pre-000053 room delivers only positioned events; no `limited`/`prev_batch` is set for the older history. Same as the old behaviour; documented as `cq` (c).
5. **`Nebu.Matrix.Room.DB.pagination_token/1` is called directly** from `server.ex` (fetch_delta_rooms, build_leave_room) while neighbouring reads go through the injectable `messages_db_module()`. It is pure so tests are unaffected; consistency only.
6. **Sequential range reads.** `fetch_delta_rooms/4` reads moved rooms one after another (no N+1 for quiet rooms; N statements for N moved rooms, D14 accepted). The initial sync's `Task.async_stream` could be mirrored if a busy user shows latency.
7. **Cursor growth.** `room_heads/3` and the cursor rows include every non-forgotten leave room (partition class `leave`) per device, on each sync and each wake rebuild; bounded by `cq` (d), mentioned for capacity planning.
8. **Proto formatting.** `proto/core.proto` field 7 is not column-aligned with fields 1-6 (cosmetic).

Compile/format: no `.formatter.exs` in `server/`, formatting is not enforced; I did not run a compile (the dev's unit job reports no warnings with `--warnings-as-errors`).

---------------------------------------------------------------------------------------------------------------------------------

## AC / decision coverage

AC (a)-(d), two-writers, skew, fallback-once, retry with previous token, leave window (leave/kick/ban), invitations once, newly joined with account data, quiet rooms/no anchor read, hv window: all have an implementation path matching D4-D13 and a staged test; the only AC clause whose guarantee is weaker than stated is "a retry ... continues incrementally" under CONCURRENT same-token requests (MAJOR-1). D7 deviation (single guarded UPDATE instead of SELECT ... FOR UPDATE) is sound. D13 per-room unresolved handling and the `moves_cursors?` re-read condition are correct.
