# Pre-Dev Test Review — forget_room_membership_purge_test.exs

Gate: PASS — 0 MAJOR.

All 7 ACs covered (AC1–AC7); auth-401 AC correctly delegated to existing
matrix_room_routes_test.exs:124 (not duplicated). timeout=0 incremental path
verified correct against do_sync/parse_timeout. No hard waits, no DB-seeding or
cookie-forging shortcuts (real Bearer JWTs via injected JWKS; only read-only
forgotten_row_count DB helper). No crash/restart test required (Option B
PostgreSQL, stateless forget) — correctly absent.

## Findings

- INFO — auth 401 already covered in matrix_room_routes_test.exs; not duplicated (correct).
- INFO — timeout=0 incremental approach correct (no long-poll). Deterministic.
- INFO — no DB-seeding/cookie-forging shortcuts. provision/2 is identity setup only.
- INFO — no Horde crash/restart test needed (PostgreSQL durability proven by fresh sync).
- MINOR (ADDRESSED) — AC4 under-constrained: added a control assertion proving a
  left-but-not-forgotten room DOES re-surface in incremental sync before forgetting,
  so the exclusion assertion is a real regression check, not a vacuous pass.
