# Code Review Findings — postgres-ssl-env-var

**Story:** PostgreSQL SSL via `NEBU_POSTGRES_SSL` env var
**Epic:** bugfix
**Cycle:** 0
**Reviewer:** Code Review Agent (bmad-code-review)
**Date:** 2026-06-25
**Verdict:** APPROVE — no CRITICAL/MAJOR. Two INFO notes for follow-up.

---

## Summary

All five acceptance criteria are met. The implementation is small, focused, and
correct. The new unit tests (20 total across the two touched test files) pass green
in the container (`elixir:1.20-alpine`, the same image `make test-unit-elixir` uses).
Code matches the project conventions (ADR-018 inline-config, single OTP app).

| AC | Status | Evidence |
|----|--------|----------|
| AC1 — `NEBU_POSTGRES_SSL=true` → `ssl: true` in `Nebu.Repo`, default `false` | PASS | `runtime.exs:122` `ssl: System.get_env("NEBU_POSTGRES_SSL", "false") == "true"` |
| AC2 — SSL also applies to migration connection | PASS | `release.ex:214` `parse_url/1` appends `++ postgres_ssl_opts()` |
| AC3 — `NEBU_POSTGRES_SSL: "true"` in server `environment:` block | PASS | `cloud-init.tftpl:448` |
| AC4 — DB URLs moved inline to `environment:`, SSL params removed | PASS | `cloud-init.tftpl:446-447`; no `?ssl=`/`?sslmode=` remain in the `.tftpl` |
| AC5 — no env var → `ssl: false` (default) | PASS | `release_test.exs` unset/false/garbage cases all assert `[ssl: false]` |

---

## Findings by Severity

### CRITICAL
None.

### MAJOR
None.

### MINOR
None blocking. (Test-review MINOR-2/MINOR-3 already triaged and accepted.)

### INFO

**INFO-1 — AC2 is a behavior change for migrations, not just a refactor (worth a deploy note).**

`parse_url/1` in `release.ex` only extracts `hostname/port/username/password/database`
from the URL — it has never parsed the query string. The old
`NEBU_DB_URL_MIGRATE=...?sslmode=require` query param was therefore **silently
ignored** and the migration connection ran **without TLS**. After this change the
migration connection gets `ssl: true` (via `postgres_ssl_opts/0`) for the first time.

This is the correct fix and exactly what AC2 asks for, but it means the migration
TLS path is newly exercised in production. Recommend confirming the migrate-and-exit
task connects successfully against Stackit PostgresFlex on the next `make redeploy`
(the story's own File List notes a "redeploy + verify" expectation). No code change
required.

**INFO-2 — Postgrex `ssl: true` defaults to `verify: :verify_full` (mlock-locked at postgrex 0.22.2).**

Bare `ssl: true` (no `ssl_opts`) in Postgrex >= 0.18 enables full peer/hostname
verification against the system CA store — unlike libpq `sslmode=require`, which
encrypts without verifying. For the **runtime Repo** this is *not a regression*: the
prior compose `environment:` block already passed `?ssl=true` (which Ecto/Postgrex
resolves to the same `ssl: true`), so verify-full was already in effect and the
deployment was working. For the **migration connection** it is new (see INFO-1).

If a future Stackit cert chain or a self-managed PG instance ever fails verification,
the operator will need an `ssl_opts: [cacerts: ...]` (or `verify: :verify_none`) escape
hatch — there is currently none, and `NEBU_POSTGRES_SSL` is boolean-only. This is a
known limitation, not a defect for this story. Suitable as a follow-up story if a
non-publicly-chained PG endpoint is ever targeted.

---

## Non-findings (verified, no action)

- **Test path resolution is correct in Docker.** `deploy_config_test.exs` resolves
  `Path.expand("../../../deploy/...", __DIR__)`. Under `make test-unit-elixir` cwd is
  `/workspace/server`, `__DIR__` = `/workspace/server/test/nebu`, three `../` →
  `/workspace`, then `deploy/tofu/examples/stackit/cloud-init.tftpl`. Resolves
  correctly both locally and in-container. The `setup_all` `flunk` guard makes a path
  regression loud rather than a false green.
- **`async: false` on `release_test.exs`** is correct — the tests mutate process env
  (`System.put_env`) and restore it via `on_exit`. No state leak.
- **Logic duplication** between `runtime.exs:122` and `release.ex:191` is a literal
  one-liner (`System.get_env("NEBU_POSTGRES_SSL", "false") == "true"`). `runtime.exs`
  cannot easily call `Nebu.Release.postgres_ssl_opts/0` at config-eval time without
  coupling config to a compiled module; the duplication is consistent with ADR-018
  (locality of behavior) and not a finding.
- **`.tftpl` template is clean.** `grep` confirms no `?ssl=`, `?sslmode=`, or
  `sslmode=require` remain anywhere in the template; `NEBU_DB_URL`/`NEBU_DB_URL_MIGRATE`
  are gone from the `.env` content block and present inline in `environment:`.
- **Stale `terraform.tfstate`** still contains old `?sslmode=require`/`?ssl=true` URLs
  (and committed live secrets), but it is a rendered state artifact, **not part of this
  diff** and out of scope for this story. Flagged here only for awareness — the
  committed real secrets in that file are a separate, pre-existing concern.

---

## Test Verification

Ran in container (`elixir:1.20-alpine`):

```
mix test test/nebu/deploy_config_test.exs test/nebu/release_test.exs --warnings-as-errors
Result: 20 passed
```

(The `:nebu_http` / `:compliance` "application not available" messages are pre-existing
config warnings unrelated to this story and do not fail the run.)
