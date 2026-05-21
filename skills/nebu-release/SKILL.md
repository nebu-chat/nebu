---
name: nebu-release
description: Manages Nebu releases and Git Flow branching (ADR-016): open/close feature epics, release branches, and hotfixes; update CHANGELOG.md, publiccode.yml, and README for each release. Use when starting a new feature epic, cutting a release, applying a hotfix, or closing a release branch.
---

# Nebu Release Manager

Implements the Git Flow strategy defined in ADR-016. Handles branch creation, release document
updates, merging, and tagging. All operations are interactive — nothing is pushed to the remote
without explicit user confirmation.

---

## Activation and Commands

```
/nebu-release                       — show status and help
/nebu-release status                — show current git flow state
/nebu-release new-epic <name>       — create feature/<name> from develop
/nebu-release open <version>        — cut release/<version> from develop
/nebu-release rc                    — tag HEAD on release/* as next RC
/nebu-release hotfix <description>  — create hotfix/* from main
/nebu-release close                 — close current release/* or hotfix/*
/nebu-release tag <version>         — emergency: manually tag HEAD on main
```

If invoked with no arguments, run `status` and print the command reference above.

---

## Pre-flight Checks (all commands)

Before any operation:

```bash
rtk git status
```

**If uncommitted changes:** warn and stop. The user must commit or stash before a release operation.

```bash
rtk git branch --show-current
```

Store as `CURRENT_BRANCH`.

```bash
rtk git log --oneline -5
```

Show for context.

---

## Command: `status`

Show a compact git flow overview:

```bash
rtk git branch -a | grep -E "main|develop|feature/|release/|hotfix/"
```

```bash
rtk git tag --sort=-version:refname | head -5
```

```bash
rtk git log --oneline $(rtk git describe --tags --abbrev=0 2>/dev/null || echo "HEAD")..HEAD --no-merges 2>/dev/null | head -20
```

Print:
```
Git Flow Status
═══════════════
Current branch: <CURRENT_BRANCH>
Latest release tags: v0.2.1, v0.2.0, v0.1.0 ...

Unreleased commits since <last-tag>:
  <git log output>

Active feature/release/hotfix branches:
  <branch list>
```

---

## Command: `new-epic <name>`

**Purpose:** Start a new feature epic. Creates the branch, story directory, and state scaffold.

**Naming rule:** `name` must be lowercase, hyphen-separated, domain-descriptive. Examples:
`matrix-presence`, `admin-room-api`, `gdpr-export`, `e2ee-key-management`.

### Steps

**1. Verify develop is up to date:**
```bash
rtk git checkout develop
rtk git pull origin develop
```

If pull fails (no remote or already up to date), continue with a warning.

**2. Create the feature branch:**
```bash
rtk git checkout -b feature/<name>
```

**3. Scaffold the epic directory:**
```bash
mkdir -p docs/stories/<name>
mkdir -p _bmad-output/nebu/epics/<name>/step-results
```

Create `_bmad-output/nebu/epics/<name>/sprint-status.yaml`:
```yaml
# generated: <TODAY_ISO>
# Epic: <name>
project: nebu
epic: <name>
epic_status: in-progress

development_status:
  # Stories are added as they complete.
  # Format:
  #   <story-slug>: done | in-progress | ready-for-dev | backlog
```

**4. Commit the scaffold (no source code yet):**
```bash
rtk git add docs/stories/<name>/ _bmad-output/nebu/epics/<name>/
rtk git commit -m "chore(<name>): scaffold epic directory and sprint-status"
```

**5. Show:**
```
✓ Epic '<name>' started.
  Branch:       feature/<name>
  Stories:      docs/stories/<name>/
  State:        _bmad-output/nebu/epics/<name>/

Start stories with:
  /nebu-pipeline --epic <name>
  /nebu-pipeline-epic --epic <name>

When development is complete, open a MR from feature/<name> → develop.
```

---

## Command: `open <version>`

**Purpose:** Cut a release branch from develop. `version` is the minor version (e.g. `v0.3` — no patch suffix).

### Steps

**1. Verify on develop and pull:**
```bash
rtk git checkout develop && rtk git pull origin develop
```

**2. Validate version format:** must match `v\d+\.\d+` (e.g. `v0.3`, `v1.0`). Stop if invalid.

**3. Show what goes into the release:**
```bash
LAST_TAG=$(rtk git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
  rtk git log $LAST_TAG..HEAD --oneline --no-merges
fi
```

Ask: "Cut `release/<version>` from develop now? [Y/n]"

**4. Create release branch:**
```bash
rtk git checkout -b release/<version>
```

**5. Initialize CHANGELOG entry placeholder:**

Check if `CHANGELOG.md` already has a `## [X.Y.0]` section. If not, add a placeholder at the top (after the header) for the user to fill in:

```markdown
## [X.Y.0] – <TODAY>

### Added

- <!-- describe new features -->

### Fixed

- <!-- describe bug fixes -->

### Changed

- <!-- describe changes -->

```

