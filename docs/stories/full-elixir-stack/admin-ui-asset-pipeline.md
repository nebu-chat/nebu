---
story_id: admin-ui-asset-pipeline
title: "Admin UI Asset Pipeline — Restore Tailwind + DaisyUI (Obsidian theme) for LiveView"
epic: full-elixir-stack
status: done
security_review: not-needed
created: 2026-06-18
branch: feature/full-elixir-stack
---

## Summary

The `admin-ui-migration` story rewrote the Go admin UI as Phoenix LiveView but dropped the
Tailwind + DaisyUI asset pipeline (the Elixir build container had no Node), shipping a
minimal hand-written `app.css` as a placeholder. The LiveView templates still reference
DaisyUI component classes (`btn`, `badge`, `toggle`, `card`, `table`, `navbar`, `alert`)
and the "Obsidian" design tokens, so the admin UI rendered unstyled. This story restores
the original design system and builds a proper, reproducible, Node-based asset pipeline for
the Elixir admin UI — without adding Node to the runtime image.

## What was done

- **`core/assets/`** — the asset source:
  - `package.json` / `package-lock.json` — `tailwindcss@^3.4` + `daisyui@^4.12` (devDeps).
  - `tailwind.config.js` — restores the original **"nebu"/Obsidian** DaisyUI theme (UX-DR1:
    `#f97316` primary on `#111827` base, WCAG-AA contrast) + typography scale (UX-DR2:
    Inter/JetBrains Mono, display/heading/body/caption/mono). `content` scans
    `../lib/nebu/**/*.{ex,heex,eex}` for the class usage in the `~H` LiveView templates.
  - `css/app.css` — `@font-face` (self-hosted WOFF2, no CDN) + `@tailwind` directives.
- **Self-hosted fonts** restored to `core/priv/static/fonts/` (Inter Regular/Medium/SemiBold,
  JetBrains Mono Regular), served by the AdminEndpoint `Plug.Static` at `/admin/static/fonts/`.
- **Build pipeline** (no local npm; Docker-only, matching the project convention):
  - `make assets` — builds the stylesheet in a `node:20-alpine` container.
  - `core/Dockerfile` — a `node` `assets` build stage that runs `npm ci && npm run build`
    and the builder copies the result into `priv/static/assets/app.css` before `mix release`.
    The runtime image stays Node-free.
- The built `core/priv/static/assets/app.css` (~51 KB, full Tailwind + DaisyUI) is committed
  as the source-of-truth artifact (so `make dev` / non-Docker contexts have it); the Docker
  build always regenerates it from `core/assets/`.

## Acceptance Criteria

1. **Given** `make assets` (or a `docker compose build core`), **When** run, **Then** it
   produces `core/priv/static/assets/app.css` containing the full Tailwind + DaisyUI build
   (DaisyUI component classes + the "nebu" theme), not the placeholder stub.
2. **Given** the running stack, **When** `/admin/login` is loaded, **Then** it renders the
   Obsidian dark theme: dark `#111827` background, raised card, orange `#f97316` primary
   button ("Login with SSO"), Inter font — matching the original design.
3. **Given** the AdminEndpoint, **When** `/admin/static/assets/app.css` and
   `/admin/static/fonts/Inter-Regular.woff2` are requested, **Then** both return 200.
4. **Given** the runtime image, **When** inspected, **Then** it contains no Node toolchain
   (assets are built in a separate Docker stage).

## Acceptance Tests

Asset/build story — verification by inspection + the existing admin e2e suite:
- `curl /admin/static/assets/app.css` → 200, ~51 KB, contains `--p:` (DaisyUI) + `color-scheme:dark`.
- Playwright computed-style check on `/admin/login`: `body` background `oklch(.21 … 264)`
  (= `#111827`), primary button `oklch(.70 .187 47.6)` (= `#f97316`), font `Inter`.
- `make build-core` / image build succeeds with the `assets` stage.

## Notes

- DaisyUI v4 emits a single configured theme as `:root` (so `<html data-theme="nebu">` is
  harmless and the colours apply globally).
- JS (`phoenix.min.js` + `phoenix_live_view.min.js` + `app.js`) remains vendored as-is — the
  LiveView socket already connects; this story is CSS/design only. A future story could add
  an esbuild step to the same pipeline.
