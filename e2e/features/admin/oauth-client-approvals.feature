@oauth-approvals
Feature: Admin UI — OAuth client registration approvals
  As an authenticated admin operator
  I want to review pending OAuth client registrations (Dynamic Client Registration)
  So that only approved applications can ever be used to access my users' accounts

  # Story: oauth-broker / oauth-metadata-dcr-admin-approval (AC4) — ATDD: written first, since implemented (the scenarios
  # are expected GREEN; they run only against the full compose stack with Dex).
  # Framework: playwright-bdd + Cucumber. Step definitions:
  #   e2e/step-definitions/admin/oauth-client-approvals.steps.ts
  #
  # Real flows only (no cookie forging, no DB seeding of clients):
  #   * the operator logs in through the real Dex OIDC flow (shared Background steps)
  #   * pending clients are created by POSTing to the REAL  POST /oauth2/register  endpoint
  #   * Approve / Reject are clicked in the REAL Admin UI
  #   * the DB is only READ to verify the persisted decision + audit entry
  #
  # Admin UI contract (shared with server/test/nebu/oauth/oauth_admin_test.exs):
  #   * sidebar group "OAuth" (parent toggle button[data-navkey="oauth"], expanded by default)
  #     -> child link "Pending Clients" a[data-navkey="oauth-pending-clients"]
  #     -> GET /admin/oauth/registrations   (page root [data-page="oauth-registrations"])
  #   * one row per pending client [data-role="oauth-client-row"][data-client-id=ID] with the
  #     cells [data-field="client-name"] [data-field="client-uri"] [data-field="redirect-uris"]
  #     [data-field="logo"] [data-field="created"]. The logo cell shows the logo URL as TEXT
  #     ([data-role="logo-url"], host in [data-role="logo-host"]); an <img> only appears after the
  #     operator clicked "Load logos" (GET ?logos=1, [data-role="load-logos"] / "hide-logos") —
  #     decision cycle 0 #2: by default the admin's browser never contacts client-hosted URLs and
  #     the Content-Security-Policy stays strict (img-src 'self' data:); only the ?logos=1 response
  #     widens img-src, to the exact logo origins on that page
  #   * the list is paginated (50 per page, ?page=N): [data-role="pending-summary"] (data-total),
  #     [data-role="more-pending"] (data-more, "N more pending"), nav [data-role="pagination"] with
  #     [data-role="page-next"] / [data-role="page-prev"] — never silently truncated (decision #1)
  #   * per-row [data-role="reject-client"] submit button in a per-row form; the confirmation step is a
  #     NATIVE confirm() (form `data-confirm`, wired by the external admin app.js — same pattern as the
  #     device-revoke flow, NOT a modal). A native confirm() cannot collect text, so the reject form has
  #     an always-visible optional text input [name="reason"] that the operator fills BEFORE clicking Reject
  #   * story oauth-client-revocation (P4, SO3/SO4): Approve is the LINK a[data-role="review-approve"] to the
  #     confirm page ([data-page="oauth-approve-confirm"], form [data-role="approve-confirm-form"], button
  #     [data-role="approve-confirm"]; no native confirm()). Approving needs a FRESH admin sign-in: the first
  #     approval of a session passes the Dex login form again, the approval then reuses that marker for 300 s
  #     (helper e2e/fixtures/oauth-admin.ts). The "approves the pending client" steps drive exactly that
  #     (the compose env NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME=true lets the dev Dex, which omits auth_time,
  #     pass; production IdPs must send auth_time)
  #   * after a decision: success toast [data-role="toast"] and the row is gone from the list
  #   * empty state [data-role="no-pending-clients"]
  #
  # Exception to "no DB seeding of clients": the pagination scenario seeds 55 pending rows directly
  # (fixtures/db.ts insertPendingOAuthClients) because POST /oauth2/register is rate limited to 50
  # requests/hour per IP, so more than one page cannot be created through the real endpoint.
  #
  # Story oauth-dcr-abuse-hardening (P2, AC15), scenarios @ac-bulk-remove-host, @ac-bulk-remove-age,
  # @ac-public-suffix, @ac-bulk-remove-keyboard. Admin UI contract (shared with oauth_admin_test.exs):
  #   * each list row has a link [data-role="bulk-remove-domain"] (aria-label "Remove all pending
  #     registrations of <registrable domain>") to GET /admin/oauth/registrations/bulk-remove?host=..&match=domain
  #   * the list page has the form [data-form="bulk-remove"] (inputs host, match radios, older_than_days)
  #   * the preview shows [data-role="bulk-match-count"] ("N pending registrations match") and the confirm
  #     form [data-form="bulk-remove-confirm"] with a native confirm() and the button
  #     [data-role="bulk-remove-confirm"]; success => redirect to the list with a toast
  #   * badges on the rows: [data-role="shared-hosting-warning"] / [data-role="public-suffix-error"]
  # Real flows only: clients are registered through the REAL endpoint (unique registrable test domains
  # e2e-bulk-<rand>.org, so the scenarios never touch foreign registrations). The one exception: the age
  # scenario seeds rows 40 days old via fixtures/db.ts insertAgedPendingOAuthClients (age cannot be
  # produced through the endpoint; same exception as the pagination scenario). The only database reads
  # are the removed rows and the audit entry; the cleanup is the existing After hook (name prefix).
  #
  # Hygiene (shared DB): an @oauth-approvals After hook resets oauth_enabled to 'false' and deletes
  # this feature's e2e-oauth-* registrations (privileged DB role; failures are loud). The empty-state
  # scenario never decides foreign pending registrations — it fails with a clear message instead.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And OAuth is enabled in the instance config
    And the operator is logged in as admin

  @ac4-list
  Scenario: [AC4] Admin views the list of pending client registrations only
    Given 3 clients are registered via Dynamic Client Registration
    And 2 more clients are registered and approved by the operator
    When the operator opens "Pending Clients" from the OAuth admin menu
    Then the page lists exactly the 3 pending registrations of this scenario
    And each pending row shows client name, client URI, redirect URIs, the logo URL as text, created time, an Approve and a Reject button
    And the page marks the client details as unverified and each row shows its application type and host-bound redirect URIs
    And none of the approved clients is listed

  @ac4-logos-on-click
  Scenario: [Decision 2] Client logos are only loaded on click, the image policy is strict by default
    Given 2 clients are registered via Dynamic Client Registration
    When the operator opens "Pending Clients" from the OAuth admin menu
    Then no logo image is rendered and the browser did not contact any client-hosted URL
    And the logo URL of each pending row is shown as text with its host
    When the operator requests the logos via the Load logos control
    Then each pending row renders its logo image with referrer policy "no-referrer"
    And only this response widens the image policy, to the exact logo origin
    When the operator hides the logos again
    Then the image policy is strict again and no logo image is rendered

  @ac4-pagination
  Scenario: [Decision 1] The pending list is paginated and never silently truncated
    Given 55 pending registrations are seeded directly in the database
    When the operator opens "Pending Clients" from the OAuth admin menu
    Then the first page lists 50 registrations and states the pending total and how many are still pending
    And a "Next page" link is offered but no "Previous page" link
    When the operator follows the Next page links until the last page
    Then all 55 seeded registrations were listed exactly once across the pages
    And the last page offers no "Next page" link and no more-pending hint

  @ac4-approve
  Scenario: [AC4] Admin approves a pending registration
    Given 1 client is registered via Dynamic Client Registration
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator approves the pending client
    Then a success toast is shown
    And the client is no longer listed as pending
    And the client's status in the database is "approved" with the admin recorded as approver
    And an audit entry "oauth_client_approved" exists for the client

  @ac4-reject
  Scenario: [AC4] Admin rejects a pending registration with a reason
    Given 1 client is registered via Dynamic Client Registration
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator rejects the pending client with the reason "Unknown vendor"
    Then a success toast is shown
    And the client is no longer listed as pending
    And the client's status in the database is "rejected" with the admin recorded as rejecter
    And an audit entry "oauth_client_rejected" with the reason "Unknown vendor" exists for the client

  # Story safari-fetch-metadata-compat (AC9): Safari sends no Sec-Fetch-User, so the strict admin forms carry a hidden
  # _click_proof field that a shared script (app.js) fills on a TRUSTED click. A real Chromium click must post it.
  @safari-click-proof
  Scenario: [Safari compat] The reject request of a real browser click carries the click proof
    Given 1 client is registered via Dynamic Client Registration
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator rejects the pending client with the reason "Click proof" and records the request
    Then the recorded reject request carried the click proof "1"
    And the client's status in the database is "rejected" with the admin recorded as rejecter

  @ac4-reject-keeps-registration
  Scenario: [AC4] A rejected registration is kept; re-registering returns the same client id and stays rejected
    Given 1 client is registered via Dynamic Client Registration
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator rejects the pending client with the reason "Not allowed"
    And the same client registers again with identical metadata
    Then the registration returns the same client id as before
    And the client's status in the database is "rejected" with the admin recorded as rejecter

  @ac4-empty
  Scenario: [AC4] Empty state when nothing is pending
    Given no client registration is pending
    When the operator opens "Pending Clients" from the OAuth admin menu
    Then the empty state "no pending client registrations" is shown

  @ac4-auth
  Scenario: [AC4] An unauthenticated visitor cannot reach the approval page
    Given an anonymous visitor without an admin session
    When the visitor opens the pending client registrations page
    Then the visitor is redirected to the admin login page

  # ── Story oauth-dcr-abuse-hardening (AC15) ─────────────────────────────────────

  @ac-bulk-remove-host
  Scenario: [AC15.1] The operator removes all pending registrations of one registrable domain
    Given 3 clients are registered via Dynamic Client Registration on one test domain
    And 1 client is registered via Dynamic Client Registration on another test domain
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator follows the bulk-remove link of the test domain
    Then the preview states "3 pending registrations match"
    When the operator confirms the removal of the pending registrations
    Then a success toast is shown
    And the 3 registrations of the test domain are gone from the database
    And the registration of the other domain is still pending
    And one audit entry "oauth_clients_bulk_removed" with removed 3 exists for these registrations

  @ac-bulk-remove-age
  Scenario: [AC15.2] The operator removes only the old pending registrations of a domain
    Given 3 pending registrations of the test domain are seeded 40 days old directly in the database
    And 1 client is registered via Dynamic Client Registration on one test domain
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator previews the removal for the test domain older than 30 days
    Then the preview states "3 pending registrations match"
    When the operator confirms the removal of the pending registrations
    Then a success toast is shown
    And the 3 seeded registrations are gone and the fresh registration is still pending
    And one audit entry "oauth_clients_bulk_removed" with removed 3 exists for the seeded registrations

  @ac-public-suffix
  Scenario: [AC15.3] A public-suffix client URI is refused; a shared-hosting client is listed with a warning badge
    When a client tries to register with the public suffix client URI "https://github.io"
    Then the registration is refused with "invalid_client_metadata"
    Given a client is registered on a shared hosting subdomain of "github.io"
    When the operator opens "Pending Clients" from the OAuth admin menu
    Then that client's row shows the shared hosting warning for "github.io"

  @ac-bulk-remove-keyboard
  Scenario: [AC15.4] The bulk removal can be completed with the keyboard only and the preview is accessible
    Given 2 clients are registered via Dynamic Client Registration on one test domain
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator opens the bulk-remove preview with the keyboard only
    Then the preview states "2 pending registrations match"
    And the page has no detectable accessibility violations
    When the operator confirms the removal with the keyboard only
    Then a success toast is shown
    And the 2 registrations of the test domain are gone from the database

  @ac-bulk-invalid
  Scenario: [AC15.5] An invalid bulk-removal criterion is explained next to the field it belongs to
    Given 1 client is registered via Dynamic Client Registration on one test domain
    When the operator opens "Pending Clients" from the OAuth admin menu
    And the operator previews the bulk removal with the host "a b"
    Then the invalid host is announced and wired to its label, error and match group
    And the preview offers no removal
