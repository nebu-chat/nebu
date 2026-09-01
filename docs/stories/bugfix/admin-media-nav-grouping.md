---
id: admin-media-nav-grouping
epic: bugfix
status: review
security_review: not-needed
ui: true
baseline_commit: 9a11d881185e35ecc7a34ec02acf1aea0c5c8f41
---

# Bug: Media admin nav items should be grouped under a "Media" parent, and "Medien" should be renamed

## Problem

`server/lib/nebu/admin/layouts.ex` currently renders three separate top-level nav leaves for
the media feature (added incrementally across the `media-security-admin-control` epic, each
with an inline comment explaining this exact gap):

```elixir
<.nav_item ... navigate="/admin/media" key="media" ...>
  Medien
  <span :if={...} data-testid="nav-media-attention-badge" role="status" ...>...</span>
</.nav_item>
<.nav_item ... navigate="/admin/media/settings" key="media-settings" ...>Media Settings</.nav_item>
<.nav_item ... navigate="/admin/media/health" key="media-health" ...>Media Health</.nav_item>
```

This is the epic's own documented "Story 0 (Media Admin UX Foundation)" gap: several stories
(5a, 5b, 9b, 10a) explicitly deferred nesting these under a shared "Medien"/"Media" parent
because that Story 0 was never built (tracked as follow-up debt, not a code defect at the
time). Product feedback now confirms this should be fixed:

1. The three items should be grouped under one parent nav item, mirroring the existing
   `key="logs"` (children: Live Stream, Trace Map, War Room, Log Retention) and `key="config"`
   (children: Role Mapping, Claim Mapping, General) precedents in the same file — a
   `@media_nav_children` module attribute + a `<.nav_item key="media" children={...}>` parent,
   not three flat top-level leaves.
2. The table view currently labeled "Medien" is not intuitive and should be renamed to
   "Media Explorer".
3. The parent label itself should be "Media" (English), matching every other top-level nav
   label in this file (Dashboard, Compliance, Logs, Users, Rooms, Spaces, Configuration) — only
   the media leaf was German, which was itself an inconsistency introduced by that one story.

## Story

**As an** admin operating the Nebu Admin UI,
**I want** the media-related pages grouped under a single "Media" nav item with clearly-labeled
children, instead of three flat, inconsistently-named top-level entries,
**so that** the nav structure is coherent and I can find the media table, settings, and health
dashboard without three separate top-level entries competing for space next to Dashboard,
Compliance, Users, Rooms, etc.

## Acceptance Criteria

1. **AC1 — One parent, not three leaves.** `/admin/media`, `/admin/media/settings`, and
   `/admin/media/health` are no longer separate top-level `<.nav_item>` entries. A single
   `<.nav_item key="media" children={media_nav_children()}>Media</.nav_item>` (or equivalently
   named helper, mirroring `config_nav_children()`/`logs_nav_children()`'s exact pattern —
   a module attribute list of `%{navigate:, key:, label:}` maps, plus a `defp` accessor) replaces
   them, positioned in the same place in the nav order the "Medien" leaf currently occupies
   (after Spaces, before Configuration).
2. **AC2 — Child labels.** The three children are labeled: "Media Explorer" (→ `/admin/media`,
   key `media-explorer`), "Settings" (→ `/admin/media/settings`, key `media-settings`), "Health"
   (→ `/admin/media/health`, key `media-health`) — dropping the redundant "Media" prefix on the
   latter two children, matching how `logs_nav_children`'s entries don't repeat "Logs" and
   `config_nav_children`'s entries don't repeat "Configuration". The Explorer child keeps the
   literal label "Media Explorer" (not just "Explorer") per explicit product direction — this is
   the one exception to the no-repeated-prefix convention, kept because "Explorer" alone doesn't
   read as media-related once nested.
3. **AC3 — Attention badge stays functionally identical, moves to the correct child.** The
   existing `nav-media-attention-badge` `<span>` (role="status", aria-hidden count +
   sr-only sentence, only rendered when `@media_attention_count` is a positive integer) attaches
   to the new "Media Explorer" child item (the one actually showing the table those attention
   counts describe) — not to the "Media" parent label. This mirrors the existing precedent of
   `war_room_dot_children/2` attaching its live pill to the specific "War Room" child, not to the
   "Logs" parent. No change to `Nebu.Admin.MediaAttentionBadge`, the PubSub wiring, or any
   `media_attention_count` assign default — this AC is purely about which nav node renders the
   existing span.
4. **AC4 — Active-state highlighting still works for all three children when navigated
   directly.** Visiting `/admin/media`, `/admin/media/settings`, or `/admin/media/health`
   directly (not via nav click) still highlights the correct child via the existing
   `active={@active_nav}` mechanism — verify against how `logs`/`config`'s existing children
   already handle this (check `nav_item/1`'s children-clause implementation for exactly how
   `active` is threaded to children before assuming behavior).
