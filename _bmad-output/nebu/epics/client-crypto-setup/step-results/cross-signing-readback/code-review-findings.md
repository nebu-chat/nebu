# Code Review — cross-signing-readback (cycle 2, re-review)

Verdict: PASS / CLEAN. MAJOR-1 RESOLVED. All cycle-1 findings cleared, no new MAJOR/MINOR.

## MAJOR-1 — RESOLVED
Cross-signing signature merge is now validate-THEN-persist:
`merge_cross_signing_signature/4` reads stored object via read-only `find_key_object/2`,
compares stored_clean vs submitted_clean (both drop signatures+unsigned), and only calls
`merge_signatures/3` (the sole writer) inside the match true-branch. Mismatch/no-stored-key
→ :invalid (M_INVALID_SIGNATURE), nothing persisted. Old cross_signing_body_matches?/3 gone.
Confirmed merge_signatures has exactly one call site, gated by the equality check.

## MINOR-1 — RESOLVED. Caller-identity guard: merge_user_signatures rejects user_id != current_user
with M_FORBIDDEN failures, no storage touched. caller sourced from conn.assigns[:current_user]
(OidcPlug-verified). AC4 success path unaffected (caller signs own key).

## MINOR-2 — RESOLVED. Symmetric `unsigned` drop on both device and cross-signing compare paths.

## INFO-1 — RESOLVED. Comment added on first-upload master_key gate.

## New regression test — PRESENT. cross_signing_test.exs AC4 CS mismatch: asserts
M_INVALID_SIGNATURE AND nothing persisted (stored object byte-for-byte unchanged + refute
attempted sig present).

## Fresh scan — clean: ADR-018 parameterised SQL, ADR-011 opaque/no-encryption, no secret logging,
no new IDOR (guard tightens it).

## Remaining INFO (non-blocking, not cycled): add a positive cross-user caller-guard test
(foreign user_id in body → M_FORBIDDEN, no storage). Optional future enhancement.
