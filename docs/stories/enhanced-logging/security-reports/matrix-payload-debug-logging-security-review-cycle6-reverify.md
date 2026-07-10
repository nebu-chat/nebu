## Security Review (Re-verify, cycle 6) — enhanced-logging / matrix-payload-debug-logging

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged diff (`git diff --staged`) — full fresh independent pass over the RequestLogger DEBUG payload-capture + two-category PayloadRedactor, the new route-aware `in_content?: true` write-path wiring, the Ecto query-logger sanitization (QueryTelemetry), and supporting config. This is an INDEPENDENT re-review of the dev-agent fix for the prior BLOCKED (HIGH) verdict; the fix description was NOT trusted — every claim was traced against the current code and against the ACTUAL registered router shapes.
**Date:** 2026-07-05
**Prior report:** `matrix-payload-debug-logging-security-review-cycle5-reverify.md` (BLOCKED / HIGH, F1-R)
**Verdict:** APPROVED (CLEAR)
**Classification:** CLEAN (no CRITICAL/HIGH; 2 MEDIUM + 2 LOW advisories)

---

### Primary mandate result (two-category redaction)

Phil's explicit LAW: BOTH categories must be genuinely closed — (1) credentials/secrets AND (2) chat message content / user-generated text — verified against REAL Matrix payload shapes on BOTH read and write paths, not merely "tests exist."

- **Category 1 (credentials):** UPHELD, untouched by this change. `@credential_keys` (incl. `client_secret`/`id_access_token`, F4) still matched at any depth; the credential branch is FIRST in the `cond`, so no content branch can shadow a secret. A unit test (`payload_redactor_test.exs:601`) explicitly confirms credentials are still redacted when `in_content?: true`. Ecto bound-parameter leak remains CLOSED (`log: false`; QueryTelemetry logs only source/duration/result).
- **Category 2 (message content) — send/state write path (the F1-R subject):** NOW GENUINELY CLOSED. The dev took the correct structural remediation (option b): route-aware `PayloadRedactor.redact_payload(params, in_content?: true)` for the send/state write-path routes, instead of relying on the fixed field-name list. `m.location.geo_uri`, custom/vendor fields, and `m.room.encrypted.ciphertext` are now masked on the write path — verified by trace AND by both unit and end-to-end tests.

The specific finding F1-R that BLOCKED cycle 5 is resolved. Two residual Category-2 leaks on OTHER write endpoints (search, presence) were surfaced by the fresh pass — MEDIUM, advisory, do not block the F1-R fix, but should be closed before epic end.

---

### F1-R re-verification (the cycle-5 blocker) — CLOSED

**Fix as implemented (verified against code, not description):**
1. `payload_redactor.ex:185-201` — new `redact_payload/2`; `in_content?: true` seeds `redact_map(payload, true)` so the top-level map is walked AS IF it were the direct children of a `content` object. `redact_payload/1` unchanged, delegates to `redact_payload(payload, [])` (`:149`). Default stays `false` (conservative).
2. `request_logger.ex:48-49,114-118,134-137` — `@send_event_path_regex` / `@state_event_path_regex` matched against `conn.request_path` in `write_path_content_body?/1`; matching request bodies routed through `redact_payload(params, in_content?: true)`, every other route keeps the default.

**Trace — send path, `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}` with an `m.location` body `{"msgtype":"m.location","body":"…","geo_uri":"geo:52.52,13.40"}`:**
`write_path_content_body?` → `true` → `redact_map(map, true)`. `geo_uri`: not credential, not `m.relates_to`, not in `@always_content_keys`, and now `in_content? = true and not content_metadata_key?("geo_uri")` → TRUE → `redact_content_value` → `***MESSAGE_CONTENT***`. Masked. `msgtype` is a `@content_metadata_keys` member → survives. Custom/vendor fields and `ciphertext` (not a metadata key) → masked; `algorithm`/`sender_key`/`session_id`/`device_id` (metadata) survive. **Leak closed.**

**Trace — state path, `PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType}[/{stateKey}]`:** both route arities (with and without `stateKey`) exist in `protected.ex:1301,1305` and both match `@state_event_path_regex` (`…/state/[^/]+(?:/[^/]*)?$`). Custom state content field → masked. **Closed.**

**Regex vs. ACTUAL router (mandate point 2):**
- Registered write routes are ALL `v3` (`protected.ex:681,1301,1305`). `v\d+` matches v3 and harmlessly permits future v1/v2 shapes; no registered write route escapes the pattern. No v1/v2 send/state routes exist to be missed.
- `conn.request_path` is the full, forward-independent original path (Plug does not strip it on `forward`); this is the same field `base_fields.path` uses, and the comment's justification is correct.
- Room IDs (`!id:server`), event types (`m.room.message`), and txn/state keys contain no literal `/`; URL-encoded slashes (`%2F`) stay encoded in `request_path`, so `[^/]+` holds. Query strings are NOT part of `request_path` (Plug separates `query_string`), so appended `?…` cannot break the match. **No realistic send/state request slips through.**
- Method is not checked, but this is SAFE: no GET/POST route shares the send/state path shape (confirmed: NO `get "/…/state/…"` route exists), and even an over-match would only apply `in_content?: true` to an empty GET body (`body_params` = `%Plug.Conn.Unfetched{}` → `nil`) or at worst OVER-redact — never under-redact. Direction of failure is fail-closed.

