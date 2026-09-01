---
story_id: 7-admin-notifications
title: "Admin Notifications (Scan Failures & Infected)"
epic: media-security-admin-control
status: done
security_review: optional
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 4b's `Nebu.Workers.MediaScanWorker` drives every quarantined upload to a terminal
state and broadcasts the outcome (`:released`, `:infected`, `scan_failed`) via
`Phoenix.PubSub`. Story 5b subscribes the admin LiveViews to a second, broader topic —
`"media:admin"`, carrying the 4-tuple `{:media_state_transition, media_id, old_state,
new_state}` — so the nav "attention" badge and the media table update live without a
per-`media_id` subscription per row. This story adds the piece the epic scopes as its own
("Admin Notifications"): an **optional outbound webhook**, fired when a file becomes
`:infected` or exhausts its scan retries into `scan_failed`, so an operator who isn't
watching the Admin UI can still be paged (e.g. into an incident channel, SIEM ingest, or a
generic alert relay) by their own infrastructure.

The webhook is deliberately **not** wired directly into `MediaScanWorker` itself — 4b's own
Dev Agent Guardrails already reserve "additional side calls on `:infected`/`scan_failed`"
for a later story (4c's `Nebu.Compliance.AuditWriter` bridge), and embedding a second
unrelated side-effect there would repeat the same layering mistake 4b was explicitly warned
against. Instead, this story introduces a small standalone subscriber,
`Nebu.Media.AlertNotifier`, that listens on 5b's already-broadcasting `"media:admin"` topic
— the same design 5b chose for the nav badge, for the same reason (a system-wide concern
that needs every file's transitions, not one topic per file) — and enqueues an Oban job to
actually perform the HTTP call. The webhook delivery itself never blocks, retries into, or
can fail back onto the scan pipeline: it is a fire-and-forget Oban enqueue from the
notifier's perspective, and Oban owns retry/backoff/discard for the delivery attempt itself,
exactly as ADR-025 already lists "the webhook notification job" among the jobs this epic's
Oban queue was chosen to carry.

**Deviation from the epic's Story 7 first draft, stated explicitly:** the epic's draft AC
described a payload of `{event, media_id, filename, uploader_id, timestamp}`. This story
narrows that to `{media_id, state, timestamp}` only — no `filename`, no `uploader_id`. An
uploaded file's name is often user-chosen free text (it can itself describe sensitive
content — a citizen's case number, a person's name, a subject line) and `uploader_id`
identifies a specific person to whatever external system receives the webhook; neither is
necessary for an ops alert whose only job is "look at media `X` in the admin UI," which
already requires an authenticated admin session to actually view any detail. This is a
compliance-motivated narrowing consistent with the epic's own target audience (German
Kommunen/Behörden) and is flagged here for confirmation rather than silently applied — if a
later review wants `filename`/`uploader_id` back, that is a deliberate scope decision to
make explicitly, not something to restore by default.

## User Story

As an admin operator, I want to optionally receive an outbound webhook call whenever a file
is flagged `:infected` or exhausts its scan retries into `scan_failed`, so that I can be
alerted through my own infrastructure (chat ops channel, SIEM, generic alert relay) without
having to keep the Admin UI open, while being confident that a slow or failing webhook
endpoint can never delay or break the underlying malware-scan pipeline.

## Acceptance Criteria

1. **AC1 — Subscribes to the established broadcast, not a new topic.**
   `Nebu.Media.AlertNotifier` (a `GenServer`, started under `Nebu.Application`'s supervision
   tree) subscribes at `init/1` to `"media:admin"` on `Nebu.PubSub` — Story 5b's broad,
   system-wide topic, carrying the 4-tuple `{:media_state_transition, media_id, old_state,
   new_state}`. This story does **not** subscribe per-`media_id` (that does not scale to
   "every file in the system," and 5b's own guardrails already reject that pattern for
   exactly this "needs every file, not one" reason) and does **not** invent a third PubSub
   topic — it consumes the one 5b already introduced for this class of admin-wide concern.
