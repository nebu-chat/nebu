# Code Review — centralize-claim-resolution (cycle 0)

**Verdict: 0 MAJOR, 1 MINOR, 5 INFO.**

## MINOR-1 (fix in dev-story cycle 1)
`server/lib/nebu/admin/auth.ex:1084` — the SEC NOTE comment above `admin_claim?/1` still says
"per `claim_value_matches?/2` **below**," but that function moved to `Nebu.Web.OidcClaims` in this
same diff. Behaviorally accurate, spatially stale (the function is no longer "below" in this file —
it's in a different module entirely).

Fix: update the reference to name the new module, e.g. "per `Nebu.Web.OidcClaims.claim_value_matches?/2`"
instead of "per `claim_value_matches?/2` below".

## INFO (no action required)
- AC3 comment preservation manually verified intact in `server/lib/nebu/web/oidc_claims.ex:29-43`.
- Private→public visibility widening for `claim_value_matches?/2`/`flatten_discovered_claims/2` is
  safe (pure functions, no state/secrets) and correctly permitted under ADR-020; `dot_path/2`
  correctly stays private.
- AC2 regression net confirmed exercised end-to-end via `admin_oidc_login_test.exs` and
  `bootstrap_oidc_flow_test.exs` calling the public wrappers.
- Fully-qualified (unaliased) call style matches existing `Nebu.Web.JwksCache`/`Nebu.Web.OidcConfig`
  usage already in the file.
- New module's moduledoc is high quality.

## Verification performed
- Zero leftover duplicated definitions in auth.ex (grep confirmed no `defp claim_value_matches?` /
  `defp flatten_discovered_claims` / `defp dot_path` remain).
- The two moved function bodies are byte-identical between old and new file.
- 34 tests in oidc_claims_test.exs, matching story description.
- Non-goals (any-key-scan risk, UserId.from_claims/2) untouched — no scope creep.

**Action: cycle 1 to dev-story — fix MINOR-1 only.**
