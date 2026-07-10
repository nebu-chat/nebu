# 5 Building Block View

## Level 1 - Top-Level Decomposition

```
nebu/
│                     (gateway/ and media/ deleted — ADR-021: the full stack is one Elixir app)
├── server/           ← Single Elixir/OTP application (Mix app :nebu, Nebu.Application, one
│                       supervisor tree — NOT an umbrella, ADR-019). Serves the Matrix C-S API,
│                       Matrix media API, the Admin UI + admin OIDC login, and runs DB migrations
│                       (Nebu.Release.migrate/0, raw SQL — ADR-018). Domains as module namespaces
│                       (ADR-020): Nebu.Matrix, Nebu.Media, Nebu.Admin, Nebu.Web, Nebu.Compliance.
├── proto/            ← (historical) .proto definitions — removed in grpc-removal epic (ADR-021, 2026-06-22)
└── docs/             ← Architecture docs (this file)
```

> **One app, five namespaces (ADR-019/020/021):** There is no umbrella project and no Go layer. The
> HTTP surface and all stateful logic run in the same BEAM node. The legacy gRPC boundary is gone;
> the HTTP routers call domain functions in-process.

## Level 2 - Single Elixir/OTP Application Internal Structure

The whole system is one Mix app under `server/lib/nebu/`, supervised by `Nebu.Application`. The HTTP
surface (Matrix C-S API, media, Admin UI) and all stateful chat logic run in the same BEAM node;
the HTTP layer dispatches to domain functions in-process (no gRPC network hop). Domains are module
namespaces (ADR-020), not separate apps.

