# Trace Map "Leitstand" — Design Spec (2026-07-07)

**Status:** Approved by Phil ("das ist echt cool") — authoritative design source for the
Trace Map redesign and Logs IA restructuring in the `enhanced-logging` epic.

**Source artifacts (all in this directory):**
- `trace-map-leitstand-dummy.html` — interactive, browser-verified design dummy
  (open locally or at https://claude.ai/code/artifact/a4d6fd3a-7897-451c-8d52-6fabd30ede9b).
  The dummy IS the spec for visual treatment, copy, and interaction feel; this document
  adds the contract-level details and implementation constraints.
- Screenshots: `tracemap-initial.png`, `tracemap-outage.png`, `tracemap-v2-capture.png`,
  `tracemap-v2-banner.png`, `tracemap-v3-resized-errorfilter.png`, `warroom-active.png`.

**Why (Phil's verdict on the shipped UX):** the flat bubble list and the disclosure tree
(`trace-map-hierarchy`) are "unbrauchbar" as a monitoring surface. The Trace Map becomes a
control-room ("Leitstand") health map: at a glance, see *where* it is red.

---

## 1. Information architecture

Sidebar gets collapsible groups (covered by existing story `admin-sidebar-nesting`):

```
Logs                 (disclosure group, aria-expanded)
├── Live Stream      /admin/logs            (existing page, unchanged)
├── Trace Map        /admin/logs/trace-map  (NEW page — this spec)
└── War Room         /admin/logs/war-room   (story: war-room-dedicated-page)
Configuration        (disclosure group)
├── General          /admin/config
├── Role Mapping     /admin/config/role-mapping
└── Claim Mapping    /admin/config/claim-mapping
```

The Trace Map is no longer a filter widget embedded in the logs page — it is its own
LiveView. The flat `TraceMapBubble` strip and the `TraceMapTree` disclosure tree are
retired from the logs page in favor of this view (Live Stream keeps its own simpler
filters; exact migration is a story-scoping decision).

## 2. The radial map

**Hierarchy:** center `nebu` → domain circles → endpoint satellites.
Domains come from the existing heuristic `Nebu.Admin.LogsLive.TraceMapTree.domain_for_endpoint/1`
(`/_matrix/client`, `/_matrix/media`, `/admin`, `/health`, catch-all) — REUSE it, do not
duplicate. Satellites are the observed `route_template`s, first-observed order.

**Geometry (from the dummy, SVG viewBox −560 −400 1120 800):** center r=52 at origin;
domains r=38 on a ring R1≈195 at fixed angles (−48°, 48°, 132°, −132° for 4 domains —
distribute evenly if domain count differs); satellites r=24 on R2≈128 around their domain,
fanned over `min(130°, n·26°)` centered on the domain's outward angle. Edges are trimmed
lines (node edge + 4px), `--line` color, opacity ~.55.

**Status model:** per node, a sliding **60 s** window over its log events.
`error > 0 → error`, else `warn > 0 → warn`, else `ok`. A parent's status is the worst
of its children (satellite → domain → nebu). Nodes heal automatically when the window
passes — no manual acknowledge.

**Visual states (Obsidian theme tokens from `server/assets/tailwind.config.js`):**

| State | Fill | Stroke | Extras |
|---|---|---|---|
| ok | `base-200` @ 35% opacity | `success` @ 55%, 1.5px | label dimmed — healthy recedes |
| warn | `#431407` (warn-bg) | `warning`, 2.5px + soft glow | ▲ badge with warn count |
| error | `#450a0a` (err-bg) | `error`, 3px + glow + pulse animation | ✕ badge with error count |
| selected | — | extra `primary` ring at r+7, 2.5px | orange = selection ONLY |
| logging off | `base-200` @ 15% | `text-disabled`, 1.5px **dashed** | count shows "off" |
| temp capture | as status | status color, **dashed** | countdown mm:ss on the node |

Status colors are reserved for health, primary orange for selection — never cross-used.
Status is never conveyed by color alone: badges (▲/✕ + count), "off" text, aria-labels.
Counters inside nodes (requests/60 s; center shows `N/min`) in mono font. Event "pings"
(expanding rings) on nodes are decorative and disabled under `prefers-reduced-motion`
(as is the error pulse).

## 3. Interactions

- **Click / Enter / Space on a node** toggles it as a stream filter (multi-select, OR
  within the dimension; domain matches all its satellites). Click on `nebu` clears all
  filters. Active filters render as removable chips in the stream header + "Clear all".
- **Hover / focus** shows a tooltip (name, route, status, req/warn/err per 60 s, CTA).
  Tooltip hides on click. Focus also targets the node in the inspector.
- **Inspector panel (right column)** for the focused/clicked node — see §4.
- **Legend card** (right column) explains all six states; always visible.

## 4. Inspector = per-node logging control panel

Live stats (requests / warnings / errors per 60 s, status pill, last 5 events) PLUS
logging controls:

- **Min level** select (DEBUG/INFO/WARN/ERROR) — wires to the per-endpoint collection
  level from `admin-logs-retention-settings` (done). On a domain node or `nebu` the
  setting cascades to all descendant endpoints, with the note "Applies to all endpoints
  in this domain" / "on the map".
- **Retention** select (1 h / 24 h / 7 d / 30 d) — same config backend.
- **Capture control** for long-polling endpoints (§5): state line + Enable/Disable button
  with live countdown.

UI contract: the panel is BUILT once per inspected node and only its stat values update
per tick — selects must never lose value/focus to a re-render (same class of bug as the
trace-map-filter-reset incident).

## 5. Long-polling endpoints: off by default, temporary capture

Supersedes the UI concept of `noise-endpoint-bucketing` (ready-for-dev — realign that
story): instead of a "noise bucket", low-signal long-polling endpoints (default list:
`/_matrix/client/v3/sync`, `/admin/keepalive`, `/health`; config-driven) are
**logging-off by default**:

- Rendered gray + dashed, count "off", no log data collected, no status.
- **Click enables temporary capture for 5 minutes** (announce via aria-live): node comes
  alive with dashed status stroke + countdown on the node and in the inspector;
  "Disable now" in the inspector ends it early. After expiry it falls back to off
  automatically — server-side timer, no client state.
- While capturing, a second click toggles the stream filter as normal.

## 6. War-room visibility

While a war-room session is active (from `war-room-dedicated-page` / existing
`war_room_manager.ex`): a red banner across the top of the Trace Map view — recording
dot + "War Room session active — capturing {user} · {elapsed}" + "Open War Room" button.
(Nav-item dot and topbar pill belong to the war-room story; the banner belongs to the
Trace Map story.)

## 7. Live stream panel (bottom of the Trace Map view)

- Compact mono log lines: time, level (colored), route, message. Autoscroll pauses on
  hover. Filtered by the map selection AND the level filter.
- **Resizable:** drag handle between map and stream (`role="separator"`,
  `aria-orientation="horizontal"`, tabindex=0; pointer drag with capture, ArrowUp/Down
  ±32px, dblclick resets to default 218px, Home/End max/min; clamp ~64px…viewport−140px).
- **Level filter pills** (DEBUG/INFO/WARN/ERROR, `aria-pressed`, level colors) with the
  leitstand shortcut: when ALL levels are active, clicking one shows ONLY that level;
  clicking the sole active level restores all; otherwise plain toggle.

## 8. Hard implementation constraints

1. **Filter/selection/expansion state lives in LiveView assigns driven by URL query
   params** (`push_patch` + `handle_params/3`) — NEVER client-DOM-only state on nodes
   that re-render under live traffic (root cause of the trace-map-filter-reset bug).
   Bookmarkable URLs fall out for free.
2. **CSP is `script-src 'self'`, no inline JS.** Client-only behavior (tooltip
   positioning, resizer drag, ping animations) goes through the established
   `app.js` `wire*` / `JS.dispatch` pattern or a `phx-hook` defined in
   `server/priv/static/assets/app.js`.
3. SVG is rendered server-side in HEEx (positions computed in Elixir — plain module,
   ADR-018/021 compliant); LiveView patches update node classes/counters.
4. Accessibility is blocking, not advisory: nodes are focusable
   `role="button" aria-pressed` elements with status+counts in `aria-label`;
   `aria-live="polite"` announcements for new errors (throttled) and capture
   enable/disable; visible focus rings; WCAG AA contrast per the Obsidian tokens;
   Playwright tests use `getByRole`/`getByLabel`.
5. No sensitive data on the map, in tooltips, or in the stream (No-Sensitive-Data law —
   route templates and counts only, never payloads/tokens/message content).
6. E2E coverage must grow with every UI story (pipeline CI gate).

## 9. Suggested story cut

1. `admin-sidebar-nesting` (exists, ready-for-dev) — matches the dummy as-is.
2. `war-room-dedicated-page` (exists, backlog) — add ACs: nav-item recording dot,
   topbar recording pill with elapsed time.
3. **NEW `trace-map-leitstand`** — the radial map page: hierarchy, status model +
   propagation, visual states, node filters + chips, tooltip, legend, war-room banner,
   resizable stream + level filter. (Largest story; may split map vs. stream panel.)
4. **NEW `trace-map-node-controls`** — inspector logging controls (level/retention wiring,
   cascade) + long-polling off-by-default with temporary capture (realigns
   `noise-endpoint-bucketing`).

## Addendum (2026-07-07, Phil)
- §1 IA correction: the Logs group child pointing at /admin/logs/config is labeled
  **"Log Retention"** (not "Configuration"; navkey `logs-config` stays). Resolves UX
  advisory A1 (duplicate accessible name vs. the top-level Configuration group).

## Addendum (2026-07-07, design owner — §5 correction)
- "Logging off" suppresses DEBUG/INFO/WARN collection and status, but ERROR entries are
  ALWAYS persisted and always drive node status (red dashed stroke + ✕ badge on an off
  node). Off silences noise, never failures.
- Inspector retention options are 1 d / 7 d / 30 d (day-granularity backend); the
  dummy's "1 h" option is dropped.

## Addendum (2026-07-08, UX gate V1/V2 correction — trace-map-node-controls)
- §5's "logging off" row prescribing `text-disabled` for the node label/stroke is
  WRONG and superseded by the same lesson already applied to warn/error text: off
  nodes are operable (clickable to enable capture), so use `text-secondary` (#9ca3af)
  at full opacity for the label/count text and the stroke — never `text-disabled`.
- The off+error composite state (errors-always-persist amendment) must announce
  "logging off" in its aria-label, not just the generic error phrasing — the
  dashed-vs-solid stroke is otherwise the only signal of that distinction, and status
  must never be conveyed by shape/color alone.

## Addendum (2026-07-09, overlap fix — trace-map-leitstand)
- §2 geometry corrected: R1 (domain ring) 195→220; R2 (satellite ring) is no
  longer a fixed 128 — it grows with a domain's own satellite count
  (`Nebu.Admin.TraceMapGeometry.satellite_ring/1`: base 150, +8 per satellite
  beyond 6) so a crowded domain (e.g. `/_matrix/client` with dozens of
  distinct observed routes) never renders overlapping circles. The fan-spread
  cap also widened from `min(130°, n·26°)` to `min(320°, n·24°)`.
- §5 off-by-default long-polling list gains `/admin/live/longpoll` (the
  Phoenix LiveView socket's own transport-polling endpoint, hit continuously
  by every open admin page) — reported as visually indistinguishable from
  noise, same class as `/_matrix/client/v3/sync`.

## Addendum (2026-07-09, resizer direction + persistence fix — trace-map-leitstand)
- §7's resizer direction was backwards: dragging the handle UP now grows the
  stream (matches the standard split-pane convention — moving the divider up
  gives the panel below it more room); dragging DOWN shrinks it. Keyboard:
  ArrowUp grows, ArrowDown shrinks (swapped to match). Home/End unchanged
  (minimize/maximize).
- Resize no longer resets on the next LiveView update: the stream panel's
  height is entirely client-owned (no server assign), so every periodic
  re-render (status tick, new log line) was morphdom-syncing the section's
  attributes back to the server's style-less markup, silently discarding a
  live resize within ~1s. Fixed by having the TraceMapLeitstand hook
  reassert the last user-chosen height in its own `updated()` callback,
  immediately after every patch.

## Addendum (2026-07-09, domain-separation fix — trace-map-leitstand)
- §2's domain layout replaced with a compass arrangement (identity-keyed,
  not position-zipped, so it applies to any subset/order of the known
  domains, not only when all 4 are simultaneously observed):
  `/_matrix/client` east (0°), `/_matrix/media` north (-90°), `/admin` west
  (180°), `/health` south (90°). Admin and Matrix Client — the two domains
  that realistically get crowded — sit diametrically opposite (180° apart,
  the maximum possible separation), same height, left/right of nebu. This
  replaces the original hand-placed `[-48, 48, 132, -132]` (only ~84-96°
  apart), which combined with the widened per-domain satellite fan (see the
  overlap-fix addendum above) let two busy neighboring domains' fans
  visually collide with each other.

## Addendum (2026-07-09, domain-distance fix — trace-map-leitstand)
- §2's domain ring (R1) widened 220→300: domains — Admin and Matrix Client
  especially — sit noticeably further from nebu, more breathing room before
  a crowded domain's own satellite fan.
- The SVG viewBox widened to match, `-560 -400 1120 800` →
  `-780 -650 1560 1300`, so the wider layout doesn't clip nodes (confirmed
  live: Health's own satellite was rendering outside the old viewBox's
  bottom edge before this fix).
- Open design question (not yet decided, no code change): does the
  nebu→domain edge line add value, or would the radial layout alone
  (position/angle already implies grouping) be cleaner without it? Deferred
  to the design owner.
