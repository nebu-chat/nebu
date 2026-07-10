## Security Review — trace-map-leitstand (SEC Gate 1)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Epic:** enhanced-logging
**Date:** 2026-07-07
**Diff scope:** `git diff --staged` — new dedicated Trace Map "Leitstand" LiveView at
`/admin/logs/trace-map` (server-side radial SVG map, 60 s sliding-window status model,
URL-driven endpoint multi-select filter, war-room banner, tooltip/inspector/legend,
resizable level-filtered live stream), plus the `TraceMapLeitstand` app.js hook, router
repoint, sidebar label rename, AC13 retirement of the embedded Endpoints dimension on
`/admin/logs`, and E2E fixtures/features.
**Frameworks:** OWASP Top 10, ASVS L2, CWE Top 25, STRIDE.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | trace_map.ex `handle_params/3`, `ingest_entry/track_endpoint/record_event` | Unbounded per-process node registry: `@node_states`, `@node_events`, `@endpoint_order`, `@extra_domains` accrete a key per distinct observed `route_template` and per distinct URL `endpoint[]` value, with no eviction of fully-aged-out endpoints. High-cardinality growth is largely prevented because RequestLogger stores route *templates* (not raw paths), but a bookmarked/crafted URL with many `endpoint[]` values seeds arbitrary map nodes (self-scoped, admin-only). | Cap the rendered node count and/or evict endpoints whose window has been empty for > window duration; cap the number of URL-seeded selections in `normalize_selected/1`. |
| 2 | LOW | e2e/fixtures/db.ts `runSql`/`sqlLiteral`/`insertOperationalLog`/`ensureOperationalLogRow` | Test fixture builds SQL by string concatenation and shell-executes it via `execSync` (`JSON.stringify(sql)` inside a double-quoted shell arg). `sqlLiteral` only doubles single quotes; correctness relies on `standard_conforming_strings=on` and on callers never passing `$`/backtick/backslash/untrusted input. Fragile-by-design but not exploitable: test-only code, values are test-controlled constants/route templates, never reachable from server/production request handling. Blast radius = ephemeral E2E/test DB. | Prefer parameterized invocation (psql variables / `--set` binds or a client lib with placeholders); keep the explicit "no arbitrary user input" contract asserted, not just commented. |

### Detail

**Finding #1 — Unbounded node/endpoint registry (DoS / resource growth)** [LOW]
Each LiveView process holds `@node_states` (one `TraceMapStatus` per node key), `@node_events`
(a 5-event list per node key), `@endpoint_order`, and `@extra_domains`. The per-node status
state self-prunes aged events (`TraceMapStatus.record/3`), and `@stream_entries`/`@node_events`
are hard-capped (250 / 5). But the *set of keys* only ever grows: a key is added when a new
`route_template` is observed on the PubSub topic or supplied via `?endpoint[]=`, and is never
removed even after all its events age out of the 60 s window. Real-world cardinality is bounded
because `route_template` is the matched route pattern (path params collapsed), so the map
naturally saturates at the number of defined routes. The URL-seeding path (`handle_params/3` →
`endpoint_order`/`extra_domains`) accepts arbitrary attacker-suppliable strings, but the impact
is confined to the admin's own session/browser (self-DoS) and bounded by URL length. Net: a
hardening item, not an exploitable condition. No auth/data-exposure impact.

**Finding #2 — E2E DB fixture SQL construction** [LOW]
`e2e/fixtures/db.ts` (added by this story per the approved "AC12 log injection" amendment)
performs direct `INSERT INTO operational_logs` / `UPDATE war_room_sessions` via `psql`,
building the statement through string concatenation with a hand-rolled `sqlLiteral` escaper and
passing it to the shell. This correctly *replaces* the rejected test-only HTTP backdoor (a
genuinely good security decision — no test routes in server code). The residual risk is purely
in the fixture's own robustness: the escaper and shell-quoting are safe only for the
constrained, test-controlled inputs used here. It is not part of the server attack surface —
there is no code path from an external actor to `runSql`. Flagged as a hardening/maintainability
note; blast radius is the disposable test database.

### Cleared (verified, no finding)

- **XSS (HEEx / SVG / tooltip)** — All dynamic values (node labels, route templates, war-room
  `started_by`/`reason`, filter chip keys, aria-labels, stream/inspector `message`) render
  through HEEx `{...}` interpolation (auto-escaped) or safe numeric attributes
  (`coord/1`→`float_to_binary`, `Base.url_encode64` dom_ids). The app.js `TraceMapLeitstand`
  hook builds the tooltip with `textContent` and `createElement` only — no `innerHTML` with
  attribute-derived data; ping elements use `setAttribute` with a fixed class + numeric radius.
  No inline JS / `on*=` handlers (CSP `script-src 'self'` upheld).
- **No Sensitive Data in Logs LAW** — Map, tooltips, aria-labels and the aria-live announcer
  carry only route templates + counts + timestamps (verified in `node_aria_label/5`,
  `maybe_announce/6`, `counts_text/1`). The stream/inspector render the same `message` field the
  existing Live Stream page already shows; that field's redaction is owned by the writer
  (`RequestLogger` sets `message` from method/path/status/duration/request_id/route_template
  only — explicit security notes, `extract_user_id/1` reduces admin `current_user` map to a bare
  id to avoid email/PII leak). This page introduces **no new** message-content exposure surface.
- **Authorization** — `/logs/trace-map` is registered inside
  `live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin}`, the identical gate as all
  other admin LiveViews. No new unauthenticated surface. Filtering is presentation-only over an
  already-admin-scoped store (no RLS bypass introduced).
- **CSRF / open redirect / injection (server)** — No new HTTP state-changing endpoints; all
  interaction is over the authenticated LiveView socket. "Open War Room" link is a static
  `navigate` to a fixed path. No SQL string-building in server code (LogStore uses its existing
  parameterized/allowlisted query path). OIDC/session/auth code untouched.
- **DoS via PubSub render churn** — Per-entry re-render matches the pre-existing LogsLive design;
  stream buffer is capped. No regression introduced.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 2 — advisory (hardening; address at leisure / before epic end)

**Verdict:** APPROVED — no commit-blocking findings.

This is a security-conscious implementation: CSP discipline (single external hook, textContent
tooltips), correct rejection of a test-only HTTP backdoor in favor of a DB fixture, writer-owned
message redaction preserved, and admin-gated routing. The two LOW items are hardening notes with
no exploit path (node-registry growth is bounded by route-template cardinality and self-scoped;
the E2E fixture is unreachable from production).