Commit:
```bash
rtk git add CHANGELOG.md
rtk git commit -m "chore(release): open release/<version> — CHANGELOG placeholder"
```

**6. Show:**
```
✓ Release branch created: release/<version>
  Fill in CHANGELOG.md, then run /nebu-release rc for a release candidate
  or /nebu-release close when ready to ship.
```

---

## Command: `rc`

**Purpose:** Tag the current HEAD on a `release/*` branch as the next release candidate.

### Steps

**1. Verify on `release/*` branch:**
```bash
CURRENT_BRANCH=$(rtk git branch --show-current)
```
If not `release/*`, stop with: "RC tagging only allowed on `release/*` branches."

**2. Derive version from branch name:** `release/v0.3` → base `v0.3.0`.

**3. Find next RC number:**
```bash
rtk git tag --sort=-version:refname | grep "^v0.3.0-rc\." | head -3
```
Increment: if `v0.3.0-rc.2` exists, next is `v0.3.0-rc.3`. If none, start at `v0.3.0-rc.1`.

**4. Confirm:**
Ask: "Tag current HEAD as `<RC_TAG>`? [Y/n]"

**5. Create tag:**
```bash
rtk git tag <RC_TAG>
```

**6. Show:**
```
✓ RC tagged: <RC_TAG>
  Push with: git push origin <RC_TAG>
  (GitLab CI will build a :rc-X.Y.Z-rc.N image)
```

---

## Command: `hotfix <description>`

**Purpose:** Create a hotfix branch from main to address a critical production issue.

`description` should be short and lowercase-hyphenated, e.g. `cve-fix`, `login-redirect-bug`.

### Steps

**1. Checkout main and pull:**
```bash
rtk git checkout main && rtk git pull origin main
```

**2. Determine current patch version:**
```bash
CURRENT_TAG=$(rtk git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
```
Parse `CURRENT_TAG` as `vMAJOR.MINOR.PATCH`. Increment PATCH by 1 → `HOTFIX_VERSION`.

**3. Show:**
```
Current main: <CURRENT_TAG>
Hotfix will become: <HOTFIX_VERSION>
Branch: hotfix/<HOTFIX_VERSION>-<description>
```

Ask: "Create hotfix branch? [Y/n]"

**4. Create branch:**
```bash
rtk git checkout -b hotfix/<HOTFIX_VERSION>-<description>
```

**5. Show:**
```
✓ Hotfix branch created: hotfix/<HOTFIX_VERSION>-<description>

Implement the fix, then run /nebu-release close to finalize the hotfix.
The hotfix will be tagged as <HOTFIX_VERSION> and merged to both main and develop.
```

---

## Command: `close`

**Purpose:** Finalize the current `release/*` or `hotfix/*` branch — update release docs, merge to main and develop, create the release tag.

Detect current branch type:
- `release/*` → run **Release Close Flow**
- `hotfix/*` → run **Hotfix Close Flow**
- Anything else → stop with error.

---

### Release Close Flow

**1. Determine version:**
- Branch `release/v0.3` → version `v0.3.0`
- If user wants a different patch (e.g. `v0.3.1` for a multi-RC release), ask.

**2. Verify CHANGELOG.md has a complete entry for `[X.Y.0]`:**
```bash
grep -n "\[X.Y.0\]" CHANGELOG.md
```
If missing or placeholder text remains: show the diff since the last tag and ask the user to complete the CHANGELOG before continuing. Spawn a sub-agent to draft a CHANGELOG entry:

```
You are helping draft a CHANGELOG entry for Nebu release <VERSION>.
Based on the following git commits, write a Keep-a-Changelog-formatted section
(### Added, ### Fixed, ### Changed — omit empty sections).
Focus on user-visible changes. Skip internal tooling commits (chore, refactor, ci).

Git log:
<GIT_LOG_OUTPUT>
```

Show the draft. User edits and confirms before continuing.

**3. Update `publiccode.yml`:**
```bash
rtk grep -n "softwareVersion\|releaseDate" publiccode.yml
```
Update:
- `softwareVersion: "X.Y.Z"`
- `releaseDate: "<TODAY_ISO>"`

```bash
rtk git add publiccode.yml
```

**4. Check README.md status line:**
```bash
grep -n "Status.*pre-alpha\|Status.*alpha\|Epics.*complete" README.md
```
Show any matches. Ask the user: "Does the README status line need updating? [show current, y/n to edit]"
If yes, open for manual edit or ask what to change.

**5. Commit release doc updates:**
```bash
rtk git add CHANGELOG.md publiccode.yml README.md
rtk git commit -m "chore(release): update CHANGELOG, publiccode.yml, README for <VERSION>"
```

**6. Confirm and merge to main:**
```
About to:
  1. git checkout main && git merge --no-ff release/<version>
  2. git tag <VERSION>
  3. git checkout develop && git merge --no-ff release/<version>
  4. Delete branch release/<version> (optional)

Proceed? [Y/n]
```

