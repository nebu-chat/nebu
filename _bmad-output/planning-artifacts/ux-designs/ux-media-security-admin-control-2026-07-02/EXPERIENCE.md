---
name: Media Security & Admin Control — Experience Contract
scope: Cross-epic UX story for media-security-admin-control-epic.md
status: final
updated: 2026-07-02
design_ref: ./DESIGN.md
sources:
  - _bmad-output/planning-artifacts/ux-design-specification.md
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/media-security-admin-control-epic.md
  - server/lib/nebu/admin/layouts.ex
  - e2e/playwright.config.ts
---

# Media Security & Admin Control — Experience Contract

How the media-admin surface **behaves**. Visual identity is in
`{DESIGN.md}`; this file references its tokens by name. On conflict, both
spines win over any mock. Scope: the cross-cutting experience shared by epic
stories 5 (Overview), 6 (Actions), 7 (Notifications), 9 (Settings),
10 (Scan Health), 11 (Storage Config) — so no single story reinvents IA,
states, or accessibility.

## Foundation

- **Form factor:** desktop-first web, inside the existing Nebu Admin shell
  (`server/lib/nebu/admin/layouts.ex`) — topbar + `w-60` sidebar + `p-6` main.
  Down to `<768px` tables collapse to cards; the console stays usable on a
  tablet an operator grabs off-hours.
- **UI system:** Phoenix **LiveView + HEEx**, Tailwind + DaisyUI theme `nebu`.
  Real-time is **Phoenix.PubSub over the LiveView socket** — *not* the Vue+SSE
  model older docs describe [D1]. Strict CSP (`script-src 'self'`): all
  interactivity via `phx-*`, no inline JS, no `window.confirm` for new dialogs.
- **URL-addressable state (PRD FR50 / NFR-O4):** every view is bookmarkable and
  shareable. Filters, sort, page cursor, active tab, and the open detail id all
  live in the URL (`params` / `push_patch`) — no reliance on socket-only or
  LocalStorage state.
- **Roles (PRD FR4 + epic, incl. Review 5 / Story 13):** `instance_admin` sees
  and operates the whole surface and *initiates* destructive actions;
  `compliance_officer` is the **second pair of eyes** — the only role that can
  *approve* a Two-Eyes terminal delete (Story 13d), release a Legal-Hold, or
  action an Art.-17 erasure request (13e). So `compliance_officer` **edits**
  (approves), not merely reads. The `media_admin_override` role is the only role
  that may release infected media (Story 6c). UI shows only actions the current
  role+state permits — no context-blind action lists.
- **Localization (PRD NFR-L1):** all copy DE + EN, language from OIDC claim /
  profile — no manual toggle. Reference strings below are German (primary).

## Information Architecture

The epic introduces a media-security domain that has **no home in today's
sidebar**. Add it as its own concern rather than burying it under System.

**Review 9 update (2026-07-10):** the sidebar rebase picked up the
`admin-sidebar-nesting` pattern already shipped for "Logs" and "Configuration"
(`Nebu.Admin.Layouts.nav_item/1` — a real `<button aria-expanded aria-controls>`
disclosure toggle with a chevron, children always in the DOM, collapse via the
`hidden` attribute, wired CSP-safely by `wireNavSectionToggles()`). "Medien"
adopts the same shape instead of a flat single link — one parent, four visible
children:

```
VERWALTUNG
  👤 Benutzer            /admin/users
  💬 Räume               /admin/rooms
  🖼  Medien  ▾  [badges]                       ← Parent: pure disclosure toggle, does not navigate itself
       Übersicht         /admin/media           (the former hub table, Story 5; filter incl. Legal-Hold + "Löschung ausstehend")
       Health        •   /admin/media/health    (scan health — dedicated route, Story 10; dot = unresolved critical alert)
       Settings           /admin/media/settings  (policy + storage + Lifecycle-Rules ladder-editor, Story 9/11/13b)
       Approvals         /admin/media/approvals (Two-Eyes-Delete queue, compliance_officer approves, Story 13d)
COMPLIANCE
  📋 Audit Log           /admin/audit           ← media actions, overrides, two-eyes approvals, erasures surface here (AuditLogLive)
```

`/admin/media/:id` stays a **drill-down**, not a nav entry (same convention as
every other detail page) — reached from "Übersicht", never from the sidebar
directly.

