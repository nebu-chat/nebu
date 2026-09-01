# Security Review — media-security-admin-control / 2c-sync-upload-shared-pipeline

**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-14
**Diff scope:** `git diff --staged` — code files only:
- `server/lib/nebu/media.ex` (+106 / −46): `store_upload/4` rewritten (new `create_and_store/6`), new shared `encrypt_compress_and_store/5`, `store_and_quarantine/7` refactored to delegate to it, `insert_media_row/7` removed.
- `server/lib/nebu/media/state_machine.ex` (+88): new `create_quarantined/1` genesis function added alongside `create/1`; `create/1`/`transition/4`/`allowed?/2`/`allowed_transitions/1` untouched.
- `server/lib/nebu/media/db.ex` (+13): doc-only change on `insert/1` (retention-reason comment); no executable change.
- Test files (`media_fakes.exs`, `media_sync_shared_pipeline_test.exs`, `media_sync_state_transition_test.exs`, `media_upload_test.exs`) and non-code artifacts (pipeline-state, step-results, story md) — excluded from finding scope.

**Story:** 2c — a pure refactor. The synchronous upload handler (`upload/1` → `store_upload/4` → new `create_and_store/6`) is rewired to call the SAME shared storage-pipeline function (`encrypt_compress_and_store/5`) that Story 2b's async PUT handler uses, and to create its `media_files` row directly in `:quarantined` via the new `StateMachine.create_quarantined/1` genesis function, replacing the old hand-rolled inline `Crypto.encrypt/3` + `storage_module().put/2` + `DB.insert/1` path.

---

## Verdict: CLEAN — no CRITICAL / HIGH / MEDIUM. Commit not blocked.

Every scrutiny target the coordinator flagged was traced end-to-end in the code and holds. The refactor is not merely neutral — it **closes a real gap**: the old sync path inserted rows via `DB.insert/1` (`@sql_insert`, a 9-column INSERT that does **not** set `state`), so the row took the `media_files.state` column default (`'released'`) and became **immediately downloadable through the Story 1c gate with no scan**. The new path lands sync uploads in `:quarantined` (non-servable until scanned+released), exactly like the async path. This eliminates an unscanned-content-servable window on the synchronous endpoint.

The four findings below are all INFO/advisory. None is exploitable; two are explicit answers to coordinator questions (both favourable), one is a documented data-lifecycle deferral, one is a fail-closed error-contract note carried from the 1b review.

---

## Findings

| # | Severity | Location | Vulnerability / Item | Remediation / Disposition |
|---|----------|----------|----------------------|---------------------------|
| F-1 | INFO (resolved) | `media.ex` `create_and_store/6` + `encrypt_compress_and_store/5`; `state_machine.ex` `create_quarantined/1` | 2b's deferred concurrent-upload TOCTOU (2b F-1): whether the sync refactor creates an equivalent race, or a NEW cross-caller race via the shared function | **Structurally ruled out.** Sync mints a fresh 128-bit `media_id` and INSERTs a new PK per request — no shared pre-existing row to race (unlike async's `/create` reservation). Shared function holds no mutable state; distinct `media_id` ⇒ distinct `storage_key`; a sync id colliding with an async reservation is caught by the PK `unique_violation` → one retry. No new race. See detail. |
| F-2 | INFO (deferred) | `media.ex:218-231` (create-then-store ordering) | Orphaned `:quarantined` row: if `create_quarantined/1` succeeds but `encrypt_compress_and_store/5` fails, the row is stuck in `:quarantined` with placeholder key material and no scan job | Not a security defect — a `:quarantined` row is never servable (Story 1c gate). Not attacker-forceable (persist is a server-side UPDATE on a fresh PK). Documented in-code; deferred to a lifecycle/reaper story (ADR-030). Concur. |
| F-3 | INFO (watch-flag) | `db.ex:196-213` (`insert/1`) | Residual `DB.insert/1` bypasses `StateMachine`: its `@sql_insert` sets no `state` (→ column default `'released'`) and writes NO `media_state_transitions` audit row. If ever re-wired to `lib/`, it re-creates the "servable, un-audited, un-scanned" write path this story removed | Fully parameterized ($1–$8), no injection, and **this story removed its last `lib/` caller** (improvement) + doc-warns "do not call from new `lib/` code". Only an `:integration` test calls it. No current exploit path. Long-term: delete `insert/1` (and its test) once the backfill test is retired, or add a CI grep gate for `DB.insert(` outside `test/`. |
| F-4 | INFO (advisory) | `state_machine.ex:315-350` (`create_quarantined/1`) | Non-exhaustive `{:error,_}` contract: a DB fault on the genesis-transition `query!` raises a `Postgrex.Error` out of `Repo.transaction/1` rather than returning `{:error, term()}` — identical shape to `create/1` (1b review L-2) | Fails **closed**: the raise rolls back the `media_files` INSERT (no row-without-audit-row), and `create_and_store/6` surfaces it as a generic 500. No partial write, no leak. Optionally document the raise-on-DB-fault contract on the `@spec`; not a defect. |

