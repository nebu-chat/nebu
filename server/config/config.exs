import Config

# enhanced-logging/matrix-payload-debug-logging (CI-gate cycle-2, global fix for
# bug 2; cycle-4 regression fix): Ecto's default query logger emits BOUND SQL
# PARAMETER VALUES verbatim at :debug level for every query — including
# credentials (opaque access/refresh tokens, e.g.
# `Nebu.Matrix.Session.MatrixSessionStore`'s queries) bound as plain params.
# `log: false` disables Ecto's own `Logger` call for every query against
# `Nebu.Repo` wherever the Repo is actually configured (this must hold
# regardless of env — the whole point of this epic is making :debug safe to
# enable anywhere, including prod). This does NOT disable the underlying
# `[:nebu, :repo, :query]` telemetry event, which Ecto still emits
# unconditionally — `Nebu.Repo.QueryTelemetry` attaches to that event and logs
# a redacted summary (source + duration_ms, never bound params) at :debug
# instead, so operators keep equivalent query-level debug visibility.
#
# IMPORTANT: this key is deliberately NOT set here (in config.exs, which is
# compiled into every build unconditionally). `Nebu.Application.repo_children/0`
# uses `Application.get_env(:nebu, Nebu.Repo)` as the sole signal for "is a
# real DB configured" — plain unit runs (no NEBU_DB_URL) must see this as `nil`
# so they start zero DB children. Setting `log: false` here made that key
# always-truthy and broke the invariant (cycle-4 regression). Instead,
# `log: false` is merged into the SAME `config :nebu, Nebu.Repo, url: ...` call
# in `config/runtime.exs`, in both places that call is made conditional on
# `NEBU_DB_URL` being present — see there.

# oauth-client-revocation (AC11): Phoenix.Logger prints the request parameters of every controller action at :debug.
# The OAuth admin forms carry a CSRF token and free-text fields (a revocation reason, the typed host): never logged.
config :phoenix,
  filter_parameters: ["password", "reason", "confirm_host", "_csrf_token", "csrf_token"]

# ── admin-ui-migration: Phoenix LiveView Admin UI endpoint (compile-time base) ──
# server: false — the AdminEndpoint never opens its own port. The umbrella's single
# Bandit listener (Nebu.Web.Router) forwards the /admin subtree into this endpoint, so
# admin rides the same listener as Matrix/media. secret_key_base + live_view signing
# salt are overridden per-env (runtime.exs in prod/dev; test.exs for the unit suite).
# ADR-019: endpoint config lives under the single :nebu app key (otp_app: :nebu).
config :nebu, Nebu.Admin.Endpoint,
  server: false,
  url: [host: "localhost"],
  # A non-empty formats list is REQUIRED: Phoenix.Endpoint.RenderErrors negotiates
  # a format and does `[{fmt, view} | _] = formats`, so an EMPTY list crashed the
  # error handler with a MatchError (masking the real exception, e.g. a rejected
  # CSRF POST) — see Nebu.Admin.ErrorHTML. html is first so it is the fallback when
  # the request carries no/empty Accept header.
  render_errors: [
    formats: [html: Nebu.Admin.ErrorHTML, json: Nebu.Admin.ErrorHTML],
    layout: false
  ],
  pubsub_server: Nebu.Admin.PubSub,
  live_view: [signing_salt: "nebu-admin-lv"],
  adapter: Bandit.PhoenixAdapter

# Phoenix uses Jason for JSON encoding.
config :phoenix, :json_library, Jason

# ── media-security-admin-control/3-clamav-genserver: ClamAV scanner client ──
# Compile-time default (generic, non-Docker-specific — safe for any environment
# that hasn't configured otherwise). Prod/dev override host/port via
# NEBU_CLAMAV_HOST/NEBU_CLAMAV_PORT in config/runtime.exs (dev-stack default:
# the Docker Compose service name "clamav"). Only the `{:tcp, host, port}`
# address shape is implemented (AC2); `{:unix, path}` is a documented,
# not-yet-implemented future option.
# signature_max_age_hours (media-security-admin-control/10b-clamav-status-freshclam-age,
# AC4): static app-config default for the freshclam signature-staleness warning threshold.
# 48h chosen per that story's AC4 justification; admin-configurable override is out of
# scope for 10b (future home: Story 9's media_config admin-settings UI).
config :nebu, Nebu.Media.ClamAV,
  address: {:tcp, "127.0.0.1", 3310},
  max_file_size_bytes: 100 * 1024 * 1024,
  signature_max_age_hours: 48

