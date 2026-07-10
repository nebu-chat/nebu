# Test Review — matrix-payload-debug-logging (pre-dev)

Verified RED phase by running the suite: 34 failures (expected — `PayloadRedactor` module doesn't
exist yet), 1 legitimate pass (default-disabled regression guard). No MAJOR findings — all AC1–AC10
plus every Oracle-flagged edge case have explicit failing test coverage.

## MINOR-1 — malformed JSON string test doesn't assert the secret is absent
`payload_redactor_test.exs:409-417`: only asserts `refute is_map(result)`. Doesn't check the literal
secret substring (`"leaked secret"`) is absent from the result. Strengthen to
`refute String.contains?(result, "leaked secret")` so an implementation that passes the string
through unchanged would actually fail this test.

## MINOR-2 — form-encoded body string test only asserts `is_binary(result)`
`payload_redactor_test.exs:399-407`: doesn't assert the embedded `refresh_token=...` value is
absent/redacted. An implementation that does nothing to raw non-JSON bodies would still pass.
Either strengthen the assertion, or add a comment making explicit that raw non-JSON body redaction
is intentionally out of scope for this story (if that's the actual design decision).

## INFO (no action required)
- Loose timing/ID assertions (`is_integer`), no hard waits — correct.
- `extract_json_log_line/1` regex is greedy across multiple JSON log lines in one `capture_log`
  block — latent brittleness, not currently exercised by any test, flag for awareness only.
- No GenServer/process state introduced — crash/restart test correctly not required.
- Not a UI story — Playwright/e2e check correctly N/A.
- Matrix error-code assertions correctly out of scope (this story doesn't change response behavior).
