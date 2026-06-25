---
story: account-data-get
epic: element-compat
reviewer: bmad-testarch-test-review
date: 2026-06-25
scope: 6 new tests in server/test/nebu/matrix/matrix_client_compat_test.exs
---

# Test Review — account-data-get (element-compat)

## Scope

Reviewing 6 new ExUnit tests added to
`server/test/nebu/matrix/matrix_client_compat_test.exs`:

- 1 test added to the existing `describe "auth gate on the client-compat endpoints — no DB"` block (line 224)
- 5 tests in the new `describe "account_data ETS store — no DB"` block (lines 418–560)

Tests are pure Plug.Test / ExUnit (no DB, no `@moduletag :integration`), consistent
with the story's requirements.

## Acceptance Criteria Coverage Map

| AC | Description | Test(s) | Verdict |
|----|-------------|---------|---------|
| AC1 | PUT stores body in ETS → 200 {} | round-trip test (PUT assertions lines 456–458); regression test (lines 548–559) | Covered |
| AC2 | GET reads from ETS → 200 <body> when found | round-trip test (GET assertions lines 461–469) | Covered |
| AC3 | GET → 404 M_NOT_FOUND "Account data not found" when not found | `GET account_data for unseen type` (lines 427–442) | Covered |
| AC4 | Auth: no Bearer → 401 M_MISSING_TOKEN | auth gate test (lines 224–228) | Covered (partial — see MAJOR-1) |
| AC5 | Data survives PUT-then-GET within session | `second PUT overwrites first` (lines 507–545) | Covered |
| AC6 | No regressions | `PUT account_data → 200 {} regression` (lines 548–559) | Covered |

---

## Quality Evaluation

### Determinism

The tests do not use hard waits (`waitForTimeout`, `Process.sleep`), conditionals
controlling test flow, or try/catch for flow control. All responses are synchronous
HTTP via `Plug.Test`. The tests are deterministic by construction.

Score: HIGH

### Isolation

**MAJOR finding (ETS key collision risk — see MAJOR-1 below).**

Beyond that finding, the `setup` block correctly mints two independent tokens with
`bearer_for("alice", priv)` / `bearer_for("bob", priv)`. The module-level
`async: false` prevents parallel test-file execution so the shared ETS table
`:NebuAccountData` cannot be written concurrently by two processes, but type-name
collisions within a sequential run (one test's PUT leaving data that a different
test's GET reads) remain possible.

Score: MEDIUM (due to MAJOR-1)

### Maintainability

Tests follow the existing file conventions exactly (same helpers, same style). Each
test is focused and well under 300 lines individually. Assertions are kept in test
bodies (not hidden in helpers). Naming is clear and maps one-to-one to ACs.

Score: HIGH

### Performance

All tests are pure in-process Plug.Test calls with no DB or network I/O. Execution
will be sub-millisecond per test. Well within the 1.5-minute quality bar.

Score: HIGH

---

## Findings

### MAJOR-1 — ETS key collision: type names are NOT unique across tests

**Severity: MAJOR**
**Dimension: Isolation**
**Tests affected: AC3 (miss), AC1+AC2 (round-trip), AC5 (overwrite)**

**Problem:**

The story's Dev Notes explicitly warn:

> *"Tests must use unique keys to avoid cross-test contamination. Use the test name
> or a unique suffix in the type string (e.g., `"m.test.account_data_get_miss_#{:erlang.unique_integer()}"`)."*

The implemented tests use **hardcoded, non-unique type strings**:

- AC3 (miss test): `type = "m.secret_storage.default_key"` (line 429)
- AC2 round-trip:  `type = "m.secret_storage.default_key"` (line 447)
- AC5 overwrite:   `type = "m.breadcrumbs"` (line 509)
- AC6 regression:  `type = "m.breadcrumbs"` (line 549)

The ETS table `:NebuAccountData` persists across all tests within a test run (it is
a named global table created once at Application start or on first access). ExUnit
runs with `async: false` at the module level, so tests run **sequentially within this
file**, but the ETS table is NOT cleared between tests.

**Concrete failure scenario:**

If test ordering is such that the round-trip test (AC2) runs *before* the miss test
(AC3), the ETS table will already contain the key `{"@alice:test.local",
"m.secret_storage.default_key"}` with the value stored by the round-trip PUT. The
miss test then calls GET for the exact same key and receives 200 with stored data
instead of 404 M_NOT_FOUND, causing a **false positive (test passes when it
should fail)** — or, after the implementation change, a **false failure masking the
404 branch entirely**.

Similarly, AC5 overwrites `m.breadcrumbs` data, and AC6 then reads it back — but
AC6 only asserts the PUT status code, so this particular ordering is benign. Still,
the collision between AC5 and AC6 is accidental rather than intentional.

**Additionally**, the IDOR test (AC4, lines 473–504) uses `type = "m.cross_signing.master"`,
which is unique enough in practice, but still hardcoded. The test does not call
`:erlang.unique_integer()` or any uniqueness mechanism.

**Required fix:**

Use `:erlang.unique_integer([:positive])` in the type string for every behavioural
test in the ETS describe block:

```elixir
# AC3 miss
type = "m.test.miss.#{:erlang.unique_integer([:positive])}"

# AC2 round-trip
type = "m.test.roundtrip.#{:erlang.unique_integer([:positive])}"

# AC4 IDOR
type = "m.test.idor.#{:erlang.unique_integer([:positive])}"

# AC5 overwrite
type = "m.test.overwrite.#{:erlang.unique_integer([:positive])}"
```

The AC6 regression test intentionally mirrors the existing test that uses
`m.breadcrumbs` and only asserts PUT status — no GET follows, so a collision there
does not create a false positive. However, for consistency, it should also use a
unique type name.

---

### MINOR-1 — AC4 (IDOR) test: `_uid_bob` is bound but immediately discarded

**Severity: MINOR**
**Dimension: Maintainability**
**Tests affected: AC4 (IDOR test, lines 473–504)**

**Problem:**

The IDOR test setup pattern binds `uid_bob` as `_uid_bob` (line 474, note the
leading underscore), meaning the Bob user ID extracted from the setup map is silently
discarded. The test then constructs the GET path using `uid_alice`'s URL only (Bob's
GET request uses Alice's user ID in the path — intentionally, to test cross-user
read). The underscore suppresses an unused-variable warning.

