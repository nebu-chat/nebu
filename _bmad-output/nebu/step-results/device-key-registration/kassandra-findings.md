# Security Review — fix-device-key-registration (SEC Gate 1)

**Reviewer:** Kassandra
**Diff scope:** Stateful Matrix device-key directory — `DeviceKeyStore` (inline SQL via `Nebu.Repo`), `/keys/upload`, `/keys/query`, `GET /devices(+/{id})`, `whoami`, `/sync` E2E extension, `m.room.encryption` state-PUT guardrail, migration `000009_device_keys.{up,down}.sql`.
**Date:** 2026-06-26
**Branch:** bugfix/login-bugs-fixing

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | **HIGH** | `server/lib/nebu/matrix/event_dispatcher/server.ex:4403` (`@initial_state_forbidden_types`) + `:384` (`apply_initial_state/3`) | **E2EE-activation guardrail bypass via `createRoom` `initial_state`.** The state-PUT guard (`protected.ex:1164`) rejects `m.room.encryption`, but the `createRoom initial_state` replay path uses a 3-entry denylist that deliberately does NOT include `m.room.encryption`. A client can create a room with `m.room.encryption` in `initial_state[].content` → the event is signed, persisted to `events`, and fanned out via `/sync`/room state → the room is now E2EE-encrypted, violating ADR-011 (managed/server-side decryption) and AC6. | Add `"m.room.encryption"` to `@initial_state_forbidden_types` (server.ex:4403). Add a regression test that POSTs `createRoom` with `m.room.encryption` in `initial_state` and asserts the room has no persisted `m.room.encryption` event (or that the entry is rejected/skipped). |
| F-2 | MEDIUM | `server/lib/nebu/web/router/protected.ex:298` + `device_key_store.ex:51` (`store_one_time_keys/3`) | **Unbounded OTK / device-row growth — no rate limit, no per-array cap, no prune.** `/keys/upload` has no `RateLimit` plug (only `/sync` does) and no cap on the number of `one_time_keys` / `fallback_keys` / device rows. The 1 MB body cap (`json_body.ex:40`) bounds ONE request (~thousands of OTK rows per request), but repeated uploads with fresh `key_id`s accumulate rows in `device_one_time_keys` without limit (store-once `ON CONFLICT DO NOTHING` only de-dups identical key_ids; it does not cap total). Authenticated DoS / unbounded DB growth. | Add a per-IP/user `RateLimit` plug to `/keys/upload` (generous, e.g. 60/min). Cap `map_size(one_time_keys)` per request (spec clients send ≤100; reject >100 with 400 `M_INVALID_PARAM`, mirroring the `initial_state` 64-cap at protected.ex:418). Optionally cap stored unclaimed OTKs per device. |
| F-3 | LOW | `server/priv/migrations/000009_device_keys.up.sql` (all 3 tables) | **No RLS on the new tables.** `device_keys` / `device_one_time_keys` / `device_fallback_keys` ship without `ENABLE ROW LEVEL SECURITY`. This is consistent with the message-data tables (`events`, `room_members` are application-scoped under single-role `nebu_app`, not RLS-protected — RLS in this schema is reserved for compliance/audit/config immutability), so it is NOT a regression of an existing defense-in-depth boundary. Recorded for the recurring "Missing RLS on new tables" pattern. Note: all queries scope by trusted `user_id`/`device_id` at the application layer, so there is no live exposure. | No change required for parity with the data schema. If a future epic introduces a RLS-by-default convention for data tables, retrofit these. |
| F-4 | INFO | `server/lib/nebu/matrix/device_key_store.ex:160-191` (`query_devices/1`) | **Spoofable inner `user_id` in the echoed blob — not exploitable.** `/keys/upload` stores the blob under the trusted `conn.assigns[:current_user]` (protected.ex:299); the inner `device_keys.user_id`/`signatures` are attacker-controlled but are echoed verbatim and the query result is keyed by the **DB `user_id` column** (the trusted uploader), not the inner field. So user A cannot make a forged record surface under victim B's `/keys/query` result, and cannot overwrite B's `(user_id, device_id)` PK row (the PK user_id is always the authenticated uploader). Clients additionally verify Ed25519 signatures against the device's own key. No action. | None. (Design is correct: trusted identity owns the PK; no IDOR / cross-user write.) |

## Detail

### F-1 — E2EE guardrail is bypassable through createRoom initial_state [HIGH]

This is the CRITICAL invariant of the whole story (ADR-011, AC6: "E2EE MUST stay OFF", "no server code path emits `m.room.encryption`"). The story added the guardrail in exactly one place — the generic state-PUT handler:

