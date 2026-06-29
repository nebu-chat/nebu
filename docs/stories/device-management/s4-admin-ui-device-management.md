---
story_id: s4-admin-ui-device-management
title: "Admin UI — per-user device management"
epic: device-management
status: done
security_review: required
matrix: false
ui: true
created: 2026-06-26
---

# S4 — Admin UI: per-user device management

## Story

**As** a Nebu operator (admin),
**I want** to see and manage the devices of a given user from the Admin UI,
**so that** I can audit a user's active sessions and revoke a lost/compromised device.

## Background

S1–S3 give a durable per-user device registry and the Matrix write API. This story exposes it to
operators in the Admin LiveView (`Nebu.Admin`, Phoenix LiveView + Tailwind + DaisyUI). Accessibility
requirements from the PRD are hard constraints (UX gate).

## Acceptance Criteria

1. **AC1 — device list per user.** On a user's admin detail page, list that user's devices:
   `device_id`, display name, last-seen (timestamp + IP), created. Empty state when the user has no
   devices.
2. **AC2 — rename.** An admin can rename a device's display name; the change persists and is reflected
   on reload.
3. **AC3 — revoke/delete.** An admin can delete a device, which revokes its session (S3 semantics —
   the user's that session is logged out) and removes its keys. A confirmation step precedes deletion.
4. **AC4 — authz + audit.** Only an authenticated admin (existing admin OIDC/role gate) may view/act;
   every rename/delete writes an audit-log entry (`Nebu.Compliance` — register the new audit actions
   in `AuditWriter.@known_actions`).
5. **AC5 — accessibility.** Keyboard-navigable, labelled controls, sufficient contrast (PRD a11y) —
   passes the UX gate.

## Acceptance Tests

### Tests written FIRST (Gherkin + Cucumber/Playwright — UI story):

1. `e2e/features/admin-device-management.feature`:
   - Scenario: admin views a user's devices → the device list renders with metadata.
   - Scenario: admin renames a device → new name shown after reload.
   - Scenario: admin revokes a device (with confirmation) → device disappears; the targeted session
     can no longer authenticate.
   - Scenario: empty state → "no devices" message for a user with none.
2. `e2e/steps/admin-device-management.steps.ts` — real browser flows (no cookie forging, no DB-seed
   shortcuts); drive through the real admin login + running stack.

## Dev Notes

- Lives under `Nebu.Admin` (Admin LiveView). Reuse the existing admin auth/role gate.
- Reuse S3's delete-device path for revocation (don't reimplement session revocation in the UI layer).
- New audit actions MUST be added to `AuditWriter.@known_actions` (project memory: merging audit
  actions without registering them silently breaks the audit trail).
- nebu-agent-ux is the owner; follow Tailwind + DaisyUI conventions.

## Dev Agent Record

### Completion Notes

Implemented the per-user device-management Admin UI (review cycle 0):

- **AC1** — `GET /admin/users/:user_id` renders a Devices table (one `[data-role="device-row"]`
  per device) showing `device_id`, display name, last-seen (timestamp + IP), and created
  (`created_ts`). Empty state `[data-role="no-devices"]` when the user has no devices.
  `DeviceKeyStore.list_devices/1` + `get_device/2` now also SELECT `created_at` and surface it
  as `"created_ts"` (epoch-ms), rendered as an ISO-8601 token.
- **AC2** — per-row rename form (`POST .../devices/:device_id/rename`) → `Nebu.Matrix.rename_user_device/3`,
  PRG redirect back to the detail page; persists, reflected on reload.
- **AC3** — per-row revoke control (`POST .../devices/:device_id` + `_method=DELETE`) →
  `Nebu.Matrix.delete_user_device/2`, which revokes the device's bound session(s) (S3 kill-switch:
  raw-JWT denylist + opaque session) AND removes its keys. A `data-confirm` confirmation step
  precedes deletion.
- **AC4** — actions are behind the existing `Nebu.Admin.Auth :require_admin` gate (unauthenticated →
  302 `/admin/login`, no domain call). Each rename/delete writes an audit row via the
  `:compliance, :audit_writer` env seam (`device_renamed` / `device_deleted`, actor = admin,
  target_type = `device`, target_id = device_id, metadata `%{"user_id" => user_id}`). Both actions
  registered in `AuditWriter.@known_actions`.
- **AC5** — real `<table>` with `<th scope="col">` headers, a labelled rename input
  (`<label class="sr-only">` + `aria-label`), real submit `<button>`s, DaisyUI semantic
  `btn-error`/`btn-primary` classes for contrast, and a page `<h1>`.
- **SECURITY** — device_id/display_name render through HEEx auto-escaping (XSS, locked by test);
  facade calls always pass the ROUTE user_id (no IDOR); state-changing POSTs require a valid CSRF
  token (real `protect_from_forgery`).

Facade function names settled on (ADR-020, in `Nebu.Matrix`): `list_user_devices/1`,
`rename_user_device/3`, `delete_user_device/2`.

Made `Nebu.Compliance.AuditWriter.do_log/7` honour its "never raises" policy by catching a
RuntimeError from a transaction against an unstarted Repo (degrades to `{:error,
:audit_write_failed}`).

Fixed two ordering/isolation defects in the staged ATDD test (no assertion weakened): moved the
nested `FakeAuditWriter` defmodule above `setup` so its alias resolves at `put_env`; restored
`admin_csrf_bypass` to `true` (the global test default) in `on_exit` instead of deleting it (a bare
delete leaked `false` into later admin tests).

**Result:** `make test-unit-elixir` → 922 passed, 2 skipped, 191 excluded, 0 warnings (exit 0 under
`--warnings-as-errors`). E2E/integration not run (pipeline CI gate owns that).

### File List

- server/lib/nebu/matrix.ex (facade: list_user_devices/1, rename_user_device/3, delete_user_device/2)
- server/lib/nebu/matrix/device_key_store.ex (list_devices/get_device SELECT created_at → created_ts)
- server/lib/nebu/admin/users_controller.ex (show/2, rename_device/2, delete_device/2 + seams + audit)
- server/lib/nebu/admin/users_html.ex (device render helpers)
- server/lib/nebu/admin/templates/users/show.html.heex (new — device list/rename/revoke UI)
- server/lib/nebu/admin/router.ex (3 routes under /admin/users/:user_id)
- server/lib/nebu/compliance/audit_writer.ex (register device_renamed/device_deleted; never-raise)
- server/test/nebu/admin/device_management_test.exs (ordering + env-isolation fixes)

## Change Log

- 2026-06-26 — S4 implemented: per-user device-management Admin UI (view/rename/revoke), Nebu.Matrix
  device facade, audit actions registered, AuditWriter never-raise hardening. All unit tests green.
