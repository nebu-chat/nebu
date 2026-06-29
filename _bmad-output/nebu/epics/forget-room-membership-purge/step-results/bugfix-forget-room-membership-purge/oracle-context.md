# Forget + Sync Exclusion — Matrix CS API v1.18 Spec Findings

## 1. Endpoints, events, MUST rules
- `POST /_matrix/client/v3/rooms/{roomId}/forget` — Requires authentication (Yes); Rate-limited (Yes). Path param `roomId` Required.
- 200 response body MUST be exactly `{}` (empty object).
- MUST: if user is currently joined, they must leave before calling `/forget` → 400 (join-guard).
- MUST: forgotten rooms "will never appear in the response to `/sync`, until the user re-joins, is re-invited, or knocks".
- Forget acts on **left** rooms; a left room only appears in the `rooms.leave` (Archived) section if a filter sets `include_leave: true`. Forget MUST suppress it from that `leave` section too.
- No new event type is emitted; forget is per-user server-side state, not a room event. Therefore join-guard rejection MUST write nothing.
- Forget is inherently per-user and idempotent.
- Related capability `m.forget_forced_upon_leave` (auto-forget on leave) — Nebu does NOT implement. Not required.
- E2EE remains out of scope (ADR-011) — no interaction.

## 2. Error codes / HTTP statuses / edge cases to test-cover
- 200 `{}` — forget after leave (happy path).
- 400 join-guard — spec example uses `M_UNKNOWN`; `M_BAD_STATE` is defined, more precise, and spec-valid. Story's `M_BAD_STATE` choice is acceptable; assert errcode + no forget row written.
- 401 unauthenticated — `M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN`, HTTP 401.
- 429 `M_LIMIT_EXCEEDED` — endpoint is rate-limited (test if wired; else deferred).
- Idempotency — second forget of same room → 200 `{}`, no duplicate row.
- Per-user isolation — A forgetting R MUST NOT affect B's sync of R.
- Initial sync exclusion of forgotten room.
- Incremental sync exclusion (join/invite/leave) of forgotten room.
- Re-join clears forget → room reappears.
- `include_leave: true` filter MUST still exclude a forgotten room from `rooms.leave`.
- Forgetting a never-joined/unknown room — only join-guard 400 mandated; otherwise idempotent/no-op (200).

Spec source: client-server-api index lines ~23700–23856 (endpoint), 23709–23711 (sync rule), 3501–3503 (M_BAD_STATE).