**Read path (mandate point 4):** `/sync`, `/messages`, `/event/{id}`, search results etc. do NOT match the write regex → default `in_content? = false`; response bodies always use `redact_payload/1`. Content stays wrapped under `content`/`prev_content` and is masked via `content_key?` recursion exactly as before. Not broken, not double-processed. **Unchanged.**

**Tests:** unit (`payload_redactor_test.exs:554-622`) cover `geo_uri`, custom field, `ciphertext` under `in_content?: true`, the credential-still-redacted case, and the default-off negative case. End-to-end (`request_logger_test.exs:279-350`) drive the real send AND state routes through the plug and assert `geo_uri` / custom / custom-state text never reaches the log and `***MESSAGE_CONTENT***` appears. Coverage is adequate and matches the exploit shapes.

---

### Findings (fresh full pass)

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F1-R | RESOLVED | `payload_redactor.ex:185-201`; `request_logger.ex:48-49,114-137` | Cycle-5 write-path content leak for non-fixed field names — now closed via route-aware `in_content?: true`. | None — verified closed. |
| N1 | MEDIUM | `request_logger.ex:108-123` (default path) + `POST /_matrix/client/v3/search` (`protected.ex:1212`) | **Category-2 residual.** `search_categories.room_events.search_term` (the user's search-query text) is user-generated text but is not in `@always_content_keys`, is nested (not top-level), and `/search` is not a write-path-content route → logged verbatim at DEBUG. Search response results ARE masked (they carry a `content` wrapper), only the REQUEST term leaks. | Either add a route-aware `in_content?`-style handling for the `search_term` position, or add `search_term` to `@always_content_keys` (any-depth), plus a write-path test asserting the query text is masked. |
| N2 | MEDIUM | same default path + `PUT /_matrix/client/v3/presence/{userId}/status` (`protected.ex:902`) | **Category-2 residual.** `status_msg` (presence free-text, user-generated) is not in `@always_content_keys` and presence is not a write-path-content route → logged verbatim at DEBUG. | Add `status_msg` to `@always_content_keys` (any-depth), plus a test. Lower privacy impact than N1 (presence text is shown to contacts), hence still MEDIUM not HIGH. |
| N3 | LOW | `PUT /_matrix/client/v3/user/{userId}/account_data/{type}` (`protected.ex:552`) | Account-data bodies are arbitrary user-defined JSON; only `@always_content_keys`/credential keys within them are masked. Non-standard keys leak. Data class is the user's OWN config (self-exposure to operator), debug-gated. | Optional: treat account_data bodies as `in_content?: true` too, or accept as low-risk. |
| N4 | LOW | `request_logger.ex:134-137` | A MALFORMED send/state path that does NOT match the regex (e.g. trailing slash `…/txn/`) 404s at the router but its body is still logged with the default `in_content? = false`, so non-fixed content fields could leak — but only for a request that does NOT actually send an event, and `@always_content_keys` still catch the common fields. Very narrow. | Optional: normalise/trim trailing slash before matching, or accept. |

### Independently verified CLEAN

- **F2 (`m.relates_to.key`), F3 (`reason`), F4 (`client_secret`/`id_access_token`)** — still closed; the new `in_content?` seeding does not shadow or reorder any of these (credential + `relates_to` + `always_content` branches all precede the `in_content?` branch in the `cond`).
- **New-gap / precedence analysis of the fix itself.** `redact_payload/2` only widens masking (adds the "non-metadata ⇒ content" catch-all at the top level); it can only OVER-redact, never under-redact. No branch-shadowing bypass introduced. `redact_payload/1` behaviour is byte-for-byte unchanged (delegates with `[]`).
- **Ecto query-logger.** `log: false` at both runtime DB-config sites; `QueryTelemetry.handle_event/4` logs only `source`/`duration_ms`/result classification. No user input reaches it. Unchanged by this diff.
- **Standard OWASP/STRIDE/CWE pass.** No SQL/command/path injection (no new user-input-to-sink path; QueryTelemetry reads telemetry metadata only). No new routes/auth/CSRF surface (RequestLogger is observe-only via `before_send`; regex match is read-only on the path string). String redaction remains literal-substring-gated before any `Regex.replace` → no ReDoS on raw media blobs. Binaries pass through opaque; response decoded only for JSON content-type. No hardcoded secrets, no weak crypto. Debug logs go to the operational `Logger` only, separate from `Nebu.Compliance`/`audit_log`.

### Summary

CRITICAL: 0
HIGH: 0 — the cycle-5 blocker F1-R is RESOLVED (verified by trace + unit + end-to-end tests, and validated against the real router shapes).
MEDIUM: 2 — advisory, address before epic end (N1 `search_term`, N2 `status_msg` — user-generated text on non-send/state write endpoints that the redactor's field-name list does not cover).
LOW: 2 — advisory (N3 account_data arbitrary keys, N4 malformed-path fallback edge).

**Verdict:** APPROVED / CLEAR. The dev applied the correct structural fix (route-aware `in_content?: true` for send/state bodies), not another fixed-list half-measure. The specific F1-R write-path content leak (`geo_uri` GPS PII, custom/vendor fields, `ciphertext`) is genuinely closed on BOTH send and state routes, the regex matches every real registered write route, and neither the read path nor credential redaction regressed. The fix does not block. Kassandra flags two MEDIUM residual user-text leaks on OTHER write endpoints (search query, presence message) that the same field-name-list limitation still leaves open — these were not the F1-R subject and are lower severity (debug-gated, operator-side, not chat-body content), but under Phil's no-sensitive-data-in-logs LAW they should be closed before the epic ends.
