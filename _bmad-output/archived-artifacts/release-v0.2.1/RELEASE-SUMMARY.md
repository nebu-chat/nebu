# Release v0.2.1 — Development Archive

**Release date:** 2026-05-20  
**Archived:** 2026-05-21  
**CHANGELOG:** see `/CHANGELOG.md` (entries for v0.1.0, v0.2.0, v0.2.1)

This archive captures the complete development state for phases 1–3 (numbered epics 1–16),
which culminated in the v0.2.1 release. All story files remain in their original locations
under `docs/stories/mvp/`, `docs/stories/phase2/`, and `docs/stories/phase3/`.

---

## Epics in v0.2.1 Baseline

| Epic | Title | Status | Stories |
|------|-------|--------|---------|
| 1  | Operators Can Deploy and Observe a Running Nebu Instance | done | 19 |
| 2  | Users Can Authenticate with SSO and Have a Verified Cryptographic Identity | done | 21 |
| 3  | Operators Have a Minimal Admin UI for Bootstrap and Debugging | done | 15 |
| 4  | End-Users Can Chat in Rooms Using Any Standard Matrix Client | done | 29 |
| 5  | Compliance Officers Can Securely Request and Export Audited Communication Data + Gateway Security Hardening | done | 34 |
| 6  | Instance Admins Can Manage the Instance Programmatically via Admin API | done | 12 |
| 7  | Instance Admins Have a Full Admin UI for Day-to-Day Operations | done | 40 |
| 8  | Project Is Published as a Public Open-Source Repository on GitHub | done | 12 |
| 9  | Post-MVP API & Admin Completeness | done | 28 |
| 10 | Managed E2EE — Key Escrow | **backlog** | deferred (ADR-011 required) |
| 11 | Full-Text Search | done | 10 |
| 12 | Media Gateway Phase 2 — Object Storage & Thumbnails | **backlog** | deferred (ADR-013 required) |
| 13 | Operators Can Deploy Nebu to Production and Validate Scalability | done (partial) | see sprint-status |
| 14 | Admin — Claim Lock, OIDC User Import, and GDPR Compliance | done | 9 |
| 15 | Matrix Spaces and Room Moderator Feature Completeness | **backlog** | deferred |
| 16 | GitLab Pages (Architecture Docs + Landing Page) | done | 3 |

**Backlogged items** (epics 10, 12, 15 and individual backlog stories from 6/7/9/11) carry
forward as potential candidates for future named epics. They are tracked in the archived
`sprint-status.yaml` below.

---

## Archived Artifacts in This Directory

| File | Description |
|------|-------------|
| `RELEASE-SUMMARY.md` | This file |
| `sprint-status.yaml` | Full legacy sprint-status as of v0.2.1 (epics 1–16) |
| `pipeline-state.yaml` | Pipeline log from `_bmad-output/nebu/pipeline-state.yaml` |
| `pipeline-state-legacy.yaml` | Pipeline log from `_bmad/nebu/pipeline-state.yaml` (old location) |
| `step-results/` | Per-story step outputs (oracle-context, test-review-findings, code-review-findings) |

---

## What Changed After This Archive

- Story and epic identifiers moved from numbers (`epic-16`, `16-3`) to domain names
  (`feature/matrix-presence`, story slug `typing-indicators.md`)
- Pipeline state is now per-epic: `_bmad-output/nebu/epics/<epic-name>/pipeline-state.yaml`
- Sprint status is now per-epic: `_bmad-output/nebu/epics/<epic-name>/sprint-status.yaml`
- Feature epics live in `feature/<epic-name>` branches per ADR-016 (Git Flow)
- Use `/nebu-release new-epic <name>` to start a new feature for v0.3.0+
