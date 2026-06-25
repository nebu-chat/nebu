# Test Quality Review — postgres-ssl-env-var

**Story:** `docs/stories/bugfix/postgres-ssl-env-var.md`
**Review Date:** 2026-06-25
**Reviewer:** TEA (Master Test Architect)
**Scope:** Red-phase acceptance tests only (pre-implementation)

## Test Files Reviewed

| File | Lines | Framework |
|---|---|---|
| `server/test/nebu/release_test.exs` (lines 80–133) | 54 | ExUnit unit |
| `server/test/nebu/deploy_config_test.exs` | 169 | ExUnit static analysis |

---

## Quality Score

**Score: 84 / 100 — Grade: A (Good)**

| Criterion | Status | Notes |
|---|---|---|
| AC coverage (no zero-coverage ACs) | PASS | See detail below |
| Isolation / env cleanup | PASS | `on_exit` restores env correctly |
| Determinism | PASS | No randomness, no timing |
| Hard waits | PASS | None |
| Assertions present and explicit | PASS | |
| Test IDs / priority markers | WARN | None present (minor) |
| BDD naming | WARN | Partial |
| Flakiness patterns | WARN | One env-ordering risk (see MINOR-1) |
| AC2 unit coverage depth | WARN | Indirect only (see MINOR-2) |
| AC1 runtime.exs path | WARN | Not covered by any test (see MAJOR-1) |

---

## Executive Summary

The two test files together form a solid, purpose-built red-phase suite for the
`postgres-ssl-env-var` story. The env-cleanup discipline (`on_exit`) is correct,
`async: false` is properly justified, and the static-analysis approach for the
cloud-init template is pragmatic and avoids infrastructure dependencies.

**Key strengths:**
- `on_exit` restores original env value (not always `nil`) — correctly handles
  pre-existing `NEBU_POSTGRES_SSL` in the test runner environment.
- `deploy_config_test.exs` covers both positive assertions (URLs present as
  inline values) AND negative assertions (no `?ssl=` / `.env` block residue) —
  catches both sides of the AC4 migration.
- Error message quality in `deploy_config_test.exs` is excellent: each `assert` /
  `refute` failure message explains what to do, not just what failed.
- The combined AC3+AC4 test (`no ?sslmode= anywhere`) acts as a safety net that
  will catch partial implementations.
- `setup_all` guard in `deploy_config_test.exs` uses `flunk/1` to give a clear
  message when the template file is missing, rather than a cryptic `File.read!` crash.

**Key weaknesses:**
- MAJOR: AC1 (`runtime.exs` sets `ssl: true` in Ecto repo config) has no direct
  unit test. The `postgres_ssl_opts/0` tests confirm the helper function, but
  `runtime.exs` wiring is never exercised in isolation.
- MINOR: AC2 migration-path coverage is indirect — no test exercises
  `parse_url/1` with the ssl opts actually merged in.
- MINOR: `deploy_config_test.exs` AC4 inline-value tests could false-pass if the
  URL is present but the `.env` removal is incomplete (the combined AC3+AC4 test
  partially mitigates this).

**Recommendation:** Approve with comments — MAJOR-1 should be addressed before
implementation is considered complete, but does not block the red-phase commit.

---

## Findings

### MAJOR-1 — AC1: `runtime.exs` Ecto wiring has zero direct test coverage

**Severity:** MAJOR
**Criterion:** AC Coverage
**Location:** Story AC1 vs. test files

**Issue:**
AC1 states: "`runtime.exs` liest `NEBU_POSTGRES_SSL` und setzt `ssl: true` auf
`Nebu.Repo` Config."

The acceptance tests in `release_test.exs` test `Release.postgres_ssl_opts/0`
(the helper the implementation _will_ call), but they do NOT verify that
`runtime.exs` actually passes the result into `config :nebu, Nebu.Repo`. If a
developer implements `postgres_ssl_opts/0` but forgets to wire it into
`runtime.exs`, all the new tests pass green while AC1 is still unmet.

The story's own "Acceptance Tests" section (test #1 and #2) describes this as:
`Application.get_env(:nebu, Nebu.Repo)[:ssl] == true` — but no test in the suite
makes this assertion.

**Why it matters for a red-phase test:**
The point of ATDD is that the failing tests define what "done" means. A test that
only exercises the helper function creates a false green once the helper exists,
even if the Ecto config line is never written. The story can be incorrectly
declared "done" with AC1 still open.

