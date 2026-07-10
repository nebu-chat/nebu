# UX Gate — admin-sidebar-nesting (2026-07-07)

Verdict: 1 violation (blocking, sent to dev), 5 advisories.

## V1 (BLOCKING → dev fix in progress)
/admin/config loses programmatic current-page indication (WCAG 1.3.1 regression):
config_controller.ex:256 assigns active_nav "config" (parent = pure disclosure button,
never emits aria-current). Fix: assign "config-general" (child key).

## Advisories
- A1: Duplicate accessible name "Configuration" — Logs child (/admin/logs/config,
  from story AC7) vs top-level Configuration group. Spec §1 / approved dummy do NOT
  contain this Logs child — story and design source conflict; implementation followed
  the story. DECISION FOR PHIL (options: drop child per Leitstand IA, or rename label
  e.g. "Retention"/"Log Settings"). Slated for resolution in trace-map-leitstand story.
- A2: Stub routes /admin/logs/trace-map + /admin/logs/war-room highlight "Live Stream"
  (aria-current on logs-monitoring). Transitional; the repointing stories MUST assign
  "logs-trace-map"/"logs-war-room". Coordination note for those stories.
- A3: Documented deviations: parent = pure toggle (keyboard contract supersedes AC13
  label-navigates); "General" appended last (spec lists first); groups default expanded
  (dummy shows non-active group collapsed) — all documented, cosmetic.
- A4: No E2E scenario proving a collapsed section stays collapsed under live morphdom
  traffic on /admin/logs (the TraceMapBubble state-wipe bug class). Analysis says safe
  (nav dynamics derive from never-changing assigns) but a pinning scenario is
  recommended — candidate for trace-map-leitstand story's E2E growth.
- A5: Sanctum BOND.md/MEMORY.md "PRD Accessibility Requirements" sections are unfilled
  placeholders — backfill in a full Sati session; this audit ran on WCAG 2.1 AA +
  story ACs + Leitstand design source.

## Clean checks
Disclosure pattern complete + dummy-consistent; keyboard via native button; hidden
removes children from tab order (flex-beats-hidden pitfall verified avoided, compiled
app.css retains [hidden] display:none); focus rings identical to existing items;
state not color-only; data-navkey continuity incl. role-mapping/claim-mapping;
role=list + nav landmark intact; all classes existing theme utilities (AC14).
