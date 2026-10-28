# e2e verification (AC11), 2026-10-19, isolated stack nebu-oauth (plain http), project element-web, FRESH stack per run
- Run A (CI parity: NEBU_RATE_LIMIT_DISABLED=true, the caps active): 25 passed, 0 failed (13.1 min): e2e-runA.log.
- Run B (limits ENABLED: NEBU_RATE_LIMIT_DISABLED=false): 25 passed, 0 failed (13.2 min): e2e-runB.log. The e2e helpers retry 429 silently, so the SERVER LOG was checked: e2e-runB-server.log (5068 lines): 0 lines with `status: 429` on any route, 0 cap 403s (no "too many pending invitations"), for 27 createRoom, 20 join and 18 invite calls: the default tiers and caps are never hit by the e2e suite.
- K9 (UI start-DM selectors) and K10 (m.direct = ff) stay excluded as @known-failure.
Server CI replica (final code): 9007 tests, 23 failures, all known flaky families (RoomsFallbackName 12, AdminOidcLogin 3, TraceMapNodeControls 3, TemporaryCaptureManager 2, LogStore.Retention 1, SsoLogin 1, WarRoom 1).
