-- 000050_room_invitations_pending_inviter_idx.up.sql
-- Story rate-limits-join-invite-create-room (epic oauth-broker, follow-up `ey`), D8.
--
-- The caps on PENDING invitations (per inviter, per inviter-invitee pair, per invitee) count rows of room_invitations whose
-- accepted_at IS NULL AND rejected_at IS NULL before every invitation write. The table has only room_invitations_invitee_idx
-- (invitee_id): there is NO index led by inviter_id, so a count by inviter would be a sequential scan of the whole table on every
-- invitation. ONE partial index, room_invitations_pending_inviter_idx on (inviter_id, invitee_id), serves the inviter count and the
-- pair count (the invitee total keeps using room_invitations_invitee_idx). Only pending rows are indexed, so the index stays small
-- (accepted and declined invitations are the bulk of the table over time) and is written only by the pending <-> decided transitions.
--
-- A plain CREATE INDEX: the table is small and Nebu.Release.migrate/0 applies every file inside one transaction, where CONCURRENTLY is
-- not available, and the build takes a SHARE lock on room_invitations (writes wait until the migration transaction commits: a
-- short window on a table of this size). No data change; rolling-deploy safe (old nodes ignore the index).

CREATE INDEX IF NOT EXISTS room_invitations_pending_inviter_idx
    ON room_invitations (inviter_id, invitee_id)
    WHERE accepted_at IS NULL AND rejected_at IS NULL;
