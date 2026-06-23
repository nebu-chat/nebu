# Security Review (SEC Gate 1) — bugfix-fix-missing-matrix-room-routes — 2026-06-20
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL, 0 HIGH. Cleared to commit.

Five new authenticated Matrix room routes (leave/forget/relations/upgrade/search) wiring HTTP → existing EventDispatcher backends.

## Verified closed
- IDOR (leave/forget/upgrade): acting user = conn.assigns[:current_user]/trusted_identity(stream); no path/body user field to forge; upgrade enforces power>=100.
- Cross-room exfiltration: relations enforces membership + room-scoped parent-event check; search scopes to member rooms at SQL (room/sender filters intersect, never widen).
- Header spoofing: stream/1 builds metadata purely from server-resolved user; client x-user-id never copied → no spoof path.
- Injection: websearch_to_tsquery($2); relation/search SQL fully parameterised; whitelisted ASC/DESC.
- DoS/error leaks: limit clamped 1..100, offset cap 10000; generic error messages; proper Matrix envelopes (no 500s).

## Non-blocking
- F-1 LOW/INFO: search `senders` filter collected but unused by backend (spec-incompleteness, not security — an ignored filter can't widen scope). Wire as AND-intersection or drop route-side collection.
- F-2 LOW (carry-over): no rate limit on these routes at core:4000 (matrix-api-migration F-3 family); inert behind OidcPlug.

Tests: 11 unit passed, 9 integration excluded (need live Postgres).
