---
paths: server/lib/nebu/admin/**
---

# Nebu.Admin Namespace

Public API Entry-Point: `Nebu.Admin` — andere Domains rufen nur dieses Modul auf.

## Verantwortlichkeiten

- Admin-UI: Phoenix LiveView (HEEx-Templates)
- Admin OIDC Login: Single OIDC Client via Bootstrap-Wizard (ADR-022)
- Admin DB-Queries: Direkte SQL via `Nebu.Repo`

## OIDC-Bootstrap (ADR-022)

- OIDC wird **ausschließlich** via Bootstrap-Wizard konfiguriert (`server_config`-Tabelle)
- Keine `NEBU_OIDC_*` oder `NEBU_ADMIN_OIDC_*` Env-Variablen
- Single OIDC Client für Matrix Bearer-Validierung UND Admin-Login
- Server bootet ohne OIDC-Config; vor Bootstrap: alle Bearer-Tokens rejected (401)

## UI-Konventionen

- Tech Stack: Phoenix LiveView + Tailwind + DaisyUI
- E2E Tests: Playwright + Cucumber/Gherkin
- Accessibility: WCAG 2.1 AA verpflichtend
- Keine plain `.spec.ts` ohne `.feature`-Gegenstück

## Security

- Admin-Endpoints sind SEC-Gate-relevant (security_review: required auto-klassifiziert)
- CSRF: Phoenix-Token für alle State-ändernden Forms
- Admin-Route-Guards via `Nebu.Admin.Auth`-Plug
