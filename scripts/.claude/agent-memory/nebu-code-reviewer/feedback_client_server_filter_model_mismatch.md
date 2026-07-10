---
name: client-server-filter-model-mismatch
description: A bugfix that adds server state narrower than the pre-existing client model (single-value-per-dimension server vs multi-value client) reintroduces the very bug it fixes for the unrepresentable case
metadata:
  type: feedback
---

When a bugfix promotes previously client-only UI state into a server assign
(the source of truth every re-render reads from), the server model MUST be
at least as expressive as the client model — otherwise the exact bug being
fixed resurfaces for any state the server can't represent.

Found in `enhanced-logging/trace-map-filter-reset-bugfix`: the fix made
`@active_filters` a `%{"endpoint"=>v, "level"=>v, "source"=>v}` map — ONE
value per dimension. But the pre-existing client filter (`app.js`'s
`activeTraceMapFilters`/`traceMapRowMatches`) supports OR-within-a-dimension
(arrays, multiple bubbles of the same dimension pressed at once), and the
click handler toggles each bubble independently (no mutual exclusion). So
clicking level=error THEN level=warning: client DOM shows both pressed;
`toggle_filter` fires twice and the second overwrites the first, leaving the
server `level="warning"`; the next unrelated re-render renders the error
bubble `active=false` and wipes it — the EXACT reset bug, for the
multi-select-same-dimension case. URL sync only encodes `values[0]`, adding
a third divergent view.

**How to apply:** when reviewing a "promote client state to server assign"
fix, enumerate what the client model can express and confirm the server
assign can hold all of it. Cardinality mismatches (one-vs-many, set-vs-
scalar) are the tell. The happy-path tests (different dimensions, single
value each) pass while the mismatched-cardinality case silently regresses.
