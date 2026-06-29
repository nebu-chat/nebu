import Config

if config_env() != :test do
  config :nebu_http, port: String.to_integer(System.get_env("NEBU_HTTP_PORT", "4000"))
end

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
#   - NEBU_SSO_REDIRECT_SCHEMES — allowed non-http client redirect schemes
#   - NEBU_OIDC_JWKS_TTL — JwksCache refresh interval (read in Nebu.Web.JwksCache)
if config_env() in [:prod, :dev] do
  config :nebu_http,
    server_name: System.get_env("NEBU_SERVER_NAME", "localhost"),
    # Advertised IdP display name for GET /_matrix/client/v3/login (m.login.sso).
    oidc_display_name: System.get_env("NEBU_OIDC_DISPLAY_NAME", "SSO"),
    sso_redirect_schemes: System.get_env("NEBU_SSO_REDIRECT_SCHEMES", ""),
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
end

# ─── media-gateway-migration: S3/MinIO storage for the Elixir media gateway ──
# Nebu.Media.Storage uses ExAws.S3 against MinIO or a real S3 endpoint, selected
# entirely by the NEBU_MINIO_* vars below (there is no NEBU_STORAGE_BACKEND switch).
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

  minio_endpoint = System.get_env("NEBU_MINIO_ENDPOINT", "minio:9000")
  use_ssl? = System.get_env("NEBU_MINIO_USE_SSL", "false") == "true"
  {host, port} =
    case String.split(minio_endpoint, ":", parts: 2) do
      [h, p] -> {h, String.to_integer(p)}
      [h] -> {h, if(use_ssl?, do: 443, else: 80)}
    end

  config :nebu_http, media_bucket: System.get_env("NEBU_MINIO_BUCKET", "nebu-media")

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
    ssl: ssl_opts
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
        path |> File.read!() |> String.trim() |> then(&:crypto.hash(:sha512, &1)) |> Base.encode16()

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
    config :nebu, Nebu.Repo, url: db_url, pool_size: 10

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
