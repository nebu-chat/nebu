---
story_id: persistent-consent-grants
title: "Remember OAuth consent grants per user and client"
epic: oauth-session-and-consent
status: done
security_review: required
matrix: false
ui: true
traceability_id: REQ-2026-003
created: 2026-10-30
---

## Story

**As** a Nebu user who has already allowed an OAuth client, **I want** Nebu to remember my "Allow" decision for that client and the scope I granted, **so that** I am not asked to consent again on every new login while the IdP login and freshness rules still apply.

## Acceptance Criteria

```gherkin
Feature: Persistent OAuth consent grants

  Scenario: First login with a client asks for consent
    Given user "alice" has no consent grant for an approved client "fluffychat"
    When alice authorizes "fluffychat" with scope "openid"
    Then the consent screen is shown to alice

  Scenario: Second login with the same client skips consent
    Given alice has allowed "fluffychat" with scope "openid"
    When alice starts a new authorization request for "fluffychat" with scope "openid"
    Then the authorization code is issued without showing the consent screen

  # Amended in the ATDD step (test review MINOR-4): the scope parser drops `profile` / `email` and never grants them, so they cannot widen a request.
  # What is observable today: `openid` (or a different Matrix prefix) widens a scope; profile / email do not.
  Scenario: Broader scope asks for consent again
    Given alice has allowed "fluffychat" with scope "api" (without "openid")
    When alice starts an authorization request for "fluffychat" with scope "openid"
    Then the consent screen is shown to alice

  Scenario: Unknown scope tokens do not widen the scope
    Given alice has allowed "fluffychat" with scope "openid"
    When alice starts an authorization request for "fluffychat" with scope "openid profile email"
    Then the authorization code is issued without showing the consent screen
    And the code carries neither "profile" nor "email"

  Scenario: Changed redirect URI asks for consent again
    Given alice has allowed "fluffychat" for redirect URI "https://a.example/cb"
    When alice starts an authorization request for "fluffychat" with redirect URI "https://b.example/cb"
    Then the consent screen is shown to alice

  Scenario: Another user is asked for consent
    Given alice has allowed "fluffychat" with scope "openid"
    When user "bob" authorizes "fluffychat" with scope "openid"
    Then the consent screen is shown to bob

  Scenario: Revoked client asks for consent again after re-approval
    Given alice has allowed "fluffychat" with scope "openid"
    And the admin has revoked the client "fluffychat"
    When the admin approves "fluffychat" again and alice authorizes it with scope "openid"
    Then the consent screen is shown to alice

  Scenario: prompt=consent always shows the consent screen
    Given alice has allowed "fluffychat" with scope "openid"
    When alice starts an authorization request for "fluffychat" with scope "openid" and prompt "consent"
    Then the consent screen is shown to alice

  Scenario: GDPR erasure removes the user's consent grants
    Given alice has allowed "fluffychat" with scope "openid"
    When alice is erased under GDPR erasure
    Then no consent grant for alice remains

  Scenario: User withdrawal removes the grant
    Given alice has allowed "fluffychat" with scope "openid"
    When alice withdraws the grant for "fluffychat" on the OAuth account page
    Then her next authorization request for "fluffychat" shows the consent screen
```

## Definition of Done

- [x] All Gherkin scenarios have failing tests (ATDD)
- [x] All tests pass (green)
- [x] Code review clean (0 MAJOR)
- [x] Security review (if required) clean (Kassandra cycle 0 and delta cycle 1 APPROVED)
- [x] UX review: 0 blocking, 4 MINOR fixed
- [x] Docs updated (arc42 05/06/07/08, ADR-033, GDPR deletion runbook, CHANGELOG)
- [ ] E2E in the https stack: NOT run. Playwright scenarios 1, 2 and 9 of `e2e/features/oauth/oauth-consent-grants.feature` did not run against the https stack: scenario 1 passed on the plain-http gate stack; scenarios 2 and 9 need the https `e2e-oauth-https` job. The `@oauth-consent-grants` tag is excluded from the plain admin e2e job (`not @oauth-consent-grants` in `scripts/e2e-ci.sh`).

## Decisions

All verified against the code; pinned by the tests of the ATDD step (`server/test/nebu/oauth/consent_grant_*_test.exs`, `server/test/nebu/migration/000057_oauth_consent_grants_test.exs`). The dev may deviate only with a note here.

