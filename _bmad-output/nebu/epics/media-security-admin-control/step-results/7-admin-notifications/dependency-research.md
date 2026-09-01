# Story 7 — Pre-dev dependency research (Step 1c/1d prep)

## 1. Broadcast call sites — VERIFIED, matches story exactly

- `server/lib/nebu/media/state_machine.ex` (`broadcast_admin/3`, called from `transition/4`
  after commit) broadcasts the 4-tuple `{:media_state_transition, media_id, from_state,
  to_state}` on topic `"media:admin"` via `Nebu.PubSub`. This is Story 5b's contract, and it
  matches this story's AC1/Technical Requirements exactly (including that `old_state` is
  present, needed for the no-op guard).
- `server/lib/nebu/workers/media_scan_worker.ex` (line ~258) broadcasts the OLDER 3-tuple
  `{:media_state_transition, media_id, new_state}` on the per-file topic `"media:#{media_id}"`
  — this is the topic/shape this story correctly does NOT subscribe to (per AC1 and the
  guardrails).
- Conclusion: no gap. `AlertNotifier` should subscribe to `"media:admin"` exactly as the
  story's illustrative code shows.

## 2. `Nebu.Media.Config` (Story 9a, `server/lib/nebu/media/config.ex`) — ALREADY landed with a `webhook_url` slot

- `@defaults` and `@key_to_atom` both already include `"webhook_url" => nil` /
  `:webhook_url` — this is a pre-existing key in the 10-key `media_config` catalog, not
  something this story needs to add via migration.
- `validate_value("webhook_url", value)` already requires `scheme: "https"` and runs
  `Nebu.Media.SSRF.check/1` on write (via `upsert/2`). Story 9b's admin UI
  (`server/lib/nebu/admin/media_settings_controller.ex` + `templates/media_settings/index.html.heex`)
  already exposes this as an editable field ("Admin notification webhook URL") end-to-end.
- **This is the SAME `webhook_url` this story's webhook needs** — not a different field. The
  story's own Technical Requirements section anticipated exactly this ("if 9a/9b has already
  landed by the time this story is implemented, prefer wiring directly to
  `Nebu.Media.Config.get(:webhook_url)` from the start rather than adding the static
  `config.exs` path only to replace it immediately after").
- **9a/9b HAVE landed** (confirmed: `config.ex`, `config_supervisor.ex`,
  `media_settings_controller.ex`, and the settings template all exist and are wired).
- **Decision (per the story's own explicit contingency, not an ambiguity requiring
  escalation):** dev-story should read the webhook URL via `Nebu.Media.Config` instead of
  introducing the static `config :nebu, :media_alerts, webhook_url: nil` app-env path the
  story's illustrative code shows.
  - **API correction:** the story's prose says `Nebu.Media.Config.get(:webhook_url)` (arity
    1), but the actual module only exposes `get/0`, returning the full 10-key catalog map.
    The correct call is `Nebu.Media.Config.get()[:webhook_url]` (or
    `Map.get(Nebu.Media.Config.get(), :webhook_url)`), in both `AlertNotifier.webhook_url/0`
    and `MediaAlertWebhookWorker.webhook_url/0`, replacing
    `Application.get_env(:nebu, :media_alerts, [])[:webhook_url]`.
  - No migration needed — the `webhook_url` column/key already exists in `media_config`
    (Story 9a's migration). Nothing to add to `server/config/config.exs` for `:media_alerts`
    webhook_url either — drop that config block from the File List; keep only the Oban
    `queues:` extension (`media_alerts: [limit: 5]`).
  - AC4 ("no webhook URL configured is a no-op") is satisfied identically:
    `Nebu.Media.Config.get()[:webhook_url]` defaults to `nil` when unset in the DB, same as
    the app-env path would have.

## 3. SSRF check — confirmed NOT a conflation, two distinct fields share one utility

- `Nebu.Media.SSRF` (`server/lib/nebu/media/ssrf.ex`) is a generic SSRF/transport-downgrade
  guard, originally built for `preview_url` (its own moduledoc header).
- It is reused by TWO independent call sites:
  1. `Nebu.Media.Config`'s `webhook_url` validation (9a/9b) — the admin-notification webhook
     this story fires against.
  2. `Nebu.Media.StorageConfig` (11a/11b) — the S3-compatible storage backend's endpoint URL
     (`storage_config.ex` lines ~55, ~251, ~895 reference "forward-carried from the 11a
     security [requirement]").
- These are different fields for different purposes (admin alert destination vs. storage
  backend target) that both happen to reuse the same generic `SSRF.check/1` helper. No
  conflict, no double-definition — this story's webhook_url reads/writes are entirely
  contained in `Nebu.Media.Config`'s existing `webhook_url` key; nothing to change in
  `Nebu.Media.StorageConfig` or 11a/11b's code.

## Net effect on this story's Technical Requirements / File List

- `Nebu.Media.AlertNotifier.webhook_url/0` → `Nebu.Media.Config.get()[:webhook_url]`
- `Nebu.Workers.MediaAlertWebhookWorker.webhook_url/0` → `Nebu.Media.Config.get()[:webhook_url]`
- `server/config/config.exs` UPDATE — only add the `media_alerts: [limit: 5]` Oban queue
  entry; do NOT add `config :nebu, :media_alerts, webhook_url: nil` (superseded by 9a/9b's
  already-shipped `media_config` table).
- No new migration required for this story.
- Test seams: since `Nebu.Media.Config.get/0` already has its own test seams
  (`Application.get_env(:nebu_http, :media_config_source)` fast path), the acceptance tests
  for "no webhook URL configured" / "webhook URL configured" cases should drive
  `Nebu.Media.Config`'s existing test seam rather than an app-env key invented by this story.
