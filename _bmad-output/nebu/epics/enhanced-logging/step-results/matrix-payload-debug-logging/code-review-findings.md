# Code Review — matrix-payload-debug-logging (cycle 0)

## MAJOR

**M1 — Missing `new_password` credential field.** `payload_redactor.ex:58` `@credential_keys` list
doesn't include `new_password` (used by `POST /_matrix/client/v3/account/password`). Oracle
explicitly MUST-listed it. Zero test coverage. Real plaintext-password leak risk at DEBUG.

**M2 — Deprecated `?access_token=` query-param redaction is dead code.** `redact_string/1` regex
exists and is unit-tested in isolation, but `RequestLogger` never logs `conn.query_string` at all —
only `request_path` (no query) and `body_params`. The Oracle MUST ("query-param access_token= must
be redacted") is unit-tested but not wired into the real request path — false confidence.

**M3 — Zero automated test coverage for `Nebu.Repo.QueryTelemetry`.** The module built in cycle 2 to
fix the Ecto SQL-param-leak regression is disabled in test.exs and has no dedicated test file. No
test proves its core guarantee ("never touch :query or :params from telemetry metadata").

## MINOR
- m1: Authorization-header redaction logic duplicated (PayloadRedactor's dead branch vs.
  RequestLogger's actually-used `redact_auth_header/1`) — violates AC10 centralization intent.
- m2: `unsigned.prev_content` (state-event previous content) not covered by content detection.
- m3: `QueryTelemetry` doesn't distinguish query success/failure in its sanitized log line.
- m4: `Jason.decode/1` unconditionally attempted on binary media response bodies — wasted work
  during a live debug session, not a correctness bug (lazy-evaluated, no prod cost by default).
- m5: pre-dev test-review MINOR-1/MINOR-2 (weak malformed-JSON/form-encoded assertions) still
  unaddressed across 3 fix cycles.

## INFO
AC9 scope discipline clean. ADR-018/020/021 respected. Credential/UIAA scoping correctly traced by
hand. No event-type allowlist for content redaction (AC7) — confirmed structurally correct.
Idempotency correct. Lazy `Logger.debug(fn -> end)` used correctly everywhere (no prod perf cost).
`Nebu.Repo` `log: false` is architecturally sound — doesn't suppress error propagation, only the
auto-log call; `QueryTelemetry` attaches idempotently and safely.

## Recommendation
M1–M3 → user decision (first formal review cycle, no 3-cycle escalation yet; M1 is a genuine
unredacted-credential-leak risk). m1–m5 → normal MINOR dev-fix cycle.
