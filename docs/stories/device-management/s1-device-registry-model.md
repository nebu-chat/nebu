---
story_id: s1-device-registry-model
title: "Device registry model — device identity separate from device keys"
epic: device-management
status: done
security_review: required
matrix: true
ui: false
created: 2026-06-26
---

# S1 — Device registry model

## Story

**As** the Nebu platform,
**I want** a device to be a first-class entity with its own identity + metadata, separate from the
optional cryptographic key blob it may publish,
**so that** every device a user logs in with can be listed and managed even if the client never
uploads E2EE device keys.

The `fix-device-key-registration` bugfix stores a device only inside `device_keys`, whose
`device_keys_json` column is `NOT NULL` — so a device exists only once crypto keys are uploaded.
Device management needs device existence to be driven by the session/login (S2), independent of keys.

## Background / current state

- Migration `000009` created `device_keys` (PK `(user_id, device_id)`, `device_keys_json NOT NULL`,
  `display_name`, `last_seen_ts`, …), `device_one_time_keys`, `device_fallback_keys`.
- `Nebu.Matrix.DeviceKeyStore` reads device identity (`list_devices/1`, `get_device/2`,
  `query_devices/1`, `sole_device_id/1`) from `device_keys`.
- **`000009` is SHIPPED / immutable.** The bugfix is being merged and deployed (the operator's Stackit
  installation needs it to clear the device_id error), so `000009` reaches production. This story must
  **NOT** edit `000009`. It adds a **new forward migration** and must **backfill** so an already-deployed
  DB (with existing `device_keys` rows) upgrades cleanly.

## Acceptance Criteria

1. **AC1 — `devices` table via a new forward migration (+ backfill).** A **new** migration
   `0000NN_devices.up/down.sql` (NOT an edit to `000009`) creates a `devices` table: `(user_id,
   device_id)` PK, `display_name` (nullable), `last_seen_ts` (nullable), `last_seen_ip` (nullable),
   `created_at`, `updated_at`. The up-migration **backfills** a `devices` row from every existing
   `device_keys` row (carrying over `display_name`/`last_seen_ts`/`created_at`), so a Stackit DB that
   already ran `000009` upgrades without data loss. A device row can exist with **no** key material.
2. **AC2 — keys reference a device.** `device_keys` holds only the crypto blob
   (`device_keys_json`) for a `(user_id, device_id)` that exists in `devices`. (Implementation may
   make `device_keys_json` `NOT NULL` again *within* the keys table, since a keys row only exists
   when keys were uploaded — the nullability moves to "does a `device_keys` row exist".) Uploading
   keys for a device upserts the `devices` row first.
3. **AC3 — store API.** `Nebu.Matrix.DeviceKeyStore` (or a new `Nebu.Matrix.DeviceStore`) exposes:
   `upsert_device/3`, `list_devices/1`, `get_device/2`, and the existing key operations, all reading
   device identity from `devices`. `query_devices/1` joins `devices` + `device_keys` and returns only
   devices that have published keys (Matrix `/keys/query` semantics unchanged).
4. **AC4 — `GET /devices` unchanged contract, new source.** `GET /devices` and `GET /devices/{id}`
   return the same JSON shape as today but sourced from `devices` (so a keyless device still appears).
5. **AC5 — no regression.** `/keys/upload`, `/keys/query`, `/sync` OTK counts, and the E2EE guardrail
   behave exactly as after the bugfix (existing `device_keys_test.exs` integration tests stay green,
   adapted only where the device-identity source changed).

## Acceptance Tests

### Tests written FIRST:

1. **DeviceStore: keyless device** — ExUnit `:integration`
   - Given: `upsert_device(user, "DEV1", display_name: "Phone")` with no key upload
   - When: `list_devices(user)`
   - Then: `DEV1` is listed (with `display_name: "Phone"`), and `query_devices([user])` does **not**
     include it (no keys published).
2. **Key upload upserts the device** — ExUnit `:integration`
   - Given: a fresh user
   - When: `POST /keys/upload` with `device_keys` for `DEV2`
   - Then: a `devices` row for `DEV2` exists AND `query_devices([user])` echoes it.
3. **Backfill: pre-existing device_keys → devices** — ExUnit `:integration`
   - Given: a `device_keys` row exists (simulating a Stackit DB that ran `000009` before this migration)
   - When: the new migration runs (or the backfill path is exercised)
   - Then: a matching `devices` row exists with the carried-over `display_name`/`created_at`, and
     `GET /devices` lists it.
4. **Regression: bugfix contracts intact** — re-run `device_keys_test.exs` round-trip/query/OTK/
   guardrail tests against the refactored store; all green.

## Dev Notes

