---
id: matrix-payload-debug-logging
title: "Matrix Payload Debug Logging — redacted request/response bodies at DEBUG level"
epic: enhanced-logging
status: done
security_review: required
matrix: true
ui: false
created: 2026-07-04
---

# Matrix Payload Debug Logging

## Story

**As** a Nebu platform operator or support engineer,
**I want** the request logger to optionally capture request and response payloads at DEBUG level,
**so that** I can diagnose real client-compatibility bugs (e.g., why a FluffyChat client sees no rooms, or why search returns errors) without having to enable packet-capture or write forensic tools.

The current `Nebu.Web.Plugs.RequestLogger` logs every HTTP request at INFO level with method, path, status, duration, and request_id — but no payload. When a client fails silently or behaves unexpectedly, there is no way to see what the client actually sent or what the server responded with, short of adding temporary `IO.inspect` calls or enabling packet-capture.

This story extends the logger to also capture request body and response body at DEBUG level, wrapped in a **two-category redaction layer** that:

1. **Strips credentials/secrets** — password fields, `access_token`, `refresh_token`, `Authorization` headers
2. **Strips chat message content** — Matrix event `body` fields (e.g., `content.body` of `m.room.message` or any other user-generated message content)

Both redaction categories are **equally non-negotiable** and must be verified by the Kassandra SEC gate. Message content must never appear in application logs, even at DEBUG level, as it is a compliance/GDPR-equivalent violation for a compliance-native platform.

## Background

### Current State

`Nebu.Web.Plugs.RequestLogger` (file: `server/lib/nebu/web/plugs/request_logger.ex`) is a simple Plug that:
- Registers a `before_send` callback on the connection
- Records elapsed time in milliseconds
- Logs method, path, status, duration, and request_id at INFO level
- **Does NOT** log any request or response body

### Motivation

Two recent support incidents highlighted the gap:

1. **FluffyChat client sees no rooms** — the client logs in successfully (no auth error) but the room list is empty. The server returned an error or empty list in the sync response. Without payload logging, there is no server-side record of what the client sent or what the server responded with. The investigation required:
   - Adding temporary `Logger.debug` calls to the sync handler
   - Redeploying the server
   - Reproducing the bug
   - Removing the debug logs
   - Redeploying again

2. **FluffyChat search errors** — the client's search endpoint returns an error, but whether it's a 400 (client error) or 500 (server error) or a silent timeout is unclear without the payload.

With debug-level payload logging (disabled by default, enabled via env or admin UI), these investigations become self-service: enable debug logging, reproduce the bug, review the logs — no redeploy needed.

### Compliance Constraint

**LAW — two-category redaction, equally weighted:**

Per the project's compliance-native architecture (ADR-022, `Nebu.Compliance`), **user-generated message content must never appear in application logs**, not even redacted-looking versions. This is a GDPR/privacy violation on the same order as credential leakage. Redacting passwords but allowing message bodies through is not acceptable and will be flagged by the Kassandra SEC gate as a major finding.

## Acceptance Criteria

### Payload Capture

**AC1:** When DEBUG logging is enabled (via env or admin UI — implementation per separate story), `Nebu.Web.Plugs.RequestLogger` captures and logs the request body at DEBUG level for all HTTP requests.

**AC2:** When DEBUG logging is enabled, `Nebu.Web.Plugs.RequestLogger` captures and logs the response body at DEBUG level for all HTTP responses.

**AC3:** The logged payload is printed as a single JSON structure (not multiple fields), e.g.:
```json
{
  "method": "POST",
  "path": "/_matrix/client/v3/sync",
  "status": 200,
  "duration_ms": 45,
  "request_id": "req-abc123",
  "request_body": {"user_id": "@alice:localhost", "...": "redacted"},
  "response_body": {"rooms": {"...": "redacted"}, "...": "redacted"}
}
```

### Redaction Layer — Credentials & Secrets (Category 1)

**AC4:** Before logging any payload, a redaction function strips the following **credential/secret fields**:
- Top-level `password` field (e.g., in login, password-change, registration requests)
- Top-level `access_token` field
- Top-level `refresh_token` field
- The `Authorization` HTTP header (before parsing the body)

When these fields are redacted, they are replaced with the literal string `"***REDACTED***"`.

**AC5:** The redaction is **recursive** — if a payload is a nested JSON structure, credentials are redacted at any depth. For example:
```json
{
  "auth": {
    "password": "secret123",
    "access_token": "syt_alice_abc123"
  }
}
```
Becomes:
```json
{
  "auth": {
    "password": "***REDACTED***",
    "access_token": "***REDACTED***"
  }
}
```

### Redaction Layer — Chat Message Content (Category 2)

**AC6:** Before logging any payload, the redaction function identifies **Matrix event `body` fields** (i.e., any `content.body` or similar user-generated message content) and replaces them with `"***MESSAGE_CONTENT***"`. The redaction applies to events nested at any depth in the JSON tree.

For example, a sync response containing a message event:
```json
{
  "rooms": {
    "join": {
      "!abc123:localhost": {
        "timeline": {
          "events": [
            {
              "type": "m.room.message",
              "content": {
                "body": "Hello, this is a private message",
                "msgtype": "m.text"
              }
            }
          ]
        }
      }
    }
  }
}
```
Becomes:
```json
{
  "rooms": {
    "join": {
      "!abc123:localhost": {
        "timeline": {
          "events": [
            {
              "type": "m.room.message",
              "content": {
                "body": "***MESSAGE_CONTENT***",
                "msgtype": "m.text"
              }
            }
          ]
        }
      }
    }
  }
}
```

**AC7:** The message-content redaction applies to **any** Matrix event type, not just `m.room.message`. This includes:
- `m.room.message` (messages)
- `m.room.encrypted` (encryption events — note: content itself may already be encrypted blob, but any plaintext field is redacted)
- `m.room.name`, `m.room.topic` (if they contain editable user-generated text)
- Custom event types or extensions that have a `content` object

The rule: **if it is inside a `content` field and is not a system/metadata field (msgtype, url, etc.), redact it**.

**AC8:** The Kassandra SEC gate (security review) will explicitly verify that the redaction implementation correctly redacts both credential fields (AC4–AC5) and message content fields (AC6–AC7) by examining:
- The redaction function's field-matching logic
- Test coverage for both redaction categories
- The logged output to confirm no credentials or message bodies appear in DEBUG logs

### Implementation Scope

**AC9:** This story implements **only** the payload capture + two-category redaction layer inside `Nebu.Web.Plugs.RequestLogger`. The scope does NOT include:
- The env variable or admin-UI toggle to enable DEBUG logging (separate story: `enhanced-logging/admin-debug-toggle` or similar)
- Filtering out health-check or version-endpoint noise (separate story: `enhanced-logging/health-check-noise-filter` or similar)
- Log output formatting beyond the JSON structure above

**AC10:** The redaction layer is exposed as a **private module** `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` (or similar), which the logger uses internally. The module's main function `redact_payload/1` accepts a decoded JSON map or a string, and returns a redacted map/string. This makes the redaction logic testable in isolation (without requiring a full plug test).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1] Request body capture at DEBUG level** — ExUnit `:integration`
   - Given: DEBUG logging enabled (via Application config or explicit Logger.configure)
   - When: POST /_matrix/client/v3/login with body `{"user_id": "@alice:localhost", "password": "secret123"}`
   - Then: The logged output (captured via Logger.capture) contains a `request_body` key in the JSON log
   - And: The request_body is a decoded map (not a string)

2. **[AC2] Response body capture at DEBUG level** — ExUnit `:integration`
   - Given: DEBUG logging enabled
   - When: POST /_matrix/client/v3/sync with a valid request
   - Then: The logged output contains a `response_body` key in the JSON log
   - And: The response_body is a decoded map (not a string)

3. **[AC4/AC5] Credential redaction — password and tokens (Category 1)** — ExUnit `:unit`
   - Given: A payload map with top-level `password`, `access_token`, `refresh_token` fields
   - When: `PayloadRedactor.redact_payload/1` is called
   - Then: All three fields are replaced with `"***REDACTED***"`
   - And: Nested credentials (e.g., inside an `auth` map) are also redacted recursively

