---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-build-matrix', 'step-04-gate']
lastStep: 'step-04-gate'
lastSaved: '2026-06-28'
epic: client-crypto-setup
coverageBasis: 'acceptance_criteria'
oracleConfidence: 'high'
oracleResolutionMode: 'formal_requirements'
oracleSources:
  - 'docs/stories/client-crypto-setup/wellknown-e2ee-default.md'
  - 'docs/stories/client-crypto-setup/cross-signing-readback.md'
externalPointerStatus: 'not_used'
gateDecision: 'PASS'
---

# Traceability Matrix & Quality Gate — Epic `client-crypto-setup`

**Author:** Murat (Master Test Architect)
**Date:** 2026-06-28
**Coverage oracle:** Formal acceptance criteria (two `Status: done` stories), confidence **high**.

## Oracle Resolution

- **Basis:** `acceptance_criteria` — both story files carry explicit, numbered AC blocks plus an "Acceptance Tests" section written test-first.
- **Resolution mode:** `formal_requirements` (no spec/external-pointer/synthetic fallback needed).
- **Sources:**
  - `docs/stories/client-crypto-setup/wellknown-e2ee-default.md` — 4 ACs
  - `docs/stories/client-crypto-setup/cross-signing-readback.md` — 8 ACs
- **Total ACs:** 12

## Test Sources Discovered

| File | Type | Notes |
|---|---|---|
| `server/test/nebu/web/wellknown_client_e2ee_test.exs` | ExUnit (`Plug.Test`, unit) | well-known E2EE hint, base_url, CORS, unauthenticated |
| `server/test/nebu/matrix/cross_signing_test.exs` | ExUnit (`@tag :integration` for DB paths; AC7 guard runs DB-less) | cross-signing upload/query/signatures/sync/durability/collision/E2EE guard |
| `server/test/nebu/matrix/matrix_client_compat_test.exs` | ExUnit (supporting) | auth-required (401) + `keys/query` 200-shape contract — supplementary, not primary AC owner |

---

## Story 1: `wellknown-e2ee-default`

| AC | Priority | Description | Test(s) | Coverage |
|---|---|---|---|---|
| 1 | **P1** | well-known includes `io.element.e2ee.force_disable: true` alongside `m.homeserver` | `wellknown_client_e2ee_test.exs`: "returns m.homeserver and io.element.e2ee.force_disable" (asserts `force_disable == true` + non-empty `base_url`) | ✅ FULL |
| 2 | **P1** | `m.homeserver.base_url` derivation (scheme/host, x-forwarded-proto/host) unchanged | `wellknown_client_e2ee_test.exs`: "base_url derivation uses x-forwarded-proto and host" (asserts `https://matrix.example.org`) + base case in AC1 test | ✅ FULL |
| 3 | **P2** | `access-control-allow-origin: *` + `application/json` content type unchanged | `wellknown_client_e2ee_test.exs`: "response keeps access-control-allow-origin: * and application/json content type" | ✅ FULL |
| 4 | **P1** | Valid JSON, served unauthenticated (no Bearer) | `wellknown_client_e2ee_test.exs`: "requires no Authorization header" (200, no auth) + JSON parse in AC1 test | ✅ FULL |

## Story 2: `cross-signing-readback`