- **Attention badges** move to the **parent** "Medien" button, exactly the
  existing `nav-attention-badge` pattern (Story 5b/7) just relocated: `infected`
  count in `{colors.media-infected}`, `scan_failed` + backlog in
  `{colors.warning}` — visible even while the group is collapsed, updated live
  via PubSub, never requiring a reload. The **"Health"** child additionally
  gets a small dot when an unresolved `critical` `media_alerts` row exists —
  the exact reuse of the War-Room "recording" dot convention already shipped
  under "Logs" → "War Room" (an additive `:dot` flag on one named child, zero
  effect on the others).
- **`/admin/media` (Übersicht)** is the hub: table + filters. **`/admin/media/health`**
  is a **dedicated route** (D6), not a strip on the overview — so an operator can
  bookmark it as a favorite ("is the scan pipeline healthy right now?") and,
  because every filter/alert view is URL-addressable, paste a link to a
  specific problem straight to a colleague. From here, an unresolved critical
  alert also offers **"Live-Diagnose starten"**, jumping into a media-scoped
  War Room session (Story 10e) for real-time, bounded diagnostic log capture —
  a deliberate escalation path above the hourly `media_scan_stats` rollup, not
  a replacement for it. **`/admin/media/:id`** is the per-file **master-detail**
  view with full audit trail. **`/admin/media/settings`** holds media policy
  (Story 9) and object-storage config (Story 11) as stacked sections, mirroring
  `/admin/config`'s own nested "General" child.
- **Story 13 (Review 5 / ADR-030) surfaces:** the **Lifecycle-Rules ladder-editor**
  (13b) is a section on `/admin/media/settings` — an S3-style ordered ladder of
  rungs (`released → deleted → hard_deleted`, with `infected`/`orphaned` inputs)
  the operator configures; setting a rung that mass-auto-deletes released files
  carries the same escalated warning as `released_delete_after_days`. **Legal-Hold**
  is a per-file pin (Story 13e) shown as a badge + detail control; a held file is
  exempt from all lifecycle auto-deletion and leaves the hold only via a Two-Eyes
  release. The **Two-Eyes-Delete approval queue** (13d) lists deletions an
  `instance_admin` requested that await a `compliance_officer`'s second approval.
- IA closes: every media story (0, 5–13) lands on one of these surfaces; every
  surface has a flow below that reaches it.

## Voice and Tone

Inherits the Obsidian microcopy law (brand voice lives in
`{DESIGN.md}` → Brand & Style). Media-specific rules:

