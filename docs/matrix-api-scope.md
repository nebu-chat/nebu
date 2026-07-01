# Matrix API Scope

This document provides a full inventory of Matrix Client-Server API endpoints and their
implementation status in Nebu. Derived from `server/lib/nebu/web/router/protected.ex` and
`server/lib/nebu/web/router.ex` route registrations, cross-referenced with the Matrix
Client-Server API specification.

**Legend:**
- ✅ Implemented - real handler with database-backed logic
- 🔶 Stub - returns a hardcoded or minimal valid response; no persistent storage
- ❌ Intentionally excluded - will not be implemented (by design)
- ⏳ Planned - requires ADR decision before implementation

---

## Discovery and Client Configuration

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/versions` | ✅ | Returns v1.1–v1.11 |
| GET | `/.well-known/matrix/client` | ✅ | Dynamic base_url from request Host |
| GET | `/_matrix/client/v3/capabilities` | 🔶 | Returns change_password: false, room_versions: {6: stable} |
| GET | `/_matrix/client/unstable/org.matrix.msc2965/auth_issuer` | ✅ | Returns OIDC issuer from `server_config` (Bootstrap Wizard) - MSC2965 OIDC discovery (Story 13-7) |
| GET | `/_matrix/client/v1/auth_issuer` | ✅ | Stable v1 path - same handler as unstable (Story 13-7) |
| GET | `/_matrix/client/unstable/org.matrix.msc2965/auth_metadata` | ✅ | Proxies OIDC discovery document from the issuer in `server_config`; 5-min TTL cache; 503 M_UNAVAILABLE on provider failure (Story 13-7) |
| GET | `/_matrix/client/v1/auth_metadata` | ✅ | Stable v1 path - same handler as unstable (Story 13-7) |

## Authentication

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/login` | ✅ | Returns m.login.sso flow |
| POST | `/_matrix/client/v3/login` | ✅ | OIDC token exchange → Nebu session. With `refresh_token: true` issues opaque access+refresh tokens (64-hex, backed by `matrix_sessions`); without it returns the raw OIDC JWT (backward compat) |
| POST | `/_matrix/client/v3/refresh` | ✅ | Opaque refresh-token rotation (Matrix CS API v1.3). Unauthenticated by spec, rate-limited; 60s grace window on the old token (Story `oidc-session-refresh`) |
| GET | `/_matrix/client/v3/login/sso/redirect` | ✅ | Initiates PKCE flow to OIDC provider. `offline_access` is requested iff the operator-configurable `matrix_oidc_refresh_mode` (`server_config`, default `offline`) is `offline` — read live by `Nebu.Matrix.SsoLogin.scope_list/0`, changeable at runtime via `/admin/config`. Note: Dex issues a refresh token only with `offline_access` (Story `oidc-refresh-mode-config`) |
| GET | `/_matrix/client/v3/login/sso/redirect/oidc` | ✅ | OIDC callback, issues Nebu token |
| POST | `/_matrix/client/v3/logout` | ✅ | Revokes session token; deletes the user's `matrix_sessions` rows |
| GET | `/_matrix/client/v3/account/whoami` | ✅ | Returns user_id from JWT or opaque session |
| GET | `/_matrix/client/v3/auth/m.login.sso/fallback/web` | ✅ | UIA SSO auth fallback (unauthenticated by spec); drives a fresh out-of-band SSO login to complete the `m.login.sso` stage of a pending UIA session, then refreshes `auth_time` (Story s3-matrix-device-endpoints) |