| AC | Priority | Description | Test(s) | Coverage |
|---|---|---|---|---|
| 1 | **P0** | `device_signing/upload` persists master/self/user signing keys, returns `200 {}` | `cross_signing_test.exs`: "AC1: upload … → 200 {}, then keys/query echoes all three" (:integration) | ✅ FULL |
| 2 | **P1** | First upload no UIA; idempotent same-key re-upload `200 {}`; overwrite different keys w/o auth → `403 M_FORBIDDEN` | `cross_signing_test.exs`: "AC2: first upload …", "AC2: idempotent re-upload …", "AC2: overwriting existing DIFFERENT keys … → 403" (:integration) | ✅ FULL |
| 3 | **P0** | `keys/query` echoes stored cross-signing keys per user; users w/o keys → empty maps; `device_keys` unchanged | `cross_signing_test.exs`: "AC3: keys/query for a user WITH cross-signing …", "AC3: … WITHOUT cross-signing → empty maps" (:integration) | ✅ FULL |
| 4 | **P0** | `signatures/upload` merges signatures into stored object; `200 {"failures":{}}` on success; per-key `M_INVALID_SIGNATURE` on mismatch; visible on next query | `cross_signing_test.exs`: "AC4: … merges a signature into a stored device key …", "AC4: … mismatch → M_INVALID_SIGNATURE …", "AC4: cross-signing-key mismatch → M_INVALID_SIGNATURE and stored signatures unchanged" (:integration) | ✅ FULL |
| 5 | **P1** | After upload, own user ID appears in `device_lists.changed` on next incremental sync | `cross_signing_test.exs`: "AC5: after device_signing/upload, own user_id appears in device_lists.changed on next incremental sync" (:integration) | ✅ FULL |
| 6 | **P0** | MUST-guard: cross-signing key ID colliding with existing device ID → `400 M_INVALID_PARAM`, nothing persisted | `cross_signing_test.exs`: "AC6: cross-signing key whose key ID collides … → 400 M_INVALID_PARAM, nothing persisted" (:integration) | ✅ FULL |
| 7 | **P0** | No room becomes encrypted; `m.room.encryption` PUT still rejected (ADR-011 regression) | `cross_signing_test.exs`: "AC7: PUT …/state/m.room.encryption → 403 M_FORBIDDEN" (DB-less unit) | ✅ FULL |
| 8 | **P2** | `make test-unit-elixir` green; no regressions in protected-router / device-key tests | Process/CI gate — covered by the unit suite executing green + `device_keys_test.exs` regression suite (compat test notes the DB-backed migration). Not a discrete behavioral AC. | ⚠️ PARTIAL (process AC, enforced via CI gate not a dedicated assertion) |

### Supporting (non-owning) coverage
- `matrix_client_compat_test.exs`: `keys/device_signing/upload` + `keys/query` **401 M_MISSING_TOKEN** without Bearer, and `keys/query` 200 five-map shape — reinforces AC1/AC3 auth + envelope guarantees but is not the primary owner of any AC.

---

## Coverage Summary

| Metric | Count | % |
|---|---|---|
| Total ACs | 12 | 100% |
| FULL coverage | 11 | 91.7% |
| PARTIAL coverage | 1 (S2-AC8, process/CI gate) | 8.3% |
| ZERO coverage | 0 | 0% |

### By priority

| Priority | ACs | Covered (FULL) | Coverage % |
|---|---|---|---|
| **P0** | 5 (S2: AC1, AC3, AC4, AC6, AC7) | 5 | **100%** |
| **P1** | 5 (S1: AC1, AC2, AC4 · S2: AC2, AC5) | 5 | **100%** |
| **P2** | 2 (S1: AC3 · S2: AC8) | 1 FULL + 1 PARTIAL | 50% FULL / 100% addressed |

**P0+P1 coverage: 10/10 = 100%** (FULL).

---

## Quality Gate Decision

**Gate: PASS** ✅

- Threshold: ≥80% P0+P1 coverage. **Actual P0+P1: 100%** — comfortably above gate.
- Overall AC coverage: 91.7% FULL, 100% addressed (no AC has zero coverage).
- **Zero MAJOR gaps** — every AC has at least one mapped test.
- All five P0 ACs (the crypto/auth/regression-critical ones — persistence, read-back, signature integrity, namespace collision guard, and the ADR-011 E2EE-stays-off regression) have FULL, dedicated coverage.

### Observations (non-blocking)
- **S2-AC8** is a process/CI gate ("suite green, no regressions"), not an observable behavioral assertion. It is correctly enforced by the unit-test gate + `device_keys_test.exs` regression suite rather than a bespoke test. Counted as PARTIAL only because it has no dedicated assertion; not a coverage gap.
- Most cross-signing ACs are `@tag :integration` (require Postgres via `make test-integration`); only AC7 and the auth-path compat checks run in the DB-less unit layer. This matches the PostgreSQL persistence strategy (ADR-018/020) and the story's stated test plan. Ensure the CI integration gate actually executes these `:integration` tests so the P0 coverage is realized, not just declared.

### Test-quality notes
- AC4 includes a validate-then-persist regression test ("cross-signing-key mismatch … stored signatures unchanged") guarding against a prior MAJOR finding — good defensive depth.
- AC6 asserts both the rejection **and** that nothing persisted (negative + state check) — strong.
- AC5 uses a real initial-sync → upload → incremental-sync sequence (no hidden seeding) — deterministic and faithful to the consume-once flag design.
