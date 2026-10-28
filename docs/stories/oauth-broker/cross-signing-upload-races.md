---
story_id: cross-signing-upload-races
title: "The cross-signing writers decide on the stored keys only under the per-user lock: two concurrent first uploads store exactly one key set, and a signature merge reads its merge base under the lock, so a concurrent reset is never written back stale (closes cq (g), Kassandra INFO-3 of sync-token-per-device, MINOR-1 of gdpr-erasure-global-data delta cycle 1)"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
traceability_id: REQ-2026-007
created: 2026-10-28
branch: feature/migrate-to-oauth2
depends_on: sync-stream-position
sizing: small
---

# Story: the cross-signing write races (follow-up `cq` (g))

## Story

**As** a Nebu user who sets up or resets cross-signing from more than one device or client at a time, **I want** every write of my
cross-signing keys to decide on the keys that are actually stored when it writes, **so that** two concurrent first uploads never
both skip user-interactive authentication with the second silently replacing the first, and a signature someone adds to my key
never undoes a reset that committed a moment earlier.

Scope: the decision read of the two upload handlers (`do_persist_cross_signing/3`, `replace_with_approval/7` in
`server/lib/nebu/web/router/protected.ex`) and the merge path of `CrossSigningKeyStore.merge_signatures/3` (`persist_single/3`,
`put_keys_no_flag/2`), real-DB race tests, the lock-order docs, the closure of `cq` (g). No migration, no new route, no response
change, no new follow-up id.

## Premise check (2026-10-28, worktree `open-chat-oauth`, read-only)

- **Race 1 confirmed, narrower than "first upload".** `do_persist_cross_signing/3` runs `get_keys_for_update/1` (`SELECT ... FOR
  UPDATE`) in a transaction and takes the first-upload branch on `master_key == nil`; `put_keys/2` takes `sync_global|<user>` only
  afterwards. When the row EXISTS (e.g. with a NULL master) the row lock already serialises two uploads. The race needs an ABSENT row:
  both reads lock nothing, both see nil, both wait on the advisory lock in `put_keys/2`, and the second upsert overwrites the
  first (the UIA-free branch twice, `changed_pos` drawn twice).
- **The replacement path is not racy today.** `replace_with_approval/7` is only reached after a stored master was seen, so its
  `FOR UPDATE` finds a row; the only deleter is the erasure, whose refused write is already `:user_erased`. It changes only if
  the lock order or the store API changes (D1, D3).
- **Race 2 confirmed, plus a validation gap.** The handler `merge_cross_signing_signature/4` validates the submitted object
  against `find_key_object/2` (plain `get_keys/1`, no lock); `merge_signatures/3` reads `get_keys/1` again, picks the key by key id,
  and `persist_single/3` reads it a THIRD time before `put_keys_no_flag/2` locks. All three reads come before the locks and are
  error-blind (a failed read looks like "nothing stored" -> `:not_found` -> failure entry `M_INVALID_SIGNATURE`).
- **Documented lock order today** (store comment at `put_keys_no_flag/2`, `user_deletion.ex` step 4a, pinned by
  `user_deletion_lock_order_test.exs` and `user_deletion_docs_test.exs` / 08-concepts): row locks first (`uia_sessions`, then
  `cross_signing_keys`), then the advisory lock. The writers of these key columns are `put_keys/2`, `put_keys_no_flag/2` and the
  erasure DELETE, and all of them hold `sync_global|<user>` when they write. `consume_changed_flag/1` only updates the flag. The
  `users` row: the erasure holds it from step 2, the writers take only FOR KEY SHARE (FK) and a plain `deletion_status` read.

## Decisions

- **D1 Lock-then-read, documented order KEPT (recommended; see OQ1).** One new store function, e.g.
  `CrossSigningKeyStore.lock_keys/1` (must run inside a transaction): `SELECT 1 ... FOR UPDATE` on the row (locks it if it
  exists), then `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))`, then the error-aware read of the three
  columns (`{:ok, keys}` / `{:error, reason}`, the `get_keys_for_update/1` shape). Under Read Committed the read after the advisory
  lock sees every commit of a previous holder, and no writer changes the key columns without that lock, so the result stays valid
  until the caller commits. Order per transaction: row -> advisory -> read -> decide -> write. This is the existing order, so the
  erasure, the replacement path and `user_deletion_lock_order_test.exs` keep their order. `put_keys/2` and
  `put_keys_no_flag/2` take the advisory lock again (re-entrant in the same transaction, harmless).
  **Rejected:** (a) advisory lock FIRST everywhere (the literal fix direction of `cq` (g)): it works only if the erasure
  (`lock_user_writers/1`), `replace_with_approval/7` (before `Uia.consume/4`) and the merge flip as well. Otherwise the upload
  (advisory -> row) and the erasure (row -> advisory) form a cycle. That flip costs a full re-analysis, the step 4a comment, 08-concepts
  and their pinned tests, and gains nothing over D1. (b) A conditional first-upload insert (`ON CONFLICT ... DO UPDATE WHERE
  master_key_json IS NULL`, 0 rows -> fall back to the stored branches): it closes race 1 only, adds a second write path, and does
  not fix race 2.
