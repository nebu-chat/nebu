# ADR-016: Git Branching and Release Strategy

## Status

Accepted - 2026-05-21

## Context

Nebu has reached its first stable release (v0.1.0 → v0.2.1). From this point, parallel development tracks co-exist: ongoing feature development for the next release, stabilization of the current baseline, and occasional critical fixes to the production state.

Without an explicit branching strategy, typical problems arise:
- Unclear which commit is "production-ready"
- Container images in the GitLab registry with no traceable origin
- Hotfixes lost because they were never merged back into the development branch
- `:latest` alternating between stable and experimental builds

Enterprise customers also require auditability as a compliance criterion: which image was deployed, from which commit, via which pipeline run.

## Decision

Nebu uses a **simplified Git Flow strategy** with two long-lived branches (`main`, `develop`) and short-lived support branches (`feature/*`, `bugfix/*`, `release/*`, `hotfix/*`).

### Branch Overview

| Branch       | Purpose                                                  | Lifetime       |
|--------------|----------------------------------------------------------|----------------|
| `main`       | Stable production state; root of all release tags        | permanent      |
| `develop`    | Integration branch for the next release                  | permanent      |
| `feature/*`  | Individual features or epics (`feature/<epic-name>`)     | until MR merge |
| `bugfix/*`   | Non-critical bugfixes targeting develop                  | until MR merge |
| `release/*`  | Release preparation (RC phase, bugfixes only)            | until release  |
| `hotfix/*`   | Critical fixes applied directly to main                  | until release  |

### Invariants

- **`main` is always deployable.** Direct push is forbidden; changes arrive exclusively via merges from `release/*` or `hotfix/*`.
- **`develop` is always compilable with all tests green.** Feature branches merge only after CI passes.
- **Semantic Versioning.** Release tags follow `vMAJOR.MINOR.PATCH` (e.g. `v0.2.0`). Pre-release suffixes: `v0.2.0-rc.1`, `v0.2.0-rc.2`.
- **A release tag is always created on `main`**, never on develop or a feature branch.

### Feature and Epic Naming

Each new feature epic is developed in its own `feature/<epic-name>` branch. The epic name is a short, lowercase, hyphenated domain identifier (e.g. `feature/matrix-presence`, `feature/admin-room-api`). This replaces the previous numbered-epic scheme (`epic-N`) and enables parallel development across multiple features without coordination overhead.

---

## Flows

### 1. Normal Feature Flow

```
develop
  │
  ├─── feature/matrix-presence   (MR → develop, squash or merge commit)
  │
  ├─── feature/admin-room-api    (MR → develop)
  │
  └─── develop (accumulates features until release decision)
```

### 2. Release Flow

```
develop
  │
  └─── release/v0.3             (branched from develop)
         │   ← bugfixes only, no new features
         │
         ├── tag: v0.3.0-rc.1   (optional RC for internal/staging tests)
         ├── tag: v0.3.0-rc.2
         │
         ├── merge → main        (fast-forward or merge commit)
         │     └── tag: v0.3.0
         │
         └── merge → develop     (so RC bugfixes are not lost)
```

### 3. Hotfix Flow

```
main (v0.2.1)
  │
  └─── hotfix/v0.2.2-cve-fix    (branched from main)
         │
         ├── merge → main
         │     └── tag: v0.2.2
         │
         └── merge → develop     (critical: hotfix must flow back to develop)
```

---

## CI/CD and Registry Mapping

Every branch and tag produces a deterministically named image in the GitLab Container Registry. The mapping is fully determined by the trigger - no manual lookup of pipeline logs required.

| Trigger                          | Image Tag                               | Description                    |
|----------------------------------|-----------------------------------------|--------------------------------|
| Push to `develop`                | `:dev-<short-sha>`, `:dev-latest`      | Integration build, unstable    |
| Branch `release/vX.Y`            | `:rc-X.Y.Z-rc.N`                       | Release candidate              |
| Tag `vX.Y.Z` on `main`           | `:X.Y.Z`, `:latest`                    | Stable release                 |
| Branch `hotfix/*`                | `:hotfix-<short-sha>`                  | Internal only, not published   |

`:latest` always and exclusively points to the most recent stable release tag. A `develop` build never overwrites `:latest`.

---

## GitLab Configuration

### Protected Branches

Under **Settings → Repository → Protected Branches**:

| Branch    | Merge allowed  | Push allowed | Force Push |
|-----------|----------------|--------------|------------|
| `main`    | Maintainers    | Nobody       | No         |
| `develop` | Developers     | Nobody       | No         |

No direct push to `main` or `develop`. All changes go through Merge Requests with a mandatory passing CI pipeline.

### Protected Tags

Under **Settings → Repository → Protected Tags**:

| Pattern | Create allowed  |
|---------|-----------------|
| `v*`    | Maintainers     |

Only Maintainers may create release tags. Prevents accidental or unauthorized releases from contributor branches.

### Merge Request Settings (recommended)

- **Squash commits** for `feature/*` → `develop`: clean develop history
- **Merge commit** for `release/*` → `main`: explicit merge node in the graph
- **Delete source branch** after merge: automatic, prevents branch graveyards
- **Require pipeline to succeed**: mandatory, no merge on red CI

---

## Tooling

The `/nebu-release` skill automates Git Flow operations for this project:

```
/nebu-release new-epic <name>   - create feature/<name> from develop
/nebu-release open <version>    - cut release/<version> from develop
/nebu-release rc                - tag current HEAD on release/* as RC
/nebu-release hotfix <desc>     - create hotfix/* from main
/nebu-release close             - close current release/* or hotfix/*
/nebu-release status            - show current git flow state
```

---

## Rejected Alternatives

### Option A: Trunk-Based Development

All features directly on `main`, no `develop` branch. Short-lived feature flags instead of branches. Popular with SaaS products using Continuous Deployment.

**Rejected** because Nebu is self-hosted: customers deploy to specific versions and require stable, tested release tags. Continuous Deployment does not fit the operating model of the target audience.

### Option B: GitLab Flow with Environment Branches

`main` for development, `stable` for production, no separate `develop` branch. Simpler, but less explicit in the RC phase.

**Rejected** because the RC phase is important for enterprise customers: they can validate RC images in staging environments before the stable release. GitLab Flow provides no clean mechanism for this.

### Option C: Full Git Flow (including `support/*` branches)

Maximum separation, including long-lived `support/*` branches for backports of older major versions.

**Deferred, not rejected.** `support/*` branches will be introduced once Nebu maintains multiple concurrently supported major versions. The overhead is not justified for the current project phase.

---

## Consequences

**Positive:**
- `:latest` is always a stable, tested release - reliable for deployment scripts and Docker Compose references in customer documentation
- Audit trail: every image tag is uniquely traceable to a git commit and a pipeline run (compliance relevance)
- RC phase enables controlled staging before release
- Hotfix flow prevents critical fixes from being lost in `develop`
- Named feature branches (`feature/<epic-name>`) enable parallel epic development without numbering conflicts

**Negative / Overhead:**
- Two merges per release (`release/*` → `main` and `release/*` → `develop`) - minor but real overhead
- Contributors must know the flow; documented in `CONTRIBUTING.md`
- GitLab Protected Branch / Tag configuration must be set up initially

**Deferred:**
- `CONTRIBUTING.md` with branch naming conventions and MR checklist
- Automated changelog from Conventional Commits (`git-cliff` or similar)
- `support/*` branches for long-term maintenance of older major versions

_Source: original German draft by Philipp Beyerlein, 2026-05-21_
