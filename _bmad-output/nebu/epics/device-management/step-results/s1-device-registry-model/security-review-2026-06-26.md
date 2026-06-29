## Security Review — s1-device-registry-model (epic: device-management)

**Reviewer:** Kassandra (adversarial security review, SEC Gate 1)
**Diff scope:** Staged changes for story S1 — new `devices` table (migration 000010 up/down) + backfill from `device_keys`; `Nebu.Matrix.DeviceKeyStore` (`upsert_device/3`, `put_device_keys` now upserts the device row first, `list_devices`/`get_device`/`sole_device_id`/`query_devices` re-sourced from `devices`); comment-only change to `GET /devices` in `protected.ex`; tests (`device_store_test.exs`, `release_test.exs`).
**Date:** 2026-06-26
**Verdict:** **APPROVED / CLEAN** — no CRITICAL/HIGH. 2 LOW advisories, both pre-existing family-wide gaps already tracked in MEMORY, neither a regression introduced by S1.

This review was executed against the S1 entries of the device-management Epic Watch-List recorded in MEMORY.md on 2026-06-26.

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | LOW | `000010_devices.up.sql` (table DDL) | New `devices` table ships with NO `ENABLE ROW LEVEL SECURITY` + per-user policy. Defense-in-depth gap. | Add RLS + per-user policy, OR add one line to the migration header explicitly documenting the deliberate omission and citing the family-wide pattern. NOT blocking — consistent with sibling auth tables `matrix_sessions` (000001) and `device_keys` (000009), both of which also lack RLS; every query is application-scoped by `user_id` from the validated session. |
| F-2 | LOW | `device_id` write boundary (PK of `devices`) | Client-chosen opaque `device_id` lands in the `devices` PK with no explicit length bound (≤255) or control-char rejection at the write boundary. | Validate/bound `device_id` at the write boundary. Correct home for this is S2 (where login/`upload_device_id` device_id handling is in scope). NOT new in S1: the identical unbounded string already keys `device_keys` (000009, shipped); S1 only mirrors the existing sink. |

---

### Detail

**Special-attention items from the review brief — all verified CLEAN.**

**(A) SQL injection — new INSERT / backfill / upsert / JOIN.** All statements are fully parameterised or pure server-internal SQL:
- `upsert_device/3` INSERT…ON CONFLICT — values passed as `$1..$6`; the `VALUES ($6, $6)` reuse is the same bound `now` parameter, not interpolation.
- `put_device_keys/4` — both writes parameterised (`$1..$6`); `user_id`/`device_id` are positional params.
- The **backfill** `INSERT INTO devices (...) SELECT user_id, device_id, ... FROM device_keys ON CONFLICT DO NOTHING` takes **no parameters at all** — it copies server-internal rows; no user-controlled string reaches the statement.
- `query_devices` JOIN uses `USING (user_id, device_id)` (static identifiers) and `WHERE dk.user_id = ANY($1)` (bound array).
- `list_devices`/`get_device`/`sole_device_id` — `WHERE user_id = $1 [AND device_id = $2]`, bound.
All routed through `query/2 → Ecto.Adapters.SQL.query` and `safe_query/2`. No string interpolation of user input anywhere. **No injection vector.**

**(B) IDOR / cross-user scoping (G3) — the highest-priority S1 check.** Every changed read/write is scoped to the session user:
- `list_devices(conn.assigns[:current_user])` — `WHERE user_id = $1`, only ever the session user. A user cannot list another user's devices.
- `get_device(conn.assigns[:current_user], device_id)` — `WHERE user_id = $1 AND device_id = $2`; `user_id` from the validated session. Foreign or unknown device → `nil` → `404 M_NOT_FOUND`. No `403`, no existence oracle.
- `upsert_device` / `put_device_keys` — `user_id` is always `conn.assigns[:current_user]` (protected.ex:299,319); **never** body-supplied. A user cannot write a `devices` row under another user's id.
- `query_devices` (the `/keys/query` directory) is intentionally cross-user by spec, returns only **public** device-key blobs for explicitly-requested users; the new JOIN narrows (key-bearing only), never widens, scope. The caller (`query_device_keys/1`) returns only the requested `{user_id => [device_ids]}` slice. No IDOR.

