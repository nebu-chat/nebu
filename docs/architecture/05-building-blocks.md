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
│   │                   authenticated media routes forwarded to two DEDICATED sub-routers — deprecated
│   │                   /_matrix/media/v3/* to Nebu.Web.Router.Media, and (since
│   │                   bugfix-fix-matrix-client-v1-media-routes) /_matrix/client/v1/media/* to
│   │                   Nebu.Web.Router.ClientV1Media — both matched BEFORE the generic /_matrix
│   │                   catch-all (Plug.Router is top-down, so forward ordering is load-bearing);
│   │                   everything else under /_matrix runs the OIDC pipeline via
│   │                   Nebu.Web.Router.Protected; forwards /admin to the Phoenix Admin endpoint;
│   │                   before_send sets X-Content-Type-Options: nosniff on EVERY response
│   ├── router/       ← sub-routers forwarded from router.ex, one Plug.Router module per Matrix
│   │   │               sub-surface, each running its own OidcPlug pipeline
│   │   ├── protected.ex ← Nebu.Web.Router.Protected — the catch-all AUTHENTICATED Matrix
│   │   │               Client-Server API router (forward "/_matrix", matched LAST, after every
│   │   │               more specific /_matrix/* prefix above it): sync, send, createRoom/join,
│   │   │               profile PUT, presence, /search, keys, device management, relations, etc.
│   │   ├── media.ex     ← Nebu.Web.Router.Media — deprecated `/_matrix/media/v3/*` routes (upload,
│   │   │               download[/{fileName}], thumbnail, preview_url), forwarded from
│   │   │               "/_matrix/media"; own OidcPlug pipeline (every media route authenticated);
│   │   │               per-IP RateLimit on upload (600/min b5) and preview_url (30/min b10, F-1 —
│   │   │               outbound-fetch SSRF-amplifier abuse cap)
│   │   └── client_v1_media.ex ← Nebu.Web.Router.ClientV1Media (NEW,
│   │                   bugfix-fix-matrix-client-v1-media-routes): authenticated Matrix
│   │                   Client-Server v1 media endpoints — GET download/{serverName}/{mediaId}
│   │                   [/{fileName}] and GET thumbnail/{serverName}/{mediaId} — forwarded from
│   │                   "/_matrix/client/v1/media", the prefix modern Element Web (spec v1.11+)
│   │                   actually calls instead of the deprecated v3 endpoints (previously
│   │                   unrouted → 404, the bug this story fixed). Reuses Nebu.Media.download/2,3
│   │                   and thumbnail/3 as-is (no handler changes) — routing-only fix. Deliberately
│   │                   a SEPARATE router from Media, not a shared/reused one (code-review cycle 1):
│   │                   forwarding this prefix to Media directly would have made /v3/upload,
│   │                   /v3/preview_url etc. cross-reachable under /_matrix/client/v1/media, and
│   │                   made un-versioned /download, /thumbnail aliases reachable under
│   │                   /_matrix/media — both unintended widenings of the URL surface. Runs its own
│   │                   OidcPlug pipeline (M_MISSING_TOKEN/M_UNKNOWN_TOKEN 401s, same as v3) and has
│   │                   ONLY these two route clauses + its own 404 catch-all — no rate limiting
│   │                   (parity with the un-rate-limited v3 download/thumbnail clauses).
│   │                   `/_matrix/client/v1/media/config` remains unimplemented (no route exists;
│   │                   out of scope for this bugfix — see docs/matrix-api-scope.md).
│   ├── oidc_config.ex ← Nebu.Web.OidcConfig — GenServer + ETS cache for OIDC issuer, audience,
│   │                   JWKS URI, and (since fix-and-configure-sso-redirect-schemes) the Admin-UI
│   │                   -managed sso_extra_redirect_schemes string, all resolved from server_config.
│   │                   Per-request DB lookups on hot paths (OIDC + SSO redirectUrl validation) are
│   │                   unacceptable, so values are cached in :nebu_http_oidc_config ETS table.
│   │                   Cluster-aware via :pg broadcast on refresh (ADR-020), triggered by both the
│   │                   Bootstrap Wizard and Nebu.Admin.DB.upsert_server_config/1 (Admin UI edits).
│   │                   Used by OidcPlug (issuer/audience), JwksCache (JWKS URI), and SsoLogin
│   │                   (extra redirect schemes for the redirectUrl allowlist).
│   │                   Operational contract: the configured issuer must resolve from both the Nebu
│   │                   network and end-user browsers — Nebu never rewrites discovery-document URLs
│   │                   (bugfix-oidc-public-endpoint-urls; dev: Dex issuer dex.localtest.me + compose alias).
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
│   │   │                 coarse for AC4's single-entry budget/override semantics).
│   │   │                 **Scope extension for media domain (Story 10e):** `scope_matches?/2`'s private
│   │   │                 clause now accepts a LIST of route templates (in addition to the existing
│   │   │                 nil/"all"/single-string forms, all unchanged) and performs OR-matching: an entry's
│   │   │                 route matches if it is a member of the list. This closure enables scoping a War Room
│   │   │                 session to an entire domain (e.g. `["/media/clamav", "/media/scan_worker", "/admin/media"]`
│   │   │                 for the media-scan-pipeline observability integration) without enumerating every
│   │   │                 endpoint individually. The war_room_sessions `scope` column was already JSON-capable
│   │   │                 (existed as a free-text seam); no migration needed.
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
│   │                   RefreshWorker (periodic per-row proactive revalidation of matrix_sessions'
│   │                   stored upstream OIDC refresh token shortly before expires_at; it addresses
│   │                   rows by their SHA-256 access_token_hash, since the table stores only token
│   │                   hashes, never plaintext tokens; it extends the
│   │                   session IN PLACE (same access/refresh token, expires_at only ever grows, capped
│   │                   at created_at + session TTL) and never rotates tokens the client must know, so
│   │                   legacy clients that never call POST /refresh stay logged in and clients that do
│   │                   refresh are not invalidated — interval/lookahead configurable via
│   │                   NEBU_MATRIX_REFRESH_WORKER_INTERVAL_MS /
│   │                   NEBU_MATRIX_REFRESH_WORKER_LOOKAHEAD_SECONDS, defaults 5min/1h — Stories
│   │                   server-paced-session-refresh/background-session-refresh-worker and
│   │                   matrix-session-refresh-fixes/refresh-worker-and-retry-semantics, supervised
│   │                   alongside Sweeper under Nebu.Repo's children); RefreshErrors (single
│   │                   transient-vs-confirmed classification of IdP/DB errors for the worker and
│   │                   POST /refresh: transient → 503 + Retry-After, session untouched; confirmed →
│   │                   401 and device session deleted)
│   ├── presence/     ← Presence status (online/offline/unavailable)
│   ├── signature/    ← Ed25519 signing (:crypto eddsa), Nebu.EventId.generate/1 (SHA-256 content
│   │                   hash), RFC 8785 canonical JSON
│   ├── permissions/  ← system roles (instance_admin | compliance_officer | user) + room power levels
│   ├── active?/1     ← Nebu.Matrix.active?(user_id) (Story 2a, media-security-admin-control epic):
│   │                   new minimal read-only public-API function (ADR-020-compliant) that checks whether a
│   │                   user is active (not deactivated). Executes `SELECT is_active FROM users WHERE user_id = $1`;
│   │                   returns true only on `[[true]]`, false otherwise (fail-closed on unknown/deactivated/DB-error).
│   │                   Injected into `Nebu.Media.Permission.can_upload?/1` (Story 2a) to enforce AC4 (permission check
│   │                   on POST /create). Deliberately narrow scope: takes an arbitrary user_id parameter (for future
│   │                   extensibility) but today's sole caller (Media.Permission) passes only the authenticated caller's
│   │                   own identity — Kassandra security review flagged that a future caller using this function with
│   │                   a client-supplied MXID could create a deactivation/existence oracle (F-4 INFO, accepted risk per
│   │                   existing M_USER_DEACTIVATED acceptance in MEMORY).
│   ├── page_token.ex  ← Nebu.Matrix.PageToken (Story: mutual-rooms + space-hierarchy refactor):
│   │                   shared opaque offset-pagination token codec extracted for reuse across multiple
│   │                   paginated endpoints. encode/2 and decode/2 accept a string prefix parameter so
│   │                   each endpoint supplies its own namespace (e.g. "h1:" for space hierarchy via
│   │                   SpaceHierarchy, "mr1:" for mutual_rooms via EventDispatcher.Server) — prefix
│   │                   mismatch on decode fails closed. Token format: url-safe Base64 of
│   │                   `<prefix><offset>`. Moved from a private implementation in SpaceHierarchy (Story 13's
│   │                   spaces epic) into a shared module to eliminate duplication.
│   └── event_dispatcher/ ← Nebu.Matrix.EventDispatcher.Server — the in-process command/DTO layer the
│                       HTTP routers call directly (send_event, create_room, join/leave, get_messages,
│                       get_room_state, set_presence/typing, get_sync_delta, invalidate_user_sessions,
│                       get_relations, get_event, search_messages, upgrade_room, get_mutual_rooms, bulk_import_users).
│                       pg Process Groups fanout for sync wakeups; membership-scoped FTS via the
│                       search DB module. Plain Elixir module — no gRPC dependency (ADR-021,
│                       grpc-removal epic 2026-06-22). build_state_events/2 threads real event
│                       identity (event_id, origin_server_ts) for state events in sync responses
│                       from the DB (m.room.create, m.room.name, generic state) and from
│                       GenServer memory (m.room.member, m.room.power_levels) — ensures spec
│                       compliance by emitting ClientEventWithoutRoomID fields for all state events
│                       (bugfix: sync-state-events-missing-fields, migration 000035).
│                       attach_replaces_state_to_state_events/2 (new, bugfix:
│                       unsigned-replaces-state, 2026-10-07): enriches sync + /messages + /event
│                       responses with `unsigned.replaces_state` field (Matrix CS API v1.19 MUST
│                       behavior) — the event_id of the state event previously current at the same
│                       (room_id, type, state_key) slot, absent from unsigned if none. Uses a
│                       single batched SQL query per response via Room.DB.fetch_replaces_state/1
│                       (UNNEST+LATERAL join against events_room_state_idx index), O(1) per
│                       response not per-state-event (AC5 N+1 avoidance). SECURITY FIX: pre-fix
│                       Room.Server.do_send_event/7 collapsed nil state_key to "" before
│                       persisting, enabling state-event forgery via PUT /send/{anyEventType}
│                       (unguarded, any joined member at power_level=0, bypasses change_state
│                       check). Attack class: room rename, join-policy bypass, history-visibility
│                       bypass, encryption flip. Post-fix: persists as SQL NULL, dropped by
│                       is_state_event signal. Core.Event proto gains is_state_event field (new,
│                       server-derived nil-ness of raw state_key column). Migration 000036
│                       backfills historical corruption via conservative inclusion list (only
│                       m.room.message empirically confirmed; fail-safe design never deletes
│                       legitimate state rows). Operator detection query documented; handoff items
│                       F-1 (pre-fix data remediation), F-2 (separate send-path m.room.encryption
│                       guard, unblocking search-disable primitive), F-3/F-4/F-6 (query filters,
│                       array chunking) tracked non-blocking per security review.
│
├── media/            ← Nebu.Media.* — media gateway + security enforcement, in-process behind the OIDC pipeline
│   ├── http/         ← Matrix /_matrix/media/v3/* + /_matrix/client/v1/media/* (upload, download,
│   │                   download/{fileName}, thumbnail, config, preview_url); lifecycle-gated by state machine.
│   │                   Download serves the stored Content-Type unchanged (inline/attachment per the Matrix spec inline
│   │                   list, active-content types neutralized to octet-stream), delivers the upload filename in
│   │                   Content-Disposition, and thumbnails only jpeg/png/apng/gif/webp (else 400) — see 08-concepts.md.
│   │                   Story 2d extends `download` (NOT `thumbnail` — out of scope) with an opt-in
│   │                   `?timeout_ms=N` download-stall wait for `:quarantined`/`:scanning` media, delegating
│   │                   to `Nebu.Media.DownloadStall` before falling through to the unchanged 1c response
│   │                   path; absent/malformed `?timeout_ms` remains byte-for-byte identical to 1c.
│   │                   Story 2b adds `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`
│   │                   (`Nebu.Media.upload_async/3`) — the async-upload companion validating a
│   │                   reservation created by `POST /_matrix/media/v1/create` (Story 2a): lookup(404) ->
│   │                   ownership(403) -> expiry(404, derived live as uploaded_at + config TTL, no persisted
│   │                   unused_expires_at column) -> state guard(409) -> blocked-type/mime_denylist(400) ->
│   │                   size(413) -> body read -> the shared `store_and_quarantine/7` persist-transition-enqueue
│   │                   seam. Story 2c's synchronous-path consolidation extracts a shared private function
│   │                   `encrypt_compress_and_store/5` that both sync (`PUT /_matrix/media/v3/upload`, via
│   │                   `store_upload/4` → `create_and_store/6`) and async paths call identically, eliminating
│   │                   duplication and ensuring both flows apply hash → gzip → AES-256-GCM → S3-write uniformly
│   │                   (AC2). Security review (Kassandra, 2b): CLEAN, 0 CRITICAL/HIGH; 1 LOW (concurrent-PUT
│   │                   TOCTOU, self-vs-self only, accepted — resolved in Story 2c via shared pipeline) + 3 INFO
│   │                   (filename header-injection watch-flag for the future download-wiring story;
│   │                   no RLS on media_files, pre-existing standing gap; migration GRANT doc-hygiene).
│   ├── state_machine.ex ← Nebu.Media.StateMachine (Story 1b + 2a + 2c + 2e + 4a, media-security-admin-control epic):
│   │                   the sole code path for state mutations on media_files (creation and transitions alike).
│   │                   Story 1b defines the state-transition half: guards 8-state machine (reserved → {quarantined | hard_deleted} →
│   │                   scanning → {released | infected | admin_blocked}; deleted → hard_deleted) with inline-SQL
│   │                   transition/4. Atomically updates media_files.state + appends audit row to append-only
│   │                   media_state_transitions ledger per transaction. Guard table (`allowed?/2`,
│   │                   `allowed_transitions/1`) encoded 15 valid edges through Story 2e (adds reserved→hard_deleted for the
│   │                   cleanup cron; e.g. quarantined→scanning, scanning→{released,infected,quarantined,admin_blocked},
│   │                   admin_blocked→released, …). Story 4a adds the 9th state, `:scan_failed` (media_state ENUM's
│   │                   9th value, migration `000028_media_scan_failed_state` — renumbered from the story's stale
│   │                   `000023` reference, since 5 sibling stories claimed 000023-000027 first), bringing the guard
│   │                   table to 21 edges: `quarantined`/`scanning` gain an outbound edge to `:scan_failed` (Oban
│   │                   `discard/2` firing before/during a scan, Story 4b), and `:scan_failed` itself has 4 outbound
│   │                   edges — back to `:scanning` (retry), or to `:released`/`:admin_blocked` (admin manual
│   │                   resolution), or to `:deleted` (retention/lifecycle parity with every other non-terminal
│   │                   state — `:scan_failed` is NOT terminal, it means "unknown," not "known-bad" or "done").
│   │                   Only `@type state`/`@transitions` changed — the transition mechanism itself (transition/4,
│   │                   allowed?/2, allowed_transitions/1, the atomic UPDATE+INSERT, actor validation) is untouched,
│   │                   and Story 1c's download-gate catch-all needed zero code change (verified against a real,
│   │                   committed ENUM value, not just the pre-existing bare-atom test fixture — see 10-quality.md).
│   │                   Invalid transitions rejected before write. Grep-based invariant test scans source for direct
│   │                   `UPDATE … media_files … SET state` (cheap first-line defense; authoritative enforcement via
│   │                   DB trigger + RLS per ADR-031, Story 1a). Story 2a adds the creation half: a new public
│   │                   `create/1` genesis function that atomically INSERTs a brand-new media_files row in state
│   │                   :reserved + its inaugural media_state_transitions row (from_state NULL, to_state 'reserved',
│   │                   actor_type 'system', actor_id NULL, per the architectural decision that uploader identity
│   │                   is tracked via the pre-existing media_files.uploader_user_id column, not via the actor-ledger's
│   │                   narrow actor_id field — see Story 2a security review for rationale). The creation path is
│   │                   separate from transition/4 and does not consult the @transitions guard table (no source/target
│   │                   pair to validate for a row that did not exist). Collision detection: `:unique_violation` on
│   │                   media_id PRIMARY KEY triggers exactly one regeneration retry; a second collision surfaces as
│   │                   500 (no unbounded loop, AC5). Actor tracking: transition/4 accepts `{:system, nil}` (scanner) or
│   │                   `{:admin, user_id}`; create/1 hardcodes `{:system, nil}` for all genesis rows. ADR-018/020 guards
│   │                   both paths. Story 2c adds a second genesis function, `create_quarantined/1`, used by the
│   │                   synchronous upload path: creates a media_files row directly in :quarantined state (never :reserved)
│   │                   with a single genesis media_state_transitions row (from_state NULL, to_state 'quarantined');
│   │                   identical contract to create/1 but destination state differs to match sync-upload semantics
│   │                   (bytes already present, skip :reserved). Story 2b is the first real production caller of
│   │                   `transition/4` (previously exercised only by `state_machine_test.exs`): its
│   │                   `store_and_quarantine/7` seam calls `transition(media_id, :quarantined, {:system, nil})` after
│   │                   a successful S3 write. Story 2e adds a specialized `:hard_deleted`-destination UPDATE path in
│   │                   `write_transition/6`: when `to_state == :hard_deleted`, the statement also nulls
│   │                   `uploader_user_id` and stamps `hard_deleted_at = now()` — this dual-column behavior appears NOWHERE else
│   │                   in the codebase (the first real caller), and Story 2e's migration 000027 first makes the column nullable
│   │                   (previously NOT NULL, a critical bug catch).
│   ├── permission.ex ← Nebu.Media.Permission (Story 2a, media-security-admin-control epic):
│   │                   injectable boundary for upload permission checks, injected via
│   │                   `:media_permission_module` (mirroring the pattern of :media_storage_module/:media_db_module/
│   │                   :media_membership_module). Single public API: `can_upload?(user_id)` calls the injected
│   │                   implementation to evaluate whether the given user has permission to create new reservations.
│   │                   Story 2a's default implementation delegates to `Nebu.Matrix.active?(user_id)` (a new minimal
│   │                   read-only public-API function, ADR-020-compliant) which SELECTs is_active from users; fail-closed
│   │                   on unknown/deactivated/DB-error cases. Designed for future extension: a later story can swap in a
│   │                   room-power-level check or a compliance-hold gate without modifying `Media.create/1` (AC4).
│   ├── crypto.ex     ← AES-256-GCM at-rest encrypt/decrypt (ADR-011 managed key escrow); whole-blob
│   │                   GCM decrypt (download decrypts in memory, then decompresses via
│   │                   `safe_maybe_gunzip/2` if `media_files.compressed=true` per ADR-029,
│   │                   and finally serves/ranges over plaintext)
│   ├── db.ex         ← inline media_files SQL (per-object AES key + nonce stored hex; ADR-018); does NOT
│   │                   issue direct state mutations (all go through StateMachine.create/1 for genesis or
│   │                   StateMachine.transition/4 for state changes per ADR-018/031). Story 1c adds `parse_state/1`
│   │                   (@doc false, direct-testable) to defensively convert raw Postgres media_state ENUM strings to
│   │                   atoms via String.to_existing_atom, fail-closed on unrecognized/future values (rescues ArgumentError
│   │                   → sentinel atom) so unknown state strings never crash with uncaught 500, enabling
│   │                   forward-compatible DB compatibility before a new ENUM value's own code lands. Story 2a adds
│   │                   `count_pending_reservations(user_id)` — an injectable seam that counts the number of :reserved rows
│   │                   for a given uploader_user_id. Used by Media.create/1's AC3 pending-upload rate-limit check. Fails
│   │                   open on DB error (returns 0) — acceptable per Kassandra security review since the cap is a soft
│   │                   business limit, not a security control, and transient DB failures are self-limiting (a DB unhealthy
│   │                   enough to fail the COUNT will also fail the subsequent genesis INSERT, rolling back and returning 500)
│   │                   Story 2b adds `lookup_reservation/2` (returns uploader_user_id/state/uploaded_at for ANY
│   │                   state, not just :reserved — distinct from the download-scoped `lookup/2`) and
│   │                   `persist_upload/1` (the UPDATE that writes storage_key/file_hash/compressed/content_type/
│   │                   filename/key material after a successful S3 write — distinct from StateMachine.transition/4,
│   │                   whose only metadata channel is the media_state_transitions ledger, not the media_files row).
│   ├── download_gate ← Nebu.Media.download_gate/1 + gate_message/1 (Story 1c, media-security-admin-control epic):
│   │                   the HTTP-layer enforcement point for media_files.state lifecycle ENUM (ADR-026).
│   │                   Runs inside with_authorised_media/4 immediately after DB lookup, before membership
│   │                   check and before storage/decrypt work. Guards allow-list: `:released` is sole allow
│   │                   (returns :serve); `:admin_blocked` → (404, M_NOT_FOUND), BYTE-IDENTICAL status AND
│   │                   body to a genuine 404 (CORRECTED 2026-07-19, Story 6a Kassandra security-review: a
│   │                   prior revision returned 451 status here, anonymizing only the body — the (451,
│   │                   M_NOT_FOUND) pairing was itself a status-line-only fingerprint, exactly the dormant
│   │                   F-1 gap noted in 1c's own security review, now closed; see ADR-026's 2026-07-19
│   │                   correction); `:infected/:deleted/:hard_deleted` → (404, M_NOT_FOUND) — the SAME
│   │                   response as `:admin_blocked`, no distinguishing field anywhere; everything else
│   │                   (including `:reserved/:quarantined/:scanning` and any future/unrecognized state) →
│   │                   catch-all-deny (451, M_NOT_YET_UPLOADED) per AC6, never serving bytes on unknown
│   │                   state. Shared helper placement ensures both download and thumbnail routes enforce
│   │                   identically with zero duplicated logic
│   ├── download_stall.ex ← Nebu.Media.DownloadStall (Story 2d, media-security-admin-control epic):
│   │                   opt-in `?timeout_ms=N` download-stall CONSUMER for the async-upload flow (Story
│   │                   2a/2b). The broadcast PRODUCER this consumer waits on is
│   │                   `Nebu.Workers.MediaScanWorker` (Story 4b) — it calls `Phoenix.PubSub.broadcast/3`
│   │                   directly (StateMachine.transition/4 itself still does not broadcast; each caller
│   │                   that needs to is responsible for it) after EVERY terminal outcome it produces
│   │                   (`:released`, `:infected`, `:scan_failed`), not just the clean-scan path — this
│   │                   was 2d's own explicit coordination requirement (its stall must wake on all three,
│   │                   not just the happy path). The topic/payload contract `"media:#{media_id}"` /
│   │                   `{:media_state_transition, media_id, new_state}` on `Nebu.PubSub` (the same
│   │                   instance already used by Nebu.Web.LogStore, NOT Nebu.Admin.PubSub) matches
│   │                   exactly. `await/4` subscribes to the media's PubSub topic FIRST, then
│   │                   re-reads state via an injected recheck fun — closes the subscribe/lost-wakeup
│   │                   race; already-resolved state short-circuits without entering `receive`. Otherwise
│   │                   blocks in a single deadline-bounded `Task`-wrapped
│   │                   `receive ... after remaining -> :timeout end` (no busy-polling, AC5), bounded by
│   │                   the caller's `Task.await(task, clamped + 50)`. A crash-safe global `:atomics`
│   │                   counter in `:persistent_term` (eager-init at `Nebu.Application.start/2` boot,
│   │                   mirroring the pre-existing `:nebu_signing_key` init pattern) caps
│   │                   simultaneously-held stalls (`max_concurrent_stalls`, default 500) and degrades
│   │                   gracefully — no slot available → immediate no-stall response, same as absent
│   │                   `?timeout_ms` — rather than erroring (AC6). `Nebu.Media.download/4` delegates
│   │                   here only for `:quarantined`/`:scanning` with a clamped timeout > 0, then falls
│   │                   through to the UNCHANGED Story 1c `with_authorised_media → download_gate →
│   │                   gate_message` path — the stall's outcome is advisory only; correctness comes
│   │                   entirely from re-running the 1c deny-mapping against the freshly re-read row, so a
│   │                   forged/spoofed broadcast can only affect timing, never which bytes get served.
│   │                   `max_stall_ms`/`max_concurrent_stalls` read via new thin
│   │                   `Nebu.Media.max_stall_ms/0` / `max_concurrent_stalls/0` accessors over
│   │                   `Application.get_env(:nebu, Nebu.Media, [])` (config.exs defaults 20_000/500) —
│   │                   deliberately NOT sourced from Story 9a's `Nebu.Media.Config` yet, so that a future
│   │                   swap to `Config.get/0` is a one-line change inside the accessor, not a call-site
│   │                   change. Security review (Kassandra, Story 2d): 0 CRITICAL/HIGH; 1 MEDIUM (M-1: the
│   │                   `download` route has no per-IP rate limit — unlike its `upload`/`preview_url`
│   │                   siblings — and the stall turns it into a connection-holding (~20s) endpoint a
│   │                   single IP can monopolize across the entire 500-slot global ceiling; graceful
│   │                   degradation keeps blast radius bounded, non-blocking) + 3 LOW, see 10-quality.md.
│   ├── membership.ex ← LOCAL room_members SQL access-control check (replaces the former gRPC
│   │                   CheckMembership RPC; media_files has no room_id → member-of-any-room, accepted
│   │                   follow-up)
│   ├── storage.ex    ← ExAws.S3 against MinIO/S3 (ADR-013); Finch pool started in Nebu.Application.
│   │                   `compress/1` (Story 12) implements ADR-029 store-smaller-of-two strategy:
│   │                   gzips via `:zlib.gzip/1` and returns `{bytes_to_store, compressed?}` tuple,
│   │                   selecting whichever of {gzipped, original} is strictly smaller (ties →
│   │                   uncompressed). No compression-level tuning; standard OTP library.
│   │                   `delete/1` (Story 8a-media-cleanup-worker, AC6): permanently removes the
│   │                   S3/MinIO object for a `:hard_deleted` row, called ONLY by
│   │                   `Nebu.Workers.MediaCleanupWorker` between ADR-032's step 1 (state
│   │                   transition) and step 3 (nulling `storage_key`). A `404` is treated as
│   │                   `:ok` (already gone, safe no-op per ADR-032); every other error is
│   │                   returned as `{:error, reason}` for the caller to leave the row untouched
│   │                   and retry on the next tick.
│   ├── clamav.ex     ← Nebu.Media.ClamAV (Story 3, media-security-admin-control epic):
│   │                   GenServer speaking the ClamAV INSTREAM protocol directly over `:gen_tcp` to a
│   │                   clamd daemon, with health-check and auto-reconnect-on-next-use. Public API is
│   │                   `scan_binary/1` accepting an in-memory decrypted binary (already fetched from
│   │                   Storage + decrypted via Crypto) and returning `{:ok, :clean}` /
│   │                   `{:ok, {:infected, signature}}` / `{:error, reason}`. Implements ADR-024
│   │                   (ClamAV selection rationale — self-hosted, DSGVO). Single named GenServer,
│   │                   no connection pooling (per story's "S" scope). Connection framing: 4-byte
│   │                   big-endian length-prefixed 4096-byte chunks, zero-length terminator. Reply
│   │                   accumulation bounded at 64 KB (F-1 security finding: prevents unbounded memory
│   │                   growth from malicious/buggy clamd response — clamd output treated as adversarial).
│   │                   Every `:gen_tcp` failure (connect timeout, recv timeout, malformed response)
│   │                   returns `{:error, reason}`, never raises. Lazy-connect on first use; detects
│   │                   socket close and reconnects on next scan (AC8).
│   │                   **Trace-Map integration (Story 10e):** connect/disconnect/health-check-state-transition
│   │                   log calls (`Logger.warning/2` for unreachable clamd, `Logger.info/2` for healthy transition)
│   │                   now carry `route_template: "/media/clamav"` metadata so these operational events show up in
│   │                   the Trace-Map/War-Room observability system (see 08-concepts.md, "Operational Logging" section).
│   │                   The healthy-transition log is gated to fire ONLY on an actual unhealthy→healthy state flip
│   │                   (compared state before/after `ensure_connected/1`), not on every poll — this prevents
│   │                   unbounded row growth in `operational_logs` since WARN/INFO persist unconditionally per
│   │                   policy, independent of admin toggles.
│   ├── scan_enqueue.ex ← Nebu.Media.ScanEnqueue (Story 2b, wired for real by Story
│   │                   4b-media-scan-worker): the `:media_scan_enqueue_module` production
│   │                   default. `enqueue/1` now performs a real
│   │                   `%{media_id: media_id} |> Nebu.Workers.MediaScanWorker.new() |>
│   │                   Oban.insert()` — the call site in `Nebu.Media`'s
│   │                   `store_and_quarantine/7` (`:reserved -> :quarantined` transition) did
│   │                   NOT need to change, exactly as 2b's own wiring instruction anticipated.
│   │                   An `Oban.insert/1` failure is logged (`Logger.error`) but still returns
│   │                   `:ok` to the caller, preserving the pre-4b no-op's return contract (2b's
│   │                   handler never inspected this seam's return value).
│   ├── supervisor.ex ← Nebu.Media.Supervisor (Story 3, media-security-admin-control epic):
│   │                   plain child Supervisor (modeled on Nebu.Compliance.Supervisor) managing
│   │                   Nebu.Media.ClamAV; wired into Nebu.Application's `media_children/0` behind a
│   │                   `config :nebu_http, :start_clamav_client` boolean gate (default true, false in
│   │                   test). No host-level access to clamd — server reaches it via compose network
│   │                   by service name (F-4 security finding: removed clamd host port publish per
│   │                   security review, as clamd is an unauthenticated control-plane service).
│   ├── workers/      ← Background job infrastructure (Story 2e, media-security-admin-control epic):
│   │                   Oban (^2.18, resolved 2.23.0) bootstrapped here for the first time as the
│   │                   codebase's async task/cron queue. Unlike the Ecto.Migration paradigm,
│   │                   Oban's postgres schema (oban_jobs table + oban_job_state enum + oban_peers)
│   │                   is applied via raw SQL migration (000026_oban_jobs.up/down.sql) — a notable
│   │                   technical decision: this project's Nebu.Release raw-SQL-only migration runner
│   │                   (ADR-018) cannot directly call Oban.Migration.up/1, so migrations are
│   │                   hand-translated from Oban's ecto-generated SQL into numbered .sql files.
│   │                   Other stories wiring Oban workers (scan queue 4b, archive/lifecycle workers,
│   │                   webhook/stats jobs) follow this same raw-SQL pattern established here.
│   │   ├── media_reserved_upload_cleanup_worker.ex ← Nebu.Workers.MediaReservedUploadCleanupWorker
│   │   │                   (Story 2e): an Oban worker on a 15-minute cron schedule ("*/15 * * * *")
│   │   │                   that enumerates `media_files` rows in state `:reserved` whose
│   │   │                   upload-reservation TTL has expired (derived live as `uploaded_at +
│   │   │                   unused_expires_ms() < now_ms`, reading the same shared `:nebu_http,
│   │   │                   :media_unused_expires_ms` app-env key that Stories 2a/2b already use —
│   │   │                   no new/duplicate config). Transitions expired reservations to `:hard_deleted`
│   │   │                   via `Nebu.Media.StateMachine.transition/4` (the sole state-mutation code
│   │   │                   path per ADR-031). Idempotent under repeated/concurrent runs: rejected races
│   │   │                   (`{:error, {:invalid_transition, _, _}}`) are silently no-ops; other failure
│   │   │                   shapes propagate, triggering Oban retries (configured: max_attempts 5,
│   │   │                   exponential backoff, Lifeline rescue plugin). The `:hard_deleted` transition
│   │   │                   path nulls `uploader_user_id` and stamps `hard_deleted_at = now()` — the FIRST
│   │   │                   code path in the codebase to reach `:hard_deleted` state (the pre-existing
│   │   │                   `deleted -> hard_deleted` edge had no real caller before this story).
│   │   ├── media_scan_worker.ex ← Nebu.Workers.MediaScanWorker (Story 4b): the on-demand
│   │   │                   (not cron-scheduled — enqueued by `Nebu.Media.ScanEnqueue` per upload)
│   │   │                   worker that drives the malware-scan lifecycle. `use Oban.Worker, queue:
│   │   │                   :media_scan, max_attempts: 5`. `queues:` config gains only the
│   │   │                   `media_scan: [limit: 10]` entry — Oban itself, its schema, and its
│   │   │                   supervisor child were already introduced by Story 2e; this story adds
│   │   │                   no new migration, dependency, or supervisor wiring. `perform/1`:
│   │   │                   `:quarantined -> :scanning` (StateMachine.transition/4); ANY entry
│   │   │                   rejection (not just the documented invalid-transition case — a
│   │   │                   code-review fix widened this to a catch-all) is a no-op/retry-safe
│   │   │                   path, never an uncaught crash. Fetches ciphertext
│   │   │                   (`Nebu.Media.Storage.get/1`), hex-decodes the row's `aes_key_hex`/
│   │   │                   `nonce_hex` (non-bang `Base.decode16/2` — a code-review fix routes a
│   │   │                   malformed value through the same retry/discard path instead of raising),
│   │   │                   decrypts (`Nebu.Media.Crypto.decrypt/3`, no seam — pure function,
│   │   │                   called directly), conditionally `:zlib.gunzip/1`s (only when
│   │   │                   `row.compressed`), then `Nebu.Media.ClamAV.scan_binary/1`. Outcome
│   │   │                   routing: clean → `:released`; `:file_too_large` → `:released` with
│   │   │                   `scan_metadata: %{skipped: "size_limit"}` (a skip, not a retryable
│   │   │                   error); infected → `:infected` + `Nebu.Media.DB.update_scan_metadata/2`
│   │   │                   persists the ClamAV signature onto `media_files.scan_metadata` (a
│   │   │                   plain column UPDATE, not a violation of the state-mutation invariant —
│   │   │                   verified by a real-Postgres regression test that this UPDATE never
│   │   │                   touches `state`); any other scanner error → `:quarantined`, then
│   │   │                   `{:error, reason}` (Oban retries) if `attempt < max_attempts`, else
│   │   │                   `:scan_failed` + `{:discard, reason}` (Story 4a's dead-letter state —
│   │   │                   a file never sits silently in `:quarantined` once retries are
│   │   │                   genuinely exhausted). Broadcasts on EVERY terminal outcome (`:released`,
│   │   │                   `:infected`, `:scan_failed`) — see `download_stall.ex` above for the
│   │   │                   consumer this producer contract satisfies. `Nebu.Media.DB` gains
│   │   │                   `lookup_for_scan/1`/`update_scan_metadata/2` for this worker's needs.
│   │   │                   **Trace-Map integration (Story 10e):** scan-start, scan-result (released/infected/scan_failed),
│   │   │                   and error-retry log calls (`Logger.info/2` for routine paths, `Logger.warning/2` for
│   │   │                   infected/error paths) now carry `route_template: "/media/scan_worker"` and
│   │   │                   `request_id: media_id` (the media UUID reused as the correlation key for non-HTTP-originated
│   │   │                   events) so a file's entire operational story — from upload through scan to admin action —
│   │   │                   groups into one Trace-Map row (via the existing `entries_by_request_id` grouping logic
│   │   │                   unchanged in `Nebu.Admin.LogsLive`). Metadata carries only identifiers (`media_id`,
│   │   │                   `clamav_signature` when infected, `reason` when erroring), never bytes/filename/content
│   │   │                   (matching the pre-existing `user_id`/`device_id` precedent).
│   │   │                   Security review (Kassandra): 0 CRITICAL/HIGH/MEDIUM; 2 LOW
│   │   │                   forward-looking watch-flags (ClamAV `max_file_size_bytes` vs. 2b's
│   │   │                   upload-cap config consistency; no `unique:` Oban constraint, harmless
│   │   │                   today via guard-table rejection) — see 10-quality.md.
│   │   │                   **Compliance audit bridge (Story 4c, ADR-028):** `infect/2` and
│   │   │                   `scan_error/4`'s exhausted-retries branch (no separate `discard/2`
│   │   │                   callback — that was pre-4b draft-prose terminology) additionally call
│   │   │                   `Nebu.Compliance.AuditWriter.log/6` with `media_infected_detected` /
│   │   │                   `media_scan_failed` (both newly added to `AuditWriter.@known_actions`,
│   │   │                   verified live by temporarily reverting + confirming the new
│   │   │                   `AuditWriterMediaActionsTest` fails loudly), alongside — never instead
│   │   │                   of — the existing `media_state_transitions` write. Metadata
│   │   │                   (`media_id`/`filename`/`sha256`/`uploader_id` +
│   │   │                   `clamav_signature`/`reason`) is enriched via an independent
│   │   │                   `db().lookup_for_scan/1` call keyed by `media_id` at write time
│   │   │                   (rather than threading the scan's own `row` through every
│   │   │                   `scan_error/4` call site, several of which run before/without a
│   │   │                   successful row fetch) — `lookup_for_scan/1`'s SELECT was extended
│   │   │                   with `filename`/`file_hash`/`uploader_user_id` for this. No `room_id`
│   │   │                   key (ADR-028 — media_files has no room_id column; that join is
│   │   │                   query-time, future work). Security review (Kassandra): 0
│   │   │                   CRITICAL/HIGH/MEDIUM; 2 LOW advisory (metadata's `inspect(reason)`
│   │   │                   widens — does not create — an existing blast radius into a
│   │   │                   broader-visibility surface, no active render path today; CSV-export
│   │   │                   injection watch-flag for whichever future story implements
│   │   │                   `compliance_export_downloaded`, no such sink exists yet) — see
│   │   │                   10-quality.md.
│   │   │                   **Scan kill-switch (Story 10d):** `scan_and_transition/3` checks
│   │   │                   `Nebu.Media.ClamAV.health_check/0` FIRST, before any storage
│   │   │                   fetch/decrypt/decompress — a kill-switch decision never needs the
│   │   │                   file bytes. When healthy, behavior is unchanged from Story 4b. When
│   │   │                   unhealthy, the admin-configured `Nebu.Media.Config.get/0`
│   │   │                   `scan_kill_switch` key (new 15th catalog key, default `"fail_closed"`
│   │   │                   — never silently `"fail_open"`) decides: `"fail_open"` releases the
│   │   │                   file unscanned (`:scanning -> :released`, metadata
│   │   │                   `%{unscanned: true, reason: "clamav_unavailable"}`) and writes a
│   │   │                   THIRD compliance audit action, `media_unscanned_release` (new
│   │   │                   `AuditWriter.@known_actions` entry — the single most
│   │   │                   security-sensitive event this story exists to make visible);
│   │   │                   `"fail_closed"` reuses `scan_error/4` UNMODIFIED with reason
│   │   │                   `:clamav_unavailable` — the identical retry-then-exhaust-to-
│   │   │                   `scan_failed` path as any other scanner error, so the
│   │   │                   exhausted-retries case rides Story 4c's existing `media_scan_failed`
│   │   │                   audit bridge above with zero new code. Migration
│   │   │                   `000034_media_config_scan_kill_switch` extends
│   │   │                   `media_config_update_mutable` (`ALTER POLICY`, no new table). Config
│   │   │                   is read fresh via `Nebu.Media.Config.get/0` on every call (no
│   │   │                   worker-side caching), so a live policy change takes effect on the
│   │   │                   very next job with no restart. Security review (Kassandra): 0
│   │   │                   CRITICAL/HIGH/MEDIUM; 1 LOW self-fixed inline (an unexpected/
│   │   │                   corrupted `scan_kill_switch` value now fails CLOSED via a catch-all
│   │   │                   clause instead of raising) — see 10-quality.md.
│   │   ├── media_alert_webhook_worker.ex ← Nebu.Workers.MediaAlertWebhookWorker
│   │   │                   (Story 7-admin-notifications): delivers the outbound admin-
│   │   │                   notification webhook `Nebu.Media.AlertNotifier` enqueues. `use
│   │   │                   Oban.Worker, queue: :media_alerts, max_attempts: 5, unique:
│   │   │                   [period: 300, keys: [:media_id, :state]]` — a DEDICATED queue,
│   │   │                   separate from this same worker family's `:media_scan` queue, so a
│   │   │                   slow/backed-up webhook delivery can never starve or delay
│   │   │                   scan-job processing (Oban's per-queue independent concurrency
│   │   │                   pools hold this at the engine level, not just by convention —
│   │   │                   verified in the story's own security review). The `unique`
│   │   │                   constraint deduplicates the same event enqueued by more than one
│   │   │                   cluster node's own `AlertNotifier` (ADR-025's preference for
│   │   │                   Oban's own guarantees over a bespoke singleton-GenServer scheme).
│   │   │                   `perform/1` POSTs a JSON body of EXACTLY `media_id`/`state`/
│   │   │                   `timestamp` (no `filename`/`uploader_id`/ClamAV signature/file
│   │   │                   content — a deliberate compliance-motivated narrowing versus the
│   │   │                   epic's own first-draft AC) via `Nebu.Media.WebhookDelivery.post/2`.
│   │   │                   Never calls `Nebu.Media.StateMachine` or writes to
│   │   │                   `media_files`/`media_state_transitions` in any branch — a
│   │   │                   structural guarantee (zero references in the module), not just a
│   │   │                   behavioral one — so a delivery failure is entirely Oban's own
│   │   │                   retry/backoff/discard concern and can never re-enter the media
│   │   │                   state machine. See 10-quality.md.
│   │   ├── media_cleanup_worker.ex ← Nebu.Workers.MediaCleanupWorker
│   │   │                   (Story 8a-media-cleanup-worker): a DAILY (`"0 2 * * *"`, 02:00 UTC)
│   │   │                   Oban-cron retention purge on the SAME shared `:media_cleanup` queue
│   │   │                   Story 2e's `MediaReservedUploadCleanupWorker` already established —
│   │   │                   the first worker in this family to reuse an existing queue rather
│   │   │                   than adding a dedicated one (contrast Story 7's deliberately-separate
│   │   │                   `:media_alerts` queue). Hard-deletes `media_files` rows that have sat
│   │   │                   in `:deleted` (Story 6a's `admin_delete/2`) or `:infected` (Story 4b's
│   │   │                   scan worker) past a per-state retention window — `deleted_days: 30` /
│   │   │                   `infected_days: 7`, read from a STATIC `Application.get_env(:nebu,
│   │   │                   :media_cleanup, [])` `config.exs` entry, deliberately NOT yet one of
│   │   │                   Story 9a's admin-configurable `media_config` keys (forward-compat note
│   │   │                   only, not a dependency of this story). Adds the sibling
│   │   │                   `infected -> hard_deleted` guard-table edge to `Nebu.Media.StateMachine`
│   │   │                   (the pre-existing `deleted -> hard_deleted` edge, added by Story 2e,
│   │   │                   was the only one before this story) and a `media_hard_deleted`
│   │   │                   `Nebu.Compliance.AuditWriter.@known_actions` entry (ADR-028 bridge).
│   │   │
│   │   │                   **ADR-032 three-step ordering** (this is the SECOND worker to reach
│   │   │                   `:hard_deleted`, and the FIRST to actually delete the S3 object — Story
│   │   │                   2e's own `:hard_deleted` transition never called `Storage.delete/1`):
│   │   │                   (1) `StateMachine.transition/4` to `:hard_deleted` (the row's
│   │   │                   `uploader_user_id` is nulled INSIDE this call, per `state_machine.ex`'s
│   │   │                   `@sql_update_state_hard_deleted`), then this worker's own
│   │   │                   `hard_deleted_at = NOW()` UPDATE; (2) `Nebu.Media.Storage.delete/1`
│   │   │                   against `storage_key` (404 → treated as `:ok`); (3) only on that
│   │   │                   success, this worker's own `storage_key = NULL` UPDATE; (4) only if
│   │   │                   that UPDATE actually affected a row, the `media_hard_deleted` audit
│   │   │                   entry. A `Storage.delete/1` failure leaves the row exactly as-is
│   │   │                   (state already `:hard_deleted`, `storage_key` still populated) for a
│   │   │                   self-healing "reaper"/completion query (`state = 'hard_deleted' AND
│   │   │                   storage_key IS NOT NULL`, no age bound) run at the end of every tick to
│   │   │                   retry — the completion query never re-invokes `transition/4`, since
│   │   │                   `:hard_deleted` has no outgoing guard-table edges. Per-row isolation:
│   │   │                   each candidate is processed inside its own `rescue`-wrapped block, so
│   │   │                   one row's S3/DB failure never blocks any other row's cleanup in the
│   │   │                   same tick (deliberately not modeled on either `SessionExpiryWorker`'s
│   │   │                   tick-level `rescue` or `MediaReservedUploadCleanupWorker`'s
│   │   │                   `reduce_while`, neither of which actually provides genuine per-row
│   │   │                   isolation).
│   │   │
│   │   │                   **Security-review fix cycle (F-1/MEDIUM, see 10-quality.md):** the
│   │   │                   `:deleted` candidate query as originally specified relied on
│   │   │                   `media_files.deleted_at`, a column NO code path ever populates —
│   │   │                   `admin_delete/2`'s `transition/4` call only sets `state`, never a
│   │   │                   `:deleted`-specific timestamp column (only the `:hard_deleted` target
│   │   │                   has a column-stamping SQL variant). This matched ZERO rows forever in
│   │   │                   production, silently defeating half the worker's purpose, and survived
│   │   │                   ATDD/test-review/CI/code-review because every test's `FakeRepo` seeded
│   │   │                   `deleted_at` directly and filtered on it — presupposing exactly the
│   │   │                   population that doesn't exist. Fixed by deriving `:deleted` row age
│   │   │                   from the append-only `media_state_transitions` ledger instead
│   │   │                   (`MAX(inserted_at) WHERE to_state = 'deleted'`), symmetric with how the
│   │   │                   `:infected` query already worked. A second, orthogonal bug found during
│   │   │                   the same fix cycle (invisible under `FakeRepo`-based testing, which
│   │   │                   never round-trips real SQL): both candidate queries bind `$1` inside
│   │   │                   `($1 || ' days')::interval`, which Postgres/Postgrex resolves as `text`
│   │   │                   — binding the raw Elixir integer crashed every real invocation with
│   │   │                   `DBConnection.EncodeError`; fixed by binding `Integer.to_string/1`
│   │   │                   instead. A new real-DB integration test
│   │   │                   (`media_cleanup_worker_integration_test.exs`, `@moduletag :integration`)
│   │   │                   drives the actual `admin_delete/2 -> StateMachine.transition/4 ->
│   │   │                   perform/1` path against live PostgreSQL, backdating the real ledger
│   │   │                   row's `inserted_at` — the test that would have caught both bugs. See
│   │   │                   10-quality.md.
│   │   ├── media_orphan_detection_worker.ex ← Nebu.Workers.MediaOrphanDetectionWorker
│   │   │                   (Story 8b-orphan-detection-gdpr): an HOURLY (`"0 * * * *"`) Oban-cron
│   │   │                   job on the SAME shared `:media_cleanup` queue as Stories 2e/8a — the
│   │   │                   epic's own established queue-sharing convention (tighter cadence than
│   │   │                   8a's daily purge is unnecessary since nothing destructive happens here).
│   │   │                   DETECTION/REPORTING ONLY — the epic's Review 5 (2026-07-02, R-015)
│   │   │                   retracted this story's original framing that it "solves DSGVO Art. 17
│   │   │                   (Right to Erasure)"; full Art. 17 requires Restriction-of-Processing +
│   │   │                   Vier-Augen-Freigabe (Story 13e, ADR-030, not built in this epic pass).
│   │   │                   The worker structurally never references `Nebu.Media.StateMachine` at
│   │   │                   all (zero aliases/calls, not just zero invocations in tests) — issues
│   │   │                   only `SELECT` statements against `media_files`/`events`, identifying
│   │   │                   `:quarantined` rows older than a configurable `orphaned_hours`
│   │   │                   threshold (default 48, own STATIC `config.exs` value under
│   │   │                   `:nebu, :media_orphan_detection` — deliberately NOT read from
│   │   │                   `Nebu.Media.Config`'s already-landed Story 9a `orphaned_hours=24`
│   │   │                   default, mirroring 8a's own `deleted_days`/`infected_days` divergence
│   │   │                   precedent) that no `events.content` row references via `content.url`,
│   │   │                   `content.avatar_url`, or `content.info.thumbnail_url` (built at query
│   │   │                   time as `mxc://<server_name>/<media_id>` — no stored `mxc_uri` column).
│   │   │                   Known, documented gap: does not check the 2 encrypted-attachment
│   │   │                   fields (`content.file.url`/`content.info.thumbnail_file.url`) that
│   │   │                   ADR-030's full 6-field mxc→room index would cover — that full index is
│   │   │                   Story 13's "Room/space resolution mechanics", out of scope here; safe
│   │   │                   because a human always reviews the candidate report before any action.
│   │   │
│   │   │                   **Query shape — 3 separate `NOT EXISTS`, not one 3-way `OR`
│   │   │                   (closes the epic's "Offene Entscheidung #3"):** `EXPLAIN ANALYZE`
│   │   │                   against a representative `events` table showed the story's own
│   │   │                   originally-specified single-`NOT EXISTS`-with-3-OR-ed-conditions form
│   │   │                   produces an unindexable `Join Filter` — confirmed via `EXPLAIN ANALYZE`
│   │   │                   that even WITH a GIN index present, and even with `enable_seqscan =
│   │   │                   off` forced, Postgres still chose a full `Seq Scan` on `events` (a
│   │   │                   `Join Filter` is evaluated post-join, never pushed down to an index).
│   │   │                   Rewriting as 3 independent `NOT EXISTS` clauses ANDed together
│   │   │                   (De Morgan's-equivalent semantics) lets each check push down as its own
│   │   │                   parameterized `Bitmap Index Scan`; the `content.info.thumbnail_url`
│   │   │                   check specifically uses NESTED containment against the top-level
│   │   │                   `content` column (`content @> '{"info":{"thumbnail_url":"..."}}'`),
│   │   │                   never `content -> 'info' @> '{"thumbnail_url":"..."}'` — the `->`
│   │   │                   extraction form empirically defeats the index entirely. New migration
│   │   │                   `000031_events_content_gin_index` adds
│   │   │                   `CREATE INDEX events_content_gin_idx ON events USING GIN (content
│   │   │                   jsonb_path_ops)` — plain, NOT `CONCURRENTLY` (confirmed
│   │   │                   `Nebu.Release.apply_migration/3` wraps every migration file in a
│   │   │                   `Postgrex.transaction/2` unconditionally, and `CONCURRENTLY` is
│   │   │                   forbidden inside a transaction regardless of which file it's in — no
│   │   │                   per-migration opt-out exists in this project's runner today).
│   │   │
│   │   │                   Writes exactly ONE `Nebu.Compliance.AuditWriter.log/6` entry per run
│   │   │                   (never one per candidate) — action `media_orphan_detection_run`
│   │   │                   (added to `@known_actions`), `actor_user_id:
│   │   │                   "system:media_orphan_detection_worker"` (the story's own draft text
│   │   │                   said `nil`, but `actor_user_id` is a REQUIRED `audit_log` field —
│   │   │                   `nil` would fail changeset validation and silently break the audit
│   │   │                   trail every run; corrected to the established `"system:<worker_name>"`
│   │   │                   convention every other system-initiated worker in this epic already
│   │   │                   uses), metadata `%{"candidate_count" => N, "candidate_media_ids" =>
│   │   │                   [...]}`. No new admin UI (`ui: false`) — surfaced via the existing
│   │   │                   `/audit-log` (`Nebu.Admin.AuditLogLive`) viewer, unchanged. Also sets
│   │   │                   `Logger.metadata(route_template: "cron:media_orphan_detection")` +
│   │   │                   a summary `Logger.info/1` (Review-9/Story 10e's "operational events via
│   │   │                   existing Logger calls" convention). See 10-quality.md.
│   │   ├── media_archive_worker.ex ← Nebu.Workers.MediaArchiveWorker
│   │   │                   (Story 8c-media-archive-worker): a DAILY (`"0 2 * * *"`, SAME slot as
│   │   │                   Story 8a) Oban-cron job on the SAME shared `:media_cleanup` queue,
│   │   │                   operating on a candidate population disjoint from 8a's by construction
│   │   │                   (`state = 'released' AND archived_at IS NULL` vs 8a's `state IN
│   │   │                   ('deleted', 'infected')`). Server-side-copies (`ExAws.S3.
│   │   │                   put_object_copy/5`, `Nebu.Media.Storage.put_object_copy/2`) aged
│   │   │                   `:released` objects into a second, separately-configured "archive"
│   │   │                   bucket UNDER THE SAME `storage_key` (ADR-029: the key is computed once
│   │   │                   at upload time — Story 11c's `compute_key/2` — and never recomputed)
│   │   │                   and stamps `archived_at` — `state` is never touched (ADR-029: "No new
│   │   │                   state for archival"), and the worker structurally never calls
│   │   │                   `Nebu.Media.StateMachine.transition/3` (pinned by a raising fake in its
│   │   │                   own test suite, not just an unasserted absence). `released_
│   │   │                   archive_after_days` (`nil` disables the worker, a pure no-op) and
│   │   │                   `archive_delete_from_primary` gate it via a STATIC
│   │   │                   `Application.get_env(:nebu, :media_archive, [])` `config.exs` entry,
│   │   │                   same not-yet-rewired-to-9a posture as 8a/8b's own config values.
│   │   │
│   │   │                   **ADR-032 copy-then-verify-then-commit ordering:** (1)
│   │   │                   `Storage.put_object_copy/2` against the archive bucket — a failure
│   │   │                   leaves the row completely untouched and propagates `{:error, reason}`
│   │   │                   all the way out of `perform/1` (Oban retries the whole job); (2) only
│   │   │                   after the copy succeeds, `Nebu.Media.DB.commit_archived/1`
│   │   │                   (`UPDATE ... WHERE state = 'released' AND archived_at IS NULL`) — the
│   │   │                   SAME `archived_at IS NULL` predicate is both the candidate query's
│   │   │                   eligibility filter and the commit's sole race/idempotency guard (no
│   │   │                   `SELECT ... FOR UPDATE` needed — Postgres re-evaluates an `UPDATE`'s
│   │   │                   `WHERE` against the just-committed row version once a concurrent
│   │   │                   writer's row lock releases); (3) only if the commit actually won the
│   │   │                   race (`{:ok, :committed}`, not `{:ok, :already_archived}`), a
│   │   │                   `media_archived` `Nebu.Compliance.AuditWriter.@known_actions` entry,
│   │   │                   then — only if `archive_delete_from_primary` — `Storage.delete/1`
│   │   │                   against the primary object (reused unchanged from Story 8a; never
│   │   │                   re-added). Uses `Enum.reduce_while/3` (Story 2e's halt-on-real-error
│   │   │                   convention), NOT Story 8a's per-row `rescue`-and-always-`:ok`
│   │   │                   convention — deliberately, so a genuine copy or commit failure
│   │   │                   surfaces as a job-level `{:error, _}` for Oban to retry, per this
│   │   │                   story's own acceptance tests.
│   │   │
│   │   │                   **Age anchor — `uploaded_at`, not a derived `released_at`:**
│   │   │                   `media_files` has no "became-released-at" column; the threshold is an
│   │   │                   already-resolved millisecond-epoch integer bound directly against
│   │   │                   `uploaded_at` (`Nebu.Media.DB.candidates_for_archive/1`), mirroring
│   │   │                   Story 2e's own `now_ms - ttl_ms` convention — NOT the story's own
│   │   │                   illustrative `uploaded_at < NOW() - ($1 || ' days')::interval`, which
│   │   │                   cannot type-check against the live schema (`uploaded_at` is `BIGINT`
│   │   │                   millisecond-epoch, confirmed against `000001_init.up.sql`, not a
│   │   │                   `TIMESTAMPTZ`).
│   │   │
│   │   │                   **Download-path bucket switch (extends Story 1c):**
│   │   │                   `Nebu.Media.fetch_and_decrypt/3` now picks `Storage.get_from_archive/1`
│   │   │                   when `row.archived_at` is truthy, else the unchanged `Storage.get/1` —
│   │   │                   runs strictly AFTER Story 1c's state-based download gate, so a
│   │   │                   non-`:released` file never reaches this switch at all; both branches
│   │   │                   share the identical decrypt/decompress/error-mapping pipeline (no
│   │   │                   distinguishing status/body between a primary- and archive-bucket read).
│   │   │                   The decrypt pipeline applies `Nebu.Media.Crypto.decrypt/3`, then
│   │   │                   `safe_maybe_gunzip/2` (conditionally decompresses via `:zlib.gunzip/1`
│   │   │                   if `media_files.compressed=true`, per ADR-029 read-path invariant,
│   │   │                   rescuing corrupt gzip as 502), before passing plaintext to download/
│   │   │                   thumbnail handlers. `Nebu.Media.DB.lookup/2`'s `@sql_lookup`/`to_map/1`
│   │   │                   now selects `archived_at`, `compressed` AND (a self-corrected
│   │   │                   pre-existing bug, in-scope of this exact change) the REAL `storage_key`
│   │   │                   column — it used to be hardcoded to `media_id`, silently correct only
│   │   │                   under the default `s3_key_prefix_template`, a dormant bug since Story
│   │   │                   11c introduced non-default templates.
│   │   │
│   │   │                   **Kassandra security review (2026-07-19):** APPROVED, 0 CRIT/HIGH/
│   │   │                   MED/LOW, 2 INFO. Independently re-verified both self-corrected bugs
│   │   │                   above against the live schema/call-graph. Found+the dev fixed one real
│   │   │                   gap during the review itself: `archive_one/1`'s `case` on
│   │   │                   `commit_archived/1` had no clause for its own documented `{:error,
│   │   │                   reason}` return — a `CaseClauseError` risk on a genuine DB failure
│   │   │                   mid-commit (harmless under Oban's own job-crash retry, but an
│   │   │                   undocumented gap) — fixed with an explicit propagating clause + a new
│   │   │                   regression test. See 10-quality.md.
│   │   ├── media_released_auto_delete_worker.ex ← Nebu.Workers.MediaReleasedAutoDeleteWorker
│   │   │                   (Story 8d-released-auto-delete): a DAILY (`"0 2 * * *"`, SAME slot as
│   │   │                   Stories 8a and 8c) Oban-cron job on the SAME shared `:media_cleanup`
│   │   │                   queue, providing the fourth and last data-minimization retention lever
│   │   │                   — soft-deletes (`state := :released -> :deleted` via
│   │   │                   `Nebu.Media.StateMachine.transition/4`, never a direct hard-delete)
│   │   │                   `:released` files past a configurable age window (`Nebu.Media.Config.
│   │   │                   get().released_delete_after_days`, default `nil` = completely disabled).
│   │   │                   Unlike Stories 8a/8b/8c (which touch already-negative/archived states),
│   │   │                   this worker's blast radius is the largest in the epic: a misconfiguration
│   │   │                   could routinely destroy files every room member can still currently see
│   │   │                   and download. `nil` is the only safe default and must mean a strict
│   │   │                   no-op (zero queries beyond reading the config value, zero state
│   │   │                   transitions, zero audit entries when disabled — Story AC3). When enabled
│   │   │                   with a positive-integer days value, eligibility is `state = 'released'`
│   │   │                   and age derived from `media_state_transitions` ledger (same pattern as 8a's
│   │   │                   `:infected`-age derivation — no dedicated `released_at` column exists on
│   │   │                   `media_files`). **This story is explicitly NOT a security feature** —
│   │   │                   per Winston-Review-3 (resolving Offene-Entscheidung #8), it exists purely
│   │   │                   for operator data-minimization convenience, and its UI warning/
│   │   │                   confirmation flow (Story 9b) lives separate to this worker's own narrow
│   │   │                   scope. Per-row isolation (rescue-wrapped, mirroring 8a's precedent,
│   │   │                   _not_ 8c's reduce_while, since a stalled file is not worth silencing
│   │   │                   the entire tick), metadata `%{"released_delete_after_days" => N,
│   │   │                   "released_for_days" => actual_days}`. Audit action
│   │   │                   `media_released_auto_deleted` (registered in `AuditWriter.@known_actions`
│   │   │                   in the same commit — the recurring allowlist footgun, Story 4c pattern).
│   │   │                   See 10-quality.md and the dedicated security review at
│   │   │                   `docs/stories/media-security-admin-control/security-reports/8d-released-
│   │   │                   auto-delete-security-review-2026-07-20.md`.
│   ├── alert_notifier.ex ← Nebu.Media.AlertNotifier (Story 7-admin-notifications,
│   │                   media-security-admin-control epic): a plain `GenServer`, started
│   │                   unconditionally right after `Nebu.PubSub` in `Nebu.Application`'s
│   │                   children list, alongside `Nebu.Media.Config.Supervisor`/
│   │                   `Nebu.Media.StorageConfig.Supervisor`. `init/1` subscribes to
│   │                   Story 5b's existing broad `"media:admin"` `Phoenix.PubSub` topic —
│   │                   NOT a new topic, and NOT a per-`media_id` subscription (does not
│   │                   scale to "every file in the system," mirrors 5b's own guardrail
│   │                   against that anti-pattern). `handle_broadcast/1` (a pure delegate
│   │                   `handle_info/2` calls into, exposed so tests can drive it without a
│   │                   PubSub round-trip) ignores a re-broadcast of the same state
│   │                   (`old_state == new_state`), ignores every `new_state` except
│   │                   `:infected`/`:scan_failed`, and — only when
│   │                   `Nebu.Media.Config.get()[:webhook_url]` is non-nil — enqueues
│   │                   exactly one `Nebu.Workers.MediaAlertWebhookWorker` Oban job via
│   │                   `Oban.insert/1`. Never makes the HTTP call itself; the notifier's
│   │                   only side effect is the enqueue.
│   ├── webhook_delivery.ex ← Nebu.Media.WebhookDelivery (Story 7-admin-notifications):
│   │                   thin Finch wrapper, the production default for
│   │                   `Nebu.Workers.MediaAlertWebhookWorker`'s `:media_webhook_http_module`
│   │                   seam. Reuses the existing `Nebu.Media.Finch` pool
│   │                   (`Nebu.Media.HttpFetch` already starts/uses it) — no second Finch
│   │                   pool. **Kassandra security review (2026-07-19) found+fixed a HIGH
│   │                   finding here, closing a forward-carry mandate Story 9a's own
│   │                   security review had explicitly recorded for this story:**
│   │                   `webhook_url` is SSRF-validated once, at admin config-SAVE time
│   │                   (`Nebu.Media.Config`'s `validate_value/2` → `Nebu.Media.SSRF.check/1`),
│   │                   but the webhook itself can fire arbitrarily long afterward (only on
│   │                   the next `:infected`/`scan_failed` event) — an unbounded window for
│   │                   a DNS-rebinding attack to repoint the saved hostname at
│   │                   `169.254.169.254`/`127.0.0.1`/an internal service after the save-time
│   │                   check already passed. `post/2` now calls
│   │                   `Nebu.Media.SSRF.checked_target/1` immediately before every
│   │                   `Finch.request/2` — re-resolving and re-validating at send time, not
│   │                   trusting the stale save-time check. Since `webhook_url` is always
│   │                   `https://` (enforced by `Nebu.Media.Config`), IP-pinning the
│   │                   connection (the mitigation `HttpFetch` applies for `http`) doesn't
│   │                   apply — SNI/cert validation requires keeping the hostname in the
│   │                   URL, the same residual-window caveat `HttpFetch` already documents
│   │                   for its own `https` branch. `Finch.request/2` never auto-follows
│   │                   redirects, so "no unvalidated redirects" (the other half of the
│   │                   9a-recorded mandate) needed no code change. See 10-quality.md.
│   ├── config.ex     ← Nebu.Media.Config (Story 9a, media-security-admin-control epic):
│   │                   GenServer + ETS `:protected` cache + Erlang `:pg` cluster-aware invalidation
│   │                   for admin-configurable media policy values (ADR-027, dedicated table separate
│   │                   from server_config per ADR-027's rationale — media_config writes never trigger
│   │                   OIDC/logging cache invalidation). Public API: `get/0` returns map of 15 policy
│   │                   keys — 9a's original 10 (max_upload_size_bytes, max_file_size_bytes,
│   │                   max_pending_per_user, max_stall_ms, deleted_days, infected_days,
│   │                   orphaned_hours, webhook_url, released_delete_after_days, mime_denylist)
│   │                   plus Story 10c's 4 alert-threshold keys (clamav_down_alert_minutes,
│   │                   signature_stale_alert_hours, backlog_depth_alert_threshold,
│   │                   scan_failed_rate_alert_pct) plus Story 10d's `scan_kill_switch`
│   │                   (default `"fail_closed"`, values `"fail_open"`/`"fail_closed"` only) —
│   │                   DB-override merged with config.exs defaults, per-key type coercion
│   │                   (string → integer, or passthrough for the two string-enum keys
│   │                   mime_denylist/scan_kill_switch). `upsert/3` (key, value,
│   │                   actor) is sole write path: validates per-key (non-negative integers; webhook_url
│   │                   requires https + Nebu.Media.SSRF.check/1; mime_denylist requires comma-separated
│   │                   plausible MIME-type prefixes), writes to media_config table (RLS-gated), logs
│   │                   media_config_updated audit entry, broadcasts `:invalidate_media_config` via
│   │                   `:pg` to peer nodes. 60s TTL fallback ensures stale security-relevant values
│   │                   (MIME denylist, upload/scan limits) are not served indefinitely on broadcast
│   │                   miss. Mirrors Nebu.Web.OidcConfig's exact pattern (ETS + :pg + TTL), adapted
│   │                   for media domain (separate instance, table, group, cache key).
│   ├── mime_denylist.ex ← Nebu.Media.mime_denylist_rejected?/1 (Story 9c, media-security-admin-control
│   │                   epic; wired by Story 2b). Public API: `mime_denylist_rejected?(content_type)` takes a resolved
│   │                   Content-Type string and returns `true` if the type matches an admin-configured
│   │                   denied prefix, else `false`. Private helper `parse_mime_denylist/1` parses the
│   │                   comma-separated MIME-type prefix list from `Nebu.Media.Config.get/0` on each
│   │                   invocation (no local caching — Config's ETS/`:pg`/TTL cache is the sole cache
│   │                   layer, ADR-020). Matching is prefix-based, case-insensitive on the denylist
│   │                   side (prefixes lowercased after trim, per Kassandra security review MEDIUM-1b
│   │                   fix), case-sensitive on the caller-supplied content_type side per explicit
│   │                   story directive (mirroring the identical behavior of `@blocked_upload_types`
│   │                   in `upload/1`). Defense-in-depth alongside ClamAV scan (Story 3/4): this
│   │                   enforces a synchronous **policy** gate at upload-time (no-category admission);
│   │                   ClamAV is an asynchronous **content** gate (byte-level malware scan). Both remain
│   │                   active independently. Story 2b's `Nebu.Media.upload_async/3` wires this
│   │                   function immediately after Content-Type resolution and before the size-limit
│   │                   check, IN ADDITION TO (not instead of) the pre-existing hardcoded
│   │                   `@blocked_upload_types` list also enforced on this path (code-review fix,
│   │                   2026-07-14 — the async route initially omitted that hardcoded XSS-vector
│   │                   blocklist that the sync `upload/1` path already enforced; both lists now run
│   │                   independently on both upload paths).
│   ├── config_supervisor.ex ← Nebu.Media.Config.Supervisor (Story 9a, media-security-admin-control epic):
│   │                   bespoke Supervisor wrapping Nebu.Media.Config GenServer with `:transient`
│   │                   restart strategy (non-standard vs. usual bare-`:permanent`-child convention;
│   │                   documented deviation verified correct by code review, not regressed via
│   │                   Nebu.Matrix.MigrationsGrantTest precedent). Wired into Nebu.Application.
│   ├── storage_config.ex ← Nebu.Media.StorageConfig (Stories 11a + 11b + 11c, media-security-admin-control
│   │                   epic): GenServer + ETS `:protected` cache + `:pg` cluster-aware invalidation
│   │                   (60s TTL fallback) for admin-configurable S3/MinIO storage TARGET config —
│   │                   mirrors Nebu.Media.Config's (Story 9a) exact pattern but is its OWN table
│   │                   (`media_storage_config`, singleton row, `CHECK (id = 1)`), OWN ETS table
│   │                   (`:nebu_media_storage_config`), OWN `:pg` group (deliberately NOT sharing 9a's
│   │                   cache/table — a rare, security-sensitive invalidation domain must not couple to
│   │                   media_config's hot per-upload/scan-limit invalidation traffic, ADR-027's
│   │                   separation rationale applied a second time; NOT itself an ADR-027 artifact).
│   │                   Field catalog: endpoint, bucket, region, use_ssl, access_key, secret_key,
│   │                   s3_key_prefix_template, archive_bucket, iam_endpoint, sts_endpoint (latter
│   │                   two gained DB-override support via migration 000037, story
│   │                   bugfix-add-sts-iam-endpoints-to-admin-ui — previously env-only).
│   │                   Per-field precedence: DB value (if
│   │                   saved) > `NEBU_MINIO_*`/`NEBU_S3_REGION` env-var fallback (preserving the
│   │                   pre-existing boot-time `_FILE`-then-plain Docker-secret precedence from
│   │                   `server/config/runtime.exs`) > compiled default. `access_key`/`secret_key` are
│   │                   encrypted at rest via `Nebu.Web.SecretBox` (AES-256-GCM, key =
│   │                   SHA-256(NEBU_INTERNAL_SECRET), fail-closed) — the SAME primitive already used
│   │                   for `server_config.oidc_client_secret` and the Matrix session store's encrypted
│   │                   refresh token, reused here rather than a fourth AES call site (`Nebu.Web` is
│   │                   shared infra per CLAUDE.md, so this is not an ADR-020 cross-domain violation).
│   │                   Encrypt/decrypt runs in the CALLER's process (`build_columns/1`/`resolved/0`),
│   │                   never inside the supervised GenServer's state — the ETS cache holds only
│   │                   ciphertext + raw env values, so the always-running holder never caches a
│   │                   decrypted secret. `get/0` returns the merged config with secrets MASKED
│   │                   (`"••••" <> last 4 plaintext chars`); only `get_for_connection/0` returns
│   │                   plaintext, and it had ZERO production callers in 11a (deferred to 11b+ wiring
│   │                   an actual S3 client). `upsert/2` is the sole write path; logs a
│   │                   `media_storage_config_updated` audit entry via `Nebu.Compliance.AuditWriter`
│   │                   naming only which field names changed, never values (secret or not). Does NOT
│   │                   rewire `Nebu.Media.Storage`'s existing `ExAws.S3` boot-time wiring — explicitly
│   │                   out of scope, left for follow-up. (11b additions: `persisted_target/0` —
│   │                   returns `{:ok, %{endpoint: ..., bucket: ...}}` when a media_storage_config row
│   │                   has ever been saved, or `:fresh` if none exists — the AC4 orphan-risk-gate
│   │                   baseline for MediaSettingsController, deliberately NOT get/0's env-var-merged
│   │                   view since a fresh config must never gate regardless of env-var defaults.
│   │                   (bugfix-add-sts-iam-endpoints-to-admin-ui adds the analogous
│   │                   `persisted_iam_sts/0` — same pattern, raw DB-only row for the
│   │                   `iam_endpoint`/`sts_endpoint` columns, used by MediaSettingsController to tell
│   │                   "a genuine DB override exists for this field" apart from "the merged view is
│   │                   non-blank purely from an env var," which decides whether blanking the field in
│   │                   the admin form should clear the DB override (`NULL`) or be a no-op.)
│   │                   `test_connection/1` — accepts a candidate map, validates the endpoint has no
│   │                   `http://`/`https://` scheme prefix (SSRF/transport-downgrade guard,
│   │                   returning `{:error, :invalid_endpoint}` before any request), resolves blank
│   │                   secrets against the stored secret server-side (never round-tripping plaintext
│   │                   to the caller), calls `ExAws.S3.head_bucket/1` via the
│   │                   `:media_storage_test_connection_fun` test seam (production default: real call),
│   │                   and returns `:ok` or `{:error, reason}` without persisting.) (11c additions:
│   │                   `validate_template/1` — validates admin-configured `s3_key_prefix_template`
│   │                   strings (mandatory `{media_id}`, five allowed placeholders total, rejects
│   │                   unbalanced braces, unrecognized tokens, path-escaping like `..`, leading `/`,
│   │                   or literal `//`), called from `upsert/1` before DB write to enforce templates
│   │                   are valid at config-save time; `compute_key/2` — pure interpolation function
│   │                   that replaces placeholders with runtime values (media_id, server_name, year/month/day
│   │                   from upload DateTime). Wired by Story 2b (`Nebu.Media.store_and_quarantine/7`,
│   │                   its only sanctioned call site) — reads `get().s3_key_prefix_template` and captures
│   │                   `DateTime.utc_now()` at the call site immediately before `Storage.put/2`; the
│   │                   default (unconfigured) "{media_id}" template interpolates to the identical flat
│   │                   key the pre-2b/11c fallback already used, so wiring introduced no behavior change
│   │                   until an admin configures a non-default template. Per-segment path-escaping check validates
│   │                   literal skeleton after stripping placeholder spans.) Security review (Kassandra, 11a):
│   │                   CLEAN, 0 CRITICAL/HIGH; 1 MEDIUM (endpoint/archive_bucket/use_ssl stored with zero
│   │                   private-IP-range SSRF validation — forward-looking carry, see 10-quality.md) + 3 LOW.
│   │                   Security review (Kassandra, 11c): CLEAN, 0 CRITICAL/HIGH; 2 LOW (compute_key/2
│   │                   trusts runtime-substituted values; no length/charset cap on template itself —
│   │                   forward-carried to Story 2b) + 3 INFO.
│   ├── storage_config_supervisor.ex ← Nebu.Media.StorageConfig.Supervisor (Story 11a,
│   │                   media-security-admin-control epic): mirrors Nebu.Media.Config.Supervisor's
│   │                   `:transient`-restart shape exactly (dedicated child Supervisor,
│   │                   `raw_start_link/1` MFA to avoid `start_link/1 → Supervisor.restart_child`
│   │                   re-entrancy deadlock, `max_restarts: 1000, max_seconds: 5`). Wired into
│   │                   Nebu.Application's unconditional children list alongside
│   │                   Nebu.Media.Config.Supervisor, giving the cache holder genuine crash-recovery
│   │                   resilience rather than a bare best-effort start.
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
│   ├── db.ex          ← Nebu.Admin.DB — inline-SQL helper queries (ADR-018) for admin-facing read-only
│   │                   concerns over shared tables. Per the precedent established in Story 5a, the only
│   │                   namespace allowed to read media_files directly for admin context — this is not a
│   │                   Nebu.Media public-API call (ADR-020). Functions: `get_server_config/0` and
│   │                   `upsert_server_config/1` for server_config reads/writes; `count_media_with_storage_key/0`
│   │                   (Story 11b) counts media_files rows with non-null storage_key (for the AC4
│   │                   orphan-risk-gate check in MediaSettingsController.save_storage/2, enforced
│   │                   at the read site only, never returning plaintext).
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
│   ├── media_settings_controller.ex ← Nebu.Admin.MediaSettingsController (stories 9b-media-settings-ui
│   │                   + 11b-storage-ui-test-connection, media-security-admin-control epic): Media
│   │                   Policy Settings page. GET /admin/media/settings (renders form pre-filled via
│   │                   Nebu.Media.Config.get/0 + Nebu.Media.StorageConfig.get/0), POST
│   │                   /admin/media/settings (9b: validates + persists media policy via
│   │                   Nebu.Media.Config.upsert/3 — the ONLY calls this module makes into Nebu.Media
│   │                   for config, ADR-020). Deliberately a plain Phoenix Controller, NOT a
│   │                   LiveView — mirrors LogsController's/ConfigController's exact conventions
│   │                   (plug-based :require_admin, module-attribute {min,max} @bounds tuples per
│   │                   numeric field, two-phase validate_and_normalize/1-then-persist so a single
│   │                   invalid field blocks ALL 9 keys from being written). Exposes 9 of
│   │                   Nebu.Media.Config's 10-key catalog (mime_denylist is Story 9c's scope, not
│   │                   this page's). webhook_url validation reuses Nebu.Media.SSRF.check/1 verbatim
│   │                   (HTTPS + private/loopback/link-local block), never re-derived. A save that
│   │                   changes released_delete_after_days from unset (nil) to a concrete value
│   │                   surfaces an additional, stronger :warning flash (role="alert") alongside the
│   │                   generic success flash, since it newly enables automatic deletion of
│   │                   previously-indefinite released media. changed_keys/2 diffs the validated
│   │                   submission against Nebu.Media.Config.get/0's current catalog and persists
│   │                   only the keys that actually changed (code-review MINOR-2 fix) — avoids
│   │                   audit-log noise and "default pinning" (a no-op resubmit no longer freezes
│   │                   every key's value against future config.exs default changes); the resulting
│   │                   per-key persist/2 loop is NOT atomic across a multi-key DB failure — a
│   │                   documented, accepted limitation (no cross-call transaction seam exists in
│   │                   Nebu.Media.Config's ADR-020 public API by design). actor_id/1 attributes each
│   │                   media_config_updated audit entry to the real admin's session-derived,
│   │                   server-verified identity (matrix_user_id/sub), never a client-suppliable
│   │                   value — closes 9a's own carried-forward audit-authz note. Nav grouping is
│   │                   now complete: the three flat media nav leaves (media-explorer, media-settings,
│   │                   media-health) are grouped under one "Media" parent in layouts.ex, closing the
│   │                   "Story 0" debt. (11b: extends `index/2` to also assign
│   │                   `:storage_config` for a second, independent form section on the same page;
│   │                   adds two new actions: `save_storage/2` — plain-Elixir validation (no
│   │                   Changeset, ADR-018), persists exclusively via Nebu.Media.StorageConfig.upsert/2
│   │                   (ADR-020); blank secrets mean "leave unchanged," persisted via
│   │                   changed_storage_keys/1 diffs; gated by AC4's orphan-risk warning when
│   │                   endpoint/bucket changes while Nebu.Admin.DB.count_media_with_storage_key/0 > 0,
│   │                   requiring a `confirm_orphan_risk` checkbox on re-render before second save
│   │                   persists; `test_connection/2` — calls StorageConfig.test_connection/1 against
│   │                   submitted-but-unsaved candidate values, renders success/failure with fixed
│   │                   messages (raw errors logged server-side, never interpolated into response),
│   │                   never persists.).
│   ├── media_settings_html.ex   ← Nebu.Admin.MediaSettingsHTML — embed_templates wrapper for
│   │                   MediaSettingsController, same shape as ConfigHTML/LogsConfigHTML.
│   │   └── templates/media_settings/index.html.heex — form template; every input wrapped in an
│   │                   explicit <label for="..."> (belt-and-suspenders with matching id=); success
│   │                   flash role="status", error/warning flash role="alert"; CSRF token via
│   │                   Plug.CSRFProtection.get_csrf_token/0.
│   ├── media_live.ex   ← Nebu.Admin.MediaLive (new, story 5a-admin-media-table, media-security-admin-
│   │                   control epic): the epic's admin-facing entry point — GET /admin/media, read-
│   │                   only filterable/keyset-paginated table over media_files (ADR-018 inline SQL,
│   │                   same @sql-module-attribute pattern as AuditLogLive, no Ecto schema). URL is the
│   │                   single source of truth for filters/cursor via handle_params/3 + push_patch/2
│   │                   (mirrors LogsLive.TraceMap's contract exactly — unlike the shared Nebu.Admin.
│   │                   LogsLive monitoring page, this module has no live_isolated/3 test suite to
│   │                   protect, so exporting handle_params/3 has no sibling-suite-breaking cost here).
│   │                   A `cursor` URL param distinguishes a fresh page-1 fetch (absent, stream reset)
│   │                   from a "Weitere laden" continuation (present, stream_insert append) — a
│   │                   bookmarked cursor URL reproduces exactly that ONE keyset page, not every prior
│   │                   page. Rows fetched via stream(:media_rows, ..., dom_id: &row_dom_id/1), same
│   │                   established pattern as Nebu.Admin.LogsLive's own @request-rows stream — this
│   │                   story only sets the stream up correctly; story 5b (below) adds the live
│   │                   stream_insert/3 on "media:admin" PubSub broadcasts. Multi-select state (socket.assigns.selected_ids, a plain MapSet keyed
│   │                   by media_id, never row index) + "select all matching filter" (same WHERE clause,
│   │                   no LIMIT, capped at 5,000 with a truncation notice) exist purely so Story 6d's
│   │                   bulk-cohort actions can attach to this table later — this story renders only the
│   │                   selection-count action-bar shell, no actual bulk action. Identity column shows
│   │                   the real `filename` (Story 2b's migration 000025, nullable — client-supplied via
│   │                   the async-upload `?filename=` query param) when present, falling back to Media-ID
│   │                   (`<code>`) when NULL; Uploader renders "—" when `uploader_user_id` is NULL
│   │                   (nulled by Story 2e's migration 000027 on the reserved→hard_deleted cleanup
│   │                   transition). ClamAV signature column reads `scan_metadata->>'clamav_signature'`
│   │                   — the actual key `Nebu.Workers.MediaScanWorker.infect/2` (Story 4b) persists, a
│   │                   schema-reality correction against the story's own earlier `'signature'`-key draft
│   │                   (same class of drift as file_path→storage_key, Review 3). State badges use 5 new
│   │                   `media-badge--*` @layer components classes (server/assets/css/app.css +
│   │                   tailwind.config.js color tokens) per DESIGN.md's media-state vocabulary — filled
│   │                   pills, dark #1c1917 text, icon + always-distinct text label (color never the only
│   │                   signal). "Weitere laden" focus-move (AC10 accessibility) is server-driven via
│   │                   push_event("focus_media_row", ...) consumed by a new, small MediaLoadMoreFocus
│   │                   phx-hook in app.js (mirrors the existing SessionKeepalive/WarRoomPill hooks'
│   │                   minimal shape) — the aria-live announcer text is pushed unconditionally either
│   │                   way. Gated by the SAME on_mount: {Nebu.Admin.Auth, :require_admin} every other
│   │                   remaining admin LiveView uses (router.ex, inside live_session :admin) — no
│   │                   bespoke authz. Row actions (Block/Unblock/Delete/Rescan) added by Story 6a below
│   │                   (Override is still 6c — out of scope here). Nav: the media nav grouping is now
│   │                   complete — all three media pages are grouped under one "Media" parent
│   │                   (media-explorer child) in layouts.ex.
│   ├── media_attention_badge.ex   ← Nebu.Admin.MediaAttentionBadge (new, story 5b-live-updates-nav-
│   │                   badges, media-security-admin-control epic): shared cross-cutting helper
│   │                   (subscribe/0, initial_count/0, classify/1, apply_transition/3) mirroring
│   │                   WarRoomIndicator's own "every remaining admin LiveView calls this from its own
│   │                   mount/3 + handle_info/2" shape exactly. Wired into all 6 admin_live_session
│   │                   LiveViews (MediaLive, DashboardLive, AuditLogLive, LogsLive, LogsLive.TraceMap,
│   │                   LogsLive.WarRoom) — 5b's own story draft undercounted this set at 3 (LogsLive +
│   │                   sub-pages only); corrected against the live router.ex during dev-story, since
│   │                   Dashboard/AuditLog already carry the identical WarRoomIndicator precedent.
│   │                   initial_count/0 is one inline `COUNT(*) WHERE state = ANY($1::media_state[])`
│   │                   per mount over the 3-state attention set (:quarantined/:scan_failed/:infected);
│   │                   every subsequent broadcast adjusts the assigned integer via classify/1's delta,
│   │                   zero DB round-trips per event (ADR-018 — no new maintained-counter table).
│   │                   `Nebu.Media.StateMachine.transition/4` (server/lib/nebu/media/state_machine.ex)
│   │                   is the SOLE broadcaster: after every successful transition's transaction
│   │                   commits, it publishes {:media_state_transition, media_id, from_state, to_state}
│   │                   on a NEW topic, "media:admin" — deliberately additional to, not a replacement
│   │                   for, Story 2d/4b's existing 3-tuple broadcast on "media:#{media_id}" (changing
│   │                   that existing topic's payload shape would silently break
│   │                   Nebu.Media.DownloadStall's strict 3-tuple receive match). MediaLive's own
│   │                   handle_info/2 additionally tracks socket.assigns.visible_media_ids (a MapSet
│   │                   reset/extended alongside handle_params/3's stream reset/append) so a broadcast
│   │                   for a media_id outside the current page/filter is a pure no-op — no per-row
│   │                   PubSub subscription (would not scale past ~50 visible rows), one broad topic
│   │                   only. A visible row's broadcast triggers one fresh re-fetch by media_id
│   │                   (fetch_row_by_id/1) rather than trusting the broadcast payload for the row's
│   │                   other columns, then stream_insert/3 patches just that row. layouts.ex renders
│   │                   the count as a small numeric badge on the "Media Explorer" child nav item
│   │                   (grouped under the "Media" parent), with aria-hidden number + sr-only accessible
│   │                   text + role="status", mirroring the war_room_active dot/pill's own accessible-
│   │                   name-equivalent pattern — nil on any
│   │                   page that hasn't wired this module (today's dead-render Users/Rooms/Spaces/
│   │                   Config controllers), which is the correct, in-scope behavior (no aria-live
│   │                   polling façade on pages with no persistent process, per this story's own
│   │                   Guardrails).
│   ├── media.ex admin_* / media_live.ex row actions ← Story 6a-routine-state-actions
│   │                   (media-security-admin-control epic): the first admin-facing WRITE path on top
│   │                   of 5a's read-only table. Four new `Nebu.Media` public functions —
│   │                   `admin_block/3`, `admin_unblock/2`, `admin_delete/2`, `admin_rescan/2` — are the
│   │                   ONLY entry points `Nebu.Admin.MediaLive` may call (ADR-020); each does exactly
│   │                   two things: drive `media_files.state` through `StateMachine.transition/4` (never
│   │                   a raw UPDATE), then bridge the admin-driven event into `audit_log` via
│   │                   `Nebu.Compliance.AuditWriter.log/6` (4c's audit-bridge pattern, ADR-028) — a new
│   │                   `:media_audit_writer_module` seam, same `:nebu_http`-namespace convention as
│   │                   every other Nebu.Media boundary. Block/Unblock check `Nebu.Media.DB.lookup_state/1`
│   │                   (new, media-id-only state lookup) BEFORE calling `transition/4` to short-circuit
│   │                   an idempotent `{:ok, :already_blocked | :already_released}` no-op (no new
│   │                   `media_state_transitions`/`audit_log` row) — the guard table has no
│   │                   `X -> X` self-edge, so this idempotency is an admin-UX decision layered on top,
│   │                   not a state-machine change. Rescan does NOT call `transition/4` at all (Story
│   │                   4b's worker performs the real `quarantined -> scanning` transition once it picks
│   │                   the job up) — it validates eligibility then re-enqueues via the EXISTING
│   │                   `:media_scan_enqueue_module` seam (`Nebu.Media.ScanEnqueue`, already a real
│   │                   `Oban.insert/1` since 4b), reusing the same call site `create_and_store/6`/
│   │                   `store_and_quarantine/7` already use rather than a second enqueue path. Delete
│   │                   only ever requests `:deleted` (soft) — never `:hard_deleted` (Story 8's scope).
│   │                   `AuditWriter.@known_actions` gained `media_blocked`/`media_unblocked`/
│   │                   `media_deleted`/`media_rescanned` in the same commit (the known allowlist
│   │                   gotcha 4c's own story flags). `MediaLive` gained 6 `handle_event` clauses
│   │                   (block/unblock/open_delete_confirm/cancel_delete_confirm/confirm_delete/rescan),
│   │                   conditional row-action buttons keyed off each row's `state`, a CSP-safe Delete
│   │                   confirm modal (no `window.confirm`, no `position: fixed` per the epic's explicit
│   │                   constraint — `absolute inset-0` instead) with a new `MediaDeleteConfirmModal`
│   │                   `app.js` hook (real Tab/Shift+Tab focus trap + focus-return-to-trigger, unlike
│   │                   `LogsLive.DetailPanel`'s side panel which explicitly documents NOT implementing a
│   │                   full trap), and a dedicated `@action_flash` assign (this admin layout does not
│   │                   render Phoenix's built-in `@flash` — mirrors `TraceMap`'s own `@cascade_flash`/
│   │                   `WarRoom`'s own `@copy_toast` precedent). A successful Block/Unblock/Delete's own
│   │                   row-badge update arrives for free via the EXISTING 5b `"media:admin"` broadcast +
│   │                   `handle_info/2` — no new manual `stream_insert/3` needed for those three; Rescan
│   │                   deliberately leaves the row's state untouched (AC4).
│   │                   **Trace-Map integration (Story 10e):** Block/Unblock/Delete/Rescan/Infected-Override
│   │                   `handle_event/3` handlers additionally call `Logger.info/2` with `route_template: "/admin/media"`
│   │                   and `request_id: media_id`, ALONGSIDE (never instead of) the existing `AuditWriter.log/6` call
│   │                   — a second, independent operational-visibility channel (diagnostic) distinct from the immutable
│   │                   compliance audit trail. No new `AuditWriter.@known_actions` entry (per Dev Agent Guardrails) — admin
│   │                   action logging is a Log Store feature, not a compliance audit feature. These logs group under the
│   │                   pre-existing `/admin` Trace-Map domain and correlate with media-scan logs via the same `media_id`
│   │                   `request_id`, so an operator can trace a file's entire lifecycle (upload → scan → admin action) as
│   │                   one grouped row inside a War Room diagnostic session.
│   │
│   │                   **Design/architecture-gap fix (migration `000029_media_state_transitions_actor_id_text`):**
│   │                   `StateMachine.transition/4`'s `{:admin, admin_id}` actor persists `admin_id` into
│   │                   `media_state_transitions.actor_id`, which was a `UUID` column since Story 1a. No
│   │                   UUID-shaped user/admin identity exists anywhere in this app's real data model —
│   │                   admin sessions carry a Matrix-ID string (the same shape `audit_log.actor_user_id`/
│   │                   `users.user_id` already use). 6a is the first real caller of `{:admin, admin_id}`
│   │                   (1b's own tests only ever used a synthetic `Ecto.UUID.generate()`), so this
│   │                   mismatch had never been exercised end-to-end before — it would have crashed every
│   │                   real admin action with `Ecto.UUID.dump!/1`'s `ArgumentError`. Fixed by changing
│   │                   `actor_id` to `TEXT` (verified zero-risk: all existing rows had `actor_id = NULL`)
│   │                   and dropping `state_machine.ex`'s `Ecto.UUID` dump!/load! round-trip — `actor_id`
│   │                   now passes through as a plain string, matching `audit_log.actor_user_id`'s shape.
│   │
│   │                   **Security-review fix (`:admin_blocked` anonymity, ADR-026):** 6a's security
│   │                   review found `download_gate(:admin_blocked)` (Story 1c) still returned a
│   │                   distinguishable `451` status (only the errcode/body were anonymized) — the exact
│   │                   dormant gap 1c's own security review had flagged as "live once the mutation path
│   │                   ships." Fixed to a byte-identical `404 + M_NOT_FOUND`, matching
│   │                   `:infected`/`:deleted`/`:hard_deleted` exactly — see the `download_gate` entry
│   │                   above and ADR-026's 2026-07-19 correction.
│   ├── media_live/detail.ex   ← Nebu.Admin.MediaLive.Detail (new, story 6b-file-detail-storage-
│   │                   summary, media-security-admin-control epic): read-only per-file detail view,
│   │                   GET /admin/media/:media_id, reached from a row in 5a's table (the "Ansehen"
│   │                   link already existed there before 6b landed). Deliberately the one Story-6
│   │                   slice that writes nothing — no state transitions, no audit_log entries, no
│   │                   action buttons of its own (6a's Block/Unblock/Delete/Rescan controls stay on
│   │                   5a's table; this page may host them later, wiring is out of scope here).
│   │                   `media_id` arrives as a static router path segment (no handle_params/3, no
│   │                   URL-driven filter state — mirrors `LogsLive.WarRoom`'s own `:show` action
│   │                   contract, unlike 5a's own `handle_params/3`-driven table). Three inline
│   │                   `@sql_*` SELECT-only queries (ADR-018), same module-attribute convention as
│   │                   `AuditLogLive`: the file's own row, its full `media_state_transitions` history
│   │                   ordered `inserted_at ASC` (oldest first — "what happened to this file", not
│   │                   insertion order), and a page-level (not per-file) storage-summary aggregate —
│   │                   `SUM(file_size)`/`COUNT(*)` grouped by `state` across ALL `media_files` rows,
│   │                   for `:released` ("Active") and `:deleted` ("Pending Hard-Delete") only. Postgres's
│   │                   `SUM(bigint)` promotes to `numeric` (Postgrex `%Decimal{}`) — the query casts
│   │                   `::bigint` explicitly so the result stays a plain integer through
│   │                   `MediaLive.humanize_bytes/1`'s `is_integer/1` guard; `GROUP BY` silently omits a
│   │                   state with zero matching rows (no zero-row returned), so the Elixir-side
│   │                   `reduce_storage_totals/1` (a small `def`, deliberately pure/DB-free so it is
│   │                   directly unit-testable against a real shared-database-safe `[]`/partial input)
│   │                   defaults both buckets to `{0, 0}`. `MediaLive` itself gained three `def` (not
│   │                   `defp`) accessors — `badge_group/1`, `badge_label/1`, `humanize_bytes/1` — purely
│   │                   so this module reuses 5a's exact badge palette and byte-rounding logic instead
│   │                   of re-deriving it a second time; no behavior change to `MediaLive` itself.
│   │                   Actor display matches `AuditLogLive`'s own convention exactly: `actor_type =
│   │                   :system` renders "System", `:admin` renders the raw `actor_id` (a Matrix-ID
│   │                   string since 6a's own `000029` migration) — no name/email join, no new
│   │                   cross-domain lookup. `compressed` renders as a plain yes/no badge, never a
│   │                   percentage/ratio — the schema (Story 1a/12) only ever persisted the flag, never
│   │                   a compressed-on-disk byte count, so there is no ratio to compute without
│   │                   re-fetching and decrypting the stored object, which this read-only view does
│   │                   not do. ClamAV signature block renders only when `scan_metadata` contains the
│   │                   REAL key `MediaScanWorker.infect/2` (Story 4b) persists —
│   │                   `"clamav_signature"`, not the plain `"signature"` this story's own AC7 text
│   │                   originally assumed (same class of schema-reality drift 5a already corrected for
│   │                   its own table view; caught and fixed during this story's own code-review, story
│   │                   file corrected in place). An unknown `media_id` renders a not-found state, never
│   │                   a crash; a `media_id` with zero transitions renders an explicit empty-history
│   │                   message. Kassandra's security review independently re-verified both self-found
│   │                   fixes above (the `clamav_signature` key and the `::bigint` cast) rather than
│   │                   taking them at face value, and re-confirmed two standing watch-flags remain
│   │                   correctly open, not closed by this story: BOND.md's file-content-preview/
│   │                   cross-origin-asset item (this page renders no preview/thumbnail at all) and 1b's
│   │                   own I-1 metadata-stored-XSS note (this page fetches `metadata` but never renders
│   │                   it).
│   ├── media_health_live.ex   ← Nebu.Admin.MediaHealthLive (new, story 10a-scan-stats-rollup,
│   │                   media-security-admin-control epic): first slice of the Scan Health & Alerts
│   │                   Dashboard, GET /admin/media/health (declared BEFORE `/media/:media_id` in the
│   │                   router — a "health" segment would otherwise dispatch as `:media_id`, same
│   │                   ordering gotcha as `/rooms/new` vs `/rooms/:room_id`). Reads ONLY the new
│   │                   `media_scan_stats` rollup table (epic's own explicit requirement — never a
│   │                   live query over `media_state_transitions`' full history). `mount/3` runs three
│   │                   inline-SQL reads once (no `handle_params/3` — no query/path params): the latest
│   │                   row (current-hour throughput/duration/backlog), a rolling-24-row aggregate, and
│   │                   a rolling-168-row aggregate; error rate is `SUM(scans_failed) / NULLIF(SUM(
│   │                   scans_total), 0)` computed in SQL and guarded to `nil` (never a literal NaN/
│   │                   Infinity) when the denominator is 0. A LiveView from the start (not a plain
│   │                   controller+template) even though this story's own content needs no PubSub/
│   │                   handle_info/2 — Stories 10b (ClamAV status)/10c (`media_alerts`) attach further,
│   │                   genuinely live sections to this SAME module, and every other admin dashboard-
│   │                   style page combining several sections (`LogsLive`, `AuditLogLive`, `MediaLive`)
│   │                   is already a LiveView, not a controller+template pair. Child nav item (`key=
│   │                   "media-health"`) under the "Media" parent — the earlier "Story 0 nested parent"
│   │                   debt (flagged by stories 5a/9b) is now closed via the admin-media-nav-grouping
│   │                   bug fix. **Story 10b adds**
│   │                   (media-security-admin-control epic): a new "ClamAV-Status" section displaying
│   │                   clamd connectivity and freshclam signature-database age; wired via
│   │                   `Nebu.Admin.ClamAVStatusIndicator` (see entry below) poll-tick in mount/3 +
│   │                   handle_info/2, 2s refresh interval.
│   ├── media_scan_stats_rollup_worker.ex ← Nebu.Workers.MediaScanStatsRollupWorker (new, story
│   │                   10a-scan-stats-rollup): hourly Oban-cron (`"5 * * * *"`, 5 minutes past the
│   │                   hour so the just-completed hour's `media_state_transitions` writes have
│   │                   committed), shared `:media_cleanup` queue (a periodic aggregation job, not a
│   │                   per-upload scan job — does not belong on `:media_scan`). Aggregates the single
│   │                   most recently fully-elapsed hour into `media_scan_stats` via `INSERT ... ON
│   │                   CONFLICT (window_start) DO UPDATE` (idempotent re-run, AC4). **Bug found+fixed
│   │                   vs. the story's own illustrative SQL** (verified empirically against a real
│   │                   Postgres before trusting the draft, per this epic's recurring gotcha pattern):
│   │                   the story's duration CTE filtered `WHERE to_state = 'scanning'` BEFORE computing
│   │                   `LEAD(...) OVER (PARTITION BY media_id ORDER BY inserted_at)` — since SQL
│   │                   evaluates `WHERE` before window functions run, this narrows each media_id's
│   │                   partition down to its `:scanning` rows alone, so `LEAD` always returned `NULL`
│   │                   (confirmed: `sample_count = 0` for every fixture, always). Fixed by computing
│   │                   `LEAD` over the FULL unfiltered per-media_id transition sequence first, filtering
│   │                   to scanning-starts/terminal-ends only in an outer step — this also naturally
│   │                   excludes `:scan_failed` retry sequences from the duration stats without special-
│   │                   casing. `scans_released`/`scans_infected` are keyed on `from_state = 'scanning'`
│   │                   (not `to_state` alone) — confirmed against the real `MediaScanWorker` that
│   │                   `release/2`/`infect/2` only ever transition FROM `:scanning`, deliberately
│   │                   excluding non-scan-driven releases (6c's `infected -> released` override, 6a's
│   │                   `admin_blocked -> released` unblock) from this scan-throughput rollup.
│   │                   `backlog_depth` is a separate, non-windowed live snapshot (`COUNT(*) FROM
│   │                   media_files WHERE state IN ('quarantined', 'scanning')`), never filtered by
│   │                   `inserted_at`. Accepts an optional `%{"window_start" => iso8601}` job-arg
│   │                   override (test-only seam, found necessary empirically — a real-clock "previous
│   │                   complete hour" is not actually isolated from this codebase's multi-minute
│   │                   `:integration` suite, which routinely straddles a real hour boundary; unrelated
│   │                   tests driving the real `MediaScanWorker`/`StateMachine` with default `NOW()`
│   │                   timestamps can retroactively land inside whatever this worker later computes as
│   │                   "the previous hour"); unreachable from any HTTP/admin endpoint in production —
│   │                   this codebase has no generic arbitrary-job-enqueue surface. New migration
│   │                   `000032_media_scan_stats` (BIGSERIAL PK, UNIQUE index on `window_start`,
│   │                   `scans_total` a `GENERATED ALWAYS AS (...) STORED` column so it can never drift
│   │                   out of sync with the three counts that define it). Unlike
│   │                   `media_state_transitions` (ADR-031, append-only ledger), `media_scan_stats` is a
│   │                   derived, re-computable rollup this worker is expected to `UPDATE` via upsert —
│   │                   deliberately NO append-only trigger, NO RLS, full DML grant to `nebu_app`
│   │                   (reviewed: holds only aggregate hourly counts, no PII, so this is a legitimate
│   │                   exception to the epic's "Missing RLS on new tables" recurring pattern, not an
│   │                   oversight).
│   ├── clamav_status_indicator.ex   ← Nebu.Admin.ClamAVStatusIndicator (new, story
│   │                   10b-clamav-status-freshclam-age, media-security-admin-control epic): shared,
│   │                   poll-based helper module (mirroring `Nebu.Admin.WarRoomIndicator` and
│   │                   `MediaAttentionBadge`'s shape) that surfaces ClamAV daemon connectivity status
│   │                   and freshclam virus-signature database staleness. Drives the "ClamAV-Status"
│   │                   section on `/admin/media/health` (10a's LiveView page). Three public functions:
│   │                   `status/0` returns a struct `%{healthy: bool, changed_at: DateTime.t(),
│   │                   signature_age: {:ok, DateTime.t()} | {:error, term()}}` sourced from
│   │                   `Nebu.Media.ClamAV.health_check/0` (AC1/AC2) and `signature_info/0` (AC3 — new
│   │                   public function on ClamAV GenServer added by this story, sends `zVERSION\0`
│   │                   over the same managed TCP connection, parses the C-asctime build date of the
│   │                   signature database, verified against the actual `clamav/clamav:stable` container
│   │                   before shipping); `schedule/0` reschedules a Process.send_after tick; and
│   │                   `assign_status/2` updates four LiveView assigns:
│   │                   `:clamav_healthy`/`:clamav_down_since`/`:clamav_signature_age`/
│   │                   `:clamav_signature_stale?`. The staleness threshold (AC4, `:clamav_signature_stale?`
│   │                   assignment) uses second-level precision: `DateTime.diff(..., :second) > 48*3600`
│   │                   (NOT an hour-truncated diff, which would fail the AC5 boundary test). Degrades
│   │                   gracefully when ClamAV client isn't running at all (`Process.whereis/1` guard).
│   │                   Call order matters (documented in `status/0`): `signature_info/0` must execute
│   │                   BEFORE `health_check/0` in the same tick because `zVERSION\0` exercises the
│   │                   socket and discovers peer-closed connections; the real clamd peer closes after
│   │                   every VERSION reply, and `health_check/0` would otherwise reuse the dead socket
│   │                   and report stale `healthy: true` for one tick. Accepts `signature_age` parse
│   │                   failures (bad/malformed reply) and renders `:unknown` state rather than crashing
│   │                   (AT6 — never raise, never misclassify as stale). Config: new key
│   │                   `signature_max_age_hours: 48` added to `config.exs` alongside existing
│   │                   `Nebu.Media.ClamAV` address/max_file_size_bytes keys. **Story 10c adds**
│   │                   (media-security-admin-control epic): the open-alerts section to the same
│   │                   `/admin/media/health` page, rendering `Nebu.Media.Alerts.list_open/0` critical
│   │                   before warning, most-recent first (see alert entries below).
│   │   ├── media_alerts_checker_worker.ex ← Nebu.Workers.MediaAlertsCheckerWorker (new, story
│   │   │                   10c-media-alerts-triggers, media-security-admin-control epic): a
│   │   │                   per-minute Oban-cron (`"* * * * *"`) job on the SAME shared `:media_cleanup`
│   │   │                   queue (alongside 2e/8a/8b/8c's workers) that evaluates four scan-pipeline
│   │   │                   health conditions against `Nebu.Media.Config`-backed thresholds and
│   │   │                   opens/auto-resolves `media_alerts` rows. AC1: migration
│   │   │                   `000033_media_alerts` creates the `media_alerts` table (BIGSERIAL PK, id,
│   │   │                   alert_type TEXT CHECK (...), severity ENUM ('warning', 'critical'),
│   │   │                   message, media_id nullable, condition_metadata JSONB, opened_at, resolved_at)
│   │   │                   with a partial-unique index on (alert_type, COALESCE(media_id, sentinel))
│   │   │                   WHERE resolved_at IS NULL (belt-and-suspenders for AC5's idempotent
│   │   │                   check-and-open, preventing two concurrent runs from duplicating the same
│   │   │                   open alert). Unlike `media_state_transitions` (ADR-031), this table is
│   │   │                   operational-monitoring, NOT append-only: rows are opened and later *updated
│   │   │                   in place* (resolved_at set) by the same periodic checker, with zero
│   │   │                   immutability trigger and zero RLS insert/update-mutable split (Dev Agent
│   │   │                   Guardrails explicitly forbid copying 1a's pattern here). AC2: four
│   │   │                   independently-evaluated conditions: `clamav_disconnected` (critical,
│   │   │                   threshold `clamav_down_alert_minutes`: 5) — reads `Nebu.Media.ClamAV.
│   │   │                   health_check/0` via injected seam; `signature_stale` (warning, threshold
│   │   │                   `signature_stale_alert_hours`: 48) — reads `ClamAV.signature_info/0`;
│   │   │                   `backlog_depth` (warning, threshold `backlog_depth_alert_threshold`: 500)
│   │   │                   — queried from `media_scan_stats` latest row; `scan_failed_rate` (warning,
│   │   │                   threshold `scan_failed_rate_alert_pct`: 10) — rolling 1h rate from
│   │   │                   `media_scan_stats`. AC3: auto-resolve (sets `resolved_at = NOW()`) when the
│   │   │                   condition clears on the next run; no admin "dismiss" action. AC5:
│   │   │                   `INSERT ... WHERE NOT EXISTS` (fast-path idempotency check) + `ON CONFLICT
│   │   │                   (...) WHERE resolved_at IS NULL DO NOTHING` (real-concurrency guard) ensures
│   │   │                   at most one open alert per condition type even under genuinely concurrent
│   │   │                   (Task.async-spawned) checker runs. Each threshold is read via
│   │   │                   `Nebu.Media.Config.get/0` at run time (never hardcoded), so an admin can
│   │   │                   retune sensitivity without redeploying.
│   │   ├── alerts.ex       ← Nebu.Media.Alerts (new, story 10c-media-alerts-triggers, media-security-
│   │   │                   admin-control epic): minimal public-API seam (ADR-020) wrapping the
│   │   │                   `media_alerts` table read. Single public function: `list_open/0` returns
│   │   │                   rows WHERE `resolved_at IS NULL` ORDER BY `CASE severity WHEN 'critical'
│   │   │                   THEN 0 ELSE 1 END, opened_at DESC` — critical-first, most-recent-first
│   │   │                   ordering; exposed to `Nebu.Admin.MediaHealthLive` which is the sole
│   │   │                   caller and renders them above the 10a/10b metrics sections. No direct
│   │   │                   media_alerts table queries from anywhere else in the codebase.
│   ├── media.ex admin_override_infected/3 ← Story 6c-infected-override (media-security-admin-control
│   │                   epic): the deliberate, narrow exception to 1b's "infected is terminal beyond
│   │                   `-> deleted`" rule — a ClamAV false positive is a real operational scenario, and
│   │                   this is the ONE sanctioned way out of it. The guard table (`state_machine.ex`)
│   │                   gains exactly one new edge, `infected: [:deleted] -> [:deleted, :released]` —
│   │                   additive only, the existing `infected -> deleted` edge is unchanged, and no other
│   │                   key's edge list changes. Unlike 6a's four routine actions (gated by the standard
│   │                   `on_mount(:require_admin)` session alone), this action is gated by a SECOND,
│   │                   distinct grant — `users.media_admin_override` (new migration
│   │                   `000030_media_admin_override_role`, a plain boolean column deliberately
│   │                   orthogonal to `users.system_role`, not a fourth enum value) — so a user needs
│   │                   BOTH `system_role = 'instance_admin'` (to reach `/admin/media` at all) AND
│   │                   `media_admin_override = true` (to see/use this one action); provisioning the
│   │                   flag itself is out of scope (direct DB access only, for now). Because the shared
│   │                   guard table already legitimately allows `:scanning`/`:admin_blocked`/
│   │                   `:scan_failed -> :released` for OTHER callers (clean-scan, 6a's own unblock, 4a's
│   │                   manual clear), `admin_override_infected/3` cannot rely on `allowed?/2` alone to
│   │                   enforce "only FROM `:infected`" — this story's own ATDD caught exactly that gap
│   │                   (an override attempt against a genuinely-`:scanning` file wrongly succeeded before
│   │                   the fix), so a dedicated `check_infected/1` guard runs between the state lookup
│   │                   and `transition/4`. Order of checks is deliberate: `validate_reason/1` (mandatory,
│   │                   non-blank, non-whitespace, trimmed — server-side, never merely UI-required) and
│   │                   `authorize_override/1` (the grant re-check, independent of whatever
│   │                   `MediaLive` already hid) both run BEFORE any state lookup, so neither a blank
│   │                   reason nor an unauthorized caller ever reaches the guard table, AND — verified
│   │                   during security review — `authorize_override/1`'s query is keyed only on
│   │                   `admin_id`, never `media_id`, so an unauthorized admin's rejection carries no
│   │                   information at all about the target file's existence or state. On success, the
│   │                   event bridges into `audit_log` via the same `Nebu.Compliance.AuditWriter.log/6`
│   │                   pattern 6a/4c established, with `metadata` carrying the admin's `reason` and the
│   │                   `original_signature` read from `media_files.scan_metadata["clamav_signature"]`
│   │                   (the real key 4b's worker persists, not the epic narrative's `"signature"`
│   │                   shorthand — same drift class 6b already corrected for its own read path).
│   │                   `AuditWriter.@known_actions` gained `media_infected_override` in the same commit
│   │                   (the same allowlist gotcha 4c/6a/6b's stories all independently flag). `MediaLive`
│   │                   gained a conditional Override button (rendered only for a session holding the
│   │                   grant, on `:infected` rows only) and a second CSP-safe confirm modal —
│   │                   `MediaOverrideConfirmModal`, same `app.js` Tab-trap/focus-return family as 6a's
│   │                   Delete modal — carrying the epic's literal escalated warning text ("Diese Datei
│   │                   wurde als Malware erkannt. Freigabe erfolgt auf eigene Verantwortung.") plus a
│   │                   mandatory reason textarea whose submit button is disabled while the trimmed
│   │                   reason is empty (a `phx-change`-tracked client affordance only; the real
│   │                   enforcement is `validate_reason/1`'s server-side check, unaffected by the UI
│   │                   state). This disabled-button wiring, once added, required its own follow-up fix:
│   │                   a `:disabled` element is excluded from native Tab order, so the Tab-trap's
│   │                   tracked "last focusable" element could never actually receive focus while the
│   │                   button was disabled — the trap's `focusable` query now excludes `:disabled`
│   │                   elements explicitly, closing a focus-trap leak that would otherwise let Tab escape
│   │                   the modal whenever it opened with an empty reason (its default state).
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

> **Room-scoped account data (story `room-account-data-and-read-markers`):** migration 000039 adds
> `user_room_account_data` keyed `(user_id, room_id, type)` (verbatim TEXT `content_json`, monotonic
> `stream_pos` from a sequence, FKs to `users`/`rooms` with `ON DELETE CASCADE`).
> `Nebu.Matrix.RoomAccountDataStore` (plain module, inline SQL, ADR-018/020) backs `PUT/GET
> /user/{userId}/rooms/{roomId}/account_data/{type}` and `POST /rooms/{roomId}/read_markers`
> (`m.fully_read`); both live in `Nebu.Web.Router.Protected`. `/sync` (`do_sync/1`) reads the position
> from the suffix of the `since` token (`<core token>.<pos>`), fills `rooms.join.<id>.account_data.events`
> via `Nebu.Matrix.Http.sync_response/3`, adds account-data-only rooms and appends the new position to
> `next_batch`. `Nebu.Web.Plugs.JsonBody` + `Nebu.Web.Plugs.RawBodyReader` keep the raw body for
> byte-exact storage and map `RequestTooLargeError` to 413 for account-data routes;
> `EventDispatcher.Server.ensure_room_member!/2` is shared with `send_receipt/2`. GDPR erasure deletes the
> rows in `UserDeletion`. Design: `docs/architecture/08-concepts.md` (Account Data).

> **Room tags (story `room-tags`):** `GET/PUT/DELETE /user/{userId}/rooms/{roomId}/tags[/{tag}]` in
> `Nebu.Web.Router.Protected` store tags in the room account data event `m.tag` of
> `Nebu.Matrix.RoomAccountDataStore` (no new table, no migration). Tag writes use the new atomic
> `RoomAccountDataStore.update/4` (read-modify-write in one transaction under the per-user advisory lock, caps
> and `notify_sync` as in `put/4`). `Nebu.Web.Plugs.RawBodyReader` gains `room_tags_shape?/1`,
> `opaque_content_shape?/1` and `opaque_content_put?/1` (shared by `JsonBody` and `RequestLogger`, router-identical
> segment normalization). /sync delivery and GDPR erasure are inherited from room account data. Design:
> `docs/architecture/08-concepts.md` (Room tags).

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
`get_mutual_rooms` (MSC2666 shared rooms intersection for two users, paginated, new),
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

> **`get_mutual_rooms` handler (MSC2666, new):** `Nebu.Matrix.EventDispatcher.Server.get_mutual_rooms/4` is the
> in-process entry point for `GET /_matrix/client/v1/mutual_rooms` (stable, CS API v1.19+) and its unstable alias
> `GET /_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms`. Query param `user_id=@other:server` identifies
> the target user. Key design decisions:
>
> 1. **No Room GenServer involvement** - pure direct-DB read. Calls `Nebu.Matrix.Room.DB.get_rooms_for_user/1` (the same
>    function `/sync`'s initial-sync path already uses) once for the authenticated caller and once for the target `user_id`,
>    then computes `MapSet.intersection/2` to yield only rooms both share, sorted by room_id.
>
> 2. **Pagination via `Nebu.Matrix.PageToken`** - windows the intersection result using offset-based pagination.
>    Stable cursor: `Nebu.Matrix.PageToken.encode("mr1:", offset)` (prefix "mr1:" prevents replay against space hierarchy
>    tokens which use "h1:"). Empty next_batch signals end.
>
> 3. **Behavioral dual-mode (stable vs. unstable)** - the stable v1 endpoint always returns a paginated response
>    (`joined: [...]`, `next_batch: "..." | null`). The unstable MSC2666 endpoint, for historical compatibility with
>    the original unstable behavior, NEVER paginates (always returns complete `joined` list, `next_batch` field absent).
>    Same handler, different route/response envelope per spec era.
>
> 4. **Rate limiting** - shared RateLimit tier `mutual_rooms` (120 req/min, burst 30). Rate limit bucket is keyed by
>    source IP only, a pre-existing design property across all tiers (`/login`, `/sync`, `/mutual_rooms`, etc., all
>    draw from one ETS bucket per IP) — flagged during security review as a known architectural limitation for
>    follow-up (per-tier isolation not scope of this story).

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Project Structure & Boundaries, §Complete Project Directory Structure; Story 9-19 (room_moderation.go, sync.go, event_dispatcher/server.ex, forgotten_rooms migration); Story 9-22 (per-device sync tokens, device_id in proto); Story 9-24 (GlobalAccountDataDB interface, ListGlobalAccountData, top-level account_data in syncResponse); Story 9-25 (syntheticNextBatch helper, syntheticBatchSeq atomic counter, sinceToken param removed from buildResponseFromBufferedEvents); Story 9-27 (upgrade_room/2 full Matrix §11.35.1 flow, GRPC.RPCError error handling, archive_room_atomic, terminate_child, try/rescue failure audit); Story 9-28 (GetRelations RPC, unsigned_relations field on Event, attach_thread_aggregations, fetch_events_by_relation, count_thread_children, event_in_room?, migration 000042); Story 9-29 (base /relations/{eventId} route, three-segment /{relType}/{eventType} route, dir/event_type/recurse/from query params, prev_batch in response, fetch_events_by_relation/5 dynamic WHERE builder); Story 11-3 (SearchMessages gRPC handler, proto extension, delegated search_db_module pattern, offset-cap security fix); Story 11-4 (search.go Gateway handler, SearchCoreClient consumer interface, §11.14.1 response shape, gRPC error mapping); Story 11-5 (NewUserRateLimiter middleware, per-user 10 req/min for /search, retry_after_ms in body); Story 11-8 (GetEvent RPC, event.go Go handler, fetch_event/2 DB function, core_grpc.pb.ex rpc :GetEvent + rpc :GetRelations bug fix); Story 11-9 (health/info.go NewInfoHandler, Nebu.BuildInfo module, GET /info on pubMux + health server, Admin UI footer via page_data.go SetBuildInfo/newPageData, ErrorMode on PageData, Dockerfile ARG/ldflags injection, docker-compose.yml build args); Story 11-10 (ClaimMappingHandler + ClaimMappingPageData + ClaimMappingConfig in claim_mapping.go, claim-mapping.html template, ClaimSelectionHandler atomic claim persistence in auth.go, ServerConfigReader LoadClaimMapping/SaveClaimMapping extension, FormatUserIDFromClaims signature refactor in grpc/metadata.go, JWTMiddleware userIDClaimLoader param, LoginHandler per-request claim resolution, migration 000044 claim mapping defaults seed); Story 12.16 (media/internal/auth middleware - TokenVerifier interface + fail-closed nil guard; media/internal/config handler; CSP + Cross-Origin-Resource-Policy headers on download/thumbnail; v1 authenticated routes in main.go); oidc-middleware-migration (nebu_http: NebuHttp.Plugs.OidcPlug Bearer-token validation, NebuHttp.JwksCache GenServer with TTL refresh + last-known-good, NebuHttp.Router.Protected /_matrix sub-router — built + unit-tested, NOT yet on the live request path; live cutover owned by matrix-api-migration); media-gateway-migration (nebu_http: NebuHttp.Media + Crypto/DB/Membership/Storage/HttpFetch/SSRF submodules + NebuHttp.Router.Media serving /_matrix/media/v3/* behind OidcPlug; media access-control now a local room_members SQL call replacing the gRPC CheckMembership RPC; ExAws.S3/MinIO storage with Finch pool in NebuHttp.Application; AES-256-GCM at-rest encryption per ADR-011; SSRF-guarded + rate-limited preview_url fetch; inline SQL per ADR-018; replaces the standalone Go media service)_