2. **AC2 — On `:infected`/`scan_failed`, optionally enqueues a webhook job — never calls
   out synchronously.** When a received broadcast's `new_state` is `:infected` or
   `scan_failed` (and `old_state != new_state`, guarding against a re-broadcast of the same
   state being treated as a fresh event), and a webhook URL is configured (AC4), the
   notifier enqueues one `Nebu.Workers.MediaAlertWebhookWorker` Oban job on a dedicated
   `:media_alerts` queue, separate from 4b's `:media_scan` queue, so a slow/backed-up
   webhook delivery can never starve or delay scan-job processing. The notifier itself never
   makes the HTTP call — it only enqueues; delivery is entirely the Oban worker's concern.
3. **AC3 — Webhook payload shape: `media_id`, `state`, `timestamp` — nothing else, and
   never file content.** The JSON body the worker POSTs is exactly
   `{"media_id": "<id>", "state": "infected" | "scan_failed", "timestamp":
   "<ISO-8601 UTC>"}`. The payload MUST NOT include the file's `filename`, `uploader_id`,
   ClamAV signature text, decrypted file bytes, or any other room/message content — see
   Summary for the compliance rationale for this deliberate narrowing versus the epic's
   first-draft AC.
4. **AC4 — Disabled by default; no webhook URL configured is a no-op, not an error.** When
   no webhook URL is configured, `AlertNotifier` does not enqueue any job at all for any
   broadcast — not "enqueues a job that no-ops," but "never enqueues." No HTTP call is ever
   attempted, and nothing is logged as a failure. See Technical Requirements for exactly
   where this config value is read from at this point in the epic's build order.
5. **AC5 — Only `:infected` and `scan_failed` notify; every other transition (including
   `:released`) is silently ignored by the notifier.** A broadcast whose `new_state` is
   `:released`, `:quarantined`, `:scanning`, `:admin_blocked`, `:deleted`, or `:hard_deleted`
   never causes a job to be enqueued, webhook-configured or not.
6. **AC6 — Webhook delivery failures never affect media state or the scan pipeline, and
   never retry-storm.** `Nebu.Workers.MediaAlertWebhookWorker` never calls
   `Nebu.Media.StateMachine` or writes to `media_files`/`media_state_transitions` in any
   branch — its only side effect is the outbound HTTP POST. A delivery failure (non-2xx
   response, timeout, connection refused) is handled entirely by Oban's own retry/backoff on
   the `:media_alerts` queue (bounded `max_attempts`, then `discard`); it can never cause a
   scan-worker retry, never blocks a future scan job, and never re-enters the media state
   machine in any way.

## Acceptance Tests

Two test files, following the `Oban.Testing`/fake-collaborator-seam conventions Story 4b's
own test file (`server/test/nebu/workers/media_scan_worker_test.exs`) already establishes
for this epic (`use Oban.Testing, repo: Nebu.Repo`, `Oban.Testing.perform_job/2` /
`assert_enqueued`/`refute_enqueued`, app-env module seams swapped for fakes in
`Nebu.Web.MediaFakes`).

### `server/test/nebu/media/alert_notifier_test.exs`

1. `test "a broadcast into :infected enqueues a MediaAlertWebhookWorker job for that media_id and state"`
   — with a webhook URL configured, calls `AlertNotifier.handle_broadcast({:media_state_transition, id, :scanning, :infected})`
   directly (the pure delegate `handle_info/2` calls into, per Technical Requirements);
   asserts `assert_enqueued(worker: Nebu.Workers.MediaAlertWebhookWorker, args: %{"media_id" => id, "state" => "infected"})`.
2. `test "a broadcast into scan_failed enqueues a MediaAlertWebhookWorker job"` — same shape
   for `{:media_state_transition, id, :quarantined, :scan_failed}`.
3. `test "no job is enqueued when no webhook URL is configured"` — webhook URL unset/nil;
   calls `handle_broadcast/1` with an `:infected` transition; `refute_enqueued(worker: Nebu.Workers.MediaAlertWebhookWorker)`.
4. `test "a broadcast into :released never enqueues a webhook job"` — table-driven over
   `:released`, `:quarantined`, `:scanning`, `:admin_blocked`, `:deleted`, `:hard_deleted` as
   `new_state`, webhook URL configured in every case; asserts no job is enqueued for any of
   them.
5. `test "a broadcast where old_state == new_state is ignored (no duplicate notification)"`
   — `{:media_state_transition, id, :infected, :infected}`; asserts no job enqueued.

### `server/test/nebu/workers/media_alert_webhook_worker_test.exs`

