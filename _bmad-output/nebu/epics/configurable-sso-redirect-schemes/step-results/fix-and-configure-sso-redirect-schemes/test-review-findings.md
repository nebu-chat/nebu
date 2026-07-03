# Test Review — fix-and-configure-sso-redirect-schemes (pre-dev gate)

## Initial findings (3 MAJOR)
1. `test_extra_redirect_schemes_empty_when_not_set` — false-RED, passed with zero AC6/AC7 wiring.
2. `test_redirect_url_rejected_custom_scheme_not_in_cache` — false-RED, passed trivially.
3. AC10 callback_url test — used invalid `put_req_header(conn, "host", ...)`, threw Plug.Conn.InvalidHeaderError.

## Resolution (fixed directly in test files, same ATDD/RED phase — no implementation added)
1. Rewrote as before/after toggle: assert allowed WITH seam set, then assert rejected after `clear_extra_schemes_seam()`. Cannot pass with a no-op stub.
2. Rewrote as positive-membership proof: assert "myorg-matrix" (in seam list) is allowed AND "unknown-scheme" (not in list) is rejected in the same test, proving list membership is checked, not "seam set => allow all".
3. Rebuilt conn with an explicit `http://example.com:4000/...` URL (Plug.Test derives conn.host/conn.port from it) instead of setting a "host" request header directly, and asserted against the conn.host/port-derived callback_url. Matches the real fallback path callback_url/1 exercises when no reverse-proxy sets X-Forwarded-* / Host override headers.
4. Corrected inaccurate comment on AC12.3 (falsely claimed pre-existing duplicate coverage).

## Verification (mix test run, host Elixir/mix, not the ephemeral-container path)
- sso_login_test.exs: 19/28 passed, 9 failed — all 9 failures are genuine RED (missing implementation): 5x AC12.1 bugfix scheme tests, 4x AC12.2 cache/seam tests. AC10 tests pass now (correctly — they test pre-existing/unchanged behavior, must stay green throughout).
- config_controller_test.exs: 0/11 passed — all genuine RED (404, route/handler not yet implemented).

## Verdict: CLEAN — cleared to proceed to dev-story.
