import Config

config :logger, level: :warning
config :nebu_http, port: 4001
# oidc-middleware-migration: the JwksCache GenServer is NOT started from the
# Application in test — jwks_cache_test.exs starts its own supervised instances
# under the same registered name. Prod/dev start it (default true).
config :nebu_http, start_jwks_cache: false
# media-gateway-migration: the preview_url tests inject a fake fetch boundary, so
# the real Finch pool is not needed in test (and starting it under the Application
# would add an unused supervised process to the children-count assertions).
config :nebu_http, start_finch: false
config :signature, pii_encryption_key: :crypto.strong_rand_bytes(32)

# admin-ui-migration: the Phoenix LiveView Admin UI endpoint. The endpoint runs with
# server: false (no port opened); it is started under the Application so the LiveView
# unit test (admin_liveview_unit_test.exs) can mount RoomsLive via live_isolated/3,
# which resolves the endpoint config (secret_key_base, signing salts). A fixed,
# non-secret test key is used — this listener never faces the network in tests.
config :nebu_http, start_admin_endpoint: true

# F-2 (security review): admin session cookie defaults to secure:true (TLS-only).
# Tests run over plain HTTP, so relax it here only.
config :nebu_http, admin_session_secure: false

config :nebu, Nebu.Admin.Endpoint,
  server: false,
  secret_key_base: String.duplicate("nebu-admin-test-secret-key-base!", 2),
  live_view: [signing_salt: "nebu-admin-lv-test"]

# Story 5.5: suppress Nebu.Compliance.SessionExpiryWorker from Application supervisor in test env
# so existing application_test.exs (Story 5.2 AC2) continues to assert children=[].
# Tests that require the worker start it directly via SessionExpiryWorker.start_link([]).
config :compliance, :workers, []

# Epic 9 HIGH-1 fix: default to NoOpAuditWriter in test env so gRPC handler tests
# that add audit calls (deactivate_user, reactivate_user, update_user_role) do not
# require a live Nebu.Repo connection. Tests that need to verify audit emission
# override this via Application.put_env(:compliance, :audit_writer, FakeAuditWriter).
config :compliance, :audit_writer, Nebu.Compliance.NoOpAuditWriter
