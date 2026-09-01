# Security Review — media-security-admin-control / 7-admin-notifications

**Date:** 2026-07-19
**Reviewer:** Kassandra (adversarial security review)
**Scope:** staged diff for story `7-admin-notifications` —
`server/lib/nebu/media/alert_notifier.ex` (NEW),
`server/lib/nebu/media/webhook_delivery.ex` (NEW),
`server/lib/nebu/workers/media_alert_webhook_worker.ex` (NEW),
`server/lib/nebu/application.ex` (+child), `server/config/config.exs` (+queue),
`server/test/nebu/media/alert_notifier_test.exs` (NEW),
`server/test/nebu/media/webhook_delivery_test.exs` (NEW),
`server/test/nebu/workers/media_alert_webhook_worker_test.exs` (NEW).

**Classification: CLEAN (post-fix). 0 CRITICAL, 0 HIGH remaining, 1 HIGH found-and-fixed
in this session, 0 MEDIUM, 0 LOW, 2 INFO.**

## F-1 HIGH (FOUND AND FIXED IN THIS SESSION) — send-time SSRF re-check missing

This story's own predecessor security review (9a-media-config-table-module,
2026-07-13) explicitly recorded a forward-carry finding naming this story:

> **F-2 MEDIUM (carry-forward to Story 7):** SSRF on webhook_url is validated at
> STORE-time only via the legacy non-pinning `check/1`; the actual sink (Story 7
> sender) re-resolves the host at send-time → DNS-rebinding/redirect SSRF
> (127.0.0.1 / 169.254.169.254). https forces re-resolution even for
> checked_target (SNI caveat). Store-time check gives false assurance; Story 7
> MUST re-check w/ `checked_target/1` IP-pinning + no unvalidated redirects.

The dev-agent's original implementation of `Nebu.Media.WebhookDelivery.post/2`
did NOT do this — it called `Finch.build(:post, url, ...)` directly with no
re-validation, and its own moduledoc explicitly (and incorrectly) reasoned that
"no `SSRF.checked_target/1` gate is needed here" because the target is
"admin-configured, trusted." This directly contradicted the explicit, already-
recorded requirement from the dependency story's own review.

**Why this matters:** `Nebu.Media.Config`'s `validate_value("webhook_url", ...)`
only validates the URL ONCE, at the moment an admin saves it via
`Nebu.Admin.MediaSettingsController`. The webhook itself only fires later, on
the next `:infected`/`scan_failed` transition — which could be minutes, hours,
or days after the save. An attacker who controls DNS resolution for the saved
hostname (a classic DNS-rebinding attack: point the domain at a public IP long
enough to pass the admin's save-time validation, then repoint it to
`169.254.169.254` (cloud-metadata), `127.0.0.1`, or an internal service) gets an
effectively unbounded window in which the server will happily re-resolve the
(now-malicious) hostname and POST to it — a confused-deputy SSRF primitive
reachable without needing to compromise the admin account at all, only DNS for
a domain the admin once pointed at something legitimate.

**Severity reasoning:** rated HIGH (elevated from the dependency review's
MEDIUM "future risk" rating) because the gap was not merely theoretical at
review time — it was the SHIPPED behavior of this story's diff, in direct
contradiction of an explicit, previously-recorded mandate naming this exact
story. Exploitation requires an admin to have configured an
attacker-eventually-controlled hostname (not a fully unauthenticated
remote-trivial bug), which keeps it below CRITICAL, but cloud-metadata SSRF
from a server-side confused deputy is a well-established, high-impact class
(credential theft via `169.254.169.254` on AWS/GCP/Azure deployments).

