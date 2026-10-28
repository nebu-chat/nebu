---
story_id: sso-origins-admin-hardening
title: "Admin SSO trust settings: strict fetch metadata + fresh re-authentication on the SSO origin / scheme saves, no framing of /admin/config, fail-closed matrix-parameter paths for approved-client trust (epic SEC gate 3 delta, X-1, X-4)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-14
branch: feature/migrate-to-oauth2
---

# Story: Harden the admin writers of legacy-SSO trust (SEC delta gate X-1 / X-4)

Source: `docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-delta-2026-10-14.md`
(finding X-1 MEDIUM, X-4 LOW; X-3 is documentation only).

## Story

As an operator I want the two admin forms that widen legacy-SSO trust (`sso_redirect_allowed_origins` = origins
that receive a `loginToken` without the confirmation page; `sso_extra_redirect_schemes` = schemes that are a
`:direct` redirect sink) to be protected like the OAuth client approval (E-3: strict fetch metadata plus a fresh
admin re-authentication), so that a script on the shared Element Web / `/admin` origin (SO7) cannot silently
re-open the G3-3 account takeover through a same-origin `fetch()` that reads the Phoenix CSRF token.

## Acceptance Criteria

1. `POST /admin/config/sso-origins` and `POST /admin/config/sso-schemes` run `Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, "/admin/config")`
   after `require_admin` and the CSRF check and before anything is validated or written:
   - a request without the four strict fetch-metadata headers of a user-clicked form submit (`Sec-Fetch-Site: same-origin`,
     `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`, `Sec-Fetch-User: ?1`) answers the existing `403` "Request refused"
     page (`data-error="fetch_metadata"`); nothing is persisted, no audit row is written;
   - without a fresh re-authentication marker bound to `/admin/config` the response is a redirect to
     `Auth.reauth_start_path("/admin/config")`; nothing is persisted, no audit row is written;
   - with both, the save behaves exactly as before (validation, persistence, audit row `sso_redirect_origins_changed`
     for the origins); the marker is consumed after a SUCCESSFUL write only (a validation error lets the admin correct the
     text with the same marker; follow the consume point of `Nebu.Admin.OAuthClientsController`, line ~137).
2. `save_refresh_mode`, `save_scopes`, claim / role mapping and the other admin forms are NOT changed (a follow-up row records the sweep of the other
   privilege-granting forms).
3. `GET /admin/config` is served with `frame-ancestors 'none'`, `X-Frame-Options: DENY` and `Cache-Control: no-store`
   (same header set as the OAuth admin confirm pages; reuse the existing plug / helper, no new copy of the header list). Other admin
   pages keep `frame-ancestors 'self'`.
4. The `/admin/config` page tells the admin, next to the two forms, that saving needs a fresh sign-in (one short
   sentence, `aria-describedby` on the submit buttons; the refusal / re-auth redirect page already exists).
5. X-4: `Nebu.OAuth` source 3 of `trusted_redirect_url?/2` (`climbs?/1`, `oauth.ex` around line 531) additionally refuses (treats as
   "not listed", so the user sees the confirmation page) any redirect URL whose path contains `;` (matrix parameters such as `..;/`) or
   `%25` (double encoding). Test rows for `https://app.example/cb/..;/x`, `https://app.example/cb/%252e%252e/x`, and the unchanged accepted
   rows (`https://app.example/cb/`, `https://app.example/cb/sub?x=1`).
6. Existing tests and e2e scenarios that save the two forms are adapted to the new flow (fetch-metadata headers on the request, a fresh
   marker through the existing test helper that the OAuth approve tests use; e2e: the existing admin re-authentication step of
   `e2e/step-definitions/oauth/` / `e2e/fixtures/oauth-admin.ts`; e2e is verified statically, it does not run in the isolated CI).
7. Documentation: `docs/architecture/07-deployment.md` (legacy SSO confirmation page / group F / SO7 wording: a same-origin script needs no user click
   on the decision pages (X-6); saving the two forms needs a fresh admin sign-in; the G3-2 rows state that the collapse also hits the
   legacy confirm page from the merge on (X-3)), ADR-033 (L3 / L8 / SO paragraph, source 3 = registered redirect URI and path boundary, not "origin"),
   `follow-ups.md` (new rows).

## Out of scope

Code change for X-3 (answer `invalid_state` before charging the per-IP bucket): documented only.

## Notes for the dev agent

- Lock-free, no SQL, no migration. Admin controllers: ADR-018 / ADR-020 conventions; the OAuth facade is `Nebu.OAuth` (`check_fetch_metadata/2`).
- Test names must stay under 255 characters.

## Dev Agent Record

Cycle 0 (TDD, about 50 generated tests in `config_sso_trust_hardening_test.exs`, X-4 rows in `oauth_trusted_redirect_origin_test.exs`, return-allowlist rows in `admin_reauth_test.exs`): AC1-AC6 implemented. Code review cycle 0: 1 MAJOR (the no-framing decision compared `request_path`, bypassed by `/admin/config/`), 3 MINOR; UX: 1 BLOCKING (silent non-save after the re-authentication round trip); Kassandra: CLEAN, 1 LOW (the same framing gap). Cycle 1: `path_info` decision, re-auth info flash plus hint wording, neutral 403 page text, `active_nav`, e2e waits, test fixes. Deviations from the story text: `@reauth_return_re` of `Nebu.Admin.Auth` also accepts the literal `/admin/config` (needed for the return after the fresh sign-in); the 403 refusal page of the OAuth admin is reused (neutral wording); every successful save needs its own fresh sign-in (single-use marker), the typed text is not replayed after the IdP round trip (notice instead). The pre-existing compile warning in `event_dispatcher/server.ex` (unreachable clause, elixir 1.20 only) is untouched.