```
server/lib/nebu/
├── application.ex    ← Nebu.Application: the single supervisor tree (Bandit listener, Phoenix
│                       PubSub + Admin endpoint, JWKS cache GenServer, Finch pool, Horde
│                       DynamicSupervisor/Registry, Session/Presence managers, eager request-time
│                       ETS tables: token denylist + rate-limit buckets)
├── repo.ex           ← Nebu.Repo (Ecto connection pool ONLY — no schemas, no Repository layer, ADR-018)
│   └── query_telemetry.ex ← QueryTelemetry (telemetry handler attached at boot; logs sanitized
│                   query summary at DEBUG — source + duration_ms only, never raw SQL or bound
│                   parameters; replaces Ecto's default query logger which leaks credentials)
├── release.ex        ← Nebu.Release.migrate/0 — applies raw-SQL migrations before the app boots (ADR-018)
├── node_registration.ex ← Nebu.NodeRegistration — PSK-based cluster node registration (ADR-008)
├── health/           ← Nebu.Health.* — /health (incl. cluster_nodes) and /info endpoints
│
├── web/              ← Nebu.Web.* — shared HTTP plumbing for the single Bandit listener
│   ├── router.ex     ← top router (Plug.Router): GET /health open; unauthenticated Matrix routes
│   │                   (POST /login, GET profile, MSC2965 discovery) forwarded to the public router;
│   │                   everything else under /_matrix runs the OIDC pipeline; forwards /admin to the
│   │                   Phoenix Admin endpoint; before_send sets X-Content-Type-Options: nosniff on
│   │                   EVERY response
│   ├── oidc_config.ex ← Nebu.Web.OidcConfig — GenServer + ETS cache for OIDC issuer, audience,
│   │                   JWKS URI, and (since fix-and-configure-sso-redirect-schemes) the Admin-UI
│   │                   -managed sso_extra_redirect_schemes string, all resolved from server_config.
│   │                   Per-request DB lookups on hot paths (OIDC + SSO redirectUrl validation) are
│   │                   unacceptable, so values are cached in :nebu_http_oidc_config ETS table.
│   │                   Cluster-aware via :pg broadcast on refresh (ADR-020), triggered by both the
│   │                   Bootstrap Wizard and Nebu.Admin.DB.upsert_server_config/1 (Admin UI edits).
│   │                   Used by OidcPlug (issuer/audience), JwksCache (JWKS URI), and SsoLogin
│   │                   (extra redirect schemes for the redirectUrl allowlist).
│   ├── jwks_cache.ex ← Nebu.Web.JwksCache — GenServer fetching OIDC provider JWKS on start + TTL
│   │                   refresh (NEBU_OIDC_JWKS_TTL, default 300s). JWKS URI resolved from
│   │                   NEBU_OIDC_JWKS_URI env var OR OidcConfig cache (fallback for bootstrap
│   │                   mode). Keeps last-known-good keys on refresh failure; volatile, recovered
│   │                   by re-fetch on supervisor restart.
│   ├── token_denylist.ex ← Nebu.Web.TokenDenylist — ETS denylist of revoked access tokens; POST
│   │                   /logout records the presented token; the OIDC plug consults it AFTER crypto
│   │                   verification; keyed by JWT jti else SHA-256(raw token); entries self-expire
│   │                   at the token exp; volatile (Postgres-backed persistence is follow-up hardening)
│   ├── oidc_claims.ex ← Nebu.Web.OidcClaims — pure, stateless recursive OIDC-claims-map walker;
│   │                   claim_value_matches?/2 (arbitrary-depth value search) and
│   │                   flatten_discovered_claims/2 (claims → dot-path {key, value} pairs, e.g.
│   │                   Keycloak-shaped realm_access.roles). Centralized here (from two independent
│   │                   private implementations in Nebu.Admin.Auth) so the admin-group-claim gate
│   │                   and the Bootstrap Wizard's claim-picker share one walker instead of two that
│   │                   could drift apart. Trust-boundary rationale (no depth guard — signed,
│   │                   verified IdP token is the boundary) travels with the code as a comment.
│   └── plugs/        ← OidcPlug (Bearer validation: alg allowlist RS*/ES*/PS*, JWKS kid select,
│                       Assent/JOSE verify of sig+exp+iss+aud+sub, issuer/audience from env var
│                       OR OidcConfig cache, denylist check, idempotent TTL-cached user
│                       provisioning), RateLimit (per-IP token bucket: /login 30/min burst 10,
│                       /sync 600/min burst 100; NEBU_RATE_LIMIT_DISABLED no-op), RequestId,
│                       RequestLogger (logs all requests at INFO + optionally at DEBUG with
│                       request/response bodies, redacted via PayloadRedactor to strip
│                       credentials and message content; propagates request_id + route_template
│                       via Logger.metadata/1 so downstream Logger.* calls inherit them; since
│                       war-room-mode, also propagates user_id/device_id — via extract_user_id/1,
│                       which reduces conn.assigns.current_user to a bare identifier string
│                       regardless of route shape [Matrix routes: plain string; /admin/* routes:
│                       Nebu.Admin.Auth's current_user map → matrix_user_id/sub only, NEVER email
│                       or the raw map] — a security-review-driven fix after code-review found the
│                       raw-assign version leaked admin emails into operational_logs metadata on
│                       admin routes, since this same plug also serves /admin/*),
│                       CORS, JSON body, security headers
│   │
│   ├── request_logger/ ← PayloadRedactor (pure, recursive two-category redaction: credentials
│   │                   like password/access_token/Authorization → ***REDACTED***; message
│   │                   content like event body/topic/name → ***MESSAGE_CONTENT***)
│   ├── log_store/      ← LogStore (operational log store — persistent, mutable, admin-configurable
│   │                   diagnostic log capture; separate from compliance audit logs, ADR-018 inline SQL):
│   │   ├── handler.ex  — central Erlang :logger handler (attached at boot, non-blocking) that
│   │                     broadcasts ALL Logger.* calls via Phoenix.PubSub to "operational_logs" topic
│   │                     (feeds live views), conditionally persists via GenServer.cast to Writer.
│   │                     Since war-room-mode: calls WarRoom.check/1 BEFORE the should_persist? gate —
│   │                     if a matching war room session tags the entry, it persists via Writer
│   │                     REGARDLESS of the ambient WARN/ERROR-only policy (the override lives here,
│   │                     not in Writer's batch-flush path — see 08-concepts.md)
│   │   ├── writer.ex   — batching GenServer (flushes every 5s or ≥100 entries) that serializes
│   │                     INSERTs to operational_logs table; per-row fallback on batch-INSERT failure;
│   │                     supervised :permanent child of Nebu.Application. Since war-room-mode,
│   │                     @columns/row_values also carry the entry's war_room_id (tagged upstream by
│   │                     Handler/WarRoom, not derived here — this module never decides tagging itself)
│   │   ├── war_room.ex — Nebu.Web.LogStore.WarRoom (new, war-room-mode): GenServer holding the single
│   │   │                 cached active session (or none — a persistent_term boolean fast-paths the
│   │   │                 common "no war room active" case so Handler.log/2's hot path never blocks on
│   │   │                 this when inactive). check/1 synchronously scope/filter-matches one log entry
│   │   │                 against the cached session and, on match, atomically increments
│   │   │                 entries_collected via a single `UPDATE ... SET entries_collected = +1[, ended_at
│   │   │                 = now(), ended_reason = 'budget_exhausted']` — serialized through this one
│   │   │                 process, so there is no read-then-write race and single-entry-granularity
│   │   │                 budget enforcement holds exactly (never overshoots max_entries). Schedules its
│   │   │                 own duration-timeout message on session load; boot-time load
│   │   │                 (do_load_active/1) immediately ends an already-past-deadline session (a
│   │   │                 restarted node cannot "forget" to end an expired session); supervisor
│   │   │                 crash-restart re-loads the same state from war_room_sessions. Deliberately NOT
│   │   │                 folded into Writer's batching (Writer flushes every 5s/100 entries — too
│   │   │                 coarse for AC4's single-entry budget/override semantics)
│   │   ├── retention.ex — TTL + max-count pruning (INFO/DEBUG per server_config policy, INFO now
│   │                     symmetric with DEBUG's max-count cap since admin-logs-retention-settings;
│   │                     WARN/ERROR always persist, no admin-configurable cap, but gained a
│   │                     hardcoded, non-configurable 90-day safety-net TTL in that same story —
│   │                     closing a previously-flagged unbounded-growth gap), wired into
│   │                     Nebu.Matrix.Session.Sweeper's hourly sweep cycle
│   │   ├── route_normalizer.ex — position-based Matrix path-segment normalization (room/user/event
│   │                     IDs → placeholders, e.g. "/rooms/:room_id/send/:event_type/:txn_id") before
│   │                     persisting route_template, replacing fragile regex ID-shape detection
│   │   ├── policy_cache.ex — persistent_term-backed cache of server_config log-policy keys
│   │                     (log_collect_info/debug, log_retention_*_days/debug_max_count, and — since
│   │                     admin-logs-retention-settings — log_retention_info_max_count, 6 keys total),
│   │                     refreshed periodically + on config write, added to avoid Nebu.Repo
│   │                     connection-pool re-entrancy (handler runs sync inside QueryTelemetry's
│   │                     telemetry callback)
│   │   └── capture_cache.ex — persistent_term-backed cache of admin_temporary_captures table (new,
│   │                     trace-map-node-controls): holds a map of {endpoint → {enabled_at, expires_at}}
│   │                     for fast lookup in should_persist?/2's temporary-capture enforcement. 2s polling
│   │                     interval + on-demand refresh on capture enable/disable events (PubSub broadcast).
│   │                     Cluster-aware via :pg invalidation, mirroring PolicyCache pattern
│   ├── log_store.ex    ← Nebu.Web.LogStore — public API: attach_handler/0 (registration),
│   │                   get_policy/0, get_logs/1 (minimal read layer for tests + Admin UI; since
│   │                   war-room-mode, get_logs/1's @allowed_filter_keys also accepts war_room_id,
│   │                   with UUID-binary/string normalization for Postgrex's native uuid type)
│
├── matrix/           ← Nebu.Matrix.* — Matrix C-S API surface + all stateful chat logic
│   ├── http/         ← Nebu.Matrix.Http* — Matrix endpoint handlers: login, logout, sync (long-poll,
│   │                   per-device since tokens, forgotten-rooms exclusion, global account_data,
│   │                   bundled m.relations), send, createRoom/join, /forget, profile, presence,
│   │                   /search, single-event fetch, /relations (all variants), MSC2965 OIDC discovery,
│   │                   typing, receipts, messages, keys, device management (PUT/DELETE /devices/{id},
│   │                   POST /delete_devices — UIA-gated; GET /auth/m.login.sso/fallback/web)
│   ├── uia.ex        ← Nebu.Matrix.Uia — User-Interactive-Authentication gate for sensitive device
│   │                   writes; single `m.login.sso` stage, Option B fresh-auth window
│   │                   (NEBU_UIA_FRESH_AUTH_SECONDS, default 900s); DB-backed single-use `uia_sessions`
│   │                   bound to (user_id, op, params) — cluster-correct (ADR-020), Story s3
│   ├── device_id.ex ← Nebu.Matrix.DeviceId — device_id ingress validation (≤255 bytes, no control
│   │                   chars) at POST /login + POST /keys/upload (Story s3, F-2)
│   ├── room/         ← Horde.DynamicSupervisor + Room GenServer (state, history, power levels);
│   │                   inline-SQL DB module: events, relations (fetch_events_by_relation/5,
│   │                   count_thread_children/2, event_in_room?/2, fetch_event/2)
│   ├── session/      ← ETS + PostgreSQL hybrid since-token manager (per-device, composite
│   │                   (user_id, device_id) key); BulkImporter (admin bulk OIDC provisioning, same
│   │                   flow as first-login provisioning); DeviceBinding (token→device store for
│   │                   raw OIDC-JWT sessions, keyed by SHA-256(token), per-node 60s TTL ETS cache,
│   │                   PostgreSQL source of truth — Story s2-device-lifecycle-at-login);
│   │                   Sweeper (hourly best-effort eviction of expired jwt_device_bindings +
│   │                   uia_sessions rows — Story s3, supervised under Nebu.Repo's children);
│   │                   RefreshWorker (periodic per-row proactive redemption of matrix_sessions'
│   │                   stored upstream OIDC refresh token shortly before expires_at, so legacy
│   │                   Element Web SSO-token-login clients that never call POST /refresh stay
│   │                   logged in — interval/lookahead configurable via
│   │                   NEBU_MATRIX_REFRESH_WORKER_INTERVAL_MS /
│   │                   NEBU_MATRIX_REFRESH_WORKER_LOOKAHEAD_SECONDS, defaults 5min/1h — Story
│   │                   server-paced-session-refresh/background-session-refresh-worker,
│   │                   supervised alongside Sweeper under Nebu.Repo's children)
│   ├── presence/     ← Presence status (online/offline/unavailable)
│   ├── signature/    ← Ed25519 signing (:crypto eddsa), Nebu.EventId.generate/1 (SHA-256 content
│   │                   hash), RFC 8785 canonical JSON
│   ├── permissions/  ← system roles (instance_admin | compliance_officer | user) + room power levels
│   └── event_dispatcher/ ← Nebu.Matrix.EventDispatcher.Server — the in-process command/DTO layer the
│                       HTTP routers call directly (send_event, create_room, join/leave, get_messages,
│                       get_room_state, set_presence/typing, get_sync_delta, invalidate_user_sessions,
│                       get_relations, get_event, search_messages, upgrade_room, bulk_import_users).
│                       pg Process Groups fanout for sync wakeups; membership-scoped FTS via the
│                       search DB module. Plain Elixir module — no gRPC dependency (ADR-021,
│                       grpc-removal epic 2026-06-22).
│
├── media/            ← Nebu.Media.* — media gateway, in-process behind the OIDC pipeline
│   ├── http/         ← Matrix /_matrix/media/v3/* + /_matrix/client/v1/media/* (upload, download,
│   │                   download/{fileName}, thumbnail, config, preview_url)
│   ├── crypto.ex     ← AES-256-GCM at-rest encrypt/decrypt (ADR-011 managed key escrow); whole-blob
│   │                   GCM decrypt (download decrypts in memory, then serves/ranges over plaintext)
│   ├── db.ex         ← inline media_files SQL (per-object AES key + nonce stored hex; ADR-018)
│   ├── membership.ex ← LOCAL room_members SQL access-control check (replaces the former gRPC
│   │                   CheckMembership RPC; media_files has no room_id → member-of-any-room, accepted
│   │                   follow-up)
│   ├── storage.ex    ← ExAws.S3 against MinIO/S3 (ADR-013); Finch pool started in Nebu.Application
│   ├── http_fetch.ex ← preview_url outbound fetch via Finch + Floki OG-tag parsing; 1 MiB body cap
│   └── ssrf.ex       ← outbound-fetch guard: scheme allowlist + blocks loopback / RFC1918 /
│                       link-local / CGNAT / cloud-metadata / IPv4-mapped / IPv6-ULA; resolve-once
│                       IP-pinning for http (https-SNI DNS-rebind TOCTOU = residual accepted risk)
│
├── admin/            ← Nebu.Admin.* — Phoenix HTTP controller + LiveView Admin UI + admin OIDC login
│   ├── endpoint.ex   ← Phoenix.Endpoint with server: false — NO separate listener; the top router
│   │                   forwards the /admin subtree by calling it, so admin pages ride the same Bandit
│   │                   port (4000) as Matrix/media
│   ├── router.ex     ← Phoenix.Router; :admin pipeline with require_admin plug; CRUD pages use
│   │                   get/post/delete routes; LiveViews (Dashboard, AuditLog, Logs) use live_session :admin;
│   │                   /admin/login + /admin/login/start + /admin/bootstrap are public (no admin gate);
│   │                   GET /logs/config + POST /logs/config/retention (LogsController, plain HTTP —
│   │                   deliberately NOT under live_session :admin, story admin-logs-retention-settings);
│   │                   stub routes live /logs/trace-map + live /logs/war-room (stories trace-map-leitstand /
│   │                   war-room-dedicated-page implement these pages; for now they render LogsLive)
│   ├── layouts.ex     ← Nebu.Admin.Layouts — Phoenix.Component helpers for the shared admin UI shell.
│   │                   root/1 renders the HTML document wrapper (Tailwind + DaisyUI stylesheet, Phoenix
│   │                   LiveView client). live/1 renders the shared admin chrome: header + left sidebar nav +
│   │                   main content area. The sidebar uses a dual-mode nav_item/1 component (story
│   │                   admin-sidebar-nesting, enhanced-logging epic). live/1 also wires in WarRoomIndicator
│   │                   to poll war room status every 2s, driving a pulsing red recording dot on the "War Room"
│   │                   sidebar item and a topbar recording pill ("War Room recording · mm:ss") visible while
│   │                   a session is active (story war-room-dedicated-page, trace-map-leitstand design closure).
│   │                     • LEAF mode (`children == []`, default) — a plain nav item with zero behavior change
│   │                       for existing call sites; renders as `<li><.link>` with active highlighting via
│   │                       @active_nav key match. When key == "logs-war-room" and @war_room_active, the
│   │                       nav item renders with a pulsing red dot and the <li> gains a distinct background.
│   │                     • PARENT mode (`children != []`) — an accessible disclosure group: <button aria-expanded
│   │                       aria-controls> toggle (with chevron icon that rotates on expand) followed by an
│   │                       indented nested <ul id="nav-{key}-children"> of child items. The parent is a pure
│   │                       disclosure control (no navigation); client-side delegated click listener
│   │                       (wireNavSectionToggles in app.js) flips aria-expanded + hidden attribute + chevron
│   │                       rotation on click (CSP-safe, survives LiveView morphdom patches).
│   │                   Current nesting: "Logs" parent (children: Live Stream/logs-monitoring → /admin/logs,
│   │                   Trace Map/logs-trace-map → /admin/logs/trace-map, War Room/logs-war-room →
│   │                   /admin/logs/war-room, Log Retention/logs-config → /admin/logs/config);
│   │                   "Configuration" parent (children: Role Mapping/role-mapping, Claim Mapping/
│   │                   claim-mapping, General/config-general → /admin/config). Pre-existing flat
│   │                   top-level "Role Mapping" and "Claim Mapping" items removed (AC6). Label
│   │                   "Configuration" under Logs renamed to "Log Retention" in story trace-map-leitstand
│   │                   (navkey logs-config unchanged).
│   │                   Active-nav mechanism extended to parents: when a child's key matches @active_nav,
│   │                   the child gets primary highlight (bg-primary text-primary-content + aria-current="page")
│   │                   and the parent gets secondary highlight (bg-base-300, never bg-primary), keeping the
│   │                   hierarchy visible. Leaf items (Dashboard, Users, Rooms, Spaces, Compliance, Bootstrap,
│   │                   Logout) render as before with full primary highlight on key match.
│   │                   Accessibility: parents are <button> elements (not links) with aria-expanded (true/false,
│   │                   toggled by client) + aria-controls pointing to child <ul>'s id. All nav items retain
│   │                   data-navkey for E2E selector compatibility (AC11). Children always in DOM; collapse adds
│   │                   hidden attribute only (no display-none class — ensures UA's [hidden] rule applies,
│   │                   closing a cascade bug where flex utility beats conditional display). Tab navigation works
│   │                   naturally (parents are focusable buttons, children focusable when parent expanded).
│   ├── auth.ex       ← admin OIDC Authorization-Code + PKCE login (login_start/callback/logout) +
│   │                   require_admin plug (for HTTP controllers) + bootstrap_gate plug (for bootstrap
│   │                   controller; open while bootstrap incomplete, locked post-setup) +
│   │                   on_mount admin gate (for LiveViews; all unauthenticated LiveView mounts now
│   │                   redirect — BootstrapLive is no longer a routed LiveView); PKCE S256 + state +
│   │                   nonce in the signed session; constant-time state validation; verifies the ID
│   │                   token via the shared OidcPlug verify; gates on server_config.admin_group_claim
│   │                   (default instance_admin, inline SQL, ADR-018); mints the Phoenix session (renew, 8h cap)
│   ├── rooms_controller.ex      ← Room Management HTTP controller (PRG pattern; inline SQL, ADR-018)
│   ├── users_controller.ex      ← User overview + per-user device management HTTP controller
│   │                   (OIDC-imported users, inline SQL); index/2 (GET /users) plus the S4
│   │                   device-management handlers show/2 (GET /users/:user_id), rename_device/2
│   │                   (POST .../devices/:device_id/rename) and delete_device/2 (POST
│   │                   .../devices/:device_id + _method=DELETE) — PRG, :require_admin-gated, CSRF;
│   │                   reaches devices ONLY through the Nebu.Matrix facade (ADR-020), never
│   │                   DeviceKeyStore directly; audits on success + failure (device-management S4)
│   ├── spaces_controller.ex     ← Spaces management HTTP controller
│   ├── config_controller.ex     ← Server configuration HTTP controller
│   ├── claim_mapping_controller.ex ← OIDC claim mapping HTTP controller
│   ├── role_mapping_controller.ex  ← Role mapping HTTP controller
│   ├── compliance_controller.ex    ← Compliance settings HTTP controller
│   ├── dashboard_live.ex        ← Dashboard LiveView (real-time metrics; remains as LiveView)
│   ├── audit_log_live.ex        ← Audit log LiveView (live-streaming audit events; remains as LiveView)
│   ├── logs_live.ex             ← Operational Logs Monitoring LiveView (live request-stream grouped by
│   │                   request_id, subscribes to Nebu.Web.LogStore's "operational_logs" PubSub topic,
│   │                   level/source bubble filtering; real server-tracked @active_filters socket assign
│   │                   supporting same-dimension multi-select, with instant client-side visual feedback
│   │                   via Phoenix.LiveView.JS.dispatch for latency, plus JS.push for server-side state
│   │                   sync; URL query params (?level=error,warning) for reloadable/shareable filtered
│   │                   views; popstate handler sync_filters to keep server assign in sync with
│   │                   back/forward navigation; story trace-map-filter-reset-bugfix fixed latent
│   │                   filter-reset bug where unrelated re-renders silently wiped click state since
│   │                   server never tracked it before; 200-row eviction cap for memory bounding; detail
│   │                   panel slide-in for chronological log threads; header now links to /admin/logs/config
│   │                   via "Sammlung konfigurieren →" (story admin-logs-retention-settings). The
│   │                   endpoint-filtering Trace Map was retired in story trace-map-leitstand and now
│   │                   lives on a dedicated page at /admin/logs/trace-map. Since war-room-mode:
│   │                   handle_event("start_war_room"/"stop_war_room", ...) — real server round-trips
│   │                   (unlike the prior filter design), gated by the same on_mount :require_admin as
│   │                   the rest of the LiveView, calling into Nebu.Admin.WarRoomManager; a 2s self-tick
│   │                   (Process.send_after) refreshes the live budget/time-remaining display independent
│   │                   of log traffic; mount/3 now reads an optional war_room_id query param and, if
│   │                   present, seeds initial_entries/0 from Nebu.Web.LogStore.get_logs(%{war_room_id: id})
│   │                   instead of the default unfiltered 200-row load — a bookmarkable "view this
│   │                   session's logs" URL (AC12)
│   │   ├── trace_map_bubble.ex  ← Reusable Phoenix.Component with :filter mode (level/source, toggleable
│   │   │                   bubbles, aria-pressed semantics), :configure mode (visual styling only —
│   │   │                   color/shape — reused by LogsController's plain-HTML template, story
│   │   │                   admin-logs-retention-settings), and :readonly mode (non-interactive preview,
│   │   │                   new, war-room-dedicated-page — bubbles render with live counts but are
│   │   │                   disabled/unclickable, used by WarRoom's pre-session live-activity scoping form).
│   │   │                   Endpoint-filtering Trace Map was retired from /admin/logs in story
│   │   │                   trace-map-leitstand.
│   │   ├── trace_map_tree.ex     ← Nebu.Admin.LogsLive.TraceMapTree (story trace-map-hierarchy):
│   │   │                   hierarchical domain→endpoint disclosure-tree wrapper component, grouping
│   │   │                   observed endpoints by top-level namespace/domain (e.g. /admin, /_matrix/client,
│   │   │                   /_matrix/media, /health) into collapsible group headers with native <button
│   │   │                   aria-expanded> disclosure controls. Kept for reuse via
│   │   │                   domain_for_endpoint/1 and group_endpoints_by_domain/1 helpers (canonical
│   │   │                   domain-classification logic used by trace-map-leitstand), though the
│   │   │                   endpoint_tree/1 component render is now unused on /admin/logs. Flagged for
│   │   │                   cleanup in a follow-up story.
│   │   ├── detail_panel.ex      ← Stateless slide-in detail-panel component; renders chronological
│   │   │                   thread of log entries for a request_id with full metadata
│   │   ├── war_room_panel.ex    ← Nebu.Admin.LogsLive.WarRoomPanel (RETIRED, war-room-mode): previously the visually
│   │   │                   distinct "🚨 Start War Room" / "🚨 War Room Active" embedded panel on /admin/logs
│   │   │                   (inactive: start form; active: live status bar). NO LONGER RENDERED on Live Stream page.
│   │   │                   Replaced by the dedicated Nebu.Admin.LogsLive.WarRoom page (story
│   │   │                   war-room-dedicated-page).
│   │   └── war_room.ex          ← Nebu.Admin.LogsLive.WarRoom (new, war-room-dedicated-page): the dedicated
│   │                       LiveView for /admin/logs/war-room, with two actions (:index list view
│   │                       and :show detail view, mirroring LogsLive.TraceMap's shape). Index displays
│   │                       active/historical war_room_sessions, a pre-session scoping form with live
│   │                       TraceMapBubble preview (level/source, :readonly mode), and exclusive-scope
│   │                       checkbox list. Show displays session metadata panel + filtered operational_logs
│   │                       (war_room_id match), copy-to-markdown export, and back link to list. Breadcrumb
│   │                       and routing via /admin/logs/war-room/:room_id (both routes in router.ex)
│   ├── trace_map_geometry.ex    ← Nebu.Admin.TraceMapGeometry (new, trace-map-leitstand): pure Elixir
│   │                   module computing radial SVG positions for the Trace Map Leitstand control-room
│   │                   page (ADR-018/021). Canonical helper: 4-domain fixed angles (−48/48/132/−132)
│   │                   with even-distribution fallback; satellite fan min(130°, n·26°) relative to
│   │                   their domain; polar_to_cartesian/2 conversion; trim_edge/2 for line padding;
│   │                   layout/1 for node-radius and ring-distance computations (nebu r=52 at origin,
│   │                   domains R1=195 r=38, satellites R2=128 r=24).
│   ├── logs_live/        ← Submodules for the trace-map-leitstand, trace-map-node-controls, and war-room-mode stories:
│   │   ├── trace_map_status.ex   ← Nebu.Admin.LogsLive.TraceMapStatus (new, trace-map-leitstand): pure
│   │   │                   module for AC3's 60-second sliding-window status calculation (worst-child
│   │   │                   propagation, auto-heal on window slide). Pure functions of (state, now_ms);
│   │   │                   record/3 self-prunes aged events for bounded per-node memory. No cleanup
│   │                   timer — aging happens naturally as the window advances with each new entry.
│   │   └── trace_map.ex         ← Nebu.Admin.LogsLive.TraceMap (new, trace-map-leitstand; extended,
│   │                   trace-map-node-controls): dedicated LiveView module at /admin/logs/trace-map,
│   │                   separate from LogsLive because it exports handle_params/3 (AC5's URL-driven
│   │                   filter state via push_patch), which would break live_isolated/3 tests of the
│   │                   shared monitoring page. Selection state: @selected seeded from bracket-array
│   │                   ?endpoint[]=… params in handle_params/3; every node click round-trips
│   │                   toggle_node/clear_filters → push_patch → handle_params/3. Status events
│   │                   recorded per-node at ingest; parents' rendered status uses TraceMapStatus.worst/1.
│   │                   A 1s server tick advances @now_ms for auto-heal visibility without traffic. War-room
│   │                   status polled every 2s (banner appears/disappears dynamically while the page is open),
│   │                   guarded behind Process.whereis(Nebu.Repo) like all DB reads (mount stays DB-free
│   │                   for unit tests). (trace-map-node-controls extends with: inspector logging control
│   │                   panel — min-level/retention selects, persistent-term CaptureCache for 2s-poll DB
│   │                   mirroring, enable/disable handlers for temporary capture — 5-minute server-side
│   │                   timers from admin_temporary_captures table, countdown display via JS hook, cascade
│   │                   config updates to domain/nebu nodes' descendant endpoints, aria-live announcements for
│   │                   capture events).
│   ├── war_room_manager.ex      ← Nebu.Admin.WarRoomManager (new, war-room-mode): the Admin-domain
│   │                   public API + inline-SQL (ADR-018) module for war room session lifecycle —
│   │                   start_session/1, stop_session/1, status/0. Deliberately NOT a Plug.Conn-aware
│   │                   HTTP controller (the story's own Dev Notes assumed a separate
│   │                   war_room_controller.ex + JSON endpoints; /admin/logs is a LiveView, not a plain
│   │                   Controller, and the admin app's :browser pipeline is html-only, so this is
│   │                   called directly from LogsLive's handle_event clauses instead — see
│   │                   08-concepts.md). Enforces "exactly one active session" via an app-level check
│   │                   PLUS a DB partial unique index backstop (war_room_sessions_single_active_idx ON
│   │                   ((1)) WHERE ended_at IS NULL) — a unique_violation on a race maps to the same
│   │                   {:error, :conflict, message} tuple as the app-level check. Also enforces
│   │                   max_entries (10..10_000) / max_duration_s (10..3_600) bounds DIRECTLY at this
│   │                   API boundary (added after a Kassandra security-review MEDIUM finding: the
│   │                   LiveView form's own bounds check alone was insufficient defense-in-depth for a
│   │                   feature whose entire purpose is bounding runaway log collection)
│   ├── war_room_indicator.ex    ← Nebu.Admin.WarRoomIndicator (new, war-room-dedicated-page): a
│   │                   shared assign helper module (no render output) that polls WarRoomManager.status/0
│   │                   every 2s to provide a live @war_room_active assign for 5 admin LiveViews
│   │                   (DashboardLive, AuditLogLive, LogsLive, LogsLive.TraceMap, LogsLive.WarRoom).
│   │                   Used by Layouts.live/1 to drive a pulsing red recording dot on the "War Room"
│   │                   sidebar nav item and a topbar recording pill ("War Room recording · mm:ss")
│   │                   visible from anywhere in the admin UI while a session is active (story
│   │                   trace-map-leitstand design approval, closure of the cross-page visibility gap)
│   ├── temporary_capture_manager.ex ← Nebu.Admin.TemporaryCaptureManager (new, trace-map-node-controls):
│   │                   the Admin-domain public API + inline-SQL (ADR-018) module for temporary logging
│   │                   capture on long-polling endpoints (endpoints off by default). DB-backed 5-minute
│   │                   timer via admin_temporary_captures table (endpoint PK, expires_at TIMESTAMPTZ,
│   │                   enabled_at TIMESTAMP, started_by TEXT). enable/2 inserts/updates a row;
│   │                   disable/2 deletes it; active?/1 checks expiry; cleanup_expired/0 removes past-expiry
│   │                   rows (NOT auto-scheduled — manual hygiene helper to avoid deadlock risk if wired into
│   │                   CaptureCache's own refresh). Cluster-safe: state is a shared DB row, expiry is a
│   │                   server-time comparison against NOW()
│   ├── logs_controller.ex       ← Nebu.Admin.LogsController — Logging Settings page (story
│   │                   admin-logs-retention-settings): GET /logs/config (renders form), POST
│   │                   /logs/config/retention (validates + persists). Deliberately a plain Phoenix
│   │                   Controller, NOT a LiveView — follows ConfigController's exact pattern
│   │                   (plug-based :require_admin, injectable writer seam via
│   │                   Application.get_env(:nebu_http, :admin_logs_retention_writer)). WARN/ERROR
│   │                   render as non-interactive divs (always-on, no UI control per AC6); INFO/DEBUG
│   │                   render as interactive buttons with server-conditional inline retention fields
│   │                   and (DEBUG only) an excessive-logging warning. Blank/"0" retention fields are
│   │                   unconditionally normalized to "no limit" server-side; the 7-day/1000-entry
│   │                   "sensible defaults" (AC8) are applied entirely client-side, never server-side.
│   ├── logs_config_html.ex      ← Nebu.Admin.LogsConfigHTML — view module for LogsController, named
│   │                   explicitly (not the Phoenix-derived LogsHTML) to avoid ambiguity with the
│   │                   sibling Nebu.Admin.LogsLive monitoring module
│   │   └── templates/logs_config/index.html.heex — form + bubbles + inline retention fields + DEBUG
│   │                   warning template; CSRF token via Plug.CSRFProtection.get_csrf_token/0
│   ├── bootstrap_controller.ex  ← Bootstrap Wizard plain HTTP controller (fix-bootstrap-wizard-liveview-bugs):
│   │                   replaces BootstrapLive for routing; accessible unauthenticated when bootstrap
│   │                   incomplete (bootstrap_gate plug); step 2 auto-discovers JWKS URI from
│   │                   {issuer}/.well-known/openid-configuration (no manual JWKS URI field); plain
│   │                   HTML POST forms (no LiveView socket → no field-clearing on reconnect);
│   │                   oidc_client_secret AES-256-GCM encrypted at rest via BootstrapLive.encrypt_secret/1
│   └── bootstrap_live.ex        ← Bootstrap Wizard LiveView (DEAD-ROUTED — no longer in router.ex);
│                       kept because Auth.oidc_config/1 and SsoLogin call encrypt_secret/decrypt_secret;
│                       will be refactored to Nebu.Web.SecretBox in a follow-up story
│
└── compliance/       ← Nebu.Compliance.* — four-eyes access, append-only audit-log writers, signed
                        export, GDPR erasure orchestration (deactivate → delete keys → anonymize →
                        audit)
```

