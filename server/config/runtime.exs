import Config

if config_env() != :test do
  config :nebu_http, port: String.to_integer(System.get_env("NEBU_HTTP_PORT", "4000"))
end

# ─── oauth-trusted-proxy-client-ip: trusted reverse-proxy CIDRs (raw string, parsed at boot) ──
# Unset / empty = no trusted proxy (the direct peer is the client). Parsing, validation and the
# fail-closed rules live in Nebu.Web.ClientIP (loaded from Nebu.Application at boot).
config :nebu_http, trusted_proxy_cidrs: System.get_env("NEBU_TRUSTED_PROXY_CIDRS")

# ─── oauth-hardening-hygiene (HY1): per-node TTL cache of the OAuth switch state ─────────────────
# NEBU_OAUTH_CONFIG_CACHE_MS: integer 0..5000 (milliseconds, 0 = cache off); unset / junk / out of range => 2000.
# An operator write of `oauth_enabled` / `oauth_issuer_url` takes effect on every node within this time.
# NEVER applied in the :test env: config/test.exs pins 0 (ExUnit stays read-through) and runtime.exs would
# otherwise override it with the default.
if config_env() != :test do
  config :nebu_http,
    oauth_config_cache_ms: Nebu.OAuth.Config.parse_cache_ms(System.get_env("NEBU_OAUTH_CONFIG_CACHE_MS"))
end

# ─── oauth-client-revocation (SO5): admin re-authentication without `auth_time` ──────────────────
# Approving / revoking an OAuth client needs a FRESH admin sign-in (`/admin/login/start?mode=reauth`). An IdP
# that reports no `auth_time` cannot prove it, so the default is fail closed. Set the variable to exactly `true`
# ONLY where the IdP has no SSO session, so a completed login flow IS an interactive login (the dev Dex of
# docker-compose.yml). It is an accepted risk, never set in the deploy templates (docs/architecture/07-deployment.md).
config :nebu_http, [{:admin_reauth_allow_missing_auth_time, System.get_env("NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME") == "true"}]

# ─── e2e-session-refresh-suites: configurable Nebu session TTL ceilings ───────
# Defaults (8h) live in Nebu.Web.SessionConfig. NEBU_MATRIX_SESSION_TTL_SECONDS /
# NEBU_ADMIN_SESSION_TTL_SECONDS let the e2e stack shorten the opaque-AT (login +
# /v3/refresh) and admin-session ceilings so the silent-refresh loop fires within a
# test window. SessionConfig.parse_ttl/1 is defensive: only a strictly positive
# integer is applied; unset / junk / <= 0 leaves the 8h default untouched. Never
# raises — must not break the login path.
for {env_name, cfg_key} <- [
      {"NEBU_MATRIX_SESSION_TTL_SECONDS", :matrix_session_ttl_seconds},
      {"NEBU_ADMIN_SESSION_TTL_SECONDS", :admin_session_ttl_seconds}
    ] do
  case Nebu.Web.SessionConfig.parse_ttl(System.get_env(env_name)) do
    {:ok, seconds} -> config :nebu_http, [{cfg_key, seconds}]
    :invalid -> :ok
  end
end

# ─── server-paced-session-refresh: background refresh worker knobs ───────────
# NEBU_MATRIX_REFRESH_WORKER_INTERVAL_MS / NEBU_MATRIX_REFRESH_WORKER_LOOKAHEAD_SECONDS
# let operators tune Nebu.Matrix.Session.RefreshWorker's cycle cadence and how far
# ahead of a session's expires_at it proactively redeems the stored upstream OIDC
# refresh token. Same defensive parsing precedent as the TTL vars above (via the
# same generic parse_ttl/1 — any strictly positive integer string); unset / junk /
# <= 0 leaves the worker's compiled-in defaults (5 min / 1h) untouched. Never
# raises — must not break application boot.
for {env_name, cfg_key} <- [
      {"NEBU_MATRIX_REFRESH_WORKER_INTERVAL_MS", :matrix_refresh_worker_interval_ms},
      {"NEBU_MATRIX_REFRESH_WORKER_LOOKAHEAD_SECONDS", :matrix_refresh_worker_lookahead_seconds}
    ] do
  case Nebu.Web.SessionConfig.parse_ttl(System.get_env(env_name)) do
    {:ok, value} -> config :nebu_http, [{cfg_key, value}]
    :invalid -> :ok
  end
end

