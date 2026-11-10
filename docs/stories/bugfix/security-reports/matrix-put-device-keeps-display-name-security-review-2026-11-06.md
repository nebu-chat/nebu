## Security Review — matrix-put-device-keeps-display-name

**Diff scope:** staged `server/` diff only. `PUT /_matrix/client/v3/devices/:device_id` in `server/lib/nebu/web/router/protected.ex` now handles a missing `display_name` key (keep the name, existence check only), `null` (clear the name), a string (rename) and any other type (400 M_BAD_JSON). `Nebu.OAuth.DeviceName.plan/3` in `server/lib/nebu/oauth/device_name.ex` now counts any stored binary, a blank one included, as an existing name. Plus the tests that go with it.
**Date:** 2026-11-06

### Findings

No security issues found.

### Points checked

1. **IDOR / existence oracle on the new `PUT {}` path.** `DeviceKeyStore.get_device/2` runs `... WHERE user_id = $1 AND device_id = $2`, and `user` comes from `conn.assigns[:current_user]` (the protected router, which needs an access token). A caller only learns whether one of their OWN device IDs exists, which `GET /devices` already tells them. Another user's device gives the same 404 as a device that does not exist, so nothing leaks across users. The rename path keeps its user-scoped `UPDATE ... WHERE user_id AND device_id`. The `{}` path writes nothing and stamps no device-list change, so it cannot be used to spam device-list updates to other users.
2. **Type confusion on `display_name`.** Before this change, any JSON value (number, map, list, boolean) went straight into the `$3` parameter of the rename. Postgrex would reject it, `rename_device` caught that and answered 404. Now only `nil` or a binary reaches the database, and everything else gets 400 before the lookup, so a wrong type also tells the caller nothing about whether the device exists. This is an improvement. The query is parameterised, so there is no injection. String length is not checked here, but that was already true for the existing rename path and is not new in this diff. The request body is limited by the shared parser.
3. **A stored blank name now counts as a name in `DeviceName.plan/3`.** A client holding a token for one of the user's devices could PUT `""` and so (a) make the Allow page show `{:existing, ""}` instead of asking for a name, (b) let a remembered Allow skip the consent page (`device_named_or_derivable?` returns true), and (c) keep a typed name from replacing it. Why this does not matter for security:
   - Only the device owner's own credentials can set the name (user-scoped UPDATE). Anyone who can do that already acts as that user and can rename the device to anything at any time.
   - The remembered-Allow skip still needs `ConsentGrantStore.skip_consent?` for the same user, client, scope and redirect_uri, and `force_consent` and the `{:replace, _}` holder still turn the skip off. The naming question is a usability step, not an authorisation control. A blank name gives the same result as any non-blank name the client could have set.
   - Before this change, `PUT {"display_name": ""}` already stored `""`. The only difference now is that the plan no longer replaces it.
   The only effect is a device that shows no name (self-inflicted, cosmetic). No finding.
4. **Logging of device names.** The diff adds no `Logger` calls. Device names are not written to logs on any path the diff touches.
5. **The other categories (XSS, CSRF, redirects, crypto, timing, rate limits).** Nothing new: no HTML output, no new route (the existing route behind bearer auth is changed), no secret comparison, no crypto. The prescan only reported a path trigger, with no pattern candidates.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED
