# Security Review — fix-admin-member-audit-actions (SEC Gate 1)

- **Date:** 2026-06-21
- **Reviewer:** nebu-agent-kassandra (adversarial)
- **Scope:** staged diff for the audit-allowlist merge regression fix
- **Verdict:** **CLEAN** — 0 CRITICAL / 0 HIGH

## Context
Merging `feature/room-management-elixir` into `feature/full-elixir-stack` introduced a
compliance regression: `Server.admin_add_room_member/3` and `admin_remove_room_member/3`
emit audit actions `"member_added"` / `"member_removed"`, but those strings were missing
from `Nebu.Compliance.AuditWriter.@known_actions`. The allowlist guard rejected them with
`{:error, :audit_unknown_action}`, so admin-initiated membership changes were silently NOT
written to `audit_log` — a broken audit trail.

## Fix
- `core/lib/nebu/compliance/audit_writer.ex`: added `member_added` and `member_removed`
  to `@known_actions`.
- Regression tests (unit + integration driving the real `AuditWriter`).

## Findings
- **Audit-integrity / log-forging:** NONE. Action strings are hardcoded server-side
  literals; never client-controllable. Allowlist still rejects unknown actions.
- **Actor attribution / spoofing:** CORRECT. `actor_id` derives from the OIDC-authenticated
  admin session (`session["current_user"]`), never client-settable; target recorded
  separately in `metadata["user_id"]`. Self-removal rejected server-side.
- **SQLi:** N/A — parameterised Ecto changeset + `Repo.insert!`.
- **Secret/PII in logs:** NONE introduced.
- Other scope items (XSS/CSRF/open-redirect/body-size/rate-limit/crypto/path-traversal/JWT):
  not applicable to a server-side allowlist string addition.

**SEC GATE 1: CLEAN.**
