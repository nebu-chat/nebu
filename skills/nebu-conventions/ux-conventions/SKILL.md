---
name: ux-conventions
description: UX- und Accessibility-Konventionen für Nebu Admin-UI. Für nebu-ux-reviewer.
  WCAG 2.1 AA, DaisyUI, Playwright+Gherkin-Standards.
---

# UX / Accessibility Konventionen

## Tech Stack Admin-UI

- **Templates:** Phoenix LiveView (HEEx) + Phoenix Channels
- **Styles:** Tailwind CSS + DaisyUI
- **E2E Tests:** Playwright + Cucumber/Gherkin (`e2e/features/`, `e2e/steps/`)

## Accessibility-Baseline (WCAG 2.1 AA)

Folgendes ist für alle Admin-UI-Stories verpflichtend:

- Alle Form-Inputs haben `<label>`-Zuordnung (via `for`/`id` oder `aria-label`)
- Interaktive Elemente erreichbar per Keyboard (Tab-Reihenfolge, Focus-Styles)
- Farbkontraste ≥ 4.5:1 für normalen Text, ≥ 3:1 für großen Text
- Keine Information nur via Farbe vermittelt
- ARIA-Roles korrekt (keine `role="button"` auf `<div>` wenn `<button>` möglich)

## DaisyUI-Consistency

- Primäre Actions → `btn btn-primary`
- Destructive Actions → `btn btn-error`
- Informations-Badges → `badge badge-info`
- Neue UI-Elemente nutzen bestehende DaisyUI-Komponenten; keine eigenen CSS-Klassen ohne Abstimmung

## E2E Test Anforderungen

**Format (verpflichtend):** Alle Playwright-Tests als Gherkin Feature Files:
```
e2e/features/<feature>.feature   ← Gherkin scenarios (zuerst, failing)
e2e/steps/<feature>.steps.ts     ← Cucumber step definitions
```

- Keine plain `.spec.ts` ohne `.feature`-Gegenstück
- Kein Cookie-Forging, kein DB-Seeding-Shortcut für Auth-Flows
- Echte Browser-Navigation via Authorization Code + PKCE
- Tests laufen gegen den echten Stack (kein Mocking)

## OIDC-Auth-Testing

Immer Authorization Code + PKCE — `grant_type=password` (ROPC) ist mit Dex v2.41+ nicht kompatibel.

## Review-Klassifikation

- **Blocking** — WCAG-Violations, fehlende Labels, Keyboard-Inaccessibility
- **Advisory** — DaisyUI-Inkonsistenz, verbesserungsfähige Farbkontraste
