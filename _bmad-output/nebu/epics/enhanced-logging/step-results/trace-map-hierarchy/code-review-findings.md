# Code Review — trace-map-hierarchy (cycle 0)

0 MAJOR. 3 MINOR:
- MINOR-1: AC5 "smooth open/close animation" unmet — transition-all/transition-transform classes are dead code after the cycle-1 a11y fix switched to binary hidden<->flex + glyph-swap chevron (neither is animatable as currently coded). Either remove dead classes (descope AC5's animation, document why) or reimplement compatibly with Tab-hiding.
- MINOR-2: aria-label always says "Expand..." even when already expanded (contradicts aria-expanded=true when announced by SR). Fix: verb-free label "Endpoints under <domain>", rely on aria-expanded alone (matches ARIA APG, which the moduledoc itself already cites). Requires updating story AC1 example + component test's label assertion too.
- MINOR-3: no carried-over/new test exercises the real "expand domain, THEN click now-visible leaf" flow — existing tests click leaves via render_click which ignores CSS visibility gate. Add one test: toggle domain open, then click the now-visible leaf, confirm filter applies.

3 INFO (no action needed): redundant per-render grouping computation (accepted at documented scale); first-paint now shows 0 bubbles until expand (intentional per AC2, not a defect, just noting UX change); @domain_overrides accumulates harmless stale keys for vanished domains.

AC8 confirmed additive-only (+207/-0 diff to logs_live_test.exs).
