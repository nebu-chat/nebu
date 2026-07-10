---
name: feedback-stale-cross-file-comments
description: When a fix relocates a config/setting between files, other files' explanatory comments referencing the OLD location often go stale and self-contradict
metadata:
  type: feedback
---

In `enhanced-logging/matrix-payload-debug-logging` cycle 3 verification: the
cycle-4 regression fix correctly moved `config :nebu, Nebu.Repo, log: false`
out of `server/config/config.exs` (unconditional, broke the zero-DB-children
invariant) into the two `NEBU_DB_URL`-gated blocks in `server/config/runtime.exs`.
`config.exs` itself was updated with an accurate comment explaining the move.
But two OTHER files that reference the same setting in prose comments —
`server/lib/nebu/application.ex` and `server/lib/nebu/matrix/session/matrix_session_store.ex`
— were NOT updated and still say "see server/config/config.exs" for where
`log: false` lives. Result: three files now disagree about where the setting
is actually set, with `config.exs` explicitly saying "NOT here" while the other
two still point at it.

**Why:** When a fix's own narrative is specifically about "config location X was
wrong, moved to Y", it's tempting to check only the file that changed and the
file with the new correct code — but a `grep` for the OLD location across the
whole repo is needed to catch every comment that still cites it. This is a
distinct failure mode from [[feedback_redaction_wiring_gap]] (which is about
functional wiring, not documentation) — this one is purely stale prose that
would mislead a future reader/debugger, not a functional bug.

**How to apply:** Whenever a review involves a fix that relocates a setting,
constant, or piece of logic from file A to file B, grep the whole diff (and
ideally the whole repo) for other files' comments that name file A as the
location, not just check that file B now has the right code. Flag any
still-pointing-at-A comments as MINOR (documentation consistency, not a
functional bug) unless the stale comment could plausibly cause someone to
reintroduce the bug by "fixing" the wrong file.

See [[project_enhanced_logging_epic]].
