## Security Review — matrix-session-refresh-fixes / token-hashing-matrix-sessions

**Diff scope:** staged diff on `bugfix/token-hashing-matrix-sessions`. `matrix_sessions` now stores the hex SHA-256 of the AT/RT
(`access_token_hash` PK, `refresh_token_hash` UNIQUE) instead of plaintext. Migration 000035 (up: backfill + drop plaintext;
down: delete all sessions + restore the old shape). `MatrixSessionStore.hash_token/1` is the single hashing seam, with `*_by_hash`
variants for RefreshWorker and `/refresh` rotation. The diff also covers tests, docs, and `NEBU_DB_URL_MIGRATE` in Makefile/.gitlab-ci.yml.
**Date:** 2026-10-08
**Reviewer:** Kassandra (OWASP ASVS L2, STRIDE, CWE-256/257/312/916)
**Predecessor:** `refresh-worker-and-retry-semantics-security-review-2026-10-07.md`. I-1 / R-5 (plaintext AT/RT) is closed by this diff, with the residual described in F-1. R-1..R-4 and R-6 are unchanged.
**Known, out of scope:** `POST /logout` deletes all of the user's sessions (`device_id: ""`). This is not part of this diff.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `server/priv/migrations/000035_matrix_sessions_token_hashing.up.sql:26-36` | CWE-312 residue: PostgreSQL `DROP COLUMN` only marks the column as dropped, and the data stays physically in the heap tuples. The backfill `UPDATE` (l.26) also writes new tuple versions that still contain the plaintext. The live, still-valid plaintext AT/RT of every migrated session therefore stays on disk until that row is updated again. It also ends up in every physical backup, snapshot, or replica taken AFTER the migration. AC1 ("no plaintext at rest") is only met at the SQL level. | Force a heap rewrite in the same migration transaction after the DROP, e.g. `CLUSTER matrix_sessions USING matrix_sessions_pkey;` (single-table CLUSTER is allowed in a transaction block, and `reform_and_rewrite_tuple` nulls dropped columns). Alternatives: copy the table (CREATE/INSERT SELECT/DROP/RENAME + re-GRANT + indexes) or `ALTER COLUMN ... TYPE text USING col \|\| ''` (forces a rewrite). Stricter option: the up migration deletes all sessions (forced re-login), which also makes old backups/WAL worthless (see I-2). Add a test that asserts `pg_class.relfilenode` changes (rewrite happened). |
| F-2 | LOW | `000035...up.sql` (whole) + deploy | Availability (STRIDE D) on a rolling/multi-node deploy: after the commit, old-code nodes query `access_token`, which no longer exists. `safe_query` returns `{:error,_}`, `OidcPlug` responds with a HARD `401 M_UNKNOWN_TOKEN` without `soft_logout`, and clients log out completely (Element discards the session and local E2EE state). Logins on old nodes fail with 500. In addition, `ACCESS EXCLUSIVE` holds the table for the backfill. The table has no sweeper and grows by one row per refresh. Not attacker-triggerable. | Release note/runbook: deploy 000035 as stop-the-world (stop all nodes, migrate, start new nodes), no rolling update. Optionally run `cleanup_expired/0` before the migration (shorter lock). |
| F-3 | LOW | `matrix_session_store.ex:156, 460, 622, 364` | Pass-the-hash latent: `get_by_access_token_hash/1`, `extend_in_place_by_hash/3`, `delete_by_access_token_hash/1` and the `rotate_tokens/1` key `:old_access_token_hash` are public `def`s and accept a hash directly as an identifier. Verified: today they are fed ONLY with DB-derived hashes (`refresh_worker.ex:255/365/382` from `candidates/0`, `http_public.ex:737` from `sess.access_token_hash`). No request input reaches them, so there is no current exploit. A future caller that passes client input in would turn a leaked DB hash into a credential and undo this fix. `rotate_tokens/1` silently prefers the hash when both keys are set. | Mark the variants `@doc false` with a warning ("never pass client-supplied values"). Add a grep-guard test (callers of `*_by_hash`/`:old_access_token_hash` only in `refresh_worker.ex` and `HttpPublic.rotate_attempt/6`). In `rotate_tokens/1`, reject maps with BOTH keys (raise -> `safe_rotate` -> 503, fail-closed). |
| I-1 | INFO | `matrix_session_store.ex:76, 83`; `http_public.ex:379-380, 723-724` | Hash choice is sound: every AT/RT comes from `generate_opaque_token/0` = `:crypto.strong_rand_bytes(32)` (256-bit CSPRNG, lowercase hex). Unsalted SHA-256 is enough. Preimage or brute force over 2^256 is infeasible, rainbow tables do not apply, and a KDF would only cost latency on the auth hot path (CWE-916 does not apply to high-entropy tokens). Hex is ASCII, so `convert_to(col,'UTF8')` in the backfill is byte-identical to `:crypto.hash/2` over the binary. A pepper/HMAC adds no confidentiality. As defense in depth it would only stop session forging by a DB-WRITE attacker (INSERT of a row with the hash of a self-chosen token). That was equally possible with plaintext, and DB write is out of the threat model. The story explicitly descopes it. | None. Optional follow-up: HMAC-SHA-256 with an app-held key, if DB write by third parties (e.g. DBA/support) enters the threat model. |
| I-2 | INFO | Operations / threat model | The backfill keeps sessions VALID. Plaintext tokens in backups, PITR/WAL archives, and replica snapshots from BEFORE the migration stay usable until the session expires naturally. The backfill UPDATE also writes the plaintext into the WAL once more. | Operator note in the release notes: if a backup/WAL leak is in the threat model, invalidate all opaque sessions after the migration (`DELETE FROM matrix_sessions`, forced re-login) and age out old backups/WAL archives under the retention policy. |
| I-3 | INFO | `refresh_worker.ex:214, 267`; `matrix_session_store.ex:547-632`; `refresh_worker.ex:352` | Logging: `Nebu.Repo` `log: false` (config.exs + runtime.exs:192/260), `QueryTelemetry` without parameters. `pg_stat_statements` normalizes parameters. New log lines are static literals plus `user_id`/`device_id` metadata. A hash can only show up in exception texts (`inspect(e)` in the worker; Postgrex unique-violation `detail` on an INSERT collision, practically impossible). That is not a credential (see the pass-the-hash check) and is an improvement over the plaintext before. Stale comment `refresh_worker.ex:352` (`sess.access_token`). | Fix the comment to `sess.access_token_hash`. |
| I-4 | INFO | `oidc_plug.ex:77`, `http_public.ex:572/771` | Pass-the-hash closed at every request entry point: Bearer (`get_by_access_token/1`), `/refresh` RT (`resolve_refresh_token/1`), replay RT (`hash_token(replay_rt)` in `rotate_tokens/1`), logout `revoke/1`, `get_auth_context/1`, `mark_access_token_used/1`, `has_open_grace_window?/1`. All of them hash client input. A presented hash (64 hex chars, no dot, takes the opaque path) gets hashed again and does not match (401). Covered by `token_hashing_test.exs:522ff`. The old timing/existence oracles (old I-4, N-9) disappear: the B-tree compare runs on SHA-256 output the attacker cannot steer. | None. |
| I-5 | INFO | `000035...down.sql:11-27` | The down migration deletes ALL sessions. That is availability, not confidentiality, and it is documented. After a rollback, old code writes plaintext tokens again (CWE-312 returns for new sessions). This is expected rollback behavior. | Mention in the release notes: a rollback means a mass re-login and plaintext storage again. |
| I-6 | INFO | `Makefile:166/184/199`, `.gitlab-ci.yml:363` | `nebu_migrate:nebu_migrate_dev_pw` is the existing dev value from `docker-compose.yml:73`. No new secret is introduced. The test DB is ephemeral. Prod uses a tofu-generated password (`deploy/tofu/examples/*/cloud-init.tftpl`). Grants: the table is ALTERed in place, so the table-level `GRANT ... ON matrix_sessions TO nebu_app` (000002:385) stays. There is no RLS or column grant on `matrix_sessions`. The migration runs in ONE runner transaction (`release.ex:163`), so a failure leaves no partial state. | None. |
| I-7 | INFO | `matrix_session_store.ex:261-365, 372-397, 449-470` | Cluster safety unchanged: the same guarded statements (`WHERE access_token_hash=$1 AND revoked_at IS NULL`, FOR UPDATE replay check, sibling locking with deterministic `ORDER BY access_token_hash`). Sort order now follows a hash instead of the token, which is still a total order, so no deadlock risk. Without either key, `old_access_token_hash/1` throws a FunctionClauseError, which `safe_rotate` turns into a 503 (fail-closed). No new TOCTOU windows. No new test seam in `lib/`. | None. |
| I-8 | INFO | `token_denylist.ex:187, 200` | A second, identical SHA-256-hex formula exists in `TokenDenylist` (pre-existing, its own purpose, not the matrix_sessions store). AC2 ("single seam") applies to the store and is met. | Optional: keep both formulas in sync via a shared helper (no security delta). |

