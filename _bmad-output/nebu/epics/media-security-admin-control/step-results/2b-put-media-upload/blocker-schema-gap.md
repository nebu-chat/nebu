# Blocker — 2b-put-media-upload: schema gaps vs. story's own AC/guardrails

Found during Step 1d prep (dependency research before ATDD), verified directly
against migrations and code:

## Gap 1 — `unused_expires_at` is never persisted anywhere

- `media_files` schema (000001_init.up.sql + 000022_media_state_machine_foundation.up.sql)
  has NO `unused_expires_at` column. Full column list: media_id, server_name,
  content_type, file_size, aes_key_hex, nonce_hex, uploader_user_id, uploaded_at,
  deleted, state, file_hash, scan_metadata, storage_key, compressed, archived_at,
  deleted_at, hard_deleted_at.
- Story 2a's `Nebu.Media.create/1` computes `unused_expires_at` purely in memory
  (`System.system_time(:millisecond) + unused_expires_ms()`) and returns it in the
  JSON response — never writes it to the row. 2a's own code-review already flagged
  this forward as INFO: "unused_expires_at not persisted (no such column) — correct
  for 2a scope, future sweeper will need a persistence source."
  (`_bmad-output/.../step-results/2a-post-media-create/code-review-findings.md:24`)
- 2b's own Technical Requirements literally say: "Expiry: `row.unused_expires_at`
  (ms-epoch) `< System.system_time(:millisecond)`" — this cannot be implemented as
  written; there is no such row field.
- 2b's own Dev Agent Guardrails forbid touching migrations: "this story only
  reads/writes existing columns, it does not add new ones."
- Same gap propagates downstream: Story 2e (cleanup cron) assumes a real
  `WHERE unused_expires_at < NOW()` column in its own story text.

Two resolution options:
  (a) Derive effective expiry at read time: `uploaded_at + unused_expires_ms()`
      (config value), no migration needed — but if the config default changes
      between reservation-time and upload-time, the recomputed window could differ
      from what was quoted to the client at `/create` time (narrow race, hours-scale).
  (b) Add a migration persisting `unused_expires_at` at genesis (in
      `StateMachine.create/1`) — cleaner/exact, but violates this story's own
      "no migration" guardrail, and the guardrail was written assuming the column
      problem didn't exist (it predates this discovery).

## Gap 2 — `filename` column does not exist

- Story AC2 requires persisting `?filename=...` on the `media_files` row for later
  `Content-Disposition` derivation. No `filename` column exists in any migration.
  Unlike Gap 1, no prior story's Dev Agent Record flagged this forward — it appears
  to be a plain oversight in this story's own scope vs. its own guardrails.
  Same two resolution shapes as Gap 1 apply (schema addition vs. some other storage
  mechanism, e.g. folding into `scan_metadata` JSONB — but that column's purpose is
  scan results, not upload metadata, so overloading it seems wrong).

## Minor (non-blocking, flagging for completeness)

- Story text says `row.uploader_id`; the actual column/key everywhere in the
  codebase (DB, StateMachine.create/1, MediaFakes) is `uploader_user_id`. Trivial
  naming fix for the dev agent, not an architecture question — not escalating this
  on its own.

## Why this blocks now (before ATDD)

Both AC2 and AC4 depend on a persistence decision (add columns via migration, or
work around without new columns) that determines the literal test assertions ATDD
needs to write (e.g. does the acceptance test seed a `filename` column, or does
"filename persisted" mean something else?). Proceeding to ATDD without resolving
this would either bake in a wrong assumption or need a redo.
