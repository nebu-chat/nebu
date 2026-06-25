# Code Review Findings — Story `account-data-get`

**Epic:** element-compat
**Reviewer:** Nebu Code Review (adversarial: Blind Hunter + Edge Case Hunter + Acceptance Auditor)
**Date:** 2026-06-25
**Outcome:** PASS — APPROVED (no MAJOR/CRITICAL). One MINOR + two notes recorded.

## Scope reviewed

- `server/lib/nebu/matrix/account_data_store.ex` (new)
- `server/lib/nebu/application.ex` (init_table wiring)
- `server/lib/nebu/web/router/protected.ex` (PUT replaced, GET added)
- `server/test/nebu/matrix/matrix_client_compat_test.exs` (auth-gate + behavioural tests)

## Acceptance Criteria → Test Traceability

| AC | Requirement | Code | Test | Status |
|----|-------------|------|------|--------|
| 1 | PUT stores body in ETS `{user_id,type}` → `200 {}` | protected.ex 270–282; store `put/3` | round-trip test (445) + regression test (560) | COVERED |
| 2 | GET reads ETS → `200 <stored body>` | protected.ex 284–297; store `get/2` | round-trip asserts `json(get_conn) == stored_body` (445) | COVERED |
| 3 | GET miss → `404 M_NOT_FOUND "Account data not found"` | protected.ex 298–299 | unseen-type test (427), asserts errcode + error string | COVERED |
| 4 | OidcPlug auth → `401 M_MISSING_TOKEN` w/o Bearer | OidcPlug in Protected pipeline | PUT (217) + GET (224) no-Bearer → 401 | COVERED |
| 5 | IDOR guard → `403 M_FORBIDDEN` for another user's data | PUT guard (275), GET guard (289) | GET IDOR test (473): Bob reads Alice → 403; Alice → 200 | COVERED (GET); PUT path untested — see MINOR-1 |
| 6 | No regressions (900 passed) | n/a | dev record: 900 passed / 0 failed / 2 skipped | COVERED (claimed; see Note-2) |

**Acceptance Auditor verdict:** Every AC has at least one test. No MAJOR finding.

## Findings

### MINOR-1 — PUT IDOR guard has no direct test
`protected.ex` guards BOTH PUT (line 275) and GET (line 289) against a path-user ≠ token-user mismatch, returning `403 M_FORBIDDEN`. The behavioural suite tests the **GET** IDOR path (test "GET another user's account_data → 403 M_FORBIDDEN", line 473) but never exercises the **PUT** IDOR path (Bob PUT-ing to Alice's key). The guard is symmetric and correct, so this is not an AC gap (AC5 says "read/write" and the read path is proven), but the write-side guard is load-bearing security code with zero coverage. A regression that silently dropped the PUT guard would not be caught.

**Disposition:** MINOR. Recommend adding one assertion: Bob `PUT`s to Alice's `account_data` path → `403 M_FORBIDDEN`, and confirm Alice's stored value is unchanged. Non-blocking.

### Note-1 — Double-encoding correctly avoided (Oracle requirement met)
The Oracle context required GET to return the stored JSON directly rather than re-encode via `send_json`. The handler does this correctly (protected.ex 293–296): `put_resp_content_type("application/json") |> send_resp(200, json_body)` emits the pre-encoded ETS string verbatim. PUT stores `Jason.encode!(body_params(conn))` once. Round-trip test asserting `json(get_conn) == stored_body` (which decodes the wire bytes) passing confirms exactly one encode/one decode — no string-literal escaping. Correct.

### Note-2 — ADR-020 cross-domain placement (acknowledged in story, accepted)
`Nebu.Web.Router.Protected` (`Nebu.Web.*`) calls `Nebu.Matrix.AccountDataStore` directly. Strictly, ADR-020's public-API rule routes cross-domain calls through `Nebu.Matrix` only. The store is a leaf ETS accessor with no behaviour, identical in disposition to `Nebu.Matrix.Http` which `Nebu.Web` already imports, and the story Dev Notes (§ADR Alignment) explicitly call this out and accept it as a shared data-access helper. Accepted — consistent with existing precedent; no change required.

## Edge Case Hunter notes (all benign)

- **ETS race / idempotency:** `ensure_table/0` (account_data_store.ex 59–72) handles the create race via `:ets.whereis` + `rescue ArgumentError`; `init_table/0` is wired into `Nebu.Application.start/2` (line 33) **before** Bandit (line 83), matching the R-2 eager-init pattern. No first-request race. Correct.
- **Test isolation:** all behavioural tests key on `m.test.account.data.#{:erlang.unique_integer([:positive])}`, so the process-persistent `:NebuAccountData` table cannot leak state across tests. Correct.
- **URL decoding:** both `user_id` and `type` are `URI.decode_www_form`'d before the IDOR comparison and the ETS key, so the encoded `@alice%3A...` form Element sends compares equal to the decoded `current_user`. Correct.
- **IDOR comparison ordering:** the guard runs against the **decoded** path user vs the token's `current_user`, before any ETS access — a non-owner is rejected without the store ever being touched (no information leak on whether a key exists). Correct.
- **`type` collision safety:** unique-integer suffixing in tests avoids the documented cross-test contamination risk.

## Blind Hunter notes

- No SQL, no `:crypto`, no external input beyond path/body already mediated by OidcPlug + Plug.Parsers; `security_review: not-needed` in frontmatter is appropriate (no auth/router/migration/crypto surface beyond the IDOR guard, which is reviewed above).
- `put/3`/`get/2` guard clauses (`is_binary/1`) match how the router calls them (decoded strings). No type-confusion path.

## Recommendation

**APPROVE — mark story `done`.** No MAJOR or CRITICAL findings; every AC is test-covered. MINOR-1 (missing PUT-IDOR test) is a nice-to-have hardening of an already-correct, symmetric guard and may be fixed instantly or deferred to the epic test-rehab workstream.
