Feature: OAuth 2.0 authorization endpoint (broker)
  As a Matrix user of an OAuth-capable client
  I want to be sent from the client to Nebu's authorization endpoint, sign in at the IdP and come back with a code
  So that only admin-approved applications can start a login and they never see my IdP credentials

  # Story: oauth-broker / oauth-authorize-idp-delegation-code (AC2-AC8, AC12, AC13) — ATDD RED phase:
  # written before the implementation; runs only against the full compose stack with the real Dex.
  # Framework: playwright-bdd (admin-ui project, baseURL = Nebu at http://localhost:8008).
  # Step definitions: e2e/step-definitions/oauth/oauth-authorize.steps.ts
  #
  # Real flows: the browser opens Nebu's REAL GET /oauth2/authorize, is sent to the REAL Dex (the one
  # IdP client, shared callback /_matrix/client/v3/login/sso/redirect/oidc) and signs in there.
  # The CLIENT side does not exist in the stack: the client redirect URIs (http://localhost:<port>/cb,
  # https://app.e2e.example/cb) are intercepted with page.route() and answered with a stub page, so the
  # final URL (code / error, state, iss) can be inspected. Nothing listens there.
  #
  # Exception to "no DB seeding": the fixture clients (approved / pending / rejected) are inserted
  # through the privileged DB role (fixtures/db.ts insertOAuthClient: INSERT pending + UPDATE, the
  # 000040 invariant) — approving through the Admin UI is covered by oauth-client-approvals.feature.
  #
  # Page contract (shared with server/test/nebu/oauth/oauth_pages_test.exs):
  #   <main data-page="oauth-error" data-error="<code>"> with one <h1>; no <script>; CSP default-src 'none'.
  #
  # Story oauth-authorize-freshness (P3, FR1): a successful IdP login no longer ends at the client. The
  # callback answers 303 to Nebu's consent page (/oauth2/consent) and the code is issued only after
  # "the user allows the app" (the consent screen itself is covered by oauth-consent.feature).
  #
  # Hygiene: an @oauth-authorize After hook resets oauth_enabled to 'false', restores the prior
  # oauth_issuer_url and deletes the e2e-oauth-authz-* clients (cascade removes their requests/codes).

  Background:
    Given OAuth is enabled with an https issuer
    And an approved native client "e2e-oauth-authz-native" with redirect URI "http://localhost/cb"

  @oauth-authorize @ac2
  Scenario: Pending client sees an accessible notice and is not redirected
    Given a pending web client "e2e-oauth-authz-pending"
    When the browser opens the authorize URL of "e2e-oauth-authz-pending" with valid parameters
    Then the page has the heading "This app is waiting for approval"
    And the page shows the next step "Ask your administrator to review and approve the app."
    And the inline style of the page is applied under the CSP
    And the page is marked as OAuth error "client_pending"
    And the browser stays on the Nebu authorize URL
    And the page contains no script element
    And the response has a Content-Security-Policy starting with "default-src 'none'"

  @oauth-authorize @ac2
  Scenario: Rejected client sees an accessible notice and is not redirected
    Given a rejected web client "e2e-oauth-authz-rejected"
    When the browser opens the authorize URL of "e2e-oauth-authz-rejected" with valid parameters
    Then the page has the heading "This app is not approved"
    And the page shows the next step "Use another app that is approved for this server."
    And the page is marked as OAuth error "client_rejected"
    And the browser stays on the Nebu authorize URL

  @oauth-authorize @ac2
  Scenario: Unknown client gets an error page
    When the browser opens the authorize URL with client_id "does-not-exist"
    Then the page has the heading "This app is not known to this server"
    And the page shows the next step "Check that you opened the right app."
    And the page is marked as OAuth error "unknown_client"
    And the browser stays on the Nebu authorize URL

  @oauth-authorize @ac2 @ac3
  Scenario: Mismatching redirect URI gets an error page, never a redirect
    When the browser opens the authorize URL of "e2e-oauth-authz-native" with redirect URI "https://evil.example.com/cb"
    Then the page is marked as OAuth error "invalid_redirect_uri"
    And the page does not contain "evil.example.com"

  @oauth-authorize @ac4
  Scenario: Missing PKCE is reported to the client as invalid_request with iss
    When the browser opens the authorize URL of "e2e-oauth-authz-native" on port 53682 without code_challenge
    Then the client receives the redirect at "http://localhost:53682/cb"
    And the redirect query has "error" = "invalid_request"
    And the redirect query has the request's "state"
    And the redirect query has "iss" = the Nebu issuer
    And the redirect query has no "errcode"

  @oauth-authorize @ac6 @ac7 @ac8
  Scenario: Happy path through the IdP ends at the client with a code
    When the browser opens the authorize URL of "e2e-oauth-authz-native" on port 53682 with scope prefix "urn:matrix:org.matrix.msc2967.client:"
    And the user signs in at the IdP
    And the user allows the app
    Then the client receives the redirect at "http://localhost:53682/cb"
    And the redirect query has a "code"
    And the redirect query has the request's "state"
    And the redirect query has "iss" = the Nebu issuer

  @oauth-authorize @ac5 @ac8
  Scenario: Element-Web-shaped request (https redirect URI, response_mode=query) succeeds in the query
    Given an approved web client "e2e-oauth-authz-web" with redirect URI "https://app.e2e.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-authz-web" with response_mode "query", scope "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj" and a nonce
    And the user signs in at the IdP
    And the user allows the app
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"
    And the redirect query has "iss" = the Nebu issuer

  @oauth-authorize @ac7
  Scenario: Replaying the IdP callback shows an expired-link page
    Given a completed authorization for "e2e-oauth-authz-native"
    When the browser opens the same IdP callback URL again with the original binding cookie
    Then the page has the heading "This sign-in link cannot be used"
    And the page shows the next step "Start signing in again from your app."
    And the page is marked as OAuth error "invalid_state"
