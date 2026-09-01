## Oracle Gate — 2e-reserved-upload-cleanup-cron

### Q1 — Spec MUST/SHOULD on reclaiming expired reservations (#post_matrixmediav1create)
- MAY — server may optionally enforce a max age for unused IDs and delete media IDs when the
  client doesn't start the upload in time — cleanup is explicitly optional, not mandated.
- SHOULD — server should include unused_expires_at (max POSIX ms timestamp to complete upload)
  — recommended, not MUST.
- Recommended default 24h — a recommendation, no spec-defined min/max TTL bound.
- SHOULD (related, not cleanup) — server should limit concurrent pending uploads per user,
  429 M_LIMIT_EXCEEDED when exceeded. Pending = uploaded-not-yet AND unused_expires_at not
  yet passed. This is why stale rows must be reclaimed, but spec doesn't mandate the cleanup
  itself.
- No requirement that mxc:// become permanently invalid at exact expiry; no requirement that
  expired reservations be observable/enumerable by clients (no list-pending endpoint exists).

Conclusion: zero wire-protocol MUST governs this worker. Pure server-side housekeeping,
internal Oban worker, no CS API surface — matches the story's own framing.

### Q2 — Error codes/edge cases for EXPIRED reservation access
- PUT .../upload/{serverName}/{mediaId} -> 404 M_NOT_FOUND covers BOTH "never created via
  POST /create" and "expired" — no distinct errcode for expired vs never-existed.
- 409 M_CANNOT_OVERWRITE_MEDIA unrelated to expiry (already-uploaded only).
- 403 M_FORBIDDEN unrelated to expiry (permission/ownership only).
- No spec-modeled distinct state transition on TTL passing — the 404 is a live comparison at
  request time, not a spec-modeled state.

Consistency requirement carried into dev-story: the PUT handler's 404 check (2b's
reservation_expired?/1, live `uploaded_at + unused_expires_ms() < now`) MUST remain
independent of this cron's cadence — otherwise a race window up to 15 minutes wide would let
an already-expired-but-not-yet-hard_deleted row wrongly accept an upload. This cron is state
hygiene (reclaiming the pending-upload slot/row), not the source of truth for the 404. No
change needed to 2b's PUT handler; just confirm during dev-story it stays untouched/independent.

No blocking spec objection to the story as written.