**Fix applied (verified in this session):** `Nebu.Media.WebhookDelivery.post/2`
now calls `Nebu.Media.SSRF.checked_target/1` immediately before every
`Finch.request/2` call — re-resolving and re-validating the host at the moment
of use, not trusting the stale save-time check. Since `Nebu.Media.Config` only
persists `https://` URLs, IP-pinning the connection (the mitigation
`Nebu.Media.HttpFetch` applies for `http`) is not applicable — SNI/cert
validation requires keeping the hostname in the URL for `https`, which is the
SAME documented residual caveat `HttpFetch` already carries for its own
`https` branch. This closes the unbounded "since the admin last saved"
window down to the same small, already-accepted residual window every other
`https` outbound call in this codebase carries.

**"No unvalidated redirects" (part of the original mandate):** confirmed
already safe with no code change needed — `Finch.request/2` (used, not
`stream_while` or any wrapper) does not auto-follow HTTP redirects; a 3xx
response is returned as-is (`{:ok, %Finch.Response{status: 3xx}}`), which the
worker's `deliver/2` maps to `{:error, {:unexpected_status, status}}` since 3xx
is outside the `200..299` success range. There is no redirect-following code
path to exploit.

**Regression coverage added:** `server/test/nebu/media/webhook_delivery_test.exs`
(NEW) exercises the real `WebhookDelivery.post/2` directly (not through the
`:media_webhook_http_module` test seam every worker-level test replaces it
with) — proving `127.0.0.1`, `10.0.0.5`, and `169.254.169.254` are all rejected
with `{:error, :blocked_address}` before any network call, `file://` is
rejected with `{:error, :bad_scheme}`, and a genuinely public IP passes the
guard and reaches the real `Finch.request/2` call (proven by getting a
connection-level error rather than a `:blocked_address` error, without
depending on a live external network dependency in CI). Verified 7/7 passing
in a plain unit run and re-verified against the live stack (`--include
integration`, real Postgres) alongside `alert_notifier_test.exs` and
`media_alert_webhook_worker_test.exs`: 12/12 passing.

## Retry/backoff amplification risk — assessed, no finding

Reviewed whether a slow/malicious webhook endpoint (one an admin points at in
good faith that happens to be compromised, or a still-live-but-hostile target
after the DNS-rebinding window above) could tie up the `:media_alerts` queue's
capacity or bleed into `:media_scan`'s:

- `Finch.request/2`'s `receive_timeout: 5_000` bounds every single delivery
  attempt to at most 5 seconds — a "hold the connection open and never
  respond" endpoint can occupy at most one of the queue's 5 concurrent slots
  for 5 seconds, not indefinitely (Slowloris-on-the-response-side is capped).
- `max_attempts: 5` bounds the total number of retries per job; combined with
  Oban's own backoff between attempts, a single hostile target's total
  lifetime occupancy of the queue is bounded, not unbounded.
- `:media_alerts` and `:media_scan` are separate Oban queues, each with its
  own independently-supervised producer and concurrency limit
  (`media_alerts: [limit: 5]`, `media_scan: [limit: 10]`) — Oban's queue
  engine dequeues per-queue against the shared `oban_jobs` table, but
  concurrency slots are not shared across queues. A fully-saturated
  `:media_alerts` queue cannot reduce `:media_scan`'s own polling/concurrency
  budget. This holds AC2/AC6's "can never starve scan-job processing"
  guarantee at the Oban-engine level, not merely by convention.
- `unique: [period: 300, keys: [:media_id, :state]]` prevents duplicate
  enqueues (e.g. from multiple cluster nodes observing the same broadcast)
  from multiplying queue pressure for the same event.

**Verdict:** no amplification finding. The existing bounds (5s timeout × 5
attempts × 5-slot queue, isolated from `:media_scan`) are sufficient.

## Payload content leakage — re-verified structurally, no finding

- `Nebu.Media.AlertNotifier.handle_broadcast/1` builds the job args map
  literally as `%{media_id: media_id, state: to_string(new_state), timestamp:
  ...}` — no other field is ever read from the broadcast tuple or any other
  source. There is no code path (conditional, fallback, or otherwise) that
  adds a fourth key.
