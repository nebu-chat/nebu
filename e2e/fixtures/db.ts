/**
 * Direct-DB seed helpers for E2E scenarios (enhanced-logging/trace-map-leitstand,
 * test-review MAJOR-1 fix).
 *
 * WHY THIS EXISTS: some scenarios need operational_logs entries at WARN/ERROR
 * level, which real black-box HTTP traffic cannot deterministically produce
 * (Nebu.Web.Plugs.RequestLogger only ever logs the request/response line at
 * INFO — see logs-monitoring.steps.ts's header comment for the long-standing
 * rationale). The originally-proposed test-only HTTP backdoor
 * (`POST /admin/_test/operational-logs`) was REJECTED by the test-review gate
 * (and would be rejected by Kassandra on a security_review:required story):
 * NO test-only HTTP routes in server code, ever. Instead this helper follows
 * the in-repo raw-SQL precedent from
 * server/test/nebu/admin/logs_live_test.exs's AC12 describe block (direct
 * INSERT INTO operational_logs) — story amendment "AC12 log injection"
 * (docs/stories/enhanced-logging/trace-map-leitstand.md, Story Amendments)
 * explicitly approves this mechanism.
 *
 * Seeded entries are picked up by the page's MOUNT-TIME LogStore history read
 * (scenarios reload/navigate after seeding) — no PubSub broadcast needed.
 *
 * ## Connection mechanism
 *
 * Two paths, in order of preference:
 *   1. `NEBU_DB_URL` set (CI) -> host `psql` against that URL.
 *   2. Fallback (local dev stack via `make dev`) -> `docker exec` psql inside
 *      the compose postgres container (default `nebu-postgres-1`, matching
 *      this repo's compose project name — override via `NEBU_DB_CONTAINER`).
 *      Inside the container, `psql -U nebu -d nebu` authenticates via the
 *      local socket (peer/trust), no password plumbing needed.
 *
 * Synchronous `execSync` is deliberate: seeds are tiny single-row INSERTs and
 * the caller must not proceed until the row is committed.
 */

import { execFileSync, execSync } from 'node:child_process';

const DB_URL = process.env.NEBU_DB_URL;
const DB_CONTAINER = process.env.NEBU_DB_CONTAINER ?? 'nebu-postgres-1';

