## Session — bugfix/media-download-451-scan-race (SEC Gate 1)

**Scope:** staged diff server/lib (media.ex lookup_maybe_stalled/4, clamped_stall_ms, thumbnail stall; download_stall.ex run_wait hardening), config.exs default_stall_ms, tests, docs.

**Finding summary:** 0 CRITICAL, 0 HIGH, 2 MEDIUM, 2 LOW, 6 INFO — APPROVED/CLEAN.
Report: docs/stories/bugfix/security-reports/media-download-451-scan-race-security-review-2026-10-13.md

**New patterns discovered:** try/after slot release NOT crash-safe under Bandit HTTP/2 (StreamProcess linked to conn handler; peer close => async exit skips `after`). Upgrades 2d L-2 (judged unreachable on HTTP/1 reasoning only) to MEDIUM F-1; reachable via h2c prior-knowledge on directly exposed port (stackit tls_mode=none).

**Accepted risks this session:** M-1 (no per-IP RateLimit / per-user stall sub-cap) re-derived 4th time — carried, not new; impact now "cancels the bugfix node-wide" rather than "denies opt-in optimization".

**Follow-up:** F-1 Registry/monitor-based slot accounting (also gives per-user sub-cap for M-1); F-4 admin UI max_stall_ms (1h bound) is inert — handler reads compile-time config.exs only; clamp_stall_ms lacks is_integer(cap) guard (term-order unclamp if Config swap yields string).