- (ATDD step) WHERE the decision is taken: in the IdP callback (`Nebu.OAuth.Authorize`), after the IdP login, gate l, provisioning, the freshness verdict, the device-holder check and the encryption of the IdP refresh token, i.e. at the place where the consent row is created today. The user is only known there. A remembered Allow mints the code through `Nebu.OAuth.Consent.issue_remembered/4` (`Consent` stays the only caller of `CodeStore.insert`, the static test of oauth-authorize-freshness AC1.2 stays green) with exactly the attributes of an Allow, and redirects to the client (`303`, `code`, `state`, `iss`, the request's response mode). No consent row, no consent cookie, no write to the grant table on the skip path. Everything else (IdP errors, gate l, deactivated user, device in use) behaves as before.
- (ATDD step) Table `oauth_consent_grants` (migration 000057): one row per (user, client): `scope` (normalised: sorted unique tokens WITHOUT the per-login `<prefix>device:<id>` token, because matrix-js-sdk / FluffyChat use a new device id for every login), `redirect_uri` (exact), `client_approved_at` (identity binding = `oauth_clients.approved_at` at the Allow), `created_at` (first Allow, never rewritten), `granted_at` (latest Allow). Runtime role: `SELECT, INSERT, DELETE` plus column level `UPDATE (scope, redirect_uri, client_approved_at, granted_at)`; RLS forced. Also `oauth_authz_requests.force_consent BOOLEAN NOT NULL DEFAULT false` (carries `prompt=consent` from authorize to the callback).
- (ATDD step) "Same client": a revocation is final for a registration (000046 guard trigger, DCR dedup keeps the revoked row; changed metadata is a NEW `client_id` with no grant), so scenario 6 ("approved again") is only reachable through the owner override. The grants are deleted in the revoke transaction (a failing audit or a failing delete rolls the revocation back), and `client_approved_at` makes a surviving row (race, backup, operator SQL) useless for a client whose `approved_at` is new.
- (ATDD step) Scenario 3 as originally worded was not observable (the Gherkin above is amended accordingly): `profile` and `email` are unknown tokens that the existing scope parser drops and never grants, so "openid profile email" after a grant for "openid" is the SAME narrowed scope and skips (pinned). What a broader scope can mean today is `openid` (and the Matrix prefix): a grant without `openid` asks again for a request with `openid`. A narrower request skips and the code carries only the requested scope (the skip never widens). The Matrix prefix is part of the token (another prefix asks again).
- (ATDD step) An Allow REPLACES scope and redirect URI with what the user just allowed (it never merges grants the user did not just click): a narrower Allow narrows the grant, another registered redirect URI MOVES it (one redirect URI per grant, so alternating URIs ask every time). Deny remembers nothing and leaves an existing grant alone. The write happens AFTER the code was issued and never fails the Allow (value-free warning, the user is asked again next time).
- (ATDD step) Skip rule, in ONE statement that joins the client row (the revoke wins the race): client `approved`, grant of this user and client, exact redirect URI, requested scope covered, binding equals the client's current `approved_at`, no `prompt=consent` (`consent` among the space separated, case sensitive values, also `login consent`). An unreadable grant table never skips (consent screen). The skip applies whatever the freshness verdict is: a DELIBERATE choice of the owner, under review by Kassandra in the security step. Reason: the IdP login and every gate stay in force, and today the freshness verdict only drives a notice on the consent screen (it never refuses a login); the code carries the same raw `auth_time`. One-line alternative if the review rejects it: add `login_fresh` to the skip condition in `Authorize.remembered?/2` (skip only after a fresh IdP login) and flip the test "the freshness verdict does not matter" in `consent_grant_flow_test.exs`.
- (ATDD step) Accepted limits (owner decision): one redirect URI per grant (alternating registered URIs ask every time), no expiry of a grant (withdrawal, revocation and erasure end it), and a withdrawal does not end existing sessions or refresh tokens.
- (ATDD step) A deactivated user with a live grant is not skipped through: the provisioning gate runs before the skip decision (access_denied, no code, no consent screen, grant untouched).
- (ATDD step) Withdrawal: new account page `/account/apps` (nav "Apps") listing the user's OWN grants of approved clients (claimed name escaped, website host, date) and `POST /account/apps/withdraw` (`csrf_token`, `client_id`; CSRF and the lenient `BrowserPost` rules of the device sign-out; notices `grant_withdrawn` / `grant_not_found`; PRG `303`). NOT gated on a fresh sign-in (it only removes a convenience) and it does NOT end existing sessions or refresh tokens (the page says so; signing a device out is the Devices page). A grant of another user or an unknown client id is `grant_not_found` and nothing changes.
- (ATDD step) GDPR erasure: `oauth_consent_grants` is added to `UserDeletion.erased_tables/0` (a failing delete rolls the erasure back with the step `delete_oauth_consent_grants`); the operator sweep and the runbook list it; the schema recurrence guard sees the table.
- (ATDD step) Existing tests that log in twice with the same user and client: `TestSupport.finish_allow/3` (and so `flow_code!/4`, `session!/4`) returns the callback's own code redirect when the user is not asked, and the three holder tests of `oauth_consent_flow_test.exs` that need the screen use `prompt=consent`.
- (ATDD step, cycle 1) After code review, Kassandra and UX review: (a) the skip needs the device state `:new` or `{:same_client, _}`; a device that would REPLACE another session (legacy session or device row on the requested id) shows the consent screen (Kassandra MEDIUM #1); (b) `prompt=login` forces the screen like `prompt=consent`, carried by the existing `force_consent` flag, no new column (LOW #2); `prompt=none` is unchanged; (c) the rollout window (a `prompt` request started on an old node may be skipped by a new node) is documented in 07-deployment and CHANGELOG (LOW #3); (d) the Website column shows the stored `client_host`, never the claimed `client_uri` host (INFO #4), fallback "unknown website"; (e) the sign-in started at `/account/apps` returns there: this needs `'apps'` in the action CHECK of `oauth_account_login_requests` (000043), widened inside migration 000057; (f) UX wording: button name `Withdraw the permission of <name> (<host>)`, intro "apps you have allowed to use your Matrix account", the longer empty state, title and h1 both "Apps you have allowed"; (g) the stale "consent on every authorization" prose in moduledocs / 05 / 06 / 07 is updated and pinned by `consent_grant_docs_test.exs`.
