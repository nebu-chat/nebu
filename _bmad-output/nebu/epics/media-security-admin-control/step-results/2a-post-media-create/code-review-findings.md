## Code Review Report — Story `2a-post-media-create` (epic `media-security-admin-control`, cycle 0)

**Verdict: CLEAN — 0 MAJOR, 0 MINOR-blocking.** All 7 ACs and the ordering requirement (§6) are genuinely satisfied by the real implementation, not just by tests.

### Acceptance criteria — all verified in the real implementation
1. Reservation via state machine — `Media.create/1 -> do_create/3` calls `state_machine_module().create/1`, no raw INSERT, uploader_user_id set correctly.
2. Response shape — 200, both content_uri + unused_expires_at, server-computed only.
3. 429 pending limit — business COUNT check, no new RateLimit tier added.
4. 403 permission — injectable :media_permission_module -> Nebu.Matrix.active?/1, ADR-020 clean (public API only).
5. media_id format/collision retry — reuses existing generate_media_id/0, retry bounded to exactly one attempt (not unbounded loop).
6. No body/params read/echoed.
7. Auth — inside OidcPlug pipeline, no bypass.
Ordering (permission before pending-count): verified in real cond, not just tests.

### Guardrail checks (all pass)
- transition/4, @type actor, @transitions guard table byte-for-byte unchanged (only create/1 added).
- No new migration; genesis INSERT covers all NOT NULL columns with sensible placeholders.
- Zero bytes touched (no Storage/Crypto calls, no client expires_at read).

### Findings — all INFO, none blocking
- INFO (flag for 2b): genesis row's `uploaded_at` is set to reservation time — a plausible real timestamp, not an obvious sentinel; 2b's PUT must overwrite it or it will permanently misreport upload time. state_machine.ex.
- INFO (for Kassandra): count_pending_reservations/1 fails open (returns 0) on DB error — documented as intentional soft business limit, not a security control. db.ex.
- INFO (drift risk): Nebu.Matrix.active?/1 reads users.is_active directly while provision_identity/2 derives via TokenValidator — consistent today, only a future-divergence risk given the same column. matrix.ex.
- INFO: unused_expires_at not persisted (no such column) — correct for 2a scope, future sweeper will need a persistence source.
- INFO (security, no issue): all new SQL parameterized, no injection surface; active?/1 returns identical false for unknown vs deactivated (no enumeration signal); media_id keeps 128-bit entropy.

### Test regression check
All pre-dev fixes retained (base64url format, production-default assertions, ordering test, collision-retry test, exactly-once guards). Nothing regressed.

**Recommendation: Proceed.** No fixes required before merge; INFO items are notes for 2b/Kassandra, not defects in 2a.
