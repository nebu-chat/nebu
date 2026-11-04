---
story_id: oauth-device-default-display-name
title: "Default display name for OAuth-created devices"
epic: oauth-session-and-consent
status: done
security_review: optional
matrix: true
ui: false
traceability_id: REQ-2026-004
created: 2026-10-30
---

## Story

**As** a Matrix user logging in via OAuth from a client that never sets a device name, **I want** the device created for my session to get a default display name derived from the OAuth client (e.g. "FluffyChat (ABCD1234)"), **so that** I can tell my devices apart in the client's device list and on the admin user page and verify the right one.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios):
#  - A client-supplied display name (PUT /devices/{id} or initial_device_display_name) always wins.
#  - A name already set on an existing device is never overwritten; re-login of the same device id keeps it.
#  - Base name = client_name of the approved OAuth client record (Nebu.OAuth.ClientStore).
#    If the client is revoked or unknown, the base name is the plain "OAuth client".
#  - Suffix = short disambiguator from the device id, e.g. " (ABCD1234)".
#  - Base name is stripped of control characters and markup and bounded to a safe length.
#  - The name must not contain tokens or credentials; no new log lines carry the name.
Feature: Default display name for OAuth-created devices

  Scenario: New OAuth device without a client-supplied name gets the client name with a device suffix
    Given an approved OAuth client named "FluffyChat" and a login that supplies no device display name
    When the OAuth session creates a new device with id "ABCD1234"
    Then the device display name is "FluffyChat (ABCD1234)"

  Scenario: Existing device name is kept on re-login with the same device id
    Given a device "ABCD1234" that already has the display name "My phone"
    When the user logs in again via OAuth with the same device id "ABCD1234"
    Then the device display name is still "My phone"

  Scenario: Client name with markup and control characters is sanitised
    Given an approved OAuth client whose client_name is "<b>Evil\u0007Client</b>"
    When the OAuth session creates a new device with id "ABCD1234" and no display name
    Then the device display name contains no markup or control characters and ends with " (ABCD1234)"

  Scenario: Overlong client name is truncated to the safe length
    Given an approved OAuth client whose client_name is 500 characters long
    When the OAuth session creates a new device with id "ABCD1234" and no display name
    Then the base part of the device display name is at most the configured safe maximum length and the suffix " (ABCD1234)" is kept

  Scenario: Legacy password login device names are unaffected
    Given a legacy login that supplies initial_device_display_name "Legacy laptop"
    When the device is created through the legacy login path
    Then the device display name is "Legacy laptop" and no OAuth default is applied
