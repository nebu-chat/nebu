---
name: dual-domain-satellite-key
description: A single-segment route (/health, /admin) is simultaneously its own domain AND a satellite key; every code path that builds per-node keys/ids must dedup or the node double-processes
metadata:
  type: feedback
---

In the Trace Map, `TraceMapTree.domain_for_endpoint("/health") == "/health"` — a
single-segment route IS its own domain. So the same string is BOTH a domain node
key and a satellite node key. Any code that fans a log entry / builds ids across
`[route, domain_for_endpoint(route), "nebu"]` must treat that collision.

**Why:** This root cause has now bitten THREE separate code paths in the same
epic:
1. dev cycle 2 — node `dom_id` was key-only → two elements shared one id →
   corrupted LiveView id-keyed DOM patching (fixed by kind-prefixing the id).
2. code-review (trace-map-leitstand) — `record_event` reduces over
   `node_keys = [route, domain_for_endpoint(route), "nebu"]` with NO `Enum.uniq`;
   for `/health` the list is `["/health","/health","nebu"]` → the event is
   recorded TWICE into the `/health` state → all displayed counts (badge,
   tooltip, inspector stats, aria-label) are 2×. Not status-affecting (>0
   threshold) so it slips past status tests.
3. the same key also renders as BOTH a domain circle and a satellite circle
   (visual redundancy).

**How to apply:** When reviewing Trace Map / radial-map code, grep for every
place that builds `node_keys`, dom ids, or iterates domain+satellite sets, and
confirm the single-segment-route collision is deduped. Check specifically that
`/health` (guaranteed) and any bare `/admin`,`/metrics` route produce counts ==
actual, not 2×. No test asserts `/health` counts — ask for one. Related:
[[policy-guard-fixed-one-entry-point-only]] (same "fixed one path, missed the
siblings" shape).