---

## Detail

### F-1 — The sync path has NO equivalent TOCTOU, and the shared function adds NO new cross-caller race [INFO, resolved]

This is the coordinator's specific question and it gets a real, specific verdict — not "deferred."

**(a) Does the sync path have an equivalent race to 2b's async F-1?** No — structurally ruled out.

2b's F-1 was a *self-vs-self* race because **both** concurrent PUTs targeted the **same pre-existing reservation row** (the `media_id` minted by an earlier `POST /create`), and `lookup_reservation/2` read `state` without a row lock, so both could pass the `row.state != :reserved` guard and both enter `store_and_quarantine/7`.

The sync path has no such shared row. `create_and_store/6` calls `generate_media_id()` (128-bit `strong_rand_bytes`) **fresh on every request**, then `create_quarantined/1` performs an **INSERT** (not an UPDATE of a pre-existing row). Two concurrent sync uploads therefore create two different PK rows, with two different `storage_key`s (default template `{media_id}` ⇒ `storage_key == media_id`), writing two different S3 objects. There is no check-then-act window over shared state: the only concurrency primitive that matters is the `media_files` PRIMARY KEY, and the INSERT is atomic. The "genuinely new PRIMARY KEY per request" property does structurally rule out the sync equivalent of the async race.

**(b) Does the shared `encrypt_compress_and_store/5` introduce a NEW race between the sync and async callers?** No.

