# Kassandra create-room-initial-state-conformance 2026-10-16

Verdict: CLEAN (0 CRITICAL / HIGH / MEDIUM, 1 LOW fixed, 8 INFO). Scope: `createRoom` `initial_state` (validation before the room exists, the forbidden types, `m.room.name` -> `rooms.name`, the failing-entry raise, M_NOT_JSON / M_BAD_JSON order, the e2e step). Reviewer: nebu-kassandra (read-only; the orchestrator wrote this file). Prior reviews consulted: space-room-in-space-bug 2026-06-22 (#68 deny-list acceptable: membership and power levels are held by the room process), fix-device-key-registration (#72 `m.room.encryption` blocked on every write path), bugfix-unsigned-replaces-state (#100).

## Permissions (what a creator can set through initial_state)
- The envelope is server-built by `emit_state_event/5` (room id, sender = the creator, timestamp, signature); the client controls `type`, `state_key`, `content` only. No write into another room.
- The creator holds power level 100 BEFORE `apply_initial_state` runs; `m.room.power_levels` / `m.room.member` / `m.room.create` are skipped, so no escalation, no foreign membership, no create rewrite.
- `m.room.encryption` (ADR-011) stays skipped (room created, nothing stored); the direct PUT answers 403: deliberate asymmetry (Element sends it), documented (D2).
- Newly skipped: `m.room.tombstone` (the only server-read type that was still open; `copy_state_events` already drops it on upgrade), `m.room.third_party_invite`.
- `m.space.parent` keeps the parent-exists + creator-is-member check (same as the PUT path). join_rules / history_visibility / guest_access only open the creator's own room (PL 100 may set them via PUT too). `m.room.canonical_alias` content is display-only (aliases resolve from the alias table). Avatar / pinned_events / server_acl / redaction / custom types: no server code reads them.
- A top-level `name` and the alias derived from it apply after `initial_state` and win; the alias is registered only after `initial_state`, so a failed entry leaves no alias row.

## Structure validation, errors, logging
- `validate_initial_state/1` runs in the router before a room exists; order: not JSON -> 400 M_NOT_JSON; JSON non-object -> 400 M_BAD_JSON; > 64 entries -> 400 M_INVALID_PARAM (cap before shapes); malformed entry -> 400 M_BAD_JSON. Fixed error texts, no input echoed. Body cap 1 MB (413).
- The new raise is caught by the `Nebu.Matrix.Error` rescue of `create_room` -> `cleanup_orphan_room`; the client gets a generic 500.
- Logging law: the old `Logger.warning(... inspect(reason))` is gone (a Postgres jsonb error carries `where: "JSON data, line 1: <content prefix>"`); the new ERROR logs room id, type and the error class / SQLSTATE only.

## Findings
- **L-1 LOW (FIXED, code-review M3):** a NUL character in `type` / `state_key` / `content` passed the validator, Postgres jsonb rejected it after the room was created: a client-triggerable 500 without a log line. Fixed: `contains_nul?/1` (keys and values, nested) -> 400 M_BAD_JSON before the room exists; value-free `Logger.error` with the error class; unit + HTTP tests.
- I-1 INFO: `initial_state` is a deny-list, `PUT /state` an allow-list (accepted under #68 / #72). Watch: when server code starts to read a new state type from events, add it to `@initial_state_forbidden_types`.
- I-2 INFO: `m.room.canonical_alias` content not validated (display spoofing in summaries, same on PUT) = follow-up `eg`.
- I-3 INFO: JSON nesting depth unbounded (`CanonicalJson.normalize`, `contains_nul?` recurse; the 1 MB body cap bounds it) = follow-up `ei`.
- I-4 INFO: the pre-existing top-level `name` path logs `inspect(reason)` of a Postgrex error (a NUL in `name` can echo the name via `where`) = follow-up `ei` (reject NUL with 400, log the class only).
- I-5 INFO: `{"_json": ...}` object body answers 400 (harmless). I-6 INFO: `state_key: null` is 400 (stricter than "optional", matches AC2). I-7 INFO: `rooms.name` length uncapped (same as PUT / top-level name) = `ei`. I-8 INFO: docs ship with the commit.

Classification: CLEAN. Counts: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 1 (fixed), INFO 8.
