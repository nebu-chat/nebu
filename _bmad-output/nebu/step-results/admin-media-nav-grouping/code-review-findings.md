# Code Review Findings — bugfix/admin-media-nav-grouping

Reviewer: bmad-code-review (adversarial: Blind Hunter / Edge Case Hunter / Acceptance Auditor)
Date: 2026-07-30
Scope: staged diff vs HEAD, files:
- `server/lib/nebu/admin/layouts.ex`
- `server/lib/nebu/admin/media_live.ex`
- `server/lib/nebu/admin/media_live/detail.ex`
- `server/test/nebu/admin/layouts_media_nav_grouping_test.exs`
- `docs/stories/bugfix/admin-media-nav-grouping.md`

Unrelated in-flight working-tree changes (docker-compose.yml, pipeline-state.yaml, memory files,
e2e/manual-media-shots/) were ignored per instructions.

## Verdict: MINOR (2 non-blocking issues). No MAJOR/CRITICAL.

---

## Acceptance Auditor — AC-by-AC verification

- **AC1 (one parent, not three leaves):** PASS. `@media_nav_children` module attribute
  (layouts.ex:84-88) + `defp media_nav_children/0` accessor (line 230) mirror
  `@config_nav_children`/`@logs_nav_children` code shape exactly (module attribute list of
  `%{navigate:, key:, label:}` maps + `defp` accessor). Single
  `<.nav_item key="media" children={@media_children}>Media</.nav_item>` (line 206) replaces the
  three flat leaves, positioned after Spaces (line 196) and before Configuration (line 207).
  Pre-dev flag #1 (module-attribute + defp accessor code shape) — CONFIRMED addressed.
- **AC2 (child labels/keys/routes):** PASS. `media-explorer`→`/admin/media`("Media Explorer"),
  `media-settings`→`/admin/media/settings`("Settings"), `media-health`→`/admin/media/health`
  ("Health"). Redundant "Media" prefix dropped on Settings/Health, kept on Explorer per product
  direction.
- **AC3 (badge moves to Explorer child, functionally identical):** PASS. `media_badge_children/2`
  (lines 238-250) additively merges badge fields onto the `media-explorer` child ONLY — mirrors
  `war_room_dot_children/2` precedent. Pre-dev flag #2 (badge NOT on settings/health, only
  explorer): CONFIRMED — the `if child.key == "media-explorer"` guard means Settings/Health never
  receive `:badge_count`, so the generic badge span (lines 427-435) never renders for them.
  Test 271-279 confirms the badge does not render on the parent button.
  Pre-dev flag #3 (byte-for-byte accessibility content): CONFIRMED preserved. Manual comparison
  of the former "Medien" leaf badge span vs the new generic child badge span:
  - `role="status"` — identical.
  - `class="badge badge-sm badge-error ml-1"` — identical.
  - aria-hidden count: `<span aria-hidden="true">{child.badge_count}</span>` — identical.
  - sr-only sentence: old `{@media_attention_count} Datei(en) benötigen Aufmerksamkeit` renders
    "N Datei(en) benötigen Aufmerksamkeit"; new `{child.badge_count}{Map.get(child,
    :badge_sr_suffix)}` with `badge_sr_suffix: " Datei(en) benötigen Aufmerksamkeit"` (leading
    space) renders the identical string. Byte-for-byte equivalent.
  - `data-testid` "nav-media-attention-badge" preserved via `badge_testid`.
  - render condition `is_integer(...) and ... > 0` preserved.
- **AC4 (active-state highlighting on direct nav):** PASS. `active_nav` renamed "media" →
  "media-explorer" in `MediaLive.mount/3` and `MediaLive.Detail.mount/3`;
  `MediaSettingsController` already used "media-settings", `MediaHealthLive` already used
  "media-health" — all match child keys, so `nav_item/1`'s child clause
  (`child.key == @active`) primary-highlights the correct child and the parent gets the
  secondary `bg-base-300` accent. Verified against the existing children-clause implementation.
- **AC5 (keyboard/expand-collapse parity):** PASS. Uses the identical generic `nav_item/1`
  parent clause (button + aria-expanded/aria-controls + toggle icon + `hidden`-only collapse) as
  Logs/Configuration — no new interaction pattern.
- **AC6 (no route/module/content regression):** PASS. `server/lib/nebu/admin/router.ex` media
  routes unchanged (MediaLive @ /media, MediaHealthLive @ /media/health, MediaLive.Detail @
  /media/:media_id, MediaSettingsController @ /media/settings). Only `active_nav` string values
  changed in the two LiveViews; no route path, module name, or page content touched. MediaLive
  page still renders `<h1>Medien</h1>` (line 988) so the existing E2E step
  `admin-media-overview.feature:27` ("the page shows Medien") is unaffected.
  Pre-dev flag #4 (router/module-binding correctness): CONFIRMED.