/** Escape a value for inclusion in a single-quoted SQL literal. */
function sqlLiteral(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

/**
 * Run one SQL statement against the stack's postgres.
 *
 * NOTE on quoting: the statement is passed through a shell. Values built by
 * this module contain only route templates / level names / simple messages
 * (no `$`, backticks, or double quotes) — callers must not feed arbitrary
 * user input through this helper.
 */
function runSql(sql: string): void {
  const cmd = DB_URL
    ? `psql "${DB_URL}" -v ON_ERROR_STOP=1 -c ${JSON.stringify(sql)}`
    : `docker exec ${DB_CONTAINER} psql -U nebu -d nebu -v ON_ERROR_STOP=1 -c ${JSON.stringify(sql)}`;

  try {
    execSync(cmd, { stdio: 'pipe' });
  } catch (err) {
    throw new Error(
      `[fixtures/db] seeding operational_logs failed (${DB_URL ? 'NEBU_DB_URL' : `docker exec ${DB_CONTAINER}`}): ` +
        `${(err as Error).message}. Is the dev stack running (make dev)?`,
    );
  }
}

/**
 * Insert one operational_logs row directly (schema:
 * server/priv/migrations/000017_operational_logs.up.sql — level/source NOT
 * NULL, message NOT NULL, inserted_at defaults to now() so the row lands
 * inside the Trace Map's 60-second status window immediately).
 */
export function insertOperationalLog(opts: {
  level: 'debug' | 'info' | 'warning' | 'error';
  routeTemplate: string;
  source?: string;
  message?: string;
}): void {
  const source = opts.source ?? 'http';
  const message = opts.message ?? `e2e-seeded ${opts.level} entry (trace-map-leitstand)`;
  const requestId = `req-e2e-seed-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;

  runSql(
    'INSERT INTO operational_logs (level, source, route_template, request_id, message, metadata) VALUES (' +
      [
        sqlLiteral(opts.level),
        sqlLiteral(source),
        sqlLiteral(opts.routeTemplate),
        sqlLiteral(requestId),
        sqlLiteral(message),
        `'{}'::jsonb`,
      ].join(', ') +
      ')',
  );
}

/**
 * Ensure an operational_logs row exists for a REAL, already-performed HTTP
 * request (dev cycle 1 fix for "a request to {string} has been recorded").
 *
 * WHY: `Nebu.Web.Plugs.RequestLogger` always logs the request line at INFO,
 * but INFO persistence is POLICY-GATED (`Nebu.Web.LogStore.should_persist?/1`
 * — `log_collect_info` defaults to FALSE). The entry is always live-BROADCAST
 * but, with the default policy, never written to `operational_logs` — so any
 * page mounted AFTER the request (which reads mount-time history from the DB)
 * can never see it. Scenarios that record traffic and THEN navigate were
 * silently depending on `log_collect_info` having been left enabled.
 *
 * This helper makes the precondition deterministic under ANY policy: after
 * the real black-box request, insert the row it WOULD have persisted (same
 * request_id from the `x-request-id` response header, same route_template,
 * level info) — but only if RequestLogger's own row is not already there
 * (INSERT … WHERE NOT EXISTS), so an INFO-collection-enabled stack does not
 * get duplicates. Same approved mechanism as insertOperationalLog above
 * (story amendment "AC12 log injection" — direct DB seed, no test-only HTTP
 * routes in server code).
 */
export function ensureOperationalLogRow(opts: {
  requestId: string;
  routeTemplate: string;
  level?: 'debug' | 'info' | 'warning' | 'error';
  source?: string;
  message?: string;
}): void {
  const level = opts.level ?? 'info';
  const source = opts.source ?? 'http';
  const message = opts.message ?? `e2e-recorded ${level} request (black-box HTTP hit)`;

  runSql(
    'INSERT INTO operational_logs (level, source, route_template, request_id, message, metadata) ' +
      'SELECT ' +
      [
        sqlLiteral(level),
        sqlLiteral(source),
        sqlLiteral(opts.routeTemplate),
        sqlLiteral(opts.requestId),
        sqlLiteral(message),
        `'{}'::jsonb`,
      ].join(', ') +
      ` WHERE NOT EXISTS (SELECT 1 FROM operational_logs WHERE request_id = ${sqlLiteral(opts.requestId)})`,
  );
}

/**
 * End any still-active war_room_sessions row (scenario cleanup — dev cycle 1).
 *
 * The trace-map war-room-banner scenario starts a REAL session and must not
 * leak it into later scenarios/suite runs: war-room.feature's own start step
 * would hit the "exactly one active session" conflict (AC2 of war-room-mode)
 * and fail. Ended via direct SQL (same mechanism as the seeding helpers
 * above) rather than UI clicks so cleanup can never race the LiveView
 * socket. Note: this skips WarRoomManager.stop_session/1's cache-reload
 * notification — harmless here (only the DB-backed status read matters to
 * tests; the hot-path capture cache self-heals on its periodic reload).
 */
export function endActiveWarRoomSessions(): void {
  runSql(
    "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// enhanced-logging/trace-map-node-controls (ATDD, RED phase) — capture-row and
// per-endpoint-config seeds. Same approved direct-SQL mechanism as above (NO
// test-only HTTP routes, ever). The story's ANSWERED design question 3
// explicitly blesses "seed an about-to-expire capture row via the db.ts
// fixture" as the E2E alternative to waiting out the 5-minute timer.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Run one SQL query and return its raw output (`-t -A`: tuples only,
 * unaligned) — the read-side sibling of runSql for scenario assertions that
 * verify persistence "via a Playwright DB query" (story AC11, Scenario B).
 */
function runSqlQuery(sql: string): string {
  const cmd = DB_URL
    ? `psql "${DB_URL}" -v ON_ERROR_STOP=1 -t -A -c ${JSON.stringify(sql)}`
    : `docker exec ${DB_CONTAINER} psql -U nebu -d nebu -v ON_ERROR_STOP=1 -t -A -c ${JSON.stringify(sql)}`;

  try {
    return execSync(cmd, { stdio: 'pipe' }).toString().trim();
  } catch (err) {
    throw new Error(
      `[fixtures/db] SQL query failed (${DB_URL ? 'NEBU_DB_URL' : `docker exec ${DB_CONTAINER}`}): ` +
        `${(err as Error).message}. Is the dev stack running (make dev)?`,
    );
  }
}

/**
 * Upsert one server_config row (schema: 000001_init.up.sql — key PK, value
 * NOT NULL, set_at BIGINT NOT NULL). Used to seed per-endpoint logging
 * config (`log_min_level_<route>` / `log_retention_days_<route>`, the
 * story's Dev Notes key format) before a scenario mounts the Trace Map.
 */
export function upsertServerConfig(key: string, value: string): void {
  runSql(
    `INSERT INTO server_config (key, value, set_at) VALUES (${sqlLiteral(key)}, ${sqlLiteral(value)}, ` +
      'extract(epoch from now())::bigint) ' +
      'ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at',
  );
  awaitOAuthConfigApplied(key);
}

// ─── oauth-hardening-hygiene (HY1/HY16): the server caches the OAuth switch per node ────────────────
//
// `Nebu.OAuth.Config` serves `oauth_enabled` / `oauth_issuer_url` from a per-node TTL cache
// (`NEBU_OAUTH_CONFIG_CACHE_MS`, default 2 s; the e2e stack keeps the production default on purpose, so e2e
// exercises the cache). A fixture that writes one of these keys therefore waits until the RUNNING server
// reflects the write: `GET /_matrix/client/v1/auth_metadata` answers 200 when OAuth is enabled with a valid
// issuer and 404 otherwise (it is not rate limited, Matrix v1.18). 100 ms interval, 5 s timeout, then it
// fails loudly (a silent timeout would turn into a confusing downstream failure).

const OAUTH_SWITCH_KEYS = new Set(['oauth_enabled', 'oauth_issuer_url']);
const OAUTH_APPLY_TIMEOUT_MS = 5_000;
const OAUTH_APPLY_POLL_MS = 100;
const OAUTH_API_URL = (process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008').replace(/\/+$/, '');

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * `GET /_matrix/client/v1/auth_metadata` as `{ status, issuer }` (`status` 0 when the request itself failed,
 * `issuer` the `issuer` member of a 200 body). Synchronous on purpose (fixtures are synchronous).
 */
function authMetadata(): { status: number; issuer: string | null } {
  const script =
    `fetch(${JSON.stringify(`${OAUTH_API_URL}/_matrix/client/v1/auth_metadata`)})` +
    '.then(async (r) => { let issuer = null; if (r.status === 200) { try { issuer = (await r.json()).issuer ?? null; } catch {} } ' +
    'process.stdout.write(JSON.stringify({ status: r.status, issuer })); })' +
    '.catch(() => process.stdout.write(JSON.stringify({ status: 0, issuer: null })))';
  try {
    const parsed = JSON.parse(execFileSync(process.execPath, ['-e', script], { stdio: 'pipe', timeout: 4_000 }).toString().trim());
    return { status: Number(parsed.status) || 0, issuer: typeof parsed.issuer === 'string' ? parsed.issuer : null };
  } catch {
    return { status: 0, issuer: null };
  }
}

/**
 * What the server must answer once it reflects the stored switch. Enabled with an issuer: 200 AND the advertised
 * `issuer` equals the stored one (both of two valid https issuers answer 200, so the status alone would not notice
 * an issuer change); the issuer validity itself is the server's business (no regex here that could drift from
 * `Nebu.OAuth.Metadata.normalize_issuer/1`: an invalid stored issuer makes the wait fail loudly). Otherwise 404.
 */
function expectedAuthMetadata(): { status: number; issuer: string | null } {
  const enabled = queryServerConfigValue('oauth_enabled') === 'true';
  const issuer = queryServerConfigValue('oauth_issuer_url');
  const stored = issuer === null ? '' : issuer.trim().replace(/\/+$/, '');
  return enabled && stored !== '' ? { status: 200, issuer: stored } : { status: 404, issuer: null };
}

/** Blocks until the server's `auth_metadata` answer reflects the stored `oauth_*` switch; no-op for any other key. */
export function awaitOAuthConfigApplied(key: string): void {
  if (!OAUTH_SWITCH_KEYS.has(key)) return;
  const expected = expectedAuthMetadata();
  const deadline = Date.now() + OAUTH_APPLY_TIMEOUT_MS;
  let last = { status: -1, issuer: null as string | null };
  while (Date.now() < deadline) {
    last = authMetadata();
    if (last.status === expected.status && (expected.issuer === null || last.issuer === expected.issuer)) return;
    sleepSync(OAUTH_APPLY_POLL_MS);
  }
  throw new Error(
    `[fixtures/db] the server did not reflect the ${key} write within ${OAUTH_APPLY_TIMEOUT_MS} ms: ` +
      `GET ${OAUTH_API_URL}/_matrix/client/v1/auth_metadata answered ${last.status} (issuer ${last.issuer ?? 'none'}), ` +
      `expected ${expected.status}${expected.issuer ? ` (issuer ${expected.issuer})` : ''} ` +
      '(per-node config cache NEBU_OAUTH_CONFIG_CACHE_MS, default 2000 ms; is the stack running?)',
  );
}

// ─── oauth-broker / media-config-tolerant-loader: a damaged media_config row ────────────────────────
//
// The Admin form is not the way to damage a stored media setting (the writer validates), the documented break-glass SQL is. These helpers write / read
// / restore ONE media_config row directly (psql as the privileged role; values are test-generated literals, no `$`, double quotes or backticks: the
// SQL goes through a shell). NOTE the server serves media_config from a per-node cache with a 60 s TTL (the direct write sends no invalidation), so a
// scenario that seeds a row must wait for the page to reflect it (see the steps of features/admin/media-config-damaged.feature).

/** The stored value of one media_config row, or null when the row does not exist. */
export function queryMediaConfigRow(key: string): string | null {
  const out = runSqlQuery(`SELECT value FROM media_config WHERE key = ${sqlLiteral(key)}`);
  return out === '' ? null : out;
}

/** Upsert one media_config row with a literal value (also a damaged one, the point of the helper). */
export function setMediaConfigRow(key: string, value: string): void {
  runSql(
    `INSERT INTO media_config (key, value, set_at) VALUES (${sqlLiteral(key)}, ${sqlLiteral(value)}, ` +
      '(extract(epoch from now()) * 1000)::bigint) ' +
      'ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at',
  );
}

/** Put one media_config row back as `queryMediaConfigRow` found it: the original value, or no row when there was none. */
export function restoreMediaConfigRow(key: string, original: string | null): void {
  if (original === null) {
    runSql(`DELETE FROM media_config WHERE key = ${sqlLiteral(key)}`);
  } else {
    setMediaConfigRow(key, original);
  }
}

/** Read one server_config value ('' -> null) for scenario assertions. */
export function queryServerConfigValue(key: string): string | null {
  const out = runSqlQuery(`SELECT value FROM server_config WHERE key = ${sqlLiteral(key)}`);
  return out === '' ? null : out;
}

/**
 * Seed one admin_temporary_captures row (expected migration:
 * 000020_admin_temporary_captures.up.sql — endpoint TEXT PRIMARY KEY,
 * enabled_at/expires_at TIMESTAMPTZ, started_by TEXT). `expiresInSeconds`
 * may be small (about-to-expire, for the auto-revert scenarios) or large
 * (stable capture the scenario disables manually).
 */
export function insertTemporaryCapture(opts: {
  endpoint: string;
  expiresInSeconds: number;
  startedBy?: string;
}): void {
  const startedBy = opts.startedBy ?? '@e2e-operator:test.local';
  const seconds = Math.floor(opts.expiresInSeconds);

  runSql(
    'INSERT INTO admin_temporary_captures (endpoint, enabled_at, expires_at, started_by) VALUES (' +
      [
        sqlLiteral(opts.endpoint),
        'now()',
        `now() + interval '${seconds} seconds'`,
        sqlLiteral(startedBy),
      ].join(', ') +
      ') ON CONFLICT (endpoint) DO UPDATE SET enabled_at = EXCLUDED.enabled_at, ' +
      'expires_at = EXCLUDED.expires_at, started_by = EXCLUDED.started_by',
  );
}

/** Scenario cleanup: remove every temporary-capture row (After-hook hygiene). */
export function clearTemporaryCaptures(): void {
  runSql('DELETE FROM admin_temporary_captures');
}

/**
 * Scenario cleanup: remove the per-endpoint logging config rows the
 * node-controls scenarios write, so later runs re-seed from a clean slate.
 */
export function clearEndpointLoggingConfig(): void {
  runSql(
    "DELETE FROM server_config WHERE key LIKE 'log\\_min\\_level\\_%' OR key LIKE 'log\\_retention\\_days\\_%'",
  );
}

/**
 * Scenario cleanup: remove operational_logs rows for the off-by-default
 * long-polling endpoints. Story amendment 2026-07-07 (errors-always-persist)
 * means an ERROR seeded for one of these routes (e.g. Scenario C2's "an
 * error has been recorded for the /health endpoint") is genuinely
 * PERSISTED and stays inside the Trace Map's own 60-second sliding window
 * (`Nebu.Admin.LogsLive.TraceMapStatus`) for up to 60 real seconds after
 * being written — long enough to leak into a LATER scenario's fresh mount
 * (`initial_entries/0` re-ingests recent history) and falsely show that
 * off endpoint in the "error" state instead of reverting cleanly to "off".
 * Called after EVERY node-controls scenario (the broadest `@node-controls`
 * tag) so this window can never straddle two scenarios.
 */
export function clearOffEndpointOperationalLogs(): void {
  runSql(
    "DELETE FROM operational_logs WHERE route_template IN " +
      "('/_matrix/client/v3/sync', '/admin/keepalive', '/health')",
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// enhanced-logging/war-room-dedicated-page (ATDD, RED phase) — war_room_sessions
// row seeds for the session list/detail E2E scenarios. Same approved direct-SQL
// mechanism as above (NO test-only HTTP routes, ever — war-room-mode's own
// design-decisions.md #6 deliberately has no JSON API to seed through instead).
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Run one SQL query and return its raw rows, one text line per row (columns
 * pipe-separated) — used where a scenario needs a generated id back (e.g. a
 * freshly-seeded session's UUID for building the detail-page URL).
 */
function runSqlReturningId(sql: string): string {
  const cmd = DB_URL
    ? `psql "${DB_URL}" -v ON_ERROR_STOP=1 -t -A -c ${JSON.stringify(sql)}`
    : `docker exec ${DB_CONTAINER} psql -U nebu -d nebu -v ON_ERROR_STOP=1 -t -A -c ${JSON.stringify(sql)}`;

  try {
    // dev-story fix: this `docker exec` psql (even in `-t -A` "tuples only,
    // unaligned" mode) still appends a trailing command-completion tag line
    // ("INSERT 0 1") AFTER the RETURNING row's own value — `.trim()` alone
    // only strips leading/trailing whitespace, not that extra LINE, so a
    // naive `.trim()` previously returned e.g.
    // "3d152aeb-...\nINSERT 0 1" as if it were the id itself (observed live:
    // this corrupted value then failed a *later* uuid-typed INSERT with
    // "invalid input syntax for type uuid"). Only the FIRST line is ever the
    // actual RETURNING value.
    return execSync(cmd, { stdio: 'pipe' }).toString().trim().split('\n')[0].trim();
  } catch (err) {
    throw new Error(
      `[fixtures/db] seeding war_room_sessions failed (${DB_URL ? 'NEBU_DB_URL' : `docker exec ${DB_CONTAINER}`}): ` +
        `${(err as Error).message}. Is the dev stack running (make dev)?`,
    );
  }
}

/** JSONB array literal for a string list, e.g. `["/a","/b"]` -> `'["/a","/b"]'::jsonb`. */
function jsonbArrayLiteral(values: string[]): string {
  return `'${JSON.stringify(values).replace(/'/g, "''")}'::jsonb`;
}

/**
 * Seed one war_room_sessions row directly (schema:
 * server/priv/migrations/000019_war_room_sessions.up.sql, plus this story's
 * own `exclusive_scope JSONB` column addition — Dev Notes Option A).
 * Returns the freshly-generated session UUID.
 *
 * `endedSecondsAgo: undefined` (default) seeds an ACTIVE session
 * (`ended_at IS NULL`) — callers MUST call `endActiveWarRoomSessions()`
 * first (AC2's "exactly one active session" partial unique index would
 * otherwise reject a second active INSERT).
 */
export function insertWarRoomSession(opts: {
  startedBy: string;
  reason: string;
  scope?: string;
  exclusiveScope?: string[];
  maxEntries?: number;
  maxDurationS?: number;
  entriesCollected?: number;
  startedSecondsAgo?: number;
  endedSecondsAgo?: number;
  endedReason?: 'manual_stop' | 'budget_exhausted' | 'duration_exceeded';
}): string {
  const maxEntries = opts.maxEntries ?? 100;
  const maxDurationS = opts.maxDurationS ?? 300;
  const entriesCollected = opts.entriesCollected ?? 0;
  const startedSecondsAgo = opts.startedSecondsAgo ?? 60;

  const endedAtExpr =
    opts.endedSecondsAgo === undefined
      ? 'NULL'
      : `now() - interval '${Math.floor(opts.endedSecondsAgo)} seconds'`;
  const endedReasonExpr =
    opts.endedSecondsAgo === undefined ? 'NULL' : sqlLiteral(opts.endedReason ?? 'manual_stop');
  const scopeExpr = opts.scope ? sqlLiteral(opts.scope) : 'NULL';
  const exclusiveScopeExpr = opts.exclusiveScope ? jsonbArrayLiteral(opts.exclusiveScope) : 'NULL';

  const id = runSqlReturningId(
    'INSERT INTO war_room_sessions ' +
      '(started_by, reason, scope, exclusive_scope, max_entries, max_duration_s, started_at, ' +
      'ended_at, ended_reason, entries_collected) VALUES (' +
      [
        sqlLiteral(opts.startedBy),
        sqlLiteral(opts.reason),
        scopeExpr,
        exclusiveScopeExpr,
        String(maxEntries),
        String(maxDurationS),
        `now() - interval '${Math.floor(startedSecondsAgo)} seconds'`,
        endedAtExpr,
        endedReasonExpr,
        String(entriesCollected),
      ].join(', ') +
      ') RETURNING id',
  );

  if (!id) {
    throw new Error('[fixtures/db] insertWarRoomSession: INSERT did not return an id');
  }

  return id;
}

// ─────────────────────────────────────────────────────────────────────────────
// media-security-admin-control/5a-admin-media-table — media_files row seeds for
// the admin media overview page. Same approved direct-SQL mechanism as above
// (NO test-only HTTP routes, ever): a real "infected" row requires a genuine
// ClamAV EICAR scan round-trip (async, Oban-queued) which is far too slow/
// nondeterministic for a page-render/filter/pagination E2E check — this
// deterministically seeds the ALREADY-SCANNED end state the page renders.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Seed one media_files row directly (schema: server/priv/migrations/
 * 000001_init.up.sql + 000022_media_state_machine_foundation.up.sql +
 * 000025_media_files_filename.up.sql). `mediaId` must be unique per call —
 * callers generate it (e.g. `e2e-media-${Date.now()}`) so it can be located
 * in the DOM afterwards.
 */