- **Functional, not technical.** "Wird geprüft", "Freigegeben", "Infiziert",
  "Gesperrt", "Gelöscht" — never "quarantined ENUM" or "ClamAV EICAR match".
  ClamAV appears only where it *is* the subject (signature name, "Virenscanner
  nicht erreichbar").
- **Three-part errors** (was / warum / was-jetzt): e.g. *"Verbindung zum
  Objektspeicher fehlgeschlagen · Endpoint nicht erreichbar · Endpoint/Port
  prüfen und erneut testen."*
- **Destructive actions get an informed pause.** The Override warning copy is
  fixed and must appear verbatim: *„Diese Datei wurde als Malware erkannt.
  Freigabe erfolgt auf eigene Verantwortung."* Hard-Delete states
  *"irreversibel — die Bytes werden gelöscht, der Nachweis-Datensatz bleibt."*
- **No bare "Pending".** A file in `scanning` reads *"Wird geprüft — Ergebnis
  in Kürze"*; a stuck scan reads its next step, not silence.

## Component Patterns (behavioral)

Visual specs are in `{DESIGN.md}`; here is behavior.

- **media-table** — server-driven filter/sort/paginate. Filters (state
  multi-select, MIME-prefix, uploader search, `uploaded_at` range) apply live
  (no Apply button) and write to the URL. Cursor pagination, 50/page, via a
  "Weitere laden" control (keyset, no OFFSET) — the inherited Load-More
  pattern, since no pagination UI exists yet. Rows update **individually** via
  PubSub (a new quarantine or a finished scan re-renders only that row).
- **media-state-badge** — pure display; state → group per `{DESIGN.md}` table;
  color + icon + text always.
- **row actions** — rendered **conditionally by state + role** (Block only from
  `released`; Unblock only from `admin_blocked`; Rescan only from `quarantined`/
  `scan_failed`; Override only from `infected` **and** `media_admin_override`).
  Block/Unblock are idempotent and fire **without** a dialog (info flash on
  no-op). Delete, Hard-Delete, Override, Kill-switch open a dialog.
- **confirm-dialog / override-dialog** — LiveView modals. Focus moves into the
  dialog on open, returns to the trigger on close; Escape cancels; the
  destructive button is never the default focus. Override's confirm stays
  disabled until the reason is non-empty.
- **settings-section** — explicit Save per section; server-side bounds
  validation (no negatives, min/max) with inline field errors
  (`aria-invalid` + `aria-errormessage`). Env-var prefill on first load. Each
  saved change emits an audit entry.
- **scan-health-stat / scan-alert-item** — read from the rollup table, refresh
  live; unresolved alerts pinned on top and auto-clear when the condition ends.
- **nav-attention-badge** — live counts; `aria-live="polite"`.
- **lifecycle-ladder-editor** (13b) — an ordered, S3-style ladder of rungs
  (`released → deleted → hard_deleted`, plus `infected`/`orphaned` inputs) with a
  duration per rung. Keyboard-reorderable; each rung validated (no negatives,
  bounds). Any rung that would mass-auto-delete never-flagged `released` files
  triggers the escalated warning + explicit confirm before save.
- **two-eyes-approval** (13d) — a queue of pending terminal deletes. Each item
  shows requester, target file, reason, request time. The approving
  `compliance_officer` gets Approve/Reject; **cannot approve own request**
  (self-approval blocked and explained, not silently hidden). Approve opens a
  confirm dialog with a mandatory rationale (enabled button + inline error, per
  H4). Both request and approval are audited.
- **legal-hold-control** (13e) — a per-file pin toggle on the detail view; setting
  it exempts the file from lifecycle auto-deletion; **releasing** it requires a
  Two-Eyes approval. State surfaced as a badge + a `/admin/media` filter.
- **erasure-request** (13e) — a detail-view action that records an Art.-17
  request; its dialog states plainly this is a *Restriction-of-Processing*
  (immediate invisibility, bytes retained under any statutory duty), not an
  instant delete. Sets the "Eingeschränkt · Löschung terminiert" state.

## State Patterns

Two state families. **(A)** the media lifecycle (domain) and **(B)** the UI
states every surface must handle.

### A. Media lifecycle (drives every badge — epic State Machine)
`reserved → quarantined → scanning → {released | infected | scan_failed}`;
admin overlay `released ↔ admin_blocked`, `* → deleted → hard_deleted`,
`infected → released` (override). External download gate an operator should
understand at a glance: `released` = 200 (downloadable), processing +
`admin_blocked` = 451, `infected`/`deleted`/`hard_deleted` = 404. The
`media_files` record is **never** deleted — after hard-delete the detail view
still shows `file_hash` + timestamps with `storage_key`/`uploader` nulled.

**Overlays (Story 13 / ADR-030), orthogonal to the lifecycle state:**
- **Legal-Hold** — a per-file pin that exempts a file from *all* lifecycle
  auto-deletion; a held file can only be released via a Two-Eyes approval. Shown
  as a distinct badge + filter; visually must not be mistaken for a lifecycle state.
- **Art.-17 Erasure = Restriction-of-Processing** (13e), not immediate deletion:
  an erasure request makes the file **immediately invisible/undownloadable**
  (restriction) while bytes are *retained* where a statutory retention duty applies
  (Art. 17(3): HGB §257 / AO §147). Physical deletion happens later, compliance-clean,
  and **only** through the Two-Eyes gate (13d). The UI must communicate this as
  "gesperrt/eingeschränkt, Löschung terminiert" — never as "gelöscht" — so an
  operator doesn't believe the bytes are already gone.

### B. UI states (every surface)
- **Empty:** `/admin/media` with no media → EmptyState "Noch keine Medien
  hochgeladen." Filter with no match → "Keine Treffer — Filter anpassen."
  No alerts → the health dashboard shows a calm "Alles ruhig" green state.
  `/admin/media/approvals` with nothing pending → calm "Keine ausstehenden
  Löschanfragen." — an empty queue is the good state here, same register as
  "Alles ruhig", not a degraded/error look.
- **Loading:** skeleton rows / `animate-pulse` on `{colors.base-300}` while the
  first query or rollup read resolves.
- **Live update:** row/badge/metric mutates in place via PubSub; announce
  material changes (new infected) politely, don't steal focus.
- **Error:** table query, connection test, or save failure → inline three-part
  error, retry affordance, never a dead end.
- **Degraded pipeline:** ClamAV down → health card flips red with "nicht
  erreichbar seit {ts}"; backlog grows; if kill-switch is `fail_closed`,
  uploads visibly return 503 and the settings page reflects the active mode.
- **Permission:** a viewer without `media_admin_override` never sees the
  Override action (hidden, not merely disabled).

## Interaction Primitives

- **Live, not polled** — PubSub row/metric updates; no manual refresh button as
  the primary path.
- **URL as state** — filter/sort/cursor/tab/detail-id in the URL; back/forward
  and bookmarking work.
- **Idempotent quick-actions** — Block/Unblock act immediately + info flash;
  reversible, so no ceremony.
- **Gated destructive actions** — Delete/Hard-Delete/Override/Kill-switch
  require a dialog; the irreversible ones state their blast radius (count,
  "no recovery").
- **Test-before-commit** — storage config offers "Verbindung testen"
  (head_bucket) with a visible result *before* Save; changing endpoint/bucket
  with existing media warns with the affected count first.
- **Everything is audited** — Block/Unblock/Delete/Hard-Delete/Override and
  every settings change write to `media_state_transitions` and, for the
  compliance-relevant ones, the global append-only audit log (surfaced in
  `AuditLogLive`).

## Accessibility Floor (behavioral)

Hard constraints — **WCAG 2.1 AA** (PRD NFR-A1, legally required for DE/EU
public bodies). Visual contrast lives in `{DESIGN.md}`.

- **Keyboard-complete (NFR-A2):** every action reachable and operable by
  keyboard — row actions, filters, pagination, dialogs. No mouse-only path.
- **Screen-reader (NFR-A3):** semantic HTML; `table` with `<th scope="col">`
  and `<caption class="sr-only">`; row actions are real `<button>`/`<a>`;
  status badges expose text (not color alone).
- **Focus management:** dialogs trap focus and restore it to the trigger on
  close; live row updates must **not** move focus.
- **Live regions:** nav attention badges and new-infected announcements use
  `aria-live="polite"`; a critical ClamAV-down alert may use `role="alert"`.
- **Forms:** visible `<label for>` (not `aria-label`-only), `*` required marker,
  `aria-invalid` + `aria-errormessage` on validation failure, hint via
  `label-text-alt`.
- **Uniform focus ring:** `focus-visible:ring-2 ring-primary ring-offset-2
  ring-offset-base-200`, matching nav.
- **Colorblind:** every media state = color **+** icon **+** text.

### Post-review hardening (D7 — WCAG lens, normative)
These pin down the dynamic behaviors the floor above named only in principle.
- **Master-detail is programmatically exposed (C3, WCAG 1.3.1/4.1.2):** the
  master list is real links/buttons; the selected item carries
  `aria-current="page"` (not just the accent bar); the detail region is
  `aria-labelledby` the filename heading; on selection, move focus to the detail
  heading **or** announce the change politely. The accent bar is `aria-hidden`.
- **PubSub row updates preserve focus (H1, 2.4.3):** use `phx-update="stream"`
  with stable per-row DOM ids; a re-render updates text/badge **in place** and
  never destroys the focused interactive element. E2E: focus a row action, push
  a row update, assert `document.activeElement` unchanged.
- **Live results are announced (H2, 4.1.3):** a visually-hidden
  `aria-live="polite"` node reports the count on every filter/sort change
  ("14 Medien gefunden" / "Keine Treffer — Filter anpassen").
- **"Weitere laden" (H3, 4.1.3/2.4.3):** after append, move focus to the first
  new row (or keep it on the button + announce "50 weitere geladen, 100 von 240").
- **Dialogs — one rule for all four (Delete, Hard-Delete, Override, Kill-switch)
  (H4/H5, 2.4.3/3.3.1):** on open, focus the first interactive element that is
  **not** the destructive action (the reason field where one exists, else Cancel);
  trap + restore + Escape + visible Cancel; scrim-click is convenience only, never
  the sole close path. The override/erasure confirm button stays **enabled** — on
  submit with an empty reason, block and surface an inline field error
  (`aria-invalid` + `aria-errormessage`, focus to the field). Never gate a legally
  required reason behind a disabled button (SR users find a dead control).
- **Status never color-only beyond badges (H6, 1.4.1):** alert items carry a
  severity word + icon; health cards a status word; the storage-test pill an icon
  + word.
- **Required fields (M2, 3.3.2):** `*` marker **plus** `aria-required="true"` and a
  visible "* = Pflichtfeld" legend.
- **Announcement politeness (M7, 4.1.3):** nav count badges `polite`; a discrete
  "neue infizierte Datei erkannt" event is `assertive`/`role="alert"`; ClamAV-down
  is `role="alert"` (must, not may).
- **Language (M5, 3.1.1/3.1.2):** `<html lang>` reflects the active DE/EN locale;
  hashes/MXIDs/keys are `<code>` (character/spell mode), not `lang="en"` prose tags.
- **Icon-mode nav (M6):** collapsed sidebar keeps an `sr-only` label on "Medien"
  and `sr-only` text on the attention badge ("1 infizierte Datei").
- **Reduced motion (L1):** skeleton `animate-pulse` and spinners gated behind
  `motion-safe:` / `prefers-reduced-motion`.

## Key Flows

> **Visual reference (illustrative only, spine wins on conflict):**
> [`mockups/key-media-list.html`](./mockups/key-media-list.html) (Flow 1
> steps 1-2) · [`key-media-detail.html`](./mockups/key-media-detail.html)
> (Flow 1 step 3 + Flow 2 override-dialog) ·
> [`key-media-health.html`](./mockups/key-media-health.html) (degraded-pipeline
> state) · [`key-media-settings.html`](./mockups/key-media-settings.html)
> (Flow 3 retention warning + Flow 4 storage test/warning) ·
> [`key-media-approvals.html`](./mockups/key-media-approvals.html) (Flow 5,
> steps 3-4 — the queue + the Approve dialog as an alternate state).

### Flow 1 — Kai triages an infected upload (Stories 5, 6, 7)
Kai (34, DevOps for a municipality, works entirely in the browser, no CLI)
opens the admin dashboard with his morning coffee. The **Medien** parent nav
button carries a red **1** — a PubSub push landed while the page was open,
visible even with the group collapsed (Review 9: badge lives on the parent).

1. He clicks **Medien** to expand the group (Space/Enter both work, pure
   disclosure — no navigation), then **Übersicht**. `/admin/media` loads; he
   filters state = *Infiziert* (filter reflected in the URL, so he can paste
   it to a colleague).
2. One red **Infiziert** row: a `.docx` from `@intern:muni.de`. He clicks it.
3. **`/admin/media/:id`** shows the SHA-256 (mono), the ClamAV signature name,
   and the full audit trail: `quarantined → scanning → infected`, timestamps,
   actor `system`.
4. He confirms it's genuine malware — no override needed. It's already
   un-downloadable (404 at the gate). He clicks **Löschen**; the confirm dialog
   states the consequence; he confirms.
5. **Climax:** the row's badge flips to **Gelöscht** *in place* via PubSub, the
   nav red **1** clears to zero, and the action lands in the global audit log
   (visible later in `AuditLogLive`). Kai never touched a terminal — the whole
   incident was one calm, auditable minute in the browser (PRD Journey 4).

### Flow 2 — the false-positive override (Story 6c, restricted role)
An engineer reports a clean build artifact was flagged. Kai lacks
`media_admin_override`, so he escalates to Sati-the-operator... to **Mara**, a
senior admin who holds it.

1. Mara opens the file's detail. Because she has `media_admin_override`, an
   **Freigeben (Override)** action is present — Kai never saw it.
2. She clicks it. The **override-dialog** opens, red header, the fixed warning
   *„Diese Datei wurde als Malware erkannt. Freigabe erfolgt auf eigene
   Verantwortung."*, and a **mandatory reason** field. The confirm button is
   disabled.
3. She types "False positive — signierter CI-Build, Hash gegen Pipeline
   verifiziert." The button enables.
4. **Climax:** on confirm, state goes `infected → released`, the badge turns
   teal, the reason is written to `media_state_transitions` **and** the global
   audit log with her actor id — the override is permanently attributable. The
   file is downloadable (200) again.

### Flow 3 — Dr. Petra tightens retention safely (Stories 9, 8d)
Dr. Petra (52, `compliance_officer`) must enforce a new data-minimization rule:
released media older than 90 days should auto-delete.

1. She opens **/admin/media/settings**, Retention section (env-prefilled,
   explicit Save, mirroring `/admin/config`).
2. She sets `released_delete_after_days` from *(aus)* to `90`.
3. **Climax:** because this toggles mass auto-deletion of never-flagged files,
   an **escalated warning banner** appears before Save — it names the blast
   radius ("betrifft alle freigegebenen Dateien älter als 90 Tage") and demands
   an explicit confirm. She reads it, confirms, saves. The change writes
   `media_config_updated {key, old:nil, new:90}` to the audit log. No silent
   one-field edit of a high-impact policy.

### Flow 4 — repointing object storage without data loss (Story 11)
Kai migrates the instance to a new MinIO cluster.

1. **/admin/media/settings** → Object Storage section. Secret fields render
   masked; he pastes the new endpoint, bucket, and credentials.
2. He clicks **Verbindung testen** — a `head_bucket` runs; an inline pill shows
   a spinner, then green **Erreichbar**. He hasn't saved yet.
3. He changes the bucket name. **Climax:** a warning appears —
   *"312 bestehende Dateien liegen im alten Bucket und wären nicht mehr
   erreichbar."* (count from `media_files WHERE storage_key IS NOT NULL`). Not a
   hard block, but no silent switch. He copies the data first, then saves;
   the audit entry `media_storage_config_updated` records *which* keys changed —
   never the secret values.

### Flow 5 — an Art.-17 erasure request under a retention duty (Story 13d/13e)
A former employee demands erasure of a file they uploaded. It's a signed contract
scan under a 10-year HGB retention duty, so "delete now" is legally wrong.

1. Kai (`instance_admin`) opens the file's detail and clicks **Löschanspruch
   erfassen (Art. 17)**. He records the request; a dialog explains this is a
   *Restriction-of-Processing*, not an immediate delete.
2. **Climax A:** on confirm, the file goes **immediately invisible/undownloadable**
   (restriction), its badge reads "Eingeschränkt · Löschung terminiert", and a
   Legal-Hold-style pin marks that bytes are retained under HGB §257. The
   requester's right is honored (no further processing) without breaking the
   retention duty. Audited.
3. When the retention duty lapses, the file appears in the **Two-Eyes-Delete
   approval queue** (`/admin/media/approvals`). Kai requested the terminal delete;
   he **cannot** approve his own.
4. Dr. Petra (`compliance_officer`) opens the queue, reviews the request + its
   audit trail, and approves. The confirm button is enabled; her mandatory
   rationale is captured inline (not gated behind a disabled button).
5. **Climax B:** only now does the `MediaLifecycleWorker` hard-delete the bytes —
   `storage_key`/`uploader` nulled, `file_hash` + timestamps retained as the
   compliance record. Both the request (Kai) and the approval (Dr. Petra) are in
   the global audit log: two names, two times, one lawful erasure.

## Inspiration & Anti-patterns

- **Reference:** Synapse's `/_synapse/admin/v1/quarantine_media` is the
  functional peer, but Nebu delivers it **as first-class Admin-UI**, not a raw
  API — richer, auditable, role-gated.
- **Anti-patterns to avoid:** color-only status; `window.confirm` for
  destructive media actions (CSP + a11y); auto-saving policy; a single "Delete
  all infected" bulk button with no per-file audit; hiding *why* a file is
  un-downloadable; renaming E2E `data-*` hooks.

## Responsive & Platform

Desktop-first (operator at a workstation). `lg:` sidebar → icon mode; `md:`
sidebar → bottom tabs, content full width; `<768px` the media table collapses
to label-value cards (inherited Atlas behavior) and the scan-health strip
stacks single-column. Touch targets ≥ 44×44px. No native app surface.

## Resolved Decisions (Phil 2026-07-02)
- **`/admin/media/health` is a dedicated route** — bookmarkable favorite,
  shareable per-problem links. (Not a strip on the overview.) [D6]
- **`/admin/media/approvals` is a dedicated route** — the Two-Eyes-Delete queue
  is its own surface, not a filtered `/admin/media`. [D8]
- **Detail view is master-detail 3-column**; open file id in the URL. [D6]
- **teal `#14b8a6` / coral `#fb7185` first-class tokens**; badges are filled
  pills with dark text (contrast-corrected). [D6/D7]
- **Storage split resolved [D8]:** PostgreSQL holds **runtime data**; media
  **binaries live in S3-compatible object storage (on-prem MinIO — no cloud
  dependency)**. Storing files in Postgres is explicitly rejected. NFR-C3 is
  scoped to runtime data accordingly; NFR-C4 records the object-storage tier as
  state-of-the-art and on-premise-compatible. See `prd.md` NFR-C3/C4.
