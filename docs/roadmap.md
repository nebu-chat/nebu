# Nebu Roadmap

This document provides a roadmap derived from Nebu's epic structure and current sprint status.
Epics 1–16 are tracked; see per-epic state in `_bmad-output/nebu/epics/<name>/sprint-status.yaml`
for named epics.

## Current Status (2026-06-30)

**Pre-1.0.** Core chat functionality is fully implemented, the Elixir single-application
consolidation is complete, and the stack is Element Web + FluffyChat compatible.
Active development focus: room management rework, deployment polish.

---

## Completed Epics

### Epics 1–2: Foundation + OIDC Login

**Status:** Done

- Single Elixir/OTP application (`Nebu.Application`); Bandit + Plug HTTP server
- OIDC authentication via Dex / Keycloak (Authorization Code + PKCE)
- Bootstrap Wizard (first-run experience, first admin OIDC setup)
- PostgreSQL schema migrations (raw SQL via `Nebu.Release`)
- Horde Registry + DynamicSupervisor for Room GenServers (ADR-004)
- ETS session cache + pg Process Groups pub/sub (ADR-002)

**Key FRs:** FR1–6 (Identity & Authentication), FR43–47 (Server Operations)

---

### Epic 3: Ed25519 Signatures + Audit Log + Media

**Status:** Done

- Ed25519 keypair generation per user (Signing + X25519 Encryption)
- Message signing via `Nebu.Signature` (all events)
- Content-hash event IDs (`Nebu.EventId.generate/1`)
- Append-only audit log with Ed25519-signed entries
- Media: AES-256-GCM upload/download via `Nebu.Media.*` (in-process)

**Key FRs:** FR25–29 (Cryptographic Identity), FR34–35 (Audit Log)

---

### Epic 4: Full Matrix Client-Server API MVP

**Status:** Done

- `/sync` long-poll with ETS + pg groups
- `PUT /rooms/{id}/send` → `EventDispatcher.Server.send_event/5` (in-process)
- `GET /rooms/{id}/messages` (paginated)
- `POST /createRoom`, `POST /join`, presence, typing, receipts
- Profile (GET/PUT displayname + avatar_url)
- `GET /presence/{userId}/status`

**Key FRs:** FR7–16 (Messaging & Rooms)

---

### Epic 5: Security Hardening + Compliance Access

**Status:** Done

- Rate limiting (per-IP, 5 tiers), body size limits, CSRF, security headers
- Compliance Access API (four-eyes approval, 24h session)
- Compliance Data Export (Ed25519-signed JSON/PDF)
- GDPR User Key Deletion + PII Anonymization
- Audit log retention scheduler (configurable, default 7 years)

**Key FRs:** FR30–35 (Compliance & Audit)

---

### Epic 6: Admin API (OpenAPI Spec-First)

**Status:** Done

- Admin API: users (cursor pagination), deactivation/reactivation, role assignment
- Room List + Get API

**Key FRs:** FR36–40 (User & Room Administration), FR51–52 (Admin API)

---

### Epic 7: Admin UI (Full Day-to-Day Operations)

**Status:** Done

- Dashboard with SSE live metrics (message throughput, active sessions)
- User/Room management UI, Compliance Access Requests, Audit Log
- Server Configuration, Role Mapping, Claim Mapping pages
- All Matrix API gap stories closed (push rules, devices, account_data, tags,
  public rooms, event context, notifications, moderation, room state)

**Key FRs:** FR48–50 (Admin UI), complete Matrix API surface

---

### Epic 8: Public Open-Source Release

**Status:** Done

- README, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md
- GitLab CI + GitHub Actions dual-host CI
- Full-Stack Acceptance Test (Playwright + Gherkin E2E, 6 flows)

---

### Epics 9–11: Arc42 Docs + FTS + Matrix API Gaps

**Status:** Done

- arc42 documentation (`docs/`) auto-generated from BMAD artifacts; `bmad-generate-arc42` skill
- ADR-010 (FTS strategy) accepted 2026-05-08; FTS on PostgreSQL `tsvector`/`tsquery` (GIN index)
- `POST /_matrix/client/v3/search` implemented
- Matrix API gaps: GET event, GET relations (+ dir/recurse/from), bundled thread aggregations,
  single-event fetch (Story 11-8), configurable OIDC claim mapping (Story 11-10)
- Read receipts start-on-demand fix (Story 11-11)

---

### Epics 12–13: Media + Deployment

**Status:** Done (media fully implemented; deployment docs complete)

