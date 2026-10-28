#!/usr/bin/env bash
# =============================================================================
# e2e-ci.sh — the Playwright e2e suites of the GitLab CI jobs (also runnable locally)
#
#   scripts/e2e-ci.sh element   Element Web (project element-web) against the plain-http compose stack
#                               (localhost:8008 / :7070 / dex.localtest.me:5556): CI job `e2e-element-web`
#   scripts/e2e-ci.sh admin     the Admin UI scenarios (project admin-ui) EXCEPT the OAuth ones, against the same plain-http stack: CI job `e2e-admin-ui`
#   scripts/e2e-ci.sh oauth     the OAuth 2.0 authorization server scenarios (features/oauth, oauth-client-approvals / -revocation,
#                               oauth-switch of the admin-ui project) against the HTTPS front door of dev/tls
#                               (https://nebu.localtest.me:7443, local CA, oauth issuer = that origin): CI job `e2e-oauth-https`
#
# Both need a Docker daemon (a DinD service in CI): compose starts the stack with published ports, Playwright runs in a container on
# the HOST network so that the origins the Element config and the Dex redirect URIs are registered for (localhost:7070, :8008,
# dex.localtest.me:5556, nebu.localtest.me:7443) are reached as they are. `--add-host` replaces an /etc/hosts edit (many DNS servers
# refuse *.localtest.me -> 127.0.0.1).
#
# Environment (all optional):
#   NEBU_E2E_PREBUILT=1   use the registry image of the server (docker-compose.ci.yml: $CI_REGISTRY_IMAGE/server:$CI_COMMIT_SHA, built by
#                         the `build-server-image` job) instead of building the server image in the DinD daemon (about 5-10 minutes)
#   NEBU_E2E_GREP         extra Playwright arguments (a test name filter, e.g. --grep @ac6-login)
#   NEBU_E2E_KEEP=1       leave the stack running after the run
#
# Exit status: the Playwright exit status (0 = every scenario passed). Reports: e2e/playwright-report/ (HTML), e2e/test-results/
# (screenshots, traces), e2e/junit.xml. The stack is always torn down (compose down -v) unless NEBU_E2E_KEEP=1.
# =============================================================================
set -euo pipefail

SUITE="${1:-}"
case "${SUITE}" in element | admin | oauth) ;; *)
  echo "usage: $0 element|admin|oauth" >&2
  exit 2
  ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"

# the Playwright image MUST match @playwright/test of e2e/package-lock.json (its browsers are built for exactly that version)
PW_VERSION="$(sed -n '/"node_modules\/@playwright\/test"/,/"version"/p' e2e/package-lock.json | sed -n 's/.*"version": "\([0-9.]*\)".*/\1/p' | head -1)"
[[ -n "${PW_VERSION}" ]] || { echo "cannot read the @playwright/test version from e2e/package-lock.json" >&2; exit 2; }
PW_IMAGE="${NEBU_E2E_PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v${PW_VERSION}-jammy}"

COMPOSE=(docker compose -f docker-compose.yml)
if [[ "${SUITE}" == "oauth" ]]; then
  [[ -f dev/tls/certs/localhost.crt ]] || sh dev/tls/gen-certs.sh
  COMPOSE+=(-f dev/tls/docker-compose.tls.yml)
fi
if [[ "${NEBU_E2E_PREBUILT:-}" == "1" ]]; then
  COMPOSE+=(-f docker-compose.ci.yml)
fi
COMPOSE+=(--profile e2e)

# shellcheck disable=SC2329  # invoked by the EXIT trap
teardown() {
  local rc=$?
  if [[ "${NEBU_E2E_KEEP:-}" != "1" ]]; then
    "${COMPOSE[@]}" logs --no-color --tail=300 server > e2e/server.log 2>&1 || true
    "${COMPOSE[@]}" down -v --remove-orphans > /dev/null 2>&1 || true
  fi
  exit "${rc}"
}
trap teardown EXIT

make setup
# Overridable (story rate-limits-join-invite-create-room, D5): CI keeps the default `true`; the verification run B of that story sets
# NEBU_RATE_LIMIT_DISABLED=false to prove that the default limits are never hit by the element-web suite.
export NEBU_RATE_LIMIT_DISABLED="${NEBU_RATE_LIMIT_DISABLED:-true}"

if [[ "${NEBU_E2E_PREBUILT:-}" == "1" ]]; then
  "${COMPOSE[@]}" pull server
fi

if [[ "${SUITE}" == "oauth" ]]; then
  "${COMPOSE[@]}" up -d --wait postgres dex minio server element
