---
name: additive-regression-passes-via-hidden-element-find
description: A "no regression" AC proven by a purely-additive test diff can pass only because LiveViewTest/Floki find nested AND hidden elements regardless of visibility — the tests never prove a real user can reach the element post-restructure
metadata:
  type: feedback
---

When a render structure changes from flat to nested-and-initially-hidden (e.g. flat bubble list -> collapsed disclosure tree) and the "no regression" AC's test diff is purely additive (0 deletions to existing tests), the existing tests keep passing NOT because behavior is preserved for a user, but because `Phoenix.LiveViewTest` `element/2 |> render_click/1` and `Floki.find/2` locate elements regardless of CSS visibility or `hidden` attribute. So a test that "clicks an endpoint bubble" still passes even though, at mount, every endpoint domain is collapsed and every leaf carries `hidden` — a real user must expand the domain first.

**Why:** trace-map-hierarchy AC8: existing endpoint-click tests (`find_bubble/3` = unscoped `Floki.find`) passed unmodified. Legitimate for proving the leaf still EXISTS, but none of the carried-over tests exercise the new expand-then-click gate; fidelity gap, not a code bug.

**How to apply:** For a "no regression" AC where render structure changed to hide/nest elements by default, verify at least one test exercises the NEW gating path (expand domain, then click a now-visible leaf) rather than only the visibility-bypassing find. Flag MINOR if all carried-over interaction tests click through the bypass. Sibling of [[fix-lacks-direct-regression-test]].
