# 11 Risks and Technical Debt

## Current Risks

### Architecture Risks

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| ~~Elixir/OTP insufficient for middleware elimination thesis~~ | — | — | **Resolved 2026-06-22**: `full-elixir-stack`/`grpc-removal` removed the Go Gateway and gRPC boundary entirely (ADR-019/020/021) — the thesis validated in production, not just loadtest. Silver-tier loadtest remains a pre-release gate for the resulting single-node Elixir server. |
| OIDC-only excludes too many potential users | Low | Medium | Deliberate scope decision for target audience with existing IdP |
| CRDT consistency edge cases in Horde during netsplit | Low | High | Single-node deployment today; cluster tested in Phase 2 before enabling libcluster |
| Cryptographic deletion not legally recognized | Low | High | Legal review pre-release; fallback: physical pseudonymization |

### Open Architecture Decisions

| ADR | Blocking Feature | Impact |
|---|---|---|
| ADR-011 (Managed E2EE) | E2EE stubs only (keys/upload acknowledged, not stored) | No end-to-end encryption |

### Security Risks

| Finding | Status | Reference |
|---|---|---|
| Token invalidation gap - short-lived tokens not revoked until OIDC expiry | Accepted risk (MVP) | Story 7-26 |
| Compliance session revoke CSRF (fixed) | Resolved | Story 7-16b, Kassandra HIGH-1 |
| Moderation caller_id from request body (fixed) | Resolved | Story 7-32, SEC Gate 2 HIGH |
| Safari re-login lands on #/welcome (Dex cached id_token + Safari 302 cache) | Resolved | Story 11-7 |
| Admin route source classification could leak email into operational logs (fixed pre-ship) | Resolved | Story `war-room-mode`, security-review-driven fix |
| Bootstrap-mode OIDC scope ignored the operator's Step 3 config — providers needing a non-`openid` scope to expose the admin claim could never complete bootstrap | Resolved | `bugfix-bootstrap-scope-ignored`, 2026-07-09 |
| Admin-logs source-classification: 1 MEDIUM accepted non-blocking after a fix attempt was reverted for an architecture conflict | Accepted risk | Story `admin-logs-monitoring-view`, Kassandra review |
| State-event forgery (pre-existing, FIXED 2026-10-07) | **CLOSED** | bugfix-unsigned-replaces-state: `Room.Server.do_send_event/7` now persists `state_key` as NULL instead of `""`, preventing any joined member from forging state events via PUT /send/{eventType}. Migration 000036 backfills `m.room.message` rows empirically. Follow-up data remediation query documented; query-filter hardening (F-3/F-4/F-6) deferred. |
| Search-pipeline encryption exclusion still matches post-fix `state_key = NULL` forged encryption rows (pre-existing, related to above) | Medium | bugfix-unsigned-replaces-state security review F-2: `search/db.ex` predicates must be tightened to `enc.state_key = ''` (not `IS NULL`) after state-forgery path is closed + m.room.encryption guard added to non-state send_event/2 path. Separate /nebu-pipeline bugfix required (not blocking this story). |

## Technical Debt

### Known Deferred Work

| Item | Deferred In | Priority |
|---|---|---|
| Real alias storage (`PUT /directory/room/{alias}` currently a stub) | Epic 7 | Medium |
| Room upgrade implementation (`POST /rooms/{id}/upgrade` returns 501) | Epic 7 (resolved Story 9-27) | Resolved |
| `GET /joined_rooms` returns empty list (clients use /sync instead) | Epic 7 | Low |
| Migration 000036 inclusion-list narrowing (`m.room.message` only, m.reaction + custom types deferred) | bugfix-unsigned-replaces-state security review F-1 | Follow-up |
| Query-filter hardening in `room/db.ex` (F-3/F-4) + fetch_replaces_state/1 array chunking (F-6) | bugfix-unsigned-replaces-state security review | Follow-up |
| Multi-instance dashboard for hosters | Epic 7 retrospective | Growth |
| Apple/Google push notifications | PRD §Growth Features | Growth |
| S3 media backend | PRD §Growth Features | Growth |
| Matrix federation protocol | PRD §Phase 3 Vision | Vision |

### Performance Gaps

| Gap | Current State | Target |
|---|---|---|
| N+1 profile lookups in GetJoinedMembers | Accepted for MVP | Batch query (Phase 2) |
| load_factor always returns 1.0 | MVP placeholder | Real calculation (Phase 2) |
| AIMD drain strategy not yet implemented | Linear only (MVP) | Phase 2 |

### Test Coverage Gaps

| Gap | Status |
|---|---|
| Silver-tier loadtest | Planned post-MVP |
| Playwright E2E for all Admin UI pages | Coverage in progress (Epic 7–8) |
| Gherkin coverage for all Matrix endpoints | Partial (traceability matrix at epic end) |

## Monitoring Recommendations

Items that should be set up before production:
- Prometheus alerts for Elixir process memory growth (Horde room GenServers, ETS tables)
- Alert on PostgreSQL connection pool saturation (`Nebu.Repo` pool — Ecto Telemetry)
- Alert on sync handler P99 latency (long-poll queue depth)
- Audit log retention cron alert if purge job fails

_Source: `_bmad-output/implementation-artifacts/sprint-status.yaml`, deferred items and security findings; `_bmad-output/planning-artifacts/prd.md`, §Risk Mitigations; Story 11-7 (Safari re-login bug resolved: nonce replay prevention, Cache-Control: no-store, denylist check at login). ADR-010 (FTS strategy) accepted 2026-05-08; `POST /search` implemented in Epic 11._
