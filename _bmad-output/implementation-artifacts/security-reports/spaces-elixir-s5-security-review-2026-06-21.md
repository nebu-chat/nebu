# Security Review (SEC Gate 1) — spaces-elixir-s5-admin-spaces — 2026-06-21
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL/HIGH/MEDIUM, 1 LOW (info). (opus code-review APPROVED.)

Admin Spaces UI (list/create/edit/child) + auto-join spaces.

## Verified (admin-as-matrix-user bypass defeated)
- matrix_user_id server-derived in put_current_user via UserId.from_claims(verified claims) — not client-settable; localpart sanitised.
- No magic bypass: writes route through Nebu.Matrix → EventDispatcher; set_space_state enforces S2 chain (allowlist first → member/power_levels/create unforgeable; then membership + :change_state PL). Admin not a member/PL-holder of a space they didn't create → denied. create_space makes admin creator (PL 100).
- Admin gate AC7: SpacesLive in the same live_session :admin require_admin block (static render + socket connect); non-admin/expired → /admin/login.
- auto-join audited (AC5): set_room_auto_join emits room_auto_join_changed with operator matrix_user_id — resolves room-naming epic F-2 MEDIUM for spaces path.
- No retro force-join: ensure_auto_join_space_memberships gated on is_new; non-fatal; flag write admin-only.
- SQL parameterised; child-count drops empty unlinks; XSS — HEEx auto-escape, no raw/{:safe}; IDOR — phx-click ids re-checked by set_space_state membership+PL.

## L-1 (INFO)
set_room_auto_join doesn't assert room_type='m.space' before toggle — harmless (admin already owns rooms toggle; disjoint list scoping routes correctly). Not blocking.

## Forward
join_rules editable via admin set_space_state (allowlisted, PL≥50) — same surface as S2/S4, no new attack surface.
