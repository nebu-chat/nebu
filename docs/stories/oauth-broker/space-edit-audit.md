---
story_id: space-edit-audit
title: "Audit rows for Admin UI space edits (follow-up dj): name / topic save, child add / remove"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-15
branch: feature/migrate-to-oauth2
---

# Story: the Admin UI changes of a Space leave an audit row (follow-up `dj`)

Source: follow-ups row `dj` (Kassandra design review of admin-forms-gate-sweep, S2 / S4 / S5). `POST /admin/spaces/:id` (name / topic),
`POST /admin/spaces/:id/children` and `DELETE /admin/spaces/:id/children/:child_id` write no audit row.
Owner decision 2026-10-15: audit rows ONLY for the space adaptations (not for `dk` configure_logging, `dl` War Room, `dm` bootstrap / login / logout: those stay
without audit, "entschieden: kein Audit", recorded in follow-ups.md).

## Investigation (the dj question: is the events table already the record?)

`Nebu.Admin.SpacesController` calls `Nebu.Matrix.set_space_state/5` with `sender_id` = the admin's Matrix id (`actor_id(conn)`: the session's `matrix_user_id`);
`Dispatcher.set_room_state/2` checks that sender as a room member with the `state_default` power level and emits the state event through the signed Room
path with `sender = admin`. So the `events` table DOES carry who changed what (sender + type + content, append-only). It is nevertheless not
enough on its own: (1) the compliance / audit view (`/admin/audit-log`, export, `audit_log` immutability invariants) reads only `audit_log`; an auditor
who looks for "who changed the space structure" must not have to know the Matrix event model; (2) every comparable Admin change (room auto-join, visibility, member
add, config saves) has an `audit_log` row with `actor_user_id`, target and metadata; (3) the generic client `PUT /rooms/:id/state/...` goes through the same
`set_room_state` and must NOT write admin audit rows (a Matrix client edit is not an admin action) -> the row is written at the ADMIN entry point.

## Decisions

- **D1 (where).** In `Nebu.Matrix.set_space_state/5`, the Matrix-domain function that only the Admin UI calls (ADR-020: the controller reaches it through the public API module
  `Nebu.Matrix`; `Nebu.Compliance.AuditWriter` is shared infrastructure). NOT in `Dispatcher.set_room_state/2` (also serves clients).
- **D2 (what).** After a SUCCESSFUL write (`{:ok, event_id}`) exactly one row, actor = `sender_id`, target_type `"room"`, target_id = the space room id, outcome `"success"`:
  `m.room.name` -> `space_name_changed` (metadata `name` = the new name, truncated to 256 graphemes and at most 1024 bytes of whole UTF-8 characters), `m.room.topic` -> `space_topic_changed` (metadata `topic`, same cut),
  `m.space.child` with an empty content map (the unlink) -> `space_child_removed` (metadata `child_room_id`), `m.space.child` otherwise -> `space_child_added`
  (metadata `child_room_id`), any other event type through this function -> no audit row (the function is only called with these four). No row for a refused / failed write.
  The event id is in every row's metadata (`event_id`) so the audit row links to the `events` record.
- **D3 (atomicity, honestly).** NOT atomic with the event: the event is emitted through the Room GenServer (own process, signed, fanned out; `rooms.name` is a separate denormalised update), a
  single Ecto transaction cannot span it (the same reason the room auto-join / visibility / member-add audits of the Dispatcher are written after the write).
  Policy: a failed audit write is logged at error level (the AuditWriter already does; a raised exception or an exit of the writer, e.g. a pool timeout, is caught at the call site and logged with the action, the room id and the error KIND only, never name / topic) and does NOT undo or hide the edit and does not fail the HTTP request (the return value stays `{:ok, event_id}` also for an exception or an exit of the writer; the audit call and the metadata building sit in the same protected block, the `Nebu.Matrix.Error` of the state write itself is NOT caught): these edits are non-destructive,
  reversible and independent of confidentiality, and the `events` row (sender = admin) remains the primary record; the privileged config saves (admin-config-audit-atomic) differ because
  they widen access. Documented in 07-deployment.
- **D4 (vocabulary).** The four actions are added to `@known_actions` of `Nebu.Compliance.AuditWriter` (dropping one would make the row silently vanish: `{:error, :audit_unknown_action}`), the audit log
  view / filters / docs that enumerate actions know them.
- **D5 (no PII beyond the event).** Name and topic are room metadata already carried by the event (not message content, not credentials); values are truncated, no user data.
- **D6 (scope).** `create_space` (a new space) is NOT part of this story (`room_created` exists for createRoom paths; follow-up note only if missing). `toggle_auto_join` already audits (`room_auto_join_changed`).

## Acceptance Criteria

1. `Nebu.Matrix.set_space_state/5` with `m.room.name` writes one `audit_log` row `space_name_changed` (actor = sender, target = space id, metadata name + event_id) after a successful event.
2. `m.room.topic` -> `space_topic_changed`; `m.space.child` with content -> `space_child_added`; with `%{}` -> `space_child_removed` (metadata child_room_id, event_id).
3. A failed state write (not a member, lacking power level, forbidden type, unknown room: `{:error, _}`) writes NO audit row.
4. A failing audit write (`{:error, :audit_write_failed}` / unknown action, a raised exception such as `ArgumentError` / `DBConnection.ConnectionError`, an exit) does not change the return value `{:ok, event_id}` and does not raise.
5. Long names / topics are truncated to 256 graphemes and 1024 bytes in the metadata; the event content itself is unchanged.
6. The four actions are in `@known_actions` (allowlist test persists one row per action); the audit log view shows `action` raw and has no further enumeration (checked), so nothing else lists actions.
7. The Admin UI path end to end: `POST /admin/spaces/:id` (name + topic, 2 rows), `POST .../children` (1 row), `DELETE .../children/:child_id` (1 row) produce the rows (integration with the real writer; the controller seam
   `:admin_spaces_state_writer` stays working for existing tests).
8. The generic client `PUT /_matrix/client/v3/rooms/:id/state/m.room.name` writes NO space audit row (negative test).
9. Docs: 07-deployment, section "Admin configuration forms and their protection" (audit coverage, D3 policy, the table row of rooms / spaces), ADR-033 SO11 (the audit inventory) names the four actions; follow-ups.md closes `dj`, records `dk` / `dl` / `dm` as "decided: no audit".

- **D7 (not truncated).** `child_room_id` is admin free text of the child form and is NOT truncated (only name / topic are); it is a room id, not content.