## Sync

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/sync` | ✅ | Long-poll (max 25s cap, was 30s); initial sync parallel room fetch (Task.async_stream, max_concurrency: 5); top-level global `account_data.events` delivered from durable PostgreSQL store — full on initial sync, changed-only on incremental (consume-once `changed` flag; account-data-durability) |

## Room Management

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| POST | `/_matrix/client/v3/createRoom` | ✅ | Creates room via `EventDispatcher.Server.create_room/2` (in-process) |
| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | ✅ | Join by room ID or alias |
| POST | `/_matrix/client/v3/rooms/{roomId}/join` | ✅ | Accept invitation |
| POST | `/_matrix/client/v3/rooms/{roomId}/leave` | ✅ | Leave room |
| POST | `/_matrix/client/v3/rooms/{roomId}/invite` | ✅ | Invite user |
| POST | `/_matrix/client/v3/rooms/{roomId}/kick` | ✅ | Kick user (power level check) |
| POST | `/_matrix/client/v3/rooms/{roomId}/ban` | ✅ | Ban user |
| POST | `/_matrix/client/v3/rooms/{roomId}/unban` | ✅ | Unban user |
| POST | `/_matrix/client/v3/rooms/{roomId}/forget` | ✅ | Forget room |
| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` | ✅ | Full Matrix §11.35.1 upgrade flow (tombstone, new room, copy state, invite members, archive old room) — Story 9-27 |
| GET | `/_matrix/client/v3/joined_rooms` | 🔶 | Returns empty list (use /sync instead) |

## Messaging and Events

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| PUT | `/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` | ✅ | Sends event via `EventDispatcher.Server.send_event/5` (in-process) |
| GET | `/_matrix/client/v3/rooms/{roomId}/messages` | ✅ | Paginated message history |
| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | ✅ | Set room state event |
| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}` | ✅ | Set state (no stateKey) |
| GET | `/_matrix/client/v3/rooms/{roomId}/state` | ✅ | Get all state events |
| GET | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | ✅ | Get single state event |
| GET | `/_matrix/client/v3/rooms/{roomId}/event/{eventId}` | ✅ | Single event fetch by ID; membership-enforced via Horde state (Story 11-8) |
| GET | `/_matrix/client/v3/rooms/{roomId}/context/{eventId}` | ✅ | Event context (before/after) |
| POST | `/_matrix/client/v3/rooms/{roomId}/read_markers` | 🔶 | Acknowledged, not persisted |

## Event Relations and Threads

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}` | ✅ | Base route - all relation types; dir/limit/recurse/from params; prev_batch in response (Story 9-29) |
| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}` | ✅ | Filter by relation type; same params (Story 9-28 / 9-29) |
| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}/{eventType}` | ✅ | Filter by relation type and event type (Story 9-29) |

## Room Members

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/rooms/{roomId}/members` | ✅ | Returns membership events |
| GET | `/_matrix/client/v3/rooms/{roomId}/joined_members` | ✅ | Compact map of joined members |
| GET | `/_matrix/client/v3/rooms/{roomId}/aliases` | ✅ | Returns [] (no alias storage yet) |

## Presence and Typing

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/presence/{userId}/status` | ✅ | Reads from Elixir presence state |
| PUT | `/_matrix/client/v3/presence/{userId}/status` | ✅ | Updates presence status |
| PUT | `/_matrix/client/v3/rooms/{roomId}/typing/{userId}` | ✅ | Sends typing indicator |
| POST | `/_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId}` | ✅ | Read receipts |

## Profile

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/profile/{userId}` | ✅ | Public (unauthenticated) |
| GET | `/_matrix/client/v3/profile/{userId}/displayname` | ✅ | Public sub-field |
| GET | `/_matrix/client/v3/profile/{userId}/avatar_url` | ✅ | Public sub-field |
| PUT | `/_matrix/client/v3/profile/{userId}/displayname` | ✅ | Requires JWT auth |
| PUT | `/_matrix/client/v3/profile/{userId}/avatar_url` | ✅ | Requires JWT auth |

## Account Data and Tags

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/user/{userId}/account_data/{type}` | ✅ | PostgreSQL-backed (durable, `Nebu.Matrix.AccountDataStore`, migration 000011); returns stored bytes verbatim; 404 M_NOT_FOUND if unset; IDOR guard (account-data-durability) |
| PUT | `/_matrix/client/v3/user/{userId}/account_data/{type}` | ✅ | Persists to PostgreSQL (durable, survives restart, opaque per ADR-011); IDOR guard; delivered via /sync (account-data-durability) |
| GET | `/_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}` | ✅ | Per-room account data |
| PUT | `/_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}` | ✅ | Per-room account data |
| GET | `/_matrix/client/v3/user/{userId}/rooms/{roomId}/tags` | ✅ | Room tags |
| PUT | `/_matrix/client/v3/user/{userId}/rooms/{roomId}/tags/{tag}` | ✅ | Add/update room tag |
| DELETE | `/_matrix/client/v3/user/{userId}/rooms/{roomId}/tags/{tag}` | ✅ | Remove room tag |
| POST | `/_matrix/client/v3/user/{userId}/filter` | 🔶 | Returns filter_id "0" (unfiltered sync) |
| GET | `/_matrix/client/v3/user/{userId}/filter/{filterId}` | 🔶 | Returns stored filter (or empty) |