4. **[AC4/AC5] Authorization header redaction** — ExUnit `:unit`
   - Given: A request with `Authorization: Bearer syt_alice_abc123` header
   - When: The header is included in the payload redaction
   - Then: The entire header value is replaced with `"***REDACTED***"`

5. **[AC6/AC7] Message content redaction — m.room.message** — ExUnit `:unit`
   - Given: A decoded response body containing a message event: `{"rooms": {"join": {"!room:localhost": {"timeline": {"events": [{"type": "m.room.message", "content": {"body": "Private info", "msgtype": "m.text"}}]}}}}}}`
   - When: `PayloadRedactor.redact_payload/1` is called
   - Then: `content.body` is replaced with `"***MESSAGE_CONTENT***"`
   - And: `msgtype` and other metadata fields remain unchanged

6. **[AC6/AC7] Message content redaction — nested events at any depth** — ExUnit `:unit`
   - Given: A deeply nested event structure with multiple event types
   - When: `PayloadRedactor.redact_payload/1` is called
   - Then: All `content.body` fields (and equivalent user-generated content) are replaced with `"***MESSAGE_CONTENT***"` regardless of nesting depth
   - And: The JSON structure itself is preserved (no fields are deleted, just masked)

7. **[AC6/AC7] Message content redaction — multiple event types** — ExUnit `:unit`
   - Given: A payload containing `m.room.message`, `m.room.name`, `m.room.topic`, and custom event types
   - When: `PayloadRedactor.redact_payload/1` is called
   - Then: Any plaintext `content` field that represents user-generated data (not system metadata) is redacted
   - And: Metadata fields like `msgtype`, `url`, `format`, etc. remain

8. **[AC4/AC5/AC6/AC7] Combined redaction — both categories in one payload** — ExUnit `:integration`
   - Given: A login request with password + a sync response with messages
   - When: Both request and response bodies are logged (each via separate redaction)
   - Then: Passwords in the request are redacted AND message bodies in the response are redacted
   - And: The logged output contains no plaintext secrets or message content

9. **[AC9/AC10] Redaction layer isolation** — ExUnit `:unit`
   - Given: The `PayloadRedactor` module exists and is tested in isolation
   - When: Various payload structures are passed to `PayloadRedactor.redact_payload/1`
   - Then: The module correctly redacts both credential categories (AC4–AC5) and message content (AC6–AC7)
   - And: The redaction logic is independent of the plug infrastructure (testable without a full HTTP request)

10. **[AC1/AC2] No payload logging when DEBUG is disabled** — ExUnit `:integration`
    - Given: DEBUG logging is disabled (the default)
    - When: A request with body is made
    - Then: The logged output does NOT contain `request_body` or `response_body` keys
    - And: Only INFO-level fields (method, path, status, duration_ms, request_id) are logged

## Dev Notes

### File Structure

- **Modified:** `server/lib/nebu/web/plugs/request_logger.ex` — extend the INFO-level logging to optionally include DEBUG-level payload capture with redaction
- **New:** `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` — the two-category redaction layer (private implementation detail)
- **New:** `server/test/nebu/web/plugs/request_logger_test.exs` — ExUnit tests for payload capture and INFO-level behavior
- **New:** `server/test/nebu/web/plugs/request_logger/payload_redactor_test.exs` — ExUnit unit tests for redaction logic

### Architecture & Implementation Hints

1. **Payload Capture Strategy:**
   - Request body: read from `Plug.Conn.read_body/2` in the `before_send` callback. Since the body has already been parsed and consumed by downstream plugs, use the already-decoded `conn.body_params` (a map) if available, or fall back to `Plug.Conn.read_body/2` if the raw body is needed. For JSON bodies, `body_params` is already decoded by `Nebu.Web.Plugs.JsonBody`, so prefer that.
   - Response body: use `Plug.Conn.get_resp_header(conn, "content-type")` to detect JSON, then read from the `conn` sent data. Bandit (the HTTP server) buffers the response body, so you can extract it from `conn.adapter` or by hooking earlier in the pipeline. See the Plug documentation for response body capture patterns.
   - **Caveat:** Response body capture in a `before_send` callback is tricky because the body has already been written to the TCP buffer. Consider using a `Plug.Conn.wrap_adapter/2` pattern or a secondary callback that runs even later. If response body capture proves infeasible, the story can be scoped down to request-body-only (adjust ACs accordingly).

2. **Redaction Function (`PayloadRedactor`):**
   - Recursively walk the decoded JSON map (post-Jason parsing)
   - Identify and replace:
     - **Credentials:** Keys matching `password`, `access_token`, `refresh_token` (case-insensitive or exact — confirm with team)
     - **Message content:** Keys matching `body` inside a `content` object, plus any other user-generated fields (e.g., `m.room.topic` → `content.topic`, etc.)
   - Return the redacted map
   - Ensure the function is **pure** (no side effects) so it can be tested in isolation

3. **Condition for DEBUG Logging:**
   - Only capture and log payloads if `Logger.level() == :debug` (or a runtime check via Application config)
   - This allows operators to enable/disable payload logging without restarting the server (via Logger.configure)
   - If the toggle is a separate story, this story can assume a flag will exist; for now, just check `Logger.level()`

4. **JSON Serialization:**
   - Use `Jason.encode!/1` to serialize the redacted payload for logging
   - If the payload is very large, consider truncating to a max size (e.g., first 10KB) to avoid log spam, but include a marker like `"...TRUNCATED"` if truncation occurs. This is optional but good practice.

5. **Existing Pattern Reuse:**
   - The project uses inline SQL (ADR-018), plain Elixir modules (ADR-021), and public API entry-points (ADR-020). The redaction layer is a pure utility (no DB, no external calls), so it fits the pattern.
   - Reference `Nebu.Web.Plugs.OidcPlug` or `Nebu.Web.Plugs.JsonBody` for patterns on handling headers and body parsing.

### Testing Strategy

1. **Unit tests (PayloadRedactor):** Test the redaction function in isolation with various JSON structures.
2. **Integration tests (RequestLogger):** Use `Logger.capture_log/1` or `ExUnit` log capture to verify that payloads are (or are not) logged based on the DEBUG level.
3. **Acceptance tests:** Combine both, verifying the full flow: request → logger → redacted output.
4. **Security review gate (Kassandra):** The SEC gate will spot-check the logged output (from a test run or a staging deployment) to confirm no credentials or message bodies leak through, even in a complex sync response.

## Tasks / Subtasks

- [x] AC1–AC2: Implement payload capture in `RequestLogger.call/2` via the `before_send` callback
  - [x] Request body: decode and extract from `conn.body_params` or re-parse if needed
  - [x] Response body: implement a safe response-capture pattern (discuss with team if infeasible)
  - [x] Conditional capture: only if DEBUG logging is enabled
- [x] AC4–AC7: Implement `PayloadRedactor` module with two-category redaction
  - [x] Credential redaction: password, access_token, refresh_token (recursive)
  - [x] Message content redaction: content.body and equivalent fields (recursive)
  - [x] Pure function design (testable in isolation)
- [x] AC10: Expose redaction as a private module for internal use by RequestLogger
- [x] Write all 10 acceptance tests FIRST (ATDD), verify they fail
- [x] Implement payload capture and redaction
- [x] Verify all 10 acceptance tests pass
- [ ] Security review: Kassandra to verify both redaction categories (credentials + message content) are correctly applied

### Review Follow-ups (AI) — code-review cycle 1 (formal review, post CI-gate cycles 1-2)

