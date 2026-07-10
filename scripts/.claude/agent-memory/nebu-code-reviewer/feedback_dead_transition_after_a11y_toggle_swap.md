---
name: dead-transition-after-a11y-toggle-swap
description: When a UX-gate a11y fix swaps an animated show/hide for a binary hidden/display toggle, the transition-* utility classes go dead and the AC's "smooth animation" requirement silently goes unmet
metadata:
  type: feedback
---

When a UX/a11y gate forces a collapsible from an animatable show/hide (max-height / opacity transition) to a binary `hidden`{display:none} toggle for correctness (Tab-reachability), the leftover `transition-all`/`transition-transform` utility classes become dead code AND the story's "smooth open/close animation" AC (e.g. AC5 here) silently goes unmet — `display:none↔flex` is not animatable, and a chevron that swaps glyph text (▼/▶) instead of applying a CSS transform never fires `transition-transform`.

**Why:** trace-map-hierarchy cycle-1 fixed the `.flex` overriding `[hidden]` cascade bug by making layout classes conditional on expansion, but left `transition-all duration-200` on the leaves container and `transition-transform duration-200` on the chevron — both now no-ops. AC5 explicitly required smooth animation; the checkbox "uses transition utilities" is literally present but non-functional.

**How to apply:** After any fix that changes a collapsible's mechanism to `hidden`/display-toggle, grep the same element(s) for orphaned `transition-*` classes and flag them (MINOR: dead classes + unmet animation AC). Related bug-class origin: [[the fixed instance is the cascade bug already tracked]].
