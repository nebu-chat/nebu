---
story_id: token-hashing-matrix-sessions
title: "Bug: matrix_sessions stores access and refresh tokens in plaintext"
type: bug
severity: medium
epic: matrix-session-refresh-fixes
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-08
branch: bugfix/token-hashing-matrix-sessions
---

## Summary

`matrix_sessions.access_token` (PRIMARY KEY) and `matrix_sessions.refresh_token` (UNIQUE) hold the live bearer
credentials in plaintext. A read-only database leak (backup, replica, SQL injection, support access) yields
immediately usable session tokens for every logged-in user. Known finding from the Kassandra reviews of
`server-paced-session-refresh` and `refresh-worker-and-retry-semantics` (I-1): "AT/RT stored unhashed, token-hashing bugfix
follows".

Precedent in the codebase: `jwt_device_bindings` already keys by SHA-256 of the token
(migration `000011_jwt_device_bindings`). The OIDC refresh token is already AES-256-GCM encrypted (`SecretBox`).

Both tokens are 256-bit random values (`MatrixSessionStore.generate_opaque_token/0`), so a plain unsalted SHA-256 is
sufficient (no brute-force or dictionary risk); no KDF/pepper is required.

## Story

As an operator,
I want Nebu to store only hashes of Matrix access and refresh tokens,
so that a database leak does not hand out usable sessions.

## Acceptance Criteria

**AC1 — No plaintext token at rest:**
After the change, no column of `matrix_sessions` (or any other table, index, log, audit row) contains a plaintext access or
refresh token. The columns `access_token` and `refresh_token` are replaced by `access_token_hash` and `refresh_token_hash`
(hex-encoded SHA-256 of the token string; PRIMARY KEY resp. UNIQUE NOT NULL, same indexes as today).

**AC2 — Single hashing seam:**
`Nebu.Matrix.Session.MatrixSessionStore` exposes one function that hashes a presented token (`hash_token/1`); every lookup,
update, delete and insert in the store uses it. Callers (OidcPlug, HttpPublic, RefreshWorker, protected.ex) keep passing
and receiving PLAINTEXT tokens at the API boundary where they need them (a freshly minted token is returned to the client
once; it is never read back from the DB). No other module computes the hash independently.

**AC3 — Behavior unchanged:**
Login, `/refresh` (pending/consumed semantics, replay, reuse detection, 503/401 mapping), RefreshWorker (in-place extension,
candidates), OidcPlug (soft-revoked tokens → `soft_logout: true`), logout, delete-device, deactivation and the UIA
`auth_time` lookup behave exactly as before. All tests of story `refresh-worker-and-retry-semantics` stay green.

**AC4 — Migration invalidates all sessions (decision 2026-10-08, Kassandra F-1):**
A new migration (next free number after `000034`; verify the number is still free at merge time) adds the hash columns,
`TRUNCATE`s `matrix_sessions` (no backfill, no CLUSTER), swaps the PRIMARY KEY/UNIQUE constraints onto the hash columns
and drops the plaintext columns, all in one transaction. ALL sessions are invalidated and everybody logs in again once:
`DROP COLUMN` leaves plaintext bytes in the table file and a backfill `UPDATE` leaves old row versions, whereas `TRUNCATE`
(new relfilenode) plus dead sessions make any plaintext residue in files/backups/WAL/replicas worthless. The release is
STOP-THE-WORLD (old nodes query the dropped column; Kassandra F-2). The `.down.sql` cannot restore plaintext: it deletes
all `matrix_sessions` rows (forcing re-login) and recreates the old columns; after a rollback the old code writes plaintext
again. All of this is documented in the migration headers and the release notes. RLS/grants stay intact (check
`migrations_grant_test`; `TRUNCATE` needs table ownership by the migration role).

**AC5 — Constant-time/no oracle leaks:**
Lookups use the hash as an indexed equality predicate (no `LIKE`, no application-side comparison of secrets). Error responses
and logs never contain a token or its hash. `payload_redactor` still redacts `access_token`/`refresh_token` fields in request
and response bodies (unchanged), and no new log line prints hashes.

**AC6 — Cluster safety (ADR-020):**
Existing atomic statements (`rotate_tokens/1`, `extend_in_place/3`, `mark_access_token_used/1`, sibling locking, FOR UPDATE
replay check) keep their semantics and ordering; deterministic lock order is now by hash. No new TOCTOU windows.

