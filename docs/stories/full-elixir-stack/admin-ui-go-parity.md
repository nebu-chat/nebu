---
story_id: admin-ui-go-parity
title: "Admin UI Go Parity — Sidebar Nav, Bootstrap Enforcement, Dashboard + Config/Audit/Compliance"
epic: full-elixir-stack
status: done
security_review: not-needed
created: 2026-06-18
branch: feature/full-elixir-stack
---

## Summary

The `admin-ui-migration` ported only 3 of the Go admin's ~8 sections (Rooms, Users,
Bootstrap) with a minimal top navbar, and the bootstrap wizard was never enforced on a
fresh instance (login landed on `/admin/rooms`). This story restores Go parity for the
Phoenix LiveView admin UI: the left-sidebar navigation, bootstrap enforcement, and the
missing pages.

## What was done

- **Sidebar layout** (`Nebu.Admin.Layouts.live`) — replaced the minimal top navbar with
  the Go-parity topbar + left sidebar (`w-60`, Obsidian `base-200`, border): Dashboard,
  Compliance, Users, Rooms, Configuration, Role Mapping, Claim Mapping, plus a pinned
  Logout; "Bootstrap Setup" appears only while unbootstrapped. Active item highlighted in
  the primary colour from each LiveView's `@active_nav`; WCAG-AA focus rings + `aria-current`.
- **Bootstrap enforcement** (`Nebu.Admin.Auth.on_mount(:require_admin)`) — an instance whose
  `server_config.bootstrap_completed` is not `"true"` now funnels every admin page into
  `/admin/bootstrap` (Go parity). `root_redirect` lands on `/admin/dashboard`.
- **New LiveViews** (read views, inline SQL per ADR-018, Obsidian/DaisyUI):
  - `DashboardLive` — System Status (core health, user/room counts) + Server Info.
  - `AuditLogLive` — recent `audit_log` events (actor/action/target/outcome/time).
  - `ComplianceLive` — `compliance_requests` (four-eyes review trail).
  - `ConfigLive` — `server_config` key/value overview.
  - `ClaimMappingLive` — editable OIDC claim mapping (user-id/displayname/email).
  - `RoleMappingLive` — editable admin group claim.
- Routes added under the `:admin` live_session; existing LiveViews set `@active_nav`.

## Acceptance Criteria

1. On a fresh (unbootstrapped) instance, an admin login is redirected to `/admin/bootstrap`
   (wizard enforced) instead of `/admin/rooms`.
2. The admin chrome is a left sidebar matching the Go variant (Dashboard, Compliance, Users,
   Rooms, Configuration, Role Mapping, Claim Mapping, Logout; Bootstrap Setup when unbootstrapped),
   with the active section highlighted.
3. `/admin/dashboard`, `/admin/audit-log`, `/admin/compliance`, `/admin/config`,
   `/admin/config/claim-mapping`, `/admin/config/role-mapping` all render (200, no error)
   in the Obsidian theme.
4. Claim/Role mapping forms persist to `server_config` via `Nebu.Admin.DB.upsert_server_config`.
5. `mix compile --warnings-as-errors` clean; unit suite green (546/2 skipped).

## Acceptance Tests

UI/structure story — verified via Playwright (Chromium) against the running stack:
- Fresh instance: login → lands on `/admin/bootstrap`; sidebar shows all Go sections.
- Bootstrapped instance: `/admin/dashboard` renders "System Status" + "Server Info"; Audit
  Log, Compliance, Config, Claim/Role Mapping render without error.
- The admin e2e suite (Playwright + Cucumber) covers the deeper flows.

## Notes

- Approve/deny actions on Compliance and richer per-row detail panels remain follow-ups —
  this story restores the navigation, bootstrap gating, and the read/config surfaces.
- JS stays vendored (phoenix/live_view + app.js); this story is layout + LiveViews only.
