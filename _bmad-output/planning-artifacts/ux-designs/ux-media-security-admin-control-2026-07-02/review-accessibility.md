# Accessibility Review (WCAG 2.1 AA) — media-security-admin-control

Adversarial review of `DESIGN.md` + `EXPERIENCE.md` against PRD NFR-A1 (WCAG 2.1
AA, legally required for DE/EU public bodies), NFR-A2 (keyboard), NFR-A3
(screen-reader). Working assumption: **implementers build exactly what the
contract says and no more.** Everything the contract leaves implicit is scored
as a future violation, because a "verify at build time" note has no owner and no
gate.

---

## Overall verdict

**CONDITIONAL FAIL — not shippable as specified.**

The two headline tokens are fine *as isolated foreground colors* (teal 5.90:1,
coral 5.45:1 on `base-200`, both pass AA). But the contract:

1. **Never specifies badge text color.** A `badge` with the token as *fill* and
   DaisyUI's default light content text lands at **2.42:1 (teal) / 2.62:1
   (coral)** — a hard 1.4.3 failure. The whole "verify ≥4.5:1 on base-200" note
   checks the wrong thing (foreground-on-surface), not the thing an implementer
   will actually build (a filled pill).
2. **Repeats a false claim** that the *inherited* tokens are "verified ≥4.5:1."
   They are not: `error #ef4444` = **3.87:1** and `neutral/terminal #6b7280` =
   **3.04:1** as text on `base-200` both **fail** normal-text AA. "Infiziert"
   and "Gelöscht" label text would be non-compliant.
3. **Under-specifies the two genuinely new, greenfield, a11y-critical surfaces**
   — the LiveView dialogs and the master-detail relationship — precisely where
   there is no inherited implementation to lean on.

The behavioral "Accessibility Floor" section is unusually strong for a UX
contract (focus trap, restore, `th scope`, `aria-live`, visible labels are all
named). The failures are in the *color math*, in the *filled-badge* case, and in
the several dynamic behaviors (live filter results, load-more, PubSub re-render
focus, disabled-submit) that the floor names in principle but does not pin down.

**Counts:** Critical 3 · High 6 · Medium 7 · Low 3.

---

## Computed contrast ratios (sRGB, WCAG 2.1 relative-luminance formula)

Surface for all: `base-200 #1f2937` (relative luminance L ≈ 0.02154).
AA thresholds: **4.5:1** normal text, **3:1** large text (≥18.66px bold /
≥24px) and non-text/UI (icons, borders, graphical objects).

| Foreground | Hex | Ratio on base-200 | Normal text (4.5) | Large / non-text (3.0) |
|---|---|---|---|---|
| **media-released** teal | `#14b8a6` | **5.90:1** | ✅ PASS | ✅ PASS |
| **media-blocked** coral | `#fb7185` | **5.45:1** | ✅ PASS | ✅ PASS |
| media-infected red (inherited `error`) | `#ef4444` | **3.87:1** | ❌ **FAIL** | ✅ pass |
| media-terminal gray (inherited `neutral`) | `#6b7280` | **3.04:1** | ❌ **FAIL** | ✅ pass (barely) |
| media-processing amber (inherited `warning`) | `#f59e0b` | **6.87:1** | ✅ PASS | ✅ PASS |
| success green (reference, not used for media) | `#22c55e` | **6.44:1** | ✅ PASS | ✅ PASS |
| base-content | `#f9fafb` | ≈ **14.9:1** | ✅ PASS | ✅ PASS |

**Filled-badge case** (token as pill background, text on top):

| Badge fill | + light text `#f9fafb` | + dark text `primary-content #1c1917` |
|---|---|---|
| teal `#14b8a6` (L≈0.372) | **2.42:1 ❌ FAIL** | **7.03:1 ✅** |
| coral `#fb7185` (L≈0.340) | **2.62:1 ❌ FAIL** | **6.50:1 ✅** |
| amber `#f59e0b` (L≈0.441) | 2.11:1 ❌ FAIL | 7.35:1 ✅ |
| red `#ef4444` (L≈0.227) | 3.72:1 ❌ (large only) | 4.40:1 ❌ (just under 4.5) |

