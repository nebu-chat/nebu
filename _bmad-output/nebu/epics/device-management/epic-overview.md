# Epic: device-management

**Branch:** `feature/device-management` (branched from `bugfix/login-bugs-fixing`, which carries the
device-key directory foundation — commit `76ad0ef3`).

**Goal:** A user has N devices (the Matrix multi-device model). Each device is a first-class,
durable entity with metadata (display name, last-seen, created), manageable by the user via the
Matrix client API **and** by an operator per-user in the Admin UI. This is the full build-out of
the foundation laid by the `fix-device-key-registration` bugfix.

## Why a separate epic (and why from this branch)

The bugfix made the Matrix device-key endpoints stateful (`device_keys` table, `/keys/upload`,
`/keys/query`, `GET /devices`, migration `000009`). It deliberately stopped at "a device registers
cleanly". Full device *management* (lifecycle from login, rename, revoke, Admin UI, reliable
session↔device binding) is a distinct feature with its own surface and is scoped here.

Branched from `bugfix/login-bugs-fixing` (not `main`) because device-management **builds directly
on** the device-key directory, which is not yet merged to `main`.

> **Migration `000009` is treated as SHIPPED / immutable.** The bugfix will be merged and deployed
> (the operator's Stackit installation needs it to clear the device_id error), so `000009` reaches
> production. S1 therefore does **NOT** edit `000009` — it adds a **new forward migration** that
> creates the `devices` table and **backfills** a `devices` row from every existing `device_keys`
> row, so an already-deployed Stackit DB upgrades cleanly. Never alter a shipped migration.
on** the device-key directory, which is not yet merged to `main`. A useful consequence: migration
`000009` has **not shipped** yet, so this epic can refine its schema in place (story S1) without a
production data migration.

## Conflict assessment — does the bugfix block a full build-out?

**No blocker. The bugfix is a forward-compatible foundation.** Three things must be *extended/
refactored* (each is a story below), none is a wall:

| # | Bugfix state | What device-management needs | Story |
|---|---|---|---|
| 1 | `device_keys.device_keys_json NOT NULL` — a device row only exists once crypto keys are uploaded | A device must exist from **login**, independent of keys (a client may never upload keys) | S1 |
| 2 | Devices are derived from `/keys/upload`; `device_id` is absent from `conn.assigns` on raw-JWT sessions (the `sole_device_id` heuristic papers over this) | Devices created/updated at **login**; `device_id` reliably bound to the authenticated request; `sole_device_id` heuristic removed | S2 |
| 3 | No write endpoints (`PUT/DELETE /devices`, `POST /delete_devices`); delete must also revoke the `matrix_sessions` token | Full Matrix device-management API | S3 |
| 4 | No operator surface | Admin UI: per-user device list, rename, revoke | S4 |

The E2EE guardrail (reject `m.room.encryption` in every write path) and the orthogonality of the
key directory to encryption (ADR-011) are unaffected and carry forward unchanged.

## Key architecture decision (see ADR-007 + Oracle review 2026-06-26)

Device keys are **not** the user's identity key. The PRD's right-to-be-forgotten / signing key is the
**per-user** server-side `user_keys` pair (Ed25519 signing + X25519 PII-encryption, ADR-007) — one
per user, already implemented and wired to GDPR erasure. Matrix **device keys** are per-device,
client-generated, the private part never on the server. This epic keeps the **multi-device** model
intact and does **not** conflate the two. Right-to-be-forgotten stays on `user_keys`.

## Stories (sequential — S1 → S4)

1. **s1-device-registry-model** — Introduce a `devices` table (identity + metadata) separate from
   `device_keys` (crypto blob). A device can exist without keys. Refactor `DeviceKeyStore` /
   `GET /devices` to read device identity from `devices`. Make `device_keys` reference a device.
2. **s2-device-lifecycle-at-login** — Register/update a device row at login (from the session
   `device_id`); reliably bind `device_id` into the authenticated request (close the raw-JWT gap),
   removing the `sole_device_id` heuristic; track `last_seen_ts` / `last_seen_ip`.
3. **s3-matrix-device-endpoints** — `PUT /devices/{id}` (rename), `DELETE /devices/{id}` +
   `POST /delete_devices` (revoke the `matrix_sessions` token + drop the device's keys), `GET /devices`
   with full metadata. **Device deletion is UIA-gated (decided: Option B):** `m.login.sso` UIA stage
   with a **15-minute fresh-auth window** — if the last fresh login is older than 15 min, a fresh SSO
   re-login is required before the deletion executes. A token *refresh* does not count as fresh auth.
   Future: extend the UIA flow with email/MFA stages without touching the endpoints.
   with full metadata. UIA-on-delete adapted to Nebu's OIDC model (no password challenge).
4. **s4-admin-ui-device-management** — Admin LiveView: per-user device list, rename, revoke/delete a
   device (force-logout that session). Accessibility per PRD (hard constraint).

## Run

```
/nebu-pipeline-epic --epic device-management
```