5. **AC5 — Keyboard/expand-collapse behavior matches the Logs/Configuration precedent exactly.**
   If `logs`/`config` render as an expandable disclosure (button + children list, matching the
   `admin-sidebar-nesting` story's AC9 "Configuration... pure disclosure toggle" note found in
   this same file), the new "Media" parent must behave identically — no new interaction pattern.
6. **AC6 — No regression to any existing route, LiveView module, or controller.** `/admin/media`,
   `/admin/media/settings`, `/admin/media/health` keep their exact current paths, backing
   LiveView/controller modules, and page content — this bug is nav-label/grouping only, not a
   routing or page-content change. `Nebu.Admin.MediaLive`, `Nebu.Admin.MediaSettingsController`,
   `Nebu.Admin.MediaHealthLive` (or whatever their real current module names are — verify against
   `server/lib/nebu/admin/router.ex`) are untouched.
7. **AC7 — Remove the now-stale "no Story 0 parent exists yet" comments.** The four inline
   comment blocks in `layouts.ex` (cited in Problem, above) explaining why these are flat leaves
   "until Story 0 lands" are removed or rewritten now that grouping exists — stale comments
   pointing at a since-fixed gap are worse than no comment.

## Dev Agent Guardrails

- Do not touch `Nebu.Admin.MediaLive`/`MediaSettingsController`/`MediaHealthLive`'s own route
  paths, module names, or page content — this is nav-presentation only.
- Do not invent a full "Story 0 Media Admin UX Foundation" scope (e.g. a shared media dashboard
  landing page, bulk actions, etc.) — that remains tracked follow-up debt. This bug fix is
  strictly the nav grouping + rename described above.
- Mirror `config_nav_children`/`logs_nav_children`'s exact code shape (module attribute + `defp`
  accessor) — don't invent a different children-list mechanism.
- Preserve the attention badge's accessibility properties (`role="status"`, aria-hidden count +
  sr-only sentence) exactly — this was itself a UX-gate-driven fix in story 5b, don't regress it.

## Dev Agent Record

### Completion Notes

- Added `@media_nav_children` module attribute + `defp media_nav_children/0` accessor in
  `server/lib/nebu/admin/layouts.ex`, mirroring `@config_nav_children`/`@logs_nav_children`'s
  exact shape. Children: `media-explorer` → `/admin/media` ("Media Explorer"),
  `media-settings` → `/admin/media/settings` ("Settings"), `media-health` →
  `/admin/media/health` ("Health").
- Replaced the three flat `<.nav_item>` leaves (media, media-settings, media-health) with a
  single `<.nav_item key="media" children={@media_children}>Media</.nav_item>` in the same
  position (after Spaces, before Configuration).
- `nav_item/1`'s children-rendering clause was extended with a generic per-child badge slot,
  gated on `Map.get(child, :badge_count)` being a positive integer — a no-op for every existing
  Logs/Configuration child (none carry `:badge_count`), verified by
  `layouts_nested_nav_test.exs`/`layouts_war_room_indicator_test.exs` continuing to pass
  unchanged. Added `defp media_badge_children/2` (mirrors `war_room_dot_children/2`'s precedent)
  which additively attaches `:badge_testid`, `:badge_count`, `:badge_sr_suffix` to the
  `media-explorer` child only. The badge's `role="status"`, aria-hidden count span, and sr-only
  sentence text ("Datei(en) benötigen Aufmerksamkeit") are byte-for-byte preserved from the
  former "Medien" leaf's badge span.
- `Nebu.Admin.MediaLive.mount/3` and `Nebu.Admin.MediaLive.Detail.mount/3` now assign
  `:active_nav` as `"media-explorer"` instead of `"media"` (the latter is now the parent's key,
  so it can no longer identify the active leaf) — required for AC4's active-highlighting
  contract; no route, module name, or page content changed (AC6).
  `Nebu.Admin.MediaSettingsController`/`Nebu.Admin.MediaHealthLive` already used
  `"media-settings"`/`"media-health"` and needed no change.
- Removed all four stale "Story 0 / no Medien parent exists yet" inline comment blocks (AC7),
  replaced with two comments describing the new grouped structure.
- `mix compile --warnings-as-errors --force`: clean. Full `mix test`: 1979 passed, 2 skipped,
  624 excluded (integration-tagged), exit 0 — no regressions.

### File List

- `server/lib/nebu/admin/layouts.ex` (modified)
- `server/lib/nebu/admin/media_live.ex` (modified — `active_nav` value only)
- `server/lib/nebu/admin/media_live/detail.ex` (modified — `active_nav` value only)

### Change Log

- 2026-07-30: Grouped the three flat media nav leaves under one "Media" parent with
  Explorer/Settings/Health children, renamed the parent label from "Medien" to "Media",
  moved the attention badge onto the "Media Explorer" child, extended `nav_item/1`'s
  children-rendering clause with a generic per-child badge slot, and removed the four stale
  "Story 0" comments. `layouts_media_nav_grouping_test.exs`: 20/20 passing. No regressions to
  `layouts_nested_nav_test.exs` or `layouts_war_room_indicator_test.exs`.