**Recommended fix:**
Add a test in `release_test.exs` (or a new `runtime_config_test.exs`) that reads
the compiled application config after setting the env var. In ExUnit this can be
done with `Application.put_env` + the config module at test time, or — more
robustly — by running a `mix eval` assertion in an integration test. The simplest
in-process approach:

```elixir
# In release_test.exs or a new config_test.exs
# Requires runtime.exs to run in :test env — needs NEBU_DB_URL present.
# Tag as :integration if a live DB is needed, otherwise use Application.put_env.

describe "runtime.exs wires NEBU_POSTGRES_SSL into Nebu.Repo config (AC1)" do
  setup do
    original = System.get_env("NEBU_POSTGRES_SSL")
    on_exit(fn ->
      case original do
        nil -> System.delete_env("NEBU_POSTGRES_SSL")
        val -> System.put_env("NEBU_POSTGRES_SSL", val)
      end
      Application.delete_env(:nebu, :postgres_ssl)  # if stored intermediately
    end)
    :ok
  end

  test "Application config :nebu, Nebu.Repo has ssl: true when NEBU_POSTGRES_SSL=true" do
    System.put_env("NEBU_POSTGRES_SSL", "true")
    # Re-evaluate the runtime config expression (or call the helper directly and
    # verify Nebu.Repo config after Application.put_env)
    ssl_opt = Nebu.Release.postgres_ssl_opts() |> Keyword.fetch!(:ssl)
    assert ssl_opt == true
    # Verify the Ecto config key — requires runtime.exs to use postgres_ssl_opts():
    # config :nebu, Nebu.Repo, ssl: Nebu.Release.postgres_ssl_opts()[:ssl]
    # Check after Application.put_env to simulate:
    Application.put_env(:nebu, Nebu.Repo,
      Keyword.merge(Application.get_env(:nebu, Nebu.Repo, []), ssl: ssl_opt))
    assert Application.get_env(:nebu, Nebu.Repo)[:ssl] == true
  end
end
```

Note: The exact approach depends on how `runtime.exs` is structured. If
`postgres_ssl_opts/0` is called at compile time of `runtime.exs` the test above
is the right shape. The key requirement is: a test must fail _specifically_ if
`runtime.exs` omits the `ssl:` key for `Nebu.Repo`.

---

### MINOR-1 — Env mutation order risk in `release_test.exs` when tests run close together

**Severity:** MINOR
**Location:** `server/test/nebu/release_test.exs` line 80–133

**Issue:**
`use ExUnit.Case, async: false` correctly disables async for the module, preventing
race conditions between the env-mutating tests and other modules. However, the
`setup` block captures `original = System.get_env("NEBU_POSTGRES_SSL")` at setup
time. If a previous test in the _same_ `describe` block fails to clean up before
`setup` runs for the next test (e.g. due to a test process crash), the `original`
captured may be the previous test's value rather than the true pre-test value.

This is an ExUnit edge case: `on_exit` hooks from a _crashed_ test process may
not run before the next test's `setup`. In practice the risk is low because
ExUnit isolates test processes, but it's worth a comment.

**Recommended fix:**
Either accept the current approach (it is standard ExUnit practice), or use
`setup_all` + `on_exit` at the describe level if strictly needed. Current
implementation is acceptable.

---

### MINOR-2 — AC2 migration-path coverage is indirect

**Severity:** MINOR
**Location:** `server/test/nebu/release_test.exs` lines 120–132

