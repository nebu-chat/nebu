# Session — Trace Map Leitstand redesign (design dummy, 2026-07-07)

**Context:** Phil rejected the shipped enhanced-logging Trace Map UX: the flat bubble
list (and even the disclosure tree from trace-map-hierarchy) is "unbrauchbar", and War
Room is still not a sidebar submenu. He asked Sati + Sally (bmad-agent-ux-designer) for
a proper interactive design dummy to feed back into the nebu-pipeline.

**What changed:** No pipeline-protected code touched. Built an interactive single-file
HTML design dummy: `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-dummy.html`
(+ screenshots `tracemap-initial.png`, `tracemap-outage.png`, `warroom-active.png` in the
same dir). Published as Claude Artifact ("leitstand-v1"):
https://claude.ai/code/artifact/a4d6fd3a-7897-451c-8d52-6fabd30ede9b

**Design concept (Phil's brief, refined):**
- Trace Map = "Leitstand" radial health map: center circle `nebu` → domain circles
  (Matrix Client, Matrix Media, Admin, Health, from the endpoint-domain heuristic in
  `TraceMapTree.domain_for_endpoint/1`) → endpoint satellites.
- Status via sliding 60 s window: healthy = translucent fill + subtle green border
  (recedes); warn = amber border + glow + ▲ count badge; error = red border + pulse +
  ✕ count badge. Worst-child status propagates inward (satellite → domain → nebu).
  Never color-alone: icons + count badges + aria-labels (No-Sensitive-Data + WCAG laws).
- Click node = toggle stream filter (multi-select, chips above stream, click nebu =
  clear). Nodes are `role=button aria-pressed` with keyboard support. Selection ring =
  primary orange, reserved for selection only; status trio reserved for health only.
- Sidebar: Logs becomes a disclosure group (Live Stream / Trace Map / War Room);
  Configuration likewise (General / Role Mapping / Claim Mapping). Active War Room
  session = pulsing red dot on the nav item + recording pill (user + timer) in topbar.
- Obsidian theme tokens exactly from `server/assets/tailwind.config.js`.

**New patterns established:** Leitstand status vocabulary (transparent-green /
amber-glow / red-pulse, inward propagation, 60 s heal window); demo controls pattern
for design dummies (inject warn/error, scenario button, rate slider, clearly badged
"Demo · simulated traffic").

**Accessibility findings:** Dummy carries aria-pressed/aria-expanded/aria-live
announcer, focus-visible rings, prefers-reduced-motion fallbacks — these must survive
into the LiveView implementation (real impl: filter state in LiveView assigns via URL
params, NOT client-DOM — see the confirmed bug in MEMORY.md).

**v2 (same session, after Phil approved v1 "ja so habe ich mir das vorgestellt"):**
- Inspector is now the per-node logging CONTROL PANEL: Min level select (cascades from
  domain/center to all descendant satellites) + Retention select; built once per node,
  only stats update per tick (so selects keep value/focus).
- Long-polling endpoints (sync, keepalive, health) are logging-OFF by default: gray
  dashed nodes showing "off", produce no log data. Click enables temporary capture
  (real: 5 min; dummy: 60 s) with a countdown on the node (dashed status stroke =
  temporary) and in the inspector ("Disable now" available); falls back to off
  automatically. Second click while capturing = normal filter toggle.
- Active War Room session shows a red banner across the Trace Map view (recdot +
  user + timer + "Open War Room" button), in addition to nav dot + topbar pill.
- Artifact republished as "leitstand-v2-controls", same URL.

**v3 (Phil: "die ansicht passt gut"):**
- Live-stream panel is resizable: drag handle between map and stream (pointer capture),
  arrow up/down when focused (role=separator), double-click resets, Home/End = max/min.
- Stream level filter: DEBUG/INFO/WARN/ERROR toggle pills in the stream header with
  the leitstand shortcut — clicking a level while all are active shows ONLY that level;
  clicking the sole active level restores all; otherwise plain toggle. aria-pressed,
  level colors match the log-line chips.
- Random baseline warn rate lowered (0.4%) so the resting state reads green.
- Artifact republished as "leitstand-v3-stream", same URL.

**Follow-up:** Awaiting Phil's feedback on the dummy; then write the design spec /
stories for `/nebu-pipeline --epic enhanced-logging` (likely: sidebar-submenu story +
trace-map-leitstand story, replacing the disclosure tree). SVG map needs a CSP-clean
implementation path (no inline JS — extend `app.js` wire* pattern or a LiveView hook
file in priv/static).
