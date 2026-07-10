---
name: liveview-unbounded-key-registry
description: admin LiveViews that key per-process assigns (node_states/events/order maps) by observed route_template AND by URL query-param values grow the KEY SET forever even when per-key buffers/windows are capped; URL-seeded keys are attacker-suppliable
metadata:
  type: project
---

In the enhanced-logging admin LiveViews (trace-map-leitstand `Nebu.Admin.LogsLive.TraceMap`),
per-LiveView-process assigns are maps keyed by node/endpoint identity: `@node_states`,
`@node_events`, `@endpoint_order`, `@extra_domains`. The devs correctly cap the *values*
(`@max_stream_lines 250`, `@max_inspector_events 5`, per-node `TraceMapStatus.record/3`
self-prunes aged events) — but the *key set* is append-only: a key is added when a new
`route_template` is seen on the `"operational_logs"` PubSub topic or supplied via `?endpoint[]=`,
and never evicted, even after all its events age out of the 60 s window.

**Why it's usually only LOW here:** `route_template` is the *matched* route pattern (path params
collapsed to `:room_id` etc.), so live cardinality saturates at the number of defined routes.
The `handle_params/3` URL-seed path (`normalize_selected/1` → `endpoint_order`/`extra_domains`)
DOES accept arbitrary attacker strings, but impact is self-scoped to the admin's own browser
session and bounded by URL length.

**Why:** capped ring-buffers give false comfort — reviewers see the `Enum.take/2` cap and move
on, missing that the enclosing Map/List of *keys* has no bound. This is a distinct shape from
[[generic-logger-persistence-sink]] (that's the write sink; this is the read-side view state).

**How to apply:** on any LiveView that seeds assigns from URL query params or accumulates a map
keyed by observed identifiers, check for (a) eviction of fully-aged/empty keys, and (b) a cap on
the number of URL-seeded entries. Flag LOW if cardinality is bounded by route templates + admin
self-scope; escalate to MEDIUM if the key can be a raw path / high-cardinality attacker value or
if the view is shared/multi-tenant. Confirmed clean-with-note on trace-map-leitstand (SEC Gate 1,
2026-07-07, L1).

Related good pattern this same story got RIGHT: E2E WARN/ERROR seeding uses a direct-SQL fixture
(`e2e/fixtures/db.ts`) instead of a test-only HTTP route in server code — the test-review gate
rejected the `POST /admin/_test/operational-logs` backdoor. When you see raw-SQL in e2e/fixtures
(not server/lib), assess it as test-only: blast radius is the disposable test DB, no external
path to `runSql`; grade fixture SQL-string-building at most LOW (fragility), never HIGH.
