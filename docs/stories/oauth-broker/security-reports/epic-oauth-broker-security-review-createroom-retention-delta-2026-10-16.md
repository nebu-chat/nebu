# Epic oauth-broker SEC delta gate createRoom + retention 2026-10-16

Verdict: **CLEAN, dormant merge PASS.** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 1 LOW (X5-1, fixed), 4 INFO. Scope: `git diff 359616f4..HEAD -- server e2e docs` (commits 71972be1 create-room-initial-state-conformance = follow-up `dx`, 5023dff4 media-cleanup-reads-media-config = follow-up `du`). Reviewer: nebu-kassandra (read-only; the orchestrator wrote this file). Prior reports consulted: the two per-story reports of 2026-10-16, `epic-oauth-broker-security-review-ci-run-delta-2026-10-15.md`.

## (a) The per-story fixes are in the commits
NUL check (`contains_nul?/1`, walks keys and values, runs before the room exists: 400 M_BAD_JSON; a lone surrogate is already a decode error), value-free logging (room id, type, error class / SQLSTATE only; the raised error is a generic 500; the worker logs the reasons `:unavailable | :invalid` and the day counts), the writer range 0..3650 (clause before the generic non-negative clause), the form hint, the pre-upgrade SELECT. No repeat of a per-story finding.

## (b) Combined effects
- createRoom: validation runs in the router before the room exists (M_NOT_JSON, `_json` M_BAD_JSON, 64-cap M_INVALID_PARAM, entry shape M_BAD_JSON); the new raise lands in the `Nebu.Matrix.Error` rescue of `create_room/2` (`cleanup_orphan_room`, room stopped `:normal`, rows deleted); aliases are registered after `initial_state`, so a failed entry leaves no alias row; side benefit: a broken body no longer silently creates a nameless room. No privilege escalation: forbidden types skipped, the creator already holds power level 100, `m.space.parent` has the PUT path's check.
- retention: strict fresh read, not `get/0`; regex `\A[0-9]{1,6}\z`; a missing key falls back to the same `@defaults` the audit guard uses, so `old` for `infected_days` is now 7 (the value the worker really used): 7 -> 5 is a shortening (audit needed), 7 -> 30 a lengthening (the accepted D2 residual); before, a missing row counted as 90 (too strict, not dangerous). No runtime / deploy / env reference to the removed `config :nebu, :media_cleanup`; the loader seam is set nowhere in `lib/` or `config/`.
- New attack surface for the dormant OAuth activation: none (no `Nebu.OAuth` code touched; createRoom is open to every authenticated user with or without OAuth tokens; the retention form stays behind the admin gate with a fresh sign-in).

## Findings
- **X5-1 LOW (FIXED after the gate):** when one `initial_state` entry fails to save, createRoom fails as a whole (D5). `EventId.generate/1` hashes the event map including a millisecond `origin_server_ts`, `events.event_id` is the primary key: two byte-identical entries in the same millisecond collided (23505) and answered 500 (the spec allows duplicates, later wins). Fixed: `apply_initial_state/3` drops exact duplicates (`Enum.uniq`); a later entry with the same `(type, state_key)` and another content still wins; unit test with five identical entries.
- X5-2 INFO: the new `m.room.name` -> `rooms.name` path logs `inspect(reason)` (NUL is refused, an echo of the name is unlikely): added to follow-up `ei`.
- X5-3 INFO: the createRoom behaviour change was documented in `docs/matrix-api-scope.md` only: a paragraph in 07-deployment was added.
- X5-4 INFO: `infected_days` default 90 -> 7 equals the worker's effective value, not a retention change; keeping infected files longer is the owner decision `eh`.
- X5-5 INFO: a damaged row makes the form show all defaults while the worker refuses to delete (safe, but the admin cannot see the cause) = `ej`.
Still open from earlier reviews: D2 LOW (a lengthening or disabling can be saved without an audit row, now effective because the worker reads the value); INFO-2 of the media story (the fail-safe delays GDPR erasure / infected removal, signalled by a daily ERROR line only: an alert is recommended).

## (d) Activation verdict: unchanged, BLOCKED
G3-2 (the positive client-IP test on the real load balancer) and the manual groups A-F (group E now also holds the retention acknowledgement) plus the written acceptance of the residuals. `oauth_enabled` stays OFF; neither commit touches the activation path.

Classification: CLEAN. CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 1 (fixed) / INFO 4. Dormant merge: PASS.
