# Kassandra short review: space-edit-audit (2026-10-15)

Verdict: CLEAN (0 CRITICAL / HIGH / MEDIUM, 2 LOW, 5 INFO). Scope: audit rows `space_name_changed` / `space_topic_changed` / `space_child_added` / `space_child_removed` written by `Nebu.Matrix.set_space_state/5` after a successful state write.
- Integrity: actor = the admin session's Matrix id; a row needs `{:ok, event_id}` (member with `state_default` power); the generic client PUT goes through the unchanged `Dispatcher.set_room_state/2` and writes no space row (negative integration test with the real writer and a positive control); no log injection (free text only in JSONB).
- Non-atomicity is acceptable for non-destructive, reversible edits (differs from the privileged config saves that widen access); the protection block catches exception and exit of the audit call only; `events` (sender = admin) stays the primary record. INFO-3: a telemetry counter for "space edit audit not written" would make a silent loss visible (follow-up `dr`).
- No-Sensitive-Data-in-Logs: the new log line carries action, room id and error kind only.
- LOW-1: `String.slice/3` is grapheme based, a value of one grapheme with 100000 combining marks stayed unbounded; FIXED (256 graphemes AND 1024 bytes, UTF-8 safe, test) ; `save` has no length validation (create caps the name at 100): follow-up `dq`.
- LOW-2: ADR-033 SO11 "Not decided here" range was stale (fixed: `dn` - `do`); the Trace Map `enable_capture` / `disable_capture` events of `dp` X3-5 are now named as covered by the "decided: no audit" of `dk` / `dl` (applied).
- INFO: remove_child of a never linked room writes a row (noise), `set_space_state` does not check that the room is a space (cosmetic: target_type "room"), every save writes two rows (`dr`).
