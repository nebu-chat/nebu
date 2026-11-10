---
story_id: 01-device-naming-chain
title: "Every OAuth device gets a clean, recognisable name"
epic: oauth-pages-redesign
status: done
security_review: required
matrix: true
ui: true
traceability_id: REQ-2026-016
created: 2026-11-05
---

## Story

**As** a user who signs in to several apps and browsers, **I want** every device that an OAuth login creates to get a clear name, shown on the Allow page and in every device list, and to be asked for a name when Nebu cannot work one out, **so that** I do not end up with ten "unknown" devices and can tell which device is which.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios). The name is decided in this order, first usable source wins:
#  1. A name the client sets itself through the Matrix API (PUT /devices/{id}, or initial_device_display_name on a legacy login)
#     always wins. In the OAuth flow it can only arrive AFTER the token, so it replaces whatever the steps below chose (existing
#     rule of oauth-device-default-display-name, unchanged). Nebu therefore never asks the user about it.
#  2. The registered client record (dynamic client registry, status approved): its client_name, sanitised by Nebu.OAuth.DeviceName.
#     "Usable" = something visible is left after sanitising AND it is not generic (case-insensitive, trimmed): "OAuth client",
#     "client", "app", "application", "unknown", "test". The list is a module constant.
#  3. The host of the registered client_uri (https only, lower case, no port), e.g. "chat.acme.example" for a self-hosted Element Web.
#  4. Ask the user on the Allow page for a name. The field is required, at most 64 characters, sanitised like step 2.
# Format: steps 2 and 3 produce "<base> (<suffix>)" as today, suffix = last 8 characters of the device id (REQ-2026-004).
#         Step 4 is stored exactly as typed after sanitising, WITHOUT a suffix: the user chose it.
# The name that WILL be given is shown on the Allow page (one labelled line); the page and every list that reads
# devices.display_name (Matrix GET /devices, admin user page, account portal) show the same text. No new column, no migration.
# The name never appears in a log line. It is plain text and HTML-escaped wherever it is rendered.
Feature: Clean device names for OAuth logins

  Scenario: A usable client name is shown on the Allow page and given to the device
    Given an approved client named "FluffyChat" and a new device with id "ABCD1234"
    When the user opens the Allow page and allows
    Then the page shows the device name "FluffyChat (ABCD1234)" and the device is created with exactly that display name

  Scenario: Without a usable client name the website host names the device
    Given an approved client whose client_name is "App" (generic) and whose client_uri is "https://chat.acme.example/web"
    When the user opens the Allow page and allows
    Then the page shows the device name "chat.acme.example (<suffix>)" and the device is created with that display name

  Scenario: When nothing usable exists the user is asked for a name
    Given an approved client without a usable client_name and without a usable client_uri
    When the user opens the Allow page
    Then the page asks for a device name, an Allow without a name is refused with the page shown again and nothing consumed, and an Allow with "Anna's phone" creates the device named exactly "Anna's phone"

  Scenario: A remembered Allow does not skip the question when a new device has no name
    Given the user has a remembered Allow for a client from which no name can be derived, and the device id is new
    When the client starts a new sign-in
    Then the Allow page is shown and asks for a device name, whereas a remembered Allow for a client with a derivable name, or a re-login of a device that already has a name, is still skipped as before

  Scenario: A typed name is sanitised and a name of only invisible characters counts as empty
    Given the Allow page asks for a device name
    When the user submits "<b>Work\u0007 laptop</b>" or a name that consists only of invisible characters
    Then the device is named "Work laptop" in the first case, and in the second case the page asks again without creating anything
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

Proposed by the UX designer from the owner's description (2026-11-05); the dev may deviate only with a note here.

- **Why step 1 never reaches the Allow page:** in the OAuth token request there is no `initial_device_display_name` channel (pinned by REQ-2026-004). A client names its device with `PUT /devices/{id}` after login. So at Allow time Nebu can only use steps 2 to 4, and the client's later `PUT` still replaces the result, which is the Matrix behaviour clients expect. A name the user typed at step 4 is a default like any other and is replaced by a later client `PUT`.
- **"Client signature from the registry"** is read as the registered metadata of the approved client (`client_name`, `client_uri`). `software_id` / `software_version` are not used: they do not tell two devices apart.
- **Remembered Allow:** the private `remembered?/3` in `server/lib/nebu/oauth/authorize.ex` (around line 480) must return `false` when the device is new (or has a NULL name) AND steps 2 and 3 yield nothing, the same "fail towards asking" pattern as `{:replace, _}` and `force_consent`. Without this a remembered grant would silently create a nameless device.
- **Where the typed name travels:** with the consent row to `Nebu.OAuth.Consent`, into the code row, into `Nebu.OAuth.Token.issue_session/3`, which today calls `DeviceName.for_client/2`. `DeviceName` gets the typed name as an input and decides; the Matrix domain still receives only `default_device_display_name` (ADR-020).
- **The consent POST gets a new field.** It is a user-supplied string: CSRF and fetch-metadata checks stay as they are, length is bounded before sanitising, it is never reflected into a header or the CSP, only HTML-escaped into the page when it is shown again after a refusal.
- **UI here is minimal on purpose:** a labelled line and one text input on the *existing* consent page. The visual redesign is `03-consent-page-redesign`, which must carry this field.
- **No backfill:** existing devices called "OAuth client (xxxxxxxx)" or "Unknown" are not renamed (as in REQ-2026-004). See Open Questions.
- **Dev note (implementation deviations, 2026-11-05):**
  - *One migration after all:* `000062_oauth_codes_device_display_name` adds the nullable `oauth_codes.device_display_name`. The typed name must survive from the Allow POST to the token request (a different request, up to 60 s later); no existing column can carry it. `devices.display_name` is unchanged (no new column there). The code row is deleted with the user at erasure like every other code field.
  - *Refused Allow answers 422* (the page again, `data-role="device-name-error"`, cookie and CSRF token still valid). The check runs before the consent row is consumed (`Nebu.OAuth.Consent.decide/5`).
  - *Free-text form field:* `FormPost.parse/2` takes a list of free-text parameters (`device_name`) that may contain control characters (valid UTF-8 still required); all other parameters keep the strict rule. Without this a typed "\u0007" would be a `400 invalid_request` instead of being sanitised.
  - *Existing named devices:* when the device already carries a name (re-login of a named device, a replaced session with a name) the page shows that name as the name the device keeps (`{:existing, name}`) and never asks; the name is not overwritten (unchanged Matrix rule).
  - *Superseded expectation:* a client with no usable `client_name` but a `client_uri` host is now named after the host (rule 3), no longer "OAuth client (suffix)"; `device_name_flow_test.exs` was adjusted. "OAuth client (suffix)" remains only when no client record is readable or approved, or nothing was typed at the token endpoint.
  - *Enter key:* the first submit button of the consent form is Deny (security: Allow is armed by JavaScript), so Enter in the name field denies; the hint next to the field says "Use the Allow button". Deny carries `formnovalidate` so it works with the empty required field.

## Open Questions

- Existing unnamed devices stay unnamed. They are repaired by the user through `06-portal-rename-device` (owner decision 2026-11-05).
- Generic-name list: `OAuth client`, `client`, `app`, `application`, `unknown`, `test`. Add more (for example `matrix`, `chat`), or make it an admin setting?
- Should the name field also be offered when a name *was* derived ("Rename before allowing")? Not in this story; the derived name is shown read-only.
- Impersonation: a typed name can be anything ("Admin laptop"). It is only shown to the same user, so accepted; Kassandra to confirm.