```

## Definition of Done

- [x] All Gherkin scenarios have failing tests (ATDD)
- [x] All tests pass (green)
- [x] Code review clean (0 MAJOR)
- [x] Security review (if required) clean

## Decisions

All verified against the code; pinned by the tests of the ATDD step (`server/test/nebu/oauth/device_name_*_test.exs`). The dev may deviate only with a note here. No browser-visible part: the story is `ui: false`, the name shows in the client's device list and on the existing admin user page and account page (both already render `devices.display_name`), so there is no e2e feature.

- (ATDD step) WHERE the name is made and written: `Nebu.OAuth.DeviceName` (new, OAuth domain) builds it in `Nebu.OAuth.Token.issue_session/3` and hands it to the Matrix domain as the attribute `default_device_display_name` of `Nebu.Matrix.oauth_issue_session/1` (ADR-020: the Matrix domain never reads the client record); `OAuthSessionStore.insert_replacing_device/1` writes it in the issuance transaction, right after the device upsert, with `UPDATE devices SET display_name = $3 WHERE user_id = $1 AND device_id = $2 AND display_name IS NULL`. The upsert itself keeps passing `display_name: nil` (its `COALESCE(EXCLUDED, existing)` would let a non-nil name overwrite). No migration, no new column, no new log line (number 000058 stays reserved for another story; no test pins the migration number). Names of the contract: `DeviceName.default_name/2` (pure), `for_client/2` (one read of the client record, never raises), `max_base_length/0` (64), `fallback_base/0` ("OAuth client").
- (ATDD step) Format: `"<base> (<suffix>)"`. Base = `client_name` of the approved client, sanitised, at most 64 CODE POINTS (graphemes would let a run of combining marks through), plain `OAuth client` when nothing usable is left or the client is revoked / pending / rejected / unknown / unreadable. "Configured safe maximum" of scenario 4 is the constant 64 (no admin setting).
- (ATDD step) Sanitising, in order: not a string or invalid UTF-8 => fallback; tags `<...>` removed (their text stays: `<script>alert(1)</script>` => `alert(1)`, plain text and harmless); remaining `<` / `>` dropped; tab, newline, CR and Unicode space separators => one space; other control characters, format characters (bidi overrides, zero width, soft hyphen), line / paragraph separators, private-use and surrogate code points dropped; runs of spaces collapse; trimmed; cut; trimmed again. KEPT on purpose: `&`, quotes, accents, every script, emoji (a legitimate app name may carry them). The name is plain text: a client that renders it as HTML must escape it, as for every display name (the DCR already rejects control characters in `client_name`, the sanitising is defence in depth for rows from before that rule or from an admin edit).
- (ATDD step) Suffix: the LAST 8 characters of the device id after dropping every character outside `[A-Za-z0-9._-]` (the scope charset admits `<`, `>`, `"`, `&`, `(`, `)` in a device id, so the suffix is derived from the id but is always safe text); shorter ids whole; nothing left => the first 8 hex characters of the SHA-256 of the id (upper case). Last, not first: structured ids (`ios-prefix-0000000A`) differ at the end. For the story's 8 character id both give the example `FluffyChat (ABCD1234)`; for Element's 10 character id the suffix is `CdEfGhIj`.
- (ATDD step) Never overwrites: only a `NULL` name is filled. Pinned: a name set by `PUT /devices/{id}` or by a legacy login survives a new OAuth login of the same device id (any number) and every refresh; the client's own `PUT` replaces the default; the EMPTY string is a name the client chose (Matrix lets a client clear it) and is kept; an existing device with a `NULL` name (a legacy login without a name, a `PUT` without `display_name`) IS named at its next OAuth login (it becomes an OAuth device, and "never overwrite" protects a name that exists). The write is scoped to the user: another user's device with the same device id is never touched. Existing devices are not renamed in bulk (no backfill).
- (ATDD step) The Gherkin rule "initial_device_display_name always wins" is satisfied by construction: the OAuth token request has no such channel (parameters of that name are ignored, pinned), so for an OAuth session only the client's `PUT` can name the device, and it always wins; for legacy / SSO logins `initial_device_display_name` is unchanged (first creation only; a legacy login that takes over an OAuth device keeps the device's name, existing rule S2 AC1).
- (ATDD step) Scenario 5 (legacy): `POST /login` with `initial_device_display_name` stores exactly that name; without one the name stays unset; the OAuth default is never applied on the legacy path. Pinned with the real login path (raw JWT in `m.login.token`, which is also what the SSO flow ends in).
- (ATDD step) Logs: neither the client name nor the made-up name is in any log line of login, issuance, refresh and re-login (the new module has no `Logger` call, static test). Note for the owner, NOT part of this story: the existing request logger writes the RESPONSE BODY of `GET /_matrix/client/v3/devices` at debug level, so any device display name (client chosen or the new default) is visible in debug logs of that read; the default adds the (public) client name there. Redacting device names in that debug line would be a separate hardening.
- (ATDD step) GDPR unchanged: the name lives in `devices.display_name` (no new table or column); the dispatcher erasure deletes the device rows (pinned with real OAuth-named devices; another user's device with the same client and device id is byte-identical afterwards). The name carries nothing of the user (no subject, user id, display name or e-mail; pinned).
- (ATDD step) Failure modes: an unreadable client record never fails the login (`for_client/2` answers the plain base); a failing UPDATE is part of the issuance transaction (the whole issuance fails and rolls back, as every other write of it).

- (ATDD step, fix pass) OWNER DECISIONS: suffix = last 8 characters (confirmed); the constant 64 is confirmed; `&`, quotes and emoji stay in the name. A device whose name is NULL is named at its next OAuth login, ACCEPTED including a device whose client cleared its name through `PUT /devices/{id}` without `display_name` (the handler stores NULL, so the next OAuth login gives it the default again; pinned by a flow test through the API). OUT OF SCOPE (separate follow-up): the request logger writes the response body of `GET /devices` at debug level, so device names (client chosen or the new default) are visible there.

### Open questions for the owner / security

None open after the owner decisions above. Follow-up outside this story: redact device names in the debug request log of `GET /devices`.

### Cycle 1 additions (ATDD, after code review and Kassandra)

- Invisible-but-not-empty names: U+3164, U+FFA0, U+115F, U+1160, U+2800, U+034F and the variation selectors U+FE00..U+FE0F are dropped; combining marks with no base letter (start of the name or after a space) are dropped, marks after a letter stay; a base that has nothing visible left is the plain `OAuth client`. A variation selector directly after an emoji is deliberately not pinned (the dev may keep emoji presentation). Homoglyph / mixed-script impersonation stays with the approval step (follow-up register).
- Docs say "the new code does not log it" with the caveat of the debug request logger's `GET /devices` capture; the epic's follow-up register `docs/stories/oauth-session-and-consent/follow-ups.md` carries: redact device names in the debug request logger; thread client_name through authenticate/redeem to avoid the second client SELECT; confusable/mixed-script warning on approve_confirm.
