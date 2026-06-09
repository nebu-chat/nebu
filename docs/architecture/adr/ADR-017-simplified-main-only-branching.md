# ADR-017: Simplified Main-Only Branching Strategy

## Status

Accepted - 2026-06-09

Supersedes: ADR-016

## Context

ADR-016 introduced a simplified Git Flow with two long-lived branches (`main` and `develop`). In practice this caused two problems:

1. **publiccode.yml tooling** — the opencode scanner interprets `develop` as a second default/main branch and emits validation warnings, which block automated compliance checks.
2. **Unnecessary overhead** — feature branches already provide isolation. The `develop` branch acts solely as a staging area before `main`, but the double-merge step (`release/*` → `main` and `release/*` → `develop`) adds friction without a corresponding benefit at the current team size.

## Decision

Remove `develop`. `main` is the single long-lived branch.

### Branch Overview

| Branch       | Purpose                                                  | Lifetime       |
|--------------|----------------------------------------------------------|----------------|
| `main`       | Single long-lived integration and release branch         | permanent      |
| `feature/*`  | Feature epics (`feature/<epic-name>`)                    | until MR merge |
| `bugfix/*`   | Non-critical bugfixes                                    | until MR merge |
| `release/*`  | Release preparation (RC phase, bugfixes only)            | until release  |
| `hotfix/*`   | Critical fixes applied directly to main                  | until release  |

### Invariants

- **`main` is always compilable with all tests green.** All branches merge only after CI passes (mandatory MR pipeline).
- **Semantic Versioning.** Release tags follow `vMAJOR.MINOR.PATCH`. Pre-release: `v0.2.0-rc.1`.
- **Release tags are always created on `main`.**
- **Direct push to `main` is forbidden.** Changes arrive via MR merge from `feature/*`, `bugfix/*`, `release/*`, or `hotfix/*`.

---

## Flows

### 1. Normal Feature Flow

```
main
  │
  ├─── feature/matrix-presence   (MR → main, squash or merge commit)
  │
  ├─── feature/admin-room-api    (MR → main)
  │
  └─── main (accumulates features until release decision)
```

### 2. Release Flow

```
main
  │
  └─── release/v0.3             (branched from main)
         │   ← bugfixes only, no new features
         │
         ├── tag: v0.3.0-rc.1   (optional RC for internal/staging tests)
         ├── tag: v0.3.0-rc.2
         │
         └── merge → main        (fast-forward or merge commit)
               └── tag: v0.3.0
```

### 3. Hotfix Flow

```
main (v0.2.1)
  │
  └─── hotfix/v0.2.2-cve-fix    (branched from main)
         │
         └── merge → main
               └── tag: v0.2.2
```

No merge-back to a separate integration branch is needed — `main` already is the integration branch.

---

## CI/CD and Registry Mapping

| Trigger                          | Image Tag                               | Description                    |
|----------------------------------|-----------------------------------------|--------------------------------|
| Push to `main`                   | `:dev-<pipeline-id>`, `:dev-latest`    | Integration build, unstable    |
| Branch `release/vX.Y`            | `:rc-X.Y.Z-rc.N`                       | Release candidate              |
| Tag `vX.Y.Z` on `main`           | `:X.Y.Z`, `:latest`                    | Stable release                 |

`:latest` always and exclusively points to the most recent stable release tag.

---

## GitLab Configuration

### Protected Branches

Under **Settings → Repository → Protected Branches**:

| Branch    | Merge allowed  | Push allowed | Force Push |
|-----------|----------------|--------------|------------|
| `main`    | Maintainers    | Nobody       | No         |

Remove protection on `develop` if previously configured.

### Protected Tags

Under **Settings → Repository → Protected Tags**:

| Pattern | Create allowed  |
|---------|-----------------|
| `v*`    | Maintainers     |

### Merge Request Settings (recommended)

- **Squash commits** for `feature/*` → `main`: clean history
- **Merge commit** for `release/*` → `main`: explicit merge node in the graph
- **Delete source branch** after merge: automatic
- **Require pipeline to succeed**: mandatory

---

## Tooling

The `/nebu-release` skill automates branching operations for this project:

```
/nebu-release new-epic <name>   - create feature/<name> from main
/nebu-release open <version>    - cut release/<version> from main
/nebu-release rc                - tag current HEAD on release/* as RC
/nebu-release hotfix <desc>     - create hotfix/* from main
/nebu-release close             - close current release/* or hotfix/* → merge to main, tag
/nebu-release status            - show current git flow state
```

---

## Migration from ADR-016

1. Delete the `develop` branch after all open MRs targeting `develop` are retargeted to `main`.
2. Remove the `develop` protected branch rule in GitLab Settings.
3. Update any Renovate or bot configurations that reference `develop` as the base branch.

---

## Rejected Alternatives

### Keep `develop`

Would retain the familiar Git Flow model but does not resolve the publiccode.yml scanner issue (the primary driver of this change) and keeps the double-merge overhead.

---

## Consequences

**Positive:**
- publiccode.yml scan passes without warnings
- One fewer long-lived branch — simpler mental model for contributors
- No more double merge on release close (was: `release/*` → `main` AND `release/*` → `develop`)
- `:dev-latest` builds on every MR merge, giving a continuously updated preview image

**Negative / Overhead:**
- `main` is slightly less stable than the old `develop` was, since it also carries unreleased work. Mitigated by mandatory CI on MR and branch protection (no direct push).
- Contributors familiar with ADR-016 need to update their mental model (`feature/*` → `main`, not → `develop`).

_Decision: Philipp Beyerlein, 2026-06-09_
