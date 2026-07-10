# Oracle Gate — war-room-mode

This is an admin diagnostic-logging feature. Its only Matrix-spec surface is (a) the
`/sync` route-template string used for scope matching and (b) `user_id`/`device_id`
filter-field validation. Confirmed facts below are from the bundled spec v1.18.

## 1. Applicable Matrix Spec Surface + MUST Requirements

- Canonical sync route template (v1.18): `GET /_matrix/client/v3/sync` — this exact string is correct for AC3/AC8.
- Versioning/aliasing: real clients could hit legacy aliases `/_matrix/client/r0/sync` and `/_matrix/client/v1/sync` (deprecated but still served on a generic Matrix server). **Verified against THIS codebase's actual router** (`server/lib/nebu/web/router/protected.ex`): Nebu only routes `get "/client/v3/sync"` — no `r0`/`v1` alias route exists at all. So exact-string scope matching against `/_matrix/client/v3/sync` is complete for Nebu; the Oracle's general caution about aliases does not apply here (no dev-story action needed beyond the exact-match already planned).
- `user_id` grammar (appendices #user-identifiers, MUST): form `@localpart:domain`; localpart MUST NOT be empty and MUST contain only `a-z 0-9 . _ = - / +` (lowercase only); total length including `@` and domain MUST NOT exceed 255 bytes. Historical IDs MAY contain other codepoints (except `:` and NUL) — validation SHOULD be lenient on read but the compliant set above is what to validate against for a filter input. **For war-room's filter field, validation should be lenient (exact-match against whatever is logged, not a strict grammar gate)** since the filter is matched against already-recorded `metadata["user_id"]` strings, not used to construct new user_ids.
- `device_id`: spec defines it as an opaque string with NO grammar/charset/length constraint and it is case-sensitive. Filter validation MUST treat it as an opaque exact-match token — do NOT lowercase, do NOT regex-restrict.
- Filter AND-semantics (AC9) is a Nebu-internal rule, not Matrix `/filter` API — no spec conflict.

## 2. Spec MUST-Requirements This Feature Could Risk Violating

- MUST NOT alter/suppress/delay/reorder the actual `/sync` (or any endpoint) protocol response — logging is a passive side-effect; collection, budget checks, and `entries_collected` writes MUST be off the request response path (async/non-blocking, matching the already-shipped `Writer.write_async/1` cast pattern; the new `WarRoom.check/1` call, even though synchronous, must be a cheap local GenServer call, never blocking on slow I/O in a way that could delay the response).
- MUST NOT affect rate-limiting behavior: no changes to `429` / `M_LIMIT_EXCEEDED` / `retry_after_ms` emission while a war-room session is active.
- MUST NOT introduce back-pressure: budget/writer contention MUST NOT block or fail the request (a full or errored log budget MUST NOT turn a `200` into a `500`).
- LAW (project memory): collected DEBUG/payload entries MUST redact access tokens, credentials, AND chat message content — bypassing normal retention (AC4.1) MUST NOT bypass redaction. War Room's `check/1` never touches `message`/redacted body fields — only already-redacted `route_template`/`metadata["user_id"/"device_id"]` — so no new leak path (confirmed in design-decisions.md #9).

## 3. Error Codes / HTTP Status / Edge Cases to Test-Cover

- No Matrix CS-API `errcode` surface here — start/stop is an admin (`Nebu.Admin`) LiveView event, not a CS endpoint; error format is admin-app-defined, not `M_*`.
- Matrix-adjacent edge cases to cover in ATDD:
  1. `device_id` filter accepted as opaque/case-sensitive exact match (no lowercasing, no charset restriction).
  2. Scope string `/_matrix/client/v3/sync` matches only that exact `route_template` value (confirmed sole sync route in this codebase).
  3. Collection is non-blocking — a `/sync` request still returns normally (200, correct body) even when the war room's budget is exhausted mid-flight, and even under a WarRoom GenServer restart/crash.
  4. Redaction remains intact for all war-room-collected entries (regression-test alongside AC4).
  5. `user_id` filter: exact-match against the logged `@user:domain` string; no need to validate ITS OWN grammar strictly (it's matched against already-valid recorded values), but obviously malformed input (empty string) should simply never match rather than error.
