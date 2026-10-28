#!/usr/bin/env bash
#
# setup_worktree_claude.sh — give a git WORKTREE of this repo its own, minimal `.claude/`.
#
# Why: a worktree usually gets `.claude` as a symlink to the main checkout. Then a Claude session started
# in the worktree sees ALL ~80 installed skills (bmad-*, cis-*, ...), writes agent memory into the main
# checkout and picks up whatever branch-state the main checkout's skills happen to be in. This script
# replaces the symlink with a real `.claude/` that contains ONLY what the nebu-pipeline really needs:
#
#   .claude/skills/   the pipeline skills + their dependencies (list below)
#   .claude/agents/   the nebu-* agents      (installed by install_claude_files.py from install/agents)
#   .claude/rules/    path-scoped rules      (installed by install_claude_files.py from install/rules)
#   .claude/settings.json   SubagentStart/Stop hooks (installed by install_claude_files.py)
#   .claude/agent-memory/   copied from the main checkout (reviewer/security patterns of earlier stories)
#
# NOT copied on purpose: settings.local.json (personal permission grants; copy by hand if you want them),
# every bmad-*/cis-* skill the pipeline does not call, nebu-release (epic-end extra, add it if needed),
# bmad-testarch-trace / bmad-retrospective (epic-end extras the pipeline only SUGGESTS to the user).
#
# Skill dependency set of the nebu-pipeline (derived from skills/nebu-pipeline/SKILL.md,
# pipeline-steps-spec.md, skills/nebu-pipeline-epic/SKILL.md and the `skills:` lines of the agents):
#   pipeline + epic runner      nebu-pipeline, nebu-pipeline-epic
#   story creation              nebu-lean-story
#   agents of the gates         nebu-agent-oracle (matrix-spec/ stays in the tracked skills/ dir: the Oracle reads it
#                               by path), nebu-agent-kassandra, nebu-agent-testing, nebu-agent-ux
#   convention skills (flat!)   cluster-safety, no-domain-model, sql-placement, elixir-otp, code-review-checklist,
#                               security-rules, matrix-spec-rules, ux-conventions   (the agents preload them by NAME,
#                               so they must be top-level skill dirs, not nested under nebu-conventions/)
#   pipeline steps              bmad-testarch-atdd, bmad-testarch-test-review, bmad-code-review (NOT tracked in git:
#                               copied from the main checkout's .claude/skills), bmad-maintain-arc42 (arc42 step)
#
# Idempotent: safe to run again after `git merge`/`git pull` changed skills/ (it re-copies from the tracked sources).
#
# Usage:  skills/nebu-pipeline/scripts/setup_worktree_claude.sh [--main <path-to-main-checkout>]
#
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
MAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --main) MAIN="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$MAIN" ]; then
  # the main checkout is the parent of the common git dir (…/open-chat/.git)
  MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
fi

TRACKED_SKILLS="nebu-pipeline nebu-pipeline-epic nebu-lean-story nebu-agent-oracle nebu-agent-kassandra nebu-agent-testing nebu-agent-ux bmad-maintain-arc42"
CONVENTION_SKILLS="cluster-safety no-domain-model sql-placement elixir-otp code-review-checklist security-rules matrix-spec-rules ux-conventions"
UNTRACKED_SKILLS="bmad-testarch-atdd bmad-testarch-test-review bmad-code-review"   # source: $MAIN/.claude/skills

cd "$ROOT"

if [ "$ROOT" = "$MAIN" ]; then
  echo "this is the main checkout: nothing to do (run it inside a worktree)" >&2
  exit 1
fi

if [ -L .claude ]; then
  echo "• removing the .claude symlink ($(readlink .claude))"
  rm .claude
fi
mkdir -p .claude/skills

copy_skill() { # <source dir> <skill name>
  local src="$1" name="$2"
  if [ ! -d "$src" ]; then echo "  ! missing source: $src" >&2; return 1; fi
  mkdir -p ".claude/skills/$name"
  rsync -a --delete \
    --exclude 'matrix-spec' --exclude 'install' --exclude '__pycache__' --exclude 'tests' \
    "$src/" ".claude/skills/$name/"
  echo "  ✓ skill $name"
}

echo "• tracked pipeline skills (from skills/)"
for s in $TRACKED_SKILLS; do copy_skill "skills/$s" "$s"; done

echo "• convention skills, flat (from skills/nebu-conventions/)"
for s in $CONVENTION_SKILLS; do copy_skill "skills/nebu-conventions/$s" "$s"; done

echo "• untracked bmad pipeline-step skills (from $MAIN/.claude/skills)"
for s in $UNTRACKED_SKILLS; do copy_skill "$MAIN/.claude/skills/$s" "$s" || true; done

echo "• agents, rules, hooks (install_claude_files.py)"
python3 skills/nebu-pipeline/scripts/install_claude_files.py

if [ -d "$MAIN/.claude/agent-memory" ]; then
  echo "• agent memory (copied from the main checkout; later writes stay in this worktree)"
  mkdir -p .claude/agent-memory
  rsync -a "$MAIN/.claude/agent-memory/" .claude/agent-memory/
fi

echo
echo "done: $(ls .claude/skills | wc -l | tr -d ' ') skills, $(ls .claude/agents | wc -l | tr -d ' ') agents, $(ls .claude/rules | wc -l | tr -d ' ') rules in $ROOT/.claude"