### Detail

**F-1 — Plaintext tokens survive DROP COLUMN physically [MEDIUM]**
PostgreSQL docs (ALTER TABLE, DROP COLUMN): "does not physically remove the column ... The space will be reclaimed over time as existing rows are updated."
The migration runs the backfill `UPDATE` (new tuple versions with plaintext + hash), then `DROP COLUMN`, `ADD PRIMARY KEY`, `ADD UNIQUE`, and `CREATE INDEX`.
None of these steps rewrites the heap. As a result, every migrated active row keeps its still-valid AT and RT as bytes in the table file. It is not readable through
SQL (nebu_app/SQL injection cannot see it), but it is readable through file access, `pg_basebackup`/volume snapshot/replica disk, or `pageinspect` (superuser).
Exactly these leak vectors ("backup, replica") are what the story names as its threat model. Rows only lose the data once they are UPDATEd again
(worker `extend_in_place`, rotation). Dormant devices whose RT is still redeemable keep it indefinitely. The dead tuple versions of the backfill also stay in the
pages until VACUUM reuses the space. Exploiting this requires physical/backup access to the DB, hence MEDIUM (defense-in-depth gap against the story's own AC1),
not HIGH.
**Fix:** at the end of `000035...up.sql`, add `CLUSTER matrix_sessions USING matrix_sessions_pkey;` (new relfilenode, dropped columns nulled, old file
unlinked at commit). Or rebuild the table by copying it. Add a test (relfilenode changed, or at least a migration-test assertion). Plus the operator note from I-2.
If no-forced-re-login is not a hard requirement, the clean alternative is a `DELETE FROM matrix_sessions` in the up migration instead of the backfill (resolves F-1 and I-2 completely).

**F-2 — Rolling deploy leads to hard logouts [LOW]**
Nebu supports clustered operation. The migration breaks the schema contract of the old code at once (no expand-contract). Old nodes answer every opaque token with
`M_UNKNOWN_TOKEN` without `soft_logout` until they are replaced. That is spec-compliant for "unknown token" and leads to a full client logout, including the loss of the local
Megolm/device state. **Fix:** stop-the-world deploy for this release (release note), or expand-contract in two releases
(this would delay the plaintext deletion and is therefore not recommended).

**F-3 — Hash-addressed public API is a latent pass-the-hash surface [LOW]**
All three `*_by_hash` functions and `:old_access_token_hash` treat the hash as a sufficient row identifier. That is correct as long as the hash comes from the DB.
The type system cannot tell a hash apart from a token (both are 64 hex chars). **Fix:** `@doc false` plus a warning, a grep-guard test on the call sites,
and reject ambiguous rotate params (both keys).

### Verified controls

- Every SQL statement on `matrix_sessions` in `lib/` (store + `refresh_worker.ex:237`) uses hash columns. No remaining read of `.access_token`/`.refresh_token` on session maps (grep). No KeyError dump of a session map possible.
- Parameter binding everywhere (`$n`); `select_sql/1` interpolates only static literals. No injection vector in the migration (static DDL/DML).
- Fresh tokens are returned to the client only once (`http_public.ex:747-750`) and are never read back from the DB.
- Backfill formula == `hash_token/1` (ASCII hex tokens); migration in one transaction; constraint/index names consistent (down restores `matrix_sessions_pkey`/`_refresh_token_key`/`idx_matrix_sessions_refresh_token`).
- OIDC RT stays AES-256-GCM (`SecretBox`); no change.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 (F-1) — advisory, address before epic end
LOW: 2 (F-2, F-3) — advisory
INFO: 8 (I-1..I-8)

**Classification: CLEAN**
**Verdict: APPROVED** (not blocked). Predecessor I-1/R-5 (plaintext AT/RT) is CLOSED at the SQL level. The physical residue (F-1) and the backup/WAL residual
(I-2) remain and should be closed in this cycle via `CLUSTER` in the migration plus a release-note operator note.

---

## Delta check 2026-10-08

**Scope:** staged diff after the remediation. F-1 is resolved by owner decision: the up migration TRUNCATEs all sessions, with no backfill and no CLUSTER. F-2 is handled by documenting a stop-the-world deploy. F-3 is handled by `@doc false`, a grep guard, and `ArgumentError` on ambiguous rotate params. This was a read-only review; no migration or test was run.

### Status of the previous findings

| # | Status | Evidence |
|---|--------|----------|
| F-1 | **CLOSED** | `000035...up.sql:36-52` runs ADD COLUMN, then `TRUNCATE`, then SET NOT NULL, then DROP COLUMN, then PK/UNIQUE, all inside ONE runner transaction (`release.ex:163` `Postgrex.transaction`). TRUNCATE gives the heap AND all indexes (old PK on `access_token`, `refresh_token_key`, `idx_matrix_sessions_refresh_token`) plus the TOAST relation new relfilenodes. The old files are truncated/unlinked at commit/checkpoint. DROP COLUMN therefore runs on an empty relation, so no tuple with dropped plaintext attributes exists. The order has no residue window: nothing between TRUNCATE and DROP writes plaintext, and outside observers only see the committed end state. TOAST: AT/RT are 64-char hex (<< 2 kB TOAST_TUPLE_THRESHOLD), so they were never toasted, and the TOAST relfilenode is renewed anyway. The migration contains no token literals, so `pg_stat_statements` and server logs get nothing (static DDL). The TRUNCATE WAL record holds no tuple data. Pre-migration WAL/PITR/replica/backup copies still contain plaintext, but every session is gone, so they are cryptographically worthless (no row matches). Freed filesystem blocks can only be recovered forensically and are worthless for the same reason. Test `token_hashing_migration_test.exs:290-301` asserts the table is empty and has a new relfilenode. I-2 (backup/WAL residual) is CLOSED by this as well. |
| F-2 | **CLOSED** (operational) | Stop-the-world is documented in the migration header (l.20-25), `07-deployment.md` (release note), `08-concepts.md`, and the story. TRUNCATE on an empty-to-small table removes the backfill lock duration. The rolling-deploy hazard still exists technically, but it is a documented operator obligation and not attacker-triggerable. |
| F-3 | **CLOSED** | The three `*_by_hash` functions are `@doc false` and carry the pass-the-hash warning (`matrix_session_store.ex:151-155, 463-467, 625-629`). `old_access_token_hash/1` (l.366-373) raises `ArgumentError` when BOTH keys or NEITHER key is present, and the raise happens before `Repo.transaction`, so there is no partial state. The only caller of `rotate_tokens/1` in `lib/` is `safe_rotate/1` (`http_public.ex:804-813`, `rescue _ -> :unavailable`), so the result is a 503 and fail-closed. Grep guard: `token_hashing_test.exs:1152-1168`, plus the `@doc false` assertion at l.1170-1180. See D-2 for the residual. |

### New findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| D-1 | INFO | `000035...up.sql:19`, `07-deployment.md` (release note, last line) | Imprecise doc: "TRUNCATE requires ownership". In fact TRUNCATE needs the `TRUNCATE` privilege, which the owner has implicitly. **No new privilege requirement:** the same migration already needs ownership for `ALTER TABLE ... DROP COLUMN`/`ADD PRIMARY KEY`, and 000012:40 already ALTERed `matrix_sessions` successfully. Role model verified: `nebu_migrate` owns tables and runs migrations (`docker-compose.yml:73`, `deploy/tofu/examples/{upcloud,stackit}/database.tf` + `cloud-init.tftpl:464/472`, NOSUPERUSER). `nebu_app` has only `SELECT/INSERT/UPDATE/DELETE` on the table (000002:385), with NO TRUNCATE, so the runtime role cannot mass-truncate. If the runner falls back to `NEBU_DB_URL` (nebu_app) on a dual-role DB, the migration fails ATOMICALLY on the first ALTER (one transaction, nothing partial). It does not escalate privileges and needs no superuser. | Optional wording: "requires the TRUNCATE privilege (implied by ownership, which the ALTERs need anyway)". |
| D-2 | INFO | `token_hashing_test.exs:1154-1168` | Guard granularity: the allowlist works per FILE and includes `http_public.ex`, the module that processes ALL client input. A future call `get_by_access_token_hash(client_value)` in `http_public.ex` would pass the guard. Dynamic invocation (`apply/3` with a computed atom) also bypasses the regex. Today there is exactly one use in `http_public.ex:737` (`sess.access_token_hash`, DB-derived). This is a tripwire, not a boundary, so it is not a vulnerability. | Optional: pin the number of hits per allowed file (e.g. `http_public.ex` == 1, only `:old_access_token_hash`), or allowlist at the function level. |
| D-3 | INFO (release note) | Operations, mass logout | TRUNCATE ends ALL opaque sessions of ALL devices AT THE SAME TIME. Clients get `401 M_UNKNOWN_TOKEN` without `soft_logout`. Element/FluffyChat run a full logout and discard the local crypto store (Olm/Megolm session keys). Nebu offers **no server-side key backup** (`GET /room_keys/version` returns 404, `protected.ex:266`), and E2EE key escrow (ADR-011) is only "Proposed". Because every device of a user is logged out together, no surviving device can share keys. **Encrypted room history becomes irreversibly unreadable** for users without a manual key export. This is availability/integrity of user data, not confidentiality. It was decided by the owner. Old `devices`/device keys stay in place, so senders keep encrypting to dead devices for a while (no leak, the private keys are deleted). JWT-mode sessions (`jwt_device_bindings`) are not affected. | Release note/runbook: announce the upgrade ahead of time and ask users to export room keys (Element: Settings -> Security -> Export E2E room keys) and re-import after re-login. Schedule a maintenance window. Optionally announce it to admins in-product. |

### Re-check of the persistent controls

- **Logging law:** the remediation adds only static `ArgumentError` messages (no params/token interpolation). `safe_rotate` swallows the exception without logging, so no hash ends up in the log. `Nebu.Repo log: false` is unchanged. OK.
- **Parameter binding:** every new/changed statement uses `$n`. The migration is static DDL. OK.
- **Fail-closed:** the ArgumentError leads to a 503 (not 200/500 with state). TRUNCATE also removes hard-revoked rows, so an old RT afterwards is `:error` and gets a 401 (never a resurrection). Non-binary client RT inputs are rejected before `hash_token/1` (`http_public.ex:562`), so there is no FunctionClauseError DoS path. OK.
- **Pass-the-hash:** every request entry point still hashes client input (I-4 unchanged). The `*_by_hash` call sites are DB-derived only (`refresh_worker.ex` `candidates/0`, `http_public.ex:737`). OK.

### Summary (delta)

CRITICAL: 0 · HIGH: 0 · MEDIUM: 0 (F-1 CLOSED) · LOW: 0 (F-2, F-3 CLOSED) · INFO: 3 new (D-1..D-3) + I-1, I-3..I-8 unchanged (I-2 CLOSED)

**Final classification (whole diff): CLEAN**
**Verdict: APPROVED.** The release note must carry D-3 (key export before the upgrade, maintenance window) and F-2 (stop-the-world).

## Resolution (cycle 1)

The first part of this report describes the rejected backfill/CLUSTER design and is kept unchanged as audit trail. Status after the cycle-1 remediation:

- F-1 and I-2: CLOSED by `TRUNCATE` (owner decision 2026-10-08: all sessions are deleted, everybody logs in again; no backfill, so no plaintext residue in old row versions).
- F-2: CLOSED by the migration header, `docs/architecture/07-deployment.md` and `08-concepts.md` (release is stop-the-world).
- F-3: CLOSED by `@doc false` on the `*_by_hash` functions, a grep guard test and `ArgumentError` on invalid rotate params.
- I-7: now raises `ArgumentError` (no longer `FunctionClauseError`).
- D-1 (TRUNCATE privilege wording) and D-3 (E2EE/mass-logout release note) are reflected in the migration header and `07-deployment.md`.
