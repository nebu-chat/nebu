# Security Review (SEC Gate 1) — spaces-elixir-s2-state-events — 2026-06-21
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL/HIGH. Cleared. (opus code-review APPROVED, 0 blocking.)

Generic Matrix state-event PUT + m.space.child/parent.

## Verified
- Allowlist enforced FIRST (before room lazy-start/existence): m.room.member/power_levels/create + non-allowlisted → 403, unforgeable; case/whitespace/custom variants rejected.
- PL check reads server-authoritative Room state.power_levels (:change_state ≥ state_default); non-member/under-PL → 403.
- m.space.parent: parent existence (404) + parent membership (403) — no false hierarchy.
- Server-authoritative top-level fields (sender from OidcPlug current_user; type/room_id/event_id/ts built server-side); content_json only client payload; SQL $1 parameterised; 1MB body cap.

## FORWARD-WARNING for S4 (MSC3083 restricted join)
m.room.join_rules is now client-writable by a PL≥50 member. When restricted-join lands, a moderator setting join_rules.allow[] becomes a membership-bypass primitive. S4 MUST validate allow[] entries (referenced rooms exist + setter has authority) and re-audit whether state_default=50 is a high-enough bar for join_rule changes on Spaces.
