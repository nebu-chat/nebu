---
story_id: media-storage-uses-admin-config
title: "Media storage operations use the admin-saved storage target"
epic: media-storage-admin-target
status: ready
security_review: required
matrix: false
ui: false
traceability_id: REQ-2026-001
created: 2026-10-29
---

## Story

**As** a server operator, **I want** the object storage target saved under /admin/media/settings to be used by all real media uploads, downloads, deletes and archive copies, **so that** a corrected endpoint or bucket takes effect without a restart and media operations stop failing against a wrong host.

## Acceptance Criteria

```gherkin
Feature: Media storage operations use the admin-saved storage target

  Scenario: Saved admin storage target is used at call time
    Given the admin has saved a storage endpoint and bucket in /admin/media/settings
    When a user uploads a media file
    Then the object is stored at the saved endpoint and bucket without a server restart

  Scenario: Nothing saved in the admin settings keeps the environment configuration
    Given no storage settings have been saved in the admin settings
    When a media file is stored, fetched, deleted or copied to the archive
    Then the environment and default values are used, including endpoint "minio:9000", bucket "nebu-media" and archive bucket "nebu-media-archive"

  Scenario: Blank endpoint is rejected without a request
    Given the effective storage endpoint resolves to an empty host
    When a media upload is attempted
    Then no HTTP request is sent to the storage service and the upload fails with the existing "Failed to store media file" error

  Scenario: Every storage operation resolves the saved target, including the archive bucket
    Given the admin has saved an endpoint, region, credentials, bucket and archive bucket
    When a media file is stored, fetched, deleted or copied to the archive bucket
    Then each of the five operations addresses the saved endpoint with the saved credentials and its saved bucket

  Scenario: Storage credentials never appear in logs or error values
    Given storage credentials are configured and a storage operation fails
    When the failure is logged and returned to the caller
    Then neither the access key nor the secret key appears in any log line, error value or exception message, also at debug level

  Scenario: Saved credentials are only used for the endpoint they belong to
    Given a storage endpoint is saved in the admin settings
    When a storage operation resolves its credentials
    Then the saved key pair is used, the environment credentials are used only for the environment's own endpoint, and any other combination fails without sending a request

  Scenario: Changing the endpoint requires entering both keys again
    Given a storage target is saved
    When the admin saves a changed endpoint or Use SSL setting without typing both keys, or with only one key
    Then nothing is saved and the form explains that both keys are required

  Scenario: Empty NEBU_MINIO_ENDPOINT aborts boot
    Given NEBU_MINIO_ENDPOINT is set to an empty or whitespace-only value in a production or development environment
    When the server boots
    Then boot aborts with a message naming NEBU_MINIO_ENDPOINT

  Scenario: Unset NEBU_MINIO_ENDPOINT keeps the default endpoint
    Given NEBU_MINIO_ENDPOINT is not set in a production or development environment
    When the server boots
    Then the storage endpoint defaults to "minio:9000"
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean
