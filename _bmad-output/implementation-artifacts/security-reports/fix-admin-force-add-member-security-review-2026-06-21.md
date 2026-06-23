# Security Review — fix-admin-force-add-member (SEC Gate 1)

- **Date:** 2026-06-21
- **Reviewer:** nebu-agent-kassandra (adversarial)
- **Scope:** staged diff — `admin_add_room_member/3` no-federation guard + invite→join transition
- **Verdict:** **CLEAN** — 0 CRITICAL / 0 HIGH (1 LOW, fixed)

## Context
Admin "add member" wrote a `room_members` row for any shape-valid user_id, including a
foreign-domain ghost (`@charlie:nebu.local` on a `localhost` server) with no account/keys —
which never resolves to a session/profile and never surfaces in the admin list. Pre-existing
(story rm4); surfaced by the merge's e2e run.

## Fix
- `admin_add_room_member/3`: default-deny user_ids whose domain != configured `server_name`
  (`local_domain?/1`) → `{:error, :foreign_domain}`; establish a pending invite then run the
  authorized `join_room/2` so force-add yields a real invite→join transition regardless of
  join_rule. On join failure, `reject_invitation` cleans up the pending invite (LOW fix).
- e2e fixture: `@charlie:nebu.local` → `@alex:localhost` (real provisioned local user).

## Findings
- **Auth / privesc:** CLEAN — `actor_id` server-derived (session["current_user"]); reachable
  only via admin router/auth.
- **`local_domain?` bypass:** CLEAN — `UserId` regex forbids `:` in localpart+domain, so
  `@x:localhost:evil` is rejected by `UserId.valid?` first; split-on-first-`:` then yields a
  clean domain; `_ -> false` default-denies. Reads configured `server_name` (not hardcoded).
- **Client-join enforcement:** CLEAN — `enforce_restricted_join!` still runs unconditionally in
  `join_room/2`; the invite is created only on the admin path.
- **Idempotency / DoS:** CLEAN — `insert_invitation` is `ON CONFLICT DO NOTHING`; cannot 500.
- **Crash handling:** CLEAN — `{:error, :foreign_domain}` surfaced as a flash (rooms_live.ex:311).
- **LOW (fixed):** dangling pending invite on join failure → now `reject_invitation` on rescue.

**SEC GATE 1: CLEAN.**