**AC7 — Docs:**
`docs/architecture/08-concepts.md` (matrix_sessions field comments and token validation section) and the arc42 building-block
text describe the hashed storage; the Kassandra "plaintext storage" notes are resolved: the original reports stay unchanged (audit trail) and a "Resolution (cycle 1)" block is appended to the security review report.

## Acceptance Tests

- Insert a session through the store; a raw `SELECT * FROM matrix_sessions` row contains no substring equal to the plaintext
  access or refresh token and contains `access_token_hash = sha256_hex(access_token)`.
- Authenticated request with the plaintext AT works; with the stored hash string as bearer fails (401).
- Migration test on a database that already contains plaintext sessions: after migrating the table is EMPTY and was physically
  rewritten (new relfilenode); plaintext columns are gone; constraints/indexes/grants exist; a failing TRUNCATE rolls everything
  back; down migration empties the table and restores the old shape (run up → down → up).
- Rotation, pending/consumed, reuse and worker candidates over the hash columns are covered by `token_hashing_test.exs`.
- Grep guard: hash-keyed store entry points are only used by RefreshWorker and HttpPublic; `rotate_tokens/1` rejects both keys.
- Test helpers that read `matrix_sessions` by `access_token`/`refresh_token` in the 13 affected test files are ported to the
  hash columns/`hash_token/1` without weakening assertions.
- Grep guard test (or invariant): no `INSERT INTO matrix_sessions`/`WHERE access_token =` against plaintext remains in `server/lib`.

## Dev Notes

- Only `matrix_session_store.ex` (and the RefreshWorker's own candidate SQL ~l.237) touch the table in `server/lib`; the rest
  is comments/consumers of the store API. 13 test files reference `matrix_sessions`/`MatrixSessionStore`.
- Base branch is `bugfix/matrix-session-refresh` (commit bd4b1705+): it rewrote the same store; this story must be merged
  after it. Migration numbering: the other pipeline may add `000035` meanwhile, renumber at merge if needed.
- Pipeline-protected paths are touched only inside this run. Consider (separately, not here) wiring `cleanup_expired/0`; and
  renaming `has_open_grace_window?/1` to "pending sibling" wording (follow-up noted in the previous story).
- Out of scope: OAuth work (`feature/migrate-to-oauth2`), token pepper/HMAC, hashing of `jwt_device_bindings` (already hashed).

## Dev Agent Record

### Implementation Notes

- Migration `000035_matrix_sessions_token_hashing` (up: add hash columns, TRUNCATE all sessions (no backfill; forced re-login), NOT NULL, drop plaintext
  columns, PK/UNIQUE on hash columns; down: delete all sessions, restore plaintext shape). STOP-THE-WORLD release (old nodes query
  the dropped column). The redundant extra index on `refresh_token_hash` was dropped (the UNIQUE constraint indexes it).
  The migration number 000035 may collide with a parallel pipeline: check at merge and renumber (keep it gap-free).
- `MatrixSessionStore.hash_token/1` is the single hashing seam. Hash-addressed variants: `get_by_access_token_hash/1`,
  `extend_in_place_by_hash/3`, `delete_by_access_token_hash/1`, and `rotate_tokens/1` accepts `:old_access_token_hash`
  (HttpPublic passes the hash from the session map; RefreshWorker candidates are hashes).
- Docs: `08-concepts.md`, `05-building-blocks.md` updated for hashed storage.
- Kassandra "AT/RT stored unhashed" notes in `security-reports/*.md` are left unchanged (audit trail); the resolution is recorded in an appended "Resolution (cycle 1)" block in the security review report. They are **resolved by this story**.
- Side finding (NOT fixed, out of scope): `POST /logout` calls `invalidate_user_sessions` with `device_id: ""`, which deletes ALL of
  the user's sessions rather than only the logging-out device's.

### File List

- server/priv/migrations/000035_matrix_sessions_token_hashing.up.sql / .down.sql (new)
- server/lib/nebu/matrix/session/matrix_session_store.ex, refresh_worker.ex; server/lib/nebu/matrix/http_public.ex
- docs/architecture/08-concepts.md, 05-building-blocks.md
- tests: token_hashing_test.exs, token_hashing_migration_test.exs, release_test.exs, refresh_semantics_test.exs (+ ported files)

### Change Log

- 2026-10-08: matrix_sessions stores token hashes only (AC1-AC7).