## Devices

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/devices` | ✅ | Lists the user's devices (backed by the `devices` table, incl. keyless devices — Story s1) |
| GET | `/_matrix/client/v3/devices/{deviceId}` | ✅ | Get single device |
| PUT | `/_matrix/client/v3/devices/{deviceId}` | ✅ | Rename device (`display_name`); owner-scoped, no UIA (Story s3) |
| DELETE | `/_matrix/client/v3/devices/{deviceId}` | ✅ | Delete a device; **UIA-gated** (`m.login.sso`, 15-min fresh-auth window, Option B). Fires the per-device JWT kill-switch: every JWT bound to `(user, device)` is denylisted until its own `exp` (Story s3) |
| POST | `/_matrix/client/v3/delete_devices` | ✅ | UIA-gated bulk delete (≤100 devices); same kill-switch per device (Story s3) |

## Push Notifications

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/pushrules/` | ✅ | All push rules (DB-backed, default rules seeded) |
| GET | `/_matrix/client/v3/pushrules/{scope}/{kind}/{ruleId}` | ✅ | Single push rule |
| PUT | `/_matrix/client/v3/pushrules/{scope}/{kind}/{ruleId}` | ✅ | Create/update push rule |
| DELETE | `/_matrix/client/v3/pushrules/{scope}/{kind}/{ruleId}` | ✅ | Delete push rule |
| PUT | `/_matrix/client/v3/pushrules/{scope}/{kind}/{ruleId}/enabled` | ✅ | Enable/disable rule |
| PUT | `/_matrix/client/v3/pushrules/{scope}/{kind}/{ruleId}/actions` | ✅ | Update rule actions |
| GET | `/_matrix/client/v3/pushers` | ✅ | List pushers |
| POST | `/_matrix/client/v3/pushers/set` | ✅ | Add/remove pusher |
| GET | `/_matrix/client/v3/notifications` | ✅ | Notification list (cursor-paginated) |

