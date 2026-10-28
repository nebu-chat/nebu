# Code review delta: sync-token-per-device (follow-up `fd`), cycle 1, 2026-10-26

**Verdict: APPROVE. 0 MAJOR, 0 MINOR, 6 INFO.** All cycle-0 findings (m1-m6, i6) are resolved correctly, nothing regressed, and the m1 rewind adds no new spin class beyond i3.

Scope: `git diff --staged` in the worktree `open-chat-oauth` (27 files, 3 more than cycle 0: `oauth_account_cross_signing_test.exs` and the staged security report, `docs/stories/oauth-broker/security-reports/sync-token-per-device-security-review-2026-10-26.md`). Input: `dev-report-cycle1.md`. No docker, no tests run; the dev reports 333 targeted (1.20) and 6576 unit (1.19) green.

## Cycle-0 findings: status

| id | status | evidence |
|---|---|---|
| m1 failed initial-shaped read never lowers `account_data_pos` | RESOLVED | `protected.ex` l.290-316: three-way `case`. `postgres.ex` `@rewind_account_data_position_sql`. `account_data_store.ex` `list_since_checked/2`. |
| m2 migration comment / release note (rewrite, lock, mixed version) | RESOLVED | `000052_*.up.sql` header l.17-23; `07-deployment.md` release note (3a): "Migration 000052, locks and duration" and "No mixed-version window" |
| m3 silent 500 on a cross-signing write failure | RESOLVED | `protected.ex` l.2904 and l.3035: `error_kind/1` only |
| m4 error branches untested | RESOLVED | HTTP describe "failed writes answer 500 M_UNKNOWN ..." (2 tests); `oauth_account_cross_signing_test.exs` Must #26 addition; store test now `{:error, _} = outcome` |
| m5 docs drift (08 l.1343, 06 l.1772, 05-bb l.2000) | RESOLVED | all three edited, plus the 05-bb cross-signing note qualified |
| m6 RED-phase prose | RESOLVED | headers say "Acceptance tests"; `apply/3` replaced by direct calls |
| i6 `put/3` must not be nested | RESOLVED | `@doc` of `put/3` |

## (a) m1 design: path-by-path

1. **Read ok:** `advance_positions(user, dev, core_token, max(ad_latest, ad_pos), cs_target)`. This is identical to cycle 0 (GREATEST, token guard).
2. **`:error` in an initial-shaped answer:** `rewind_account_data_position(user, dev, core_token, cs_target)`, which runs `SET account_data_pos = 0, cross_signing_pos = GREATEST(cross_signing_pos, $4) WHERE user_id AND device_id AND since_token = $3`. The answer delivered no `account_data`, so 0 is exactly right.
3. **`:error` in a true delta:** `advance_positions(..., ad_pos, cs_target)`. This equals cycle 0 (`max(ad_pos, ad_pos)`), so the client keeps its older rows and the newer ones come next time.

- **Race safety:** the plain SET is guarded by the token of THIS response. Only the request that just persisted that token can match. A concurrent request of the same device either replaced the token (so this write is a no-op and the other response writes its own) or comes later with this token after the response (so it reads the rewound value). There is no interleaving that lowers a position delivered by a DIFFERENT response.
- **No insert:** it is an UPDATE only, with no orphan for a deleted device (store test: "never inserts a row and never touches another device, the '' row or another user").
- **`cross_signing_pos`:** GREATEST is kept, and `cs_target` is computed once before the branch, so the device-list semantics are unchanged.
- **Statement count:** the rewind REPLACES the advance (one write in every branch), so the +3 pins still hold. The http/member re-pins are unchanged and the dev's runs are green.
- **Spin / hot loop:**
  - After a rewind, the next request with that token runs `pending_since?(user, 0)`.
  - If the account data table is readable again, it is true: `timeout_ms = 0`, then `list_since_checked(0)` delivers every row and advances. One immediate answer, then normal long-poll. Bounded.
  - If the read still fails, `pending_since?` uses the same column and table, so it fails too and answers `false` (its failure direction). The request long-polls; no loop.
  - A loop needs a persistent SPLIT where the `LIMIT 1` probe succeeds but the full read fails. One example is a statement timeout on a user with many large rows. In that case each answer returns at once, and the client loops up to the 600/min limit.
  - That split already existed in cycle 0 for a true delta (failed list keeps `ad_pos`, pending stays true) and is the i3 class. The rewind only widens the trigger from "rows above P" to "any row" for the same split. Not a new class: see INFO d1.
- **`list_since_checked/2`:** returns `:error` for `{:error, _}` and `:repo_not_started`. It still raises on a corrupt `content_json` (`Jason.decode!`, cycle-0 i5). Its `@doc` now says "never raises on a database error", which is accurate.

## (b) m3 log lines

`"cross-signing key write failed: #{error_kind(reason)}"` and `"m.oauth cross-signing key write failed: #{error_kind(reason)}"`. `error_kind/1` yields a struct module name, an atom or `"error"`. There is no message, no key material, no user id and no token. The tests assert the positive line AND refute the key material and the trigger message (`write blocked`), so the refutes are not vacuous: the trigger message would be present if the reason were logged with `inspect`.

## (c) New tests: meaningful?