```
# protected.ex:1164
event_type == "m.room.encryption" ->
  error(conn, 403, "M_FORBIDDEN", "End-to-end encryption is not supported on this server")
```

But `createRoom` carries `initial_state` to a *different* writer. `apply_initial_state/3` (server.ex:4411) replays each entry through `emit_state_event/5` (signs + `insert_event` + `:pg` fan-out) and gates only on a 3-entry denylist:

```
# server.ex:4403
@initial_state_forbidden_types ~w(m.room.create m.room.member m.room.power_levels)
```

The accompanying comment (server.ex:4400-4402) *explicitly states* `m.room.encryption` is "honored" and that this is "deliberately NOT a narrow allowlist." That reasoning is sound for membership/power-level forgery (per my MEMORY pattern #64: those are GenServer-authoritative, so a forged event is inert) — but it does NOT hold for `m.room.encryption`, which is **event-derived**, not GenServer-authoritative. The codebase itself proves the event has real effect: `search/db.ex:30-35,58-63` excludes any room that has a persisted `m.room.encryption` state event. Once the event is in `events` and delivered via `/sync`, Element treats the room as encrypted and begins client-side Megolm → the server can no longer read message content → the managed-decryption model (ADR-011) is broken, and those messages silently vanish from search/compliance.

**Exploit (authenticated, single request):**
```
POST /_matrix/client/v3/createRoom
{ "initial_state": [ { "type": "m.room.encryption", "state_key": "",
    "content": { "algorithm": "m.megolm.v1.aes-sha2" } } ] }
```

The acceptance test for the guardrail (`device_keys_test.exs` header, line 11) only exercises the state-PUT path, so this bypass is untested.

**Fix:** add `"m.room.encryption"` to `@initial_state_forbidden_types`. (`m.room.encryption` is also currently copied by `copy_state_events` during room upgrade — server.ex:4523 lists it among types to copy — so a future `/upgrade` of a once-encrypted room would re-emit it; out of this diff's scope but worth a follow-up note once F-1 lands, since after the fix no room should ever hold the event.)

### F-2 — /keys/upload has no rate limit and no per-array cap [MEDIUM]

`/keys/upload` (protected.ex:298) runs no `RateLimit` plug. The only bound is the global 1 MB body cap. `store_one_time_keys/3` inserts one row per `(algorithm, key_id)`; `ON CONFLICT DO NOTHING` only suppresses byte-identical re-uploads of the *same* key_id. An authenticated client can loop uploads with fresh key_ids and grow `device_one_time_keys` without limit (no prune job, no per-device ceiling). The `createRoom` handler already established the project's mitigation pattern for exactly this shape (initial_state capped at 64, protected.ex:418) — `/keys/upload` should mirror it. Severity MEDIUM (authenticated; resource-exhaustion, not data exposure).

### F-3 — no RLS on new tables [LOW] / F-4 — spoofed inner user_id [INFO]

See table. Neither is a live exploit; F-3 is parity-consistent with the data schema, F-4 is correctly defended by keying on the trusted DB column.

## SQL injection / secrets / crypto checks (clean)

- **SQL injection:** all 11 queries in `DeviceKeyStore` are parameterized (`$1..$N`), incl. `user_id = ANY($1)` for the list query (store:177). No string interpolation of user input into SQL. CLEAN.
- **Secrets in logs:** no device-key material, tokens, or PII logged. `apply_initial_state` logs only type/room_id/state_key on skip. CLEAN.
- **Crypto:** no crypto introduced in this diff (public keys stored verbatim; signing path unchanged, Ed25519 via existing `emit_state_event`). CLEAN.
- **Auth/IDOR on reads:** `/devices`, `/devices/{id}`, `/sync` counts all scope by `conn.assigns[:current_user]` (trusted). `/keys/query` returns public directory data (spec-intended) for authenticated callers. CLEAN.
- **Path/decode:** `URI.decode_www_form` on `:device_id` path param feeds only a parameterized query. CLEAN.

## Summary

CRITICAL: 0
HIGH: 1 (F-1) — **blocks commit**
MEDIUM: 1 (F-2) — advisory, address before epic end
LOW: 1 (F-3) — advisory
INFO: 1 (F-4)

**Verdict: BLOCKED** — F-1 (E2EE guardrail bypass via createRoom initial_state) violates the ADR-011 hard constraint and AC6, and is exploitable by any authenticated user in a single request. One-line fix + regression test required before commit.