# ─── oidc-bootstrap-only-config (ADR-022): OIDC config is bootstrap-only ──────
# OIDC is configured EXCLUSIVELY through the Bootstrap Wizard (server_config), read
# at runtime via the DB-backed Nebu.Web.OidcConfig cache. There are NO NEBU_OIDC_* /
# NEBU_ADMIN_OIDC_* configuration variables — issuer, audience, JWKS URI, and the
# single OIDC client (id/secret) all come from server_config. The server BOOTS
# without OIDC config; OidcPlug/SsoLogin/Admin.Auth validate per-operation and fail
# closed (all Bearer tokens 401, admin → /bootstrap) until the wizard completes.
#
# Only non-config presentation/operational knobs remain here:
#   - NEBU_OIDC_DISPLAY_NAME — advertised IdP label for GET /v3/login (m.login.sso)
#   - NEBU_OIDC_JWKS_TTL — JwksCache refresh interval (read in Nebu.Web.JwksCache)
#
# story fix-and-configure-sso-redirect-schemes (AC3): NEBU_SSO_REDIRECT_SCHEMES has
# been REMOVED. Additional client-facing SSO redirect schemes (beyond the hardcoded
# defaults element/schildichat/im.fluffychat.auth) are now bootstrap-only, configured
# via the Admin UI (/admin/config) and read through Nebu.Web.OidcConfig's cache
# (server_config.sso_extra_redirect_schemes) — no env var config path, consistent
# with ADR-022.
if config_env() in [:prod, :dev] do
  config :nebu_http,
    server_name: System.get_env("NEBU_SERVER_NAME", "localhost"),
    # Advertised IdP display name for GET /_matrix/client/v3/login (m.login.sso).
    oidc_display_name: System.get_env("NEBU_OIDC_DISPLAY_NAME", "SSO"),
    start_jwks_cache: true

  # ── device-management S3: UIA fresh-auth window (Option B) ──────────────────
  # Device delete (DELETE /devices/{id}, POST /delete_devices) is UIA-gated: a login
  # within this many seconds satisfies it; otherwise the caller is challenged for a
  # fresh m.login.sso. Default 900s (15 min). Only a strictly-positive integer is
  # applied; junk/<=0 leaves the Nebu.Matrix.Uia default untouched.
  case Integer.parse(System.get_env("NEBU_UIA_FRESH_AUTH_SECONDS", "")) do
    {seconds, ""} when seconds > 0 -> config :nebu_http, uia_fresh_auth_seconds: seconds
    _ -> :ok
  end

  # ── room-account-data-and-read-markers: abuse limits ────────────────────────
  # NEBU_ROOM_ACCOUNT_DATA_MAX_ROWS_PER_USER: max (room, type) rows one user may store
  # (default 1000 in Nebu.Matrix.RoomAccountDataStore). NEBU_ROOM_ACCOUNT_DATA_MAX_BYTES:
  # max size of one content body (default 65536). NEBU_ROOM_ACCOUNT_DATA_MAX_TOTAL_BYTES:
  # max total content bytes per user (default 4194304). Only strictly-positive integers
  # within the 64-bit signed range apply; anything else keeps the default (never crashes).
  for {env, key} <- [
        {"NEBU_ROOM_ACCOUNT_DATA_MAX_ROWS_PER_USER", :room_account_data_max_rows_per_user},
        {"NEBU_ROOM_ACCOUNT_DATA_MAX_BYTES", :room_account_data_max_bytes},
        {"NEBU_ROOM_ACCOUNT_DATA_MAX_TOTAL_BYTES", :room_account_data_max_total_bytes}
      ] do
    case Integer.parse(System.get_env(env, "")) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> config :nebu, [{key, n}]
      _ -> :ok
    end
  end

  # ── rate-limits-join-invite-create-room: per-user tiers and pending-invitation caps ──
  # The per-user rate-limit tiers of POST /createRoom, POST /rooms/{roomId}/invite, POST /join and (story
  # moderation-routes-atomic-ban) POST /rooms/{roomId}/kick | ban | unban, (story membership-state-model) GET
  # /rooms/{roomId}/members | initialSync (rate per minute and burst each) and the three caps on
  # PENDING invitations (per inviter, per invitee, per inviter-invitee pair). Same rule as above: only a strictly positive int64
  # integer applies, anything else keeps the default (never crashes). Nebu.Web.RateLimitTiers
  # additionally rejects a pair whose burst / rate exceeds 60 (the sweeper's one-hour argument) or an invite burst below 50, falls
  # back to the default pair and warns at boot (variable names only). The tiers are per node (ETS); the caps are cluster-wide.
  for {env, app, key} <- [
        {"NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN", :nebu_http, :rate_limit_create_room_per_min},
        {"NEBU_RATE_LIMIT_CREATE_ROOM_BURST", :nebu_http, :rate_limit_create_room_burst},
        {"NEBU_RATE_LIMIT_INVITE_PER_MIN", :nebu_http, :rate_limit_invite_per_min},
        {"NEBU_RATE_LIMIT_INVITE_BURST", :nebu_http, :rate_limit_invite_burst},
        {"NEBU_RATE_LIMIT_JOIN_PER_MIN", :nebu_http, :rate_limit_join_per_min},
        {"NEBU_RATE_LIMIT_JOIN_BURST", :nebu_http, :rate_limit_join_burst},
        {"NEBU_RATE_LIMIT_MODERATION_PER_MIN", :nebu_http, :rate_limit_moderation_per_min},
        {"NEBU_RATE_LIMIT_MODERATION_BURST", :nebu_http, :rate_limit_moderation_burst},
        {"NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN", :nebu_http, :rate_limit_members_read_per_min},
        {"NEBU_RATE_LIMIT_MEMBERS_READ_BURST", :nebu_http, :rate_limit_members_read_burst},
        {"NEBU_INVITE_MAX_PENDING_PER_INVITER", :nebu, :invite_max_pending_per_inviter},
        {"NEBU_INVITE_MAX_PENDING_PER_INVITEE", :nebu, :invite_max_pending_per_invitee},
        {"NEBU_INVITE_MAX_PENDING_PER_PAIR", :nebu, :invite_max_pending_per_pair},
        # story membership-state-model (D19): the node-wide limit of concurrent member-state reads (default 3, Nebu.Matrix.MemberSliceGate;
        # an invalid value is ignored and warned at boot, the variable name only)
        {"NEBU_MEMBER_SLICE_MAX_CONCURRENCY", :nebu, :member_slice_max_concurrency}
      ] do
    case Integer.parse(System.get_env(env, "")) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> config app, [{key, n}]
      _ -> :ok
    end
  end
