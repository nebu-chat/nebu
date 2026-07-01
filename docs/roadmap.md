# Nebu Roadmap

This document provides a roadmap derived from Nebu's epic structure and current sprint status.
Since v0.3.0 the project uses **named epics** (no numeric identifiers — see CLAUDE.md, "Named Epic
Convention"). The historical numbered MVP epics (1–8) are complete; development since then proceeds
as a stream of named feature epics, each on its own `feature/<epic-name>` branch (ADR-017).

## Current Status (2026-06-30)

**Pre-alpha, single Elixir/OTP stack.** Core chat functionality plus a spec-faithful client
surface (device-key directory, cross-signing key directory, account_data, devices, whoami) is
implemented, and real clients (Element Web) register and run cleanly. Not production-ready —
see [Current Limitations](../README.md#current-limitations).

The architecture is now **one Elixir/OTP application** (`:nebu`, `Nebu.Application`), not an
umbrella (ADR-019). The former Go gateway + Go media gateway and the entire gRPC/protobuf layer
have been **removed** (ADR-021): the command/DTO layer is in-process plain Elixir modules
(`Nebu.Matrix.EventDispatcher.Server` + `Core.*` structs). Migrations are **raw SQL** run by
`Nebu.Release.migrate/0` before boot (ADR-018) — no ORM, no golang-migrate. No Redis, no NATS,
no Kafka (ETS + pg process groups, ADR-002).

---

## Completed Foundation (numbered MVP epics 1–8)

The original numbered epics built the MVP and reached public open-source readiness. These remain
in `docs/stories/mvp/`, `phase2/`, `phase3/` and are not renumbered.

| Epic | Scope | Key FRs |
|---|---|---|
| 1–2 | OTP core (rooms, sessions, presence, event dispatch), OIDC login (Auth Code + PKCE), Bootstrap Wizard, PostgreSQL schema | FR1–6, FR43–47 |
| 3 | Ed25519 signing + X25519 keypairs (ADR-007), content-hash event IDs (ADR-003), append-only audit log, minimal Media Gateway (AES-256-GCM) | FR25–29, FR34–35 |
| 4 | Full Matrix Client-Server API MVP — `/sync`, send, messages, createRoom, join, presence, typing, receipts, profile | FR7–16 |
| 5 | Security hardening + Compliance Access (rate limiting, body-size limits, CSRF, security headers, four-eyes compliance, signed export, GDPR deletion) | FR30–35 |
| 6 | Admin API (OpenAPI spec-first, ADR-009) — users, rooms, roles, deactivation/reactivation | FR36–40, FR51–52 |
| 7 | Admin UI — dashboard, user/room management, compliance requests, audit log, server config, role mapping; full Matrix API gap closure | FR48–50 |
| 8 | Public open-source release — README, CONTRIBUTING, SECURITY, CI (GitHub + GitLab), secret scanning, e2e acceptance suite | — |

> Note: epics 1–8 originally described a Go gateway, gRPC EventBus, golang-migrate, and an Elixir
> umbrella. Those implementation choices were **superseded** by the consolidation work below
> (ADR-019/020/021/018). The functional requirements they delivered still hold; the runtime shape
> changed.

---

## Completed Consolidation & Named Feature Epics

Done since the numbered MVP — each a named epic (see `_bmad-output/nebu/epics/<name>/` and
`docs/stories/<name>/`).

| Epic | What it delivered | Decision |
|---|---|---|
| `otp-consolidation` | Collapsed the Elixir umbrella into a single OTP app | ADR-019 |
| `full-elixir-stack` | Removed the Go gateway + Go media gateway; the whole stack is one Elixir/OTP app | ADR-021 |
| `grpc-removal` | Removed the last gRPC/protobuf deps; command layer is in-process plain modules + `Core.*` structs; native `Nebu.Matrix.Error`/`Status` | ADR-021 (supersedes ADR-005) |
| `media-gateway-stackit-objectstore-support` | S3-compatible media backend (MinIO / Stackit object store) via ExAws/Finch | ADR-013 |
| `room-naming-and-default-rooms` | Room naming + default-room behavior fixes | — |
| `spaces-elixir` | Matrix Spaces support in the Elixir room layer | — |
| `element-compat` | Element Web compatibility — MSC2965 OIDC discovery, `/.well-known/matrix/client` advertising `io.element.e2ee.force_disable`, clean client bootstrap | ADR-011 |
| `device-management` | Device-key **directory** (PostgreSQL-backed `DeviceKeyStore`), `keys/upload`/`keys/query`, `/devices`, `/account/whoami` — not E2EE | ADR-011 |
| `oidc-bootstrap-only` | OIDC configured exclusively via the Bootstrap Wizard (`server_config`); all `NEBU_OIDC_*`/`NEBU_ADMIN_OIDC_*` env vars removed; single OIDC client for both Matrix Bearer + admin login; fail-closed until bootstrapped | ADR-022 |
| `client-crypto-setup` | Opaque cross-signing key directory (upload/read-back) so clients complete crypto setup cleanly while E2EE stays off | ADR-011, ADR-023 (draft) |
| `forget-room-membership-purge` | `POST /rooms/{id}/forget` — persist + purge forgotten rooms from `/sync` | — |
| `upcloud-deployment` | UpCloud deployment posture / IaC | ADR-014 |

A series of bugfix epics (`fix-bootstrap-wizard-*`, `fix-matrix-sso-redirect-missing`,
`fix-missing-matrix-room-routes`, `fix-jwt-denylist-persistence`, `fix-short-oidc-sessions`,
`fix-admin-member-audit-actions`, `room-list-not-updated-after-leafe`,
`bugfix-admin-login-without-env-oidc-variables`) hardened the OIDC bootstrap and Matrix flows.

---

## In Progress

| Epic | Description | Status |
|---|---|---|
| `client-crypto-setup` | Cross-signing key-directory polish + 400/403 fidelity follow-up | In progress (SEC Gate 2 clean) |
| `e2e-test-rehab` | Stabilize the brittle admin/Element Playwright suite (shared login steps, room seeding) — a dedicated test-rehab workstream | In progress |
| account_data durability | Durable PostgreSQL `account_data` + `/sync` delivery | Recently landed |

---

## Planned / Vision

### Near-term

- **Deployment postures (ADR-023, draft):** make the **Compliance Mode** (E2EE off, server-readable
  content) vs. **Normal Mode** (E2EE on, native federation) boundary an explicit, named decision
  before more code assumes "managed forever". Federation-auth and key-escrow mechanisms require the
  architect (Open Questions in ADR-023).
- **Clustering hardening:** multi-node via `libcluster` + `Horde` + `pg` (ADR-020) — behave
  identically on one node and in a cluster.
- **Managed E2EE key escrow (ADR-011):** server-side decryption model — NOT true E2EE. ADR-011
  must be accepted before implementation.
- **Full-Text Search (ADR-010):** PostgreSQL `tsvector` + GIN index (migration 000042 groundwork
  exists); roll out search UX.

### Phase 3 Vision (Future)

| Feature | Description |
|---|---|
| Matrix Federation | Server-Server API — the "Normal Mode" endgame (ADR-023) |
| E2EE-with-escrow | Special forked Matrix client performing E2EE while escrowing keys to the server (ADR-011 + ADR-023) |
| Apple/Google Push | APNs/FCM push notifications for mobile clients |
| Admin-UI-as-Chat-Agent | Room-based admin interaction via Nebu itself |
| MCP Support | Integration in the AI tooling ecosystem |
| Platinum-Tier Scale | >5000 concurrent users per node in cluster |

---

## Performance Tier Goals

| Tier | Target | Gate |
|---|---|---|
| Silver | >500 concurrent users / m5.large | MVP release gate |
| Gold | >1000 concurrent users / cluster | Clustering hardening |
| Platinum | >5000 concurrent users / cluster | Phase 3 |

Traffic mix for loadtest: 60% sync, 20% send, 10% presence+typing, 5% room ops, 5% profile+misc.

_Source: `_bmad-output/nebu/epics/<epic-name>/`; `docs/stories/<epic-name>/`;
`_bmad-output/planning-artifacts/prd.md`, §Scoping & Release Strategy; CLAUDE.md (§ADR table,
§Named Epic Convention); `docs/architecture/adr/`_
