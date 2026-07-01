# Code Review — wellknown-e2ee-default (cycle 0)

VERDICT: CLEAN (0 CRITICAL, 0 MAJOR, 0 MINOR, 2 INFO)

## Summary

Implementation adds exactly one static key `"io.element.e2ee" => %{"force_disable" => true}`
to the existing `Jason.encode!` map in `get "/.well-known/matrix/client"`
(`server/lib/nebu/web/router.ex`). scheme/host derivation, CORS `*`, and
`application/json` content type are untouched. Endpoint stays unauthenticated. No
mode-toggle config / scope creep.

## AC coverage

- AC1 (new key) + AC4 (valid JSON, 200): test 1
- AC4 (unauthenticated): test 2
- AC2 (base_url derivation incl. x-forwarded-proto/host): test 3 → `https://matrix.example.org`
- AC3 (CORS + content-type): test 4

All 4 ACs covered. Tests deterministic, Plug.Test direct, no DB seeding / cookie forging.

## INFO

- Comment block accurate and scoped (cites ADR-011, flags Element-proprietary/non-spec).
- Test 4 content-type uses `=~ "application/json"` (tolerates charset suffix). Correct.

No security concerns: static boolean, no secrets exposed, no user input into the new key,
correctly unauthenticated as `.well-known` requires.
