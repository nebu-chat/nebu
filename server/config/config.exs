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

import_config "#{config_env()}.exs"
