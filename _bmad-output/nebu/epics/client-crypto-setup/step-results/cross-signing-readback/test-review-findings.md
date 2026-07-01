# Pre-Dev Test Review — cross-signing-readback

File: server/test/nebu/matrix/cross_signing_test.exs (12 tests)

## AC coverage: COMPLETE
All 7 behavioral ACs have >=1 test; both spec error codes and HTTP statuses asserted
(403/M_FORBIDDEN, 400/M_INVALID_PARAM, 200 with M_INVALID_SIGNATURE in failures). No
cookie forging, no DB-seeding shortcuts (state established via the real HTTP API).

| AC | Test | Status |
|----|------|--------|
| 1 | AC1 upload + query echo | Covered |
| 2 | first-upload / idempotent / overwrite→403 | Covered |
| 3 | with-XS + without-XS empty maps | Covered |
| 4 | merge + mismatch(M_INVALID_SIGNATURE) | Covered |
| 5 | device_lists.changed incremental sync | Covered |
| 6 | collision → 400 M_INVALID_PARAM + nothing persisted | Covered |
| 7 | m.room.encryption 403 (ADR-011) | Covered |
| durability | put_keys → fresh get_keys | Covered (hardened) |

## MAJOR-1 — durability test round-trips in-process (RESOLVED in test phase)
Reviewer: the mandated read-on-start durability test read in the SAME process, so a
future in-process/ETS cache could mask a missing Postgres row → not a true durability
proof.
Resolution (applied now, red phase, test-only): the read-back is now performed in a
separately-spawned `Task` (a real process boundary) and awaited, forcing the durable
Postgres path. Comment corrected (no Ecto sandbox; live Repo pool). MAJOR cleared.

## MINOR-1 — AC4 mismatch test conflates keys-map mismatch with bad signature.
Dev note: keep a single mismatch case is acceptable; impl must return per-(user,key)
M_INVALID_SIGNATURE in `failures` when the signed object doesn't match the stored key.

## MINOR-2 — AC2 overwrite test hard-codes the 403 (not UIA 401) simplification.
This is the story's explicit choice (403 M_FORBIDDEN "Key ID in use"). Keep; documented.

## MINOR-3 — shared hard-coded key literals across helpers (low risk, small file).

## INFO — no hard waits/sleeps; deterministic; per-test unique uids. Good.

## Verdict: CLEAN to start dev (MAJOR-1 resolved in red phase).