This is technically correct — the test intends for Bob to attempt to read *Alice's*
path with Bob's Bearer — and the binding suppression is the right call since `uid_bob`
is genuinely not needed in the path. However, the test comment says "Bob attempts to
read Alice's account_data" but does not make this structure obvious at a glance. A
reader must mentally verify that the GET path (`uid_alice`) diverges from the auth
header (`token_bob`).

**Recommended improvement (not a blocker):**

Add a brief inline comment before the GET call making the cross-user nature explicit:

```elixir
# Bob (token_bob) attempts to read Alice's account_data path → 403
get_conn =
  call(
    :get,
    "/_matrix/client/v3/user/#{URI.encode_www_form(uid_alice)}/account_data/#{type}",
    nil,
    auth(token_bob)   # Bob's token, Alice's user ID in path
  )
```

---

### MINOR-2 — AC4 (IDOR) test: does NOT verify that Alice's own data is readable after the PUT

**Severity: MINOR**
**Dimension: Coverage**
**Tests affected: AC4 (IDOR test)**

**Problem:**

The IDOR test verifies only that Bob cannot read Alice's data (403 M_FORBIDDEN). It
does not verify that Alice herself **can** read the same data back after the PUT. This
gap means the test would still pass even if the GET handler rejected *all* requests
(including the owner's), as long as it returned 403 to Bob.

The round-trip test (AC2) provides partial coverage for the owner-readable path, but
it uses `m.secret_storage.default_key` while the IDOR test uses `m.cross_signing.master`.
These are tested in isolation, so the combination path (PUT as Alice, GET as Bob, GET
as Alice) is not exercised as a single scenario.

**Recommended improvement:**

Add a final assertion in the IDOR test: after the Bob-403 check, verify Alice can
read her own data:

```elixir
# Alice can still read her own data
own_conn =
  call(
    :get,
    "/_matrix/client/v3/user/#{URI.encode_www_form(uid_alice)}/account_data/#{type}",
    nil,
    auth(token_alice)
  )

assert own_conn.status == 200
assert json(own_conn) == alice_body
```

---

### INFO-1 — async: false is module-level but not documented as intentional

**Severity: INFO**
**Dimension: Maintainability**

The module declares `use ExUnit.Case, async: false` (line 35). This is necessary
because the tests share the global ETS table `:NebuAccountData`. However, there is
no comment explaining *why* `async: false` is required. A future developer might
change it to `async: true` (for speed) without realising it would cause ETS
collision failures.

**Recommended improvement:**

Add a brief comment at the `async: false` declaration:

```elixir
# async: false — tests share the global ETS table :NebuAccountData; parallel
# execution would cause cross-test key collisions.
use ExUnit.Case, async: false
```

---

### INFO-2 — AC3 (miss test) uses the same type as the round-trip test (see MAJOR-1)

**Severity: INFO (subsumed by MAJOR-1)**

Noted for completeness: the miss test (`m.secret_storage.default_key`, line 429)
and the round-trip test (`m.secret_storage.default_key`, line 447) use identical ETS
keys. This is the primary instance of the MAJOR-1 collision risk. Fixing MAJOR-1
resolves this finding entirely.

---

## Summary

| ID | Severity | AC | Description |
|----|----------|----|-------------|
| MAJOR-1 | MAJOR | AC1–AC3, AC5–AC6 | Hardcoded ETS type names — cross-test collision risk; miss test can become false positive |
| MINOR-1 | MINOR | AC4 | `_uid_bob` discard is correct but comment clarity could be improved |
| MINOR-2 | MINOR | AC4 | IDOR test does not verify owner (Alice) can still read her own data |
| INFO-1  | INFO  | all | `async: false` has no explanatory comment |
| INFO-2  | INFO  | AC3, AC2 | Specific collision instance (subsumed by MAJOR-1) |

**Gate decision:** MAJOR-1 must be resolved before the story can be marked `done`.
The tests are otherwise structurally sound, well-focused, and correctly model the
acceptance criteria. MINOR and INFO findings are improvements but do not block.

## AC Coverage Gate

Per CLAUDE.md Gate 3: every Acceptance Criterion must have at least one test.

| AC | Covered | Note |
|----|---------|------|
| AC1 — PUT → 200 {} | YES | round-trip PUT assertions + regression test |
| AC2 — GET returns stored body | YES | round-trip GET assertions |
| AC3 — GET → 404 M_NOT_FOUND | YES | miss test — **at risk due to MAJOR-1** |
| AC4 — 401 M_MISSING_TOKEN (auth gate) | YES | auth gate test |
| AC4 — 403 M_FORBIDDEN (IDOR) | YES | IDOR test |
| AC5 — data survives multiple round trips | YES | overwrite test |
| AC6 — no regressions | YES | regression test |

All ACs covered. Coverage gate passes. MAJOR-1 is a reliability/isolation defect,
not a coverage gap.