**Tinted-background case** (DaisyUI "soft" badge: token at low opacity over
base-200, token color as text). Not quantified in the contract, so the effective
background luminance is unknown. Worst realistic case — a ~25% teal tint over
base-200 raises the surface L from 0.0215 to ≈0.11, dropping teal-text contrast
from 5.90:1 to ≈**3.4:1 (FAIL for normal text)**. Coral behaves the same. This
combo is a live risk *because the tint opacity is unspecified.*

Interpretation:
- The two new tokens **pass as text on the raw surface** — good.
- They **fail as filled pills with the default light text** — and a filled pill
  is the most likely reading of `badge badge-sm media-badge--{group}`.
- Red and gray **fail as text even on the raw surface.**
- Any "soft/tinted" badge treatment silently erodes the pass.

---

## Critical

### C1 — Badge text color is unspecified; filled pills fail AA at 2.4–2.6:1
**WCAG 1.4.3 (Contrast Minimum).**
`media-state-badge` is `<span class="badge badge-sm media-badge--{group}">` with
the token bound to a "media-badge--* utility class," but the contract never says
whether the token is the badge's *background* or its *text/border* color, nor
what the text color on a filled badge is. DaisyUI badges default to a filled
background with light content text. Built that way: teal fill + `base-content`
text = **2.42:1**, coral = **2.62:1**, amber = **2.11:1** — all far below 4.5:1.
The "verify ≥4.5:1 on base-200" instruction does not catch this because it tests
foreground-on-surface, not text-on-fill.
*Fix:* Specify the badge treatment explicitly and normatively. Either (a) filled
pill → mandate dark text `primary-content #1c1917` (teal 7.03:1, coral 6.50:1,
amber 7.35:1 all pass) and set it in the `media-badge--*` class, **not** left to
DaisyUI default; or (b) outline/ghost pill → token as **text + 1px border** on
`base-200` (teal 5.90:1, coral 5.45:1 pass — but red 3.87:1 and gray 3.04:1 still
fail as text, see C2). Add a contrast-check to the build (e.g. a token-pair
assertion test) so "verify at build time" has an owner and a gate.

### C2 — "Inherited tokens verified ≥4.5:1" is false for red and gray
**WCAG 1.4.3.**
DESIGN.md §Colors asserts contrast is "verified for the inherited tokens." It is
not. As **text** on `base-200`: `media-infected` red `#ef4444` = **3.87:1** and
`media-terminal` gray `#6b7280` = **3.04:1** — both fail normal-text AA. So the
"Infiziert" and "Gelöscht" badge labels/icons, or any red/gray body text
(signature name in red, "down seit" in gray, audit-trail terminal rows), are
non-compliant if rendered as token-colored text on the surface. Only as a filled
pill with dark text (C1 fix) or as a non-text icon (3:1) do they pass.
*Fix:* Remove the false "verified" claim. Treat red and gray text on `base-200`
as failing and forbid it: render `Infiziert`/`Gelöscht` only as filled pills
with dark text, and set audit-trail / metadata body text to `base-content`, never
to the state token. If a red *text* accent is wanted, darken/lighten it to ≥4.5:1
within the hue (e.g. a lighter red) — the same escape hatch the doc already
offers for teal/coral.

### C3 — Master-detail relationship is only visual; no programmatic exposure
**WCAG 1.3.1 (Info & Relationships), 4.1.2 (Name, Role, Value).**
The detail view is a 3-column master-detail. The contract exposes the active
master row **only** as "the `3px` primary left-accent" — a pure color/visual cue.
There is no `aria-current`, no announced relationship between the master list and
the detail panel, and no statement of what a screen-reader user hears when a row
is activated and the detail region swaps content via `push_patch`. A blind
operator cannot tell which file is selected, nor that the right-hand panel now
describes it. This is the core interaction of Story 6 and it is inaccessible as
specified.
*Fix:* Specify: master list is a real list of links/buttons (each navigates to
`/admin/media/:id`); the active item carries `aria-current="page"` (not just the
accent bar); the detail panel is a labelled region (`aria-labelledby` the file
name heading) and receives a focus move or a polite live announcement on
selection so the change is perceivable; the accent bar is decorative
(`aria-hidden` reinforcement). State this alongside the visual accent, not
instead of it.

