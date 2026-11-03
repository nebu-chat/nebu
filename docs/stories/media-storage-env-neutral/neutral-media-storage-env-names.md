---
story_id: neutral-media-storage-env-names
title: "Neutral media storage environment variable names (hard break)"
epic: media-storage-env-neutral
status: done
security_review: required
matrix: false
ui: false
traceability_id: REQ-2026-001
created: 2026-11-02
---

## Story

**As** a server operator, **I want** the object store environment variables named neutrally as `NEBU_MEDIA_STORAGE_*` instead of the MinIO-specific `NEBU_MINIO_*` (and `NEBU_TEST_MINIO_ENDPOINT` becomes `NEBU_TEST_MEDIA_STORAGE_ENDPOINT`), **so that** configuration does not reference a discontinued product, and I am clearly told that the old names are no longer read, because they are a hard break with no fallback.

## Acceptance Criteria

```gherkin
Feature: Neutral media storage environment variables

  Scenario: Server reads object store settings from the neutral names
    Given the environment sets NEBU_MEDIA_STORAGE_ENDPOINT and NEBU_MEDIA_STORAGE_BUCKET
    When the server starts
    Then media uploads and downloads use that endpoint and bucket

  Scenario: The *_FILE secret variant keeps precedence over the plain variable
    Given NEBU_MEDIA_STORAGE_SECRET_KEY_FILE points to a readable file and NEBU_MEDIA_STORAGE_SECRET_KEY is also set
    When the server loads the storage configuration
    Then the secret read from the file is used

  Scenario: Legacy NEBU_MINIO_* names are ignored and not read
    Given a deployment still sets NEBU_MINIO_ENDPOINT and does not set NEBU_MEDIA_STORAGE_ENDPOINT
    When the server starts
    Then the default endpoint "minio:9000" is used and the legacy NEBU_MINIO_ENDPOINT value is not read

  Scenario: The breaking change is documented for operators
    Given the release containing the rename is prepared
    When an operator reads the CHANGELOG and the deployment documentation
    Then the CHANGELOG has a breaking-change entry listing every removed NEBU_MINIO_* name with its NEBU_MEDIA_STORAGE_* replacement, and the operator-facing deployment note says that old names are silently ignored

  Scenario: Object store credentials never appear in logs or errors
    Given object store credentials are configured through the neutral variables
    When the server logs its startup configuration or reports a storage error
    Then neither the access key nor the secret key value appears in any log line or error message
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean
