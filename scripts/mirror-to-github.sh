#!/bin/sh
# =============================================================================
# scripts/mirror-to-github.sh
# Mirror the current checkout (openCoDE `main`) to the GitHub sister repository.
#
# The GitHub repo is a read-only mirror: it is never built there and all
# development happens on openCoDE. To make that obvious, the mirrored tree
# differs from openCoDE `main` by exactly one commit on top: README.md gets a
# banner pointing at the canonical openCoDE repository. (The repo contains no
# .github/workflows, so nothing is built on GitHub.)
#
# GitHub `main` therefore always is "<openCoDE main> + 1 mirror commit" and is
# force-pushed (with lease) on every sync. The mirror commit carries a
# `Mirrored-From: <sha>` trailer, which makes re-runs for the same openCoDE
# commit a no-op.
#
# Usage (CI):  MIRROR_REPO=nebu-chat/nebu MIRROR_TOKEN=... sh scripts/mirror-to-github.sh
# Usage (test): MIRROR_URL=/path/to/bare.git sh scripts/mirror-to-github.sh
#
# Requires a checkout with full history (GIT_DEPTH=0) so the parent commits of
# the mirror commit are the real openCoDE commits.
# =============================================================================
set -eu

BRANCH="${MIRROR_BRANCH:-main}"
SOURCE_URL="${SOURCE_URL:-https://gitlab.opencode.de/nebu/nebu-server}"

if [ -z "${MIRROR_URL:-}" ]; then
  : "${MIRROR_REPO:?MIRROR_REPO (e.g. nebu-chat/nebu) is required}"
  : "${MIRROR_TOKEN:?MIRROR_TOKEN (GitHub token with contents:write) is required}"
  MIRROR_URL="https://x-access-token:${MIRROR_TOKEN}@github.com/${MIRROR_REPO}.git"
fi

SRC_SHA=$(git rev-parse HEAD)
SRC_SHORT=$(git rev-parse --short=8 HEAD)

# Refuse shallow clones: GitHub must receive the full openCoDE history below the
# mirror commit, not a truncated one.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "error: shallow checkout — set GIT_DEPTH=0 for this job" >&2
  exit 1
fi

REMOTE_SHA=$(git ls-remote "$MIRROR_URL" "refs/heads/${BRANCH}" | cut -f1)
if [ -n "$REMOTE_SHA" ]; then
  git fetch --quiet "$MIRROR_URL" "$BRANCH"
  if git log -1 --format=%B FETCH_HEAD | grep -qx "Mirrored-From: ${SRC_SHA}"; then
    echo "Mirror already at ${SRC_SHORT} — nothing to do."
    exit 0
  fi
fi

git config user.name "Nebu Mirror Bot"
git config user.email "nebu-mirror@noreply.invalid"

# --- README banner (idempotent: an existing marker block is replaced) --------
HEADER_FILE=$(mktemp)
README_TMP=$(mktemp)
trap 'rm -f "$HEADER_FILE" "$README_TMP"' EXIT

cat > "$HEADER_FILE" <<EOF
<!-- mirror-header:start -->
> **Read-only mirror.** The canonical repository of Nebu lives on openCoDE:
> **<${SOURCE_URL}>**.
> Development, issues, merge requests and CI all happen there. This GitHub
> repository is synchronised automatically from \`main\` and is not built here —
> please file issues and contributions upstream.
<!-- mirror-header:end -->

EOF

sed '/<!-- mirror-header:start -->/,/<!-- mirror-header:end -->/d' README.md > "$README_TMP"
cat "$HEADER_FILE" "$README_TMP" > README.md

git add README.md
git commit -q \
  -m "chore(mirror): sync with openCoDE main @ ${SRC_SHORT}" \
  -m "Read-only mirror of ${SOURCE_URL}.
Adds the README mirror header." \
  -m "Mirrored-From: ${SRC_SHA}"

# Explicit lease on the tip we inspected above (empty = branch must not exist
# yet), so a concurrent push to the mirror is never silently overwritten.
git push "$MIRROR_URL" \
  --force-with-lease="refs/heads/${BRANCH}:${REMOTE_SHA}" \
  "HEAD:refs/heads/${BRANCH}"

echo "Mirrored ${SRC_SHORT} to ${MIRROR_REPO:-$MIRROR_URL} (${BRANCH})."
