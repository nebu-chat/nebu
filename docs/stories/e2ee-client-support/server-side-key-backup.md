---
story_id: server-side-key-backup
title: "Server-side key backup (room keys) as opaque store"
epic: e2ee-client-support
status: done
security_review: required
matrix: true
ui: false
traceability_id: REQ-2026-011
created: 2026-10-30
---

## Story

**As** a Matrix client user who logs in again on a new device, **I want** my client to create and restore a server-side room key backup (Matrix CS API v1.18, "Server-side key backups"), **so that** "chat recovery" and secret-storage bootstrap complete and I can read my older encrypted history.

Scope and constraints (the story is the source of truth for the implementer):

- Endpoints: `POST|GET /client/v3/room_keys/version`, `GET|PUT|DELETE /client/v3/room_keys/version/{version}`, `PUT|GET|DELETE /client/v3/room_keys/keys`, `/room_keys/keys/{roomId}` and `/room_keys/keys/{roomId}/{sessionId}`. All key routes require `?version=`.
- `POST /version` takes `algorithm` and `auth_data` (opaque JSON, size-bounded) and returns the new version string. `GET /version` and `GET /version/{version}` return `etag`, `count`, `algorithm`, `auth_data`, and `version`. `PUT /version/{version}` updates `auth_data`; the `version` in the body must match the URL. `DELETE /version/{version}` deletes the version and all its keys.
- Errors: `M_NOT_FOUND` for an unknown version (reads and writes). `M_WRONG_ROOM_KEYS_VERSION` when a key write names a version that is not the current one.
- Key PUT merge rule (per spec, in this order): if `is_verified` differs keep the verified one; otherwise keep the lower `first_message_index`; if equal keep the lower `forwarded_count`; a full tie keeps the stored session. The count does not change when a session is replaced. Responses carry `{etag, count}`.
- Session blobs (`session_data`) and `auth_data` are stored as opaque JSON and never decrypted or parsed beyond the JSON well-formedness and size checks. They must never be logged (no sensitive data in logs).
- `etag` and `count` are computed from DB state, not held in process memory (cluster-safe). State lives only in the DB.
- Storage: ADR-018 inline SQL in the handler (no repository/service layer). New migration after `000055` with runtime role grants and RLS/ownership policies in the style of the per-user tables (cross_signing keys, account data). Every row is scoped to the owning user; no cross-user access path.
- Quotas (decided here): max 10 backup versions per user; an 11th create is refused with 403 `M_FORBIDDEN` (no silent deletion, because that would destroy a user's key backup). Max 100 000 sessions per version. Max 8 KiB per `session_data` blob, max 16 KiB for `auth_data`, max 5 MiB per request body on `room_keys` routes. Rate limits follow the sibling client write endpoints.
- GDPR erasure must delete all key-backup versions and session rows of the erased user.
- ADR-011 stays: Nebu keeps rejecting `m.room.encryption`. This story only adds the key directory/backup store. Document the clarification in `docs/architecture/adr/` and in the 05/08 docs.
- Out of scope: the `m.oauth` UIA stage for backup creation (separate story).
- Acceptance scenarios below cover the main behaviour. Further scenarios for update/delete, quotas, size limits, GDPR erasure and unknown-version errors must be added by the implementation pipeline before code is written.

## Acceptance Criteria

```gherkin
Feature: Server-side key backup
  Scenario: Create a backup version and read it back
    Given I am logged in and have no key backup version
    When I POST /room_keys/version with algorithm "m.megolm_backup.v1.curve25519-aes-sha2" and an auth_data object
    Then GET /room_keys/version returns that version with its etag, count 0, the algorithm and the auth_data

  Scenario: Store session keys and read them back with count and etag
    Given I have a current backup version
    When I PUT /room_keys/keys?version=<current> with one session for a room
    Then the response contains etag and count 1, and GET /room_keys/keys?version=<current> returns the same session_data

  Scenario: A better session replaces the stored one
    Given a session is stored with first_message_index 10 and is_verified false
    When I PUT the same session with first_message_index 5 and is_verified true
    Then the stored session is replaced by the new one

  Scenario: Writing to a version that is not the current one is refused
    Given my current backup version is "2" and version "1" exists
    When I PUT /room_keys/keys?version=1 with a session
    Then the server responds M_WRONG_ROOM_KEYS_VERSION and stores nothing

  Scenario: Another user cannot read my backup
    Given user A has a backup version with stored keys
    When user B GETs /room_keys/version/<A's version> or /room_keys/keys?version=<A's version>
    Then the server responds M_NOT_FOUND and returns no data
```

## Decisions

- Oracle context: `_bmad-output/nebu/epics/e2ee-client-support/step-results/server-side-key-backup/oracle-context.md` is authoritative for shapes and errors (idempotent DELETE with soft-delete marker, `current_version` in the 403, `{"rooms":{}}`/`{"sessions":{}}` for empty reads, `M_MISSING_PARAM` for a missing `version`, versions never reused, key write for an unknown version: 403 when the user has any current version else 404).
- Quota error for the 11th version is 403 `M_FORBIDDEN` (not `M_LIMIT_EXCEEDED`, which clients auto-retry). Only the one spec algorithm is accepted (400 `M_INVALID_PARAM` otherwise).
- Tests of the old stub (`matrix_client_compat_test.exs`, `unrecognized_routes_test.exs`, `unrecognized_routes_integration_test.exs`) are updated in this story; the 405 `Allow` for `/room_keys/version` stays `GET, POST`.
- Tables `room_key_backup_versions` and `room_key_backup_sessions` (both `user_id TEXT NOT NULL`, both in `UserDeletion.erased_tables/0`, sessions first). The session rows have a FOREIGN KEY `(user_id, version)` to their version, without a cascade (a version row cannot go while sessions point to it).
- Version numbers are per-user counters: the first version of every user is `"1"` (decimal string, strictly increasing, never reused). Version numbers of different users therefore coincide; every query is scoped by `user_id`.
- SUPERSEDED (cycle 1, Kassandra MEDIUM 3): the cycle-0 rule "the 5 MiB cap applies to requests that carry a bearer, anonymous requests keep the 1 MB default" is replaced by: NO pre-auth parse. `JsonBody` leaves the bodies of `v3/room_keys/**` unfetched; the body is read only after the authentication: the route authenticates first, then charges the write rate limit, then reads and parses the body with the 5 MiB limit. An anonymous, junk-bearer or malformed-credential request is answered 401 WITHOUT its body being read (whatever its size: never 413, never `M_NOT_JSON`); an exhausted write bucket is 429 before the body is read. Valid token: exactly 5 MiB is accepted, one byte more is 413. Every other route keeps its 1 MB pre-router parse.
- SUPERSEDED (cycle 2): Rate limits (cycle 1): the WRITES have their own per-user bucket (60 per minute, burst 30). The two BULK reads (`GET /room_keys/keys`, `GET /room_keys/keys/{roomId}`) have a bucket of their own (30 per minute, burst 10 per user, 429 `M_LIMIT_EXCEEDED` with `retry_after_ms`); the single-session GET and `GET /room_keys/version*` stay unlimited (a documented divergence from the spec's "rate-limited": a restoring client reads one session per undecryptable event). `GET /keys*` splices the stored JSON text into the response instead of decoding and re-encoding every blob (the contract is structural equality).
- SUPERSEDED (cycle 2): Storage quotas (cycle 1, Kassandra HIGH 1 and LOW 4): a per-user aggregate byte budget over all live versions (canonical bytes of every `session_data` plus every live version's `auth_data`; default 256 MiB, seam `:nebu, :room_keys_max_bytes_per_user`), decided under the advisory lock, net of replacements (a replace counts only the size delta), freed by deleting sessions or versions, exceeded = `403 M_FORBIDDEN` and nothing stored; and a cap on the total version rows per user INCLUDING the soft-delete markers (default 1000 rows, seam `:nebu, :room_keys_max_version_rows_per_user`): a create beyond it is `403 M_FORBIDDEN`. The markers are never pruned (needed for never-reused numbers and the idempotent DELETE): the growth is bounded by that cap and accepted (risk register).
- SUPERSEDED (cycle 2): Lock timeout (cycle 1, Kassandra MEDIUM 2): every writer runs `SET LOCAL lock_timeout` (seam `:nebu, :room_keys_lock_timeout_ms`, default 2000) before the `sync_global` advisory lock; SQLSTATE 55P03 is `429 M_LIMIT_EXCEEDED` with `retry_after_ms` and stores nothing, so waiters cannot exhaust the shared pool of 10 connections. Reads take no lock.
- SUPERSEDED (cycle 2, delta review) - memory and concurrency (HIGH): the default byte budget is 64 MiB (seam `:nebu, :room_keys_max_bytes_per_user` unchanged; cycle 1 had 256 MiB). Bulk reads (`GET /room_keys/keys`, `GET /room_keys/keys/{roomId}`) have at most ONE in flight per user and at most TWO in flight per node (seam `:nebu, :room_keys_max_concurrent_bulk_reads_per_node`, default 2, read at request time): a monitor based slot (a process that reads the seam and calls `Process.monitor` on the request process, freed on `:DOWN`, so a killed request frees it; not only `try/after`); the excess is `429 M_LIMIT_EXCEEDED` with `retry_after_ms`, answered before any database work. The bulk bucket burst is 3 (30 per minute stays, cycle 1 had burst 10) and the room_keys WRITE burst is 5 (60 per minute stays, cycle 1 had burst 30). Streaming the response is NOT required (follow-up); `11-risks` records the honest peak (about 300-350 MiB per request for a 256 MiB version before the lower budget, about 64 MiB x 2.5 after) and the accepted residual.
- SUPERSEDED (cycle 2) - lock (MEDIUM): the waiting lock with `lock_timeout` of cycle 1 is replaced by `pg_try_advisory_xact_lock` in all nine writers: a busy lock is an immediate `429 M_LIMIT_EXCEEDED` with `retry_after_ms`, and no waiter ever holds a pool connection; reads never take the lock. The `lock_timeout` seam (`:room_keys_lock_timeout_ms`, default 2000) stays ONLY as the safety net for ROW locks (55P03 is still 429).
- SUPERSEDED (cycle 2) - budget accounting (MEDIUM): every stored session row costs `octet_length(room_id) + octet_length(session_id) + 128` bytes (a fixed cost per row) besides the canonical bytes of its `session_data`, and every live version costs its `auth_data` bytes. The O(1) counter column is a documented follow-up (the check is O(scan) of the user's rows per write).
- Version reads (cycle 2): `GET /room_keys/version` and `GET /room_keys/version/{version}` have a light bucket of their own (120 per minute, burst 30 per user, shared by the two routes, separate from the bulk and the write buckets); the single-session GET stays unlimited. All buckets are node-local (in a cluster the effective limit is N x the documented one).
- Version-row cap lockout (cycle 2, code review MINOR-3): no automatic pruning. The 403 text keeps pointing at the operator and the docs (`docs/compliance/gdpr-deletion-runbook.md`) contain the exact operator SQL (a fenced `sql` block with `DELETE FROM room_key_backup_versions ... '<user_id>'`) that prunes the old marker rows of one user while keeping the highest-numbered marker, so numbers are never reused; the SQL is executed by a test.
- Route normalizer (cycle 2, INFO-2): `/room_keys/version/{n}` is normalized to `/room_keys/version/:version`, not `:room_id`. `JsonBody` (INFO-5): the skip clause matches the DECODED path segments, so an encoded `room%5Fkeys` path is not parsed before the authentication either.
- The migration is `000058_room_key_backup` (cycle 0 used 000056, which clashes with the session-lifetime story; 000057 is reserved for persistent consent grants); it adds the partial index `(user_id, version) WHERE deleted_at IS NULL`. The route normalizer replaces the client-chosen room and session id segments of `room_keys/keys/**`, so they never reach the request log.
- The session cap per version (100 000) and the 11th version are both `403 M_FORBIDDEN`; oversize `session_data` / `auth_data` / body are `413 M_TOO_LARGE`; sizes are canonical JSON bytes.
- Element e2e: every Element e2e login now creates a REAL backup. The Element e2e job is a merge gate for this story (re-run it, or a manual smoke: fresh login, "Set up recovery", log in again on a second device and restore). `e2e/features/element/crypto/recovery-setup.feature` (known failure K7) is the place to add an API read-back of `GET /room_keys/version` once K7 is fixed; `e2e/KNOWN-FAILURES.md` (the "Unable to set up keys" entry, which names the `room_keys/version` stub) must be updated: the server gap is closed by this story.

## Definition of Done

- [ ] Element e2e job re-run (or manual smoke) before merge; `e2e/KNOWN-FAILURES.md` stub wording updated (wording updated; the Element/FluffyChat end-to-end verification of the key backup/restore flow was NOT run, there is no client e2e for it)
- [x] All Gherkin scenarios have failing tests (ATDD)
- [x] All tests pass (green) (see the note below for the one expected red test)
- [x] Code review clean (0 MAJOR)
- [x] Security review (if required) clean (Kassandra cycle 2 APPROVED; two accepted MEDIUM risks recorded in `docs/architecture/11-risks.md`)

## Close-out notes (2026-10-30)

- Verification not run: the Element/FluffyChat end-to-end verification of the key backup/restore flow (fresh login, "Set up recovery", second device restore) was not run; no client e2e exists for it. Do it as a manual smoke before deploying.
- Gates: the full e2e gate ran green (147 passed, 0 failed relevant). The no-DB suite has ONE expected red test: the `release_test.exs` migration-contiguity guard (versions must be 1..n). This branch carries migration 000058 while 000056 (session lifetime) and 000057 (consent grants) live on branch `bugfix/oauth-session-lifetime-and-consent`.
- MERGE ORDER: this branch must be merged AFTER `bugfix/oauth-session-lifetime-and-consent` (or rebased onto it) before pushing or deploying. Otherwise `Nebu.Release.migrate` would skip 56/57 forever on a node that already applied 58.