```bash
rtk git checkout main
rtk git merge --no-ff release/<version> -m "release: merge release/<version> → main"
rtk git tag <VERSION>
```

**7. Merge back to develop:**
```bash
rtk git checkout develop
rtk git merge --no-ff release/<version> -m "release: merge release/<version> → develop (RC fixes)"
```

**8. Offer branch cleanup:**
Ask: "Delete release/<version> branch? [Y/n]"
```bash
rtk git branch -d release/<version>
```

**9. Show:**
```
✓ Release <VERSION> closed.
  Tagged: <VERSION>
  main:   merged ✓
  develop: merged ✓

Push commands:
  git push origin main
  git push origin develop
  git push origin <VERSION>

Next steps (optional):
  /bmad-maintain-arc42     — review and update architecture docs
  /bmad-retrospective      — if this closes an epic
```

---

### Hotfix Close Flow

**1. Determine version from branch name:**
`hotfix/v0.2.2-cve-fix` → `VERSION=v0.2.2`

**2. Update `CHANGELOG.md`:** add or verify hotfix entry. Use the same agent-assisted draft approach as in the Release Close Flow if no entry exists.

**3. Update `publiccode.yml`:** same as Release Close Flow.

**4. Commit:**
```bash
rtk git add CHANGELOG.md publiccode.yml
rtk git commit -m "chore(hotfix): update CHANGELOG and publiccode.yml for <VERSION>"
```

**5. Confirm and merge:**
```
About to:
  1. git checkout main && git merge --no-ff hotfix/<branch>
  2. git tag <VERSION>
  3. git checkout develop && git merge --no-ff hotfix/<branch>
  4. Delete hotfix/<branch> (optional)

Proceed? [Y/n]
```

```bash
rtk git checkout main
rtk git merge --no-ff hotfix/<branch> -m "hotfix: merge hotfix/<branch> → main"
rtk git tag <VERSION>
rtk git checkout develop
rtk git merge --no-ff hotfix/<branch> -m "hotfix: merge hotfix/<branch> → develop"
```

**6. Offer branch cleanup:**
```bash
rtk git branch -d hotfix/<branch>
```

**7. Show:**
```
✓ Hotfix <VERSION> closed.
  Tagged: <VERSION>
  main:   merged ✓
  develop: merged ✓

Push commands:
  git push origin main
  git push origin develop
  git push origin <VERSION>
```

---

## Command: `tag <version>`

**Purpose:** Emergency direct tagging. Only for cases where the close flow cannot be used (e.g. manual merge already done).

**1. Verify on `main`:**
```bash
rtk git branch --show-current
```
If not `main`, warn: "Tag should be created on main. Current branch: <X>. Continue? [y/N]"

**2. Validate version format:** must match `v\d+\.\d+\.\d+(-rc\.\d+)?`.

**3. Check for duplicate tag:**
```bash
rtk git tag | grep "^<version>$"
```
If exists, stop with error.

**4. Confirm:**
Ask: "Create tag `<version>` on current HEAD (`<short-sha>`)? [Y/n]"

**5. Create tag:**
```bash
rtk git tag <version>
```

Show:
```
✓ Tagged: <version>
Push with: git push origin <version>
```

---

## Release Sequence Reference

### Full Feature Release

```
1. /nebu-release new-epic <name>          # start feature development
   /nebu-pipeline --epic <name>           # implement stories (repeat)
   → MR: feature/<name> → develop         # when done, open MR on GitLab

2. /nebu-release open <version>           # cut release branch when develop is stable
   /nebu-release rc                       # optional: tag RC for staging tests

3. /nebu-release close                    # update docs, merge, tag
   git push origin main develop <VERSION>
```

### Hotfix

```
1. /nebu-release hotfix <description>     # branch from main
   # implement fix
   /nebu-release close                    # update docs, merge, tag
   git push origin main develop <VERSION>
```

---

## Error Handling

| Situation | Response |
|---|---|
| Uncommitted changes | Stop. Instruct user to commit or stash. |
| Not on expected branch | Stop with clear message. |
| Invalid version format | Stop. Show expected format. |
| CHANGELOG placeholder still present | Stop until user completes the entry. |
| Merge conflict | Stop. Show conflict files. Instruct user to resolve and re-run. |
| Remote not available | Warn but continue locally. Show manual push command. |
| Tag already exists | Stop with error. Never overwrite a tag. |

---

## Conventions (from ADR-016)

- Epic names: `feature/<name>` — lowercase, hyphen-separated, max 30 chars
- Hotfix branches: `hotfix/vX.Y.Z-<description>`
- Release branches: `release/vX.Y` (no patch — patch is `0` unless RCs reveal issues)
- Tags: `vMAJOR.MINOR.PATCH` (never `v1.0` without patch suffix)
- CHANGELOG: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format
