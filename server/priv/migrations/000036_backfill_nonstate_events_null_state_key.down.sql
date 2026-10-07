-- Rollback for 000036_backfill_nonstate_events_null_state_key.up.sql.
--
-- ─── Why this rollback is approximate, not exact (read before running) ─────
--
-- The up migration corrects EXISTING rows in place (`state_key = '' ->
-- NULL`); it is not an INSERT, so it cannot use 000035's "tag new rows with a
-- distinguishing marker, then DELETE WHERE marker = ..." trick to precisely
-- and exclusively target what it changed. There is no spare marker column on
-- `events` to stamp, and adding one is out of scope for a bugfix migration.
-- This rollback therefore uses the only information actually available: the
-- up migration's own WHERE clause, inverted. It sets `state_key = ''` back
-- for every row where `state_key IS NULL` AND `event_type` is one of the same
-- verified non-state types the up migration's INCLUSION list targets (code-
-- review cycle 3, MAJOR-1 — see that file's own rationale comment for how the
-- list was built and verified).
--
-- This is EXACT if run immediately after the up migration, before any new
-- non-state event has been written. It becomes LOSSY once real traffic
-- resumes: the companion code fix (`room/server.ex`'s `do_send_event/7`,
-- same cycle) means every NEW non-state event sent after both fixes deploy is
-- now CORRECTLY persisted with `state_key IS NULL` — exactly the same stored
-- representation as a row this migration nulled. Once such new rows exist,
-- this rollback cannot tell "a row the up migration corrected" apart from "a
-- brand new, correctly-NULL row the fixed writer produced" — it would wrongly
-- re-corrupt the latter back to `''`, undoing half of this bugfix's own
-- writer-side correctness for any event sent in the interim. There is no way
-- to distinguish these two cases from the stored data alone without a marker
-- column this migration does not have the luxury of adding.
--
-- Practical guidance: treat this `.down.sql` as a same-deploy-window
-- emergency rollback only (e.g. this migration is found to be subtly wrong
-- immediately after a deploy, before meaningful new traffic has landed) —
-- NOT as a general-purpose "undo this feature" button to reach for after the
-- system has run with the fix for any length of time. Also note a `.down.sql`
-- only reverts SCHEMA/DATA; it cannot un-deploy the paired `do_send_event/7`
-- code fix, so running this rollback alone does not actually restore
-- "pre-fix" application behavior either way — the write-path bug stays fixed
-- regardless of whether this historical-data correction is rolled back.

UPDATE events
SET state_key = ''
WHERE state_key IS NULL
  AND event_type IN (
      'm.room.message'
  );