export function insertMediaFile(opts: {
  mediaId: string;
  state?:
    | 'reserved'
    | 'quarantined'
    | 'scanning'
    | 'released'
    | 'infected'
    | 'admin_blocked'
    | 'deleted'
    | 'hard_deleted'
    | 'scan_failed';
  contentType?: string;
  fileSize?: number;
  uploaderUserId?: string;
  filename?: string;
  uploadedMsAgo?: number;
  clamavSignature?: string;
  scannedAt?: string;
}): void {
  const state = opts.state ?? 'released';
  const contentType = opts.contentType ?? 'application/octet-stream';
  const fileSize = opts.fileSize ?? 1024;
  const uploaderUserId = opts.uploaderUserId ?? '@e2e-media-operator:test.local';
  const uploadedAgo = opts.uploadedMsAgo ?? 0;
  const filenameExpr = opts.filename ? sqlLiteral(opts.filename) : 'NULL';

  const scanMetadataExpr =
    opts.clamavSignature || opts.scannedAt
      ? `'${JSON.stringify({
          clamav_signature: opts.clamavSignature,
          scanned_at: opts.scannedAt ?? new Date().toISOString(),
        }).replace(/'/g, "''")}'::jsonb`
      : 'NULL';

  runSql(
    'INSERT INTO media_files ' +
      '(media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex, ' +
      'uploader_user_id, uploaded_at, deleted, state, filename, scan_metadata) VALUES (' +
      [
        sqlLiteral(opts.mediaId),
        sqlLiteral('e2e.test.local'),
        sqlLiteral(contentType),
        String(fileSize),
        sqlLiteral('e2eaeskeyhex'),
        sqlLiteral('e2enoncehex'),
        sqlLiteral(uploaderUserId),
        `((extract(epoch from now()) * 1000)::bigint - ${Math.floor(uploadedAgo)})`,
        'false',
        sqlLiteral(state),
        filenameExpr,
        scanMetadataExpr,
      ].join(', ') +
      ') ON CONFLICT (media_id) DO UPDATE SET state = EXCLUDED.state',
  );
}

