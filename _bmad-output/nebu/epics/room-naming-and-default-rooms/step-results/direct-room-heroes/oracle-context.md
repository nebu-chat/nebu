# Oracle Context — direct-room-heroes

Oracle review completed 2026-05-28 (pre-embedded in story file frontmatter: `oracle_reviewed: true`).

## Matrix Spec §11.2.2 — Room Summary / Heroes

### When to include summary
- **Initial sync** (`since` absent): always include summary for rooms without `m.room.name`
- **Delta sync**: include summary only if heroes/counts changed since the previous sync token
- **When a room gains `m.room.name` in this delta**: send `heroes = []` and counts in this one delta so clients can clear their cached heroes. After that, omit summary for named rooms.

### Hero computation (spec §11.2.2.5, strict)
- Pool = all members in `join` state + all members in `invite` state, **excluding** the syncing user
- Selection order: joined members first (by `joined_at ASC`), then invited members
- Cap at **5 heroes** total
- Hero IDs must be full MXIDs (e.g., `@alice:nebu.local`)

### Counts
- `joined_member_count` = COUNT from `room_members WHERE left_at IS NULL`
- `invited_member_count` = COUNT from `room_invitations WHERE accepted_at IS NULL AND rejected_at IS NULL`

### AC#3 clarification — Named rooms
When a room has an explicit `m.room.name`, the spec does NOT require heroes. Nebu SHOULD omit the summary entirely (no `summary` key in JSON) via pointer + `omitempty`. This is the correct spec-compliant behavior.

### AC#5 clarification — Delta sync
Delta sync MAY omit summary when heroes/counts have not changed. Nebu SHOULD omit it (do not send unchanged data). Implementation: compare current heroes/counts to what was sent at the previous token; only include summary if different.

### No schema changes needed
Heroes computed at sync time from existing `room_members` and `room_invitations` tables.

### `m.direct` / `is_direct`
Written by clients only. Nebu stores and returns via existing account data sync path. No server-side generation required.