- **m1 HTTP (no-since and stale-since):**
  - The precondition is pinned (`ad_before == max_ad_pos and > 0`), so the `{0, _}` assertion fails against the cycle-0 code: not vacuous.
  - The row-holds-this-answer's-token check proves the guard matched.
  - Then every row is delivered once, and then not again.
- **True-delta control:** `{^ad_before, _}` plus delivery of only the newer row. This proves the third branch does not rewind.
- **Store:**
  - `list_since_checked` covers ok, `:error` while the column is hidden, and back to ok.
  - `rewind` with a foreign token changes nothing; with its own token it is a plain SET to 0 and `cross_signing_pos` is never lowered.
  - It never inserts and never touches other rows, and returns `{:error, _}` while the columns are hidden.
- **500 tests:**
  - Global PUT: status, errcode, no content in the body or log, the kind is in the log, no row, no wake (`refute_receive`), and it works after the trigger is removed.
  - First cross-signing upload: the same, plus `stored_master == nil` and the own user not listed.
- **`oauth_account_cross_signing_test.exs`:**
  - The approval-not-burned case is pinned through `T.uia_row(sid)["consumed"] == false`.
  - The same approved session gives 200 after the trigger is removed, so the rollback of `Uia.consume` really happened.
  - `changed_since?` is unchanged (no position stamped by the rolled-back write).
- **`with_hidden_columns!` cleanup:**
  - It restores in `after` AND in `on_exit`.
  - The restore is idempotent: it checks `information_schema` for the hidden name before renaming back.
  - A failing restore raises (not swallowed).
  - The suite is `async: false`, so the DDL rename does not hit concurrent tests of this module.
  - `block_writes!` / `T.block_cross_signing_writes!` register `on_exit` removal.

## (d) Docs and migration comment accuracy

- The migration header correctly states:
  - the volatile-default rewrite (TOAST included) under ACCESS EXCLUSIVE;
  - the non-concurrent index;
  - the three catalog-only columns;
  - that old nodes are incorrect writers (overwrite keeps `stream_pos`, no `changed_pos`, no lock);
  - "deploy without a mixed-version window". The false "keeps working" claim is gone.
- The release note matches the 000051 style (maintenance window, no lock timeout, grows with table size). See INFO d3 for the leftover "DDL only, no data statement" parenthesis.
- 08-concepts, 06-runtime and 05-bb are corrected. 05-bb names `list_since_checked/2` and `rewind_account_data_position/4`.

## (e) Regression check against the cycle-0 notes

- The D9 lock and `nextval` in both branches, the two columns, the GREATEST on success, the token guard, never-insert, the post-commit wake via `:pg.get_members/1`, D10, the D11 pre-check and the device-less clause are all byte-identical to cycle 0, apart from the three-way branch.
- No new `:ok =` match or ignored result. No new log line other than the two above. No `get_local_members` in `lib/`.
- The optional-callback facade pattern is extended consistently. The dispatcher Spy lacks the third callback, so the facade answers `:ok`, which is harmless there.
- No unstaged changes under `server/` or `docs/`.

## MAJOR

None.

## MINOR

None.

## INFO

- **d1. The rewind widens the i3 split-failure loop, without creating a new class.** `server/lib/nebu/web/router/protected.ex` l.290-316. After a rewind to 0, a persistent state where `pending_since?` (`LIMIT 1`) succeeds but `list_since_checked` fails makes every device-bound `/sync` with a `since` return at once, until the read recovers. Cycle 0 had the same split for true deltas whenever rows were above `ad_pos`. It is bounded by the 600/min sync limit. Optional, together with i3: skip the D11 pre-check when the previous answer's read failed (that needs a marker; not worth it now).
- **d2. `AccountDataStore.list_since/2` has no `lib/` caller any more.** Only `list_since_checked/2` is used by the route; `list_since/2` is kept as the story's contract for the tests (`account_data_store.ex` ~l.180-198). Its `@doc` ("so the caller's position does not advance ... never miss") describes the cycle-0 route behaviour. Harmless; it could say "the `/sync` route uses `list_since_checked/2`".
- **d3. A small contradiction is left in the release note.** `docs/architecture/07-deployment.md` release note (3a) still says "(... four position columns, DDL only, no data statement)" right before the new "locks and duration" sentence. It is technically true (no DML), but next to "REWRITES the whole table" a reader may misread it. Optional: drop "DDL only".
- **d4. The story text is not amended for the rewind.** `docs/stories/oauth-broker/sync-token-per-device.md` l.263-266 (D9 "Failure direction") and the Sizing contract list (l.177-184) do not mention `list_since_checked/2`, `rewind_account_data_position/4` or the initial-shaped failed-read case. The code, the moduledocs and 05-bb do. Same pattern as earlier stories, where cycle-N fixes leave the AC/decision prose behind. Optional: one sentence in D9.
- **d5. A security report is newly staged.** `docs/stories/oauth-broker/security-reports/sync-token-per-device-security-review-2026-10-26.md` is in the staged set and not in the dev report. It is docs only and was not reviewed here; I am noting it so the commit scope is intentional.
- **d6. The cycle-0 INFO items not addressed by instruction are unchanged:** i3, i5, i8 (story `status: ready`), i9.
