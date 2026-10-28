# Kassandra short review: room-keys-version-post-stub (2026-10-15)

Verdict: CLEAN (0 CRITICAL / HIGH / MEDIUM, 1 LOW, 3 INFO). Scope: `POST /_matrix/client/v3/room_keys/version` stub (200 `{"version":"1"}`, nothing stored).
- Auth: behind OidcPlug (the catch-all marker `nebu_unrecognized` is only set by the final `match _`), 401 `M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN` pinned by tests; the route list test (AC12) pins its presence.
- No information leak (constant answer; the implemented-route set is public in `docs/matrix-api-scope.md`), no amplifier (no DB / GenServer / IO; global JsonBody 1 MB limit), no logging of content.
- LOW-1 (false sense of key backup): with E2EE off (ADR-011) nothing is lost; 07-deployment now states that Element shows a recovery key although no room key is backed up and that `PUT room_keys/keys` stays unrecognized (applied).
- INFO-1 POST version "1" vs GET 404 is spec-inconsistent but documented (D2) and verified against Element; INFO-2 a dead comment reference (fixed); INFO-3 scope held (one route).
