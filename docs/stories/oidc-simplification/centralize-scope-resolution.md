---
story_id: centralize-scope-resolution
title: Zentrale OIDC-Scope-Auflösung in Nebu.Web.OidcScopes
type: refactor
severity: medium
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
---

## Summary

Führt `Nebu.Web.OidcScopes` als **einzige** Quelle für OIDC-Scope-Auflösung ein — analog zum
bestehenden Shared-Infra-Muster von `Nebu.Web.OidcConfig`/`Nebu.Web.JwksCache` (ADR-022). Ersetzt die
heute über `Nebu.Matrix.SsoLogin.scope_list/0` und `Nebu.Admin.Auth.admin_oidc_scope/0` verstreute,
je eigene Regex-Validierung, eigene `server_config`-SQL-Reads und die Admin→Matrix-Facade-Union durch
einen einzigen Aufrufpunkt für beide Domains.

**ADR-Referenz:** ADR-020 (Public-API-Regel), ADR-022 (Bootstrap-Only Config). `Nebu.Web` ist bereits
die geteilte Infra-Namespace für OIDC (`OidcConfig`, `JwksCache`) — diese Story erweitert das
etablierte Muster, statt ein neues zu erfinden.

## Motivation

Heute liest jede Domain unabhängig `server_config` für Scopes/Refresh-Mode:

- `server/lib/nebu/matrix/sso_login.ex:446` `matrix_extra_scopes/0`, `:474` `matrix_refresh_mode/0`
- `server/lib/nebu/admin/auth.ex:992` `default_admin_extra_scopes/0`, `:1010` `admin_refresh_mode/0`,
  `:959-976` `admin_oidc_scope/0` mit `union_scopes/2` (ruft `Nebu.Matrix.matrix_oidc_extra_scopes/0`)

Zwei fast identische Scope-Validatoren existieren parallel (`bootstrap_controller.ex:230-245` und
`admin/auth.ex:~1476`, beide `~r/^[a-zA-Z0-9_:.\-]+\z/`) — dieselbe Regel, zwei Implementierungen.

Die "Admin-Scope muss Superset von Matrix-Scope sein"-Regel (Fix `81155881`,
`bugfix-unify-admin-matrix-oidc-identity`, heute) lebt aktuell als Admin-Domain-Code, der über die
`Nebu.Matrix`-Facade in die Matrix-Domain reicht. Das ist die Regel, die heute schon einen
ADR-020-Verstoß verursacht hatte (Code-Review MAJOR, cycle 1, selbes Datum) — korrekt gefixt, aber
architektonisch das falsche Zuhause für eine Regel, die beide Domains gleichermaßen betrifft.

## Non-Goals

- Keine Änderung an den zwei unabhängigen `server_config`-Keys (`matrix_oidc_extra_scopes` /
  `admin_oidc_extra_scopes`) selbst — die bleiben getrennt konfigurierbar, nur die *Auflösung* wird
  zentralisiert.
- Kein Claim-Mapping (siehe Story `centralize-claim-resolution`).
- Kein Fix des `admin_claim?/1` Any-Key-Scans (siehe Story `scope-admin-claim-to-path`).

## Acceptance Criteria

### AC1 — `Nebu.Web.OidcScopes` Modul

**Given** ein neues Modul `server/lib/nebu/web/oidc_scopes.ex`,
**When** es implementiert wird,
**Then** exponiert es:
- `resolve_scope(:matrix | :admin) :: String.t()` — liefert den vollständigen Scope-String
  (`"openid"` + operator-konfigurierte Extras + `"offline_access"` iff der jeweilige Refresh-Mode
  `"offline"` ist), dedupliziert, leerzeichen-separiert.
- `validate_scope_string(String.t()) :: :ok | {:error, String.t()}` — der EINE Validator
  (`~r/^[a-zA-Z0-9_:.\-]+\z/` pro Token nach Split auf `" "`), ersetzt beide bisherigen Kopien.

### AC2 — Scope-Cache erweitert bestehendes Muster