end

# ─── media-gateway-migration: S3/MinIO storage for the Elixir media gateway ──
# Nebu.Media.Storage uses ExAws.S3 against MinIO or a real S3 endpoint. The NEBU_MINIO_*
# vars below are the boot-time default target (there is no NEBU_STORAGE_BACKEND switch);
# a target saved under /admin/media/settings takes precedence and is resolved per request
# by Nebu.Media.StorageConfig, so it needs no restart.
# Credentials are file-based Docker Secrets (read the file
# path envs, mirroring what the removed Go `media:` service consumed). Only wired
# in prod/dev — unit tests inject a fake storage boundary and never touch ExAws.
if config_env() in [:prod, :dev] do
  minio_access_key =
    case System.get_env("NEBU_MINIO_ACCESS_KEY_FILE") do
      nil -> System.get_env("NEBU_MINIO_ACCESS_KEY", "")
      path -> path |> File.read!() |> String.trim()
    end

  minio_secret_key =
    case System.get_env("NEBU_MINIO_SECRET_KEY_FILE") do
      nil -> System.get_env("NEBU_MINIO_SECRET_KEY", "")
      path -> path |> File.read!() |> String.trim()
    end

  # Unset keeps the default. Set but empty (or only whitespace) is a misconfiguration that would otherwise boot with a
  # host-less endpoint and fail every media operation: abort the boot instead.
  minio_endpoint =
    case System.get_env("NEBU_MINIO_ENDPOINT") do
      nil ->
        "minio:9000"

      value ->
        case String.trim(value) do
          "" -> raise "NEBU_MINIO_ENDPOINT is set but empty; set host[:port] or leave it unset (default minio:9000)"
          endpoint -> endpoint
        end
    end

  use_ssl? = System.get_env("NEBU_MINIO_USE_SSL", "false") == "true"

  {host, port} =
    case String.split(minio_endpoint, ":", parts: 2) do
      [h, p] -> {h, String.to_integer(p)}
      [h] -> {h, if(use_ssl?, do: 443, else: 80)}
    end

  # Nothing in lib/ reads this key any more: Nebu.Media.Storage takes the bucket from
  # Nebu.Media.StorageConfig.request_target/0 (saved > NEBU_MINIO_BUCKET > "nebu-media"). Kept for the boot-time
  # config contract (runtime_storage_endpoint_test); do not wire a new consumer to it, resolve through StorageConfig.
  config :nebu_http, media_bucket: System.get_env("NEBU_MINIO_BUCKET", "nebu-media")

  # media-security-admin-control/8c-media-archive-worker (AC1): the boot-time
  # archive-bucket name, the fallback Nebu.Media.Storage.archive_bucket/0 uses
  # when no archive bucket is saved under /admin/media/settings. Same MinIO/S3
  # connection as the primary bucket, just a different bucket name.
  config :nebu_http,
    media_archive_bucket: System.get_env("NEBU_MINIO_ARCHIVE_BUCKET", "nebu-media-archive")

  # bugfix-upcloud-s3-iam-sts-endpoints (AC2): UpCloud Managed Object Storage
  # exposes separate IAM/STS endpoint URLs alongside the public S3 endpoint
  # (NEBU_MINIO_ENDPOINT above) — plumbed through as-is (no default, nil when
  # unset) so the S3 driver config carries them for providers that need them.
  # Unrelated/unused by MinIO and other S3-compatible backends that don't set
  # these vars. Mirrors Nebu.Media.StorageConfig's own env resolution of the
  # same two vars (AC1). An empty string (e.g. cloud-init's s3_iam_endpoint/
  # s3_sts_endpoint locals falling back to "" when the provider's endpoint
  # list has no matching entry) is treated the same as unset — normalized to
  # nil rather than leaking a set-but-empty value.
  normalize_optional_env = fn
    nil -> nil
    "" -> nil
    value -> value
  end

  # code review (bugfix-add-sts-iam-endpoints-to-admin-ui, cycle 2, N2-MINOR-3):
  # these two app-env keys are NOT admin-DB-override-aware and have ZERO
  # readers anywhere in the codebase (verified by grep) — a stale, divergent
  # second source of truth now that Nebu.Media.StorageConfig resolves these
  # same two values with its own DB > env > default precedence (including any
  # admin-UI override). Any future code that needs the resolved iam/sts
  # endpoint MUST call Nebu.Media.StorageConfig.get_for_connection/0 instead
  # of reading these Application.get_env keys directly — do not wire a new
  # consumer to them.
  config :nebu_http,
    media_iam_endpoint: normalize_optional_env.(System.get_env("NEBU_MINIO_IAM_ENDPOINT")),
    media_sts_endpoint: normalize_optional_env.(System.get_env("NEBU_MINIO_STS_ENDPOINT"))

  # Opt-in: let the admin-configured storage endpoints (endpoint/iam_endpoint/
  # sts_endpoint) resolve to private addresses (RFC1918, CGNAT, IPv6 ULA).
  # Required for UpCloud's `*-private.upcloudobjects.com` endpoints, which
  # resolve to 100.64.0.0/10. Loopback/link-local/metadata stay blocked, and
  # preview_url/webhooks are never affected. Default: strict (false).
  config :nebu_http,
    media_storage_allow_private_endpoints:
      System.get_env("NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS", "false") == "true"

  # Baseline ExAws config only: Nebu.Media.Storage overrides host/scheme/port/region/credentials per request with the
  # resolved target (saved > these env values > defaults), so a saved target never has to be written back here.
  config :ex_aws,
    access_key_id: minio_access_key,
    secret_access_key: minio_secret_key,
    region: System.get_env("NEBU_S3_REGION", "us-east-1")

  config :ex_aws, :s3,
    scheme: if(use_ssl?, do: "https://", else: "http://"),
    host: host,
    port: port,
    # MinIO requires path-style addressing (bucket in the path, not the host).
    region: System.get_env("NEBU_S3_REGION", "us-east-1")
