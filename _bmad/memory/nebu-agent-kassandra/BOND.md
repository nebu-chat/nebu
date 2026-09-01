# Bond

## Basics
- **Name:** Phil
- **Call them:** Phil
- **Language:** German

## Nebu Architecture — Security Context
**Stack is now a single Elixir/OTP app (`:nebu`), no Go (ADR-021, `grpc-removal` epic).** The old
"Go Gateway + Elixir Core" split is gone — disregard older notes of mine that assume it. Security
boundaries now live in Elixir module namespaces under `server/lib/nebu/`:
- `Nebu.Web` — the single Bandit listener's top router + plugs (OIDC, rate limit, request id). Auth / token-validation boundary.
- `Nebu.Matrix` — Matrix CS API + stateful chat (rooms/sessions/permissions/signing). Command layer is in-process plain modules (`EventDispatcher.Server` raising `Nebu.Matrix.Error`), NOT gRPC anymore.
- `Nebu.Media` — media gateway (upload/download/crypto/storage via ExAws/Finch → MinIO/Stackit object store).
- `Nebu.Admin` — Admin UI (Phoenix LiveView + the converting HTTP controllers) + admin OIDC login + admin DB.
- `Nebu.Compliance` — audit log.
Public-API rule (ADR-020): cross-domain calls only via `Nebu.Matrix` / `Media` / `Admin`. Findings my
older memory attributes to "Go middleware" now map to `Nebu.Web` plugs or the per-controller `Nebu.Admin.Auth` plugs.

## Accepted Risks
{Formally acknowledged security trade-offs with date, justification, and owner sign-off. These are not re-flagged as findings.}

| Risk | Justification | Accepted by | Date |
|------|--------------|-------------|------|
| M_USER_DEACTIVATED confirms account existence to authenticated callers | Matrix CS API v1.18 spec requires M_USER_DEACTIVATED for deactivated accounts; accessible only to callers with valid OIDC JWT; consistent with Synapse/Dendrite behavior | Kassandra (Story 14.4 security review) | 2026-05-17 |

## Sensitive Surfaces
- Auth handlers / token comparison, admin endpoints, migration files, the in-process command layer.
- **Media Gateway Management UI — epic drafted 2026-07-01** (`tmp/media-epic.md`, "Media Security & Admin Control": ClamAV quarantine/scan/release state machine + admin media UI). Pre-implementation design consultation done same day — see [[MEMORY]] "media-security-clamav (WHOLE-EPIC DESIGN consultation)" row for the full watch-list (3 design-HIGH incl. the admin-preview concern below, still unaddressed in the current draft). Original 2026-06-25 flag preserved below — still the high-scrutiny checklist for Story 5/6 when they land:
  - **Attacker-controlled content in the admin same-origin context.** Uploaded files (arbitrary `Content-Type`, filenames, EXIF, SVG) rendered/previewed in the admin UI = stored-XSS + content-injection. Serve previews from a separate sandboxed origin (or `Content-Disposition: attachment` + `X-Content-Type-Options: nosniff` + a tight per-response CSP); never render uploaded HTML/SVG inline in the admin origin. (See Epic 12 patterns in [[MEMORY]]: "Inline Content-Type echoed back with inline disposition", "Unauthenticated media endpoint + unbounded resource".)
    **Partially CLOSED (Story 5a, 2026-07-18):** the `/admin/media` table renders `filename` (Story 2b's
    client-supplied `?filename=`) via plain HEEx auto-escaping only, no preview/thumbnail (AC6 excludes
    it) — regression-tested against a `<script>` payload. The FILE-CONTENT-preview/cross-origin-asset/
    SRI half of this item is still fully open — re-check in full whenever a future story (6b detail-view
    or later) adds an actual preview/thumbnail surface.
    **Re-checked per this note's own trigger (Story 6b, 2026-07-19):** confirmed 6b ships NO
    preview/thumbnail/file-content-rendering surface (pure metadata + transition-history + storage
    aggregates) — nothing here for this item to apply to. Still OPEN, unchanged, for whichever future
    story (6c/6d or later) actually adds a preview.
  - **Cross-origin assets ⇒ SRI + CSP origins.** Once admin UI assets/content come from the object store, the same-origin assumption that makes SRI unnecessary breaks — revisit SRI and pin `script-src`/`img-src`/`connect-src` origins. (See SRI watch-flag row in [[MEMORY]].)
  - **Authz on every media-management endpoint**, not just the trigger — listing/preview/delete each leak or mutate; admin-gate the whole router chain (Epic 14 pattern: "Long-running op progress endpoint needs auth gate").
  - **Destructive cleanup ops** (delete/purge uploads) need audit_log emit + the action name in `AuditWriter.@known_actions`, and ideally a four-eyes / confirmation guard. (Epic 14 patterns: "Bulk operation with no audit_log entry".)
  - SSRF/path-traversal on object-store keys supplied via request params (bucket/key must not be caller-controlled without validation).

## Working Style
{How they prefer findings — inline during PR, structured report, blocking vs advisory separation. What level of detail they find useful.}

## Things They've Asked Me to Remember
{Explicit requests.}

## Things to Avoid
{What annoys them, what doesn't work, what to steer away from.}