- Prefer **split tables** (`devices` + `device_keys`) over making `device_keys_json` nullable — cleaner
  separation of device lifecycle vs. key lifecycle, and S2/S3/S4 all key off `devices`.
- **New forward migration only — `000009` is immutable (shipped to Stackit).** The up-migration
  creates `devices` and backfills from `device_keys`
  (`INSERT INTO devices (user_id, device_id, display_name, last_seen_ts, created_at, updated_at)
  SELECT user_id, device_id, display_name, last_seen_ts, created_at, updated_at FROM device_keys
  ON CONFLICT DO NOTHING`). Idempotent (`IF NOT EXISTS`), matches the `00000N_*` naming + BIGINT
  epoch-millis convention. Bump the `release_test.exs` migration-count assertion accordingly.
- Keep inline SQL (ADR-018), cluster-correct (ADR-020).
- Do **not** touch `user_keys` (ADR-007 per-user signing/PII keys) — unrelated to device identity.

## Tasks / Subtasks

- [x] AC1 — New forward migration `000010_devices.up/down.sql` creating the `devices` table
  (PK `(user_id, device_id)`, `display_name`, `last_seen_ts`, `last_seen_ip`, `created_at`,
  `updated_at`) + `idx_devices_user`, with an idempotent backfill from `device_keys`
  (`ON CONFLICT DO NOTHING`; `last_seen_ip` left NULL — no source). `000009` untouched. Migration-count
  assertion in `release_test.exs` already bumped to 1–10.
- [x] AC2 — `DeviceKeyStore.put_device_keys/4` upserts the `devices` row FIRST (carrying
  `display_name`), then the `device_keys` crypto row. Device existence is independent of keys.
- [x] AC3 — Store API: added `upsert_device/3` (idempotent, COALESCE-update of metadata);
  re-sourced `list_devices/1`, `get_device/2`, `sole_device_id/1` from `devices`;
  `query_devices/1` now JOINs `devices` + `device_keys`, returning only key-bearing devices,
  with `device_display_name` sourced from `devices`.
- [x] AC4 — `GET /devices` and `GET /devices/{id}` unchanged contract, now sourced from `devices`
  (keyless devices appear). No router signature changes needed. Optional `last_seen_ip` added to the
  device shape (omitted when null).
- [x] AC5 — No regression: `/keys/upload`, `/keys/query`, `/sync` OTK counts, and the E2EE guardrail
  behave as before; existing `device_keys_test.exs` stays green.

## Dev Agent Record

### Completion Notes

- Single-module decision: kept `Nebu.Matrix.DeviceKeyStore` (story-permitted) rather than a new
  `DeviceStore` module — minimises churn at the router (function names unchanged).
- `device_row/1` now emits an optional `last_seen_ip` (omitted when null, never serialised as null) —
  Matrix Device shape permits it.
- Backfill verified against the live dev DB: applying `000010` inserted 15 `devices` rows from existing
  `device_keys`, and a `device_keys LEFT JOIN devices` orphan count returned 0.
- Test-review MINOR findings addressed in `device_store_test.exs`: deleted the unused `otk/1` helper
  (MINOR-4, warnings-as-errors gate), added the keyless `GET /devices/{id}` shape-parity check
  (MINOR-2), the idempotent double-`upsert_device/3` assertion (MINOR-3), and a SQL-level backfill
  orphan-invariant assertion scoped to the test user (MINOR-1).
- T3 backfill test adjusted: a `device_keys` row seeded *after* boot-time migration cannot be covered
  by the boot-time backfill, so the test now exercises the migration's own idempotent backfill SQL —
  the practical ExUnit expression of "the backfill path is exercised".

### Validation

- `make build-server` → EXIT 0, zero warnings.
- `make test-unit-elixir` (full DB-less suite, `--warnings-as-errors`) → EXIT 0, zero warnings.
- Integration (`device_store_test.exs` + `device_keys_test.exs` + `release_test.exs`, `--include
  integration --warnings-as-errors`, against live PostgreSQL with `000010` applied) → EXIT 0, all green.

## File List

- server/priv/migrations/000010_devices.up.sql (new)
- server/priv/migrations/000010_devices.down.sql (new)
- server/lib/nebu/matrix/device_key_store.ex (modified)
- server/test/nebu/matrix/device_store_test.exs (modified — MINOR-1..4 + T3 backfill path)

## Change Log

- 2026-06-26 — S1 device registry model: new `devices` table (000010) + backfill from `device_keys`;
  `DeviceKeyStore.upsert_device/3` added; device-identity reads re-sourced from `devices`;
  `query_devices/1` joins both tables. Test-review MINOR findings addressed. (Amelia)

## Status

review
