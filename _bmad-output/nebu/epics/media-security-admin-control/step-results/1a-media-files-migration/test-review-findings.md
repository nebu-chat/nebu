# Test Quality Review — Story 1a-media-files-migration (pre-dev)

MAJOR:
- M1: Down migration's actual DROP statements (AC11 — trigger, function, table CASCADE,
  8 columns, 2 ENUM types, in dependency-safe order) are never asserted. Only the
  no-GRANT check touches .down.sql.
- M2: ENUM value ORDER (AC2 says "in this order") is only checked via MapSet/set-equality,
  not list/order equality. A shuffled-but-same-set ENUM would still pass.

MINOR (non-blocking, logged for dev-story awareness):
- N1: "row unchanged" test omits inserted_at from the re-SELECT comparison.
- N2: Only column presence (not type/nullability/default) checked for 7 of 8 new columns.
- N3: down-migration no-GRANT check duplicated in two files (harmless).
- N4: no regression guard against FORCE ROW LEVEL SECURITY being added.
- N5: static-analysis file at 360 lines, over soft 300-line guideline (informational only).

Resolution: M1 and M2 fixed inline as test-only additions before dev-story (see
step-results dir) — added down-migration DROP-statement/order assertions and tightened
the ENUM-2 test to list-order equality. Re-verified RED (still fails — migration file
does not exist yet). MINOR items left as-is per pipeline MINOR-does-not-block policy.
