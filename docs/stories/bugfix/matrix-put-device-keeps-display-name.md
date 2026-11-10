---
story: matrix-put-device-keeps-display-name
epic: bugfix
status: done
security_review: required
matrix: true
ui: false
---

# Bugfix — `PUT /devices/{deviceId}` without `display_name` must keep the name

Found by the retro Oracle review of `oauth-pages-redesign/01-device-naming-chain`
(`_bmad-output/nebu/epics/oauth-pages-redesign/step-results/01-device-naming-chain/oracle-retro-review.md`).

## Problem

Matrix spec v1.18, `PUT /_matrix/client/v3/devices/{deviceId}`: `display_name` — "If not given, the display name is unchanged."
`server/lib/nebu/web/router/protected.ex` passes a missing key as `nil` to `Nebu.Matrix.DeviceKeyStore.rename_device/3`
(`SET display_name = $3`), so `PUT {}` sets the name to NULL and silently erases the user's name.
A non-string `display_name` (number, object) reaches the SQL parameter and yields a wrong 404 for an existing device.

Second, deferred MINOR of story 01: `Nebu.OAuth.DeviceName.plan/3` treats a stored blank (non-NULL) `display_name`
as "no name", so the Allow page's remembered-Allow path would replace it (`insert_replacing_device` drops the typed name).

## Acceptance criteria

```gherkin
Scenario: PUT without display_name keeps the name
  Given a device named "Work laptop"
  When the client sends PUT /_matrix/client/v3/devices/{deviceId} with the body {}
  Then the response is 200 {}
  And GET /devices and /keys/query unsigned.device_display_name still show "Work laptop"

Scenario: An explicit JSON null clears the name
  Given a device named "Work laptop"
  When the client sends PUT /devices/{deviceId} with {"display_name": null}
  Then the response is 200 and the device has no name

Scenario: A non-string display_name is rejected
  Given a device named "Work laptop"
  When the client sends PUT /devices/{deviceId} with {"display_name": 5} or {"display_name": {"a": 1}}
  Then the response is 400 M_BAD_JSON and the name is unchanged

Scenario: An unknown device is still 404
  When the client sends PUT /devices/{unknown} with {"display_name": "x"} or {}
  Then the response is 404 M_NOT_FOUND

Scenario: A stored blank name counts as a name for the Allow page plan
  Given a device whose stored display_name is "" (non-NULL)
  Then DeviceName.plan/3 returns {:existing, ""} and the typed name is not replaced
```

## Notes

- The test helper `clear_name!` (device_name_oauth_test_support.exs) encoded the bug (`PUT {}` = NULL); it clears with `{"display_name": null}` now.
- No migration. Matrix portal rename (`Nebu.Matrix.AccountManagement.rename_device/3`) always sends a string and is unaffected.
