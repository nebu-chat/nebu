## Not Applicable — No Matrix CS API Surface

**Verdict:** This story does not engage the Matrix Client-Server API. It is internal admin/observability plumbing, out of Oracle's spec-authority scope entirely.

**Why:**
- All ten ACs describe: Logger metadata calls (`route_template`, `request_id`) on internal GenServer/Oban-worker/LiveView code, an additive `WarRoom.scope_matches?/2` matcher, and one admin-dashboard button wired to `WarRoomManager.start_session/1`.
- None of these are CS API requests, responses, event types, or sync-response structures.
- AC4's `domain_for_endpoint/1` heuristic is explicitly **unmodified** by this story — it's reused as-is.
- The route templates introduced (`/media/clamav`, `/media/scan_worker`, `/admin/media`) are Nebu-internal log-domain labels for grouping purposes, not `/_matrix/...` paths — no collision, no interoperability implication.
- The `/_matrix/client/v3/sync` / `/_matrix/client` strings in the story text are, per the framing given, illustrative examples of a pre-existing grouping behavior — not something this story implements or changes.

**Per Creed boundaries** ("Authority ends at the CS API boundary," "Never invent spec behavior to fill a gap"): no MUST requirements, error codes, or spec-defined edge cases apply here. Manufacturing spec citations against this story would be noise, not signal.

**Recommendation:** Route this story's quality gate through normal code review / test-design (Murat/TEA), not an Oracle compliance gate.