else
  "${COMPOSE[@]}" up -d --wait
fi

ADD_HOSTS=(--add-host=dex.localtest.me:127.0.0.1 --add-host=nebu.localtest.me:127.0.0.1)
ENVS=(
  -e CI=1
  -e NEBU_E2E_GREP="${NEBU_E2E_GREP:-}"
  -e NEBU_E2E_NAV_TIMEOUT_MS="${NEBU_E2E_NAV_TIMEOUT_MS:-60000}"
  -e NEBU_OIDC_ISSUER=http://dex.localtest.me:5556/dex
  -e DEX_ISSUER_URL=http://dex.localtest.me:5556/dex
  # the direct-DB fixtures (fixtures/db.ts) use host `psql` against this URL (the compose postgres publishes 5432; host network)
  -e NEBU_DB_URL=postgresql://nebu:nebu_dev_password@localhost:5432/nebu
)

if [[ "${SUITE}" == "element" || "${SUITE}" == "admin" ]]; then
  ENVS+=(
    -e NEBU_BASE_URL=http://localhost:8008
    -e NEBU_ADMIN_URL=http://localhost:8008
    -e NEBU_MATRIX_BASE=http://localhost:8008
    -e NEBU_ELEMENT_URL=http://localhost:7070
  )
  if [[ "${SUITE}" == "element" ]]; then
    PW_ARGS="--project=element-web"
  else
    # every scenario of the admin-ui project except the OAuth groups (they need the https stack: suite `oauth`)
    ENVS+=(-e NEBU_E2E_TAGS="not @pending-feature and not @short-ttl and not @known-failure and not @legacy-sso-confirm and not @oauth-account and not @oauth-authorize and not @oauth-consent and not @oauth-approvals and not @oauth-revocation and not @oauth-switch")
    PW_ARGS="--project=admin-ui"
  fi
else
  ORIGIN="https://nebu.localtest.me:7443"
  ENVS+=(
    -e NEBU_BASE_URL="${ORIGIN}"
    -e NEBU_ADMIN_URL="${ORIGIN}"
    -e NEBU_MATRIX_BASE="${ORIGIN}"
    -e NEBU_ELEMENT_URL="${ORIGIN}"
    # the oauth issuer IS the browser's origin (the consent / account POST checks its Origin against the issuer, e2e/fixtures/oauth-issuer.ts)
    -e NEBU_E2E_OAUTH_ISSUER="${ORIGIN}"
    # no Matrix user sessions are needed: skip the Element warm-up (there is no Element at localhost:7070 on this stack)
    -e NEBU_E2E_SKIP_USER_WARMUP=1
    # node (fetch in fixtures) trusts the local CA of dev/tls; Chromium ignores certificate errors (e2e/fixtures/client-stubs.ts)
    -e NODE_EXTRA_CA_CERTS=/workspace/dev/tls/certs/ca.pem
  )
  PW_ARGS="--project=admin-ui features/oauth oauth-client-approvals oauth-client-revocation oauth-switch"
fi

if [[ "${SUITE}" == "oauth" ]]; then
  # The oauth switch of the stack: the issuer is the front door's origin (the scenarios switch `oauth_enabled` themselves and restore the issuer
  # they found; without an issuer a DCR registration answers "OAuth 2.0 is not supported by this server"). The same two keys as dev/tls/oauth.sh.
  "${COMPOSE[@]}" exec -T postgres psql -U nebu_migrate -d nebu -v ON_ERROR_STOP=1 -c "
    INSERT INTO server_config (key, value, set_at) VALUES
      ('oauth_enabled', 'true', extract(epoch from now())::bigint),
      ('oauth_issuer_url', '${ORIGIN}', extract(epoch from now())::bigint)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at"
fi

set +e
docker run --rm --network=host "${ADD_HOSTS[@]}" -v "${ROOT}:/workspace" -w /workspace/e2e "${ENVS[@]}" \
  -e PLAYWRIGHT_HTML_OPEN=never -e PLAYWRIGHT_JUNIT_OUTPUT_FILE=junit.xml \
  "${PW_IMAGE}" \
  sh -c 'apt-get update -qq > /dev/null && apt-get install -y -qq postgresql-client > /dev/null \
    && npm ci --silent && npm run preflight && npx bddgen \
    && npx playwright test --reporter=list,html,junit '"${PW_ARGS}"' ${NEBU_E2E_GREP:-}'
RC=$?
set -e
exit "${RC}"
