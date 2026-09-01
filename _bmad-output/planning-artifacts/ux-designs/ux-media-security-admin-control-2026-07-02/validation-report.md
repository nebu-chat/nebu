# Validation Report — Media Security & Admin Control

- **DESIGN.md:** `./DESIGN.md`
- **EXPERIENCE.md:** `./EXPERIENCE.md`
- **Run at:** 2026-07-02 (Reviewer Gate, 3 parallel lenses)
- **Lenses:** rubric-walker · accessibility (WCAG 2.1 AA) · implementation-consistency
- **Reviewer files:** `review-rubric.md`, `review-accessibility.md`, `review-implementation.md`

## Overall verdict

The spine pair is disciplined and well-shaped — canonical section order, hex on
every color token, clean state-family split, honest LiveView/HEEx inheritance,
and an unusually strong behavioral Accessibility Floor. Two things dominated the
gate. **(1)** The accessibility lens returned a *conditional fail*: the color
math was wrong in two places — filled badges with default light text fail at
2.4–2.6:1, and the "inherited tokens verified" claim was false (`error` red
3.87:1 and terminal gray 3.04:1 fail as text). **(2)** The rubric lens caught
that the epic had grown the same day (Review 5 → **Story 13**, 13a–13e) with
three new Admin-UI surfaces the contract didn't cover — a real coverage gap,
verified against the epic. The implementation lens confirmed the contract is
**buildable (GO with corrections)**, its two core bets (CSP-safe LiveView modals,
LiveView+PubSub) hold, but several "inherited" components are actually greenfield.

**All critical/high findings and the Story 13 gap were resolved (D7); the spines
remain `status: final`.** Post-review sign-off (D8) closed the residuals:
`/admin/media/approvals` is a dedicated route, the `status-warn-bg` token edit is
approved to go through the pipeline/security review, and the NFR-C3↔S3 tension is
resolved — PostgreSQL for runtime data, S3/MinIO (on-prem) for static media files;
files-in-Postgres rejected (PRD NFR-C3/C4 updated). No open decisions remain.

## Category verdicts (rubric-walker)
- Flow coverage — adequate → **strengthened** (Story 13 flow added)
- Token completeness — strong
- Component coverage — adequate → **strengthened** (4 Story-13 components added, behavioral+visual)
- State coverage — strong
- Visual reference coverage — strong (no mockups/wireframes this run — spine-only, by design)
- Bloat & overspecification — strong
- Inheritance discipline — adequate → **corrected** (greenfield vs inherited relabeled)
- Shape fit — strong

## Findings by severity

### Critical (3) — all RESOLVED
**[Accessibility C1]** Badge text color unspecified → filled pills fail 1.4.3 (teal 2.42:1 / coral 2.62:1).
_Fix applied:_ media badges are filled pills with **dark text `#1c1917`** (teal 7.03:1, coral 6.50:1), set in the `media-badge--*` class; build-time token-pair contrast test mandated. (DESIGN §Colors, §media-state-badge)

**[Accessibility C2]** "Inherited tokens verified ≥4.5:1" is false — red 3.87:1, gray 3.04:1 fail as text.
_Fix applied:_ false claim removed; measured-contrast table added; red/gray forbidden as body/label *text*; infected badge lightens red or leans on the ⚠ glyph. (DESIGN §Colors)

**[Accessibility C3]** Master-detail relationship is color-only (no programmatic exposure) — 1.3.1/4.1.2.
_Fix applied:_ master items are links with `aria-current="page"`; detail is an `aria-labelledby` region with focus-move/announce on selection; accent bar `aria-hidden`. (DESIGN §media-detail-panel, EXPERIENCE §Post-review hardening)

### High (7) — all RESOLVED in-spec
**[Rubric HIGH]** Story 13 (13b/13d/13e) uncovered; settings IA drifted.
_Fix applied:_ IA, role model (compliance_officer now approving), State overlays (Legal-Hold, Art.-17 restriction), Flow 5, and 4 new components added; epic Story 0 DoR extended to 13b/13d/13e.

**[Accessibility H1]** PubSub row re-render drops keyboard focus (2.4.3). _Fix:_ `phx-update="stream"` stable ids, in-place update, E2E focus assertion.
**[Accessibility H2]** Live filter results not announced (4.1.3). _Fix:_ visually-hidden `aria-live="polite"` result-count node.
**[Accessibility H3]** "Weitere laden" focus/announce unmanaged (4.1.3/2.4.3). _Fix:_ focus to first new row + count announcement.
**[Accessibility H4]** Disabled confirm button hides mandatory-reason requirement (3.3.1). _Fix:_ button stays enabled; inline field error on empty submit; applies to override + erasure + two-eyes.
**[Accessibility H5]** Dialog focus-in rule underspecified for override/kill-switch. _Fix:_ one rule for all four dialogs — focus first non-destructive element; kill-switch gets full trap/restore/Escape spec.
**[Accessibility H6]** Alerts/health/test-pill convey status by color alone (1.4.1). _Fix:_ severity/status word + icon mandated on all three.

### Medium (per lens) — RESOLVED or noted
- **[Impl M1]** teal/coral + `media-badge--*` are net-new (theme has no such semantic; `app.css` has no component layer). _Fix:_ stated as greenfield additions to `tailwind.config.js` + a new `@layer components`.
- **[Impl M2]** master-detail / `StatusCard` / `AlertItem` / `MasterListItem` don't exist in code. _Fix:_ relabeled greenfield-following-spec (real build scope).
- **[Impl M3]** "mirror /admin/config" + "env prefill" misreads config (dead controller, DB prefill, no live validation). _Fix:_ split into visual-mirror vs new-LiveView interaction; env-prefill scoped as the epic's migration path, reconciled with ADR-022.
- **[Accessibility M1]** Emoji status glyphs fragile. _Fix:_ icon-font/SVG bound to token color, `aria-hidden`, no emoji.
- **[Accessibility M2–M7]** required `aria-required`+legend, secret-toggle `aria-pressed`+name, audit-table `scope`, `<html lang>` switch + `<code>` for IDs, icon-mode nav labels, assertive new-infected / must ClamAV-down `role=alert` — all pinned in §Post-review hardening.

### Low (per lens) — noted in-spec
- **[Rubric medium/low]** `components` frontmatter is a name-list not a token-object; Story 10 lacked a Key Flow; a few behavioral rows thin. _Partially addressed_ (Story-13 components carry full behavioral+visual rows; frontmatter kept as name-list — acceptable for this spine's inheritance model, logged).
- **[Accessibility L1–L3]** reduced-motion, scrim-dismiss-is-convenience, ring-offset per surface — pinned.
- **[Impl m1–m4]** `status-warn-bg` naming/value-change flagged for pipeline; "no shadow scale" claim corrected; `data-state` vs `data-status` documented; pipeline-protected implementation note added.

## Reviewer files
- `review-rubric.md` — 0 critical · 1 high · 6 medium · 8 low
- `review-accessibility.md` — 3 critical · 6 high · 7 medium · 3 low (verdict: conditional fail → resolved)
- `review-implementation.md` — 0 critical · 3 major · 4 minor · 6 confirmed-correct (verdict: GO with corrections)