> **Room upgrade flow:** `upgrade_room/2` in `Nebu.Matrix.EventDispatcher.Server` implements the
> complete Matrix spec §11.35.1 sequence atomically: (1) tombstone the old room, (2) create the new
> room with `predecessor` field, (3) join creator, (4) set power levels, (5) copy state events,
> (6) invite old members, (7) `archive_room_atomic/1` (SELECT FOR UPDATE, idempotent on `:not_found`)
> marks the old room row archived in PostgreSQL, (8) `Horde.DynamicSupervisor.terminate_child/2` stops
> the old room GenServer. Errors surface as `Nebu.Matrix.Error` with a `Nebu.Matrix.Status` atom,
> mapped to HTTP 500 by `Nebu.Matrix.Http.call_core/1`. A top-level `try/rescue` writes a failure
> entry to the audit trail before reraising.

> **PostgreSQL table `forgotten_rooms (user_id, room_id, forgotten_at_ms BIGINT)`:** defined in
> the canonical schema `000001_init.up.sql` (the table pre-existed; it is not a separate
> migration). Tracks rooms the user has dismissed via `POST /forget`. The Elixir wiring landed
> in the `forget-room-membership-purge` bugfix epic (Story 9-19 shipped only a no-op stub):
> `forget_room/2` inserts (after the not-joined guard), both sync builders reject the forgotten
> room_ids in-process, and `join_room/2` removes the row on re-join. Excluded from all `/sync`
> sections (join, leave, invite). Primary key `(user_id, room_id)`; cascade delete on `users` removal.