**(C) `sole_device_id` mis-attribution (explicit brief concern).** `sole_device_id/1` now reads `devices` (incl. keyless) instead of `device_keys`. It is reached from `upload_device_id/2` **only** when the body has no `device_id` AND the token carries no bound `device_id` (raw-JWT OTK top-up). The function is strictly scoped to `current_user`'s own rows (`WHERE user_id = $1 LIMIT 2`, returns a value only on exactly one row). Therefore:
- It can **never** cross users — worst case is attributing the caller's OWN OTK to the wrong one of the caller's OWN devices, and only when there is exactly one device (no ambiguity).
- The source change makes a 1-keyless-device user resolve to that device (previously `nil`), which is the intended, more-correct attribution per the story Dev Notes.
No new cross-device-transfer primitive. **CLEAN.** (Note: the real device-id authority decision — body `device_id` authoritative over the token-bound device — lives in pre-existing `upload_device_id/2`, untouched by S1, and is the S2 fail-closed/binding item on the Watch-List.)

**(D) Backfill correctness / cross-contamination.** `SELECT user_id, device_id, ... FROM device_keys` is a **row-wise** copy of the composite `(user_id, device_id)` key from a single source row — no JOIN, no cartesian product — so a device can never be backfilled under the wrong user. `ON CONFLICT (user_id, device_id) DO NOTHING` makes it idempotent and safe to re-run on an already-migrated DB. `last_seen_ip` has no source in `device_keys` → correctly left NULL. Verified by `device_store_test.exs` (the "directly-seeded device_keys row is reflected in `devices`" test exercises byte-identical backfill SQL). **CLEAN.**

**(E) Migration hygiene (Watch-List S1.2).** 000010 is a NEW forward migration; it does not edit the shipped/immutable 000009. `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` + `ON CONFLICT DO NOTHING` → idempotent. Inline SQL (ADR-018). `release_test.exs` version list bumped to include `10`, with an explanatory comment. Down migration drops index then table with `IF EXISTS` and a data-loss WARNING. **CLEAN.**

**(F) Body-size / rate limits.** `GET /devices` and `GET /devices/{id}` are read-only, behind `OidcPlug`, return only the caller's own rows (bounded by the caller's device count), and accept no request body. `/keys/upload` retains its pre-existing `@max_keys_per_upload` (100) cap (untouched). No new unbounded surface.

**(G) JWT / session / impersonation.** S1 does not change token validation or session handling. `user_id` for every write/read is `conn.assigns[:current_user]` (the validated identity). S1 does not introduce a path where device identity diverges from the session in a way that enables impersonation — that surface (login honoring client `device_id`, token↔device binding) is S2 and out of scope here. **No regression.**

**(H) Weak crypto / plaintext secrets in logs / path traversal.** None. Directory-only metadata; no crypto primitives added; no logging of secrets; `URI.decode_www_form(device_id)` feeds a parameterised `WHERE device_id = $2` (no filesystem path). **CLEAN.**

---

### Watch-List reconciliation (MEMORY.md, device-management S1)

| Watch-List item | Result |
|---|---|
| `devices` table RLS or documented omission | F-1 LOW — consistent with `matrix_sessions`/`device_keys` family; documented omission recommended, not blocking. |
| New forward migration, idempotent, inline SQL, `release_test` count bumped | VERIFIED — all hold. |
| `device_id` length ≤255 + reject control chars at write boundary | F-2 LOW — not added; pre-existing sink mirrored from 000009; correct home is S2. |
| `sole_device_id` keyless mis-attribution | VERIFIED safe — scoped to caller's own devices, cannot cross users. |
| IDOR scoping in every new/changed query | VERIFIED — all scoped to session `user_id`. |

---

### Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 2 (F-1 devices-table RLS — family-wide gap; F-2 `device_id` input bound — pre-existing sink, close at S2)

**Verdict: APPROVED / CLEAN.** No commit-blocking findings. Both LOW items are pre-existing, family-wide defense-in-depth gaps already tracked in MEMORY — neither is introduced or worsened by S1. The S1 diff is correctly scoped, fully parameterised, IDOR-safe, and backfill-correct. Carry F-1 and F-2 to the epic-end SEC Gate 2 (F-2 expected to be resolved by S2's device_id write-boundary handling).
