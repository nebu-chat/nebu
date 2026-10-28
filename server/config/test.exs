import Config

config :logger, level: :warning
config :nebu_http, port: 4001

# The idle-bucket sweeper must not fire in the background of tests that freeze the limiter clock;
# its tests call sweep_idle/0 and send(pid, :sweep) explicitly.
config :nebu_http, rate_limit_sweep_interval_ms: :infinity

# story oauth-hardening-hygiene (HY1): ExUnit stays read-through (every Nebu.OAuth.Config.get/1 reads
# server_config). The cache tests set a TTL explicitly and restore it; config/runtime.exs does not touch it in :test.
config :nebu_http, oauth_config_cache_ms: 0

# enhanced-logging/matrix-payload-debug-logging (CI-gate cycle-2): disable
# Nebu.Repo.QueryTelemetry's own Logger.debug/1 call in :test — the handler
# still attaches and runs (unconditionally, everywhere), it just skips
# logging. See the module's @moduledoc "Disabled in :test" section for why:
# ExUnit.CaptureLog.capture_log/1 intercepts the GLOBAL logger, so a query
# fired by any concurrently-running async test can otherwise inject an
# unrelated log line into another test's captured output while it is
# mid-capture at :debug (this broke request_logger_test.exs's AC1 JSON-line
# extraction). No test asserts on this module's own output.
config :nebu, Nebu.Repo.QueryTelemetry, enabled: false
# oidc-middleware-migration: the JwksCache GenServer is NOT started from the
# Application in test — jwks_cache_test.exs starts its own supervised instances
# under the same registered name. Prod/dev start it (default true).
config :nebu_http, start_jwks_cache: false
# media-gateway-migration: the preview_url tests inject a fake fetch boundary, so
# the real Finch pool is not needed in test (and starting it under the Application
# would add an unused supervised process to the children-count assertions).
config :nebu_http, start_finch: false

# media-security-admin-control/3-clamav-genserver: the real Nebu.Media.ClamAV
# GenServer is NOT started from the Application in test — clamav_test.exs
# starts its own start_supervised!/1 instance per test against a real fake
# clamd (:gen_tcp.listen/2 fake server), and a pure-unit run has no real clamd
# container to connect to. Prod/dev start it (default true).
config :nebu_http, start_clamav_client: false

# enhanced-logging/operational-log-store: the central :logger handler is NOT
# attached automatically at boot in :test — every test that needs it
# attached calls Nebu.Web.LogStore.attach_handler/0 itself (idempotent). This
# keeps log_store_test.exs's "registers exactly one new handler" idempotency
# test meaningful: it needs to observe a handler_ids delta of exactly +1 from
# its OWN call, which a boot-time attach (already done before any test runs)
# would otherwise pre-empt. Prod/dev attach it unconditionally at boot (AC2).
config :nebu_http, attach_log_store_handler: false
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

# admin-http-refactor: acceptance tests use Plug.Test directly (not ConnTest/browser).
# They build session conns without going through a GET to acquire a CSRF token, so
# CSRF protection is bypassed for the test environment. NEVER set this in prod/dev.
config :nebu_http, admin_csrf_bypass: true

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
