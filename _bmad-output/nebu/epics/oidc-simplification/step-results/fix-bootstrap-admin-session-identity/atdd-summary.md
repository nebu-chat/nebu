# ATDD (Step 2) — fix-bootstrap-admin-session-identity

## Files

- `server/test/nebu/admin/bootstrap_admin_session_identity_test.exs` — NEW file, unit-level
  coverage for AC1, AC2, AC4, session_exp behavior-change pin, oidc_user_id_claim cache-timing edge.
  Uses the same injectable-seam pattern as `bootstrap_oidc_flow_test.exs`
  (`:admin_bootstrap_store` dispatcher, `Nebu.Matrix.OidcClaimCache.reset_for_test/0`,
  `:matrix, :oidc_claim_reader`).
- `server/test/nebu/admin/admin_create_room_test.exs` — MODIFIED, +123 lines. New `describe`
  block "AC3: room-creator after bootstrap is the Matrix user_id, not the raw sub" drives the
  REAL Admin HTTP pipeline (`Nebu.Admin.Endpoint` → Router → `RoomsController.create/2` →
  `actor_id/1`) with a session fixture shaped EXACTLY as `bootstrap_confirm_claim/2` writes it
  today (no `matrix_user_id` key) — confirmed via code read that the pre-existing tests in this
  file call `Nebu.Matrix.create_room/2` directly and bypass `actor_id/1` entirely, so they could
  never have caught this bug (the AC3 test-fixture risk flagged in the story is real and is why a
  new describe block, not a fixture edit, was needed).

## RED-phase run (executed directly, `docker run elixir:1.20-alpine mix test` on both files)

**Result: 6/14 passed, 8/14 failed — all failures for the expected reason (nil/wrong
`matrix_user_id`, wrong `session_exp`), zero compile or setup errors.**

| AC | Test | Result | Reason |
|---|---|---|---|
| AC1 | minted session contains matrix_user_id | RED | `matrix_user_id` absent from hand-rolled bootstrap map |
| AC1 | matrix_user_id == UserId.from_claims/2 | RED | got `nil`, expected `@abc-123:localhost` |
| AC1 | bootstrap matrix_user_id == subsequent normal-login's | RED | got `nil` vs `@abc-123:localhost` (SEC Gate 1a) |
| AC2 | preferred_username claim honoured | RED | got `nil`, expected `@kai:localhost` — flattened `bootstrap_claims` stash is unusable for `UserId.from_claims/2` |
| AC2 | sub-fallback baseline sanity | GREEN (intentional) | today's hand-rolled map already carries raw `sub` string into `"sub"` field — not the bug this AC covers |
| AC3 | room-creator falls back to raw sub today | RED | `actor_id` received by injected `:admin_room_creator` seam equals the raw sub (bug reproduced through real Endpoint/Router/Controller) |
| AC3 | post-fix-shape session used as-is (contrast case) | GREEN (intentional) | sanity check that a session WITH `matrix_user_id` already works correctly |
| AC4 | sub/email/admin preserved | GREEN (intentional) | additive-only — must stay green after the fix |
| session_exp pin | near-term `exp` floors session_exp | RED | got `now+8h` value, expected the near-term `claims["exp"]` (today's hand-rolled path ignores `exp` entirely) |
| session_exp pin | no-exp default unchanged | GREEN (intentional) | pins the case that must NOT change |
| cache-timing | non-default `oidc_user_id_claim="email"` honoured in same flow | RED | got `nil`, expected `@kai@example.com`-derived (sanitized) localpart |

8 RED + 6 intentional GREEN = 14 total. Every AC in the story (AC1-AC4) plus the two extra
verification points identified during fresh code-read grounding (session_exp behavior-change,
OidcClaimCache timing) has at least one RED test.

## Process note

Two background ATDD agent invocations were launched (first with slightly stale grounding context,
second with corrected line numbers/findings) while investigating an apparent stall — both were
in fact alive and progressing (confirmed via growing JSONL transcript size), not hung. The second
agent's file output was adopted as authoritative; both agents were sent stop messages once the
work was verified complete. Test execution was performed directly by the orchestrator
(`docker run elixir:1.20-alpine ... mix test <files>`) rather than waiting further on the
delegated agent's own test run, to avoid further pipeline delay.
