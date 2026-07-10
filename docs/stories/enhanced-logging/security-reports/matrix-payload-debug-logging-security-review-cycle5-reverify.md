## Security Review (Re-verify, cycle 5) — enhanced-logging / matrix-payload-debug-logging

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged diff (`git diff --staged`) — full fresh pass over the RequestLogger DEBUG payload-capture + two-category PayloadRedactor, Ecto query-logger sanitization (QueryTelemetry), supporting config. This is an INDEPENDENT re-review after the dev-agent fix cycle addressing the prior BLOCKED verdict; the fix description was NOT trusted — every claim was traced against the current code.
**Date:** 2026-07-05
**Prior report:** `matrix-payload-debug-logging-security-review-2026-07-05.md` (BLOCKED / CRITICAL, F1–F4)
**Verdict:** BLOCKED
**Classification:** HIGH

---

### Primary mandate result (two-category redaction)

Phil's explicit LAW: BOTH categories must be genuinely closed — (1) credentials/secrets AND (2) chat message content/user-generated text — verified against REAL Matrix payload shapes, not merely "tests exist."

- **Category 1 (credentials):** UPHELD. F4 is closed (`client_secret`/`id_access_token` in both `@credential_keys` and `@credential_string_keys`). The Ecto bound-parameter leak remains CLOSED (`log: false` at both runtime DB-config sites; `QueryTelemetry` logs only source/duration/result). No credential leak found.
- **Category 2 (message content):** STILL PARTIALLY REFUTED. F2 (`m.relates_to.key`) and F3 (`reason`) are now genuinely closed. BUT the F1 fix is **structurally incomplete for the write path**: the dev chose the field-name approach (a fixed `@always_content_keys` list) instead of treating the write-path request body as a content object. Consequently, any content field whose name is NOT in that fixed list still leaks verbatim on the write path (no `content` wrapper ⇒ `in_content? = false` ⇒ the "non-metadata ⇒ content" catch-all never fires). Real, exploitable shapes: `m.location.geo_uri` (plaintext GPS coordinates — PII), custom event content fields (e.g. `com.example.custom_event`), poll question/answer text, and `m.room.encrypted.ciphertext`.

Because a genuine user-content leak remains on the intended "safe in prod at :debug" path, the mandate does NOT hold. This blocks the commit.

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F1-R | HIGH | `payload_redactor.ex:161-188` (`redact_map/3`), `@always_content_keys:109`; wiring `request_logger.ex:90-96` (`redact_payload` always called with `in_content? = false`) | **Residual of F1.** On the Matrix write path the request body IS the content object but has no `content` wrapper, so `redact_map` runs with `in_content? = false`. Only `@credential_keys`, `m.relates_to`, and the FIXED `@always_content_keys` (`body`/`formatted_body`/`filename`/`topic`/`name`/`displayname`/`reason`) are masked. Every OTHER content field leaks: `m.location`'s `geo_uri` (plaintext location PII), custom-event fields, poll text, `m.room.encrypted`'s `ciphertext`. The read path masks these correctly (the test at `payload_redactor_test.exs:238` proves the project INTENDS `custom_field` to be redacted) — the write path is inconsistent and leaks the identical shape. | Make write-path redaction treat the top-level send/state body as a content object: route-aware `redact_payload(body, in_content?: true)` for `PUT .../send/{eventType}/{txnId}` and `PUT .../state/{eventType}/{stateKey}` (the second option from the original F1 remediation). Add write-path (unwrapped) tests for `geo_uri`, a custom-event field, and `ciphertext` asserting `***MESSAGE_CONTENT***`. |
| F1-R.a | LOW | same | `m.room.encrypted.ciphertext` specifically: leaks on the write path but is already-encrypted data (no plaintext exposure). Design intent (moduledoc) was to redact it; covered by the F1-R remediation. Flagged separately only to note its confidentiality impact is low. | Same fix as F1-R closes it. |
| A1 | LOW (advisory) | `payload_redactor.ex:98-101,286-289` | 3PID `sid` (session id) is not in the credential sets. Judgment: NOT required — `sid` is a short-lived identifier useless without the accompanying `client_secret` (which IS redacted), and the 3PID/identity flow is not implemented in Nebu's router today. `mac` (appservice/legacy) likewise not added. Acceptable as-is. | Optional: add `sid`/`mac` if/when 3PID or appservice endpoints become reachable. |

### Detail

**F1-R — write-path content leak persists for non-fixed field names (HIGH)**
Trace of a realistic `m.location` write body `PUT /rooms/{id}/send/m.room.message/{txn}` → `body_params = {"msgtype":"m.location","body":"My location","geo_uri":"geo:52.5200,13.4050","info":{...}}`:
`redacted_request_body/1` → `redact_payload(map)` → `redact_map(map, false)`.
- `body` → `always_content_key?` ⇒ `***MESSAGE_CONTENT***` ✓
- `msgtype` → `true ->` branch, unchanged (metadata) ✓
- `geo_uri` → not credential, not `m.relates_to`, not in `@always_content_keys`; `in_content?` is **false** so the `in_content? and not content_metadata_key?` branch is skipped ⇒ `true ->` branch ⇒ `redact_value/3` ⇒ `redact_string/1`, which for a bare scalar returns it unchanged ⇒ **`geo:52.5200,13.4050` LEAKS**.