**Issue:**
The test at line 124 ("ssl opts are suitable for inclusion in Postgrex
start_link opts") verifies the shape of the returned keyword list but does not
confirm that `parse_url/1` (the private migration-connection builder) actually
merges `postgres_ssl_opts()` into its returned opts. The comment at line 122
acknowledges this ("A dedicated integration test in the integration suite covers
the live DB path.") which is a reasonable tradeoff for a private function.

However, the integration test referenced does not yet exist — it is described as
future work. This leaves AC2 with only a structural/shape test at unit level and
no failing test that will specifically catch a developer forgetting to add
`++ postgres_ssl_opts()` inside `parse_url/1`.

**Recommended fix (optional):**
Add a comment that explicitly names the integration test file and scenario that will
cover this, so it is tracked. Or expose `parse_url/1` as `@doc false` (like
`postgres_ssl_opts/0`) and add a unit test that verifies `parse_url/1` includes
`ssl: true` when `NEBU_POSTGRES_SSL=true`. Since `parse_url/1` currently builds
keyword options from a URL, a unit test is feasible without a DB:

```elixir
test "parse_url/1 includes ssl: true when NEBU_POSTGRES_SSL is true" do
  System.put_env("NEBU_POSTGRES_SSL", "true")
  opts = Release.parse_url("postgresql://user:pass@localhost:5432/testdb")
  assert Keyword.fetch!(opts, :ssl) == true
end
```

This requires making `parse_url/1` `@doc false` public (similar to `select_pending`
and `list_up_migrations`). Worth considering.

---

### MINOR-3 — `deploy_config_test.exs`: AC4 `.env` removal tests could false-pass

**Severity:** MINOR
**Location:** `server/test/nebu/deploy_config_test.exs` lines 95–116

**Issue:**
The AC4 tests check for the absence of `NEBU_DB_URL=postgresql` (with `=`) in
the `.env` block and for the presence of `NEBU_DB_URL:` (with `:`) in the
environment block. These are distinct patterns and the tests are correct.

However, the refute at line 104 (`~r/NEBU_DB_URL=postgresql/`) would still pass
if a developer moves the URL to `.env` with a different format (e.g.
`NEBU_DB_URL = postgresql://...` with spaces). This is a very low-probability
failure mode for a Compose env file but worth noting.

The combined AC3+AC4 test at lines 156–168 partially covers this by asserting no
`sslmode=require` anywhere. No action strictly required — just awareness.

---

### INFO-1 — No test IDs or priority markers

**Severity:** INFO
**Location:** Both test files

**Note:**
Neither file uses P0/P1 priority markers or story-scoped test IDs. These are
recommended by the BMAD TEA conventions for traceability (`/bmad-testarch-trace`).
Since this is a small bugfix story with 5 ACs and 9 tests, the absence is
acceptable. If a traceability report is generated for the bugfix epic, these tests
will show as untagged.

---

### INFO-2 — `deploy_config_test.exs` uses `setup_all` but individual tests receive content via the map

**Severity:** INFO
**Location:** `server/test/nebu/deploy_config_test.exs` lines 38–45

**Note:**
The `setup_all` block correctly reads the file once and passes it via `%{content:
content}` to each test. This is the right pattern for a static read that should
not be repeated per test. Well done.

---

## AC Coverage Matrix

| AC | Description | Test(s) Present | Coverage | Status |
|---|---|---|---|---|
| AC1 | `NEBU_POSTGRES_SSL=true` → `ssl: true` in Ecto Repo config (`runtime.exs`) | `postgres_ssl_opts/0` returns `[ssl: true]` (indirect) | Indirect only — `runtime.exs` wiring untested | **MAJOR GAP** |
| AC2 | SSL also applies to migration connection (`release.ex`) | Shape test at lines 124–131; comment says integration test TBD | Helper shape verified; `parse_url/1` merge untested | Partial |
| AC3 | Stackit Compose has `NEBU_POSTGRES_SSL: "true"` in environment block | `deploy_config_test.exs` line 50–55 | Direct static assertion | PASS |
| AC3 (no SSL params) | DB URLs in environment block contain no `?ssl=` or `?sslmode=` | `deploy_config_test.exs` lines 61–89 | Direct static assertion | PASS |
| AC4 | DB URLs not in `.env` block | `deploy_config_test.exs` lines 95–116 | Direct static assertion | PASS |
| AC4 (inline values) | Both URLs directly as inline values in environment block | `deploy_config_test.exs` lines 122–151 | Direct static assertion | PASS |
| AC5 | Regression: unset `NEBU_POSTGRES_SSL` → `ssl: false` | Lines 102–118 in `release_test.exs` | 3 cases: unset, "false", "yes" | PASS |

---

## Recommendation

**Approve with comments.**

The suite is functionally solid as a red-phase commit. All ACs have at least one
test except AC1, which is covered only indirectly. MAJOR-1 should be addressed
before the implementation is marked `done` — either by adding a direct test that
verifies the `runtime.exs` Ecto config key, or by updating the story's Acceptance
Tests section to explicitly acknowledge the indirect coverage approach and document
the follow-up integration test.

The two MINOR findings (AC2 indirection, AC4 false-pass edge case) are
non-blocking and can be addressed during implementation if the developer wishes
to strengthen coverage.