/** Scenario cleanup: remove every media_files row this fixture seeded (prefix-scoped). */
export function clearMediaFiles(mediaIdPrefix: string): void {
  runSql(`DELETE FROM media_files WHERE media_id LIKE '${mediaIdPrefix}%'`);
}

/** Insert one operational_logs row already tagged with a war_room_id (AC5 detail-view seeding). */
export function insertOperationalLogForWarRoom(
  warRoomId: string,
  opts: {
    level?: 'debug' | 'info' | 'warning' | 'error';
    routeTemplate?: string;
    source?: string;
    message?: string;
  } = {},
): void {
  const level = opts.level ?? 'info';
  const source = opts.source ?? 'http';
  const routeTemplate = opts.routeTemplate ?? '/admin/users';
  const message = opts.message ?? `e2e-seeded war-room-tagged ${level} entry`;
  const requestId = `req-e2e-wr-seed-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;

  runSql(
    'INSERT INTO operational_logs (level, source, route_template, request_id, message, metadata, war_room_id) VALUES (' +
      [
        sqlLiteral(level),
        sqlLiteral(source),
        sqlLiteral(routeTemplate),
        sqlLiteral(requestId),
        sqlLiteral(message),
        `'{}'::jsonb`,
        sqlLiteral(warRoomId),
      ].join(', ') +
      ')',
  );
}

/**
 * Scenario cleanup: remove EVERY war_room_sessions row, unconditionally —
 * no `started_by`/`reason` pattern filter. dev-story fix: `operational_logs
 * .war_room_id` has a FK constraint back to `war_room_sessions` (migration
 * 000019) — the AC3-AC5/AC14 scenarios attach captured log entries to a
 * seeded session via `insertOperationalLogForWarRoom`, so those child rows
 * must be deleted FIRST or this DELETE fails with "still referenced from
 * table operational_logs" (observed live) once any scenario that seeds
 * captured entries has run.
 *
 * Coordinator finding (2026-07-08, round 3): a PATTERN-based filter
 * (`started_by LIKE '@e2e-wr-%' OR reason LIKE 'e2e %'`, this function's
 * previous shape) cannot catch sessions seeded by OTHER feature files that
 * also touch war rooms through the REAL UI with the real logged-in e2e
 * admin's own `started_by`/an arbitrary `reason` (e.g.
 * `logs-trace-map.feature`'s own `@ac6-war-room-banner` scenario) — those
 * leaked into this feature's exact-count/empty-state assertions under a
 * FULL suite run. `war_room_sessions` has no meaning outside E2E fixture
 * data on this stack (dev/test-only), so an unconditional clear is safe:
 * called from a `Before` hook on EVERY scenario in
 * war-room-dedicated-page.feature (see war-room-dedicated-page.steps.ts) —
 * no scenario in that file depends on another scenario's session
 * surviving, each `Given` seeds exactly what it needs.
 */
export function clearWarRoomSessions(): void {
  runSql('DELETE FROM operational_logs WHERE war_room_id IS NOT NULL');
  runSql('DELETE FROM war_room_sessions');
}


// ─── oauth-broker/oauth-metadata-dcr-admin-approval (AC4/AC5) ───────────────────

export type OAuthClientRow = {
  clientId: string;
  status: string;
  approvedBy: string;
  approvedAt: string;
  rejectedBy: string;
  rejectedAt: string;
};

/**
 * Read one `oauth_clients` row by metadata->>'client_name' (migration
 * 000040_oauth_clients_and_auth_metadata). Read-only: the clients themselves are created
 * through the REAL `POST /oauth2/register` endpoint and decided through the REAL Admin UI —
 * this helper only VERIFIES persisted state (Scenario "status in database changes to ...").
 * client_name values are test-generated (alphanumerics + dash), safe for the shell.
 */
export function queryOAuthClientByName(clientName: string): OAuthClientRow | null {
  const out = runSqlQuery(
    "SELECT client_id || '|' || status || '|' || coalesce(approved_by,'') || '|' || " +
      "coalesce(approved_at::text,'') || '|' || coalesce(rejected_by,'') || '|' || " +
      `coalesce(rejected_at::text,'') FROM oauth_clients WHERE metadata->>'client_name' = ${sqlLiteral(clientName)}`,
  );
  if (out === '') return null;
  const [clientId, status, approvedBy, approvedAt, rejectedBy, rejectedAt] = out.split('|');
  return { clientId, status, approvedBy, approvedAt, rejectedBy, rejectedAt };
}

/** Count audit_log rows for an action + target (AC4/AC7 admin audit entries). */
export function countAuditEntries(action: string, targetId: string): number {
  return Number(
    runSqlQuery(
      `SELECT count(*) FROM audit_log WHERE action = ${sqlLiteral(action)} AND target_id = ${sqlLiteral(targetId)}`,
    ),
  );
}

/** Read the `metadata->>'reason'` of the newest audit entry for an action + target ('' if none). */
export function queryAuditReason(action: string, targetId: string): string {
  return runSqlQuery(
    `SELECT coalesce(metadata->>'reason','') FROM audit_log WHERE action = ${sqlLiteral(action)} ` +
      `AND target_id = ${sqlLiteral(targetId)} ORDER BY id DESC LIMIT 1`,
  );
}

/**
 * Count pending registrations whose client_name does NOT start with `namePrefix` (i.e. rows this
 * feature did not create). Read-only; lets a scenario refuse to run on a dirty shared DB instead of
 * deciding foreign registrations.
 */
export function countPendingOAuthClientsOutsideNamePrefix(namePrefix: string): number {
  return Number(
    runSqlQuery(
      "SELECT count(*) FROM oauth_clients WHERE status = 'pending' AND " +
        `coalesce(metadata->>'client_name','') NOT LIKE ${sqlLiteral(namePrefix + '%')}`,
    ),
  );
}

/**
 * Scenario cleanup for registrations this feature created (name-prefix scoped).
 *
 * Connection role (test-review m4): this module connects as the compose/CI superuser `nebu`
 * (`docker exec ... psql -U nebu`, or NEBU_DB_URL=postgresql://nebu@postgres in CI) — NOT as the
 * runtime role `nebu_app`, which may only DELETE `pending` oauth_clients rows (row level security,
 * migration 000040) — this cleanup also removes the approved/rejected ones the scenarios create,
 * which only the privileged role can. Any failure (e.g. NEBU_DB_URL pointing at nebu_app) is
 * deliberately NOT swallowed: runSql throws, so leaked state fails the run loudly instead of
 * silently polluting the DB.
 */
export function clearOAuthClientsByNamePrefix(prefix: string): void {
  runSql(
    `DELETE FROM oauth_clients WHERE metadata->>'client_name' LIKE ${sqlLiteral(prefix + '%')}`,
  );
}

/**
 * Seed `count` PENDING registrations named `<namePrefix>-<n>` (client_id = the same string) directly
 * in the DB and return their client ids. Used ONLY by the pagination scenario: the real
 * `POST /oauth2/register` is rate limited to 50 requests/hour per IP, so more than one page (50)
 * of pending registrations cannot be created through the real endpoint. `namePrefix` must be
 * test-generated (alphanumerics + dash): no `$`, quotes or backticks (the statement goes through a
 * shell, see runSql).
 */
export function insertPendingOAuthClients(namePrefix: string, count: number): string[] {
  const p = sqlLiteral(namePrefix);
  runSql(
    'INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status) ' +
      `SELECT ${p} || '-' || g, jsonb_build_object('client_name', ${p} || '-' || g, ` +
      "'client_uri', 'https://example.com', 'logo_uri', 'https://example.com/logo.png', " +
      `'redirect_uris', jsonb_build_array('https://example.com/callback/' || ${p} || '-' || g)), ` +
      `'e2e-hash-' || ${p} || '-' || g, 'pending' FROM generate_series(1, ${Math.floor(count)}) g`,
  );
  return Array.from({ length: count }, (_, i) => `${namePrefix}-${i + 1}`);
}

// ─── oauth-broker/oauth-client-revocation (P4, AC10) ───────────────────────────────

export type OAuthClientRevocationRow = {
  status: string;
  approvedBy: string;
  revokedBy: string;
  revokedAt: string;
  revokedReason: string;
};

/**
 * Read the decision columns of one `oauth_clients` row by client_id (migration 000046: `revoked_by`,
 * `revoked_at`, `revoked_reason`). Read-only: clients are registered through the REAL DCR endpoint, approved
 * and revoked through the REAL Admin UI; this only VERIFIES the persisted state. `clientId` is a server-generated
 * value (base64url: letters, digits, `-` and `_`), always passed through sqlLiteral.
 */
export function queryOAuthClientRevocation(clientId: string): OAuthClientRevocationRow | null {
  const out = runSqlQuery(
    "SELECT status || '|' || coalesce(approved_by,'') || '|' || coalesce(revoked_by,'') || '|' || " +
      "coalesce(revoked_at::text,'') || '|' || coalesce(revoked_reason,'') " +
      `FROM oauth_clients WHERE client_id = ${sqlLiteral(clientId)}`,
  );
  if (out === '') return null;
  const [status, approvedBy, revokedBy, revokedAt, ...reason] = out.split('|');
  return { status, approvedBy, revokedBy, revokedAt, revokedReason: reason.join('|') };
}

/** Number of `matrix_sessions` rows of an OAuth client (the revocation must leave none). */
export function countOAuthClientSessions(clientId: string): number {
  return Number(runSqlQuery(`SELECT count(*) FROM matrix_sessions WHERE client_id = ${sqlLiteral(clientId)}`));
}

/** The `metadata` JSON text of the newest audit entry for an action + target ('' if none). */
export function queryAuditMetadata(action: string, targetId: string): string {
  return runSqlQuery(
    `SELECT coalesce(metadata::text,'') FROM audit_log WHERE action = ${sqlLiteral(action)} ` +
      `AND target_id = ${sqlLiteral(targetId)} ORDER BY id DESC LIMIT 1`,
  );
}

// ─── oauth-broker/oauth-dcr-abuse-hardening (P2, AC15) ──────────────────────────

/**
 * Seed `count` PENDING registrations named `<namePrefix>-<n>` (client_id = the same string) that are
 * `ageDays` days old, with the stored `client_host` / `client_domain` (migration 000044) set, and
 * return their client ids. Used ONLY by the "older than N days" bulk-removal scenario: the age of a
 * registration cannot be produced through the real `POST /oauth2/register` endpoint (same exception
 * as the pagination scenario, `insertPendingOAuthClients`). Values must be test-generated
 * (alphanumerics, dash, dot): they go through a shell, see runSql.
 */
export function insertAgedPendingOAuthClients(
  namePrefix: string,
  count: number,
  ageDays: number,
  host: string,
  domain: string,
): string[] {
  const p = sqlLiteral(namePrefix);
  runSql(
    'INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status, client_host, client_domain, created_at) ' +
      `SELECT ${p} || '-' || g, jsonb_build_object('client_name', ${p} || '-' || g, ` +
      `'client_uri', 'https://' || ${sqlLiteral(host)}, ` +
      `'redirect_uris', jsonb_build_array('https://' || ${sqlLiteral(host)} || '/callback/' || ${p} || '-' || g)), ` +
      `'e2e-hash-' || ${p} || '-' || g, 'pending', ${sqlLiteral(host)}, ${sqlLiteral(domain)}, ` +
      `now() - (${Math.floor(ageDays)} * interval '1 day') FROM generate_series(1, ${Math.floor(count)}) g`,
  );
  return Array.from({ length: count }, (_, i) => `${namePrefix}-${i + 1}`);
}

/**
 * The `oauth_clients_bulk_removed` audit rows (story oauth-dcr-abuse-hardening, AH9) whose
 * `metadata.client_ids` contains `clientId`: how many there are and the `removed` count of the newest.
 * Read-only.
 */
export function queryBulkRemovalAudit(clientId: string): { count: number; removed: number } {
  const where =
    "action = 'oauth_clients_bulk_removed' AND " +
    `metadata->'client_ids' @> jsonb_build_array(${sqlLiteral(clientId)}::text)`;
  const count = Number(runSqlQuery(`SELECT count(*) FROM audit_log WHERE ${where}`));
  const removed = count === 0 ? 0 : Number(runSqlQuery(`SELECT metadata->>'removed' FROM audit_log WHERE ${where} ORDER BY id DESC LIMIT 1`));
  return { count, removed };
}

// ─── oauth-broker story 2 (oauth-authorize-idp-delegation-code) ──────────────────

/** Remove one server_config key (privileged role; used to restore an absent `oauth_issuer_url`). */
export function deleteServerConfig(key: string): void {
  runSql(`DELETE FROM server_config WHERE key = ${sqlLiteral(key)}`);
  awaitOAuthConfigApplied(key);
}

/**
 * Create an OAuth client row with a FIXED client_id in the given status, the way the database
 * allows it (migration 000040: INSERT only `pending`, then UPDATE the decision). Any earlier row
 * with that id is removed first (privileged role), so a scenario always starts from a known
 * registration. `client_name` = the client id, so `clearOAuthClientsByNamePrefix` also removes it;
 * the FK cascade (migration 000041) removes its authorization requests and codes.
 * Values are test-generated literals (no `$`, double quotes or backticks: the SQL goes through a shell).
 */
export function insertOAuthClient(opts: {
  clientId: string;
  status: 'pending' | 'approved' | 'rejected';
  redirectUris: string[];
  applicationType: 'web' | 'native';
  clientUri?: string;
  /** `client_name` of the registration (default: the client id). A test-generated literal. */
  clientName?: string;
}): void {
  const id = sqlLiteral(opts.clientId);
  const uris = opts.redirectUris.map(sqlLiteral).join(', ');
  runSql(`DELETE FROM oauth_clients WHERE client_id = ${id}`);
  runSql(
    'INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, status) VALUES (' +
      `${id}, jsonb_build_object('client_name', ${opts.clientName !== undefined ? sqlLiteral(opts.clientName) : id}, 'client_uri', ${sqlLiteral(opts.clientUri ?? 'https://client.e2e.example')}, ` +
      `'redirect_uris', jsonb_build_array(${uris}), 'application_type', ${sqlLiteral(opts.applicationType)}, ` +
      "'token_endpoint_auth_method', 'none', 'response_types', jsonb_build_array('code'), " +
      "'grant_types', jsonb_build_array('authorization_code', 'refresh_token')), " +
      `'e2e-hash-' || ${id}, ${sqlLiteral(opts.applicationType)}, 'pending')`,
  );
  if (opts.status === 'approved') {
    runSql(
      "UPDATE oauth_clients SET status = 'approved', approved_by = '@e2e-admin:localhost', approved_at = now() " +
        `WHERE client_id = ${id}`,
    );
  } else if (opts.status === 'rejected') {
    runSql(
      "UPDATE oauth_clients SET status = 'rejected', rejected_by = '@e2e-admin:localhost', rejected_at = now() " +
        `WHERE client_id = ${id}`,
    );
  }
}

/** Scenario cleanup by client_id prefix (privileged role; cascades to oauth_authz_requests / oauth_codes). */
export function clearOAuthClientsByIdPrefix(prefix: string): void {
  runSql(`DELETE FROM oauth_clients WHERE client_id LIKE ${sqlLiteral(prefix + '%')}`);
}

// ─── oauth-broker story 6 (oauth-account-management) ───────────────────────────
//
// All helpers below connect as the privileged role (see clearOAuthClientsByNamePrefix) and never
// swallow a failure: leaked account sessions / OAuth sessions must fail the run loudly. Values are
// test-generated literals (Matrix user ids, client-id prefixes): no `$`, double quotes or backticks.

/**
 * story oauth-authorize-freshness (P3): delete the consent rows (`oauth_consent_requests`, migration
 * 000045) of every client whose id starts with `prefix`. Scenario hygiene next to
 * clearOAuthClientsByIdPrefix (whose FK cascade would also remove them): a failed scenario must not
 * leave live consent rows behind (their 10 000-row soft cap is global). Privileged role, never swallowed.
 */
export function clearOAuthConsentRequestsByClientPrefix(prefix: string): void {
  runSql(`DELETE FROM oauth_consent_requests WHERE client_id LIKE ${sqlLiteral(prefix + '%')}`);
}

/** Delete every account-page browser session (`oauth_account_sessions`, migration 000043) of a user. */
export function clearAccountSessions(userId: string): void {
  runSql(`DELETE FROM oauth_account_sessions WHERE user_id = ${sqlLiteral(userId)}`);
}

/**
 * Delete every `matrix_sessions` row whose OAuth `client_id` starts with `prefix`, together with the
 * devices (and their key material) those sessions were on. Must run BEFORE
 * clearOAuthClientsByIdPrefix: `matrix_sessions.client_id` references `oauth_clients` ON DELETE
 * RESTRICT (migration 000042).
 */
export function clearOAuthSessionsByClientPrefix(prefix: string): void {
  const p = sqlLiteral(prefix + '%');
  const owned = `SELECT user_id, device_id FROM matrix_sessions WHERE client_id LIKE ${p}`;
  for (const table of ['device_one_time_keys', 'device_fallback_keys', 'device_keys', 'devices']) {
    runSql(`DELETE FROM ${table} WHERE (user_id, device_id) IN (${owned})`);
  }
  runSql(`DELETE FROM matrix_sessions WHERE client_id LIKE ${p}`);
}

/**
 * Delete one device of a user completely: every `matrix_sessions` row of the device (any auth_api),
 * its JWT bindings, the device row and its key material (After-hook cleanup of the legacy device).
 */
export function clearDeviceOfUser(userId: string, deviceId: string): void {
  const u = sqlLiteral(userId);
  const d = sqlLiteral(deviceId);
  for (const table of ['matrix_sessions', 'jwt_device_bindings', 'device_one_time_keys', 'device_fallback_keys', 'device_keys', 'devices']) {
    runSql(`DELETE FROM ${table} WHERE user_id = ${u} AND device_id = ${d}`);
  }
}

/** Delete every OAuth (`auth_api = 'oauth'`) session row of a user (precondition "no OAuth session"). */
export function deleteOAuthSessionsOfUser(userId: string): void {
  runSql(`DELETE FROM matrix_sessions WHERE user_id = ${sqlLiteral(userId)} AND auth_api = 'oauth'`);
}

/** The newest account session's `auth_time` (unix seconds) of a user, or null when none exists. */
export function queryAccountSessionAuthTime(userId: string): number | null {
  const out = runSqlQuery(
    `SELECT auth_time FROM oauth_account_sessions WHERE user_id = ${sqlLiteral(userId)} ORDER BY created_at DESC LIMIT 1`,
  );
  return out === '' ? null : Number(out);
}

/** The database clock (unix seconds): the reference for auth_time comparisons (no host clock skew). */
export function queryDbEpochSeconds(): number {
  return Number(runSqlQuery('SELECT floor(extract(epoch FROM now()))::bigint'));
}