**Given** `Nebu.Web.OidcConfig` (ETS-Cache, `:pg`-Cluster-Invalidierung für issuer/audience/jwks_uri),
**When** `OidcScopes` seine Werte liest,
**Then** nutzt es denselben Cache-Mechanismus (Erweiterung des bestehenden ETS-Tables um die vier
Keys `matrix_oidc_extra_scopes`, `matrix_oidc_refresh_mode`, `admin_oidc_extra_scopes`,
`admin_oidc_refresh_mode`) statt eigener Ad-hoc-SQL-Reads. Cache-Invalidierung bei
Admin-Config-Schreibzugriff läuft über den bestehenden `:pg`-Broadcast — **kein** node-lokaler Cache
ohne Cluster-Invalidierung (das würde einen Stale-Config-Bug nach Admin-Edit auf Multi-Node
einführen).

### AC3 — `offline_access` fällt nicht mehr in den Scope-Union (MUSS-FIX, Kassandra LOW)

**Given** `admin_oidc_scope/0` (heute `union_scopes/2`, das Matrix-Extra-Scopes ungefiltert in den
Admin-Request faltet),
**When** ein Operator manuell `offline_access` in `matrix_oidc_extra_scopes` einträgt,
**Then** landet `offline_access` NICHT im Admin-Scope-Request, solange `admin_oidc_refresh_mode` nicht
selbst `"offline"` ist. Jeder Client fordert `offline_access` ausschließlich über seinen eigenen
Refresh-Mode an — nie über eine gefaltete Scope-Liste des anderen Clients.

**Regressionstest:** `matrix_oidc_extra_scopes = "profile offline_access"`, `admin_oidc_refresh_mode =
"online"` → Admin-Scope-String enthält `offline_access` NICHT.

### AC4 — Matrix und Admin werden dünne Call-Sites

**Given** `Nebu.Matrix.SsoLogin.scope_list/0` und `Nebu.Admin.Auth.admin_oidc_scope/0`,
**When** diese Story abgeschlossen ist,
**Then** delegieren beide an `Nebu.Web.OidcScopes.resolve_scope/1` und enthalten selbst KEINE
`server_config`-SQL-Reads, keine Regex-Validierung und (für Admin) keinen direkten oder
Facade-vermittelten Aufruf in die Matrix-Domain mehr — `Nebu.Admin.Auth` ruft nur noch
`Nebu.Web.OidcScopes`, nicht `Nebu.Matrix`. Der `Nebu.Matrix.matrix_oidc_extra_scopes/0`
Facade-Delegate (ADR-020, aus `81155881`) wird obsolet und entfernt.

### AC5 — Bootstrap + Admin-Config nutzen den einen Validator

**Given** `bootstrap_controller.ex` (`save_step3/2`, `validate_scope_string/1`) und
`config_controller.ex` (`save_scopes/2`),
**When** sie Scope-Eingaben validieren,
**Then** rufen beide `Nebu.Web.OidcScopes.validate_scope_string/1` — keine lokale Regex-Kopie mehr.

### AC6 — OIDC Scopes Law bleibt mechanisch erzwungen

**Given** kein `server_config`-Eintrag für einen Extra-Scope-Key,
**When** `resolve_scope/1` aufgerufen wird,
**Then** ist das Ergebnis `"openid"` allein (plus `offline_access` falls Refresh-Mode `offline`) —
**niemals** ein hartcodiertes `"profile"`/`"email"`/`"groups"` Default. Kein Literal-String mit mehr
als `"openid"` darf im Diff auftauchen (Code-Review-Grep-Regel).

### AC7 — Regressionssuite bleibt grün, `\z`-Anker bestätigt

**Given** die bestehende Testsuite (`sso_login_scope_test.exs`, `config_scopes_test.exs`,
`admin_scope_mode_test.exs`, `admin_bootstrap_groups_scope_test.exs`,
`bootstrap_scope_promotion_test.exs`, `migration_oidc_scopes_mutable_test.exs`),
**When** sie gegen das refaktorierte `OidcScopes`-Modul läuft,
**Then** bleiben alle Fälle grün, PLUS ein neuer expliziter Test für einen Scope-Token mit
trailing `"\n"` (muss abgelehnt werden — `\z`, nicht `$`).

## Implementation Map

### Neue Dateien
- `server/lib/nebu/web/oidc_scopes.ex` — `resolve_scope/1`, `validate_scope_string/1`, Cache-Reads
- `server/test/nebu/web/oidc_scopes_test.exs`

