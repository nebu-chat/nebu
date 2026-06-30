---
name: code-review-checklist
description: Nebu Code-Review-Checkliste. Lädt automatisch für nebu-code-reviewer
  und nebu-test-reviewer. MAJOR/MINOR/INFO Klassifikation.
---

# Code-Review-Checkliste

## Klassifikation

- **MAJOR** — muss gefixt werden bevor Commit; blockiert Pipeline
- **MINOR** — sollte gefixt werden; Pipeline-Auto-Cycle (max 3 Rounds)
- **INFO** — Verbesserungsvorschlag, kein Block

## Architektur-Checks (MAJOR bei Verletzung)

- [ ] Kein Repository-Pattern, kein Service-Layer, kein Ecto.Schema (ADR-018)
- [ ] SQL inline im Handler, nicht in Helper-Modulen (ADR-018)
- [ ] Cross-Domain-Calls nur über `Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin` (ADR-020)
- [ ] Neue Module unter dem richtigen Namespace (`Nebu.Matrix.*`, etc.)
- [ ] Keine neue `mix.exs`, kein neues `use Application` (ADR-019)

## Cluster-Safety-Checks (MAJOR bei Verletzung)

- [ ] Process-Registrierung via `Horde.Registry` (nicht `Process.register/2`)
- [ ] PubSub via `:pg` (nicht `Phoenix.PubSub` für cluster-kritische Pfade)
- [ ] `GenServer.start_link` nur über `Horde.DynamicSupervisor`

## Sicherheits-Quick-Checks (MAJOR/CRITICAL)

- [ ] Keine parameterlose SQL-String-Interpolation (`"SELECT ... #{user_input}"`)
- [ ] Keine Secrets/Passwörter in Logs oder Fehlermeldungen
- [ ] Externe Inputs validiert bevor sie in DB oder Template gehen

## Test-Coverage-Checks (MAJOR bei Fehlen)

- [ ] Jedes Acceptance Criterion hat mindestens einen Test
- [ ] GenServer-State-Stories haben einen Crash/Restart-Test
- [ ] UI-Stories haben Playwright+Gherkin-Tests in `e2e/features/`
- [ ] Matrix-API-Stories haben ExUnit `:integration` Tests

## OIDC/Auth-Checks (MAJOR)

- [ ] Keine `grant_type=password` in Tests (Dex v2.41+ unterstützt kein ROPC)
- [ ] Authorization Code + PKCE für alle OIDC-E2E-Tests

## Elixir-Style (MINOR)

- [ ] `let it crash` — kein defensives `try/rescue` ohne Supervisor-Strategie
- [ ] `handle_*` Callbacks für GenServer-State, kein direkter Zugriff
- [ ] Supervisor-Strategie `one_for_one` als Default, Abweichungen begründet