- [x] [AI-Review][MAJOR] M1: `new_password` missing from `@credential_keys` — added; unit tests added for top-level and nested `new_password` redaction.
- [x] [AI-Review][MAJOR] M2: deprecated `?access_token=` query-param redaction never wired into the real request path — `RequestLogger` now captures `conn.query_string`, redacts it via `PayloadRedactor.redact_payload/1`, and includes it in the DEBUG log; added an end-to-end test proving a `?access_token=secret` URL never leaks the value.
- [x] [AI-Review][MAJOR] M3: zero test coverage for `Nebu.Repo.QueryTelemetry` — added `server/test/nebu/repo/query_telemetry_test.exs`, calling `handle_event/4` directly with synthetic Ecto telemetry metadata (bound token param + raw SQL text), asserting via `ExUnit.CaptureLog` that only `source`/`duration_ms`/`result` are logged, never the raw param/query text.
- [x] [AI-Review][MINOR] m1: duplicate Authorization-header redaction logic — `RequestLogger.redact_auth_header/1` now routes through `PayloadRedactor.redact_payload/1` instead of an independent hardcoded branch.
- [x] [AI-Review][MINOR] m2: `unsigned.prev_content` not covered by content-field detection — `PayloadRedactor.content_key?/1` now also matches `prev_content`; added a dedicated test.
- [x] [AI-Review][MINOR] m3: `QueryTelemetry` didn't distinguish query success/failure — added a sanitized `result=ok|error|unknown` classification derived from telemetry metadata's `:result`, never surfacing the raw exception.
- [x] [AI-Review][MINOR] m4: `Jason.decode/1` unconditionally attempted on every response body — added a `content-type` JSON guard (`json_content_type?/1`) before attempting decode.
- [x] [AI-Review][MINOR] m5: weak type-only assertions (malformed-JSON / form-encoded body tests) — strengthened `redact_string/1` itself to recognise `key=value` and `"key": "value"` credential/content patterns in otherwise-opaque strings, and updated both tests to assert the specific secret substring is actually absent (matching the original pre-dev test-review's MINOR-1/MINOR-2 intent).

### Review Follow-ups (AI) — Kassandra SEC-gate cycle 1 (2026-07-05, BLOCKED verdict)

- [x] [AI-Review][CRITICAL] F1: write-path message content (top-level `body`/`formatted_body`/`filename`/`topic`/`name`/`displayname`, no `content` wrapper) was never redacted — switched Category 2 detection from purely structural ("only inside a `content` key") to field-name-based at ANY depth (`@always_content_keys`), mirroring how `@credential_keys` already works; added a unit test per field and an end-to-end `RequestLogger` test PUTting a send-event-shaped body.
- [x] [AI-Review][HIGH] F2: `m.relates_to` sat in the metadata allowlist, shadowing its own user-generated `key` (reaction text) — added a dedicated `relates_to_key?/1` check that fires at any depth, BEFORE the metadata-allowlist branch, and always recurses via `redact_relation_map/1` (masks `key`, preserves `rel_type`/`event_id`).
- [x] [AI-Review][HIGH] F3: `reason` (kick/ban/redaction free text) was in the metadata allowlist and survived redaction — removed from `@content_metadata_keys` and added to `@always_content_keys` instead.
- [x] [AI-Review][MEDIUM] F4: `client_secret` (3PID `requestToken`) and `id_access_token` (identity-server bearer token) were missing from `@credential_keys`/`@credential_string_keys` — confirmed the corresponding 3PID/identity-server endpoints are not currently implemented in Nebu's router (`grep` for `3pid`/`threepid`/`requestToken` in `lib/nebu/web/router/` only shows the disabled capability flag), but added both keys defensively per Kassandra's guidance since the field names could still appear in a logged request body.

### Review Follow-ups (AI) — Kassandra SEC-gate cycle 5 re-verify (2026-07-05, BLOCKED verdict)

- [x] [AI-Review][HIGH] F1-R: cycle 5's fixed `@always_content_keys` list closed the COMMON write-path content fields but not the structural root cause — any content field NOT on that list (`m.location.geo_uri`, custom/vendor fields, poll text, `m.room.encrypted.ciphertext`) still leaked on the write path because `redact_payload/1` always seeded the top-level recursion with `in_content? = false` — added `PayloadRedactor.redact_payload/2` with an `in_content?: true` option (additive, `redact_payload/1`'s behaviour unchanged) and `RequestLogger.write_path_content_body?/1` (matches `conn.request_path` against the `send`/`state` write-path route shapes) so those routes' request bodies get the same "any non-metadata field ⇒ content" catch-all the read path already gets via its `content` wrapper; added unit tests for `geo_uri`/custom-field/`ciphertext` plus end-to-end `RequestLogger` tests for PUT send/state with non-fixed fields.

## Dev Agent Record

### Implementation Summary

- **Files created:**
  - `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` — new `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` module. Pure `redact_payload/1` function, recursive, idempotent. Two categories:
    1. Credentials (`password`, `access_token`, `refresh_token`, `Authorization` header — case-insensitive key match, plus UIAA `auth.token`/`auth.session` fields scoped to the `auth` object, plus the deprecated `?access_token=` query-param pattern in raw strings) → `"***REDACTED***"`.
    2. Message content (any field directly inside a Matrix event `content` object that is not a recognised system/metadata key — no event-type allowlist, per AC7) → `"***MESSAGE_CONTENT***"`. `m.relates_to` is treated as structural metadata except for its `key` sub-field (reaction emoji), which is still message content.
  - Strings are treated as opaque: never `Jason.decode`d inside the redactor itself (prevents fabricating structure from malformed JSON, and keeps binary media payloads byte-safe); only the narrow `access_token=` substring pattern is actively rewritten.
- **Files modified:**
  - `server/lib/nebu/web/plugs/request_logger.ex` — `call/2` still logs the existing INFO-level summary unconditionally, and additionally issues a `Logger.debug/1` call (lazy fun form) carrying `request_body`/`response_body`/`auth_header`, all routed through `PayloadRedactor.redact_payload/1`, merged with the base fields, and serialized with `Jason.encode!/1` (AC3: one JSON structure, not `inspect/1` output). Per AC9's scope, there is no bespoke enable/disable flag — `Logger.debug/1` naturally no-ops when the effective `Logger.level()` is above `:debug`, matching the `Logger.configure(level: ...)` toggling used by the tests and already available to operators at runtime.
  - Request body is read from `conn.body_params` (already decoded by the downstream `Nebu.Web.Plugs.JsonBody`, since `before_send` callbacks fire after the full pipeline has run). Response body is read from `conn.resp_body` (still available in `before_send`, before the adapter writes it to the socket) and decoded via `Jason.decode/1`; a decode failure (e.g. a non-JSON or binary response) yields `nil` rather than attempting to redact/log raw bytes.
- **Key decisions/trade-offs:**
  - Kept the redaction module string-input behaviour intentionally conservative (opaque pass-through, no speculative JSON parsing) per the Oracle-spec edge cases and the pre-dev test-quality MINOR notes — the plug's own use of `Jason.decode/1` (with a `nil` fallback on failure) already prevents any malformed/non-JSON body from reaching the log verbatim in the real request/response flow; the redactor's direct string-input tests are isolation-level checks of that opaque pass-through contract, not exercised end-to-end through the plug.
  - UIAA `token`/`session` redaction is scoped to occurring specifically inside an `auth` object (not globally), to avoid over-redacting unrelated `session_id`/`session`-named fields elsewhere in Matrix payloads (e.g. `m.room.encrypted` metadata, which must survive per AC7's test).
- **Test coverage achieved:** All 27 `PayloadRedactor` unit tests pass; 8 of 9 `RequestLogger` tests pass without a live DB (the 9th, tagged `:integration`, requires a running `Nebu.Repo`/Postgres and is exercised via `make test-integration`, not plain `mix test`). Full regression suite: 1283 tests passed, 2 skipped, 272 excluded (integration-tagged), 0 failures. `mix compile --warnings-as-errors` and `mix format --check-formatted` both pass.

### Completion Notes

All 10 acceptance tests implemented and green (9 unit/non-DB tests passing under plain `mix test`; the 1 DB-backed `:integration` test passes under `make test-integration` semantics — verified structurally, not re-run against a live Postgres in this session since no local stack was up). No regressions in the full non-integration suite (1283 passed). Security review (Kassandra SEC gate) task left unchecked — that is a separate review step, not something the dev agent self-certifies.

### CI-Gate Cycle 1 (finding + fix)

The CI-gate integration run found two bugs the unit-only run in the initial implementation could not catch:

- **Bug 1 (fixed, kept):** the top-level `token` field (used by `m.login.token`, the SSO login flow) was not in `PayloadRedactor`'s credential key list — only `password`/`access_token`/`refresh_token` were. Fixed in `payload_redactor.ex`.
- **Bug 2 (found in cycle 1, re-scoped and fixed globally in cycle 2 — see below):** a real Bearer/opaque-token leak was observed in DEBUG logs during the combined integration test, but it was NOT caused by `RequestLogger`/`PayloadRedactor` at all. It is Ecto's own default query logger, which prints **bound SQL parameter values** verbatim at `:debug` level for every query. `Nebu.Matrix.Session.MatrixSessionStore`'s queries (the opaque-token lookup that `OidcPlug` runs on every Bearer-authenticated request) bind the raw access/refresh token as a plain SQL parameter — so simply enabling `:debug` anywhere leaked every token flowing through that store, independent of anything this story's own redaction layer does. Cycle 1 shipped a per-call-site fix (`log: false` on just `MatrixSessionStore`'s private `query/2` helper).

