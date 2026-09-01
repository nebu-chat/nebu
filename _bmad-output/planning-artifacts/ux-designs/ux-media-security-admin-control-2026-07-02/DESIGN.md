---
name: Media Security & Admin Control — Visual Identity
scope: Cross-epic UX story for media-security-admin-control-epic.md
status: final
updated: 2026-07-02
inherits: ux-design-specification.md (Obsidian / DaisyUI theme "nebu")
sources:
  - _bmad-output/planning-artifacts/ux-design-specification.md
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/media-security-admin-control-epic.md
  - server/assets/tailwind.config.js
  - server/lib/nebu/admin/layouts.ex
colors:
  # Inherited from theme "nebu" (do not redefine — reference only)
  primary: "#f97316"
  primary-hover: "#ea580c"
  primary-content: "#1c1917"
  primary-subtle: "#431407"
  base-100: "#111827"
  base-200: "#1f2937"
  base-300: "#374151"
  base-content: "#f9fafb"
  text-secondary: "#9ca3af"
  success: "#22c55e"
  warning: "#f59e0b"
  status-warn-bg: "#451a03"   # D3: CHANGE the existing tailwind.config.js token (currently #431407) to this, to break the collision with primary-subtle / warning-content
  error: "#ef4444"
  neutral: "#6b7280"
  # NEW — media-state vocabulary (this epic) [D2]
  media-processing: "#f59e0b"      # amber — reserved/quarantined/scanning (reuses warning)
  media-released: "#14b8a6"        # teal — released & downloadable (confirmed token, D6)
  media-infected: "#ef4444"        # red — malware found (reuses error)
  media-blocked: "#fb7185"         # coral — admin_blocked (confirmed token, D6)
  media-terminal: "#6b7280"        # gray — deleted/hard_deleted (reuses neutral)
typography:
  sans: "Inter"
  mono: "JetBrains Mono"      # media_id, file_hash (SHA-256), MXID, ClamAV signature
  scale: [text-caption, text-mono, text-body, text-heading, text-display]
rounded:
  control: "6px"    # buttons, inputs, selects
  card: "8px"       # stat cards, alert items, config sections, detail panels
  pill: "10px"      # badges, nav attention badges, filter pills
spacing:
  base: "4px"
  step: "8px"
  card-padding: "24px"     # p-6
  content-padding: "24px"  # main p-6
components:
  - media-state-badge
  - media-table
  - media-detail-panel
  - confirm-dialog
  - override-dialog
  - settings-section
  - storage-config-section
  - scan-health-stat
  - scan-alert-item
  - nav-attention-badge
  - lifecycle-ladder-editor
  - two-eyes-approval
  - legal-hold-control
  - erasure-request
---

# Media Security & Admin Control — Visual Identity

This is the **visual delta** for the media-admin surface of
`media-security-admin-control-epic.md`. It **inherits** the product-wide
Obsidian design system (DaisyUI theme `nebu`, defined in
`server/assets/tailwind.config.js` and `ux-design-specification.md`) and
specifies only what the six media-admin stories (5, 6, 7, 9, 10, 11) add.
On any conflict, this file wins over a mock; the inherited system wins where
this file is silent.

> **Stack note.** The real Admin UI is Phoenix **LiveView + HEEx**, Tailwind +
> DaisyUI theme `nebu`, under `server/lib/nebu/admin/` — not the "Go Templates"
> some older docs mention. Strict CSP (`script-src 'self'`, no inline JS):
> interactivity is `phx-*` bindings, never inline handlers.
>
> **Implementation path.** `server/lib` is pipeline-protected (CLAUDE.md): every
> screen here lands via `/nebu-pipeline --epic media-security-admin-control` with
> `ui:true`, so the `nebu-agent-ux` a11y gate and the admin-ui Playwright suite
> (`workers:1`, serial, shared DB) fire per story.

## Brand & Style

Ops-grade, dark-first, "leise wenn gut, laut wenn wichtig." A media-security
console is a place an operator visits when something might be wrong — so the
resting state is calm (mostly `media-released` teal and neutral gray) and only
genuine risk (`infected` red, unresolved `critical` alerts) is loud. Every
status is spoken three ways — **color + icon + text** — never color alone.
Technical truth is shown in `JetBrains Mono` (hashes, MXIDs, signatures);
everything else is plain-language German/English, no engine names in UI copy.

## Colors

All colors are CSS custom properties on theme `nebu`. **Never hardcode hex** in
templates — use the DaisyUI/token classes.

**Measured contrast on `base-200 #1f2937` (WCAG 2.1, corrected after review — the
earlier "all inherited tokens verified" claim was WRONG):**

