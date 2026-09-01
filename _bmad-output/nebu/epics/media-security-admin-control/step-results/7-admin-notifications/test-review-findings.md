# Step 3 — Pre-dev test-review (self-reviewed, no sub-agents per orchestrator instruction)

## Coverage
All 9 Acceptance Tests from the story map 1:1 to a test in one of the two new files:
- `server/test/nebu/media/alert_notifier_test.exs` — AT1-AT5 (AC1, AC2, AC4, AC5).
- `server/test/nebu/workers/media_alert_webhook_worker_test.exs` — AT6-AT9 (AC3, AC6).

## RED-phase verification (ran against the real elixir:1.20-alpine image, `mix test`)
- `media_alert_webhook_worker_test.exs` (no `:integration` tag, needs no live Postgres):
  4/4 tests fail with `Expected worker to be a module that implements the Oban.Worker
  behaviour` (module does not exist yet) — genuine RED.
- `alert_notifier_test.exs` (`@moduletag :integration`, mirrors `scan_enqueue_test.exs`'s
  own real-Postgres convention since `AlertNotifier.handle_broadcast/1` performs a real
  `Oban.insert/1`): compiles clean (one expected "undefined function" warning, since
  `Nebu.Media.AlertNotifier` does not exist yet); run without a live DB correctly flunks
  via the file's own `Process.whereis(Nebu.Repo) == nil` guard — same contract as
  `scan_enqueue_test.exs`/`media_admin_actions_test.exs`. Will genuinely RED (module
  undefined) once run under `make test-integration`'s live Postgres, verified at ci-gate.

## Design-decision note carried from dependency-research.md
Both files deliberately do NOT introduce a new `:media_alerts` app-env key for
`webhook_url` — they drive `Nebu.Media.Config`'s existing `:nebu_http,
:media_config_source` test seam instead, since Story 9a/9b already ships a real
`webhook_url` slot in `media_config` (see `dependency-research.md`). This is a
deviation from the story's own illustrative Technical Requirements code, made per the
story's own explicit "confirm at dev-story time" instruction — flagged here again so the
dev-story step doesn't try to reconcile against the illustrative app-env snippet.

## Gaps considered and accepted as out of scope for this story
- No test exercises the real `Nebu.Media.WebhookDelivery` module's own `Jason.encode!`/
  Finch call — the worker's own seam (`:media_webhook_http_module`) replaces it entirely
  in both test files, consistent with how `Nebu.Media.ClamAV`'s real GenServer is never
  exercised by `media_scan_worker_test.exs` either. `WebhookDelivery` is a "thin Finch
  wrapper" per the story's own Technical Requirements — its correctness is proven at
  ci-gate's live-stack integration run, not a dedicated unit test (no story AC asks for
  one).
- No test exercises `Nebu.Application`'s supervision-tree wiring of `AlertNotifier`
  (starting after `Nebu.PubSub`) — this is exactly the class of thing `make redeploy` +
  `make test-integration`'s full-stack boot proves (an app that fails to boot fails the
  whole gate), not a meaningful unit-test assertion, consistent with 4b's own ATDD
  moduledoc precedent ("Oban actually boots the queue" is a ci-gate concern, not a unit
  test).

## Verdict
CLEAN — 0 MAJOR gaps. Proceeding to dev-story.
