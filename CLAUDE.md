# CLAUDE.md

This file provides global guidance for all agents. Module-specific rules are in `.claude/rules/`.
Domain conventions (cluster-safety, no-domain-model, security) are in `skills/nebu-conventions/`.

## Projekt

**Nebu** — compliance-native, self-hosted, Matrix Client-Server API kompatibler Chat-Server.
Pure Elixir/OTP (ADR-019 — single OTP app `:nebu`). Kein Federation by Design. Apache 2.0.

## Code Change Policy

`server/lib/`, `server/test/`, `server/priv/migrations/` sind pipeline-protected.
Direkte Änderungen außerhalb eines aktiven `nebu-pipeline`-Runs sind nicht erlaubt.
Bei Bugs: `/nebu-pipeline --bug "<beschreibung>"`. Bei Features: `/nebu-pipeline --epic <name>`.

## Modulstruktur

Drei Namespaces: `Nebu.Matrix` (Matrix API + Chat-Logic), `Nebu.Media` (Upload/Download),
`Nebu.Admin` (Admin-UI + OIDC). Jeder hat genau ein Public-API-Modul für Cross-Domain-Calls.
`Nebu.Web` (Routing/Plugs), `Nebu.Compliance` (Audit-Log) sind shared infrastructure.

## Build & Test

```bash
make build-server          # mix compile (build container)
make test-unit-elixir      # mix test (build container)
make dev                   # docker compose up (server + postgres + dex + minio)
make redeploy              # rebuild server image + recreate container (nach Code-Änderungen)
make test-integration      # full stack + Gherkin E2E tests
```

**Nach Code-Commits immer `make redeploy`** — `make build-server` baut kein Docker-Image.

## Named Epic Convention

Stories: `docs/stories/<epic-name>/<story-slug>.md`
Pipeline state: `_bmad-output/nebu/epics/<epic-name>/pipeline-state.yaml`
Git branches: `feature/<epic-name>` (branched from `main`, merged back to `main`).

```
/nebu-pipeline --epic <name>       — einzelne Story in Named Epic
/nebu-pipeline-epic --epic <name>  — alle Stories eines Epics
/nebu-release new-epic <name>      — branch + scaffold dirs
```

## Key ADRs

| ADR | Entscheidung |
|---|---|
| 018 | No Domain Model — SQL inline im Handler, keine Repository/Service-Layer |
| 019 | Single OTP App — kein Umbrella, ein `mix.exs`, ein `Nebu.Application` |
| 020 | Public-API-Regel — Cross-Domain nur über `Nebu.Matrix`/`Media`/`Admin` |
| 021 | Pure Elixir — kein Go, kein gRPC; Command-Layer in-process plain modules |
| 022 | OIDC Bootstrap-Only — kein `NEBU_OIDC_*` Env; Bootstrap-Wizard schreibt `server_config` |

## Definition of Ready

Eine Story ist „ready" wenn: Akzeptanzkriterien vorhanden, Story-Klassifikation
(`classify_story.py`) durchgeführt, kein offenes ADR betroffen.