end

# ─── media-security-admin-control/3-clamav-genserver: ClamAV scanner client ──
# Nebu.Media.ClamAV connects to a clamd daemon over TCP (INSTREAM protocol).
# NEBU_CLAMAV_HOST/NEBU_CLAMAV_PORT let operators point at a real clamd;
# defaults match the dev-stack's Docker Compose service name ("clamav" on the
# default network, port 3310) — the same "env var defaults to the compose
# service name" pattern used for NEBU_MINIO_ENDPOINT above. Only wired in
# prod/dev — unit tests configure Nebu.Media.ClamAV directly (per-test, via
# Application.put_env) against a fake clamd and never touch this block
# (config/test.exs also disables the Application-supervised instance,
# start_clamav_client: false).
if config_env() in [:prod, :dev] do
  clamav_host = System.get_env("NEBU_CLAMAV_HOST", "clamav")
  clamav_port = String.to_integer(System.get_env("NEBU_CLAMAV_PORT", "3310"))

  config :nebu, Nebu.Media.ClamAV, address: {:tcp, clamav_host, clamav_port}
end

# Placeholder — NEBU_* env vars added as each story requires them
# e.g., Story 1.3 adds database URL:
# config :room_manager, Nebu.Repo,
#   url: System.get_env("NEBU_DB_URL") || raise "NEBU_DB_URL not set"

