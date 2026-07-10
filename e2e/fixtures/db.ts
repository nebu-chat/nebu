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

import { execSync } from 'node:child_process';

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