# ── media-security-admin-control/2d-download-stall-mechanism ──────────────────
# Opt-in `?timeout_ms=N` download stall on :quarantined/:scanning media.
# max_stall_ms: server-owned ceiling a client-requested timeout is clamped to
#   (AC2, spec's "content repository SHOULD impose a maximum").
# max_concurrent_stalls: global ceiling on simultaneously held stall requests
#   (AC6) — beyond it, requests degrade to the immediate 1c response.
# Read via Nebu.Media.max_stall_ms/0 / max_concurrent_stalls/0 (a one-line swap
# to Nebu.Media.Config.get/0 once Story 9 lands).
config :nebu, Nebu.Media,
  max_stall_ms: 20_000,
  max_concurrent_stalls: 500

# ── media-security-admin-control/2e-reserved-upload-cleanup-cron (ADR-025) ────
# Oban bootstrap. 2e lands ahead of 4b (MediaScanWorker) in actual build order,
# so it absorbs the one-time schema/config/supervisor setup 4b's own story had
# originally planned. `queues:` originally declared only `media_cleanup` here;
# 4b (media-security-admin-control/4b-media-scan-worker) adds the `media_scan`
# queue entry below for its own Nebu.Workers.MediaScanWorker.
#
# IMPORTANT — the `Oban.Plugins.Cron` crontab entry for
# `Nebu.Workers.MediaReservedUploadCleanupWorker` is deliberately NOT listed
# below yet. Confirmed via direct inspection of the fetched `oban ~> 2.18`
# dependency (deps/oban/lib/oban/config.ex `Config.new/1`: `with {:error,
# reason} <- validate(opts) do raise ArgumentError, reason end`, and
# deps/oban/lib/oban/plugins/cron.ex `validate_crontab/1`: `not
# Code.ensure_loaded?(worker) -> {:error, ...}`) that `Oban.Plugins.Cron`
# validates every crontab worker module EAGERLY, at `Oban.start_link/1` time —
# not lazily at first cron tick. Since `Nebu.Workers.MediaReservedUploadCleanupWorker`
# does not exist yet (ATDD-only story — the worker itself is dev-story's job),
# listing it here would crash Oban's supervisor child (and therefore the whole
# app) the moment Oban is ever started against a real DB (`make redeploy` /
# `make test-integration`), even though it is harmless for the plain unit
# suite (Oban is never started there — see `repo_children/0` in
# `Nebu.Application`, gated on `Nebu.Repo` being configured).
#
# media-security-admin-control/2e-reserved-upload-cleanup-cron (AC2): the
# worker module now exists (server/lib/nebu/workers/
# media_reserved_upload_cleanup_worker.ex) — the crontab entry deferred during
# ATDD (Oban.Plugins.Cron validates every crontab worker module eagerly via
# Code.ensure_loaded?/1 at Oban.start_link/1 time, so listing it before the
# module existed would have crashed the app on boot) is added below.
#
# CONFIRMED BUG FOUND WHILE VERIFYING THIS BOOTSTRAP (2026-07-14, fixed here):
# the story's own guardrail text put `shutdown_grace_period:` INSIDE the
# `media_cleanup` queue's keyword list — that is NOT a valid per-queue Oban
# option. Confirmed by actually starting Oban against a real Postgres
# (`Nebu.Release.migrate()` boots the full `Nebu.Application`, which starts
# Oban once `Nebu.Repo` is configured): it raised `** (ArgumentError) invalid
# value for :queues, queue :media_cleanup, unexpected option
# {:shutdown_grace_period, 30000}` (`deps/oban/lib/oban/config.ex`
# `validate_queue/2` delegates unknown per-queue keys to the engine, which
# rejects it). `shutdown_grace_period` is a TOP-LEVEL Oban instance option
# (`deps/oban/lib/oban.ex` `t:option/0` / `deps/oban/lib/oban/queue/supervisor.ex`
# reads it off `conf.shutdown_grace_period`, applied to every queue on that
# Oban instance) — moved down here accordingly.
config :nebu, Oban,
  repo: Nebu.Repo,
  shutdown_grace_period: :timer.seconds(30),
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)},
    # code-review MINOR fix: Oban.Plugins.Pruner's max_age is in SECONDS (not
    # ms like Lifeline's rescue_after/shutdown_grace_period above/below) — a
    # plain literal is clearer than mixing the :timer ms helper with a
    # manual `div(1000)` to get back to seconds.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Nebu.Workers.MediaReservedUploadCleanupWorker},
       # media-security-admin-control/8a-media-cleanup-worker (AC2): daily
       # 02:00 UTC retention purge of aged :deleted/:infected media_files
       # rows. Safe to add here (unlike 2e's own ATDD-time chicken-and-egg
       # problem documented above) since Nebu.Workers.MediaCleanupWorker
       # already exists by the time this entry is added.
       {"0 2 * * *", Nebu.Workers.MediaCleanupWorker},
       # media-security-admin-control/8c-media-archive-worker (AC10): shares
       # Story 8a's 02:00 UTC cadence — the two jobs' candidate populations
       # are disjoint by construction (8a: state IN ('deleted', 'infected');
       # 8c: state = 'released' AND archived_at IS NULL), so no row-level
       # contention exists between them.
       {"0 2 * * *", Nebu.Workers.MediaArchiveWorker},
       # media-security-admin-control/8b-orphan-detection-gdpr (AC2): hourly
       # DETECTION-ONLY report of orphaned :quarantined media_files rows.
       # Tighter than 8a's daily cadence is not required since nothing
       # destructive happens here — hourly just keeps the audit-log report
       # reasonably fresh. Safe to add here for the same reason as 8a above
       # (Nebu.Workers.MediaOrphanDetectionWorker already exists by the time
       # this entry is added).
       {"0 * * * *", Nebu.Workers.MediaOrphanDetectionWorker},
       # media-security-admin-control/8d-released-auto-delete (AC2): shares
       # 8a/8c's 02:00 UTC cadence. Disjoint from both by construction (this
       # worker's own candidate query is state = 'released' AND
       # released_delete_after_days-derived age — it never fires unless an
       # admin has explicitly opted in via Nebu.Media.Config, defaulting to
       # nil/disabled) — the :deleted rows it produces simply feed 8a's own
       # existing deleted_days-based eligibility query on 8a's NEXT run, not
       # this same tick.
       {"0 2 * * *", Nebu.Workers.MediaReleasedAutoDeleteWorker},
       # media-security-admin-control/10a-scan-stats-rollup (AC3): 5 minutes
       # past every hour — enough buffer that the just-completed hour's
       # media_state_transitions writes (all synchronous DB inserts from
       # Story 4b's worker) have committed before this rollup queries them,
       # without meaningfully delaying visibility of the new hour's numbers.
       # Runs on the shared :media_cleanup queue (a periodic aggregation job,
       # not a per-upload scan job — does not belong on :media_scan).
       {"5 * * * *", Nebu.Workers.MediaScanStatsRollupWorker},
       # media-security-admin-control/10c-media-alerts-triggers (AC2): every
       # minute — tighter than every other entry above, because the default
       # clamav_down_alert_minutes threshold is 5 minutes and a coarser cron
       # cadence would materially delay detection. Runs on the shared
       # :media_cleanup queue (a periodic housekeeping/monitoring job, not a
       # per-upload scan job).
       {"* * * * *", Nebu.Workers.MediaAlertsCheckerWorker},
       # oauth-broker/oauth-metadata-dcr-admin-approval (ADR-033): hourly purge of
       # `pending` OAuth client registrations older than oauth_pending_ttl_days
       # (default 30). Only status = 'pending' rows can match; approved/rejected
       # registrations are never purged. Own queue (limit 1): a periodic
       # housekeeping job that must not compete with media jobs.
       {"23 * * * *", Nebu.Workers.OAuthPendingPurgeWorker},
       # epic oauth-broker, story oauth-authorize-idp-delegation-code (AC11): every 10
       # minutes, purge expired authorization requests and authorization codes expired more
       # than 24 h ago. Housekeeping only (consumption checks expires_at itself).
       {"*/10 * * * *", Nebu.Workers.OAuthFlowPurgeWorker},
       # epic oauth-broker, story client-ip-misconfiguration-warnings (SEC gate 3, G3-2): every 6 hours at
       # minute 37 (clear of the :00 / :05 / :10 / :23 jobs), read-only check of `devices` for a collapsed
       # client address; logs ONE warning with counts only. The signal needs 24 h of traffic anyway, and a
       # real single-NAT deployment would get 24 unsilenceable lines a day at an hourly cadence (4 a day is
       # loud enough). Existing limit-1 `oauth_cleanup` housekeeping queue, no new queue.
       {"37 */6 * * *", Nebu.Workers.ClientIPCheckWorker}
     ]}
  ],
  # media-security-admin-control/4b-media-scan-worker (AC2): media_scan is
  # Nebu.Workers.MediaScanWorker's own queue, enqueued on-demand by 2b's
  # upload handler (via Nebu.Media.ScanEnqueue) — not on a cron schedule, so
  # no crontab entry is added for it.
  # media-security-admin-control/7-admin-notifications (AC2): media_alerts is
  # Nebu.Workers.MediaAlertWebhookWorker's own dedicated queue, enqueued by
  # Nebu.Media.AlertNotifier on :infected/:scan_failed — separate from
  # media_scan so a slow/backed-up webhook delivery can never starve or delay
  # scan-job processing. No crontab entry either (event-driven, not scheduled).
  queues: [media_cleanup: [limit: 10], media_scan: [limit: 10], media_alerts: [limit: 5], oauth_cleanup: [limit: 1]]