## Room Directory and Public Rooms

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/publicRooms` | ✅ | Public room directory |
| POST | `/_matrix/client/v3/publicRooms` | ✅ | Filtered public rooms |
| PUT | `/_matrix/client/v3/directory/room/{roomAlias}` | 🔶 | Acknowledged, no storage |
| DELETE | `/_matrix/client/v3/directory/room/{roomAlias}` | 🔶 | Acknowledged |
| GET | `/_matrix/client/v3/directory/room/{roomAlias}` | 🔶 | Returns 404 (no alias storage) |

## Full-Text Search

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| POST | `/_matrix/client/v3/search` | ✅ | PostgreSQL `tsvector`/`tsquery` FTS on `events` table (GIN index, migration 000042); room filter, pagination, `order_by` (rank/recent); member-only access enforced — Epic 11 / ADR-010 |

## User Directory

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| POST | `/_matrix/client/v3/user_directory/search` | ✅ | Searches users table |

## Third-Party and Other

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| GET | `/_matrix/client/v3/account/3pid` | 🔶 | Returns empty list (3PIDs not supported) |
| GET | `/_matrix/client/v3/thirdparty/protocols` | 🔶 | Returns {} |
| GET | `/_matrix/client/v3/voip/turnServer` | 🔶 | Returns 404 (TURN not configured) |
| GET | `/_matrix/media/v3/config` | ✅ | Returns `{"m.upload.size": N}` - unauthenticated, deprecated (Story 12.16) |

## Media Repository

These endpoints are served by **`Nebu.Media.*`** (in-process within the single Elixir/OTP
application), behind the same Bandit listener as the Matrix API.

**Deprecated unauthenticated endpoints (v3) - backward compatibility:**

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| POST | `/_matrix/media/v3/upload` | ✅ | AES-256-GCM encrypt → store → `mxc://` URI; OIDC auth required |
| GET | `/_matrix/media/v3/download/{serverName}/{mediaId}` | ✅ | Decrypt + stream; CSP + CORP headers (Story 12.16) |
| GET | `/_matrix/media/v3/download/{serverName}/{mediaId}/{fileName}` | ✅ | Same + `Content-Disposition: filename="{fileName}"` |
| GET | `/_matrix/media/v3/thumbnail/{serverName}/{mediaId}` | ✅ | On-demand thumbnail; AES decrypt + resize; CSP + CORP headers (Story 12.16) |
| GET | `/_matrix/media/v3/config` | ✅ | `{"m.upload.size": N}` - unauthenticated, deprecated (Story 12.16) |

**Authenticated endpoints (v1.11+, Matrix CS API spec):**

| Method | Endpoint | Auth | Status | Notes |
|---|---|---|---|---|
| GET | `/_matrix/client/v1/media/config` | Bearer | ✅ | `{"m.upload.size": N}` - 401 M_MISSING_TOKEN if no token (Story 12.16) |
| GET | `/_matrix/client/v1/media/download/{serverName}/{mediaId}` | Bearer | ✅ | Auth-gated download; same handler as v3 (Story 12.16) |
| GET | `/_matrix/client/v1/media/download/{serverName}/{mediaId}/{fileName}` | Bearer | ✅ | Auth-gated download with filename in `Content-Disposition` (Story 12.16) |
| GET | `/_matrix/client/v1/media/thumbnail/{serverName}/{mediaId}` | Bearer | ✅ | Auth-gated thumbnail (Story 12.16) |

**Auth error codes for all `/_matrix/client/v1/media/*` endpoints:**

| Condition | HTTP | errcode |
|---|---|---|
| Missing / non-Bearer Authorization header | 401 | `M_MISSING_TOKEN` |
| Invalid or expired Bearer token | 401 | `M_UNKNOWN_TOKEN` |

## Key Directory (E2EE-ready, not E2EE)

A PostgreSQL-backed **key directory** that persists and reads back opaque client key
material so Matrix clients (Element Web / Element X) complete device registration and
cross-signing bootstrap cleanly. This is an **E2EE-readiness** facility, **orthogonal to
encryption**: all stored material is opaque, the server never decrypts and never holds a
private part, and persisting these keys does **not** enable room encryption —
`m.room.encryption` is still rejected (`403 M_FORBIDDEN`) per
[ADR-011](architecture/adr/ADR-011-managed-e2ee-key-escrow.md).

| Method | Endpoint | Status | Behavior |
|---|---|---|---|
| POST | `/_matrix/client/v3/keys/upload` | ✅ | Persists device + one-time + fallback public keys (`Nebu.Matrix.DeviceKeyStore`, migration 000009) |
| POST | `/_matrix/client/r0/keys/upload` | ✅ | Same as v3 (legacy compatibility) |
| POST | `/_matrix/client/v3/keys/query` | ✅ | Echoes stored `device_keys` (DeviceKeyStore) **and** stored `master_keys` / `self_signing_keys` / `user_signing_keys` (CrossSigningKeyStore); empty maps for users without keys |
| POST | `/_matrix/client/v3/keys/device_signing/upload` | ✅ | Persists opaque master/self/user cross-signing keys per user (`Nebu.Matrix.CrossSigningKeyStore`, migration 000010); `200 {}`. MUST-guard: a cross-signing key ID colliding with an existing device ID → `400 M_INVALID_PARAM` before any write. Idempotent re-upload of identical keys is allowed without UIA; overwriting different keys without `auth` → `403 M_FORBIDDEN` (cross-signing-readback story) |
| POST | `/_matrix/client/v3/keys/signatures/upload` | ✅ | Validate-then-persist: merges supplied signatures into the stored device/cross-signing key objects (caller-identity guard); `200 {"failures": {}}` on success, per-(user,key) `M_INVALID_SIGNATURE` under `failures` on mismatch. Merged signatures are visible on the next `keys/query` |

