# Code Review — 4b-media-scan-worker (cycle 0)

## AC coverage verification

All 10 ACs implemented and covered by tests (see test-review AC matrix). AC1/AC2 correctly
adapted to reality (queue-only addition to already-bootstrapped Oban). CI gate green (1845
unit / 2321-37 integration, all failures pre-existing/unrelated per baseline diff).

## Findings

**MINOR-2:** `Nebu.Workers.MediaScanWorker.scan_and_transition/3` uses `Base.decode16!/2`
(bang) directly inside a `with` chain's plain `<-` bindings (not `{:ok, _} <-`). A malformed/
corrupted `aes_key_hex`/`nonce_hex` value raises `ArgumentError`, which is NOT caught by the
`with...else` clause (the `else` only fires on a non-matching pattern-match result, not a raised
exception) — the raise propagates out of `perform/1` entirely, bypassing `scan_error/4`. On the
LAST attempt, this means the worker never reaches the `:scan_failed` transition or AC8's
required broadcast — Oban's own crash-handling still retries/discards the job, but silently,
without this worker's own AC9 dead-letter guarantee. Low likelihood in practice (requires
corrupted DB data — this codebase always writes valid hex via its own Crypto module), but it
directly undermines AC9's stated purpose ("a file never gets stuck silently in :quarantined
after retries are genuinely exhausted"). Fix: use non-bang `Base.decode16/2` and route a decode
failure through the same `scan_error/4` path as any other pre-scan failure.

**MINOR-3:** `perform/1`'s `case` on the entry `:scanning` transition only matches
`{:error, {:invalid_transition, from, :scanning}}` and `{:ok, :scanning}`.
`Nebu.Media.StateMachine.transition/4` can also return `{:error, :not_found}` or
`{:error, :invalid_actor}` per its own documented contract — neither is handled, so either
would raise `CaseClauseError` (again bypassing `scan_error`'s clean retry/discard path, same
class of gap as MINOR-2, on the entry transition instead of mid-scan). Fix: add a catch-all
`{:error, reason} -> scan_error(media_id, reason, attempt, max_attempts)` clause (or similar)
so any unexpected StateMachine outcome still drives the worker's own retry/discard/broadcast
guarantee instead of an uncaught crash.

**INFO-1:** `infect/2` performs `state_machine().transition/4` then `db().update_scan_metadata/2`
as two separate, non-transactional writes, and does not log on the second call's failure. The
story's own Technical Requirements explicitly frames the same-transaction approach as a
"prefer," not a MUST ("is not a violation of Story 1b's state-mutation invariant... still,
prefer doing this write in the same DB transaction"), so this is not a correctness gap against
the AC — flagging only so a future story tightening this doesn't have to rediscover it. Consider
at least logging a warning if `update_scan_metadata/2` returns `{:error, _}`.

## Decision

0 MAJOR/CRITICAL. 2 MINOR (MINOR-2, MINOR-3) + 1 INFO. Cycling back to dev-story per pipeline
auto-cycle rule (cycle 1).
