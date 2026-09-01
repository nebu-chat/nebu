# Test Review — bugfix/admin-media-nav-grouping

Reviewed: `server/test/nebu/admin/layouts_media_nav_grouping_test.exs` (20 tests) against
`docs/stories/bugfix/admin-media-nav-grouping.md` (AC1-AC7 + Dev Agent Guardrails) and the
current `server/lib/nebu/admin/layouts.ex`.

## Verdict

**MINOR** — the suite tightly pins the primary observable behavior (grouping, positioning,
labels, hrefs, real active-nav highlighting via actual router/LiveView integration, disclosure
markup, stale-comment removal). A handful of narrow gaps exist, listed below; none of them would
let a *materially* broken implementation pass silently, but two (badge exclusivity, badge
accessibility-content preservation) are worth a look before/while dev-story runs, and are cheap
to add.

## What's solid (verified by reading the actual test file + layouts.ex)

- **AC1 positioning/leaf-collapse**: `top_level_keys/1` + exact-order assertions
  (`spaces, media, config`) and the `Enum.filter(...) == ["media"]` check make it impossible for
  `media-settings`/`media-health` to remain as top-level entries while still passing.
- **AC2 labels/keys/hrefs**: each child is checked by exact `data-navkey`, exact `href`, and
  either a required substring ("Media Explorer") or an explicit `refute ... "Media Settings"` /
  `refute ... "Media Health"` to enforce the dropped prefix. Good.
- **AC4 active-highlighting is NOT stubbed** — this was my main worry per the task brief, and
  it's handled correctly: the AC4 `describe` block uses `get_page_html/1`, which drives a real
  GET through `@endpoint.call/2` into the actual router → actual `MediaLive` /
  `MediaSettingsController` / `MediaHealthLive` → actual `Layouts.live/1`. This means a dev
  implementation that groups the nav HTML correctly but forgets to update the backing LiveViews'
  own `active_nav` assign (e.g. leaves it as `"media"` instead of renaming to `"media-explorer"`
  to match the new child key) will genuinely fail these tests — it isn't testing a hand-fed
  `active_nav` override, it's exercising the real wiring. Each of the three tests also asserts
  the specific child gets `bg-primary`/`aria-current="page"` and the parent gets the *secondary*
  `bg-base-300` (never `bg-primary`) — this is checking the correct child, not just "some child."
- **AC5 claim about reusing `admin-sidebar-nesting.feature` coverage is TRUE, not hand-waved.**
  I read `e2e/features/admin/admin-sidebar-nesting.feature` directly: it proves real
  keyboard-driven Tab/Space/Enter toggling of `aria-expanded` and the hidden-attribute-not-flex
  regression against the shared generic `nav_item/1` disclosure mechanism (via the `config`/`logs`
  parent buttons). Since the story explicitly requires Media to reuse that same generic mechanism
  with "no new interaction pattern," and the component-level AC5 tests here confirm Media's button
  carries the identical `aria-expanded`/`aria-controls`/toggle-icon/`ml-4` markup, the claim that no
  new E2E scenario is needed holds up — it isn't a scope dodge, the generic mechanism really is
  already proven elsewhere and Media doesn't introduce a variant of it.
- **AC6**: real GET-based integration tests confirm hrefs/paths/200s are unchanged; `h1` presence
  confirms `MediaLive`'s actual page content still renders (not a stubbed page).
- **AC7**: the two `refute source =~ ...` substring checks between them hit all four stale comment
  blocks currently in `layouts.ex` (I enumerated all four: the media-settings "Correction 2" block,
  the media leaf's "5a" block, the badge's "no nested Medien parent" block, and media-health's
  "10a-scan-stats-rollup" block) — confirmed by reading the file; no block escapes both refutes.

## Gaps found (MINOR, listed for the coordinator's call)

1. **AC1's mandated code-shape (module attribute + `defp` accessor, "don't invent a different
   children-list mechanism") is functionally unenforced.** All 20 tests assert on rendered
   HTML/DOM only. AC7's test proves source-inspection (`File.read!` + `refute source =~ ...`) is
   already an established pattern in this very file, but nothing analogous asserts a
   `@media_nav_children` module attribute or `media_nav_children/0` function actually exists. A
   dev could hand-roll bespoke HTML producing byte-identical output without touching the shared
   `nav_item/1` parent/children mechanism at all, and every test here would still pass — violating
   both AC1's explicit wording and the Dev Agent Guardrails' explicit "don't invent a different
   children-list mechanism." Cheap fix: one source-inspection test mirroring AC7's pattern (e.g.
   `assert source =~ "media_nav_children"` or check the module exports a 0-arity `media_nav_children`
   via `function_exported?/3`).

2. **AC3 "moves to the correct child" isn't exclusive.** The three AC3 tests confirm (a) the
   badge renders on `media-explorer` with `count: 3`, (b) the badge does NOT render on the parent
   `<button>`, and (c) no badge renders anywhere with `count: nil`. Nothing refutes the badge also
   appearing on `media-settings` or `media-health`. An implementation that (mistakenly) attaches
   the badge to all three children instead of only `media-explorer` would pass every AC3 test as
   written. Cheap fix: add `refute find(settings_link, badge_selector)` /
   `refute find(health_link, badge_selector)` to test (b) or a new one.

3. **AC3's explicit "preserve accessibility properties exactly" guardrail has zero test
   coverage for content, only for `role="status"`.** The guardrail text is specific: "role="status",
   aria-hidden count + sr-only sentence... this was itself a UX-gate-driven fix in story 5b, don't
   regress it." The AC3 tests check `data-testid="nav-media-attention-badge"` and `role="status"`
   only — none assert the aria-hidden numeric span or the sr-only "Datei(en) benötigen
   Aufmerksamkeit" sentence survived the move. Since this is a lift-and-shift of existing markup
   (not new logic), actual regression risk is low, but it's the one guardrail item named
   "don't regress" with literally no test protecting it. Cheap fix: assert
   `Floki.find(badge, "[aria-hidden] ~ .sr-only")`-equivalent still contains the count/sentence.

4. **AC6's "module names/routes untouched" is only indirectly checked.** Tests confirm the
   observable HTTP behavior (200, href, `h1` present) but nothing inspects `router.ex` to confirm
   the LiveView/controller module bindings themselves are unchanged. Low risk — this is also a
   named Dev Agent Guardrail and would surface in code review — but noting it since the task asked
   about "no regression to routing."

## Non-issues (checked, found to be fine)

- AC4 sibling-exclusivity (does a wrong impl highlight all 3 children at once?) — structurally
  impossible given the existing `nav_item/1` highlight logic is a scalar `child.key == @active`
  equality check reused unchanged from the config/logs precedent; not worth a test.
- AC2's substring-based label assertions (`=~ "Media Explorer"` etc. rather than exact-string
  equality) are slightly loose but paired with exact `href`/`data-navkey` assertions, so the
  practical risk of a false-positive pass is negligible.

CLEAN or MAJOR:[list] or MINOR:[list] → see Verdict above.
