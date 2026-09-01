# Spine Pair Review — nebu-chat (media-security-admin-control)

## Overall verdict
A disciplined, well-shaped pair that a downstream consumer can source-extract from: canonical section order is exact, tokens carry hex, state families are split cleanly, and inheritance-by-reference is honest about the real LiveView/HEEx stack. The one contract-level gap that matters: the pair is scoped to epic stories 5/6/7/9/10/11 and predates Review 5 (same day, 2026-07-02), which added **three new Admin-UI stories (13b Lifecycle-Rules-UI, 13d Two-Eyes-Delete, 13e Erasure-Request)** on `/admin/media/settings` — these have no UX contract and the settings-page IA in the spine has already drifted from the epic's consolidated Lifecycle model. Secondary: Story 10 (Scan Health) has no Key Flow, two named components lack behavioral rows, and the spine's "inherited tokens verified ≥4.5:1" claim is false for the load-bearing `error` red.

## 1. Flow coverage — adequate

### Findings
- **high** Stories **13b / 13d / 13e** (Lifecycle-Rules ladder editor, Two-Eyes-Delete dual-control, Art.-17 Erasure-Request) are Admin-UI stories introduced in the epic's Review 5 (2026-07-02, same date as these spines) and have **no Key Flow, no IA entry, and no component**. Story 13b explicitly *consolidates the Retention knobs* the spine still lists as a flat section. As the DoR contract for UI stories, the pair silently omits three of them (epic §Story 13, DoD "each UI story abgeglichen"). *Fix:* either extend scope (add a Lifecycle-ladder flow with a compliance_officer protagonist + a Two-Eyes proposed→confirmed flow) or add an explicit "out of scope — see Story 13" note in EXPERIENCE.md Foundation so consumers know the gap is deliberate.
- **medium** Story 10 (Scan Health & Alerts Dashboard, an XL story and Kai's stated "at-a-glance health" persona need) has **no Key Flow**. The load-bearing "ClamAV goes down → critical alert → operator responds / flips kill-switch" narrative exists only as State Patterns "Degraded pipeline" (EXPERIENCE.md:150) and Interaction Primitives — never walked with a protagonist + climax. *Fix:* add Flow 5 — Kai reacts to a ClamAV-down critical alert on `/admin/media/health`, sees backlog grow, checks the kill-switch mode.
- **medium** None of the four Key Flows carries an explicit **failure beat**, unlike the shape example (`experience-example-shadcn.md:123,133`) whose flows end on a "Failure:" line. Flow 1 (Delete), Flow 3 (Save retention), Flow 4 (Test Connection) all have obvious failure branches (save fails, head_bucket fails) that the contract leaves to prose elsewhere. *Fix:* append a one-line Failure: beat to each flow (Flow 4's head_bucket failure is the whole point of Test-Connection and should be shown).
- **low** Block/Unblock/Rescan quick-actions (Story 6a) are covered behaviorally but never appear in a flow; acceptable since they are ceremony-free, but a one-line mention in Flow 1 would close it.

## 2. Token completeness — strong

### Findings
- **low** The two NEW tokens (`media-released` teal `#14b8a6`, `media-blocked` coral `#fb7185`) do pass ≥4.5:1 on `base-200` (computed 5.9:1 and 5.45:1) — the deferred verification the spine asks for actually holds, so the fallback-lightness clause (DESIGN.md:118-120) will not fire. Good contract discipline; noting only that the values are confirmable now rather than "must be checked."
- **low** `typography.scale` is a bare list of role names `[text-caption … text-display]` with no `fontSize`/`fontWeight` in frontmatter; sizes appear only in prose (DESIGN.md:129-134). Per design-md-spec `typography` is a nested object of role→metrics. Inherited-by-reference justifies not restating, but a machine consumer can't extract the ramp from frontmatter. *Fix:* acceptable as-is given inheritance; if strictness matters, promote the four elaborated roles to real token objects.

## 3. Component coverage — adequate

### Findings
- **medium** `media-detail-panel` has a full visual spec (DESIGN.md:207-214) but **no row in EXPERIENCE.md "Component Patterns"**. Its behavior (master-detail, URL-addressable open id, audit-trail timeline, `md:` collapse) is scattered across Foundation/IA/Flow 1 but never stated as a component behavioral rule. *Fix:* add a Component Patterns row for media-detail-panel (select-updates-URL, audit-trail read-only, responsive collapse).
- **medium** `storage-config-section` is a named frontmatter component + visual spec (DESIGN.md:231-240) but has **no dedicated behavioral row** in EXPERIENCE.md; its behavior lives only in Interaction Primitives "Test-before-commit" and Flow 4. *Fix:* add a Component Patterns row (masked secrets, Test-Connection-before-Save pill states, change-warning with count).
- **low** EXPERIENCE.md "row actions" is a behavioral pattern with no matching DESIGN.md component name — fine (it's behavior over media-table), just note it isn't a component.

## 4. State coverage — strong

### Findings
- **low** `/admin/media/:id` detail has no explicit **not-found / invalid-id** state. The hard-deleted case is covered (record persists with nulled fields, EXPERIENCE.md:137-138), but "media_id doesn't exist / bad URL" — reachable since the id is URL-addressable and shareable — is unspecified. *Fix:* one line in State Patterns B for a 404/"nicht gefunden" detail state.
- **low** Per-surface focus/cold-load states are handled globally (Accessibility Floor focus ring + Loading skeleton) rather than walked per surface; adequate for this product, noted for completeness.

## 5. Visual reference coverage — strong (none present)

`mockups/` and `wireframes/` do not exist; `imports/` exists but is **empty**. No visual references to link, therefore no orphans. Both spines correctly state "spine wins on conflict with any mock." Nothing to cover.

## 6. Bloat & overspecification — strong

### Findings
- **low** DESIGN.md frontmatter restates ~10 inherited hex values (primary, base-100…neutral) that the spine's own rule says to "reference only, do not redefine" (DESIGN.md:14-28). design-md-spec's inheritance guidance is "reference by name … specify only the deltas." The `# do not redefine` comments mitigate, and having the values inline makes the file self-contained, but it is source-restatement of the parent theme. *Fix:* optional — keep if self-containment is valued; otherwise cite `tailwind.config.js` line refs instead.
- **low** `3px` borders and `~300px` master-list width are literal px rather than tokens; acceptable because they mirror the inherited AlertItem/StatusCard/MasterListItem conventions verbatim and no token exists for them.

## 7. Inheritance discipline — adequate

### Findings
- **medium** **`error` red `#ef4444` measures 3.9:1 on `base-200`**, below AA — yet DESIGN.md:90-91 asserts "every status foreground ≥ 4.5:1 on its surface (base-200), **verified for the inherited tokens**." The claim is false for the loudest, most load-bearing status (infected). Either the usage is red-as-fill with light text on top (in which case the stated target — red *on* base-200 — is the wrong contrast to cite) or a red text/border label fails AA. *Fix:* correct the claim: state which combos are foreground-on-base-200 vs. fill-with-base-content-text, and verify `base-content` on `media-infected` fill; don't assert "verified" for a token that isn't.
- **medium** Role-capability inconsistency. Foundation (EXPERIENCE.md:40) says `compliance_officer` "**reads** audit-relevant views," but Flow 3 has Dr. Petra (`compliance_officer`) **editing and saving** retention policy (EXPERIENCE.md:236-247). The epic's Review-5 `compliance_officer` is the Two-Eyes-Delete approver (Story 13d), a capability the spine doesn't mention. *Fix:* reconcile — state whether compliance_officer may write settings, and note the Story-13 two-eyes role (or defer it with the Story-13 scope note).
- **low** Source drift: `.decision-log.md` "Confirmed sources" names `server/lib/nebu/admin/templates/**` and `e2e/features/**`, while the DESIGN/EXPERIENCE frontmatter cite `layouts.ex` and `e2e/playwright.config.ts`. All resolve; the named paths just aren't identical across context files. *Fix:* align source lists.
- All frontmatter sources resolve (verified on disk); component names that appear in both files are verbatim; every EXPERIENCE `{colors.*}` ref (`media-infected`, `warning`, `base-300`) resolves to a DESIGN token.

## 8. Shape fit — strong

### Findings
- **medium** DESIGN.md frontmatter `components` is a **bare YAML list of names**, not the spec's `component-name → {token: value|{path.to.token}}` object (design-md-spec.md:20,50; contrast `design-example-shadcn.md:36-48`). Visual token values live only in prose (## Components), so a machine consumer cannot resolve component tokens from frontmatter. *Fix:* promote to the object form for at least the two genuinely-new components (media-state-badge, the dialogs), referencing `{colors.media-*}`.
- **low** DESIGN.md body section order is exact-canonical (Brand&Style → Colors → Typography → Layout&Spacing → Elevation&Depth → Shapes → Components → Do's/Don'ts). EXPERIENCE.md carries all required defaults plus an invented "Resolved Decisions (D6)" tail section that earns its place (records the sign-off that closes D2/D4/D6). No action.

## Mechanical notes
- Sources spot-checked on disk — all resolve: `ux-design-specification.md`, `prd.md`, `media-security-admin-control-epic.md`, `server/assets/tailwind.config.js`, `server/lib/nebu/admin/layouts.ex`, `e2e/playwright.config.ts`.
- Contrast computed (WCAG relative luminance) on `base-200 #1f2937`: teal `#14b8a6` = 5.9:1 (pass), coral `#fb7185` = 5.45:1 (pass), amber `warning #f59e0b` = 6.83:1 (pass), **red `error #ef4444` = 3.9:1 (fails 4.5:1 as foreground)**.
- Components: 10/10 have visual specs in DESIGN.md; 8/10 have behavioral rows in EXPERIENCE.md (missing: media-detail-panel, storage-config-section).
- Frontmatter color tokens: all 15 (10 inherited + 5 media-state) + `warning-bg` carry hex. No color token missing a value.
- Key Flows: 4 present (Kai-triage, Mara-override, Petra-retention, Kai-storage) covering stories 5/6/7/9/11; Story 10 uncovered by a flow; Stories 13b/13d/13e out of declared scope and uncovered.
- No `mockups/` or `wireframes/` dir; `imports/` empty — zero visual-reference orphans.