After a successful `device_signing/upload`, the uploading user's own ID is surfaced in
`device_lists.changed` of their next incremental `/sync` (consume-once `cross_signing_changed`
flag on the `cross_signing_keys` table). Both stores follow ADR-018 (inline parameterised SQL
via `Nebu.Repo`, no Ecto schema). `CrossSigningKeyStore` mirrors `DeviceKeyStore`.

## Current E2EE Stubs

These endpoints are implemented as stubs to prevent Matrix client error dialogs. No actual
key material is stored. See [ADR-011](architecture/adr/ADR-011-managed-e2ee-key-escrow.md) for
the roadmap toward Managed E2EE.

| Method | Endpoint | Status | Stub Behavior |
|---|---|---|---|
| POST | `/_matrix/client/v3/keys/claim` | 🔶 | Returns empty one_time_keys |
| GET | `/_matrix/client/v3/keys/changes` | 🔶 | Returns changed: [], left: [] |
| GET | `/_matrix/client/v3/room_keys/version` | 🔶 | Returns 404 M_NOT_FOUND (no backup configured) |
| POST | `/_matrix/client/v3/room_keys/version` | 🔶 | Returns version: "1" (not stored) |
| GET | `/_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device` | 🔶 | Returns 404 M_NOT_FOUND (MSC3814 not supported) |
| GET | `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` | 🔶 | Returns 404 M_NOT_FOUND (MSC4143 not supported) |

## Spaces (MSC1772 / MSC2946 / MSC3083) — epic: spaces-elixir

Matrix Spaces are implemented as part of the `spaces-elixir` epic.

| Method | Endpoint | Status | Notes |
|---|---|---|---|
| POST | `/_matrix/client/v3/createRoom` (with `creation_content.type: "m.space"`) | ✅ | Space creation via existing `createRoom` endpoint — `type: "m.space"` added to `m.room.create` |
| PUT | `/_matrix/client/v3/rooms/{roomId}/state/m.space.child/{childRoomId}` | ✅ | Add/remove child room from space; power level check |
| PUT | `/_matrix/client/v3/rooms/{roomId}/state/m.space.parent/{parentSpaceId}` | ✅ | Link child room to parent space |
| GET | `/_matrix/client/v1/rooms/{roomId}/hierarchy` | ✅ | MSC2946 BFS traversal over `m.space.child` state events; `limit`, `max_depth`, `suggested_only`, `from` params; paginated SpaceSummary response |

**Dependent changes to existing endpoints:**

| Method | Endpoint | Change |
|---|---|---|
| GET | `/_matrix/client/v3/capabilities` | Room versions extended to 6–10, default `"10"` (required for `restricted` join rules) |
| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | Restricted join rule enforcement (MSC3083): checks caller membership in `allow`-listed spaces |
| POST | `/_matrix/client/v3/rooms/{roomId}/join` | Same restricted join rule check |

---

## Intentionally Excluded

The following endpoint namespaces are deliberately not implemented. Nebu is designed as a
closed-network, non-federated server. These APIs are only relevant for Matrix federation and
identity services.

| Namespace | Reason |
|---|---|
| `/_matrix/federation/*` | No federation - see [README §No Federation](../README.md#no-federation) (closed-network data-sovereignty model; Phase 3 vision) |
| `/_matrix/identity/*` | No identity server - email/phone binding not supported |
| `/_matrix/key/v2/server` | Server key exchange only needed for federation |