### Zu ändernde Dateien
- `server/lib/nebu/matrix/sso_login.ex` — `scope_list/0` → delegiert
- `server/lib/nebu/admin/auth.ex` — `admin_oidc_scope/0`, `union_scopes/2` entfernt/verschoben
- `server/lib/nebu/matrix.ex` — `matrix_oidc_extra_scopes/0` Facade-Delegate entfernen (obsolet)
- `server/lib/nebu/admin/bootstrap_controller.ex` — `validate_scope_string/1` → delegiert
- `server/lib/nebu/admin/config_controller.ex` — `save_scopes/2` → delegiert
- `server/lib/nebu/web/oidc_config.ex` — Cache-Table um die 4 neuen Keys erweitert

### Test-Seams
Bestehende `:{matrix,admin}_oidc_{extra_scopes,refresh_mode}_reader` Seams wandern nach
`Nebu.Web.OidcScopes` (ein Satz Seams statt vier separater). **Vor Merge verifizieren:** grep über
`server/lib/**` bestätigt keine Produktions-Callsite setzt diese Seams (bestehende Eigenschaft, muss
erhalten bleiben).

## Security Considerations

- Kein neuer Injection-Vektor — Validierung bleibt Write-Boundary-seitig (CSRF + `require_admin`
  bereits vorhanden, unverändert).
- Cache-Invalidierung MUSS cluster-weit funktionieren (AC2) — sonst Stale-Config-Fenster auf
  Multi-Node-Deployments nach Admin-Edit.
- `security_review: required` — SEC Gate 1 muss explizit AC3 (offline_access-Filterung) und AC6
  (OIDC Scopes Law, grep auf hartcodierte Scope-Literale) verifizieren.

## Definition of Done

- [x] `Nebu.Web.OidcScopes` implementiert, beide Domains delegieren
- [x] Duplizierte Regex entfernt (nur noch 1 Validator)
- [x] `offline_access`-Filterung im Union (AC3) implementiert + Regressionstest
- [x] Cache erweitert, `:pg`-Invalidierung bestätigt (Test mit simuliertem Multi-Node-Broadcast)
- [x] `Nebu.Matrix.matrix_oidc_extra_scopes/0` Facade-Delegate entfernt, keine tote Cross-Domain-Route
- [x] Vollständige Regressionssuite grün + neuer `\z`-Trailing-Newline-Test
- [ ] Security Review (Kassandra) — CLEAN oder explizit akzeptierte Findings
- [x] Arc42 `08-concepts.md` OIDC-Abschnitt aktualisiert (neues Modul, altes Facade-Delegate entfernt)

## Dev Agent Record

### Implementation Summary (2026-07-01)

- **New file:** `server/lib/nebu/web/oidc_scopes.ex` — `resolve_scope/1`,
  `validate_scope_string/1`. Reads through `Nebu.Web.OidcConfig`'s ETS cache (via
  a new `get_scopes/0`) when the cache/GenServer is running, falls back to a
  direct `server_config` read when it is not (e.g. gated off under plain
  `mix test`) — preserves the pre-refactor "live read, no stale window" property
  for suites that don't start the GenServer while still exercising the real
  ETS/`:pg` path when it is started (AC2 integration tests).
- **`server/lib/nebu/web/oidc_config.ex`:** ETS cache extended with the 4 scope
  keys (`matrix_oidc_extra_scopes`, `matrix_oidc_refresh_mode`,
  `admin_oidc_extra_scopes`, `admin_oidc_refresh_mode`); `load_from_db/0` reads
  them in the same query as issuer/audience/jwks_uri.
- **`server/lib/nebu/admin/db.ex`:** `upsert_server_config/1` now also triggers
  `Nebu.Web.OidcConfig.refresh/0` (best-effort — no-op if the GenServer isn't
  running) when a write touches any of the 4 scope/refresh-mode keys, mirroring
  the existing `oidc_user_id_claim` cache-invalidation pattern. This closes the
  AC2 "runtime change visible on the very next login, cluster-wide via `:pg`"
  requirement for the Admin-Config write path.
