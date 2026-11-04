# Fix brief — 2 MINOR of the cycle-4 delta review (cycle 5, user asked to fix them, do not defer)

Full findings: `_bmad-output/nebu/epics/e2ee-client-support/step-results/device-key-directory/code-review-findings.md` (the 2 MINOR items). Scope: ONLY these two.

1. `server/test/nebu/matrix/device_key_directory_claim_limits_test.exs` (~170-178): the adapted all-or-nothing test lost its discrimination (the caller
   request bucket now refuses the 5th request whether or not the stage-2 refusal refunded bob2's target bucket). Restore it: after the refusal advance the
   test clock enough for the caller request bucket (30/min, burst 10) to hold a token again (~2.1 s) and require that the follow-up request for bob2 passes
   (5 passes in total as before), OR assert that bob2's per-target ETS row still holds its full tokens. The test must FAIL if the refund of the
   per-target buckets is removed (convince yourself by reading, mix cannot run in your sandbox).
2. `docs/stories/e2ee-client-support/device-key-directory.md` lines ~66, ~80, ~85: stale text contradicting D8 and the new `keys_changes` tier.
   D9 ("No rate limit of its own beyond the generic tiers"), the open question (the tests pin that `/keys/changes` is NOT limited), D20
   ("bucket keys chosen by the caller"). Rewrite to the current behaviour (keys_changes 60/min burst 20 per user; per-target buckets keyed on the SHA-256 digest;
   claim targets budget 600/min burst 1000). Grep the story file for other stale statements of the same kind.
Do not touch anything else. Reply with the digest.