> **`sync_tokens` schema change in Story 9-22:** migration 000041 adds `device_id TEXT NOT NULL DEFAULT ''`
> and replaces the `user_id`-only primary key with a composite `(user_id, device_id)` PK.
> Legacy rows are preserved with `device_id = ''`. Each device now maintains an independent
> sync checkpoint, preventing parallel sessions on different devices from overwriting each other's
> `since` token.

> **Cross-signing key directory (story `cross-signing-readback`):** migration 000010 adds
> `cross_signing_keys`, keyed by `user_id`, storing the opaque `master_keys` / `self_signing_keys`
> / `user_signing_keys` objects plus a consume-once `cross_signing_changed BOOLEAN` flag.
> `Nebu.Matrix.CrossSigningKeyStore` (plain module, inline parameterised SQL via `Nebu.Repo`,
> ADR-018) mirrors `Nebu.Matrix.DeviceKeyStore` (migration 000009): `keys/device_signing/upload`
> persists, `keys/query` echoes the stored objects, `keys/signatures/upload` merges signatures
> (validate-then-persist, caller-identity guard), and `/sync` surfaces the uploading user's own ID
> in `device_lists.changed` by consuming the flag. A cross-signing key ID colliding with an
> existing device ID is rejected (`400 M_INVALID_PARAM`) before any write. All material is opaque
> — this is an E2EE-readiness directory orthogonal to encryption; `m.room.encryption` is still
> rejected (`403 M_FORBIDDEN`, ADR-011).

