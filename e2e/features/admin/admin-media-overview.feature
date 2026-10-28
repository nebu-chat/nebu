Feature: Admin Media Overview — /admin/media table (filter + pagination)

  As an admin (e.g. Kai, instance_admin), I want to browse all media files in a
  filterable, paginated table — by state, uploader, MIME-type, and upload date —
  so that I can find files needing attention (an infected upload, a stuck scan, a
  specific user's uploads) without scrolling through the entire media_files table.

  # Story: docs/stories/media-security-admin-control/5a-admin-media-table.md
  # UX mockup Key Flow step 1: "Kai triages an infected upload".
  #
  # Media rows are seeded directly via fixtures/db.ts (insertMediaFile) — a real
  # infected/scanned row requires a genuine async ClamAV round-trip (Oban-queued),
  # far too slow/nondeterministic for a page-render/filter/pagination check. This
  # mirrors the already-approved direct-DB-seed mechanism used throughout this
  # E2E suite (see fixtures/db.ts's own header comment on operational_logs seeding
  # for the precedent and rationale — no test-only HTTP routes, ever).

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @media-security-admin-control @ac1-ac2 @5a-admin-media-table
  Scenario: The page renders the table for a seeded infected file
    Given an infected media file "e2e-media-infected-1" has been seeded
    When the operator navigates to "/admin/media"
    Then the page shows "Medien"
    And the media table shows a row for "e2e-media-infected-1" with state "Infiziert"

  # @known-failure (e2e/KNOWN-FAILURES.md, K3): the state-filter pill leaves one row that the scenario expects to be filtered out; failing identically on the commit before the oauth-broker stories
  @media-security-admin-control @ac3 @5a-admin-media-table @known-failure
  Scenario: A state-filter pill click narrows the visible rows
    Given an infected media file "e2e-media-filter-infected" has been seeded
    And a released media file "e2e-media-filter-released" has been seeded
    When the operator navigates to "/admin/media"
    And the operator clicks the "Infiziert" state filter pill
    Then the media table shows a row for "e2e-media-filter-infected"
    And the media table does not show a row for "e2e-media-filter-released"

  # @known-failure (e2e/KNOWN-FAILURES.md, K4): after 'Weitere laden' the table shows 50 instead of 55 rows; failing identically at the baseline
  @media-security-admin-control @ac4 @5a-admin-media-table @known-failure
  Scenario: "Weitere laden" appends more rows without a full page reload
    Given 55 released media files sharing uploader "e2e-media-loadmore-uploader" have been seeded
    When the operator navigates to "/admin/media" filtered to uploader "e2e-media-loadmore-uploader"
    Then the media table shows 50 rows
    When the operator clicks the "Weitere laden" button without a page reload
    Then the media table shows 55 rows
    And no full page navigation occurred
