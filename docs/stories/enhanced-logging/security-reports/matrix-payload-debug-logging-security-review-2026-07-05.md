## Security Review — enhanced-logging / matrix-payload-debug-logging

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged diff (`git diff --staged`) — RequestLogger DEBUG payload capture + two-category PayloadRedactor, Ecto query-logger sanitization (QueryTelemetry), supporting config.
**Date:** 2026-07-05
**Verdict:** BLOCKED
**Classification:** CRITICAL

---

### Primary mandate result (two-category redaction)

Phil's explicit reason this story exists is that BOTH redaction categories are verified: (1) credentials/secrets AND (2) chat message content must never reach the log, even at DEBUG.

- **Category 1 (credentials):** SUBSTANTIALLY UPHELD for the fields in scope, with a reachability-dependent completeness gap (F4). The Ecto bound-parameter leak (cycle-2/4 fix) is independently verified CLOSED.
- **Category 2 (message content):** REFUTED. The redactor's content detection is structurally keyed on a literal `content`/`prev_content` wrapper plus a metadata allowlist. Real Matrix payloads violate both assumptions:
  - The **write path** (send message, set state, set room name/topic, send reaction) puts the event content at the **top level of the request body with no `content` wrapper** — so it is never redacted (F1, CRITICAL).
  - The metadata allowlist **over-shadows** genuine user-generated text (`m.relates_to.key`, `reason`) even on the read path where content IS wrapped (F2, F3, HIGH).

The message-content half of the mandate does NOT hold. This blocks the commit.

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F1 | CRITICAL | `payload_redactor.ex:91-128,155` (design) + `request_logger.ex:90-96` + `protected.ex:693,1756` | Message content in write-path request bodies is NOT redacted. Matrix `PUT .../send/{eventType}/{txnId}` and `PUT .../state/{eventType}/{stateKey}` send the event content as the raw top-level body (`{"body":..,"msgtype":..}`, `{"topic":..}`, `{"name":..}`). Redaction only fires inside a key named `content`/`prev_content`; at top level `in_content?=false`, so `body`/`formatted_body`/`topic`/`name` fall through untouched and are logged verbatim in `request_body`. | Redact by field-name at ANY depth for known user-text keys (`body`, `formatted_body`, `topic`, `name`, `displayname`, ...), not only when nested under a `content` wrapper; OR treat the request body of send/state endpoints as a content object. Add an end-to-end plug test that POSTs/PUTs a message body and asserts `***MESSAGE_CONTENT***`. |
| F2 | HIGH | `payload_redactor.ex:76-79,121-125,166-196` | `m.reaction` `m.relates_to.key` (user-generated reaction text) leaks. `m.relates_to` is in `@content_metadata_keys`, so inside `content` the walker takes the else branch and recurses with `in_content?=false`; `key` is then not redacted. `redact_relation_map/1` (which would mask `key`) is unreachable for the standard placement because it is only called via `redact_content_value/1`, which is skipped for allowlisted metadata keys. | Special-case `m.relates_to`: recurse into it while still masking its `key` child (call `redact_relation_map/1` for it), instead of blanket metadata pass-through. |
| F3 | HIGH | `payload_redactor.ex:76-79` (`reason` in `@content_metadata_keys`) | `reason` is whitelisted as metadata, but in `m.room.member` (kick/ban/leave) and `m.room.redaction` it is user-generated free text and survives redaction on the read path (sync/messages responses). | Remove `reason` from `@content_metadata_keys` so it is treated as content, or scope the allowlist per event type. |
| F4 | MEDIUM | `payload_redactor.ex:70,221` (`@credential_keys` / `@credential_string_keys`) | Credential-key set omits `client_secret` (3PID `requestToken` flows) and `id_access_token` (identity-server bearer token). If/when those endpoints are reachable in Nebu, the values leak. Reachability-dependent (Nebu is federation-less; verify endpoint surface). | Add `client_secret`, `id_access_token` (and consider `mac`) to the credential key sets. |

### Detail