---

## High

### H1 — Live PubSub row re-render will silently drop keyboard focus
**WCAG 2.4.3 (Focus Order), 2.4.7 (Focus Visible), 3.2.5.**
EXPERIENCE.md correctly says "live row updates must **not** move focus," but with
LiveView/morphdom, re-rendering the row a user is focused inside (e.g. focus is
on the Block button of a row that a PubSub `scan finished` event re-renders) can
*destroy and recreate* that node, dropping focus to `<body>`. "Don't move focus"
is necessary but not sufficient — the risk is focus *loss*, not focus *theft*.
*Fix:* Require `phx-update="stream"` with stable DOM ids per row and
`phx-key`/preserved-element handling so the focused control survives patch;
mandate that a re-render never removes/replaces the focused interactive element
(update text/badge in place). Add an E2E assertion: focus a row action, push a
row update, assert `document.activeElement` is unchanged.

### H2 — Live filter results are not announced to screen readers
**WCAG 4.1.3 (Status Messages).**
Filters "apply live (no Apply button)" and rewrite the URL. Sighted users see the
table repopulate; a screen-reader user gets **nothing** — no "12 Treffer" count,
no "keine Treffer." The empty/no-match copy exists visually but is not tied to a
live region. Silent result changes on a live-filter table are a classic 4.1.3
failure.
*Fix:* Add a visually-hidden `aria-live="polite"` status node that announces the
result count on every filter/sort change ("14 Medien gefunden" / "Keine Treffer
— Filter anpassen"). Specify it in EXPERIENCE.md so it is not skipped.

### H3 — "Weitere laden" (load-more): new rows and focus not managed
**WCAG 4.1.3, 2.4.3.**
Keyset "Weitere laden" appends 50 rows. The contract says nothing about (a)
announcing "50 weitere geladen, 100 von 240," or (b) where focus goes after the
button — if the button remains and more rows are appended below it, a keyboard
user is stranded above content they just requested, and a screen-reader user
doesn't know anything happened.
*Fix:* After load, move focus to the first newly-appended row (or keep it on the
button and announce the count via a live region). Specify the announcement string
and the focus target.

### H4 — Disabled confirm button as the only gate = no error identification
**WCAG 3.3.1 (Error Identification), 3.3.3 (Error Suggestion), 1.3.1.**
Both the override-dialog ("Confirm disabled until reason is non-empty") and
"Test-before-commit" gate behavior by *disabling* the primary button. A disabled
button is removed from the tab order and announces no reason; a screen-reader
user tabbing the dialog finds a dead control with no explanation of what is
required. The mandatory-reason field is the legally sensitive four-eyes gate —
this is the worst place to hide the requirement in a disabled state.
*Fix:* Keep the confirm button **enabled**; on submit with an empty reason, block
and surface an inline error on the field (`aria-invalid="true"` +
`aria-errormessage` pointing at "Begründung ist erforderlich"), move focus to the
field. This matches the settings-form pattern the contract already mandates
elsewhere — apply it consistently to the dialog.

### H5 — Dialog focus-in target and "not on destructive button" underspecified
**WCAG 2.4.3, 2.4.7.**
The confirm-dialog says "auto-focus on Cancel" — good. But the override-dialog
(highest tier, red header) does not say what receives focus on open. It has a
mandatory reason field; focusing the *field* is arguably right, but it is not
stated, and "default focus not on the destructive button" is only asserted for
one dialog, not established as a rule for all four (Delete, Hard-Delete, Override,
Kill-switch). Kill-switch (`fail_open ↔ fail_closed`) is a system-wide toggle with
no dialog spec at all beyond "opens a dialog."
*Fix:* State a single rule for **all** media dialogs: on open, focus the first
interactive element that is *not* the destructive action — the reason field where
one exists, otherwise Cancel. Give the kill-switch dialog the same explicit
focus/trap/restore/Escape spec as the others, and confirm it consumes the
consequence line.

### H6 — Status conveyed by border color alone (alerts, health cards, storage test)
**WCAG 1.4.1 (Use of Color).**
Three surfaces lean on a colored border as the severity/status signal with no
guaranteed text/icon equivalent: (a) `scan-alert-item` — `3px` left-border
critical=red / warning=amber; (b) `scan-health-stat` — `3px` top-border green/
amber/red; (c) storage "Test Connection" result pill — spinner / green / red.
`role="alert"`/`role="status"` handles the *programmatic* channel, but the
*visual* severity distinction is color-only unless each carries an icon + word
("Kritisch"/"Warnung", "Erreichbar"/"Fehlgeschlagen"). The color-blind rule the
doc applies rigorously to badges is not applied to these.
*Fix:* Extend "color + icon + text" to alert items (severity word + icon), health
cards (status word, e.g. "Beeinträchtigt"/"Nicht erreichbar", not just a red
border), and the storage-test pill (already has "Erreichbar"/failure text — make
the icon mandatory and the text non-optional, never a bare colored dot/spinner).

---

## Medium

### M1 — Emoji glyphs as status icons are fragile and double-announce
**WCAG 1.4.1, 4.1.2, 1.4.11.**
Badges use emoji (🟠 ✓ ⚠ ⛔) as the icon channel. Emoji: (a) are read
inconsistently by screen readers ("no entry" for ⛔, "orange circle" for 🟠) —
not the status word; (b) with the visible text label present, they should be
`aria-hidden` to avoid double announcement, which is not specified; (c) their
color is OS/font-controlled, so you cannot guarantee the icon's own contrast or
that it tracks the token. ✓ and ⚠ as bare monochrome glyphs may also fail 3:1 as
non-text if rendered in a low-contrast color.
*Fix:* Use icon-font/SVG glyphs bound to the token color (contrast-controllable),
mark them `aria-hidden="true"` since the text label carries the meaning, and drop
emoji for status. If emoji stay, mandate `aria-hidden` + a real text label.

### M2 — Required marker "*" has no programmatic/legend spec
**WCAG 3.3.2 (Labels or Instructions), 1.3.1.**
The floor says `*` required marker, but not that the field carries
`aria-required="true"` / `required`, nor that a "* = Pflichtfeld" legend exists.
An asterisk alone is a visual convention; screen-reader users may not learn the
field is required.
*Fix:* Pair every `*` with `aria-required="true"` on the control and a visible
legend explaining the asterisk; ensure the asterisk itself is not the sole
carrier of "required."

### M3 — Show/hide secret toggle lacks accessible name and state
**WCAG 4.1.2.**
Secret fields get a "show/hide toggle," but no accessible name or
`aria-pressed`/state is specified. An icon-only eye toggle with no name/state is
opaque to screen readers, and toggling `type=password`→`text` is not itself
announced.
*Fix:* Toggle is a `<button>` with `aria-pressed` and a dynamic accessible name
("Passwort anzeigen"/"Passwort verbergen"); announce nothing extra beyond the
name change.

### M4 — Table row-header scope and `th` coverage only partially specified
**WCAG 1.3.1.**
`<th scope="col">` on every column header and `<caption class="sr-only">` are
correctly mandated (good — closes the inherited gap). But the master-detail audit
trail is "a compact table or divide-y timeline"; if it is a table, its header
scope is unaddressed, and no row-header (`scope="row"`, e.g. the filename or
timestamp column) is specified for either table, so cell associations in a wide 9-
column table are weaker than they should be.
*Fix:* Require `scope="col"` on the audit-trail table headers too, and designate a
`scope="row"` cell (filename) in the media table so the 9 columns associate to a
row identity.

### M5 — Language switching and lang attributes incompletely specified
**WCAG 3.1.1 (Language of Page), 3.1.2 (Language of Parts).**
Good: mono technical strings wrapped in `<span lang="en">`. Missing: the DE↔EN
switch (from OIDC claim) must update `<html lang>` — not stated. Also, tagging a
SHA-256 hash / MXID / storage key as `lang="en"` is questionable — these are not
English prose; a screen reader may read them as words. Code-like strings are
better exposed as `<code>` with the reader spelling/character mode, not
`lang="en"`.
*Fix:* Specify that `<html lang>` reflects the active locale; reserve
`lang="en"` for actual English UI prose, and mark hashes/IDs as `<code>` (the doc
already mentions `<code>`) without a spurious language tag.

### M6 — Collapsed (icon-mode) sidebar nav item + attention badge need names
**WCAG 4.1.2, 1.1.1.**
At `lg:` the sidebar collapses to icon mode. The "Medien" nav item then shows an
icon + attention badge with no visible text. If the label is not exposed
(`sr-only` text / `aria-label`) the item and its infected-count badge are
unlabeled for screen readers and unclear to sighted users without a tooltip.
*Fix:* In icon mode, keep an `sr-only` label on the nav item and ensure the
attention badge has `sr-only` text ("1 infizierte Datei") — the doc mentions
`sr-only` for the badge in one place; make it normative for icon mode too.

### M7 — New-infected announcement: politeness level may be wrong
**WCAG 4.1.3.**
Both the nav attention badge and "new-infected announcements" are specified as
`aria-live="polite"`, with `role="alert"` only "may" be used for ClamAV-down. A
newly discovered *infected* file is a security event; polite means it waits
behind other speech and can be missed. Ambient count badges being polite is
correct; the *new-infected event* announcement arguably warrants assertive.
*Fix:* Keep the nav count badge polite; make the discrete "neue infizierte Datei
erkannt" announcement assertive (or `role="alert"`), and make ClamAV-down
`role="alert"` mandatory ("may" → "must") since it is the critical degraded state.

---

## Low

### L1 — Loading/skeleton animation ignores reduced-motion
**WCAG 2.3.3 (Animation from Interactions, AAA) / good practice.**
`animate-pulse` skeletons and any spinner should honor
`prefers-reduced-motion: reduce`. Not mentioned.
*Fix:* Gate pulse/spinner animation behind `motion-safe:` / a reduced-motion
media query.

### L2 — Scrim dismiss is mouse-only (Escape covers keyboard, but state it)
**WCAG 2.1.1 (Keyboard).**
`backdrop-blur` scrim implies click-outside-to-close (mouse). Escape is specified,
so keyboard parity exists — but the contract should state scrim-click is a
convenience only and Escape/Cancel are the guaranteed paths, so an implementer
doesn't ship scrim-click as the sole close affordance.
*Fix:* Note explicitly: every dialog closes via Escape and a visible Cancel
button; scrim click is optional and never the only close path.

### L3 — Focus ring offset color assumes base-200 everywhere
**WCAG 2.4.7.**
The uniform ring is `ring-offset-base-200`. Controls inside dialogs (on `base-200`
panels) are fine, but any control on `base-100` (page) or `base-300` (topbar) gets
a mismatched offset that can reduce ring visibility.
*Fix:* Either use the surface-appropriate `ring-offset-*` per context or verify
the ring itself (`ring-primary #f97316`, ≥3:1 vs adjacent) is visible on all three
surfaces regardless of offset.

---

## What the contract already gets right (do not regress)

- Keyboard completeness (NFR-A2) is named for row actions, filters, pagination,
  dialogs; CSP-safe LiveView modals replace `window.confirm` (2.1.1 win — no
  mouse-only path *as stated*, subject to H1/H3 focus gaps).
- Focus trap + restore-to-trigger + Escape are specified for dialogs (2.4.3).
- `<th scope="col">` + `<caption class="sr-only">` mandated on the media table,
  explicitly closing the inherited config/compliance/audit gap.
- Visible `<label for>` required over aria-label-only (3.3.2); `aria-invalid` +
  `aria-errormessage` for settings validation (3.3.1) — apply this to the dialog
  too (H4).
- `<768px` reflow to label-value cards (1.4.10) and ≥44×44px targets (2.5.5).
- Permission-gated actions hidden not disabled for the override role (avoids the
  disabled-control ambiguity — ironically the opposite of H4's dialog case).
- "color + icon + text" is stated as the badge rule — the failures are that it is
  not extended to alerts/health/test-pill (H6) and that the color math and
  filled-badge/emoji realizations aren't nailed down (C1, C2, M1).
