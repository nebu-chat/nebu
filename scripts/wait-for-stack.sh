#!/usr/bin/env bash
# =============================================================================
# scripts/wait-for-stack.sh
# Polls until all Nebu services (postgres, dex, server) are healthy or a 120s
# timeout is reached.
# go-removal-cleanup (full-elixir-stack): the Go gateway was removed — the server now
# serves the public Matrix endpoint, so there is no separate gateway to poll.
#
# Usage:
#    scripts/wait-for-stack.sh
#
# Exits 0 on success, 1 on timeout.
#
# Story 8-11 — AC #3: used as before_script in the integration-test-k8s CI job
# so that tests only run after the full stack is ready (GitLab CI services:
# start all sidecars in parallel without depends_on ordering).
# =============================================================================

set -euo pipefail

TIMEOUT=120
INTERVAL=2

# ---------------------------------------------------------------------------
# Health check functions — one per service
# ---------------------------------------------------------------------------
check_postgres() {
    if command -v pg_isready >/dev/null 2>&1; then
        pg_isready -h postgres -U nebu -d nebu >/dev/null 2>&1
        return $?
    fi
    # Fallback: bash TCP redirect (no external tool required)
    (bash -c 'cat /dev/null > /dev/tcp/postgres/5432') 2>/dev/null
}

check_dex() {
    wget -q -O- 'http://dex:5556/dex/.well-known/openid-configuration' >/dev/null 2>&1
}

check_server() {
    wget -q -O- 'http://server:4000/health' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------
echo "Waiting for stack to become healthy (timeout: ${TIMEOUT}s)..."

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    all_ok=true

    # postgres
    if check_postgres; then
        echo "[OK]   postgres"
    else
        echo "[..]   postgres"
        all_ok=false
    fi

    # dex
    if check_dex; then
        echo "[OK]   dex"
    else
        echo "[..]   dex"
        all_ok=false
    fi

    # server (serves the public Matrix endpoint after the full-elixir-stack cutover)
    if check_server; then
        echo "[OK]   server"
    else
        echo "[..]   server"
        all_ok=false
    fi

    if [ "$all_ok" = true ]; then
        echo "All services healthy after ${elapsed}s."
        exit 0
    fi

    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

echo "ERROR: stack not ready after ${TIMEOUT}s — timed out." >&2
exit 1