| Token | Hex | As text on base-200 | As filled pill + light text | As filled pill + **dark** text `#1c1917` |
|---|---|---|---|---|
| `media-processing` amber | `#f59e0b` | 6.87:1 ✅ | 2.11:1 ❌ | 7.35:1 ✅ |
| `media-released` teal | `#14b8a6` | 5.90:1 ✅ | 2.42:1 ❌ | 7.03:1 ✅ |
| `media-blocked` coral | `#fb7185` | 5.45:1 ✅ | 2.62:1 ❌ | 6.50:1 ✅ |
| `media-infected` red | `#ef4444` | **3.87:1 ❌** | 3.72:1 ❌ | 4.40:1 ❌ (just under) |
| `media-terminal` gray | `#6b7280` | **3.04:1 ❌** | — | — |

**Normative rules (close C1/C2):**
1. Media-state badges are **filled pills with DARK text `#1c1917`** — set the
   text color in the `media-badge--*` class, never leave it to DaisyUI's light
   default (that's the 2.1–2.6:1 failure).
2. `media-infected` red and `media-terminal` gray **fail as text** on `base-200`.
   Never render state labels/metadata as red/gray *text*; use the filled-pill
   form (dark text) for badges, and `base-content` for body/audit text.
   `media-infected` even as a filled pill with dark text lands at 4.40:1 — for
   the infected badge use a **slightly lighter red** within the hue to clear 4.5,
   or pair it with the ⚠ icon carrying the semantic (icon = non-text 3:1).
3. Any "soft/tinted" badge (token over a low-opacity tint) is **forbidden**
   unless its computed text contrast is re-checked ≥4.5:1 — tinting silently
   erodes the pass.
4. Ship a **token-pair contrast assertion test** so "verify at build time" has an
   owner and a gate.

### Inherited (reference, do not redefine)
`primary #f97316`, `base-100 #111827` (page), `base-200 #1f2937` (surface/
sidebar/cards), `base-300 #374151` (hover/border), `base-content #f9fafb`,
`text-secondary #9ca3af`, `success #22c55e`, `warning #f59e0b`,
`error #ef4444`, `neutral #6b7280`. **D3 (corrected):** the real token is
`status-warn-bg` and its current value `#431407` (`tailwind.config.js:50`)
**collides** with both `primary-subtle` (`:45`) and DaisyUI `warning-content`
(`:30`). Fix = change `status-warn-bg` to `#451a03` in the config; flag this
shared-token edit for the pipeline/security review.

### New — media-state vocabulary [D2]
The epic (Story 5a) deliberately extends the 3-level ops traffic light with
two media-specific hues so "a file is available" and "a file is admin-blocked"
never read as the generic ops green/red. One token per lifecycle group:

| Token | Hue | Media states | Rationale |
|---|---|---|---|
| `media-processing` | amber (`#f59e0b`) | `reserved`, `quarantined`, `scanning`, `scan_failed`* | work in flight / needs attention |
| `media-released` | teal (`#14b8a6`) | `released` | clean **and downloadable** — distinct from ops "OK" green |
| `media-infected` | red (`#ef4444`) | `infected` | malware — highest alarm |
| `media-blocked` | coral (`#fb7185`) | `admin_blocked` | deliberate human block — distinct from malware red |
| `media-terminal` | gray (`#6b7280`) | `deleted`, `hard_deleted` | inert / gone |

\* `scan_failed` renders amber in nav attention badges (Story 7) but is a
terminal-until-rescan state in the table; pair its amber with a distinct icon.

> **Confirmed (D6), contrast-corrected (D7).** teal `#14b8a6` and coral
> `#fb7185` are first-class palette tokens (the Obsidian palette grows by exactly
> these two) and both **pass as text on `base-200`** (5.90:1 / 5.45:1). But
> media badges are **filled pills**, so they carry **dark text `#1c1917`** per
> the normative rules above — teal 7.03:1, coral 6.50:1. Both are net-new
> additions to `theme.extend.colors` in `server/assets/tailwind.config.js`, and
> the `media-badge--*` classes are a **new `@layer components` block** in
> `server/assets/css/app.css` (which today holds only the bare `@tailwind`
> directives) — greenfield, not inherited CSS.

## Typography

Inherits the `nebu` scale unmodified. Media-specific usage:

- **`text-mono` (JetBrains Mono, 0.875rem)** — `media_id`, `file_hash`
  (SHA-256), uploader MXID, ClamAV signature name, `s3_key_prefix_template`
  preview, storage keys. Wrap technical strings in `<code>` / `<span lang="en">`.
- **`text-display` (2.25rem/700)** — the big scan-health numbers (throughput,
  backlog depth, error rate) on the dashboard stat cards.
- **`text-heading` (1.5rem/600)** — page title ("Medien", "Scan-Gesundheit"),
  detail-panel section headings.
- **`text-caption`** — timestamps (`uploaded_at`, `scanned_at`, "down seit"),
  table metadata, hint text.
- Table rows and badges: `text-sm` minimum for anything interactive.

## Layout & Spacing

Inherits the admin shell (`layouts.ex`): topbar `h-12 bg-base-300`, left
`nav.w-60 bg-base-200`, `main#main-content.overflow-auto.p-6`. Media screens
live **inside** this shell — no new chrome.

- **`/admin/media`** — full-width list. Filter bar on top (`space-4` gaps),
  then the media table. Optional scan-health strip (Story 10) either above the
  filter bar as `grid grid-cols-1 sm:grid-cols-3 lg:grid-cols-4 gap-4` stat
  cards, or on its own `/admin/media/health` route.
- **`/admin/media/:id`** (detail) — **master-detail 3-column** grid (the
  inherited Matrix pattern, D6): media list (~300px, the filtered
  `/admin/media` result) · fluid detail panel (metadata + storage card, then
  the audit trail as a vertical timeline of state transitions) · optional
  context rail collapses below `lg:`. The open file's id lives in the URL so a
  single file is directly bookmarkable/shareable. Below `md:` it degrades to
  the stacked single-column detail.
- **`/admin/media/settings`** — self-constrained `max-w-2xl`, single column
  (Don't: multi-column admin forms). Sections stacked with `space-8`:
  *Upload & Limits* → *Retention* → *Notifications (webhook)* → *MIME policy* →
  *Object Storage* (Story 11). Explicit **Save** per section; no auto-save.
- **`/admin/media/approvals`** (Story 13d, gap filled 2026-07-11 — no layout
  existed for this route before) — full-width, **single table, no filter bar**:
  a `compliance_officer` works one bounded queue of pending terminal-delete
  requests, not a filtered search, so the filter-bar chrome from `/admin/media`
  does not belong here. Page heading + one explanatory line above the table
  ("Löschanfragen, die eine zweite Freigabe benötigen."). Empty state: calm
  "Keine ausstehenden Löschanfragen." (no red, no icon of alarm — an empty
  queue is a good state, not a degraded one, same register as Scan-Gesundheit's
  "Alles ruhig").
- Spacing: `p-6` card padding, `space-6` between fields, `space-8` between
  sections, matching `/admin/config`.

## Elevation & Depth

Depth via the `base-100 → base-200 → base-300` background stack + `1px` borders.
(Correction, D7: shadows *do* exist in the codebase — `shadow-sm` on the
dashboard stat card, `shadow` on login/bootstrap. The border-only choice for new
media cards is a **deliberate** rule, not a claim that no shadow scale exists.)

The `StatusCard` / `AlertItem` / `MasterListItem` patterns referenced below live
in `ux-design-specification.md`, **not** in the codebase — they are **greenfield
components to build following the spec**, not inherited code to reuse (D7).

- Stat / detail cards: `card bg-base-200` + `1px` `base-300` border.
- **Scan-alert item:** `3px` **left-border** in `media-infected` (critical) or
  `warning` (warning) — follows the spec's `AlertItem` (greenfield).
- **Scan-health stat card:** `3px` **top-border** in the status color (green
  when healthy, amber degraded, red when ClamAV down) — follows the spec's
  `StatusCard` (greenfield).
- **Confirm / override dialog:** greenfield. Use `base-200` panel + `1px`
  `base-300` border + `backdrop-blur` scrim over the LiveView. No box-shadow.

## Shapes

Inherited radii, formalized as tokens (see frontmatter `rounded`): `6px`
controls, `8px` cards/sections/dialogs, `10px` pills. State badges are full
pills (`10px`). Status dots and any avatar remain circular. The active
nav-item keeps its `3px` primary left-accent bar; nav attention badges are
`10px` pills placed inline-right of the nav label.

## Components

Behavioral specs live in EXPERIENCE.md; here are the **visual** definitions.
Reuse DaisyUI primitives already in the codebase; only the media-state badge
and the dialogs are genuinely new.

> **Visual reference (illustrative only, spine wins on conflict):**
> [`mockups/key-media-list.html`](./mockups/key-media-list.html) ·
> [`key-media-detail.html`](./mockups/key-media-detail.html) ·
> [`key-media-health.html`](./mockups/key-media-health.html) ·
> [`key-media-settings.html`](./mockups/key-media-settings.html) ·
> [`key-media-approvals.html`](./mockups/key-media-approvals.html). Legal-Hold
> and Erasure-Request badges are not yet rendered — no hex assigned, see
> `.decision-log.md` D9.

### media-state-badge
`<span class="badge badge-sm media-badge--{group}">` = **filled pill, token
background, dark text `#1c1917`** (set in the class — see Colors C1) + a leading
**icon-font/SVG glyph** bound to the token color and marked `aria-hidden="true"`
(the text label carries the meaning) + the visible label. **No emoji** for status
(screen readers announce "orange circle"/"no entry", not the state; and emoji
color is OS-controlled, uncheckable — D7/M1). One `media-badge--*` class per state
group (processing/released/infected/blocked/terminal), authored in the new
`@layer components` block. **Icon + text always** (colorblind rule). Labels:
"Wird geprüft" (scanning), "Freigegeben" (released), "Infiziert" (infected —
lighten the red to ≥4.5:1 or lean on the ⚠ glyph), "Gesperrt" (admin_blocked),
"Gelöscht" (deleted).

### media-table
DaisyUI `table table-zebra` inside `<div class="overflow-x-auto">` (the
config/compliance convention, not the plain-table one). **Every** `<th>` gets
`scope="col"` (closes the gap seen on config/compliance/audit tables). Columns:
state-badge · filename · uploader (mono MXID) · MIME · size (human) ·
`uploaded_at` · `scanned_at` · ClamAV signature · actions. `<caption class="sr-only">`.
Row carries `data-role="media-row"` + `data-media-id` + `data-state` hooks
(E2E-stable). Below `768px`, rows collapse to label-value cards (inherited
Atlas mobile behavior).

### media-detail-panel
**Master-detail 3-column** (D6) — a **greenfield** responsive layout following
the spec's Matrix pattern (no such layout exists in code yet; estimate as new
build). A ~300px master list of links/buttons (`base-200`); the active item
carries `aria-current="page"` **and** the `3px` primary left-accent (the accent
is decorative, `aria-hidden`), beside a fluid detail `card bg-base-200 p-6` that
is a labelled region (`aria-labelledby` the filename heading). The detail card holds a metadata grid (mono
hash/size/MIME), a storage-bytes line (active vs pending-hard-delete, reported
separately), then the audit trail — a compact `table table-zebra` or `divide-y`
timeline of `media_state_transitions` (actor, from→to, reason, timestamp).
Collapses to single-column stack below `md:`.

### confirm-dialog (Delete / Hard-Delete / Kill-switch)
Greenfield LiveView modal (`phx-click`, CSP-safe — not `window.confirm`).
`role="dialog"`, `aria-modal="true"`, focus-trap, Escape closes, auto-focus on
**Cancel**. `base-200` panel, `backdrop-blur` scrim. Danger action = `btn`
with `media-infected`/`error` colors. **Hard-Delete** is High-tier: shows the
"irreversibel — kein Recovery" consequence line and (for cohorts) the affected
count. Follows the inherited tiered ConfirmDialog.

### override-dialog (Infected → Released, Story 6c)
Highest-tier variant of confirm-dialog. Escalated red header, the **mandatory
free-text reason** field (non-empty, `aria-required`), and the exact warning
copy: *„Diese Datei wurde als Malware erkannt. Freigabe erfolgt auf eigene
Verantwortung."* Confirm button disabled until reason is non-empty. Only
rendered for the `media_admin_override` role.

### settings-section / storage-config-section
**Visually** mirror `/admin/config` (`form-control` wrapper,
`input input-bordered` / `select select-bordered`, `label-text-alt` hint — these
classes are real). **Interaction diverges (D7/M3):** `/admin/config` is a
dead-controller POST-reload form with DB-backed prefill and no live validation;
the media settings page is a **new LiveView** so it can do per-section save +
live inline validation (`aria-invalid`/`aria-errormessage`). Prefill is
**env-var read-once** as the migration path the epic specifies (Story 9b/11b,
`NEBU_MINIO_*` still a fallback) — distinct from `/admin/config`'s DB prefill; do
not conflate, and keep it reconciled with ADR-022 (env only for the one-time
media/storage migration, then DB-authoritative). Secret fields (`access_key`,
`secret_key`) render masked (`type="password"`) with a show/hide toggle — a
`<button aria-pressed>` with a dynamic accessible name ("Passwort
anzeigen"/"verbergen"); never echo stored secret values. "Test Connection"
button (Story 11) sits beside the storage fields with an inline result pill
(pending spinner / green success / red failure) **before** Save. Escalated
inline warning banner (`3px` left-border `warning`) when
`released_delete_after_days` goes `nil → value` or when endpoint/bucket changes
with existing media.

### scan-health-stat / scan-alert-item
`stat`-style cards (`text-display` number, `text-caption` label) with a `3px`
status top-border. Alert items stack unresolved-first with a `3px` left-border
(critical=red, warning=amber), `role="alert"` (critical) / `role="status"`
(warning), and persist until auto-resolved. **Color is never the sole signal
(D7/H6):** every alert carries a severity **word** ("Kritisch"/"Warnung") + icon;
every health card shows a status **word** ("Gesund"/"Beeinträchtigt"/"Nicht
erreichbar"), not just a colored border. The storage "Test Connection" result is
an icon + word pill ("Erreichbar"/"Fehlgeschlagen"), never a bare colored
dot/spinner.

### nav-attention-badge
`10px` pill inline-right of the media nav label. `media-infected` for infected
count, `warning` amber for `scan_failed` + backlog. Icon or `sr-only` text so
it isn't color-only; `aria-live="polite"` so PubSub updates announce.

### lifecycle-ladder-editor (Story 13b, greenfield)
An ordered vertical ladder of rung cards (`card bg-base-200` + `1px` border,
radius `8px`), each with a state-transition label + a duration `input`. Rungs use
the media-state badge vocabulary for their endpoints. A drag/reorder handle is a
real `<button>` (keyboard-reorderable), not a drag-only affordance. High-blast
rungs render the escalated inline warning banner (`3px` left-border `warning`).

### two-eyes-approval (Story 13d, greenfield)
A queue list (`table table-zebra` in `overflow-x-auto`, `<th scope="col">`) of
pending terminal deletes: target file (its current `media-state-badge`, for
context) · requester (mono MXID) · reason · request time · Approve/Reject
actions. Self-requested rows show a disabled, **explained** state ("Eigene
Anfrage — Freigabe durch zweite Person") instead of the two buttons.

**Approve dialog** — a confirm-dialog variant with the **mandatory-reason**
field pattern override-dialog established (non-empty, `aria-required`,
confirm **enabled** + inline error on empty submit per H4/H5), but its **header
is neutral** (`base-content` on `base-200`, not the escalated red override-dialog
uses) — a compliance-approved hard-delete is not a malware alarm, and Do's/Don'ts
already says red is reserved for real malware. The confirm **button** still
carries the `media-infected`/`error` danger color (Hard-Delete is irreversible),
same as the plain confirm-dialog's danger tier — only the header escalation is
withheld, not the destructive-button color.

**Reject dialog** — the plain confirm-dialog tier, **optional** reason
(EXPERIENCE.md is silent on requiring one for a rejection; flagged as a gap
call, not spec text — confirm with Phil before Story 13d dev).

### legal-hold-control (Story 13e, greenfield)
A detail-view pin toggle (`<button aria-pressed>`), plus a distinct
`media-blocked`-adjacent badge (NOT the same as `admin_blocked` — needs its own
glyph + "Legal Hold" text so the two don't read alike). Release routes through
two-eyes-approval, never a direct toggle-off.

### erasure-request (Story 13e, greenfield)
A detail-view action button opening a dialog whose body explains
Restriction-of-Processing (dark, informational, not the red malware-override
treatment). Sets the "Eingeschränkt · Löschung terminiert" badge — its own
neutral-but-distinct treatment, never the `media-terminal` "Gelöscht" gray (bytes
are NOT gone yet).

## Do's and Don'ts

**Do**
- Status = **color + icon + text**, every media badge, every alert.
- Keep the resting console calm — teal/gray dominate; red only for real malware.
- Reuse `table table-zebra` + `overflow-x-auto` and set `<th scope="col">` on
  every header (fix the inherited gap).
- Mono-font every technical string (`media_id`, SHA-256, MXID, signature).
- Mask secret storage fields; never render stored `secret_key`/`access_key`.
- Verify the two new hues at **≥4.5:1 on `base-200`** before shipping.

**Don't**
- Don't hardcode hex — use theme tokens / `media-badge--*` classes.
- Don't reuse ops `success` green for `released` (that's what teal is for) or
  ops `error` red for `admin_blocked` (that's what coral is for) [D2].
- Don't use `window.confirm` for the new media dialogs — CSP-safe LiveView
  modals only.
- Don't auto-save settings; explicit Save per section, like `/admin/config`.
- Don't put a multi-column form on the settings page.
- Don't rename or drop existing `data-role`/`data-page`/`data-section` hooks —
  they are E2E acceptance guards; additive only.