# Room IDs use this server name — must match the gateway's NEBU_SERVER_NAME.
config :event_dispatcher, server_name: System.get_env("NEBU_SERVER_NAME", "localhost")

if config_env() in [:prod, :dev] do
  db_url = System.get_env("NEBU_DB_URL") || raise("NEBU_DB_URL is not set")

  ssl_opts =
    if System.get_env("NEBU_POSTGRES_SSL", "false") == "true" do
      case System.get_env("NEBU_POSTGRES_CA_CERT_FILE") do
        nil ->
          [verify: :verify_none]

        path ->
          db_host = URI.parse(db_url).host || "localhost"

          [
            verify: :verify_peer,
            cacertfile: to_charlist(path),
            server_name_indication: to_charlist(db_host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
      end
    else
      false
    end

  config :nebu, Nebu.Repo,
    url: db_url,
    pool_size: 10,
    ssl: ssl_opts,
    # enhanced-logging/matrix-payload-debug-logging: disable Ecto's own query
    # logger (which prints bound SQL parameter values verbatim at :debug,
    # including credentials) — see config/config.exs for the full rationale.
    # Set here (merged into the existing NEBU_DB_URL-gated config call) rather
    # than unconditionally in config.exs, so `Nebu.Application.repo_children/0`'s
    # `Application.get_env(:nebu, Nebu.Repo)` presence check still correctly
    # returns nil when no DB is configured (plain unit runs).
    log: false
end

# ── admin-ui-migration: Phoenix LiveView Admin UI endpoint (runtime secret) ───
# The AdminEndpoint runs with server: false (forwarded by Nebu.Web.Router into the
# shared Bandit listener), but it still needs a secret_key_base to sign the session
# cookie + the LiveView socket token. Derive it from NEBU_ADMIN_SECRET_KEY_BASE when
# set, else fall back to the shared internal secret file (already mounted for node
# registration), else — only outside prod — a random key. A short/empty key is
# rejected so a misconfigured prod node fails fast at boot rather than signing with a
# weak key.
if config_env() in [:prod, :dev] do
  admin_secret_key_base =
    cond do
      v = System.get_env("NEBU_ADMIN_SECRET_KEY_BASE") ->
        v

      path = System.get_env("NEBU_INTERNAL_SECRET_FILE") ->
        # Stretch the (possibly short) internal secret to >= 64 bytes via SHA-512 hex
        # so Plug.Session's key-derivation has enough entropy.
        path
        |> File.read!()
        |> String.trim()
        |> then(&:crypto.hash(:sha512, &1))
        |> Base.encode16()

      config_env() == :dev ->
        Base.encode16(:crypto.strong_rand_bytes(48))

      true ->
        raise "NEBU_ADMIN_SECRET_KEY_BASE (or NEBU_INTERNAL_SECRET_FILE) must be set in prod"
    end

  config :nebu, Nebu.Admin.Endpoint,
    secret_key_base: admin_secret_key_base,
    # Overrides compile-time default ("localhost") so Phoenix accepts LiveView socket
    # connections from the configured public hostname (origin check uses url[:host]).
    url: [host: System.get_env("NEBU_SERVER_NAME", "localhost")]

  # oidc-bootstrap-only-config (ADR-022): the admin OIDC operator login uses the
  # SINGLE wizard-configured client (server_config.oidc_client_id/secret) — the same
  # client that validates Matrix Bearer tokens. There is no separate admin OIDC client
  # and no NEBU_ADMIN_OIDC_* config. The /admin/callback redirect_uri is derived at
  # runtime by Nebu.Admin.Auth.redirect_uri/0 from :server_name + :admin_session_secure
  # (server-controlled, never from request headers) and is registered on the one client.

  # Admin session cookie `secure` flag (Nebu.Admin.Endpoint). Defaults to true
  # (TLS-only, fail-closed). Set NEBU_ADMIN_SESSION_SECURE=false ONLY for a local
  # dev stack served over plain http://localhost (otherwise the login-state cookie
  # is not sent on the OIDC callback on stricter browsers → "Invalid login state").
  config :nebu_http,
    admin_session_secure: System.get_env("NEBU_ADMIN_SESSION_SECURE", "true") != "false"
end

# ─── Integration tests (matrix-api-migration AC1/AC2) ────────────────────────
# The Matrix HTTP router and the gRPC server delegate to OTP modules that hit
# Nebu.Repo directly (rooms, events, profiles, receipts). The :integration-tagged
# ExUnit tests drive the router in-process, so Nebu.Repo MUST be started in the
# test BEAM. `make test-integration-elixir` sets NEBU_DB_URL and runs against the
# live Compose PostgreSQL. Configure the Repo (and the OIDC/server-name params the
# router reads) in :test ONLY when NEBU_DB_URL is present — plain unit runs (no
# NEBU_DB_URL) still start zero DB children, exactly as before.
if config_env() == :test do
  if db_url = System.get_env("NEBU_DB_URL") do
    # log: false — see the prod/dev block above and config/config.exs for the
    # full rationale (Ecto's default query logger leaks bound credential
    # params at :debug; kept co-located with the real DB config so the
    # NEBU_DB_URL-presence invariant in Nebu.Application.repo_children/0 holds).
    config :nebu, Nebu.Repo, url: db_url, pool_size: 10, log: false

    server_name = System.get_env("NEBU_SERVER_NAME", "test.local")
    config :event_dispatcher, server_name: server_name
    config :nebu_http, server_name: server_name
  end
end

# ─── Story 13-6: libcluster — server node clustering ────────────────────────
# Only active in prod/dev environments (Docker Compose + Kubernetes).
# In test, clustering is not started to avoid EPMD noise in unit tests.
#
# Strategy selection via CLUSTER_STRATEGY env var:
#   "gossip"     — Cluster.Strategy.Gossip (UDP multicast, Docker Compose default)
#   "kubernetes" — Cluster.Strategy.Kubernetes.DNS (Helm / K8s default)
#   anything else / unset — no libcluster started
#
# CLUSTER_NODES (comma-separated) is used by the Epmd strategy for explicit
# peer lists when gossip multicast is unavailable. In Docker Compose the
# RELEASE_NODE env var sets the Erlang node name (e.g. "nebu@server").
if config_env() in [:prod, :dev] do
  cluster_strategy = System.get_env("CLUSTER_STRATEGY", "")

  libcluster_topologies =
    case cluster_strategy do
      "gossip" ->
        [
          nebu: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: 45892,
              if_addr: "0.0.0.0",
              multicast_addr: "255.255.255.255",
              broadcast_only: true
            ]
          ]
        ]

      "kubernetes" ->
        k8s_namespace = System.get_env("KUBERNETES_NAMESPACE", "default")
        k8s_selector = System.get_env("KUBERNETES_SELECTOR", "app.kubernetes.io/name=nebu-server")

        [
          nebu: [
            strategy: Cluster.Strategy.Kubernetes.DNS,
            config: [
              service: System.get_env("KUBERNETES_SERVICE_NAME", "nebu-server-headless"),
              application_name: "nebu",
              namespace: k8s_namespace,
              polling_interval: 10_000,
              kubernetes_selector: k8s_selector
            ]
          ]
        ]

      _ ->
        # No clustering — single-node mode (default when CLUSTER_STRATEGY is not set)
        []
    end

  if libcluster_topologies != [] do
    config :libcluster, topologies: libcluster_topologies
  end
end

if config_env() in [:prod, :dev] do
  pii_key_hex =
    System.get_env("NEBU_PII_ENCRYPTION_KEY") ||
      raise "NEBU_PII_ENCRYPTION_KEY is not set. Must be a 64-char hex string (32 bytes)."

  pii_key =
    case Base.decode16(pii_key_hex, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> raise "NEBU_PII_ENCRYPTION_KEY is not valid hex. Must be a 64-char hex string."
    end

  unless byte_size(pii_key) == 32 do
    raise "NEBU_PII_ENCRYPTION_KEY must decode to exactly 32 bytes, got #{byte_size(pii_key)}"
  end

  config :signature, pii_encryption_key: pii_key
end
