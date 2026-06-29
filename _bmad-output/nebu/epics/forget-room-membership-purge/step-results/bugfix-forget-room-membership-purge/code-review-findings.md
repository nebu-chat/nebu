# Code Review — forget-room-membership-purge (cycle 0)

No CRITICAL/MAJOR. All 8 ACs satisfied. 3 MINOR + 2 INFO — all auto-fixed.

- MINOR-1: forget_room/2 calls insert_forgotten_room directly (unguarded) — correct
  (forget must fail loudly), but add a comment noting it is deliberate.
- MINOR-2: unforget_room not called on the {:error, :already_member} join branch — add
  it (cheap, idempotent) so a raced/stale forgotten row can't permanently hide a joined room.
- MINOR-3: unforget_room's Process.whereis guard silently skips clear if Repo down —
  note the forget-loud / unforget-silent trade-off in the comment.
- INFO-1: AC3/AC4 test comments say "leave section" but the HTTP renderer puts
  recently-left rooms in rooms.join (leave hardcoded {}). room_in_sync?/2 checks all
  sections so assertions are valid — clarify the comments.
- INFO-2: behaviour-callback opt-out via function_exported?/3 correctly reasoned — no change.
