# Oracle Spec Context — account-data-durability

Matrix CS API v1.18, §Client Config / §GET /sync. (nebu-agent-oracle subagent not
available in this environment; spec facts below are well-established CS-API rules and
match the story's inline Oracle notes.)

## /sync response shape for account_data
- Global account data lives at the **top level** of the `/sync` response under
  `account_data` → `{ "account_data": { "events": [ ... ] } }`. This is SEPARATE from
  per-room account data (`rooms.join.{roomId}.account_data`), which is OUT of scope here.
- Each entry is `{ "type": <string>, "content": <object> }`. Account-data events carry
  **NO** `event_id`, `sender`, `origin_server_ts`, `state_key` — only `type` + `content`.
- Order is not significant.
- Empty case: `account_data.events` SHOULD be `[]` (an empty array), not omitted. We will
  always emit the `account_data` key with an `events` array (possibly empty) to be safe and
  consistent; clients tolerate either, but an explicit empty array is the cleanest.

## Initial vs incremental
- **Initial sync** (no `since`): return ALL of the user's global account_data, regardless of
  any change flag.
- **Incremental sync** (`since` present): return ONLY account_data that changed since the
  client's last sync. A per-(user,type) consume-once `changed` boolean — set TRUE on PUT,
  read-and-cleared atomically on the next incremental sync via `UPDATE ... RETURNING` — is a
  spec-acceptable implementation of "changed since `since`". This mirrors the existing
  `cross_signing_changed` flag pattern (cluster-correct). Initial sync MUST NOT consume the
  flag (it returns everything and should leave the per-type changed flags so a concurrent
  incremental poll still behaves; simplest correct rule: initial sync clears flags too since
  the client now has everything — but to avoid losing a write that landed between the initial
  snapshot read and flag clear, clear only the rows we actually returned. Practically: initial
  returns all + clears all returned rows' flags; incremental returns+clears only changed rows).

## Auth rules (unchanged, already enforced)
- `PUT /user/{userId}/account_data/{type}`: `{userId}` MUST equal the authenticated user,
  else `403 M_FORBIDDEN`. Body is arbitrary JSON, stored opaquely.
- `GET .../account_data/{type}`: `403 M_FORBIDDEN` if `{userId}` != auth user; `404 M_NOT_FOUND`
  if the type is absent for the user.

## ADR-011 opacity
- `content` is opaque. Element stores client-encrypted secret-storage material
  (`m.secret_storage.default_key`, `m.secret_storage.key.<id>`, encrypted private
  cross-signing keys `m.cross_signing.master|self_signing|user_signing`). The server MUST
  store/return these byte-for-byte and MUST NOT parse or decrypt them.

## Divergence flags
- None. ACs 1–6 are spec-compliant. The only design choice the spec leaves open is the
  "changed since" mechanism — the consume-once flag is acceptable and matches Nebu's
  established `cross_signing_changed` idiom.
