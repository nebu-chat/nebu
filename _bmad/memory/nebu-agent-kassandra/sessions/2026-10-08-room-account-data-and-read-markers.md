
## Session — matrix-spec-gaps / room-account-data-and-read-markers (SEC Gate 1)

**Scope:** staged diff (worktree open-chat-sync, branch bugfix/sync-room-account-data): RoomAccountDataStore, mig 000035, room AD PUT/GET, /sync `<core>.<pos>` token, read_markers, ensure_room_member! extraction, RawBodyReader/JsonBody, erasure 4b.

**Finding summary:** 0 CRITICAL, 0 HIGH, 3 MEDIUM, 3 LOW, 5 INFO. CLEAN/APPROVED. Report: docs/stories/matrix-spec-gaps/security-reports/room-account-data-and-read-markers-security-review-2026-10-08.md

**New patterns discovered:** shared-plug error->flag sibling regression (global AD PUT >1MB now stores {} with 200). Per-value and row caps without an aggregate cap = ~64 MB per /sync amplification (client-chosen position 0). Carried logging F-1 (account_data body) extended to room AD routes.

**Accepted risks this session:** none.

**Follow-up:** M1 fix before merge recommended. Global account_data still not erased on GDPR (known).
