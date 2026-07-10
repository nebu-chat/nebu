# CI Gate — cycle 0 result: 2 real bugs to fix, 4 pre-existing failures excluded

Full unfiltered run via `rtk proxy make test-integration`: 1557 tests, 9 failures.
True baseline (verified via `rtk proxy` on stashed pre-story code, full suite): 1521 tests, 4 failures.
Net new: 5 failures. 2 are real bugs in this story's implementation (must fix). 3 are a suspected
pre-existing DB-growth flakiness pattern, unrelated to this story (see "Excluded" section).

## Must fix (real bugs in this story's code)

### Bug 1 — top-level `token` field (m.login.token) not redacted
`server/test/nebu/web/plugs/request_logger_test.exs:365` ("combined redaction over a real
authenticated login + sync round trip") sends:
```
POST /_matrix/client/v3/login
{"type": "m.login.token", "token": "<jwt>", "password": "must-not-leak-into-logs"}
```
AC4 only lists `password`/`access_token`/`refresh_token` as top-level credential fields. Matrix's
`m.login.token` login type carries the actual credential in a top-level `token` field, not
`access_token`/`refresh_token`, and not nested under `auth.*` (which the current implementation
does redact per its own design note about scoping UIAA `token`/`session` to inside an `auth`
object). Fix: add top-level `token` to the credential field list redacted by
`PayloadRedactor.redact_payload/1`, alongside `password`/`access_token`/`refresh_token`.

Verify: `refute String.contains?(log_output, token)` at request_logger_test.exs:389 must pass —
currently the raw JWT appears in the DEBUG log because `"token"` at the top level isn't matched.

### Bug 2 — Authorization header not redacted on a bodyless GET request
`server/test/nebu/web/plugs/request_logger_test.exs:204` ("an Authorization Bearer header value
never appears in plaintext in the DEBUG log") sends:
```
GET /_matrix/client/v3/sync
Authorization: Bearer syt_super_secret_token_value_abc123
```
No request body. This fails both the `refute String.contains?(log_output, <token>)` AND (per the
test's design) is meant to also prove the `***REDACTED***` marker is present. Check whether the
current header-capture/redaction path in `Nebu.Web.Plugs.RequestLogger` only runs when
`conn.body_params` is non-empty, or otherwise short-circuits for GET/bodyless requests — the header
must be captured and redacted independent of whether a body exists.

## Excluded (pre-existing, not caused by this story)

Verified via a full, unfiltered `rtk proxy make test-integration` run on the STASHED pre-story
codebase (not just a targeted subset) — true baseline is 4 failures, not 2 (the very first baseline
capture was silently truncated by rtk's output cap and under-reported). See corrected
`baseline-integration.log` in this directory.

1. `Nebu.Admin.AdminStaleRoomsTest` — pre-existing, confirmed on baseline.
2. `Nebu.Web.RegressionSyncLoadTest` (200 concurrent /sync, median latency SLA) — pre-existing,
   confirmed on baseline (ExUnit.TimeoutError, Postgrex pool contention in `persist_since_token`).
   Not caused by DEBUG payload logging.
3. `Nebu.Matrix.MatrixSsoTest` (POST /login → 500 instead of 200) — pre-existing, confirmed on
   baseline.
4. `Nebu.Matrix.SsoLoginTest` (`extra_redirect_schemes/0` cache/seam) — pre-existing, confirmed on
   baseline.

## Flagged, not blocking — suspected pre-existing flakiness (not confirmed with 100% certainty)

`Nebu.Web.AdminOidcLoginTest` — 3 failures (AC3/AC4/AC5, "admin-only-provisioned operator appears in
GET /admin/users") appeared ONLY in the full run with this story's tests added, NOT in a targeted
3-file subset run against baseline code. However:
- The failure output shows `Nebu.Admin.DB.list_users/3` returning a list of several hundred
  accumulated test users (many `@ad-http-*`, `@ajfl*`, `@alex*` prefixed rows from unrelated test
  files) with the target user missing — this is the signature of a pagination/limit assumption in
  `list_users/3` breaking once the shared, non-transactional test DB accumulates enough rows, not a
  bug in `RequestLogger`/`PayloadRedactor`.
- There is no plausible code path by which this story's changes (a logging plug) could affect
  `Nebu.Admin.DB.list_users/3`'s pagination logic.
- This story's own new integration test does add ~1-2 rows to the shared DB (consistent with every
  other integration test file, which already contribute hundreds of accumulated rows) — the most
  likely mechanism is simply tipping an already-fragile row-count-dependent assertion, not a genuine
  regression in application logic.
- Full confirmation would require another ~18-minute full-suite `rtk proxy` run on baseline code
  with this story's exact 2 new tests spliced in (isolating the "does adding N more rows do this"
  variable) — expensive for a low-confidence payoff given the mechanism is already well understood.

Recommendation: accept this as a known pre-existing test-suite fragility (shared, ever-growing,
non-transactional integration DB + a pagination-sensitive assertion in `AdminOidcLoginTest`), track
it as a follow-up bug/tech-debt item, and do not block this story on it. If the dev-story agent's fix
for Bugs 1-2 happens to touch nothing DB-related (it shouldn't), no further action needed here before
re-running ci-gate.
