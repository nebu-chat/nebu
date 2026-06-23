# Security Review — fix-admin-member-list-leftjoin (SEC Gate 1)

- **Date:** 2026-06-21
- **Reviewer:** nebu-agent-kassandra (adversarial)
- **Scope:** staged diff — `Nebu.Admin.DB.list_room_members/1` INNER→LEFT JOIN + regression test
- **Verdict:** **CLEAN** — 0 CRITICAL / 0 HIGH / 0 MEDIUM

## Context
`list_room_members/1` used `INNER JOIN users`, silently dropping room members without a
provisioned `users` row (e.g. an admin-added user who has not yet logged in via OIDC). The
admin member list therefore hid legitimate members. Surfaced as e2e
admin/member_management.feature AC2/AC4.

## Fix
- `core/lib/nebu/admin/db.ex`: `JOIN users` → `LEFT JOIN users`. Members with no users row
  return nil display-name fields.
- `core/test/nebu/admin/list_room_members_unprovisioned_test.exs`: new `:integration` regression.

## Findings
- **SQLi:** CLEAN — still parameterised (`$1`); only join semantics changed.
- **nil-row crash / DoS:** CLEAN — nil display fields fall through `decrypt_display_name/1`'s
  catch-all clause (server.ex:3677) → `""`. No FunctionClauseError, no 500.
- **PII / plaintext leak:** CLEAN — nil PII rows skip decryption entirely (surface narrowed).
- **IDOR / auth boundary:** CLEAN — only widens what an already-authenticated admin sees for
  a room they manage; no caller-controlled input, no auth predicate touched.
- **Watch-item (non-blocking):** member-row template renders `user_id` via HEEx `{ }`
  (auto-escaped) — verified no `raw/1`. No stored-XSS path.

**SEC GATE 1: CLEAN.**