# The retention windows of Nebu.Workers.MediaCleanupWorker (deleted_days 30, infected_days 7 without a stored
# value) come from the media_config table (Admin media settings) via Nebu.Media.Config.retention_days/0 since story
# media-cleanup-reads-media-config (follow-up du); the former `config :nebu, :media_cleanup` block is gone.

# media-security-admin-control/8b-orphan-detection-gdpr (AC4): the
# unreferenced-quarantined-file detection threshold for
# Nebu.Workers.MediaOrphanDetectionWorker. Read via
# Application.get_env(:nebu, :media_orphan_detection, []) with the same
# default as a fallback. Deliberately a SEPARATE, own key/value from
# Nebu.Media.Config's (Story 9a, already landed) own `orphaned_hours`
# default of 24 for the media_config DB table — per 9a's own moduledoc,
# this worker is not rewired to read from there yet (mirrors 8a's own
# deleted_days/infected_days precedent of an intentionally-separate,
# not-yet-rewired config.exs value). Not yet one of Story 9a's
# admin-configurable media_config keys in actual effect — a forward-compat
# note only, not a dependency of this story.
config :nebu, :media_orphan_detection,
  orphaned_hours: 48

# media-security-admin-control/8c-media-archive-worker (AC1): gates
# Nebu.Workers.MediaArchiveWorker. released_archive_after_days: nil disables
# the worker entirely (its candidate query returns zero rows, a pure no-op —
# never raises). archive_delete_from_primary: false (default) leaves the
# primary-bucket object in place after a successful archive copy. Read via
# Application.get_env(:nebu, :media_archive, []) with the same defaults as a
# fallback, the pattern Story 8a used before story media-cleanup-reads-media-config moved it to media_config. Not yet
# one of Story 9a's admin-configurable media_config keys — a forward-compat
# note only, not a dependency of this story.
config :nebu, :media_archive,
  released_archive_after_days: nil,
  archive_delete_from_primary: false

import_config "#{config_env()}.exs"