> **Durable global account data (story `account-data-durability`):** migration 000011 adds
> `account_data`, keyed by `(user_id, type)`, storing the account-data value verbatim in a TEXT
> `content_json` column (opaque, ADR-011 — never parsed or decrypted) plus a consume-once
> `changed BOOLEAN` flag. This replaces the previous volatile, node-local **ETS** stub:
> `Nebu.Matrix.AccountDataStore` is now a plain module with inline parameterised SQL via
> `Nebu.Repo` (ADR-018), mirroring `CrossSigningKeyStore`. `PUT/GET
> /user/{userId}/account_data/{type}` now persist/read the durable row (survive restart,
> cluster-correct per ADR-020); the `user==auth` IDOR guard and 404-absent behaviour are
> unchanged. `GET /sync` delivers the top-level `account_data.events` from this store via
> `put_global_account_data/3` in `Nebu.Web.Router.Protected`: an INITIAL sync (no `since`)
> returns ALL entries (`list_all_and_clear/1`); an INCREMENTAL sync returns only entries whose
> `changed` flag is set, read-and-cleared atomically (`UPDATE … RETURNING`,
> `list_changed_and_clear/1`). This closes the recovery-durability gap that
> `cross-signing-readback` deliberately left out — Element's `m.secret_storage.*` /
> `m.cross_signing.*` recovery material now survives restarts and is delivered to the client.
> (Supersedes the volatile-ETS description and the Go-era Story 9-24 `room_account_data WHERE
> room_id = ''` approach noted below, which the Elixir stack does not use for global account data.)

