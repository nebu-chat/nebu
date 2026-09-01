# UX Gate — Story 10b (clamav-status-freshclam-age)

## BLOCKING
Missing `aria-live`/`role="status"` on poll-updating content. The new "ClamAV-Status" section
in server/lib/nebu/admin/media_health_live.ex (lines ~208-231) re-renders on the same 2s
handle_info(:refresh_clamav_status, ...) poll tick as WarRoomIndicator, but has zero
aria-live/role="status" markup. This is a genuine gap, not an acceptable precedent-match:
WarRoomIndicator's own topbar pill (server/lib/nebu/admin/layouts.ex:138) and
MediaAttentionBadge's nav badge (layouts.ex:212) both use role="status", and layouts.ex has an
explicit existing comment (lines 208-219) stating this as a hard rule for any live-updating
value: needs (1) role="status" so a screen-reader user is notified of a changed value without
having to poll by tabbing to it, and (2) an sr-only text equivalent. Story 10b's own AC6 models
this section "directly on the already-shipped WarRoomIndicator pattern" but only copied the poll
mechanics, not the accessibility half of that same pattern.

Fix: wrap the dynamic status content in a role="status" container (implicit aria-live="polite"
+ aria-atomic="true"), consistent with layouts.ex's documented rule and trace_map.ex's
aria-live="polite" announcer pattern for similar live content.

## PASS (no issue)
1. Color-alone signaling (WCAG 1.4.1) — every state has distinguishing text alongside the
   badge class, no color-only state.
2. Semantic structure/heading hierarchy — matches the existing throughput/duration/backlog/
   error-rate sections' pattern exactly.
3. Keyboard/focus — no interactive elements in the new markup, nothing needed.
4. DaisyUI class reuse — badge-success/error/warning match existing usage elsewhere
   (compliance_html.ex, rooms_html.ex), no ad hoc colors.

## NON-BLOCKING
<p class="badge ..."> instead of <span class="badge ...">  — existing badge usage elsewhere
uses <span> for inline chips; this section uses block-level <p>. Not a WCAG violation, just a
DaisyUI consistency deviation — fine to fix opportunistically, not before ship.

## Verdict
BLOCKED — 1 blocking accessibility violation (missing role="status"/aria-live on poll-updating
ClamAV status content). Per pipeline policy, UX gate blocking violations are escalated to the
user rather than auto-fixed by this orchestrator.
