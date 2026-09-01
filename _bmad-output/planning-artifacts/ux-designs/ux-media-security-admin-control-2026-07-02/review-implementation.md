# Implementation-Consistency Review — media-security-admin-control

Reviewer pass over `DESIGN.md` + `EXPERIENCE.md` (dir
`_bmad-output/planning-artifacts/ux-designs/ux-media-security-admin-control-2026-07-02/`)
against the real Nebu admin stack. Every finding cites the file it was verified against.

## Overall verdict

**Buildable — GO, with corrections.** The contract is grounded in the real stack
(Phoenix LiveView + HEEx, Tailwind + DaisyUI theme `nebu`, strict CSP) and it
correctly retracts the stale "Go Templates / Vue+SSE" claims. Its two central
technical bets are sound against the actual code: (1) `phx-click` LiveView modals
are genuinely CSP-safe here, and (2) `/admin/media` as a LiveView + PubSub surface
has real precedent. No CRITICAL blockers.

The problems are **accuracy of the "inherited vs. greenfield" line**: several things
the contract calls "inherited" (`media-badge--*` tokens/CSS layer, the master-detail
`MasterListItem`/`StatusCard`/`AlertItem` components) **do not exist in code** and are
net-new build work, and the "mirror `/admin/config`" settings claim misreads how
`/admin/config` actually works (dead controller, POST-reload, DB prefill — not env,
not live inline validation). These are Major (they mislead effort/estimation) but not
blocking. Implementation must run through `/nebu-pipeline` with `ui:true` (server/lib
is pipeline-protected) — the contract does not state this.

---

## Major

### M1 — teal/coral tokens and `media-badge--*` classes are net-new mechanism, not "reference only"
DESIGN frontmatter lists `media-released #14b8a6` (teal) and `media-blocked #fb7185`
(coral) and instructs: "define `media-badge--*` utility classes in the media CSS
layer bound to the tokens" (DESIGN.md:100-120, 188-195).
Reality: theme `nebu` has **no teal/coral semantic** — only primary orange, success
green, warning amber, error red, neutral/info gray
(`server/assets/tailwind.config.js:14-35`). And `server/assets/css/app.css:37-39` is
**only** `@tailwind base; @tailwind components; @tailwind utilities;` — there is **no
existing custom `@layer components` block** to drop `.media-badge--released` into. So
this is a real new mechanism, not an inheritance: implementers must (a) add the two
hues to `theme.extend.colors` in `tailwind.config.js` (alongside `primary-hover`,
`status-*-bg` at lines 43-52) and (b) author a new component layer in `app.css`.
*Fix:* State explicitly that both the two color tokens (`tailwind.config.js
theme.extend.colors`) **and** a new `@layer components { .media-badge--* { … } }` block
in `app.css` are greenfield additions; keep the ≥4.5:1-on-`base-200` verification
requirement (DESIGN.md:262) as an acceptance check on those two hexes.

### M2 — master-detail / `MasterListItem` / `StatusCard` / `AlertItem` are presented as "inherited" but do not exist
DESIGN.md:150-152, 170, 207-213 and EXPERIENCE.md:280-283 repeatedly frame the
3-column detail view as "the inherited Matrix pattern (D6)", the scan cards as
"mirrors `StatusCard`", and the alert items as "mirrors the inherited `AlertItem`",
with a "~300px master list … mirroring `MasterListItem`".
Reality: `grep` across `server/lib/nebu/admin/` finds **no** master-detail layout,
`MasterListItem`, `StatusCard`, or `AlertItem`. The only card in code is
`DashboardLive.stat_card/1` (`server/lib/nebu/admin/dashboard_live.ex:51-60`,
`card bg-base-200 shadow-sm`). The `[class*="status-card--…"]` selector in
`e2e/step-definitions/admin/dashboard.steps.ts:17` targets a component that is **not
implemented** (red-phase/pending). These patterns live in `ux-design-specification.md`
(aspirational), not in the codebase.
*Fix:* Relabel the detail layout, master list, scan-health cards, and alert items as
**greenfield** components that follow the design-spec pattern, not "inherited" code to
reuse. This is significant build scope (a whole new 3-column responsive layout) and
should be estimated as such.

