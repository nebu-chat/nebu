import Config

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