> **Full-text search column in Story 11-1 (ADR-010):** migration 000042 adds a `search_vector tsvector`
> column to the `events` table, populated by a PL/pgSQL trigger (`events_search_vector_trigger`)
> on every `INSERT OR UPDATE OF content`. The trigger calls
> `to_tsvector('pg_catalog.simple', coalesce(content->>'body', ''))`, using the `simple`
> text search configuration (language-agnostic, no stemming - appropriate for a multilingual
> chat server). A GIN index (`events_search_vector_gin_idx`) enables efficient `@@ tsquery`
> queries. All existing events were backfilled during the migration. This is the database
> foundation for `POST /_matrix/client/v3/search` (Epic 11). Scope enforcement at query time:
> `WHERE room_id = ANY($membership_room_ids)` prevents cross-room leakage.

> **Global account data in sync responses (Story 9-24):** `syncResponse` gains a top-level
> `AccountData syncAccountDataSection` field (JSON key `account_data`, never omitted) that carries
> global `m.*` account data events per Matrix spec §6.3. The sync handler in `Nebu.Matrix.Http*`
> injects global account data by querying `room_account_data WHERE room_id = ''` (inline SQL, ADR-018)
> inside a user-scoped transaction that sets the `app.user_id` GUC to satisfy the RLS policy. The
> response always includes `account_data.events` (never omitted, may be empty).

> **Synthetic next_batch token (Story 9-25, GAP-BUFFER-NEXT-BATCH):** when a sync response is served
> from a local fast-path rather than a fresh `get_sync_delta` round-trip, the sync handler in
> `Nebu.Matrix.Http*` generates a monotonic `buf_<unix_ms>_<seq>` token (unique even for
> sub-millisecond bursts). The synthetic token is never persisted to `sync_tokens`; if the client
> sends it on the next request, `get_sync_delta` finds no matching row and triggers a safe full
> re-sync (FallbackToInitial). No schema change.

> **`devices` table — device as a first-class entity (Story s1-device-registry-model):** migration
> `000010_devices.up.sql` adds a `devices` table (`PRIMARY KEY (user_id, device_id)`; `display_name`,
> `last_seen_ts`, `last_seen_ip`, `created_at`, `updated_at`) that holds device IDENTITY + management
> metadata, SEPARATE from the crypto-key blob in `device_keys` (migration 000009). A `devices` row may
> exist with NO key material (a *keyless* device). Because 000009 is shipped/immutable (it reached the
> operator's Stackit install), 000010 is a NEW forward migration that BACKFILLS `devices` from existing
> `device_keys` rows (`INSERT … SELECT … ON CONFLICT DO NOTHING`; `last_seen_ip` has no source there →
> NULL). `Nebu.Matrix.DeviceKeyStore` (in `matrix/`) gains `upsert_device/3`; `list_devices/1`,
> `get_device/2`, and `sole_device_id/1` now read device identity from `devices` (so `GET /devices`
> lists keyless devices), while `query_devices/1` INNER-JOINs `devices` + `device_keys` so
> `POST /keys/query` still returns ONLY key-bearing devices (Matrix semantics unchanged).
> `put_device_keys/4` upserts the `devices` row FIRST, then the `device_keys` row — device existence is
> independent of keys, and a crash between the two writes leaves only a valid keyless device. Inline SQL
> (ADR-018), PostgreSQL-backed/cluster-correct (ADR-020), orthogonal to E2EE (ADR-011). Foundation for
> the device-management epic (S2–S4). No new ADR.

> **`jwt_device_bindings` table — token→device binding for raw-JWT sessions (Story
> s2-device-lifecycle-at-login):** migration `000011_jwt_device_bindings.up.sql` adds
> `jwt_device_bindings (token_hash TEXT PK, user_id TEXT, device_id TEXT, created_at BIGINT)`
> (forward migration; 000010 from S1 is immutable). It backs `Nebu.Matrix.Session.DeviceBinding`:
> an opaque Nebu session already records its device in `matrix_sessions.device_id`, but a raw OIDC
> JWT is issued by the IdP and carries no Nebu `device_id`, so login persists the `token→device_id`
> association here and `OidcPlug` looks it up on every authenticated request. The row is keyed by
> `SHA-256(access_token)` — the cleartext token is **never** stored, so a DB dump exposes no usable
> bearer tokens. A per-node 60s-TTL ETS cache (mirroring `OidcPlug`'s provision cache) keeps the
> per-request lookup off the DB hot path; PostgreSQL remains the source of truth so login and a later
> request may land on different nodes (cluster-correct, ADR-020). Writes are best-effort — a missing
> table or DB hiccup degrades to "no bound device" (handled like an unbound token) and never crashes
> login. Inline SQL (ADR-018). Orthogonal to E2EE (ADR-011). No new ADR.

> **`000012_device_management_uia` — UIA + kill-switch schema (Story s3-matrix-device-endpoints):**
> migration `000012_device_management_uia.up.sql` is a NEW forward migration (000009–000011 are
> shipped/immutable; idempotent `ADD COLUMN IF NOT EXISTS` / `CREATE … IF NOT EXISTS`). It adds the
> columns + table that back UIA-gated device writes and the per-device JWT kill-switch:
> - `matrix_sessions.auth_time BIGINT` (nullable) — the user's last FRESH authentication time (unix
>   seconds), set at login from the id_token's `auth_time`/`iat`. The 15-min freshness gate compares
>   `now - auth_time`; token refresh copies it **verbatim** (`MatrixSessionStore.refresh_auth_time/2`)
>   so a refresh can never reset freshness. A row with no `auth_time` is always treated as stale.
> - `jwt_device_bindings.exp BIGINT` — the verified JWT's expiry, written by `DeviceBinding.put/3`;
>   the kill-switch denylists each bound token until its own `exp`, and `Session.Sweeper` evicts rows
>   whose `exp` has passed.
> - `idx_jwt_device_bindings_user_device` on `(user_id, device_id)` — serves the kill-switch's
>   enumeration of every binding for a deleted device.
> - `uia_sessions (session_id PK, user_id, op, params, stage_complete, consumed, created_at,
>   expires_at)` — server-issued, single-use UIA sessions bound to `(user_id, op, params)`. **DB-backed,
>   not node-local ETS (ADR-020):** a session is minted on one node, its `m.login.sso` stage completed
>   by the browser SSO callback on possibly another node, and the re-submit may hit a third — every node
>   reads the same authoritative row, and single-use is enforced by an atomic
>   `consumed = TRUE WHERE consumed = FALSE` UPDATE. Inline SQL (ADR-018). Orthogonal to E2EE (ADR-011).
>   No new ADR.

> **`Nebu.Matrix` device facade — the ADR-020 cross-domain entry point for device management
> (Story s4-admin-device-management):** S4's Admin UI consumes devices through three NEW public
> functions on the `Nebu.Matrix` facade, never by reaching into `Nebu.Matrix.DeviceKeyStore` or
> `Session.*` directly (Public-API rule, ADR-020):
> - `list_user_devices/1` — lists a user's devices from the durable `devices` registry (keyless
>   devices included); read-path, never raises. `created_at` is now surfaced (alongside
>   `display_name`/`last_seen_ts`/`last_seen_ip`) so the detail page can show a "created" column.
> - `rename_user_device/3` — renames a device's `display_name`, scoped to the OWNING `user_id`;
>   returns `:ok` on a hit, `:error` for an unknown/foreign device (no IDOR — `:error` maps to a flash).
> - `delete_user_device/2` — revoke + delete in one call: fires the **S3 per-device JWT kill-switch
>   first** (`TokenDenylist.revoke_by_hash/2` for every `jwt_device_bindings` row of the pair, then
>   drops the bindings + the opaque session), then removes the device identity row and all key
>   material. User-scoped, best-effort/idempotent, returns `:ok`. Unlike the Matrix self-delete path
>   it preserves no caller credential — an admin acts on another user's device, so EVERY bound token
>   is revoked.
>
> The facade keeps the Admin controller thin and the cross-domain boundary explicit: Admin → `Nebu.Matrix`
> facade → (DeviceKeyStore / TokenDenylist / DeviceBinding / MatrixSessionStore). No new migration
> (S4 reuses S1–S3 schema), no new ADR. Orthogonal to E2EE (ADR-011).

