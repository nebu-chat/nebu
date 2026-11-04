---
story_id: session-lifetime-setting
title: "Admin-configurable Matrix session lifetime"
epic: oauth-session-and-consent
status: ready
security_review: required
matrix: false
ui: true
traceability_id: REQ-2026-002
created: 2026-10-30
---

## Story

**As** an administrator, **I want** to set how long a signed-in Matrix/OAuth session lasts in the admin UI (`/admin/config`), **so that** I can balance security against users being logged out unexpectedly after a fixed 8 hours.

## Acceptance Criteria

```gherkin
Feature: Admin-configurable Matrix session lifetime

  Scenario: Without a saved value a login keeps the 8 hour ceiling
    Given no session lifetime has been saved and NEBU_MATRIX_SESSION_TTL_SECONDS is unset
    When a user signs in to Matrix
    Then the new session's session_expires_at is 8 hours after the login

  Scenario: Saved lifetime applies to the next login
    Given an administrator has saved a Matrix session lifetime of 2 hours on /admin/config
    When a user signs in to Matrix
    Then the new session's session_expires_at is 2 hours after the login

  Scenario: Out-of-range lifetime is refused and nothing is saved
    Given an administrator enters a session lifetime of 100 days, above the 90 day maximum
    When the administrator saves the OAuth settings form
    Then the save is refused, a validation error is shown next to the lifetime field, and the stored value is unchanged

  Scenario: Existing sessions keep the ceiling they were issued with
    Given a user signed in while the lifetime was 8 hours and their session_expires_at is set
    When the administrator saves a lifetime of 2 hours
    Then that user's existing session still expires at its original session_expires_at

  Scenario: Stale fresh-sign-in marker shows the reauth link instead of Save
    Given the administrator's fresh sign-in marker has expired
    When the administrator opens the session lifetime form
    Then the form shows "Sign in again to save" instead of "Save" and submitting the value does not save it

  Scenario: Lifetime change is written to the audit log
    Given the stored session lifetime is 8 hours
    When an administrator saves a session lifetime of 2 hours
    Then an audit entry records the administrator, the setting name, and the old and new values as numbers only
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

- The lifetime stays an ABSOLUTE ceiling from login (a refresh never extends `session_expires_at`); this story makes the length configurable, it does not introduce a sliding window.
- Bounds: whole seconds, 3600 (1 h) to 7 776 000 (90 days). Default stays 8 h when nothing is saved; the env `NEBU_MATRIX_SESSION_TTL_SECONDS` remains the fallback below a saved value.
- The setting applies to every new Matrix session (OAuth and legacy login via `Nebu.Web.SessionConfig.matrix_session_ttl_seconds/0`); sessions already issued keep their ceiling. The admin session ceiling is NOT part of this story.
- The form lives in the OAuth settings of `/admin/config` (`Nebu.Admin.OAuthSwitch`, same fresh-sign-in marker, same "Sign in again to save" / "Save" button flow), shows the current value in hours/days text and a hint that existing sessions keep their ceiling.
- (ATDD step) The form is a SEPARATE section and form on `/admin/config` (`POST /admin/config/session-lifetime`), not a field of the OAuth switch form: the switch pins two keys, an issuer acknowledgement and a kill-switch audit exemption that do not apply to a setting that also governs the legacy login. Same fresh-sign-in marker (bound to `/admin/config`) and button flow; the button reads "Save session lifetime", the stale state the link "Sign in again to save". "Saves the OAuth settings form" in scenario 3 means this form.
- (ATDD step) Storage and audit: `server_config.matrix_session_ttl_seconds` (migration 000056 adds it to the update allowlist; without it the second save fails), audit action `session_lifetime_changed` (`before_seconds`, `after_seconds`: numbers only) in the same transaction as the value; the audit is mandatory for every change, a shorter lifetime is not exempt. The value is read through `Nebu.OAuth.Config` (per-node TTL cache; the saving node uses the new value at once, other nodes within `NEBU_OAUTH_CONFIG_CACHE_MS`).
- (ATDD step) "Unchanged" is judged against the SAVED value only: with nothing saved, entering the value in effect (for example the default 28800) saves it and writes the audit row, so an explicit value can be persisted. A value that cannot be entered (an env value below 3600, as the e2e stack uses) is shown in the field as it is and refused when posted back.
- (ATDD step) "Sessions already issued keep their ceiling" is absolute for OAuth sessions (`matrix_sessions.session_expires_at` is stored per row, copied verbatim by every refresh). A LEGACY session has no stored ceiling: its extension and refresh-reuse bound is `created_at + the CURRENT lifetime` (`MatrixSessionStore`, `RefreshWorker`). A lowered value therefore stops the extension of existing legacy sessions earlier, a raised value lets the worker extend them up to the new bound; `expires_at` is never shortened. Accepted and documented (07-deployment, characterisation test `session_lifetime_legacy_follow_test.exs`), not frozen.
- (ATDD step, cycle 1) A saved lifetime must never turn LONGER because a read failed: each node keeps the last known good saved value (no TTL). An unreadable `server_config`, a missing repository or a damaged / out-of-range row (ignored, never clamped) answers that value; the env value / 8 hours apply only when no good value was ever loaded on the node or after a successful read that found no row (removed on purpose). A deliberate admin save replaces it at once; a read that was already in flight while the save committed cannot overwrite it (compare-and-set). The failed read is not cached. The warning for a damaged row is limited to one per minute per node, names the key and never the value.
