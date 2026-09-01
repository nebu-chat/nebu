# Code Review Cycle 2 — VERDICT: PASS (0 MAJOR, 0 MINOR, 4 non-blocking INFO)

Both cycle-0 MAJORs verified genuinely fixed:
- MAJOR-1 transition-gate: `was_healthy? = state.healthy` captured before `ensure_connected/1`, gated `if not was_healthy? and new_state.healthy`. GenServer serializes handle_call so no concurrency race. Invariant holds (every path setting socket:nil also sets healthy:false). Strengthened test proves exactly one log across two consecutive polls.
- MAJOR-2 Logger.info reversion: severity per call site matches AC1/AC2/AC3 exactly; infected/error paths correctly still Logger.warning (not over-corrected). Logger.configure(level: :info) scoping verified safe: all 4 modules (3 story files + request_logger_test.exs precedent) are async:false, describe-block-scoped setup+on_exit restore, no cross-test/cross-module pollution possible.

All 3 MINORs correctly folded in (row_to_session/1 string-id kept with sound justification; handler_test.exs File List row present with accurate rationale; cross-referencing comments present and useful at all 3 row_to_session/1 sites).

AC1-AC10 and all Dev Agent Guardrails reconfirmed intact. 4 INFO findings, all non-blocking (rescan dead-code removal confirmed safe; ClamAV recovery log only via health_check path, pre-existing scope per AC1; actor_id/1 nil edge case mirrors existing precedent; empty-list scope vacuously valid, unreachable in practice).

No 3rd-cycle escalation warranted. Ready to proceed.

---

# Code Review — Story 10e: Trace-Map/War-Room Integration (cycle 0, superseded by cycle 2 above)

**Verdict summary:** 2 MAJOR, 3 MINOR, 4 INFO. All Dev Agent Guardrails respected. All ACs functionally implemented and tested.

## MAJOR

### MAJOR-1 — ClamAV "healthy" logged as WARN on EVERY health_check/0, not on state transitions
`server/lib/nebu/media/clamav.ex:184` logs `Logger.warning("clamd connection healthy", route_template: "/media/clamav")` unconditionally in the `{:ok, new_state}` branch of `handle_call(:health_check, ...)` — no transition gate, despite the code comment claiming "state transition." `health_check/0` is called on every scan job, periodically by the alerts checker worker, and on every dashboard render. Since WARN is always-persisted by LogStore.Handler (INFO/DEBUG are policy-gated, WARN/ERROR are not), this writes an unbounded, permanent "clamd connection healthy" row to operational_logs on every clean poll — AC1 specifies "health-check-state transitions," not every poll. The module already has `state.healthy`/`new_state.healthy` and a `put_healthy/2` helper that gates on real transitions — a transition-gated log was readily available. The AC1 test only performs a single health_check so it doesn't catch the spam.

### MAJOR-2 — Logger.warning/2 substituted for the AC-specified Logger.info/2 to route around a test-config gap
All new scan-pipeline log calls use `Logger.warning/2` instead of `Logger.info/2`: `media_live.ex:758` (log_admin_media_action/2 — **AC3 explicitly specifies Logger.info/2**, direct AC violation), `media_scan_worker.ex` scan-start/released, `clamav.ex:184` healthy. Root cause confirmed: `config/test.exs:3` sets `config :logger, level: :warning`, dropping `:info` calls before the handler; the 3 new test files never raise the level. The established codebase pattern for exactly this situation (`request_logger_test.exs`, `logs_live_test.exs`, `http_foundation_test.exs`, `cors_plug_test.exs`) is `Logger.configure(level: :info)` + on_exit restore in the TEST, not lowering production severity. As implemented, routine admin actions (block/unblock/delete/rescan) and successful scans are always-persisted as WARN — defeating the admin-configurable INFO persistence policy and semantically misleading, actively undermining the incident-triage surface this story serves (an operator filtering to WARN/ERROR to find real problems drowns in routine noise). AC1/AC2 text permits either level, softening those two sites; AC3's explicit `Logger.info/2` mandate is a clean violation.

## MINOR (auto-cycle back to dev-story)

- MINOR-1: `WarRoomManager.row_to_session/1` was changed to return a string `id` for ALL callers, when only the one `media_health_live.ex` push_navigate site needed it — a call-site-only `Ecto.UUID.load!(session.id)` conversion would have avoided all ripple into stop_session/1, fetch_by_id/1, war_room_manager_test.exs, and handler_test.exs. Internally consistent and fully tested now, but avoidable blast radius.
- MINOR-2: `server/test/nebu/web/log_store/handler_test.exs` was modified (5 sites) but is not recorded in the story's File List — it belongs to the already-merged enhanced-logging epic. The edit is necessary given MINOR-1's approach (verified no other site was missed: log_store_test.exs, logs_live_test.exs, war_room_exclusive_scope_test.exs, war_room_test.exs all source `id` from their own raw-SQL RETURNING, never from WarRoomManager) but undocumented — update File List / Dev Agent Record.
- MINOR-3: two identically-named `row_to_session/1` functions (WarRoomManager: string, LogsLive.WarRoom: string, LogStore.WarRoom: binary, unchanged/correct) now disagree in shape — latent footgun for future maintainers, worth a cross-referencing comment.

## INFO (no action needed)

- INFO-1 (positive): AC9 media_id hint correctly independent of severity — confirmed gated separately from the critical-only action.
- INFO-2: AC1 connect/disconnect coverage is partial (only health_check-coincident connects logged, not scan_binary's ensure_connected/1 path) — AC1 test only exercises health_check path so it passes, but not universally captured.
- INFO-3: validate_scope/1 error message says "non-empty route paths" but empty list `[]` passes vacuously (harmless).
- INFO-4: encode_scope/1/decode_scope/1 duplicated across war_room_manager.ex and war_room.ex — consistent with ADR-018, acceptable.

## Verified correct
Dead-clause removal in media_live.ex confirmed safe (admin_rescan/2's closed @spec exhausted). Action-string parity (AC3) confirmed. AC8 error handling fully matched. Validation chain reachable. Migration column types confirmed (scope=TEXT, filter=JSONB, id=UUID) — JSON encode/decode and UUID string/binary handling technically sound, backward-compat holds. AC4/AC5 pinned by pure-function regression test.

## Guardrail compliance — all respected
No TraceMapTree/TraceMap change; no RequestLogger/PayloadRedactor touch; no AuditWriter.@known_actions entry; bounds unchanged (10..10_000/10..3_600); no war_room_sessions migration column-type change.