## Level 2 - In-Process Command & DTO Layer

> **gRPC fully removed (ADR-021 / `grpc-removal` epic, 2026-06-22):**
>
> The `proto/` directory and generated Elixir stubs (`core_grpc.pb.ex`) no longer exist.
> `Core.*` are now hand-maintained plain `defstruct` DTOs in `server/lib/nebu/matrix/`.
> `Nebu.Matrix.EventDispatcher.Server` is a plain Elixir module (`defmodule` / `def`);
> it no longer `use GRPC.Server`. Errors are `Nebu.Matrix.Error` with
> `Nebu.Matrix.Status` atoms; `Nebu.Matrix.Http.call_core/1` maps them to Matrix HTTP
> error envelopes. There is no `:grpc` or `:protobuf` Hex dependency and no `make proto`
> target.

Key command handlers: `send_event`, `create_room`, `join_room`, `get_messages`, `get_room_state`,
`set_presence`, `set_typing`, `validate_token`,
`get_sync_delta` (incremental sync with per-device `device_id`, Story 9-22),
`invalidate_user_sessions` (per-device or full-user session cleanup, Story 9-22),
`get_relations` (thread relation events for a parent event_id, Story 9-28/9-29),
`search_messages` (full-text search with membership enforcement, Story 11-3),
`get_event` (single event fetch by event_id scoped to a room, membership-enforced, Story 11-8),
`bulk_import_users` (admin bulk provisioning of OIDC users, identical flow to first login, Story 14-3a).

> **Historical note:** prior to the `grpc-removal` epic these handlers were defined in a gRPC
> `CoreService` and called via generated `Core.*` protobuf request/response structs. The struct
> field tables in the source-provenance notes below (`GetSyncDeltaRequest`, `InvalidateUserSessionsRequest`,
> etc.) describe the field contract that was carried forward into the plain-struct DTOs; the fields
> themselves are unchanged.

**`GetSyncDeltaRequest` fields (Story 9-22):**

| Field | Type | Description |
|---|---|---|
| `user_id` | string | Matrix user ID |
| `since_token` | string | Client-supplied sync token |
| `timeout_ms` | int64 | Long-poll timeout |
| `device_id` | string | Device-scoped checkpoint key; empty string = legacy fallback |

**`InvalidateUserSessionsRequest` fields (Story 9-22):**

| Field | Type | Description |
|---|---|---|
| `user_id` | string | Matrix user ID |
| `device_id` | string | When set, only invalidates this device; when empty, invalidates all user sessions |


_Source: `_bmad-output/planning-artifacts/architecture.md`, §Project Structure & Boundaries, §Complete Project Directory Structure; Story 9-19 (room_moderation.go, sync.go, event_dispatcher/server.ex, forgotten_rooms migration); Story 9-22 (per-device sync tokens, device_id in proto); Story 9-24 (GlobalAccountDataDB interface, ListGlobalAccountData, top-level account_data in syncResponse); Story 9-25 (syntheticNextBatch helper, syntheticBatchSeq atomic counter, sinceToken param removed from buildResponseFromBufferedEvents); Story 9-27 (upgrade_room/2 full Matrix §11.35.1 flow, GRPC.RPCError error handling, archive_room_atomic, terminate_child, try/rescue failure audit); Story 11-2 (Nebu.Search.DB, membership-scoped FTS SQL contract, encrypted-room exclusion, integration test infrastructure); Story 11-10 (ClaimMappingHandler admin settings page, ClaimSelectionHandler bootstrap extension, ServerConfigReader interface with LoadClaimMapping/SaveClaimMapping, FormatUserIDFromClaims refactored signature, JWTMiddleware userIDClaimLoader param, migration 000044 default claim mapping seed); Story 12.16 (media/internal/auth middleware package - TokenVerifier interface + fail-closed nil guard; media/internal/config handler package; CSP + Cross-Origin-Resource-Policy headers on download/thumbnail; v1 authenticated media routes in main.go)_
**`Core.Event` struct - `unsigned_relations` field (Story 9-28):**

The shared `Core.Event` struct gained field `unsigned_relations` (originally protobuf field 9;
now a plain key in the `defstruct`):

```elixir
# unsigned_relations: binary()
# JSON: {"m.thread":{"count":N,"latest_event":{...},"current_user_participated":bool}}
```

Set by `attach_thread_aggregations/3` in Elixir for events that have at least one thread reply.
Empty (`""` / nil) for events with no relations - the sync handler omits `m.relations` from the
`unsigned` JSON object when the field is absent.

**`GetRelationsRequest` / `GetRelationsResponse` fields (Story 9-28 / 9-29):**

| Field | Type | Description |
|---|---|---|
| `user_id` | string | Caller; membership guard enforced in Elixir |
| `room_id` | string | Room that contains the parent event |
| `event_id` | string | Parent event ID (thread root) |
| `rel_type` | string | Relation type, e.g. `"m.thread"`; empty = all relation types (Story 9-29) |
| `limit` | int32 | Max events returned; 0 = default 20; clamped to 100 |
| `event_type` | string | Filter by event type; empty = all event types (Story 9-29, field 6) |
| `dir` | string | `"f"` = oldest-first ASC; `"b"` = newest-first DESC (default) (Story 9-29, field 7) |
| `recurse` | bool | Accepted without error; MVP passes through (Story 9-29, field 8) |
| `from` | string | Opaque pagination token; empty = first page (Story 9-29, field 9) |

Response: `repeated Event events` + `string next_batch` (empty when no more pages) + `string prev_batch` (for dir=b backward pagination, Story 9-29, field 3).

> **Migration 000042 (Story 9-28):** `CREATE INDEX CONCURRENTLY … ON events
> ((content->'m.relates_to'->>'event_id')) WHERE content ? 'm.relates_to'` - expression index
> on the `m.relates_to` JSONB field; required by `fetch_events_by_relation/5` and
> `count_thread_children/2` to avoid sequential scans on the events table.