### M3 — "mirror `/admin/config`" + "env-var prefill" misreads the real settings mechanism
EXPERIENCE.md:118-123 and DESIGN.md:154-159, 231-240 say the settings page mirrors
`/admin/config` with "env-var prefill on first load", "server-side bounds validation …
inline field errors (`aria-invalid` + `aria-errormessage`)".
Reality: `/admin/config` is a **dead controller**, not a LiveView
(`server/lib/nebu/admin/config_controller.ex` + `config_html.ex`; routes at
`router.ex:187-189` are `ConfigController` actions). It uses plain `method="post"`
forms with a full-page reload and **no live/inline validation**
(`templates/config/index.html.heex:10-45`). Prefill comes from the **`server_config`
DB table** via `Nebu.Admin.DB.get_server_config()` / `scope_value(@config, …)`
(`config_controller.ex:150`, template lines 20/34) — **not** from env vars; ADR-022
deliberately removed the `NEBU_OIDC_*` env path (CLAUDE.md ADR-022). So:
- "env-var prefill" is inaccurate for the actual pattern (DB-backed prefill with
  placeholders) and brushes against ADR-022. If media config truly has env defaults,
  say so explicitly and reconcile with ADR-022; otherwise call it DB-config prefill.
- Live inline field errors (`aria-invalid`/`aria-errormessage` as you type) require a
  **LiveView** — that is a *divergence* from `/admin/config`'s dead-controller
  POST-reload model, not a mirror of it. Either build settings as a new LiveView (fine,
  precedent exists) or accept dead-controller re-render-on-submit validation.
*Fix:* Split the claim: settings **visually** mirrors `/admin/config` (`form-control`,
`input input-bordered`, `label-text-alt` — those classes are real, template lines
14-27). Its **interaction** (live validation, per-section save) is a new LiveView, not
inherited from config's POST forms. Correct "env-var prefill" to DB-config prefill (or
justify env against ADR-022).

---

## Minor

### m1 — `warning-bg #451a03` token name/value doesn't exist; real token is `status-warn-bg #431407`
DESIGN.md:26,97 says "use `warning-bg #451a03` (not the spec's `#431407`, which
collides with `primary-subtle`)." The real config has **`status-warn-bg: "#431407"`**
(`tailwind.config.js:50`) — and indeed it collides: `primary-subtle` is also `#431407`
(line 45) and DaisyUI `warning-content` is `#431407` (line 30). So the contract's
collision observation is correct, but the token it names (`warning-bg`) and the value
it recommends (`#451a03`) **do not exist anywhere** and must be added.
*Fix:* Name it `status-warn-bg` (the existing convention) and note that its value must
be **changed** from `#431407` to `#451a03` in `tailwind.config.js:50` to resolve the
collision — this is an edit to a shared token, flag it for the pipeline/security review.

### m2 — DESIGN claims "no shadow scale exists"; shadows are in fact used
DESIGN.md:163-172 asserts "depth via the background stack + 1px borders, **not**
shadows (no shadow scale exists)." Reality: `shadow-sm` is used in
`dashboard_live.ex:53`, and `shadow` in `login_controller.ex:101` and `auth.ex:1570`;
the autocomplete listbox uses `shadow` in `app.js:129`.
*Fix:* The border-only choice for new media cards is fine as a *deliberate* rule, but
drop the false "no shadow scale exists" premise — shadows are present in the codebase.

### m3 — new `data-state` hook diverges from existing `data-status` convention
DESIGN.md:204-205 adds `data-media-id` + `data-state` on rows. The existing status
hook on the users table is **`data-status`** (`templates/users/index.html.heex:21`,
consumed by `[data-status]`-style selectors). E2E already selects state via
`data-status` and via class substrings (`[class*="status-card--…"]`,
`dashboard.steps.ts:17`).
*Fix:* Additive and non-breaking, so acceptable — but prefer `data-status` for
consistency with the existing badge convention, or explicitly document why media uses
`data-state`. Note the positive corollary: because E2E already selects by
`[class*="status-card--…"]`, the `media-badge--{group}` class approach (M1) is directly
selectable in tests — good fit.