- `Nebu.Workers.MediaAlertWebhookWorker.perform/1` pattern-matches exactly
  `%{"media_id" => media_id, "state" => state, "timestamp" => ts}` from
  `Oban.Job.args` and forwards them verbatim to `deliver/2` — no enrichment,
  no DB lookup to hydrate additional fields.
- `media_id` is the server-generated internal media identifier (128-bit
  base64url, per Story 2a's `create/1` genesis path) flowing through
  `Nebu.Media.StateMachine`'s own broadcast — never user-supplied free text,
  never a room/message identifier. It is opaque outside an authenticated
  admin session (matches the story's own Summary rationale for narrowing the
  payload versus the epic's first-draft AC).
- `alert_notifier_test.exs` and `media_alert_webhook_worker_test.exs`
  additionally regression-guard this via a JSON round-trip assertion (`Map.keys
  == ["media_id", "state", "timestamp"]` exactly).

**Verdict:** no leakage finding.

## AC1/AC5 topology re-verified against the real broadcast call sites

Confirmed (not just trusted from the story prose) against the actual tree:
`Nebu.Media.StateMachine.broadcast_admin/3` (state_machine.ex:248-254)
broadcasts the 4-tuple `{:media_state_transition, media_id, from_state,
to_state}` on `"media:admin"` — exactly what `AlertNotifier.init/1` subscribes
to. The older 3-tuple `{:media_state_transition, media_id, new_state}` on
`"media:#{media_id}"` (`media_scan_worker.ex`) is correctly NOT subscribed to.

## Guardrail structural re-verification (AC6)

`Nebu.Workers.MediaAlertWebhookWorker` has zero references to
`Nebu.Media.StateMachine` or `Nebu.Media.DB` anywhere in the module — a
delivery failure has no code path back into the media domain. This is a
structural guarantee, not merely a behavioral one confirmed only by test.

## INFO (non-blocking)

- **I-1:** `Nebu.Media.Config.get()[:webhook_url]` is read independently by
  both `AlertNotifier` and `MediaAlertWebhookWorker` (two call sites, matching
  the story's own stated design so a future `media_config` swap stays a
  two-line change). Since `Nebu.Media.Config`'s own cache has up to a 60s TTL
  fallback window (per its moduledoc), an admin disabling the webhook
  (`webhook_url` → nil) could see up to one in-flight enqueue still fire, and
  an already-enqueued job could still see the OLD (now possibly stale) URL for
  up to that same window at pickup time. No security impact (the URL was
  validated when it was set; a brief propagation lag is an accepted trade-off
  of the shared cluster-cache design, not new to this story) — noted for
  completeness only.
- **I-2:** The Oban `unique` constraint's cluster-safety rationale (multiple
  nodes' `AlertNotifier`s observing the same broadcast) is sound and matches
  ADR-025's stated preference for Oban's own guarantees over a bespoke
  singleton scheme — no gap found in this area.

## Test evidence

- `server/test/nebu/media/webhook_delivery_test.exs`: 7/7 passing (plain unit
  run, elixir:1.19-alpine).
- `server/test/nebu/media/alert_notifier_test.exs` +
  `server/test/nebu/workers/media_alert_webhook_worker_test.exs` +
  `webhook_delivery_test.exs` together: 12/12 passing against the live stack
  (`mix test --include integration`, real Postgres, real `Oban.insert/1`).
- Full `make test-integration` run post-fix: 2443 tests, 29 failures (all
  pre-existing, unrelated — `SyncConcurrentTest`, `TraceMapNodeControlsTest`;
  zero media/webhook/alert failures), 3 skipped.
- Full unit suite (`mix test`, excluding integration): 1867 passed, 0
  failures, 2 skipped.

## Follow-up stories required

None. The single HIGH finding was fixed within this same review session and
re-verified; no residual CRITICAL/HIGH remains.