- **AC7 (remove stale "Story 0" comments):** PASS. All four stale comment blocks removed from
  layouts.ex, replaced with two comments describing the new grouped structure. Test AC7 greps the
  source for "Story 0" / 'no nested "Medien" parent' and both are gone.

## Blind Hunter — the "supporting change" (active_nav rename) scrutiny

- **Genuinely necessary, not scope creep:** With the leaf collapsed into a parent keyed "media",
  had `MediaLive`/`Detail` kept `active_nav = "media"`, the parent button would match
  `key == active` and get the PRIMARY highlight, while NO child would get `aria-current="page"`
  (no child key equals "media"). AC4 requires the specific child to be primary-highlighted. The
  rename to "media-explorer" is the minimal change that satisfies AC4. Confirmed necessary.
- **Nothing else references the old "media" active_nav key:** `grep -rn 'active_nav.*"media"'`
  across server/lib and server/test returns zero hits. All four media backing modules now assign
  child-matching keys (media-explorer / media-settings / media-health). No dead/controller render
  still sets `active_nav = "media"`. No E2E/Playwright selector keys off `active_nav = "media"`
  (only `admin-media-overview.feature` touches media, and it asserts page body text, not nav).

## Edge Case Hunter — generic per-child badge slot backward-compatibility

- **Not a lucky coincidence — the guard is robust.** The new badge span
  (lines 427-435) is gated on `is_integer(Map.get(child, :badge_count)) and Map.get(child,
  :badge_count) > 0`. `Map.get/2` returns `nil` for every Logs/Configuration child (none carry
  `:badge_count`) → `is_integer(nil)` is `false` → span never renders. `{child.badge_count}` and
  `{Map.get(child, :badge_sr_suffix)}` are only evaluated INSIDE the guarded `:if`, so no
  KeyError for badge-less children. The war-room `:dot` slot is likewise `Map.get(child, :dot,
  false)` and orthogonal — the media-explorer child never carries `:dot`, and logs children never
  carry `:badge_count`. Both optional slots coexist safely.
- **Additive-merge pattern is idiomatic** and matches `war_room_dot_children/2` exactly.
- `media_attention_count` non-integer/nil values: handled identically to the pre-change guard.
- Detail page (`/admin/media/:media_id`) sets `active_nav = "media-explorer"` → correctly
  highlights the Explorer child (detail is logically under the table). No badge on detail (uses
  the nil `media_attention_count` default). No regression.

## Test-quality review (layouts_media_nav_grouping_test.exs)

- 20 tests, non-tautological, real assertions across AC1-AC7 using Floki against rendered HTML +
  real router dispatch for the active-state/route tests. Positioning, disclosure markup, child
  keys/labels/hrefs, badge placement, parent-vs-child highlight, and source-comment removal are
  all covered. Good quality.

---

## Findings

### MINOR-1 — AC3 byte-for-byte accessibility content is preserved but NOT guarded by a test
The Dev Agent Guardrails call the badge's accessibility markup (`role="status"`, aria-hidden
count, sr-only sentence) a "UX-gate-driven fix... don't regress it". The implementation preserves
it exactly, but the AC3 tests only assert the badge's presence, `data-testid`, and
`role="status"` on the Explorer child. No test asserts the aria-hidden count value or the sr-only
sentence text ("Datei(en) benötigen Aufmerksamkeit"). A future refactor of `media_badge_children/2`
or the badge span could silently drop or alter the sr-only equivalent with no failing test.
Recommendation: add one assertion for the sr-only sentence text and the aria-hidden count span.
Non-blocking (implementation is correct today).

### MINOR-2 — Stale moduledoc comment left in media_settings_controller_test.exs
`server/test/nebu/admin/media_settings_controller_test.exs` (moduledoc, ~lines 83-90) still states
the "Medien" parent nav item "does not exist yet anywhere in server/lib/nebu/admin/layouts.ex (no
prior story creates it)". That parent now exists. AC7 scoped only layouts.ex, so this is outside
the story's staged files, but the change to layouts.ex makes this comment actively misleading.
Recommendation: update or remove the note. Non-blocking.

### Informational (not a finding)
Nav child label is now "Media Explorer" (English) while the destination page's own `<h1>` remains
"Medien" (German, layouts unchanged per AC6). This nav-label/page-heading mismatch is DELIBERATE —
AC6 forbids page-content changes and the E2E suite still asserts the "Medien" heading. Flag for
product only; not an implementation defect.

## Compile/test note
Static review only; the suite was not independently re-run in this review. Dev Agent Record claims
`mix compile --warnings-as-errors --force` clean and `mix test` 1979 passed / 2 skipped / 624
excluded, exit 0, with layouts_media_nav_grouping_test.exs 20/20 and no regression to
layouts_nested_nav_test.exs / layouts_war_room_indicator_test.exs. The code changes are low-risk
and consistent with that claim.
