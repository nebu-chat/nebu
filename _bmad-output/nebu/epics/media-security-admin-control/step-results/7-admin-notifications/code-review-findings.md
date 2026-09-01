# Step 6 — Code review (self-reviewed, no sub-agents per orchestrator instruction)

## Scope
`server/lib/nebu/media/alert_notifier.ex`, `server/lib/nebu/media/webhook_delivery.ex`,
`server/lib/nebu/workers/media_alert_webhook_worker.ex`,
`server/lib/nebu/application.ex` (+10 lines), `server/config/config.exs` (+3 lines),
both new test files.

## AC-by-AC verification
- **AC1** (subscribe to `"media:admin"` only, no per-media_id, no new topic): `init/1`
  subscribes to `@topic "media:admin"` only. Confirmed against the real
  `Nebu.Media.StateMachine.broadcast_admin/3` call site (`state_machine.ex:248-254`) —
  topic name and 4-tuple shape match exactly.
- **AC2** (enqueue-only, never synchronous HTTP, dedicated queue, no-op guard): `handle_broadcast/1`'s
  first clause `{:media_state_transition, _id, same, same} -> :ok` guards the re-broadcast
  case before the `new_state in @notify_states` clause is reached. The notifier never
  calls any HTTP function — only `Oban.insert/1`. Queue `:media_alerts` is separate from
  `:media_scan` in both the worker's `use Oban.Worker` and `config.exs`.
- **AC3** (payload = exactly `media_id`, `state`, `timestamp`): `perform/1` pattern-matches
  exactly these three keys and forwards them verbatim to `deliver/2` — no code path adds
  any other field. Verified via test (JSON round-trip asserts exactly 3 keys).
- **AC4** (no webhook URL ⇒ never enqueues, not an error): `if webhook_url() do ... end`
  — when `nil`, the `if` body never runs, `Oban.insert/1` is never called, no error/log.
  Verified via test.
- **AC5** (only `:infected`/`:scan_failed` notify): `@notify_states [:infected,
  :scan_failed]` guard on the second `handle_broadcast/1` clause; every other `new_state`
  falls to the catch-all `-> :ok`. Verified via table-driven test over all 6 other states.
- **AC6** (worker never touches media state; failures are Oban's problem): worker module
  has zero references to `Nebu.Media.StateMachine` or `Nebu.Media.DB` — structurally
  guaranteed, not just behaviorally. `deliver/2` maps non-2xx/timeout/connection-refused
  to `{:error, reason}`, which Oban's queue engine retries per `max_attempts: 5` then
  discards — no custom `discard/2` logic needed (matches the story's own note).

## Design-decision correctness (webhook_url source)
Both `AlertNotifier.webhook_url/0` and `MediaAlertWebhookWorker.webhook_url/0` read
`Nebu.Media.Config.get()[:webhook_url]` — verified this is the REAL API shape (`get/0`,
not `get/1`) by reading `config.ex` directly, not just trusting the story's prose. No
migration added (`webhook_url` key already exists in `media_config` since Story 9a) — no
`GRANT` statement needed since no new table/column was created (the epic's known
Story-9a-gotcha about new-table grants does not apply here).

## Cleanliness / reuse
- Reuses `Nebu.Media.Finch` pool (no second Finch pool started).
- Reuses the existing `:media_config_source` test seam (`Nebu.Media.Config`'s own,
  Story 9a) rather than inventing a parallel one.
- No duplication of `Nebu.Media.SSRF` logic — `WebhookDelivery` correctly does NOT call
  `SSRF.checked_target/1` (validation already happened at config-write time via
  `Nebu.Media.Config`'s `validate_value/2`), avoiding a redundant/confusing second guard.

## Findings
None — 0 MAJOR/CRITICAL, 0 MINOR. Verdict: CLEAN.

## Note carried forward
Per the story's `security_review: optional` frontmatter and this outbound-webhook/
network-facing surface, the orchestrator's own briefing says to ask before running
Kassandra rather than deciding unilaterally — surfaced back to the caller rather than
auto-run or auto-skipped.

## Post-security-review update
Kassandra's review (see `docs/stories/media-security-admin-control/security-reports/
7-admin-notifications-security-review-2026-07-19.md`) found 1 HIGH: this self-review
missed that `Nebu.Media.WebhookDelivery.post/2` needed a send-time SSRF re-check
(`SSRF.checked_target/1`) per an explicit forward-carry mandate recorded in Story 9a's
own security review — the code as originally written reasoned incorrectly that no
re-check was needed. Fixed in the same pass: `post/2` now calls `SSRF.checked_target/1`
before every `Finch.request/2`. New test file `webhook_delivery_test.exs` (7 tests)
added, exercising the real module directly. Re-verified: full unit suite green (1867
passed), full `make test-integration` clean of media regressions (2443 tests, 29
pre-existing/unrelated failures), 12/12 media/webhook tests green live-stack.
Updated verdict: CLEAN post-fix, 0 remaining findings.
