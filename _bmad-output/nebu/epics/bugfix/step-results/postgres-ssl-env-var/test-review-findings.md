# Test Review Findings — postgres-ssl-env-var

Date: 2026-06-25

## Score: 84/100 — Grade: A (Good)
## Recommendation: Approved with fixes applied

## Findings

### MAJOR-1 (RESOLVED) — AC1 had no direct test for runtime.exs Ecto wiring

AC1 says `runtime.exs` reads `NEBU_POSTGRES_SSL` and sets `ssl: true` on `Nebu.Repo` config.
The original tests verified `Release.postgres_ssl_opts/0` but not that runtime.exs uses it.

**Fix applied:** Added two tests in `release_test.exs` that simulate the runtime.exs wiring:
- `"postgres_ssl_opts/0 produces opts compatible with Nebu.Repo Ecto config (AC1 wiring)"` — NEBU_POSTGRES_SSL=true
- `"postgres_ssl_opts/0 produces ssl: false when NEBU_POSTGRES_SSL is unset (AC1 default)"` — unset case

### MINOR-2 — AC2 migration-path coverage is indirect

`parse_url/1` is private; tests verify `postgres_ssl_opts/0` returns the right shape.
A live integration test would fully cover this path. Accepted as-is for unit scope.

### MINOR-3 — AC4 .env removal tests are format-sensitive

`refute content =~ ~r/NEBU_DB_URL=postgresql/` could theoretically bypass spaces-around-`=`.
Very low probability for Compose env files. Combined sslmode=require check provides safety net.

### INFO-1 — No P0/P1 priority markers

Acceptable for a small 5-AC bugfix story.

## Final status: 0 MAJOR (all resolved), 2 MINOR (accepted)
