## Security Review — e2ee-compliance-channel-guard (cycle 1, delta re-review of LOW 1 + LOW 2)

**Diff scope:** the fixes for the two LOW findings of `e2ee-compliance-channel-guard-security-review-2026-11-03.md`: `check_not_encrypted_event/1` in `emit_state_event_at/6`, `m.room.encrypted` added to the `copy_state_events/3` exclusion list, a new upgrade integration test, and the "type filter, not content filter" wording in ADR-011 (update 2026-11-03), the 11-risks row and the `http_to_device.ex` Allowlist doc.
**Date:** 2026-11-03

### Findings

No security issues found.

### Verification

**L1 — upgrade copy / state funnel: CLOSED.**
- `emit_state_event_at/6` (event_dispatcher/server.ex ~9297) runs `check_not_encrypted_event/1` as the first step of its `with`. That is before signing, before `insert_event` and before the `:pg` broadcast, so a refusal leaves no row, no broadcast and no lock (the function takes no lock).
- Callers of `emit_state_event_at/6`, listed again here:
  - preset (742): fixed types.
  - name (759), topic (771), canonical_alias (931, 1796): fixed types.
  - initial_state (9207): `m.room.encrypted` is already in `@initial_state_forbidden_types` (979), which is checked earlier (1664).
  - `emit_state_event/5` (9276), whose callers are:
    - the upgrade `m.room.create` (8498): fixed type.
    - the upgrade copy (9433/9434): the type is in `excluded_types` and is filtered out before `copy_plan` runs. The copy loop is an `Enum.each` that ignores the return value, so a refusal could not crash the upgrade either.
  - The new `{:error, :encrypted_event_forbidden}` tuple can therefore not be reached from any caller today. Callers that do match `{:error, reason}` log only `db_error_class/1`, which is `inspect(atom)`. That text is value-free: no content and no 500 text with client data.
- Other room write paths:
  - State PUT: the `@writable_state_types` allowlist (4454) applies before the room process. The router guard is at protected.ex 3350.
  - Tombstone: `write_state` with the fixed type `m.room.tombstone`.
  - Timeline: the only entry is `EventDispatcher.send_event` (247). It has the head clause for `@encrypted_room_event_type` (176), and the router guard is at protected.ex 1837.
  - Room.Server `insert_event` calls: membership events, the redaction writer and the personal-room bootstrap. All of these use fixed types.
  - I found no path that still stores an `m.room.encrypted` state or timeline event.
- Upgrade of a room that already holds a legacy event: the legacy rows stay in the old room and are not copied. The upgrade stays 200, no room is left half-built and no lock is held. The test seeds the legacy rows below the API (`legacy_event!`) with an empty state key and a non-empty one. It asserts 200, no `m.room.encrypted` in the new room, that topic and name were copied, and that the old rows are untouched. The test matches the scenario tag.
- Not changed by this fix and not a finding: legacy `m.room.encrypted` TIMELINE rows from before the story stay readable in the old room. The upgrade does not copy timeline events, so this is outside the copy path. It was already noted as legacy data in the previous report.

**L2 — wording: TRUTHFUL.**
- ADR-011 line 54 (DE), the 11-risks row (line 37) and the `http_to_device.ex` moduledoc all say the same thing: the allowlist is a type filter and not a content filter, any content up to the existing budgets passes under the listed types, and the channel is as large as before. None of them claims the channel is closed.
- In the moduledoc, `m.room.encrypted` is also described correctly as carrying arbitrary opaque content by design.

**New problems from the fix:** none.
- No state event type was lost: the exclusion list only gained `m.room.encrypted`, and the legacy-oversized skip/reduce counts are unchanged because the type is filtered out before planning.
- No new error leaks text.
- Not run here: mix and Docker, so the claim that the new test fails on the old code was not executed (the orchestrator verifies with quick.sh).

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0 (previous LOW 1 and LOW 2 are closed)

**Verdict:** APPROVED