**Finding F1 — write-path message content leaks (CRITICAL)**
`RequestLogger.redacted_request_body/1` logs `conn.body_params` through `PayloadRedactor.redact_payload/1`. For the send-event handler (`protected.ex:693`, `content = body_params(conn)`) and the set-state handler (`protected.ex:1756`, whose own comment reads "body is the raw content object"), the client sends the event content directly as the top-level JSON body — there is no `content` key. `redact_map/3` only enters Category-2 redaction via `content_key?/1` matching `content`/`prev_content`. At the top level `in_content?` is `false`, so `body`, `formatted_body`, `topic`, `name` hit the `true ->` branch → `redact_value/3` → `redact_string/1`, which for a decoded scalar string (not a raw JSON/query fragment) returns it unchanged. Result: the exact plaintext a user typed appears in the DEBUG log's `request_body` field.

This is the single most common Matrix write operation, and this epic's stated goal (per `config.exs` header) is to make `:debug` "safe to enable anywhere, including prod." Under the exact intended operating condition, every sent message body, room name, and topic leaks — a direct violation of the no-sensitive-data-in-logs LAW and a GDPR-equivalent compliance breach. All existing Category-2 tests wrap content under a `content` key, so this path has zero coverage.

**Finding F2 / F3 — allowlist over-shadows user text (HIGH)**
Even on the read path, where events are correctly wrapped in `content`, the metadata allowlist is too broad. `m.relates_to` being allowlisted means the walker recurses into it with `in_content?=false`, leaving the reaction `key` (user-chosen text) unredacted; the dedicated `redact_relation_map/1` is dead code for the standard shape. `reason` being allowlisted means kick/ban/redaction free-text reasons survive. Both are user-generated content and violate the LAW whenever the corresponding events traverse `/sync` or `/messages` at DEBUG.

**Finding F4 — credential-set completeness (MEDIUM)**
`@credential_keys` covers login/register/refresh/account-password/UIAA. Matrix 3PID/identity flows also carry `client_secret` and `id_access_token` (an identity-server bearer token). These are not in the set. Severity is MEDIUM and reachability-dependent because Nebu is federation-less and may not expose those endpoints — confirm the router surface; if present, promote.

### Independently verified CLEAN

- **Ecto query-logger fix (cycle-2/4).** `config :nebu, Nebu.Repo, log: false` is applied at BOTH real-DB config sites (`runtime.exs:154` prod/dev, `runtime.exs:233` integration) and deliberately NOT in `config.exs` (preserving the `repo_children/0` presence check). No other `config :nebu, Nebu.Repo` site exists. `MatrixSessionStore.query/2` calls `Ecto.Adapters.SQL.query/3` with no per-call `:log` override, so it inherits `log: false`. `QueryTelemetry.handle_event/4` logs only `source`, `duration_ms`, and an `ok`/`error`/`unknown` classification — never `:query`, `:params`, or the raw exception. Telemetry event `[:nebu, :repo, :query]` matches the default prefix for `otp_app: :nebu` repo `Nebu.Repo`. No path found where Ecto's own unsanitized logger can still fire with a real DB at `:debug`.
- **Compliance/audit boundary.** Nothing in this diff writes to or reads `Nebu.Compliance` / `audit_log`. DEBUG payload logs go to the operational `Logger` (stdout) only; operational debug logs and compliance audit logs remain cleanly separate. The debug path cannot be mistaken for an audit trail.
- **Standard OWASP/STRIDE/CWE pass.** No SQL/command/path injection introduced (session-store change is comment-only). No new routes, auth, or CSRF surface. Redaction regexes (`redact_query_style/3`, `redact_json_string_style/3`) are linear and literal-substring-gated — no ReDoS. Response body decoded only for JSON content-type; binaries pass through opaque. No hardcoded secrets, no weak crypto.

### Summary

CRITICAL: 1 — block commit (F1)
HIGH: 2 — block commit (F2, F3)
MEDIUM: 1 — advisory (F4)
LOW: 0

**Verdict:** BLOCKED. The two-category mandate is NOT satisfied: credential redaction largely holds and the Ecto leak is closed, but message-content redaction is defeated on the entire Matrix write path (F1) and partially on the read path (F2/F3). Root cause is a single design assumption — that user content is always nested under a `content`/`prev_content` wrapper and that everything outside a metadata allowlist is caught. Neither holds for real Matrix payloads.