6. `test "performs a POST to the configured webhook URL with exactly media_id, state, and timestamp"`
   — fake HTTP seam (`:media_webhook_http_module`) captures the request; `perform_job(MediaAlertWebhookWorker, %{"media_id" => id, "state" => "infected", "timestamp" => ts})`
   returns `:ok`; asserts the captured JSON body decodes to a map with exactly the keys
   `"media_id"`, `"state"`, `"timestamp"` (and no others — explicit regression guard against
   `filename`/`uploader_id`/signature ever creeping back in) and the captured URL matches
   the configured webhook URL.
7. `test "a delivery failure (timeout/non-2xx) returns {:error, reason} so Oban retries with backoff, and never touches media state"`
   — fake HTTP seam returns `{:error, :timeout}`; asserts `perform_job/2` returns
   `{:error, :timeout}` (a retryable failure, matching `Oban.Testing`'s convention already
   used in 4b's test 3); asserts the fake `StateMachine`/`DB` seams recorded zero calls —
   proving delivery failure has no path back into the media domain.
8. `test "exhausting max_attempts discards the job without any effect on media state"` —
   `perform_job/2` called with `attempt: max_attempts, max_attempts: max_attempts` and a
   fake HTTP seam that keeps failing; asserts the worker either returns `{:error, reason}`
   (letting Oban's own `max_attempts` bookkeeping discard it, no custom `discard/2` call
   needed since this job has no dead-letter-visible domain state to transition) and again
   asserts zero calls into any media-domain fake.
9. `test "a successful 2xx response returns :ok and the job is not retried"` — fake HTTP
   seam returns `{:ok, 200}`; asserts `perform_job/2` returns `:ok`.

## Technical Requirements

### Subscriber: `Nebu.Media.AlertNotifier`

`server/lib/nebu/media/alert_notifier.ex` — a `GenServer` added to `Nebu.Application`'s
supervision tree (after `Nebu.PubSub` is started, same ordering constraint 4b's Oban child
already documents for needing its dependency started first):

```elixir
defmodule Nebu.Media.AlertNotifier do
  use GenServer

  @topic "media:admin"
  @notify_states [:infected, :scan_failed]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Nebu.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:media_state_transition, media_id, old_state, new_state}, state) do
    handle_broadcast({:media_state_transition, media_id, old_state, new_state})
    {:noreply, state}
  end

  # Exposed as a pure(ish) delegate so tests can drive it without a running
  # GenServer/PubSub round-trip.
  def handle_broadcast({:media_state_transition, _media_id, same, same}), do: :ok

  def handle_broadcast({:media_state_transition, media_id, _old_state, new_state})
      when new_state in @notify_states do
    if webhook_url() do
      %{media_id: media_id, state: to_string(new_state), timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
      |> Nebu.Workers.MediaAlertWebhookWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  def handle_broadcast(_other), do: :ok

  defp webhook_url, do: Application.get_env(:nebu, :media_alerts, [])[:webhook_url]
end
```

(Illustrative — the load-bearing points are: subscribe to `"media:admin"` only, the
`old_state == new_state` no-op guard, the `new_state in @notify_states` filter, and "no
webhook URL configured ⇒ never call `Oban.insert/1`.")

### Oban worker: `Nebu.Workers.MediaAlertWebhookWorker`

`server/lib/nebu/workers/media_alert_webhook_worker.ex`:

```elixir
defmodule Nebu.Workers.MediaAlertWebhookWorker do
  use Oban.Worker,
    queue: :media_alerts,
    max_attempts: 5,
    unique: [period: 300, keys: [:media_id, :state]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_id" => media_id, "state" => state, "timestamp" => ts}}) do
    case webhook_url() do
      nil -> :ok  # config changed to disabled between enqueue and pickup — no-op, not an error
      url -> deliver(url, %{media_id: media_id, state: state, timestamp: ts})
    end
  end

  defp deliver(url, payload) do
    case webhook_http().post(url, payload) do
      {:ok, status} when status in 200..299 -> :ok
      {:ok, status} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp webhook_url, do: Application.get_env(:nebu, :media_alerts, [])[:webhook_url]
  defp webhook_http, do: Application.get_env(:nebu, :media_webhook_http_module, Nebu.Media.WebhookDelivery)
end
```

`server/lib/nebu/media/webhook_delivery.ex` — the thin Finch wrapper, production default
for the `:media_webhook_http_module` seam:

```elixir
defmodule Nebu.Media.WebhookDelivery do
  @finch Nebu.Media.Finch
  @recv_timeout 5_000

  def post(url, payload) do
    body = Jason.encode!(payload)
    req = Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(req, @finch, receive_timeout: @recv_timeout) do
      {:ok, %Finch.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Reuses the `Nebu.Media.Finch` pool `Nebu.Media.HttpFetch` already starts/uses (Story
`media-gateway`-adjacent groundwork; see `server/lib/nebu/application.ex`) rather than
starting a second Finch pool. Unlike `HttpFetch`, this call has no SSRF concern in the same
sense (the target is an admin-configured, trusted destination, not an arbitrary
user-supplied URL from an upload) — no `SSRF.checked_target/1` gate is needed here — and the
payload/response are both tiny, so buffering `Finch.request/2` (not the streaming
`stream_while/5` `HttpFetch` uses for arbitrarily large preview targets) is appropriate.

### Queue configuration — extends 4b's `config :nebu, Oban` block

`server/config/config.exs` — this story extends the `queues:` list 4b's AC2 already
introduces, adding a queue dedicated to alert delivery so it can never contend with scan
throughput:

```elixir
config :nebu, Oban,
  # ...(4b's plugins/repo unchanged)...
  queues: [
    media_scan: [limit: 10, shutdown_grace_period: :timer.seconds(30)],
    media_alerts: [limit: 5]
  ]
```

The `unique: [period: 300, keys: [:media_id, :state]]` option on the worker exists for
**cluster-safety**: `Nebu.PubSub` broadcasts are visible to every connected node (Nebu runs
clustered via `libcluster`/`horde`), so if more than one node has its own `AlertNotifier`
subscribed to `"media:admin"`, more than one node could observe the same broadcast and
attempt to enqueue the same job. Oban's Postgres-backed uniqueness constraint deduplicates
this cheaply (one row wins the unique index, the rest are no-ops) without requiring a
bespoke leader-election/singleton-GenServer scheme for `AlertNotifier` itself — consistent
with this epic's general preference (ADR-025) for letting Oban's built-in guarantees do this
kind of work rather than hand-rolling it.

### Webhook URL config source — app-env now, `media_config` later (explicit design choice to confirm)

At the point in the epic's build order where this story is likely implemented, Story
9a/9b's `media_config` table and `Nebu.Media.Config` module (ADR-027) may not yet exist —
9 is an XL-split story (9a/9b/9c) with its own dependency chain, and ADR-027 itself already
states the intended transition explicitly: *"the Story 7 first-draft decision '`webhook_url`
is ops-only, configured via `config.exs`' is revised — `webhook_url` becomes
admin-configurable via `media_config` from Story 9b onward."* This story therefore
implements the **simple, static** path now:

```elixir
config :nebu, :media_alerts, webhook_url: nil  # or "https://..." set by ops
```

read via the single `webhook_url/0` private function in both `AlertNotifier` and
`MediaAlertWebhookWorker` shown above. Both call sites are intentionally the *only* two
places that read this key, so that when Story 9b lands, swapping `Application.get_env(:nebu,
:media_alerts, [])[:webhook_url]` for `Nebu.Media.Config.get(:webhook_url)` is a two-line
change with no other ripple. **Confirm at dev-story time**: if 9a/9b has already landed by
the time this story is implemented, prefer wiring directly to `Nebu.Media.Config.get/1`
from the start rather than adding the static `config.exs` path only to replace it
immediately after.

## File List

| File | Change Type |
|---|---|
| `server/lib/nebu/media/alert_notifier.ex` | NEW |
| `server/lib/nebu/workers/media_alert_webhook_worker.ex` | NEW |
| `server/lib/nebu/media/webhook_delivery.ex` | NEW |
| `server/lib/nebu/application.ex` | UPDATE — add `Nebu.Media.AlertNotifier` to the supervision tree, after `Nebu.PubSub` |
| `server/config/config.exs` | UPDATE — add `config :nebu, :media_alerts, webhook_url: nil` and extend `config :nebu, Oban`'s `queues:` list with `media_alerts: [limit: 5]` |
| `server/test/nebu/media/alert_notifier_test.exs` | NEW |
| `server/test/nebu/workers/media_alert_webhook_worker_test.exs` | NEW |
| `server/test/nebu/media/media_fakes.exs` | UPDATE (if needed) — add a fake `:media_webhook_http_module` seam capturing POSTs for assertions |

## Dev Agent Guardrails

### Do Not Change

- **Never include decrypted file content or overly sensitive metadata in the webhook
  payload.** The payload is exactly `media_id`, `state`, `timestamp` (AC3). Do not add
  `filename`, `uploader_id`, the ClamAV signature string, or any other `media_files`/
  `media_state_transitions` column "for convenience" or to match the epic's literal
  first-draft AC — see Summary for why this story deliberately deviates from that draft.
  If a future story wants richer payloads, that must be a deliberate, explicitly-reviewed
  addition, not a default restoration.
- **Do not let webhook delivery failures block or retry-storm the scan pipeline.**
  `Nebu.Workers.MediaAlertWebhookWorker` must never call `Nebu.Media.StateMachine`, never
  write to `media_files`/`media_state_transitions`, and must run on its own `:media_alerts`
  Oban queue — never share 4b's `:media_scan` queue's concurrency limit. A slow or
  permanently-down webhook endpoint must never delay a single scan job.
- **Do not subscribe `AlertNotifier` per-`media_id`.** Use the existing broad `"media:admin"`
  topic from Story 5b (mirrors 5b's own guardrail against the identical anti-pattern for the
  nav badge, for the identical reason — this is a system-wide concern, not a per-file one).
- **Do not invent a new PubSub topic or payload shape.** Consume 5b's `"media:admin"` /
  `{:media_state_transition, media_id, old_state, new_state}` contract as-is; do not
  introduce a third topic/shape alongside 2d/4b's per-`media_id` `"media:#{media_id}"` and
  5b's `"media:admin"`.
- **Do not add SMTP/email notification.** Out of scope for this epic per the epic's own
  Story 7 text ("Kein SMTP-Mail in diesem Epic").
- **Do not call `Nebu.Compliance.AuditWriter` from this story's modules.** That bridge is
  Story 4c's scope, hooked directly into `MediaScanWorker`'s own transition call sites — this
  story's webhook is a separate, independent consumer of the same broadcasts, not a second
  place to add compliance-audit writes.

## Dependencies

- **Depends on:**
  - **4b — `Nebu.Workers.MediaScanWorker`** — the ultimate source of the `:infected`/
    `scan_failed` transitions this story reacts to, and the PubSub broadcast machinery
    (`Nebu.PubSub`, the `{:media_state_transition, ...}` message family) this story builds
    on. This story also relies on 4b having introduced Oban itself (dependency, schema,
    supervisor entry, `config :nebu, Oban` block) — this story only extends that
    configuration with a second queue, it does not re-introduce Oban.
  - **5b — Live Row Updates + Nav Attention Badges** — hard dependency for the specific
    broadcast contract this story subscribes to: the broad `"media:admin"` topic and its
    4-tuple payload (`old_state` included), which 5b introduces specifically so system-wide
    consumers (the nav badge, and this story's webhook notifier) don't need one subscription
    per file. If 5b has not yet landed when this story is implemented, confirm with 5b's dev
    agent whether the 4-tuple broadcast call site (recommended: inside
    `Nebu.Media.StateMachine.transition/3`, per 5b's own Technical Requirements) has been
    wired — this story cannot function correctly against only the 3-tuple
    `"media:#{media_id}"` broadcast 2d/4b describe in isolation, since it has no `old_state`
    to run the "ignore no-op re-broadcasts" guard against.
  - **Loosely depends on 9a/9b — `media_config` table / `Nebu.Media.Config` module
    (ADR-027).** Not a hard build-order dependency: this story ships with a static
    `config.exs`-sourced `webhook_url` (see Technical Requirements) and does not require
    9a/9b to exist. However, ADR-027 explicitly documents that `webhook_url` becomes
    admin-configurable via `media_config` "from Story 9b onward" — **flag this as a design
    choice to confirm during dev-story**: if 9a/9b has already landed by the time this story
    is picked up, wire directly to `Nebu.Media.Config.get(:webhook_url)` instead of adding
    the static path only to replace it immediately afterward.