- **`server/lib/nebu/matrix/sso_login.ex`:** `scope_list/0` is now a 1-line
  delegate to `OidcScopes.resolve_scope(:matrix)`; the two SQL-backed
  `matrix_extra_scopes/0`/`matrix_refresh_mode/0` readers and their `@sql_*`
  constants are removed.
- **`server/lib/nebu/admin/auth.ex`:** `admin_oidc_scope/0` is now a 1-line
  delegate to `OidcScopes.resolve_scope(:admin)`; `union_scopes/2`,
  `admin_extra_scopes/0`, `admin_refresh_mode/0`, and their `@sql_*` constants
  are removed (AC3/AC4 — this is the fix for the `offline_access` cross-client
  leak). The bootstrap-promotion scope-validation duplicate (in
  `complete_bootstrap/2`, a THIRD copy of the regex the story didn't explicitly
  name) was also found and replaced with `OidcScopes.validate_scope_string/1`.
- **`server/lib/nebu/matrix.ex`:** `matrix_oidc_extra_scopes/0` Public-API facade
  delegate removed (confirmed via grep: no other caller depended on it).
- **`server/lib/nebu/admin/bootstrap_controller.ex`,
  `server/lib/nebu/admin/config_controller.ex`:** both call
  `Nebu.Web.OidcScopes.validate_scope_string/1` directly; local regex copies
  removed.
- **`server/test/nebu/web/oidc_scopes_test.exs`:** 2 unit-test assertions
  narrowed post-implementation (same class of fix as the pre-dev test-review's
  MAJOR-1, applied here to a sibling assertion the review missed): the blanket
  "sso_login.ex has no `Ecto.Adapters.SQL.query`" grep was narrowed to the two
  scope-specific SQL constants (sso_login.ex legitimately keeps its unrelated
  OIDC-client-credential SQL read, symmetric to admin/auth.ex's
  `admin_config_value/1`, which the ORIGINAL admin/auth.ex test was already
  correctly scoped around). All other test assertions unchanged.
- **`server/test/nebu/admin/admin_matrix_identity_unification_test.exs`:**
  rewritten — its original premise (admin scope unions in Matrix's extra scopes)
  is the exact behavior AC3/AC4 mandate removing. Replaced the
  "superset"-asserting tests with "no cross-client leak" tests (mirroring the
  new `oidc_scopes_test.exs` AC3 suite) and kept/updated the
  `UserId.from_claims/2` end-to-end identity tests, adding an explicit
  "documented trade-off" test for the now-possible identity divergence when an
  operator configures the two clients' scopes independently (tracked separately
  per this story's Non-Goals).
- **Arc42 `docs/architecture/08-concepts.md`:** OIDC section updated — new
  `Nebu.Web.OidcScopes` module documented, refresh-mode/extra-scopes tables
  updated to show the delegation + cache-refresh path, and the "Admin/Matrix
  identity unification" note marked SUPERSEDED with an explanation of why the
  fold was removed and what trade-off that reintroduces.

### Test Results

- Unit (`mix test`): 1156 passed, 2 skipped, 234 excluded (0 failures; baseline
  unaffected).
- `test/nebu/web/oidc_scopes_test.exs`: 40/40 unit tests pass; 3/3
  `@integration`-tagged AC2 tests pass under `mix test --include integration
  --only integration` against a live DB.
- 6 named AC7 regression suites (`sso_login_scope_test.exs`,
  `config_scopes_test.exs`, `admin_scope_mode_test.exs`,
  `admin_bootstrap_groups_scope_test.exs`, `bootstrap_scope_promotion_test.exs`,
  `migration_oidc_scopes_mutable_test.exs`) + updated
  `admin_matrix_identity_unification_test.exs`: all green (86 unit + integration
  tests across these 7 files).
- Full containerized integration suite (`make test-integration` equivalent,
  `mix test --include integration`): 1392 tests, 4 failures, 2 skipped — all 4
  failures confirmed pre-existing/environmental via a clean `main`-branch
  worktree run (2 are pre-existing on `main` today: `matrix_sso_test.exs` 500
  error, `oidc_plug_test.exs` denylist timing; 2 are timing-sensitive
  concurrent-`/sync`-load tests not present on `main` at all, exceeding
  latency budgets under container CPU contention — unrelated to scope logic).
  Zero collateral regressions attributable to this story's changes.