- **D2 Upload handler.** `do_persist_cross_signing/3` replaces `get_keys_for_update/1` with `lock_keys/1`. The branch table stays
  as it is: master nil -> first upload (written in the same transaction); stored -> `{:stored, stored}` -> `M_MISSING_PARAM` /
  idempotent 200 / OAuth replacement / legacy 403. A failed read is still `:read_failed` -> 500, never the first-upload branch.
  The loser of a first-upload race therefore answers like any upload against stored keys: 200 for identical keys (no second
  `changed_pos`), otherwise the replacement path (OAuth `m.oauth` challenge, legacy 403).
- **D3 Replacement path.** `replace_with_approval/7` also uses `lock_keys/1` after `Uia.consume/4` (order: uia row -> cs row ->
  advisory -> read). This keeps the protocol uniform. It closes no live race (Premise 2).
- **D4 Signature merge under the lock.** `merge_signatures/3` (or a successor taking the validated object) runs ONE transaction:
  `lock_keys/1` -> find the key by key id IN THAT READ -> compare the non-`signatures`/`unsigned` part of the locked object with the
  submitted object (the handler's validate-then-persist check, repeated under the lock) -> deep-merge -> write all three columns
  from the locked read -> erasure predicate as today (0 rows = `:not_found`, nothing stored). No match, or a different object under
  the same key id -> `:not_found` -> failure entry, nothing written. The handler's early `find_key_object/2` may stay as a cheap
  pre-check. The stale `get_keys/1` reads in `merge_signatures/3` / `persist_single/3` are removed. Replace the comment
  "NOT protected here: the MERGE BASE" with the new protocol. `cross_signing_changed` / `changed_pos` are still not touched by a
  merge.
- **D5 Errors and logs.** The upload: unchanged (read failure 500, write failure 500 with the error kind only, `user_erased`
  answer unchanged). The merge: a failed locked read is handled like a failed merge write today (raise
  "cross-signing signature merge failed" -> 500), never an all-nil base (OQ2). No new log line, and never key material, key
  ids or signatures in a log line.
- **D6 Docs and closure; NO new follow-up id.** `follow-ups.md` row `cq`: item (g) becomes "(g) **CLOSED by story
  cross-signing-upload-races (2026-10-28): ...** **Original item:** <current (g) text verbatim>". The other items and the status
  `open, non-gating` stay, and the "Follow-up ids." line stays byte-identical (pinned by the docs suites). The step 4a comment in
  `user_deletion.ex`, the store moduledoc/comments and the 08-concepts lock-order passage name `lock_keys/1` and the order row ->
  advisory -> read. Add a docs test (`cross_signing_upload_races_docs_test.exs`) for the closure, the id line and the 08-concepts
  sentence.
- **D7 Test technique (real PostgreSQL, deterministic).** Use the barrier pattern of `user_deletion_lock_order_test.exs`
  (`E.await_blocked!/3`, own connections, committed rows, `async: false`): a holder session takes `sync_global|<user>` (or the row
  lock), the racers are started, the test polls `pg_locks` until each racer is blocked, and then releases. Every scenario must FAIL
  on the current code. Mutation checks for the dev: the advisory lock moved back behind the decision (scenario 1 fails); the merge
  base read moved before `lock_keys/1` (scenario 2 fails); `lock_user_writers/1` order flipped (scenario 4 fails with `40P01`).
- **D8 Security review required (Kassandra).** UIA bypass (the second UIA-free first upload is the INFO-3 finding), the
  integrity of the key directory (stale write-back), the erasure guard (D10 of gdpr-erasure-global-data unchanged), deadlock / DoS
  (one more lock statement per write, still bounded), logging.

## Non-goals

- A first upload without a master key (row with a NULL master): it is still "no keys yet" (INFO-1 rule, unchanged).
- The device-key signature path (`merge_device_key_signature/4`, `DeviceKeyStore`): a different table, not `cq` (g).
- `cq` (a)-(e): unchanged.

## Acceptance Criteria

```gherkin
Feature: cross-signing writes decide on the stored keys only under the per-user lock

  Scenario: Two concurrent first uploads store exactly one key set
    Given a user with no cross-signing row and two device_signing/upload requests, with identical keys in one run and different keys in another, both blocked behind the user's sync_global lock
    When the lock is released
    Then exactly one request takes the UIA-free first upload, the stored keys are its keys and changed_pos was drawn once, and the other answers 200 for identical keys or the replacement answer (m.oauth challenge for OAuth, 403 for legacy) for different keys

  Scenario: A signature merge concurrent with a cross-signing reset never writes back stale columns
    Given a reset of the self-signing key holds the user's cross-signing row and waits for the advisory lock, and a signatures/upload for the same user's master key has started
    When the reset commits and the merge proceeds
    Then the stored self-signing and user-signing keys are the reset's keys and the master carries the new signature, and a merge whose signed key was replaced by the reset stores nothing and reports a failure entry

  Scenario: An erased user's uploads and merges are still refused
    Given an erasure of the user holds its locks while a first upload and a signature merge for that user wait
    When the erasure commits
    Then the upload is answered with the existing user_erased answer, the merge with a failure entry, and no cross_signing_keys row exists for the user

  Scenario: Uploads, the signatures upload and the erasure never deadlock
    Given a first upload, an OAuth replacement, a signature merge and an erasure of the same user are released together from a barrier, repeated several times
    When all of them run
    Then every one finishes within the timeout, none fails with deadlock_detected, and the lock order row then advisory then read is the one documented in the store, user_deletion.ex and 08-concepts

  Scenario: A failed decision read is an error, never a first upload
    Given the locked read of the stored keys fails for an upload and for a signature merge
    When the requests are handled
    Then the upload answers 500 M_UNKNOWN and stores nothing, the merge answers 500 and stores nothing, and no log line contains key material
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Open Questions for the orchestrator

- **OQ1 Lock order.** D1 keeps row -> advisory and moves the decision read BEHIND the advisory lock. The alternative is the literal
  `cq` (g) direction, advisory first, which forces the erasure, the replacement path and the merge to flip and their pinned tests
  to be rewritten. Recommendation: D1.
- **OQ2 Merge read failure.** Today a failed merge read is silently `:not_found` (a failure entry `M_INVALID_SIGNATURE`, 200 overall).
  D5 makes it a 500 like a failed merge write. Accept the change, or keep the failure entry? Recommendation: 500 (fail loud, no
  silent stale base).
- **OQ3 Store API.** Should the advisory lock live inside the store (`lock_keys/1`, `get_keys_for_update/1` removed or delegating
  to it) or stay as an explicit handler step? Recommendation: the store, so no caller can decide on an unlocked read again. Should
  the merge take the validated submitted object, so the check is repeated under the lock (D4)? Recommendation: yes.

## Orchestrator decisions on the open questions (2026-10-28)

- **OQ1 decided: D1.** The documented lock order (row lock, then the `sync_global|` advisory lock) is kept for every writer and the
  erasure; the decision read moves behind the advisory lock. The literal "advisory lock first everywhere" direction is rejected
  (it would flip the erasure, the replacement path and the merge and their pinned lock-order tests).
- **OQ2 decided: 500.** A failed read in the signature merge is a 500, like a failed merge write (fail loud, no silent stale base).
- **OQ3 decided: the store owns the lock.** `CrossSigningKeyStore.lock_keys/1` takes row lock, advisory lock, then reads;
  `get_keys_for_update/1` is removed or delegates to it, so no caller can decide on an unlocked read; the merge takes the
  validated submitted object and repeats the match check under the lock (D4).

## Orchestrator decisions after ATDD (2026-10-28)

- **D-A1 early pre-check.** The error-blind `find_key_object/2` pre-check in the signatures handler goes away (or becomes
  error-aware and is only an optimisation): the decision is made under the lock, and a failed read is a 500 (D5, scenario 5).
- **D-A2 `get_keys_for_update/1`.** It may be removed when no caller is left, with the pin in `oauth_account_cross_signing_test.exs`
  (~621-636) amended to `lock_keys/1`; keeping it as a delegate to `lock_keys/1` is equally acceptable. No second unlocked-read path.
- **D-A3 OAuth replacement is two transactions** (decide in `do_persist_cross_signing/3`, write in `replace_with_approval/7`): accepted,
  the write re-reads under the lock; the test asserts only the order-independent invariant. Not merged into one transaction here.
- **D-A4 merge vs merge** lost update is closed by D4 as a side effect; kept as a red test.
- **D-A5 pins.** Scenarios 3, the upload half of 5 and most of 4 pin behaviour that is already correct (guards against mutants); D3 is
  covered by a source pin and a mutant only (no live race on the replace path).

## Accepted residuals (orchestrator, after code review and security review cycle 0, 2026-10-28)

- **Absent-then-present window (code review MINOR-2).** The row lock of `lock_keys/1` locks nothing for an absent row. A signature merge
  that took that empty row lock waits for the advisory lock while a first upload commits the row. An erasure of the same user then locks the
  new row and waits for the advisory lock. If the merge gets the advisory lock first, its write waits for the row the erasure holds: a cycle
  that PostgreSQL resolves with `40P01` (the erasure fails closed, or the merge answers 500). A first upload has the same window when the row
  committed in between has a NULL master (a partial upload with only a self-signing key: its read sees no master and its upsert takes the row
  lock only after the advisory lock; pre-existing, code review cycle 1 MINOR-A). Three actors of one user within milliseconds;
  it cannot be closed without flipping the lock order to advisory first everywhere (rejected, OQ1). Documented in the store moduledoc, the
  step 4a comment, 08-concepts and the `cq` (g) closure.
- **No cap on the key ids of one `signatures/upload` body (Kassandra F-2).** Each key id that is not a device key costs one short locked
  transaction on the caller's OWN row and advisory key (cross-user bodies are `M_FORBIDDEN` before the store). The O(n) cost pre-existed
  (about 3x per entry now); self-contention only, bounded by the 1 MB body limit. No cap in this story.
- INFO-6 (`lock_keys/1` outside a transaction makes the advisory lock a no-op): documented in `@doc`, no runtime assertion.