Same mechanism leaks `com.example.custom_event`'s `custom_field`, poll `question`/answer text, and `m.room.encrypted.ciphertext` on the write path. Root cause: the fix relies on a fixed field-name list PLUS a "non-metadata inside content ⇒ content" catch-all, but the catch-all is gated on `in_content? = true`, which never holds for the wrapper-less write body. The original F1 remediation offered two options; option (b) — "treat the request body of send/state endpoints as a content object" — was the structural fix and was not taken. Under the epic's stated operating condition (":debug safe to enable anywhere, including prod"), plaintext user location and custom/poll content reach the DEBUG log — a direct violation of the no-sensitive-data-in-logs LAW and a GDPR-relevant PII exposure. No write-path test covers any non-fixed content field (`geo_uri` count in the suite: 0), so this path is unverified.

**F2 — CLOSED (verified).** `relates_to_key?/1` is evaluated at ANY depth BEFORE the `in_content?` branch. For a reaction `content = {"m.relates_to":{"rel_type":"m.annotation","event_id":"$x","key":"👍"}}`, `redact_relation_map/1` masks `key` → `***MESSAGE_CONTENT***` while `rel_type`/`event_id` pass through `redact_value(_, false)` untouched. Works both wrapped (read path) and top-level (`PUT /send/m.reaction/{txn}` write path). Nested credentials/content under `m.relates_to` still caught (non-`key` children recurse via `redact_value(v, false)` ⇒ `redact_map(_, false)`).

**F3 — CLOSED (verified).** `reason` moved to `@always_content_keys`, so it is masked at any depth: read-path `m.room.member` (`{"membership":"ban","reason":"spam"}` ⇒ `membership` survives as metadata, `reason` masked) and write-path (`POST /rooms/{id}/ban`, `PUT /redact/...` ⇒ `reason` masked).

**F4 — CLOSED (verified).** `client_secret` and `id_access_token` present in BOTH `@credential_keys` (structured, any depth) and `@credential_string_keys` (query-string/form + malformed-JSON string redaction). `sid` intentionally omitted (see A1) — acceptable.

**Precedence / new-gap analysis (mandate point 5).** Order is credential → `m.relates_to` → `@always_content_keys` → (`in_content?` and not metadata) → generic. No key appears in two of the fixed lists, so no branch-shadowing bypass exists. Credential check is first ⇒ no content-branch can shadow a secret. Over-redaction of exact-match `name`/`filename` outside content is possible (e.g. a device `name`) but is a false-positive, not a security bug, and is not absurd. The `m.relates_to` special-case does not introduce a bypass (non-`key` children still fully walked for credentials/content). No new vulnerability introduced by the fix itself.

### Independently verified CLEAN (full fresh pass)

- **F2, F3, F4** — closed as detailed above.
- **Ecto query-logger.** `config :nebu, Nebu.Repo, ... log: false` present at BOTH runtime DB-config sites (`runtime.exs:154` prod/dev, `runtime.exs:233` integration) and deliberately absent from `config.exs` (preserving the `repo_children/0` presence check). `MatrixSessionStore` uses no per-call `:log` override ⇒ inherits `log: false`. `QueryTelemetry.handle_event/4` logs only `source`, `duration_ms`, and an `ok`/`error`/`unknown` classification — never `:query`, `:params`, or the raw exception. No path for Ecto's unsanitized logger to fire with a real DB at `:debug`.
- **Standard OWASP/STRIDE/CWE pass.** No SQL/command/path injection (session-store change is comment-only; QueryTelemetry reads telemetry metadata, no user input). No new routes/auth/CSRF surface. String redaction (`redact_query_style`/`redact_json_string_style`) is literal-substring-gated (`String.contains?/2`) before any `Regex.replace` ⇒ no ReDoS on raw media blobs. Binaries pass through opaque; response body decoded only for JSON content-type. No hardcoded secrets, no weak crypto. Debug logs go to operational `Logger` (stdout) only — cleanly separate from `Nebu.Compliance`/`audit_log`.

### Summary

CRITICAL: 0
HIGH: 1 — block commit (F1-R: write-path content leak for non-fixed content field names — `geo_uri`/custom/poll/ciphertext)
MEDIUM: 0
LOW: 2 — advisory (F1-R.a ciphertext; A1 `sid`/`mac`)

**Verdict:** BLOCKED. The credential category and the Ecto leak are fully closed, and F2/F3/F4 are genuinely fixed. But the F1 fix is structurally incomplete: by choosing a fixed field-name list instead of treating the write-path body as a content object, it closes the common plain-text-message case while leaving every other content field (`geo_uri` plaintext location PII, custom-event text, poll text, `ciphertext`) leaking on the Matrix write path — the exact class of bug F1 was raised for. The correct fix is route-aware `in_content? = true` redaction for send/state request bodies, plus write-path tests for the unwrapped custom/`geo_uri` shapes.
