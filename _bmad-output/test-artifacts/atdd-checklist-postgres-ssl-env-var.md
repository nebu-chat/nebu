---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
lastStep: step-04-generate-tests
lastSaved: '2026-06-25'
storyId: postgres-ssl-env-var
storyKey: postgres-ssl-env-var
storyFile: null
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-postgres-ssl-env-var.md
generatedTestFiles:
  - server/test/nebu/release_test.exs
  - server/test/nebu/deploy_config_test.exs
inputDocuments:
  - server/config/runtime.exs
  - server/lib/nebu/release.ex
  - server/test/nebu/release_test.exs
  - deploy/tofu/examples/stackit/cloud-init.tftpl
  - _bmad/tea/config.yaml
tddPhase: RED
---

# ATDD Checklist — postgres-ssl-env-var

## Step 1: Preflight & Context

- **Stack:** fullstack (Elixir/OTP backend + Playwright E2E)
- **Story type:** Infrastructure/config — no browser-visible behavior
- **Test types selected:** ExUnit unit tests (backend only); no Gherkin/E2E needed
- **Story key:** `postgres-ssl-env-var`

### Acceptance Criteria Identified

| AC | Description | Test Level |
|----|-------------|------------|
| AC1 | `NEBU_POSTGRES_SSL=true` sets `ssl: true` in Ecto Repo config | Unit (ExUnit) |
| AC2 | SSL also applied to migration Postgrex connection | Unit (ExUnit) |
| AC3 | Stackit Compose has `NEBU_POSTGRES_SSL: "true"` in environment block, no SSL in DB URLs | Static analysis (ExUnit file read) |
| AC4 | Both DB URLs in environment block directly, not in .env block | Static analysis (ExUnit file read) |
| AC5 | Regression: no `NEBU_POSTGRES_SSL` → `ssl: false` (default) | Unit (ExUnit) |

---

## Step 2: Generation Mode

**Mode selected:** Sequential / AI generation (pure backend story, no UI)

---

## Step 3: Test Strategy

### Priority Map

| Test | AC | Priority | Level |
|------|----|----------|-------|
| `postgres_ssl_opts/0` returns `[ssl: true]` when env is "true" | AC1 | P0 | Unit |
| `postgres_ssl_opts/0` returns `[ssl: false]` when env is not set | AC5 | P0 | Unit |
| `postgres_ssl_opts/0` returns `[ssl: false]` when env is "false" | AC5 | P1 | Unit |
| `postgres_ssl_opts/0` returns `[ssl: false]` for garbage values | AC5 | P1 | Unit |
| `postgres_ssl_opts/0` returns a valid Postgrex keyword list | AC2 | P1 | Unit |
| `cloud-init.tftpl` has `NEBU_POSTGRES_SSL: "true"` | AC3 | P0 | Static |
| DB URLs in environment block have no `?ssl=` or `?sslmode=` | AC3 | P0 | Static |
| `NEBU_DB_URL=` not in .env content block | AC4 | P0 | Static |
| `NEBU_DB_URL_MIGRATE=` not in .env content block | AC4 | P0 | Static |
| `NEBU_DB_URL` as inline value in environment block | AC4 | P1 | Static |
| `NEBU_DB_URL_MIGRATE` as inline value in environment block | AC4 | P1 | Static |

---

## Step 4: Generated Test Files (RED Phase)

### File 1: `server/test/nebu/release_test.exs` (updated)

Added describe block: `"postgres_ssl_opts/0 — NEBU_POSTGRES_SSL controls ssl: option (AC1 + AC2)"`

**5 failing tests** — all fail with `UndefinedFunctionError` because `Nebu.Release.postgres_ssl_opts/0` does not exist yet.

### File 2: `server/test/nebu/deploy_config_test.exs` (new)

**6 failing tests** — all fail because `cloud-init.tftpl` still contains SSL query params in DB URLs, `NEBU_POSTGRES_SSL` is absent, and DB URLs are still in the `.env` block.

---

## TDD RED Phase Verification

- **854 tests passing** (no regressions from new test files)
- **11 tests failing** — exactly the 11 new tests
- **2 pre-existing skipped** (unchanged)

All 11 failing tests fail for the **correct reason** (the feature is not implemented):
- `release_test.exs` → `UndefinedFunctionError: Nebu.Release.postgres_ssl_opts/0 is undefined or private`
- `deploy_config_test.exs` → assertion failures because the template still has SSL in URLs and missing `NEBU_POSTGRES_SSL`

---

## Implementation Contract for Dev

To make these tests GREEN, implement:

1. **`Nebu.Release.postgres_ssl_opts/0`** in `server/lib/nebu/release.ex`:
   ```elixir
   @doc false
   @spec postgres_ssl_opts() :: keyword()
   def postgres_ssl_opts do
     [ssl: System.get_env("NEBU_POSTGRES_SSL", "false") == "true"]
   end
   ```

2. **Use `postgres_ssl_opts/0` in `parse_url/1`** (for migrations) and in **`runtime.exs`** (for Repo config).

3. **Update `deploy/tofu/examples/stackit/cloud-init.tftpl`**:
   - Add `NEBU_POSTGRES_SSL: "true"` to the server service `environment:` block
   - Remove `?ssl=true` / `?sslmode=require` from all DB URL values
   - Move `NEBU_DB_URL` and `NEBU_DB_URL_MIGRATE` from the `.env` content block to inline values in the `environment:` block
