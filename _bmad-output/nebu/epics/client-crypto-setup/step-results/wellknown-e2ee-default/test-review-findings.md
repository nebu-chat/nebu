# Pre-Dev Test Review — wellknown-e2ee-default

Test file: `server/test/nebu/web/wellknown_client_e2ee_test.exs`
RED confirmed: 2/4 failing on the missing `io.element.e2ee.force_disable` key;
2/4 (base_url + CORS baseline) already green, asserting unchanged behavior.

## AC → Test coverage

| AC | Requirement | Covered by | Status |
|----|-------------|-----------|--------|
| 1 | body has m.homeserver + io.element.e2ee.force_disable | test 1, test 3 | ✅ |
| 2 | base_url derivation (x-forwarded-proto/host) unchanged | test 3 (asserts `https://matrix.example.org`) | ✅ |
| 3 | access-control-allow-origin `*` + application/json kept | test 4 | ✅ |
| 4 | valid JSON, served unauthenticated | test 1 (Jason.decode! + 200), test 2 (no auth header, 200) | ✅ |

Every acceptance criterion has at least one test. No MAJOR gap.

## Quality checks

- Deterministic: pure `Plug.Test` against `Nebu.Web.Router` — no network, no sleep, no hard waits.
- No DB seeding, no cookie forging (endpoint is unauthenticated by design).
- Stateless endpoint → no GenServer crash/restart test required (correct per TDD standard).
- Proxy-host header set via `req_headers` directly (Plug.Test reserves the `host` header) —
  exercises the router's real `get_req_header(conn, "host")` path. Sound.
- Assertions are specific (exact base_url, `force_disable == true`, `"*"` ACAO, content-type
  contains application/json) — not loose truthiness.

## Verdict

CLEAN — 0 MAJOR. Tests are ready; proceed to dev-story.