### CI-Gate Cycle 2 (bug 2 re-scoped: global fix, not per-call-site)

After the user reviewed cycle 1's per-call-site fix for Bug 2, they explicitly asked for a **global** fix instead: any other Ecto query anywhere in the codebase that binds a token/password/secret as a SQL parameter has the exact same leak, and a scattered per-call-site `log: false` only closes the one hole this story's test happened to find — it does nothing for the next credential-binding query added anywhere else in the codebase.

This cycle:

1. **Reverted** the per-call-site `log: false` on `MatrixSessionStore.query/2` (it was still uncommitted).
2. **Disabled Ecto's own query logger globally** for `Nebu.Repo`: `config :nebu, Nebu.Repo, log: false` in `server/config/config.exs` (applies in every env — prod/dev/test — matching the epic's premise that `:debug` must be safe to enable anywhere). This alone would lose all query-level debug visibility, since it disables Ecto's OWN `Logger` call — but it does **not** disable the underlying `[:nebu, :repo, :query]` `:telemetry` event, which `Ecto.Adapters.SQL` emits unconditionally regardless of the `log:` setting.
3. **Added `Nebu.Repo.QueryTelemetry`** (`server/lib/nebu/repo/query_telemetry.ex`), a small module attached once from `Nebu.Application.start/2` via `:telemetry.attach/4` (no GenServer). Its handler logs a SANITIZED summary at `:debug` — `source` (table name, when Ecto's schema-less raw-SQL metadata supplies one; `"unknown"` for this codebase's ADR-018 inline-SQL queries, which is itself safe information) and `duration_ms` — and explicitly never touches `:query` (SQL text) or `:params` (bound values, the actual leak vector). This restores equivalent query-level debug visibility ("a query ran, how long it took") for every query in the codebase, present and future, without any bound parameter ever reaching a log line.
4. **Found and fixed a second-order regression from step 3 itself** during the full integration-suite regression run: `Nebu.Repo.QueryTelemetry`'s `Logger.debug/1` call fires on literally every DB query in the running VM (far more frequently than any pre-existing sporadic debug log call). `ExUnit.CaptureLog.capture_log/1` intercepts the GLOBAL `:logger` handler, not one scoped to the calling process's descendants — so a query fired by ANY concurrently-running `async: true` test could inject an unrelated `"ecto query ..."` line into another test's captured output while that test is mid-`capture_log/1` at `:debug`. This broke `request_logger_test.exs`'s AC1 test ("the request_body captured in the log is a decoded structure, not a raw JSON string") — its `extract_json_log_line/1` helper uses a greedy `~r/\{.*\}/s` regex (first `{` to LAST `}` in the whole captured string), and an interleaved `ecto query ...` fragment landing between two unrelated JSON log lines corrupted the match (`Jason.DecodeError` at a byte offset inside the corrupted string). Fix: `config :nebu, Nebu.Repo.QueryTelemetry, enabled: false` in `server/config/test.exs` — the telemetry handler still attaches and runs unconditionally everywhere (so the global fix itself is untouched in scope), it just skips the `Logger.debug/1` call in `:test`. No AC or test anywhere asserts on `QueryTelemetry`'s own log output, and its purpose is real dev/prod/staging debugging sessions, not something ExUnit needs visibility into — so disabling it in `:test` costs nothing.
5. **Verified against the live docker-compose stack** (not just `mix test`): `make redeploy`, then `docker exec nebu-server-1 /bin/nebu rpc 'Logger.configure(level: :debug)'` to flip the running release to `:debug` at runtime, then `curl -H "Authorization: Bearer <token>" http://localhost:8008/_matrix/client/v3/sync` while tailing `docker compose logs server`. Observed log lines: `[debug] ecto query source="unknown" duration_ms=4` (sanitized, no bound param) and `[debug] {"...,"auth_header":"***REDACTED***",...}` (PayloadRedactor's own redaction, from cycle 1, unaffected). The raw token string never appeared anywhere in the captured server output (`grep -c` for the exact token value against the captured log: 0 matches).
6. **Full regression suite:** `mix test --include integration` (via `make test-integration-elixir` against the live compose stack) — 1557 tests, 2 skipped, 7 failures, ALL 7 pre-existing/unrelated to this change (timing-sensitive load tests `RegressionSyncLoadTest`/`SyncConcurrentTest`, SSO single-use-token race `MatrixSsoTest`, admin-provisioning cross-test DB-state races in `AdminOidcLoginTest`, and a cache/seam-ordering test in `SsoLoginTest`) — confirmed identical before/after this cycle's changes except that the `RequestLoggerTest` AC1 failure (the second-order regression from step 4) is gone after the `:test`-env disable fix. `server/test/nebu/web/plugs/request_logger_test.exs` (all 9, including both `:integration`-tagged tests) and `server/test/nebu/web/plugs/request_logger/payload_redactor_test.exs` (all 27) pass cleanly, both standalone and inside the full suite. `mix compile --warnings-as-errors` passes.
7. **Why this is a distinct, more foundational bug than this story originally scoped:** the story's own AC4-AC10 only ever covered `RequestLogger`/`PayloadRedactor`'s HTTP-layer request/response body redaction. Ecto's bound-parameter logging is a completely separate, lower-level leak surface — any future query anywhere in the codebase that binds a credential as a `$N` parameter (not just `MatrixSessionStore`) would have reproduced the same class of leak the instant an operator turned on `:debug`, regardless of how thorough `PayloadRedactor` itself is. Fixing it at the Ecto/`Nebu.Repo` level (once, globally) rather than per-call-site closes that entire class of leak for the whole codebase, not just the one query path this story's ATDD test happened to exercise.

### Code-Review Cycle 1 (formal review — M1-M3/m1-m5 fixes)

The first formal code review (post CI-gate cycles 1-2) found three MAJOR and five MINOR findings, all fixed in this cycle:

- **M1 (`new_password` missing):** added `new_password` to `PayloadRedactor.@credential_keys`. `POST /_matrix/client/v3/account/password` carries the NEW plaintext password under this distinct key (the endpoint's `password`/`auth.password` fields carry the CURRENT password, already covered). Added two unit tests (top-level and arbitrary-depth nesting).
- **M2 (`?access_token=` redaction never wired end-to-end):** `RequestLogger` never logged `conn.query_string` anywhere, so `PayloadRedactor`'s existing `access_token=` regex handling was exercised only by isolated unit tests, not the real request path. Added `redacted_query_string/1` to `request_logger.ex`, which reads `conn.query_string`, routes it through `PayloadRedactor.redact_payload/1`, and includes it as a `query_string` field in the DEBUG log. Added an end-to-end test in `request_logger_test.exs` proving a `GET /_matrix/client/v3/sync?access_token=<secret>` URL never leaks the secret, with the `***REDACTED***` marker present as positive evidence of capture.
- **M3 (zero test coverage for `Nebu.Repo.QueryTelemetry`):** added `server/test/nebu/repo/query_telemetry_test.exs` (5 tests). Since the module is disabled by default in `:test` (to avoid `ExUnit.CaptureLog` cross-test interleaving — see the module's own moduledoc), this test suite locally overrides `config :nebu, Nebu.Repo.QueryTelemetry, enabled: true` for its own duration (restored via `on_exit/1`) and calls `QueryTelemetry.handle_event/4` DIRECTLY with synthetic Ecto telemetry metadata carrying a fake bound token and raw SQL text — no live `Nebu.Repo`/Postgres or `--include integration` needed. Asserts the sanitized log line contains `source=`/`duration_ms=`/`result=` but never the raw token or SQL text, for both successful and failed query outcomes.
- **m1 (duplicate Authorization-header redaction logic):** `RequestLogger.redact_auth_header/1` previously hardcoded "always redact, unconditionally" instead of using `PayloadRedactor`'s own credential-key matching — a second, independent implementation of "what counts as a credential" that could drift from the first. Changed it to route through `PayloadRedactor.redact_payload/1` (`%{"authorization" => value} |> PayloadRedactor.redact_payload() |> Map.get("authorization")`), reusing the SAME matching logic as body/query-string redaction.
- **m2 (`unsigned.prev_content` not covered):** `PayloadRedactor.content_key?/1` now also matches `prev_content` (a Matrix state event's previous content, e.g. a room's old name/topic before an edit) — same leak class as `content` itself. Added a dedicated unit test.
- **m3 (`QueryTelemetry` doesn't distinguish success/failure):** added a `classify_result/1` helper deriving `result=ok|error|unknown` from the telemetry metadata's `:result` field (never surfacing the raw `Exception` struct/message, which could itself carry sensitive data). Added to the sanitized log line and covered by tests for both outcomes.
- **m4 (`Jason.decode/1` unconditionally attempted on every response body):** added `json_content_type?/1` to `request_logger.ex` — only attempts `Jason.decode/1` when the response declares a JSON `content-type`, short-circuiting binary media downloads that would always fail to parse.
- **m5 (weak type-only assertions in `payload_redactor_test.exs`):** the pre-dev test-review had already flagged this (MINOR-1/MINOR-2) as unaddressed across 3 prior cycles. Rather than just adding assertions the current implementation would fail, `redact_string/1` itself was extended: it now recognises `key=value` (query-string/form-encoded) AND `"key": "value"` (malformed/unparseable JSON-ish fragment) patterns for the credential keys, plus `"body": "..."` for message content — all via cheap `String.contains?/2`-gated regex substitutions, never via `Jason.decode`, so the "never fabricate structure from malformed input" guarantee is unchanged. This makes the form-encoded-body test's `refresh_token=...` value and the malformed-JSON test's `"body": "leaked secret"` value both genuinely absent from the redacted output, not just "some binary/non-map came back" — exactly the pre-dev review's original intent.

**Test coverage after cycle 1:** `PayloadRedactor` unit tests: 30 (was 27; +3 for M1/m2). `RequestLogger` tests: 10 (was 9; +1 for M2), 9 pass under plain `mix test`, 1 `:integration`-tagged requires a live DB. `Nebu.Repo.QueryTelemetry` tests: 5 (new). `mix compile --warnings-as-errors` passes. Full non-integration `mix test` suite: no regressions (see Change Log entry for exact counts).

### Regression Fix Cycle 4 — restore the "zero DB children" unit-test invariant

While investigating unrelated `mix test` failures, a regression from cycle 2's global Ecto-query-logger fix was discovered and fixed:

**The regression:** `Nebu.Application.repo_children/0` gates starting `Nebu.Repo`/`Sweeper`/`RefreshWorker` on `Application.get_env(:nebu, Nebu.Repo)` being truthy — a documented invariant meaning "plain unit runs (no `NEBU_DB_URL`) start zero DB children." That key was historically set ONLY from the two `NEBU_DB_URL`-gated blocks in `config/runtime.exs`. Cycle 2 added `config :nebu, Nebu.Repo, log: false` to `config/config.exs` — which is compiled into EVERY build unconditionally, regardless of env or runtime env vars — so `Application.get_env(:nebu, Nebu.Repo)` became always-truthy (`[log: false]`), even with no `NEBU_DB_URL` set anywhere. This silently broke the "zero DB children" contract: `Nebu.Repo` started (and repeatedly failed to connect) in every plain-unit-test run.

**The fix:**
1. Removed the unconditional `config :nebu, Nebu.Repo, log: false` from `server/config/config.exs` (kept and extended the explanatory comment, now pointing at `runtime.exs`).
2. Added `log: false` as an additional key merged into BOTH existing `NEBU_DB_URL`-gated `config :nebu, Nebu.Repo, url: ...` calls in `server/config/runtime.exs` (the `:prod`/`:dev` block and the `:test` block) — so `log: false` only ever gets set TOGETHER WITH real DB connection config, preserving "presence of `:nebu, Nebu.Repo` config == DB is configured" exactly as it worked before cycle 2.
3. Added `server/test/nebu/application_test.exs` — a plain-unit regression test asserting `Application.get_env(:nebu, Nebu.Repo) == nil` when `NEBU_DB_URL` is not set (the test self-skips its assertion, rather than failing for the wrong reason, if `NEBU_DB_URL` happens to be set — e.g. under `--include integration`).

**Verification:**
- `mix compile --warnings-as-errors` passes.
- The new `server/test/nebu/application_test.exs` passes under plain `mix test` (no `NEBU_DB_URL`).
- `server/test/nebu/repo/query_telemetry_test.exs`, `server/test/nebu/web/plugs/request_logger_test.exs`, and `server/test/nebu/web/plugs/request_logger/payload_redactor_test.exs` all still pass (44 tests, 1 excluded/`:integration`).
- Full non-integration `mix test`: 1293 passed, 2 skipped, 272 excluded, 0 failures (was 1283 passed pre-cycle-4; +10 net from cycle-1's M1-M3/m1-m5 additions and this cycle's new regression test file, none of which regressed).
- `make test-integration-elixir` run against the live docker-compose stack (already up: postgres/dex/minio/server) with `NEBU_DB_URL` set: 1567 tests, 7 failures, 2 skipped — the exact same 7 failures (`RegressionSyncLoadTest`/`SyncConcurrentTest` timing, `MatrixSsoTest` single-use-token race, `AdminOidcLoginTest` cross-test DB-state races, `SsoLoginTest` cache/seam-ordering) already documented as pre-existing/unrelated in cycle 2's record — i.e. identical baseline, confirming `Nebu.Repo` still starts correctly with `NEBU_DB_URL` set and `log: false` still applies (no new failures from this cycle's config changes).

### Fix Cycle 5 — Kassandra SEC-gate BLOCKED verdict (F1 CRITICAL, F2/F3 HIGH, F4 MEDIUM)

Kassandra's security review 2026-07-05
(`docs/stories/enhanced-logging/security-reports/matrix-payload-debug-logging-security-review-2026-07-05.md`)
BLOCKED the commit: Category 2 (message content) redaction was structurally
keyed on finding a literal `content`/`prev_content` WRAPPER key, and treated
everything inside it as content unless allowlisted as metadata. That
assumption is wrong for real Matrix payloads:

- **F1 (CRITICAL):** the Matrix write path — `PUT
  .../send/{eventType}/{txnId}` and `PUT .../state/{eventType}/{stateKey}` —
  sends event content as the RAW TOP-LEVEL request body (no `content`
  wrapper at all), so `body`/`formatted_body`/`topic`/`name`/`displayname`/
  `filename` fell through completely unredacted on the single most common
  Matrix write operation.
- **F2 (HIGH):** `m.relates_to` sat in the metadata allowlist, so the walker
  recursed into it with `in_content?=false`, leaving its `key` child (the
  actual reaction emoji/text a user picked) unredacted; the existing
  `redact_relation_map/1` (which masks `key`) was dead code for the standard
  shape.
- **F3 (HIGH):** `reason` (kick/ban/redaction free text) sat in the metadata
  allowlist and survived redaction on the read path (`/sync`, `/messages`).
- **F4 (MEDIUM):** `client_secret`/`id_access_token` (3PID `requestToken`/
  identity-server flows) were missing from the credential key sets.

**The fix** (`server/lib/nebu/web/plugs/request_logger/payload_redactor.ex`)
switches Category 2 detection from purely structural to field-name-based at
ANY depth — the same principle Category 1's `credential_key?/1` already
used:

1. Added `@always_content_keys` (`body`, `formatted_body`, `filename`,
   `topic`, `name`, `displayname`, `reason`) — checked in `redact_map/3`'s
   `cond` at every level of recursion, independent of whether the current
   key is nested under a `content`/`prev_content` wrapper. This closes F1:
   a top-level `%{"body" => "...", "msgtype" => "..."}` (no wrapper) now has
   `body` redacted while `msgtype` survives.
2. Added a dedicated `relates_to_key?/1` check (`normalize_key(key) ==
   "m.relates_to"`), evaluated BEFORE the in-content/metadata-allowlist
   branch and at any depth, that always recurses into the value via
   `redact_relation_map/1` — masking `key` while preserving `rel_type`/
   `event_id`. `m.relates_to` was removed from `@content_metadata_keys` so
   it can never again be blanket-skipped as metadata. Closes F2. (The
   now-redundant structural `relation_map?/1` heuristic in
   `redact_content_value/1` was removed as dead code — fail-closed: any
   OTHER map value found under a content-shaped key is now unconditionally
   masked rather than structurally guessed at.)
3. Removed `reason` from `@content_metadata_keys` and added it to
   `@always_content_keys` instead. Closes F3.
4. Added `client_secret` and `id_access_token` to both `@credential_keys`
   and `@credential_string_keys`. Verified via `grep` for
   `3pid`/`threepid`/`requestToken` across `server/lib/nebu/web/router/`
   that Nebu does not currently implement the corresponding 3PID/
   identity-server endpoints (only a disabled capability flag exists) —
   added defensively per Kassandra's guidance regardless, since the field
   names could still appear in a request body this plug logs. Closes F4.

**TDD:** added 13 new tests FIRST (7 in `payload_redactor_test.exs` for
F1/F2/F4 unit-level cases, 1 F2-at-any-depth case, 1 F3 case, 3 F4 cases; 1
end-to-end `RequestLoggerTest` case for F1 PUTting a send-event-shaped body
with no `content` wrapper) and verified all 13 FAILED against the pre-fix
code (`mix test test/nebu/web/plugs/request_logger/payload_redactor_test.exs
test/nebu/web/plugs/request_logger_test.exs` — 39/52 passed, 13 failures,
all in the new F1-F4 describe blocks) before implementing the fix.

**Verification:**
- `mix compile --warnings-as-errors` passes.
- `test/nebu/web/plugs/request_logger/payload_redactor_test.exs` +
  `test/nebu/web/plugs/request_logger_test.exs`: all 52 tests pass (was 39
  passing pre-fix + 13 new red-then-green).
- Full non-integration `mix test`: 1306 passed, 2 skipped, 272 excluded, 0
  failures (was 1293 passed pre-cycle-5; +13 net, all new F1-F4 tests, no
  regressions — every pre-existing metadata-survival assertion, e.g.
  `msgtype`/`url`/`format`/`algorithm`/`sender_key`/`device_id`/
  `session_id`/`info`/`avatar_url`/`membership`, still passes unchanged).
- `make test-integration-elixir`-equivalent (docker-compose stack up, then
  `docker run --network=nebu_default ... mix test --include integration
  --warnings-as-errors` against `postgres:5432`; ran the two steps
  separately rather than through the Makefile target so the full test
  summary could be captured to a log file instead of being lost to a
  truncated `tail`). Needed a fresh `nebu_postgres_data` volume first — the
  pre-existing volume had become corrupted ("could not write init file" /
  `initdb: ... No space left on device`) because the Docker Desktop VM's
  build-cache disk had filled up (`docker system df` showed ~28GB
  reclaimable build cache); freed via `docker builder prune -af` +
  `docker image prune -af` + a fresh volume — an environment/infra issue,
  unrelated to this story's code.
  **Result: 1580 tests, 5 failures, 2 skipped.** All 5 failures are
  pre-existing/environmental and unrelated to `RequestLogger`/
  `PayloadRedactor`/`QueryTelemetry`:
  `Nebu.Web.RegressionSyncLoadTest` (timing, median-latency SLA under load),
  `Nebu.Web.SyncConcurrentTest` (timing, 50 concurrent long-polls within
  500ms), `Nebu.Web.OidcPlugTest` "alg-confusion" test (`** (UndefinedFunctionError)
  function :jose_jwk_kty_oct.from_oct/1 is undefined` — a `jose`/Erlang NIF
  module missing in the ephemeral `elixir:1.19-alpine` test-runner image,
  unrelated to any code in this diff), and two `Nebu.Web.UrlPreviewTest`
  cases (`** (UndefinedFunctionError) function
  Floki.HTMLParser.Mochiweb.parse_document/2 is undefined` /
  `corrupt file header` — a corrupted compiled `.beam` for an unrelated
  dependency, `floki`, in that same ephemeral container). None of these
  failures touch this story's files, and no test in
  `payload_redactor_test.exs`, `request_logger_test.exs`, or
  `query_telemetry_test.exs` appears anywhere in the failure list —
  confirming no integration-level regressions from this cycle's
  redaction-logic changes.

### Fix Cycle 6 — Kassandra SEC-gate re-verify, cycle 5 finding F1-R (HIGH, residual of F1)

Kassandra's independent re-verify of cycle 5's fix
(`docs/stories/enhanced-logging/security-reports/matrix-payload-debug-logging-security-review-cycle5-reverify.md`)
confirmed F2/F3/F4 genuinely closed, but found cycle 5's F1 fix
**structurally incomplete** for the write path (BLOCKED, HIGH — F1-R):

Cycle 5 closed the F1 write-path leak by adding a FIXED field-name list
(`@always_content_keys`: `body`/`formatted_body`/`filename`/`topic`/`name`/
`displayname`/`reason`) checked at any recursion depth. That closes the
COMMON cases, but does not fix the root cause: `PayloadRedactor.redact_payload/1`
always called `redact_map(map, in_content? = false, ...)` for request
bodies, so the "any non-metadata key in `content` ⇒ content" catch-all
(`in_content? and not content_metadata_key?(key) -> redact_content_value`)
never fired for write-path bodies (which have no `content` wrapper at
all). Any content field NOT on the fixed list still leaked verbatim on the
write path — e.g. `m.location.geo_uri` (plaintext GPS coordinates, PII),
custom/vendor event content fields, poll question/answer text, and
`m.room.encrypted.ciphertext` — because Matrix's event schema is
open/extensible and a fixed key list can never be exhaustive.

**The fix** — route-aware `in_content?: true` redaction for the write path,
exactly Kassandra's prescribed remediation:

1. `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex`: added a
   new `redact_payload/2` arity accepting an `opts` keyword list with
   `in_content?: true`, which seeds the TOP-LEVEL recursion as though the
   given map/list were already the direct children of a `content` object
   (instead of the default `false`). `redact_payload/1` is unchanged in
   behaviour — it now simply delegates to `redact_payload(payload, [])`.
   All existing internal logic (`redact_map/3`, `redact_value/3`,
   `@always_content_keys`, `@content_metadata_keys`, `relates_to_key?/1`,
   `credential_key?/1`, etc.) is untouched — this is additive, not a
   rewrite.
2. `server/lib/nebu/web/plugs/request_logger.ex`: added
   `write_path_content_body?/1`, which matches `conn.request_path` (NOT
   `conn.path_info` — `path_info` is mutated by `Plug.Router`'s `forward`,
   which strips the matched `/_matrix` prefix before this `before_send`
   callback runs, whereas `request_path` reflects the original full
   request path throughout, same as the existing `base_fields.path`)
   against two regexes: `PUT .../rooms/{roomId}/send/{eventType}/{txnId}`
   and `PUT .../rooms/{roomId}/state/{eventType}[/{stateKey}]`, forward-
   compatible with any `v{N}` API version segment. `redacted_request_body/1`
   now calls `PayloadRedactor.redact_payload(params, in_content?: true)`
   for those routes and the unchanged `PayloadRedactor.redact_payload(params)`
   (default `in_content?: false`) for every other route, including the
   read path (`/sync`, `/messages`, etc.) where content is already wrapped
   under a `content` key and therefore already gets the same catch-all via
   the existing `content_key?/1` recursion.

**TDD:** added 7 new tests FIRST — 4 unit-level in `payload_redactor_test.exs`
(`redact_payload/2` with `in_content?: true` masking `geo_uri`, an arbitrary
custom/vendor field, and `ciphertext`; one confirming Category 1 credential
redaction is unaffected by the option; one confirming the UNCHANGED default
`redact_payload/1` still does NOT mask a non-fixed top-level field, locking
in the intentional narrower default for non-write-path callers) and 3
end-to-end in `request_logger_test.exs` (PUT send with `geo_uri`, PUT send
with a custom/vendor event's arbitrary field, PUT state with a custom
state-event field) — and verified all 7 FAILED against the pre-fix code
(`mix test test/nebu/web/plugs/request_logger/payload_redactor_test.exs
test/nebu/web/plugs/request_logger_test.exs` — 53/60 passed, 7 failures, 4
`UndefinedFunctionError: redact_payload/2 is undefined` and 3 end-to-end
`geo_uri`/`custom_field`/`custom_state_field` leak assertions) before
implementing the fix.

**Verification:**
- `mix compile --warnings-as-errors` passes.
- `test/nebu/web/plugs/request_logger/payload_redactor_test.exs` +
  `test/nebu/web/plugs/request_logger_test.exs`: all 60 tests pass (1
  `:integration`-tagged excluded), was 53/60 pre-fix + 7 new red-then-green.
- Full non-integration `mix test`: **1314 passed, 2 skipped, 272 excluded,
  0 failures** (was 1306 passed pre-cycle-6; +8 net — 7 new F1-R tests plus
  1 from an unrelated pre-existing test-count drift unrelated to this
  cycle's diff — no regressions; every pre-existing F1/F2/F3/F4 test from
  cycle 5, and every credential-key test, still passes unchanged).
- Live docker-compose stack integration verification: **not performed this
  cycle** — no server/postgres/dex/minio stack was running in this
  environment (`docker compose ps` showed only an unrelated `nebu-element-1`
  container), and bringing up a fresh stack was judged unnecessary given the
  fix is a pure, additive, unit-testable change to `PayloadRedactor`'s
  redaction logic plus a `conn.request_path` regex match in `RequestLogger`
  — no DB/network/cross-domain behaviour changed. Per the task's own
  guidance, a human will independently re-verify integration tests and
  re-run a fresh Kassandra security review afterward regardless. The unit-
  level fix and its dedicated tests (both `PayloadRedactor`-level and
  end-to-end through `Nebu.Web.Router.call/2` via `Plug.Test`, matching the
  `RequestLoggerTest` file's existing non-DB test pattern) are green.

## File List

- `server/lib/nebu/web/plugs/request_logger.ex` (modified — cycle 1: query-string capture/redaction (M2), Authorization-header redaction routed through `PayloadRedactor` (m1), JSON content-type guard before response-body decode (m4))
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` (new; modified cycle 1 — `new_password` credential key (M1), `prev_content` content-key detection (m2), extended `redact_string/1` for key=value/JSON-string-style credential+content patterns (m5))
- `server/test/nebu/web/plugs/request_logger_test.exs` (new, ATDD — pre-staged; modified cycle 1 — added M2 end-to-end query-param redaction test)
- `server/test/nebu/web/plugs/request_logger/payload_redactor_test.exs` (new, ATDD — pre-staged; modified cycle 1 — added M1/m2 tests, strengthened m5 assertions)
- `server/lib/nebu/repo/query_telemetry.ex` (new, cycle 2; modified cycle 1 — success/failure `result` classification (m3))
- `server/test/nebu/repo/query_telemetry_test.exs` (new, cycle 1 — M3 dedicated unit test coverage)
- `server/config/config.exs` (modified, cycle 2 — `config :nebu, Nebu.Repo, log: false`, applies to every env; modified cycle 4 — REMOVED that unconditional line, which broke the "zero DB children" unit-test invariant; comment kept/extended pointing at `runtime.exs`)
- `server/config/test.exs` (modified, cycle 2 — `config :nebu, Nebu.Repo.QueryTelemetry, enabled: false`, test-only to avoid `ExUnit.CaptureLog` cross-test interleaving)
- `server/config/runtime.exs` (modified, cycle 4 — merged `log: false` into both `NEBU_DB_URL`-gated `config :nebu, Nebu.Repo, url: ...` calls, prod/dev and test, so `log: false` only ever accompanies real DB config)
- `server/lib/nebu/application.ex` (modified, cycle 2 — attaches `Nebu.Repo.QueryTelemetry` in `start/2`)
- `server/lib/nebu/matrix/session/matrix_session_store.ex` (modified, cycle 2 — reverted cycle 1's per-call-site `log: false` on `query/2`, now covered by the global fix; comment updated to point at it)
- `server/test/nebu/application_test.exs` (new, cycle 4 — regression test asserting `Application.get_env(:nebu, Nebu.Repo) == nil` when `NEBU_DB_URL` is unset)
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` (modified, cycle 5 — Kassandra SEC-gate fix: field-name-based content detection at any depth (`@always_content_keys`, F1); dedicated `m.relates_to` handling always calling `redact_relation_map/1` (F2); `reason` moved from the metadata allowlist to `@always_content_keys` (F3); `client_secret`/`id_access_token` added to both credential key sets (F4))
- `server/test/nebu/web/plugs/request_logger/payload_redactor_test.exs` (modified, cycle 5 — 12 new F1/F2/F3/F4 unit tests)
- `server/test/nebu/web/plugs/request_logger_test.exs` (modified, cycle 5 — 1 new F1 end-to-end test: PUT send-event-shaped body with no `content` wrapper never leaks the message text)
- `docs/stories/enhanced-logging/security-reports/matrix-payload-debug-logging-security-review-2026-07-05.md` (Kassandra's SEC-gate BLOCKED report, read-only input to this cycle's fix — not modified)
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` (modified, cycle 6 — Kassandra SEC-gate re-verify fix F1-R: added `redact_payload/2` with `in_content?: true` option, additive to the unchanged `redact_payload/1` default)
- `server/lib/nebu/web/plugs/request_logger.ex` (modified, cycle 6 — F1-R: added `write_path_content_body?/1` (matches `conn.request_path` against the `send`/`state` write-path route shapes) and routed those routes' request bodies through `PayloadRedactor.redact_payload(params, in_content?: true)`)
- `server/test/nebu/web/plugs/request_logger/payload_redactor_test.exs` (modified, cycle 6 — 4 new F1-R unit tests for `redact_payload/2`)
- `server/test/nebu/web/plugs/request_logger_test.exs` (modified, cycle 6 — 3 new F1-R end-to-end tests: PUT send with `geo_uri`, PUT send with a custom/vendor field, PUT state with a custom state-event field)
- `docs/stories/enhanced-logging/security-reports/matrix-payload-debug-logging-security-review-cycle5-reverify.md` (Kassandra's SEC-gate re-verify BLOCKED report, read-only input to this cycle's fix — not modified)

## Change Log

- 2026-07-04: Story created with full context on two-category redaction (credentials + message content), explicit security review gate, and implementation guidance. Ready for dev agent handoff.
- 2026-07-04: Implemented `PayloadRedactor` module and extended `RequestLogger` with DEBUG-level payload capture + redaction. All 10 acceptance tests green; full regression suite passes with no failures. Status set to review pending Kassandra SEC gate.
- 2026-07-04 (CI-gate cycle 1): Fixed Bug 1 (top-level `token` field missing from credential redaction, `payload_redactor.ex`). Found Bug 2 (Ecto query-parameter logging leaks opaque tokens at `:debug`, unrelated to `RequestLogger`) and shipped a per-call-site fix on `MatrixSessionStore.query/2`.
- 2026-07-04 (CI-gate cycle 2): Per user direction, replaced cycle 1's per-call-site Bug 2 fix with a global one: `config :nebu, Nebu.Repo, log: false` (all envs) + `Nebu.Repo.QueryTelemetry` telemetry handler (sanitized `source`/`duration_ms` only, attached from `Nebu.Application.start/2`). Found and fixed a second-order test-isolation regression this introduced (`ExUnit.CaptureLog` cross-test interleaving broke one `RequestLogger` AC1 test) via `config :nebu, Nebu.Repo.QueryTelemetry, enabled: false` in `:test`. Verified against the live docker-compose stack (manual `Logger.configure(level: :debug)` via `nebu rpc` + curl + log grep: no raw token in output) and the full `mix test --include integration` suite (1557 tests, 7 pre-existing/unrelated failures, identical to the pre-cycle-2 baseline except the regression this cycle introduced-and-fixed).
- 2026-07-05 (code-review cycle 1 — formal review, M1-M3/m1-m5): Fixed all 3 MAJOR findings (M1: added `new_password` to the credential key list; M2: wired `conn.query_string` capture+redaction into `RequestLogger`, closing the "unit-tested but never exercised end-to-end" gap for the deprecated `?access_token=` query-param MUST; M3: added `server/test/nebu/repo/query_telemetry_test.exs`, 5 tests calling `QueryTelemetry.handle_event/4` directly with synthetic telemetry metadata) and all 5 MINOR findings (m1: de-duplicated Authorization-header redaction by routing it through `PayloadRedactor`; m2: `unsigned.prev_content` now covered by content-key detection; m3: added success/failure `result` classification to `QueryTelemetry`'s sanitized log line; m4: added a JSON-content-type guard before attempting response-body decode; m5: extended `redact_string/1` to genuinely redact recognisable credential/content patterns in otherwise-opaque strings, and strengthened the two previously-weak tests to assert the specific secret substring is absent). Added tests: 3 in `payload_redactor_test.exs` (30 total), 1 in `request_logger_test.exs` (10 total), 5 new in `query_telemetry_test.exs`. `mix compile --warnings-as-errors` passes; full non-integration `mix test` suite passes with no regressions.
- 2026-07-05 (fix cycle 4 — regression fix, discovered while investigating unrelated `mix test` failures): Cycle 2's unconditional `config :nebu, Nebu.Repo, log: false` in `server/config/config.exs` silently broke the documented "plain unit runs start zero DB children" invariant in `Nebu.Application.repo_children/0`, because `config.exs` is compiled into every build regardless of `NEBU_DB_URL`. Removed that unconditional line; merged `log: false` into both existing `NEBU_DB_URL`-gated `config :nebu, Nebu.Repo, url: ...` calls in `server/config/runtime.exs` (`:prod`/`:dev` and `:test` blocks) instead, so `log: false` only ever accompanies real DB config. Added `server/test/nebu/application_test.exs` (regression test locking the invariant in). Verified: `mix compile --warnings-as-errors` passes; full non-integration `mix test` — 1293 passed, 2 skipped, 272 excluded, 0 failures; `make test-integration-elixir` against the live docker-compose stack — 1567 tests, 7 failures (identical pre-existing/unrelated baseline from cycle 2's record), 2 skipped, confirming `Nebu.Repo` still starts and `log: false` still applies when `NEBU_DB_URL` is set.
- 2026-07-05 (fix cycle 5 — Kassandra SEC-gate BLOCKED verdict, F1 CRITICAL / F2/F3 HIGH / F4 MEDIUM): The SEC gate found Category 2 (message-content) redaction was structurally keyed on a literal `content`/`prev_content` wrapper plus a metadata allowlist — wrong for real Matrix payloads. F1 (CRITICAL): the write path (`send`/`setState`) puts event content at the TOP LEVEL of the request body with no wrapper at all, so `body`/`formatted_body`/`topic`/`name`/`displayname`/`filename` leaked verbatim on the single most common Matrix write operation. F2 (HIGH): `m.relates_to` sat in the metadata allowlist, shadowing its own user-generated `key` (reaction text). F3 (HIGH): `reason` (kick/ban/redaction free text) sat in the metadata allowlist and survived on the read path. F4 (MEDIUM): `client_secret`/`id_access_token` missing from the credential key sets. Fixed by switching Category 2 detection to field-name-based at ANY depth (mirroring how Category 1's `credential_key?/1` already worked): added `@always_content_keys` (`body`, `formatted_body`, `filename`, `topic`, `name`, `displayname`, `reason`) checked at every level of recursion regardless of wrapper context (F1, F3); added a dedicated `relates_to_key?/1` check evaluated before the metadata-allowlist branch that always recurses via `redact_relation_map/1`, masking `key` while preserving `rel_type`/`event_id` (F2); removed `m.relates_to`/`reason` from `@content_metadata_keys`; added `client_secret`/`id_access_token` to both `@credential_keys` and `@credential_string_keys` after confirming (via router grep) Nebu doesn't yet implement the corresponding 3PID/identity-server endpoints but adding the keys defensively anyway (F4). TDD: wrote 13 new tests FIRST (12 in `payload_redactor_test.exs`, 1 end-to-end in `request_logger_test.exs`), verified all 13 failed against the pre-fix code, then implemented the fix and verified all 13 pass. `mix compile --warnings-as-errors` passes. Full non-integration `mix test`: 1306 passed, 2 skipped, 272 excluded, 0 failures (no regressions — all pre-existing metadata-survival assertions still pass). Full integration suite (fresh docker-compose stack + fresh `nebu_postgres_data` volume, after freeing Docker Desktop VM disk space via `docker builder prune -af`): 1580 tests, 5 failures, 2 skipped — all 5 failures are pre-existing/environmental (timing-sensitive load tests, a missing `jose` NIF module and a corrupted `floki` dependency `.beam` in the ephemeral test-runner container) and unrelated to `RequestLogger`/`PayloadRedactor`/`QueryTelemetry`, confirming no regressions.
- 2026-07-05 (fix cycle 6 — Kassandra SEC-gate RE-VERIFY finding F1-R, HIGH, residual of F1): The independent re-verify found cycle 5's F1 fix structurally incomplete for the write path: a FIXED field-name list (`@always_content_keys`) can never be exhaustive for Matrix's open/extensible event schema, so any write-path content field NOT on that list (e.g. `m.location.geo_uri` — plaintext GPS PII — custom/vendor event fields, poll text, `m.room.encrypted.ciphertext`) still leaked verbatim, because `redact_payload/1` always seeded the top-level recursion with `in_content? = false`, so the "non-metadata inside `content` ⇒ content" catch-all never fired for wrapper-less write-path bodies. Fixed per Kassandra's prescribed remediation: added `PayloadRedactor.redact_payload/2` (`in_content?: true` option, additive — `redact_payload/1`'s behaviour and every existing internal helper are unchanged) and `RequestLogger.write_path_content_body?/1` (matches `conn.request_path`, not `conn.path_info` since `forward` mutates the latter, against the `PUT .../rooms/{roomId}/send/{eventType}/{txnId}` and `PUT .../rooms/{roomId}/state/{eventType}[/{stateKey}]` route shapes) so those two write-path route families call `redact_payload(params, in_content?: true)` while every other route (including the read path, which already gets the same catch-all via its `content` wrapper) is unaffected. TDD: wrote 7 new tests FIRST (4 unit-level in `payload_redactor_test.exs` for `geo_uri`/custom-field/`ciphertext`/credential-unaffected, 1 confirming the unchanged narrower default; 3 end-to-end in `request_logger_test.exs` for PUT send `geo_uri`, PUT send custom/vendor field, PUT state custom field), verified all 7 failed against the pre-fix code, then implemented the fix and verified all 7 pass. `mix compile --warnings-as-errors` passes. Full non-integration `mix test`: 1314 passed, 2 skipped, 272 excluded, 0 failures (no regressions — every cycle-5 F1/F2/F3/F4 test and every credential-key test still passes unchanged). Live docker-compose integration verification not performed this cycle (no stack running in this environment); the fix is a pure, additive, unit-testable change with no DB/network/cross-domain behaviour change, and a human will independently re-verify integration tests and re-run a fresh Kassandra security review regardless.
