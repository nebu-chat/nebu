#!/usr/bin/env bash
#
# no-go-files.sh — CI smoke gate for the full-elixir-stack migration.
#
# Acceptance Test AT#1 (docs/stories/full-elixir-stack/go-removal-cleanup.md):
#   When executed in the repo root,
#   Then exit 0 if `find . -name "*.go" -not -path "*/vendor/*"` returns empty,
#        exit 1 with the list of found .go files otherwise.
#
# This proves the Go layer is fully removed. It is intentionally toolchain-free
# (pure POSIX find) so it runs in any CI image without a Go toolchain installed.
#
set -euo pipefail

# Resolve the repository root so the gate works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# Exclude vendored third-party Go (none expected, but matches the AC literally)
# and the .git directory. node_modules can carry .go fixtures from JS tooling and
# is never part of our source tree, so it is excluded too.
# Portable across bash 3.2 (macOS) and 4+ — no mapfile.
GO_FILES="$(
  find . \
    -path './.git' -prune -o \
    -path '*/vendor/*' -prune -o \
    -path '*/node_modules/*' -prune -o \
    -name '*.go' -type f -print | sort
)"

if [ -z "${GO_FILES}" ]; then
  echo "OK: no Go source files found — full-elixir-stack migration complete."
  exit 0
fi

COUNT="$(printf '%s\n' "${GO_FILES}" | grep -c .)"
echo "FAIL: Go source files still present (the Go layer must be fully removed):" >&2
printf '%s\n' "${GO_FILES}" | sed 's/^/  /' >&2
echo "" >&2
echo "Found ${COUNT} .go file(s). See docs/stories/full-elixir-stack/go-removal-cleanup.md" >&2
exit 1
