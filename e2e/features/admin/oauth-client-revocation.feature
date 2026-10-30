@oauth-revocation
Feature: Admin UI — withdrawing an approved OAuth client and the fresh sign-in for client decisions
  As an authenticated admin operator
  I want to approve a client only after signing in again, and to withdraw an approved client for good
  So that a mistaken approval can be undone and a script in another web app on this origin cannot decide for me

  # Story: oauth-broker / oauth-client-revocation (P4, AC10) — ATDD: written first, run only against the full
  # compose stack with Dex (they are typechecked and bddgen'ed in the isolated environment, never executed there).
  # Framework: playwright-bdd + Cucumber. Step definitions:
  #   e2e/step-definitions/admin/oauth-client-revocation.steps.ts   (helpers: e2e/fixtures/oauth-admin.ts)
  #
  # Real flows only: the client registers through the REAL POST /oauth2/register, the operator approves and
  # revokes in the REAL Admin UI (confirm pages, fresh sign-in through Dex), the DB is only READ.
  #
  # Admin UI contract (shared with server/test/nebu/oauth/oauth_admin_clients_test.exs):
  #   * sidebar "OAuth" gains a[data-navkey="oauth-approved-clients"] -> /admin/oauth/clients
  #     ([data-page="oauth-clients"], rows [data-role="oauth-approved-row"][data-client-id], cells
  #     data-field="client-name|application-type|approved-by|approved-at|last-used|sessions", the verified host
  #     in [data-role="client-host"], link [data-role="revoke-client"]) and a[data-navkey="oauth-revoked-clients"]
  #     -> /admin/oauth/clients/revoked ([data-page="oauth-revoked-clients"], rows [data-role="oauth-revoked-row"],
  #     cells data-field="revoked-by|revoked-at|revoked-reason")
  #   * revoke confirm page /admin/oauth/clients/:id/revoke ([data-page="oauth-revoke-confirm"]): the verified host
  #     [data-role="client-host"], the live device count [data-role="revoke-device-count"], the form
  #     [data-role="revoke-confirm-form"] with [name="confirm_host"] (the host must be typed), [name="reason"] and
  #     the submit [data-role="revoke-confirm"]; success => redirect to the approved list with a [data-role="toast"]
  #   * the POSTs of approve / revoke need the fresh sign-in marker and the fetch metadata of a user-clicked form
  #     submit; a fetch() from a page script is answered 403 (error page data-error="fetch_metadata")
  # The compose env NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME=true is what lets the dev Dex (no auth_time claim)
  # pass the fresh sign-in check in these scenarios (documented accepted risk, open question 3 of the story).
  #
  # Hygiene (shared DB): an @oauth-revocation After hook resets oauth_enabled to 'false' and deletes this feature's
  # e2e-oauth-revoke-* registrations (privileged DB role; failures are loud).

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And OAuth is enabled in the instance config
    And the operator is logged in as admin

  # Story admin-reauth-button-flow: the state is shown on the primary control of the confirm pages. Without a fresh sign-in the form shows the link
  # "Sign in again to approve" / "... to revoke" INSTEAD of its submit; after the sign-in the page shows the submit and the validity line.
  @reauth-button
  Scenario: The approve confirm page shows a Sign in again link, after the sign-in the Approve client button and a validity line
    Given a client is registered for the revocation scenarios
    When the operator opens the approve confirm page of the client
    Then the confirm page shows the "Sign in again to approve" link and no "Approve client" button
    When the operator follows the "Sign in again to approve" link and signs in again
    Then the confirm page shows the "Approve client" button, no sign-in link and a validity line

  @reauth-button
  Scenario: The revoke confirm page shows a Sign in again link, after the sign-in the Revoke client button and a validity line
    Given an approved client is registered for the revocation scenarios
    When the operator opens the revoke confirm page of the client
    Then the confirm page shows the "Sign in again to revoke" link and no "Revoke client" button
    When the operator follows the "Sign in again to revoke" link and signs in again
    Then the confirm page shows the "Revoke client" button, no sign-in link and a validity line

  @ac10-approve
  Scenario: [AC10.1] Approving goes through a confirm page and a fresh sign-in; the client then appears under Approved Clients
    Given a client is registered for the revocation scenarios
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator reviews the pending client and approves it on its confirm page
    Then the confirm page showed the verified host of the client before it was approved
    And the operator had to sign in again at the identity provider before the approval was saved
    And a success toast is shown
    When the operator opens the approved clients page from the OAuth admin menu
    Then the client is listed there with its verified host and 0 live sessions
    And the client's database status is "approved" with an approval audit entry

  @ac10-revoke
  Scenario: [AC10.2] Revoking an approved client with its typed host withdraws it for good
    Given an approved client is registered for the revocation scenarios
    When the operator revokes the client by typing its host and the reason "Lost the signing key"
    Then a success toast is shown
    And the client is no longer listed under Approved Clients
    When the operator opens the revoked clients page from the OAuth admin menu
    Then the client is listed there with the reason "Lost the signing key" and the revoking admin
    And the client's database status is "revoked" with exactly one revocation audit entry and no session left
    When the client's authorize URL is opened in the browser
    Then the page is marked as OAuth error "client_rejected"

  @ac10-wrong-host
  Scenario: [AC10.3] A wrong host on the confirm page changes nothing
    Given an approved client is registered for the revocation scenarios
    When the operator tries to revoke the client by typing the host "not-the-host.example.org"
    Then the operator stays on the revoke confirm page with an error message
    And the client's database status is "approved" and no revocation audit entry exists

  @ac10-fetch
  Scenario: [AC10.4] A script on an admin page cannot revoke a client with fetch()
    Given an approved client is registered for the revocation scenarios
    When a script on an admin page posts the revoke form of the client with a fetch request and the correct host
    Then the server answers 403
    And the client's database status is "approved" and no revocation audit entry exists

  @ac10-keyboard
  Scenario: [AC10.5] The revocation can be completed with the keyboard only and its form is labelled
    Given an approved client is registered for the revocation scenarios
    When the operator opens the revoke confirm page of the client
    Then the host and reason inputs of the confirm page are labelled and described
    And the page has no detectable accessibility violations
    When the operator revokes the client with the keyboard only, typing its host and the reason "Lost the signing key"
    Then a success toast is shown
    And the client's database status is "revoked" with exactly one revocation audit entry and no session left