> **`Nebu.Search.DB` - membership-scoped FTS query layer (Story 11-2):**
> the membership-scoped search SQL layer under `server/lib/nebu/matrix/` defines the SQL contract for
> `POST /_matrix/client/v3/search` (Epic 11). Key design invariants:
>
> 1. **SQL-layer membership enforcement** - the subquery `WHERE room_id IN (SELECT room_id FROM room_members WHERE user_id = $1 AND left_at IS NULL)` runs inside the same PostgreSQL query. There is no application-layer post-filter; membership is checked at query execution time. This prevents cross-room IDOR leakage even if Elixir application logic is bypassed.
>
> 2. **Encrypted-room exclusion** - rooms that have an `m.room.encryption` state event (`state_key = '' OR state_key IS NULL`) are excluded from search results via `NOT EXISTS (SELECT 1 FROM events enc WHERE enc.room_id = e.room_id AND enc.event_type = 'm.room.encryption')`. Ciphertext bodies are never returned in plaintext search responses.
>
> 3. **`user_id` security invariant** - the `user_id` parameter MUST be sourced from the validated session (`conn.assigns.current_user` set by `OidcPlug`), never from the request payload. Passing a caller-supplied user_id bypasses all membership enforcement and enables cross-room IDOR. This invariant is enforced by the caller (`search_messages` handler) not by `Nebu.Search.DB` itself.
>
> 4. **`websearch_to_tsquery` + `pg_catalog.simple`** - consistent with the trigger configuration in migration 000042 (ADR-010). `ts_rank_cd` for result ordering (density-aware ranking).
>
> 5. **Module placement** - in `event_dispatcher` (not `room_manager`) because the gRPC search handler (Story 11.3) lives in `Nebu.EventDispatcher.Server`. Adding search to `Nebu.Room.DB` would violate the single-responsibility principle and pollute `Nebu.Room.DBBehaviour`.

> **Integration test infrastructure (Story 11-2):** `Makefile` gains a `test-integration-elixir` target that runs ExUnit tests tagged `@tag :integration` against a live PostgreSQL instance (`NEBU_TEST_DB_URL`). The 6 search integration tests (AC1 cross-room scope, AC2 structural SQL shape, AC3 kicked-user exclusion, zero-membership guard, encrypted-room exclusion, multi-room inclusion) are excluded from the `test-unit-elixir` target via `ExUnit.configure(exclude: [:integration])` in `event_dispatcher/test/test_helper.exs`.

> **`search_messages` handler (Story 11-3):** `Nebu.Matrix.EventDispatcher.Server.search_messages/2` is the
> in-process entry point for `POST /_matrix/client/v3/search` (implemented in Story 11-4). Key design decisions:
>
> 1. **Delegated search module** - the handler delegates to `search_db_module()` (runtime-swappable via `Application.get_env(:event_dispatcher, :search_db_module, Nebu.Search.DB)`) to keep SQL logic in `Nebu.Search.DB` and make the handler unit-testable with a fake via `FakeSearchDB`.
>
> 2. **`user_id` from trusted assigns only** - the handler reads `user_id` from `conn.assigns.current_user` (set by `OidcPlug`). The `request.user_id` field is intentionally ignored. This enforces the Story 11-2 security invariant at the HTTP layer.
>
> 3. **Pagination** - `next_batch` is `Base64(Integer.to_string(offset + limit))`. An empty string signals no more pages. The handler caps `offset` at `10_000` to prevent unbounded deep-paging queries (Kassandra MEDIUM finding, fixed inline).
>
> 4. **Limit clamping** - `limit` is clamped to `[1, 100]`; zero defaults to 10.
>
> 5. **DTO additions** - `SearchMessagesRequest` / `SearchMessagesResponse` structs and the `search_messages` handler were added to the `Core.*` DTO layer. (Historically these were protobuf types regenerated via `make proto`; since the `grpc-removal` epic they are plain Elixir `defstruct` DTOs.)

**`GetEventRequest` / `GetEventResponse` fields (Story 11-8):**

| Field | Type | Description |
|---|---|---|
| `room_id` | string | Room that owns the event; scopes the DB query |
| `event_id` | string | Unique event ID to fetch |
| `user_id` | string | Caller; Elixir enforces joined-member check via Horde room state |

Response: `Event event` - the full event proto (same `Event` message used by sync and relations endpoints).

> **`get_event` handler design (Story 11-8):** `Nebu.Matrix.EventDispatcher.Server.get_event/2` looks up
> the room via `Nebu.Matrix.Room.RoomSupervisor.lookup_room/1` (Horde registry). If the room is unknown, it
> raises `Nebu.Matrix.Error` with `:not_found`. It then calls `room_registry_module().get_state/1` and checks
> `MapSet.member?(state.members, user_id)` - non-members receive `:permission_denied`. On success it
> delegates to `messages_db_module().fetch_event/2` (SQL: `SELECT … WHERE event_id=$1 AND room_id=$2 LIMIT 1`)
> and calls `attach_thread_aggregations/3` so the returned event already carries bundled `m.thread`
> aggregation data (same as sync responses). The `GetEventRequest` / `GetEventResponse` structs are
> plain `defstruct` DTOs (historically added to `core.proto`; now hand-maintained).

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Project Structure & Boundaries, §Complete Project Directory Structure; Story 9-19 (room_moderation.go, sync.go, event_dispatcher/server.ex, forgotten_rooms migration); Story 9-22 (per-device sync tokens, device_id in proto); Story 9-24 (GlobalAccountDataDB interface, ListGlobalAccountData, top-level account_data in syncResponse); Story 9-25 (syntheticNextBatch helper, syntheticBatchSeq atomic counter, sinceToken param removed from buildResponseFromBufferedEvents); Story 9-27 (upgrade_room/2 full Matrix §11.35.1 flow, GRPC.RPCError error handling, archive_room_atomic, terminate_child, try/rescue failure audit); Story 9-28 (GetRelations RPC, unsigned_relations field on Event, attach_thread_aggregations, fetch_events_by_relation, count_thread_children, event_in_room?, migration 000042); Story 9-29 (base /relations/{eventId} route, three-segment /{relType}/{eventType} route, dir/event_type/recurse/from query params, prev_batch in response, fetch_events_by_relation/5 dynamic WHERE builder); Story 11-3 (SearchMessages gRPC handler, proto extension, delegated search_db_module pattern, offset-cap security fix); Story 11-4 (search.go Gateway handler, SearchCoreClient consumer interface, §11.14.1 response shape, gRPC error mapping); Story 11-5 (NewUserRateLimiter middleware, per-user 10 req/min for /search, retry_after_ms in body); Story 11-8 (GetEvent RPC, event.go Go handler, fetch_event/2 DB function, core_grpc.pb.ex rpc :GetEvent + rpc :GetRelations bug fix); Story 11-9 (health/info.go NewInfoHandler, Nebu.BuildInfo module, GET /info on pubMux + health server, Admin UI footer via page_data.go SetBuildInfo/newPageData, ErrorMode on PageData, Dockerfile ARG/ldflags injection, docker-compose.yml build args); Story 11-10 (ClaimMappingHandler + ClaimMappingPageData + ClaimMappingConfig in claim_mapping.go, claim-mapping.html template, ClaimSelectionHandler atomic claim persistence in auth.go, ServerConfigReader LoadClaimMapping/SaveClaimMapping extension, FormatUserIDFromClaims signature refactor in grpc/metadata.go, JWTMiddleware userIDClaimLoader param, LoginHandler per-request claim resolution, migration 000044 claim mapping defaults seed); Story 12.16 (media/internal/auth middleware - TokenVerifier interface + fail-closed nil guard; media/internal/config handler; CSP + Cross-Origin-Resource-Policy headers on download/thumbnail; v1 authenticated routes in main.go); oidc-middleware-migration (nebu_http: NebuHttp.Plugs.OidcPlug Bearer-token validation, NebuHttp.JwksCache GenServer with TTL refresh + last-known-good, NebuHttp.Router.Protected /_matrix sub-router — built + unit-tested, NOT yet on the live request path; live cutover owned by matrix-api-migration); media-gateway-migration (nebu_http: NebuHttp.Media + Crypto/DB/Membership/Storage/HttpFetch/SSRF submodules + NebuHttp.Router.Media serving /_matrix/media/v3/* behind OidcPlug; media access-control now a local room_members SQL call replacing the gRPC CheckMembership RPC; ExAws.S3/MinIO storage with Finch pool in NebuHttp.Application; AES-256-GCM at-rest encryption per ADR-011; SSRF-guarded + rate-limited preview_url fetch; inline SQL per ADR-018; replaces the standalone Go media service)_
