# Code Review: matrix-refresh-revalidates-with-idp (cycle-1 re-review)

Reviewed the full staged diff (8 files, 1152 insertions / 59 deletions): http_public.ex,
admin/auth.ex, matrix_session_store.ex, sso_login.ex, new oidc_token_exchange.ex,
login_refresh_test.exs (+715 lines), device_lifecycle_login_test.exs.

## Verification of the 4 named cycle-1 points

1. **MAJOR (blank display_name/email + key regen)** — confirmed fixed. `check_still_active/2`
   (http_public.ex:645-646) uses `fresh_claims["preferred_username"] || fresh_claims["name"] || ""` /
   `fresh_claims["email"] || ""`, byte-identical to the login path's extraction (line 329-330).
   Regression test present and traces the exact `signing_key_id IS NULL` backfill branch.
2. **MINOR m2 (unrefreshable session without OIDC RT)** — test present, verified `Store.create/1`
   with no `oidc_refresh_token` key produces a `nil` column, correctly routed through
   `revalidate_with_idp/1`'s fallthrough clause.
3. **MINOR m1 (transient vs confirmed)** — test genuinely exercises the intended path. Traced
   `TokenValidator.validate/4` → `Application.get_env(:session_manager, :validator_module, Postgres)`
   — the `TransientlyFailingValidator` seam really reaches `check_still_active/2`'s third clause
   (`{:error, {:transient_check_failed, :db_timeout}}`), not `:deactivated`. Assertions
   (`get_by_refresh_token/1` returns the row + original AT still authenticates `/sync`) are real
   proof the delete branch didn't fire.
4. **Stale RED-phase comment + arch doc drift** — both rewritten accurately. Grepped all staged
   files for RED-phase phrase set: zero hits in added lines. 08-concepts.md now correctly documents
   the two-branch AC2 behavior (confirmed → hard-delete; transient → 401 only, session intact),
   matching the actual code.

## New findings from fresh full-diff review

**MAJOR:** None.

**MINOR:** None new — the diff is clean of the previously-known issue classes.

**INFO:**
- `Nebu.Web.OidcTokenExchange.discover/2` (new module) calls `Nebu.Matrix.OidcMetadata.fetch/1`
  directly — a cross-domain submodule reach-through. Not flagged higher because this exact call is
  already made from 4 pre-existing sites (jwks_cache.ex, admin/auth.ex, bootstrap_controller.ex) with
  no facade delegate ever added; this is one more instance of an already-endemic, pre-existing
  pattern rather than a novel violation class.
- Neither the Matrix refresh path nor its explicit reference implementation
  (`Nebu.Admin.Auth.refresh_admin_session/1`) binds the freshly-returned id_token's `sub` claim back
  to the session's original identity before trusting the fresh claims for backfill/lifetime. Relies
  on OAuth2 refresh-token-scoping as an implicit guarantee. Not new to this diff and symmetric with
  the pattern it mirrors, so INFO only — would become MAJOR if a future diff added sub-binding to one
  domain and not the other.
- admin/auth.ex's `discover/2`, `token_endpoint_post/3`, `extract_tokens/1` are NOT dead code
  post-refactor — verified they still serve the separate authorization_code exchange leg
  (`exchange_code/4`), a legitimately distinct call site from the now-shared refresh-token exchange.

AC1–AC6 all traced and confirmed covered by code + tests; AC5's shared-module extraction is real
(admin/auth.ex now delegates, no duplicated ~20-line copy remains).

**Recommendation: no further dev cycle needed for the 4 named issues — all genuinely resolved.**
The three INFO items require no action.

Known pre-existing out-of-scope edge case (not fixed, not flagged as new): `{:ok, nil}` branch in
TokenValidator re-provisioning a fully-row-deleted user via provision_new_user rather than denying.