- `Nebu.Media.*` fully in-process: AES-256-GCM, ExAws/Finch, thumbnails, CSP/CORP headers
- Authenticated v1 media endpoints (`/_matrix/client/v1/media/*`)
- Deployment docs: Docker Compose (primary), AWS ECS Fargate, Stackit VMs (ADR-014)
- UpCloud deployment support (`upcloud-deployment` epic)

---

### Named Epic: full-elixir-stack / otp-consolidation / grpc-removal

**Status:** Done (2026-06-22)

The key consolidation epics:
- `full-elixir-stack`: Go gateway deleted; all HTTP surfaces moved into Elixir/OTP (ADR-021)
- `otp-consolidation`: Umbrella removed (ADR-019); one `mix.exs`, one `Nebu.Application`
- `grpc-removal`: `:grpc`/`:protobuf` deps deleted; no network gRPC listener; `Core.*` are plain
  `defstruct` DTOs; `Nebu.Matrix.Error`/`Status` replace `GRPC.RPCError`/`GRPC.Status` (ADR-021)

---

### Named Epic: oidc-bootstrap-only (ADR-022)

**Status:** Done (2026-06-28)

- OIDC configured exclusively via Bootstrap Wizard (`server_config`); all `NEBU_OIDC_*` env vars removed
- Single OIDC client for both Matrix Bearer validation and admin operator login
- Fail-closed until bootstrapped; OIDC config validated per-operation, not at boot

---

### Named Epic: device-management

**Status:** Done

- Device table (`devices`), device list/get/rename endpoints
- UIA-gated device delete + bulk delete (`m.login.sso`, 15-min fresh-auth window)
- Per-device JWT kill-switch on delete; per-device sync token isolation

---

### Named Epic: element-compat

**Status:** Done

- Element Web login spinner fix (XFF rate limit, profile tier, `revocation_endpoint`, CORS)
- OIDC session refresh (opaque Matrix tokens, 8h lifetime, grace period rotation)
- Admin silent OIDC refresh; configurable `admin_oidc_refresh_mode` / `matrix_oidc_refresh_mode`
- SSO nonce + denylist (Story 11-7); Bootstrap dynamic OIDC credentials

---

### Named Epic: spaces-elixir

**Status:** Done (2026-06-22)

- Matrix Spaces (MSC1772/MSC2946/MSC3083) fully in Elixir
- Space creation, `m.space.child`/`m.space.parent` state events
- `GET /hierarchy` BFS traversal, restricted join enforcement (MSC3083)
- Admin Spaces UI; Element Web E2E coverage

---

### Named Epic: room-naming-and-default-rooms

**Status:** Done

- Room canonical aliases auto-generated from name (Story `room-canonical-alias-from-name`)
- Room summary (`m.heroes`) in sync response (Story `direct-room-heroes`)
- Auto-join rooms at first login + bulk import (Stories `admin-auto-join-rooms`, `auto-join-on-user-import`)
- Creator provisioning + orphan cleanup (`admin-room-creator-provisioning`)
- Admin user autocomplete for room/space add-member (`admin-add-user-autocomplete`)

---

## Active / Recent Work

### Named Epic: rework-room-management

**Status:** In progress

Room management refactor: improved room CRUD flows, membership management,
and room settings in the Admin UI.

---

## Planned / Backlog

| Feature | Epic / Story | Priority |
|---|---|---|
| Multi-node clustering validation | Phase 2 (post-MVP loadtest) | Medium |
| Apple/Google push notifications | PRD §Growth Features | Growth |
| Matrix Federation protocol | PRD §Phase 3 Vision | Vision |
| Platinum-tier scale (>5000 users) | Phase 3 | Vision |
| MCP support | PRD §Phase 3 Vision | Vision |

---

## Performance Tier Goals

| Tier | Target | Gate |
|---|---|---|
| Silver | >500 concurrent users / m5.large | MVP release gate |
| Gold | >1000 concurrent users / cluster | Phase 2 |
| Platinum | >5000 concurrent users / cluster | Phase 3 |

Traffic mix for loadtest: 60% sync, 20% send, 10% presence+typing, 5% room ops, 5% profile+misc.

_Source: `_bmad-output/planning-artifacts/epics.md`; `_bmad-output/planning-artifacts/prd.md`, §Scoping & Release Strategy; `_bmad-output/implementation-artifacts/sprint-status.yaml`; named epic state files in `_bmad-output/nebu/epics/`_
