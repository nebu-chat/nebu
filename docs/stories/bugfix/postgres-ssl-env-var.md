---
id: postgres-ssl-env-var
epic: bugfix
status: review
security_review: not-needed
baseline_commit: 6b1c79a0ab62c17ddb9c9fa57c2740d2b74b6bf8
---

# PostgreSQL SSL via NEBU_POSTGRES_SSL env var

## Problem

SSL für PostgreSQL-Verbindungen ist aktuell direkt in der DB-URL (`?ssl=true`) kodiert. Das ist fehleranfällig und inkonsistent: Die `NEBU_DB_URL` im Stackit Compose-`environment:` hat `?ssl=true`, die gleiche URL in `.env` hat `?sslmode=require`. `NEBU_DB_URL_MIGRATE` in `environment:` referenziert nur die `.env`-Variable und hat damit `?sslmode=require` statt `?ssl=true`.

Außerdem sind beide DB-URLs doppelt gepflegt: einmal im `.env` und einmal im Compose `environment:` Block.

## Story

**Als** Operator der Nebu auf Stackit betreibt,
**möchte ich** SSL für PostgreSQL über eine separate `NEBU_POSTGRES_SSL=true` Env-Variable steuern,
**damit** die DB-URLs SSL-frei bleiben und SSL an einer einzigen Stelle aktiviert wird.

## Acceptance Criteria

1. **`NEBU_POSTGRES_SSL=true` setzt `ssl: true` in Ecto** — `runtime.exs` liest `NEBU_POSTGRES_SSL` und setzt `ssl: true` auf `Nebu.Repo` Config. Default ohne Env-Var ist `false`.

2. **SSL gilt auch für Migrations-Verbindung** — `release.ex` `migrate_url/0` bzw. die Repo-Config für Migrations respektiert `NEBU_POSTGRES_SSL` ebenfalls.

3. **Stackit Compose hat `NEBU_POSTGRES_SSL: "true"` direkt im environment-Block** — cloud-init.tftpl setzt `NEBU_POSTGRES_SSL: "true"` im `server` service `environment:`.

4. **Beide DB-URLs direkt im Compose, nicht mehr in `.env`** — `NEBU_DB_URL` und `NEBU_DB_URL_MIGRATE` werden aus dem `.env`-Block entfernt und direkt als Werte in den `environment:`-Block des Compose `server` Service eingefügt. SSL-Query-Parameter (`?ssl=true`, `?sslmode=require`) werden aus den URLs entfernt — SSL wird ausschließlich über `NEBU_POSTGRES_SSL` gesteuert.

5. **Regression: bestehende Deployments ohne `NEBU_POSTGRES_SSL` funktionieren** — Wenn `NEBU_POSTGRES_SSL` nicht gesetzt ist, wird `ssl: false` verwendet (bisheriges Verhalten für lokale Dev-Stacks ohne SSL).

## Affected Files

- `server/config/runtime.exs` — `ssl:` Option zu `Nebu.Repo` config hinzufügen
- `server/lib/nebu/release.ex` — SSL für die Migrations-Verbindung
- `deploy/tofu/examples/stackit/cloud-init.tftpl` — DB-URLs in `environment:` verschieben, `?ssl=true`/`?sslmode=require` aus URLs entfernen, `NEBU_POSTGRES_SSL: "true"` hinzufügen

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`NEBU_POSTGRES_SSL=true` setzt ssl: true** — ExUnit unit test
   - Given: `System.put_env("NEBU_POSTGRES_SSL", "true")`
   - When: runtime config wird ausgewertet
   - Then: `Application.get_env(:nebu, Nebu.Repo)[:ssl] == true`

2. **Kein `NEBU_POSTGRES_SSL` → ssl: false (default)** — ExUnit unit test
   - Given: `NEBU_POSTGRES_SSL` ist nicht gesetzt
   - When: runtime config wird ausgewertet
   - Then: `Application.get_env(:nebu, Nebu.Repo)[:ssl] == false` (oder nil/default)

3. **Stackit compose hat kein SSL in DB-URLs** — statische Analyse / grep
   - Given: `cloud-init.tftpl` nach dem Fix
   - Then: `NEBU_DB_URL` enthält kein `?ssl=` oder `?sslmode=`
   - Then: `NEBU_POSTGRES_SSL: "true"` ist im `environment:`-Block vorhanden

4. **Beide DB-URLs nicht mehr im `.env`-Block** — statische Analyse / grep
   - Given: `cloud-init.tftpl` nach dem Fix
   - Then: Im `.env`-content-Block von cloud-init gibt es kein `NEBU_DB_URL=` und kein `NEBU_DB_URL_MIGRATE=`
   - Then: Beide Variablen sind direkt als `key: value` im `environment:`-Block des server service

## Dev Notes

- Ecto/Postgrex akzeptiert `ssl: true` als Repo-Option. Die URL-Parameter `?ssl=true` und `?sslmode=require` können dann entfernt werden.
- `release.ex` nutzt `migrate_url/0` das die URL direkt an Postgrex übergibt. Hier entweder einen eigenen `Repo`-Config-Slot für Migrations anlegen oder die `ssl:`-Option separat an den Start-Opts mitgeben.
- Im cloud-init Compose-Template: `$${NEBU_DB_URL_MIGRATE}` wurde bisher aus `.env` befüllt. Nach dem Fix ist der Wert direkt im `environment:`-Block als `NEBU_DB_URL_MIGRATE: "postgresql://..."` — kein `$${}`-Verweis mehr nötig.

## File List

- `server/lib/nebu/release.ex` — added `postgres_ssl_opts/0` public function; merged into `parse_url/1`
- `server/config/runtime.exs` — added `ssl:` key to `Nebu.Repo` config block
- `deploy/tofu/examples/stackit/cloud-init.tftpl` — removed `NEBU_DB_URL`/`NEBU_DB_URL_MIGRATE` from `.env` content block; inlined both URLs without SSL params in `environment:` block; added `NEBU_POSTGRES_SSL: "true"`

## Dev Agent Record

### Completion Notes

Implemented all three changes in a single cycle (Cycle 0):

1. `Nebu.Release.postgres_ssl_opts/0` — new public `@doc false` function returning `[ssl: true]` when `NEBU_POSTGRES_SSL == "true"`, `[ssl: false]` otherwise. Merged into `parse_url/1` via `++ postgres_ssl_opts()` so AC2 (migrations) is covered automatically.

2. `runtime.exs` — added `ssl: System.get_env("NEBU_POSTGRES_SSL", "false") == "true"` to the `Nebu.Repo` config block for prod/dev environments (AC1).

3. `cloud-init.tftpl` — removed the two `NEBU_DB_URL*=postgresql://...?sslmode=require` lines from the `.env` content block; replaced the `environment:` block entries with clean inline URLs (no SSL params); added `NEBU_POSTGRES_SSL: "true"` (AC3 + AC4).

All 867 unit tests pass (0 failures, 0 warnings), including the 7 new `postgres_ssl_opts/0` tests in `release_test.exs` and all 6 static-analysis tests in `deploy_config_test.exs`.

## Change Log

- 2026-06-25: Implemented postgres-ssl-env-var story — added `NEBU_POSTGRES_SSL` env var support across release.ex, runtime.exs, and cloud-init.tftpl. All 13 new/pre-existing tests pass.