### m4 — pipeline / code-change policy not reflected in the contract
CLAUDE.md: `server/lib`, `server/test`, `server/priv/migrations` are pipeline-protected;
implementation must run through `/nebu-pipeline` (here `--epic media-security-admin-control`)
and each UI story must carry `ui:true` so the `nebu-agent-ux` gate and E2E growth fire.
Neither DESIGN.md nor EXPERIENCE.md mentions this.
*Fix:* Add a one-line implementation note that all six stories land via nebu-pipeline
with `ui:true`, and that each UI story must grow the admin-ui Playwright suite
(`workers:1` serial, shared DB — `playwright.config.ts:85-86`).

---

## Confirmed correct (no action)

- **CSP / modal approach (EXPERIENCE.md:30-37, DESIGN.md:73-74, 216-222).** Admin CSP
  is `default-src 'self'; … style-src 'self' 'unsafe-inline'; script-src 'self'`
  (`router.ex:85-91`) — **no** `unsafe-inline` for scripts. `phx-click` LiveView modals
  work because interactivity ships from the **external** `app.js` (allowed by
  `script-src 'self'`) over the LiveSocket (`app.js:227-262`). Avoiding `window.confirm`
  for new dialogs is right; today's `data-confirm` → `window.confirm` path
  (`app.js:28-44`) is only for dead-controller pages. `style-src 'unsafe-inline'` means
  `backdrop-blur` scrims are fine.
- **LiveView + PubSub render mode (EXPERIENCE.md:30-37).** Real LiveView precedent:
  `DashboardLive`, `AuditLogLive`, `BootstrapLive` (`use Phoenix.LiveView, layout:
  {Nebu.Admin.Layouts, :live}`); CSP `connect-src 'self' ws: wss:` (`router.ex:86`) and
  a LongPoll fallback (`app.js:247-259`) support socket PubSub. No story is forced onto
  a dead controller; `/admin/media` as LiveView is realistic.
- **Greenfield component claim (extraction-notes).** Confirmed: no modal/dialog
  (`role="dialog"`/`aria-modal`), no toast, no pagination UI, no `animate-pulse` anywhere
  in `server/lib/nebu/admin/`. All genuinely greenfield.
- **Table convention (DESIGN.md:196-206).** Confirmed drift: users/rooms use
  `table w-full` **with** `<th scope="col">` (`users/index.html.heex:6-11`); config,
  compliance, audit use `table table-zebra` in `overflow-x-auto` **without** `scope`
  (`config/index.html.heex:88-91`, `compliance/index.html.heex:6-15`,
  `audit_log_live.ex:34-43`). The contract's choice — zebra + overflow-x-auto + `scope`
  on every `<th>` + `sr-only` caption — is consistent and correctly closes the gap.
- **Layout shell (DESIGN.md:138-141, EXPERIENCE.md:27-29).** Matches `layouts.ex`
  exactly: topbar `h-12 bg-base-300` (line 59), `nav.w-60 bg-base-200` (line 66),
  `main#main-content.flex-1.overflow-auto.p-6` (line 92), skip-link + `role=banner/main`,
  `nav_item/1` + `@active_nav` + `aria-current` + `data-navkey` (lines 107-127). Adding a
  "Medien" nav item and preserving `data-role`/`data-page`/`data-section` hooks is
  consistent with how existing steps select (`data-page` on users/rooms,
  `data-section="devices"`).
- **E2E serial suite (EXPERIENCE.md, DESIGN.md:204).** `fullyParallel:false`,
  `workers:1`, shared DB, base `http://localhost:8008` (`playwright.config.ts:85-90,100`).
  Additive `data-media-id`/`data-state` and `media-badge--*` class hooks do not threaten
  serial execution.
