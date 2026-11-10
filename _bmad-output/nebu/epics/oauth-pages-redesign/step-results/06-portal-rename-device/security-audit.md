## Security Review — oauth-pages-redesign/06-portal-rename-device

**Diff scope:** staged server/ + e2e/ (13 files): new `GET/POST /account/devices/rename` (Nebu.OAuth.Account), `Nebu.Matrix.account_rename_device/3` -> `AccountManagement.rename_device/3` -> `DeviceKeyStore.rename_device/3`, new `rename.html.eex`, rename links on the device templates, PageText strings, ExUnit + Playwright tests, e2e DB fixtures.
**Date:** 2026-11-05
**Prescan:** no candidates (path trigger only: server/lib/nebu/oauth/account.ex).

### Findings

No security issues found.

### Checks performed (all passed)

| Check | Result |
|---|---|
| User id only from the session | `rename_page` / `render_rename` / `rename_device` / `store_device_name` use `session.user_id` from `current_session/1` only. No request parameter carries a user id. |
| Foreign device id cannot be renamed | The SQL is `UPDATE devices ... WHERE user_id = $1 AND device_id = $2` with `$1` = session user. A foreign id updates 0 rows, so the transaction is rolled back and nothing is written. |
| Foreign vs unknown device cannot be told apart | POST: `rename_failure/2` runs the same `SELECT 1 ... WHERE user_id=$1 AND device_id=$2` for both, and both get `{:error,:not_found}`, which is answered with a 303 to `device_not_found`. GET: the id is looked up only in `account_devices(session.user_id)`, so a foreign id and an unknown id both get the same `device_not_found` redirect. Timing is the same: one UPDATE and one SELECT on the composite key either way. Freshness is checked BEFORE ownership (same order as `delete_device`): a stale session sends either id to the rename page, which then answers `device_not_found` in both cases. No oracle. |
| GET page does not leak other users' devices | Only a device found in the session user's own device list is rendered. Otherwise the user is redirected to the list with a fixed notice. `device_id` passes `valid_device_id?`. `notice` is checked against an allow-list (`notice_codes/0`) and never echoed raw. |
| CSRF / Origin / freshness order | `post/3`: `FormPost.parse`, then `current_session`, then `checked_post` (hidden CSRF token via `secure_compare` on the hash AND `BrowserPost.check` with navigation rules), then `dispatch`, then `rename_device` (auth_time nil -> `freshness_unavailable`, stale -> `stale`, invalid id -> `device_not_found`, then name sanitising, then the write). Same as `delete_device`. |
| FormPost free_text scope | `free_text = ["device_name"]` only when `path == ["devices","rename"]`. Every other account POST keeps the strict control-character check. `csrf_token` and `device_id` on the rename route still get the strict `clean?` check. Duplicate parameters are rejected. Query string on a POST is rejected. Body size is capped (`@max_body`). |
| Name sanitising | `DeviceName.typed/1`: cut to 512 code points, then strip tags and `<`/`>`, Cc/Cf/Zl/Zp/Co/Cs, invisible fillers and orphan combining marks, then 64 code points. The store re-checks it (`valid_device_name?`: valid UTF-8, non-empty, at most 64, trimmed, no Cc/Cf/Zl/Zp). |
| Name escaped | `rename.html.eex` uses `Phoenix.HTML.Engine` (auto-escape, which also escapes `"`/`'` in `value="..."`). `rename_href` uses `URI.encode_query`, and its output is escaped by the engine. `aria-label` goes through `tf/3` (plain text, escaped after filling). The page has CSP `frame-ancestors 'none'`, `form-action 'self'`, and X-Frame-Options DENY via `put_headers`. |
| Name never logged | Success logs only `user_id` and `device_id` (the id is already verified as the user's own). The error path logs a constant string. `AccountManagement` and `DeviceKeyStore` do not log the name. |
| POST without session -> 302 via `start_login` (reviewed deviation) | Accepted. It runs before CSRF/BrowserPost, so a cross-site POST can make a browser with no session start a portal sign-in. The effects are the same as following a plain `GET /account` link: one login-request row, capped per source (AH11), plus the per-IP `oauth_account` rate limit, and a binding cookie. The return target is the fixed device list, so no attacker-chosen target is stored and nothing is renamed. No state change, no login-CSRF gain (the IdP signs in the victim's own identity). |
| SQL | All queries are parameterised. The e2e fixtures use `sqlLiteral` (test-only code). |
| Rate limit | The `/account*` entry point runs the per-IP `oauth_account` bucket before routing. |
| Matrix side effects | A rename of a keyed device stamps the device-list stream, the same as `PUT /_matrix/client/v3/devices/{id}`. Other users already see device names through `/keys/query` `unsigned.device_display_name`. This is spec behaviour and is not widened by this story. |

### Open question: should a rename be audit-logged via Nebu.Compliance?

**Recommendation: no, keep the default.** Reasons:
1. Consistency. The audit log (`AuditWriter.log`) records admin, media, compliance and space actions. Self-service device changes are not recorded there: the same rename via Matrix `PUT /devices/{id}`, and the portal device sign-out (`delete_device`), which carries more risk. Auditing only the portal rename would leave a gap that misleads: the same change through the Matrix API would leave no entry.
2. Security value is low. A rename changes a label of the user's own device. It grants no access and removes nothing.
3. Data minimisation. A rename entry would have to store the old and new name, which is free text the user typed (PII). The audit log is append-only and retention-bound. The existing `Logger.info` (user_id + device_id, no name) is enough as an operational trace.
**Condition:** if device sign-out or Matrix device changes are ever audited, add rename in the same story, recording only user_id, device_id and the action (never the name).

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED
