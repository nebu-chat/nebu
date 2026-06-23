# Security Review (SEC Gate 1) — spaces-elixir-s3-hierarchy — 2026-06-21
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL/HIGH/MEDIUM, 2 INFO. (opus code-review APPROVED.)

SpaceHierarchy BFS + GET /_matrix/client/v1/rooms/{id}/hierarchy.

## Verified (private-room leak boundary holds)
- Root gate fires before any data on every page (incl. replayed token); non-member of non-public/non-world-readable root → 403, no rooms key. Forged token can't skip the gate.
- Hidden child never leaks: resolver returns :hidden before build_room_summary; excluded room's name/topic/members/avatar/children_state never constructed; children still traversed (spec). Visible parent's children_state exposes only the stripped m.space.child edge.
- Visibility predicate safe (member OR join_rule=public OR history_visibility=world_readable); guest_can_join/suggested/via/order output-only.
- Pagination token: url-safe Base64 "h1:"<>offset; fail-closed (400) on forgery; carries only offset, no internal state/injection.
- BFS cycle-safe (visited MapSet), limit≤1000, max_depth≥0 — no DoS.
- No IDOR (user from OidcPlug); param validation 400; SQL parameterised; migration 000005 idempotent+reversible additive partial indexes.

## INFO
- index not CONCURRENTLY (brief events write-lock on large existing instance; N/A fresh deploy).
- dangling edge to deleted room → :hidden (no enumeration oracle).

## FORWARD-WARNING for S4 (restricted-join MSC3083)
join_rules.allow[] is client-writable by PL≥50 (S2). S4 MUST validate every allow[] entry (type, well-formed room_id, requester actually joined the allowed space) + re-audit state_default bar. Hierarchy now surfaces join_rule:"restricted" — S4 allow-room resolution must not leak a private allow-room's existence.