- **No shared mutable state.** The function generates its `key`/`nonce` as local variables via `:crypto.strong_rand_bytes/1` on each invocation and computes `file_hash`/`storage_key` from its arguments only. Two concurrent invocations (one sync, one async) share nothing — no module attribute, no ETS, no process state is mutated.
- **`media_id` collision across callers is caught by the PK, not by a race.** For a sync upload's fresh random `media_id` to equal an existing async reservation's `media_id`, it would have to collide in 128 bits. If it did, `create_quarantined/1`'s INSERT hits the PK `unique_violation` → `{:error, :media_id_taken}` → sync retries once with a new id. The sync path **cannot overwrite** an async reservation row, because it INSERTs (fails on collision) rather than UPDATEs. So there is no path where a sync request and an async request end up writing the same `media_files` row.
- **`storage_key` collision requires `media_id` collision.** `{media_id}` is a mandatory template placeholder (2b's verified `compute_key/2` / `check_media_id_present/1` analysis), so every computed key carries the unique `media_id`. Distinct `media_id` ⇒ distinct `storage_key`, for the default template and any admin template alike. No cross-caller S3-object overwrite.

Net: 2b F-1 is **closed for the sync path by construction** and **not widened for the async path** by sharing the function. The residual async self-vs-self integrity edge described in 2b F-1 is unchanged by this story (the async path's `lookup_reservation`-then-`store_and_quarantine` structure is untouched) and remains the LOW/INFO it was rated in 2b. Nothing in this refactor made it worse; the shared function did not become a new collision surface.

### F-2 — Orphaned `:quarantined` row on post-create failure [INFO, deferred]

`create_and_store/6` creates the row in `:quarantined` *first*, then runs `encrypt_compress_and_store/5`. If the latter fails (S3 put or the `persist_upload` UPDATE), the row is left in `:quarantined` with placeholder key material (`aes_key_hex=''`, `nonce_hex=''`, `storage_key=NULL`) and no scan job. The dev documented this in-code (media.ex:219-231) and deferred remediation to a future reaper story.

Security assessment: **not a vulnerability.**
- A `:quarantined` row is never downloadable — the Story 1c gate serves only `:released`. Placeholder/absent key material is never exercised because the bytes are never served.
- It is not attacker-forceable: `persist_upload` is a server-side UPDATE on a just-created PK row; a client cannot induce its failure. The S3 put failing requires an infrastructure fault, not attacker input.
- Worst case is DB/object housekeeping (a stuck row + possibly an orphaned S3 object per ADR-032), bounded by the same rate-limit + 50 MB size cap that gate every upload. No amplification.

This is the correct trade-off for AC4's "create directly into `:quarantined`" design. Concur with the deferral; recorded for the reaper story so a stuck-`:quarantined`-with-no-scan-job sweep is added alongside the `:reserved` sweep.

### F-3 — Residual `DB.insert/1` dead write path bypasses the StateMachine [INFO, watch-flag]

`Nebu.Media.DB.insert/1` is retained (documented) for a single `:integration` test that seeds a pre-migration-shaped row. This story **removed its last production caller** (`insert_media_row/7`) — a genuine improvement, and AC1 ("row created via StateMachine, never `DB.insert/1`") is satisfied in `lib/`.

The residual watch-flag (matches my memory pattern "Vestigial legacy … dead write path"): `@sql_insert` is a 9-column INSERT that (a) does **not** set `state`, so a row created through it takes the column default `'released'` — immediately servable — and (b) writes **no** `media_state_transitions` audit row. The Story 1b grep-invariant checker scans for `UPDATE media_files … SET … state =` and would **not** catch this INSERT (wrong statement shape; it never mentions `state`). So if a future story re-wires `insert/1`, it silently reintroduces exactly the un-scanned/un-audited/servable write path this refactor eliminated.

No change required for 2c (parameterized, no injection, no `lib/` caller, clearly doc-warned). Disposition: when `media_files_state_backfill_test.exs` is eventually retired, delete `insert/1` with it; or add a CI grep gate rejecting `DB.insert(` (or `Media.DB.insert(`) anywhere under `server/lib/`.

### F-4 — `create_quarantined/1` raises rather than returns `{:error,_}` on a DB-layer transition fault [INFO, advisory]

`create_quarantined/1` mirrors `create/1` exactly: the genesis `media_files` INSERT uses non-bang `query` (so `unique_violation` → clean `{:error, :media_id_taken}`), but the genesis-transition INSERT uses `query!` (bang). A DB fault on the transition insert raises a `Postgrex.Error` that propagates out of `Repo.transaction/1`; the `case result do {:ok,_}/{:error,_}` does not catch it, and `create_and_store/6` does not rescue it, so it surfaces as an unhandled 500 to the client.

This is the same fail-closed behavior the 1b review recorded as L-2 for `create/1`/`transition/4`, and it is security-sound: the raise rolls the whole transaction back, so there is **no `media_files` row without its paired `media_state_transitions` genesis row** (the atomicity invariant holds), and the error surface to the client is a generic 500 with no internal detail. Advisory only: optionally document the raise-on-DB-fault contract in the `@spec`/moduledoc.

---

## Adversarial probe results (coordinator watch-list)

1. **`create_quarantined/1` SQL injection / actor spoofing / atomicity (state_machine.ex):** CLEAN.
   - `@sql_insert_genesis_quarantined` binds only `media_id`/`server_name`/`uploader_user_id`/`now_ms` as `$1..$4`; `content_type`,`file_size`,`aes_key_hex`,`nonce_hex`,`deleted`,`state` are hardcoded literals (`'',0,'','',false,'quarantined'`). No interpolation of caller values.
   - `@sql_insert_genesis_quarantined_transition` hardcodes `from_state=NULL, to_state='quarantined', actor_type='system', actor_id=NULL`; binds only `$1` (media_id) and `$2` (`%{}` metadata). The function **takes no actor argument** — there is no path for an attacker (or any caller) to inject an admin `actor_id` into a sync-upload genesis row.
   - Atomic: both INSERTs run in one `Repo.transaction/1`; the transition INSERT is `query!` → any fault rolls back the media_files INSERT. Row-without-audit-row is impossible (see F-4).
   - `unique_violation → :media_id_taken` returns a bare atom; no DB internals, no sensitive data leaked to the caller.

2. **`create_and_store/6` + `encrypt_compress_and_store/5` (media.ex):** CLEAN.
   - **Fresh key+nonce per upload:** `:crypto.strong_rand_bytes(32)` + `:crypto.strong_rand_bytes(12)` generated inside `encrypt_compress_and_store/5` on every call. Retries re-enter `create_and_store/6` *before* this function runs, so each attempt (and each of sync/async) gets independent material. GCM catastrophic (same key+same nonce) reuse is structurally impossible.
   - **SHA-256 on RAW bytes before compression:** `file_hash = :crypto.hash(:sha256, body)` on the plaintext `body`, computed *before* `Nebu.Media.Storage.compress(body)`. Verified in code — matches the story claim.
   - **One-retry cap:** `create_and_store/…/retried?`: `false` initially → `{:error, :media_id_taken} when not retried?` recurses with `true` → a second collision fails the guard and drops to the `{:error, _}` → 500 clause. No infinite loop; no DoS via forced collisions (which are infeasible at 128-bit anyway).
   - **`compute_key/2` inputs server-controlled only:** `media_id` (server random), `server_name` (`server_name()` config), `uploaded_at` (`DateTime.utc_now()`). `content_type` is not fed to the key; `filename` is `nil` for sync. No attacker-controlled path-traversal input — matches 2b's verified analysis.

3. **Sync `filename = nil` (media.ex:232):** CLEAN. `create_and_store/6` passes `nil` literally to `encrypt_compress_and_store/5`, which binds it to `persist_upload`'s `$6`. The `filename` column is nullable (migration 000025), so SQL NULL is schema-valid — no crash. `row.filename` is read by nothing (2b F-2), so the sync path stores no filename and reflects none. No injection, no header sink reached.

4. **Rate-limiting / auth / content-type blocklist / size-limit untouched:** CLEAN — verified by diff, not by belief. No diff hunk touches `upload/1` (lines 160-190), `over_content_length?`, `read_full_body`, `@blocked_upload_types`, `@default_max_upload_bytes`, or `server/lib/nebu/web/router/media.ex` (the `OidcPlug` + rate-limit tier). Only `store_upload/4`'s internals changed. The blocked-type → 413-content-length → body-read → empty-body validation cond and the router-level auth/rate-limit are byte-for-byte intact. AC3 external contract preserved.

5. **`DB.insert/1` (db.ex):** CLEAN for this diff (doc-only change). Parameterized $1–$8, no injection, no `lib/` caller. Residual re-wire landmine recorded as F-3 watch-flag.

6. **Own adversarial sweep — injection / auth-bypass / race / resource-exhaustion:**
   - `uploader_user_id` = `conn.assigns[:current_user]` (OidcPlug-set canonical `@user:server`), bound as a parameter — no injection, correct canonical identity stored (addresses the old Epic-12 `uploader_user_id ≠ Matrix id` pattern).
   - `metadata` is a hardcoded `%{}` — no attacker channel into the JSONB column on either genesis path.
   - `mxc://#{server}/#{created_media_id}` response interpolation uses server-config `server` + server-random `media_id` — no attacker-influenced bytes.
   - No new logging of key material, body, or PII (`create_quarantined/1` logs nothing; `encrypt_compress_and_store/5` logs nothing).
   - Security improvement noted: sync uploads now land `:quarantined` (non-servable) instead of the old `DB.insert/1` path's `state='released'` default (servable, unscanned).

---

## Summary

- **CRITICAL:** 0
- **HIGH:** 0
- **MEDIUM:** 0
- **LOW:** 0
- **INFO:** 4 — F-1 (2b TOCTOU structurally ruled out for sync + no new cross-caller race — *resolved*), F-2 (orphaned `:quarantined` row on post-create failure — not a security defect, deferred to reaper), F-3 (`DB.insert/1` residual dead write path — watch-flag, not reintroduced by this story), F-4 (`create_quarantined/1` raises on DB-layer transition fault — fails closed, advisory)

**Verdict: CLEAN.** `create_quarantined/1` upholds every invariant the 1b review established for `create/1` (fully parameterized SQL, hardcoded `system`/`NULL` actor with no injection channel, atomic UPDATE/INSERT that fails closed, clean `:media_id_taken` mapping). The shared `encrypt_compress_and_store/5` generates a fresh key+nonce per call, hashes raw bytes before compression, caps retries at one, and feeds only server-controlled values into the S3 key template. The sync path passes `filename = nil` into a nullable column with no downstream sink. The refactor leaves auth, rate-limiting, the content-type blocklist, and the size limit entirely untouched, and it closes a real gap (sync uploads no longer land directly in servable `:released`). The 2b-deferred TOCTOU is structurally ruled out for the sync path and not widened for the async path. No blocking findings.
