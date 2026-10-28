#!/usr/bin/env bash
# =============================================================================
# ci-local.sh
# Run CI jobs locally via Docker — mirrors GitLab CI exactly.
#
# Uses the same Docker images as .gitlab-ci.yml (single source of truth).
# Calling any job here produces the same result as the pipeline.
#
# go-removal-cleanup (full-elixir-stack): the Go layer was removed — lint-go and
# test-unit-go are gone; a no-go-files smoke gate replaces them.
#
# Usage:
#   scripts/ci-local.sh                # run all jobs sequentially
#   scripts/ci-local.sh --no-go        # run no-go-files smoke gate only
#   scripts/ci-local.sh --test-elixir  # run test-unit-elixir only
#   scripts/ci-local.sh --scan         # run secret-scan only
#   scripts/ci-local.sh --verify       # run verify-docs only
#   scripts/ci-local.sh --docs         # build documentation website (static)
#   scripts/ci-local.sh --docs-watch   # start docs dev server with live-reload
#   scripts/ci-local.sh --all          # run all jobs (same as no args)
#
# Jobs: no-go-files  test-unit-elixir  secret-scan  verify-docs
# Docs: --docs / --docs-watch require Node.js + npx (not Docker)
#
# Requires: Docker in PATH (all jobs except --docs / --docs-watch)
#           Node.js + npx in PATH (--docs / --docs-watch only)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Image versions — keep in sync with the Makefile (DOCKER_ELIXIR).
# Public docker.io images so the script works on a fresh clone without
# access to the GitLab Container Registry.
# ---------------------------------------------------------------------------
ELIXIR_IMAGE="elixir:1.19-alpine"

# ---------------------------------------------------------------------------
# Pre-flight: Docker must be in PATH
# ---------------------------------------------------------------------------
preflight_check() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found in PATH." >&2
        echo "  Install Docker Desktop or Docker Engine and ensure it is running." >&2
        echo "  See https://docs.docker.com/get-docker/" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# docker_run — mount repo into /workspace and run a command
# ---------------------------------------------------------------------------
docker_run() {
    docker run --rm \
        -v "${REPO_ROOT}:/workspace" \
        -w /workspace \
        "$@"
}

# ---------------------------------------------------------------------------
# Individual job functions
# ---------------------------------------------------------------------------
job_no_go_files() {
    echo "==> no-go-files (full-elixir-stack smoke gate)"
    "${SCRIPT_DIR}/../test/smoke/no-go-files.sh"
}

job_test_unit_elixir() {
    echo "==> test-unit-elixir"
    docker_run "${ELIXIR_IMAGE}" \
        sh -c "cd server && mix local.hex --force && mix local.rebar --force && mix deps.get && mix test --warnings-as-errors"
}

job_secret_scan() {
    echo "==> secret-scan"
    "${SCRIPT_DIR}/scan-secrets.sh" --ci
}

job_verify_docs() {
    echo "==> verify-docs"
    "${SCRIPT_DIR}/verify-readme-attribution.sh"
    "${SCRIPT_DIR}/verify-contributing.sh"
    "${SCRIPT_DIR}/verify-security-policy.sh"
}

# ---------------------------------------------------------------------------
# docs helpers — require Node.js / npx, not Docker
# ---------------------------------------------------------------------------
_docs_preflight() {
    if ! command -v npx >/dev/null 2>&1; then
        echo "ERROR: npx not found in PATH." >&2
        echo "  Install Node.js (https://nodejs.org/) and ensure npx is available." >&2
        exit 1
    fi
}

_docs_prepare() {
    echo "  Injecting docs/architecture/ and docs/getting-started.md ..."
    mkdir -p "${REPO_ROOT}/website/dokument/architecture"
    cp -r "${REPO_ROOT}/docs/architecture/." "${REPO_ROOT}/website/dokument/architecture/"
    cp "${REPO_ROOT}/docs/getting-started.md" "${REPO_ROOT}/website/dokument/getting-started.md"
}

job_docs() {
    echo "==> docs (static build → ${REPO_ROOT}/out)"
    _docs_preflight
    _docs_prepare
    cd "${REPO_ROOT}" && npx --yes @document-writing-tools/markdown-webbook@2.1.0 \
        --input website/dokument \
        --output out \
        --title "Nebu" \
        --theme opencode \
        --copyright "Nebu contributors - Apache 2.0" \
        --logo-path "website/dokument/assets/nebu-logo.svg" \
        --copy-to-public-dir "website/dokument/public-extra"
    echo "  Output: ${REPO_ROOT}/out/index.html"
}

job_docs_watch() {
    echo "==> docs-watch (dev server - http://localhost:3000)"
    _docs_preflight
    _docs_prepare
    cd "${REPO_ROOT}" && npx --yes @document-writing-tools/markdown-webbook@2.1.0 \
        --input website/dokument \
        --title "Nebu" \
        --theme opencode \
        --copyright "Nebu contributors - Apache 2.0" \
        --logo-path "website/dokument/assets/nebu-logo.svg" \
        --copy-to-public-dir "website/dokument/public-extra" \
        --watch
}

run_all() {
    job_no_go_files
    job_test_unit_elixir
    job_secret_scan
    job_verify_docs
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    local rc="${1:-1}"
    cat >&2 <<EOF
Usage: $(basename "$0") [MODE]

Modes:
  (no args)        run all jobs sequentially (excludes docs)
  --all            run all jobs sequentially (excludes docs)
  --no-go          run no-go-files smoke gate
  --test-elixir    run test-unit-elixir
  --scan           run secret-scan
  --verify         run verify-docs
  --docs           build documentation website (static, output: /tmp/nebu-website-out)
  --docs-watch     start docs dev server with live-reload (http://localhost:3000)
  --help, -h       show this message

CI jobs (--all, --test-elixir, --scan, --verify): require Docker in PATH.
  Uses public docker.io image: elixir:1.19-alpine.
  --no-go runs without Docker.

Docs jobs (--docs, --docs-watch): require Node.js + npx in PATH.
  Uses @document-writing-tools/markdown-webbook via npx (no Docker needed).
EOF
    exit "${rc}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MODE="${1:-all}"

# --help / -h and --no-go work without docker being installed
case "${MODE}" in
    --help | -h)
        usage 0
        ;;
    --no-go)
        job_no_go_files
        exit 0
        ;;
esac

preflight_check

case "${MODE}" in
    --all | all)
        run_all
        ;;
    --test-elixir)
        job_test_unit_elixir
        ;;
    --scan)
        job_secret_scan
        ;;
    --verify)
        job_verify_docs
        ;;
    --docs)
        job_docs
        ;;
    --docs-watch)
        job_docs_watch
        ;;
    *)
        echo "Unknown mode: ${MODE}" >&2
        usage 1
        ;;
esac
