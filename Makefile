# Nebu — Docker-only build system
# All build commands run inside Docker containers.
# No local Go, Elixir, or buf installation required.

# go-removal-cleanup (full-elixir-stack): DOCKER_GO / DOCKER_NODE / DOCKER_BUF were used
# only by the now-removed Go gateway build and admin asset pipeline.
DOCKER_ELIXIR = docker run --rm -v $(PWD):/workspace -w /workspace elixir:1.20-alpine
DOCKER_TOFU   = docker run --rm --entrypoint sh -v $(PWD):/workspace -w /workspace ghcr.io/opentofu/opentofu:1.9
DOCKER_HELM   = docker run --rm --entrypoint sh -v $(PWD):/workspace -w /workspace alpine/helm:3.17

# Registry used for release images — override by setting CI_REGISTRY_IMAGE in the environment.
CI_REGISTRY_IMAGE ?= registry.gitlab.com/philippb/open-chat

# Strip the leading 'v' from TAG (e.g. v1.0.0 → 1.0.0) for image tagging.
IMAGE_VERSION = $(patsubst v%,%,$(TAG))

.PHONY: ci build-gateway build-media build-server redeploy dev dev-reset-db setup test-unit-go test-unit-elixir test-integration test-integration-elixir test-integration-ci test-e2e test-matrix-compat test-load-silber build-element-e2e test-e2e-element build-fluffychat-e2e test-e2e-fluffychat gen-api assets test-compose-ports test-compose-minio test-iac-validate test-load-syntax release release-push

## ci: Aggregate CI gate — Elixir unit tests + the no-go-files smoke gate (AT#2).
## go-removal-cleanup (full-elixir-stack): the canonical local CI entrypoint after
## the Go layer was removed.
ci: test-unit-elixir
	./test/smoke/no-go-files.sh

## build-gateway: REMOVED — the Go gateway no longer exists (full-elixir-stack migration).
build-gateway:
	@echo "Error: Go layer has been removed in the full-elixir-stack migration. See docs/stories/full-elixir-stack/go-removal-cleanup.md" && exit 1

## build-media: REMOVED — the Go media gateway no longer exists (full-elixir-stack migration).
build-media:
	@echo "Error: Go layer has been removed in the full-elixir-stack migration. See docs/stories/full-elixir-stack/go-removal-cleanup.md" && exit 1

## build-server: Compile the Elixir/OTP server inside container (mix compile — does NOT rebuild the Docker image)
build-server:
	$(DOCKER_ELIXIR) sh -c "cd server && mix local.hex --force && mix deps.get && mix compile"

## redeploy: Rebuild the server Docker image (via docker compose) and restart the container.
## Use this after committing code changes — make build-server does NOT update the image used
## by docker compose. Always use --no-cache to avoid stale layer reuse.
## go-removal-cleanup (full-elixir-stack): the server is now the only application image — it serves
## Matrix, /_matrix/media, and the admin UI. Build args carry real version metadata.
redeploy:
	GIT_COMMIT=$$(git rev-parse --short HEAD) \
	BUILD_TIME=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
	RELEASE_VERSION=$$(git describe --tags --always 2>/dev/null || echo dev) \
	docker compose build --no-cache server
	docker compose up -d --force-recreate server

## release: Build the versioned release image locally (TAG=vN.N.N required).
## go-removal-cleanup (full-elixir-stack): only the server image is built now — it serves
## Matrix, /_matrix/media, and the admin UI. Image is tagged $(CI_REGISTRY_IMAGE)/nebu-server:<version>.
## Use docker login registry.gitlab.com before pushing. Chain with release-push:
##   TAG=v1.0.0 make release release-push
release:
ifndef TAG
	$(error TAG is required. Usage: TAG=v1.0.0 make release)
endif
ifeq ($(strip $(TAG)),)
	$(error TAG is required. Usage: TAG=v1.0.0 make release)
endif
	@echo "$(TAG)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' || \
		(echo "ERROR: TAG must match vN.N.N (e.g. v1.0.0). Got: $(TAG)" && exit 1)
	docker build \
		--build-arg GIT_COMMIT=$$(git rev-parse --short HEAD) \
		--build-arg BUILD_TIME=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
		--build-arg RELEASE_VERSION=$(IMAGE_VERSION) \
		-t $(CI_REGISTRY_IMAGE)/nebu-server:$(IMAGE_VERSION) \
		./server

## release-push: Push the versioned release image to the registry (TAG=vN.N.N required).
## Run after `make release TAG=vN.N.N`. Requires docker login registry.gitlab.com.
## go-removal-cleanup (full-elixir-stack): pushes only the nebu-server image.
release-push:
ifndef TAG
	$(error TAG is required. Usage: TAG=v1.0.0 make release-push)
endif
ifeq ($(strip $(TAG)),)
	$(error TAG is required. Usage: TAG=v1.0.0 make release-push)
endif
	docker push $(CI_REGISTRY_IMAGE)/nebu-server:$(IMAGE_VERSION)

## dev: Start the full local development stack (server, postgres, dex, minio)
dev:
	docker compose up

## dev-reset-db: Drop and recreate the nebu database, then restart the server so migrations re-run.
## go-removal-cleanup (full-elixir-stack): the server now runs migrations on startup and serves health.
## WARNING: This destroys ALL data in the local database. Use only in development.
## Usage: make dev-reset-db
dev-reset-db:
	@echo "Stopping all containers and removing volumes (this destroys all local DB data)..."
	docker compose down --volumes
	@echo "Starting postgres first to ensure roles are provisioned..."
	docker compose up -d postgres
	@echo "Waiting for postgres to be ready..."
	@until docker compose exec -T postgres pg_isready -U postgres -q; do sleep 1; done
	@echo "Starting all services (the server will run migrations on startup)..."
	docker compose up -d
	@echo "Waiting for the server to be healthy (max 120s)..."
	@_retries=0; until docker compose exec -T server curl -fs http://localhost:4000/health >/dev/null 2>&1; do \
		_retries=$$((_retries+1)); \
		if [ "$$_retries" -ge 60 ]; then echo "ERROR: server did not become healthy after 120s"; exit 1; fi; \
		sleep 2; \
	done
	@echo "dev-reset-db complete. Run 'docker compose logs server' to verify migrations ran cleanly."

## setup: First-time setup — generate .secrets/internal_secret, MinIO credentials, and dev credentials
setup:
	@mkdir -p .secrets
	@if [ ! -f .secrets/internal_secret ]; then \
		openssl rand -hex 32 > .secrets/internal_secret; \
		echo "Generated .secrets/internal_secret"; \
	else \
		echo ".secrets/internal_secret already exists, skipping"; \
	fi
	@if [ ! -f .secrets/minio_root_user ]; then \
		openssl rand -hex 16 > .secrets/minio_root_user; \
		echo "Generated .secrets/minio_root_user"; \
	else \
		echo ".secrets/minio_root_user already exists, skipping"; \
	fi
	@if [ ! -f .secrets/minio_root_password ]; then \
		openssl rand -hex 16 > .secrets/minio_root_password; \
		echo "Generated .secrets/minio_root_password"; \
	else \
		echo ".secrets/minio_root_password already exists, skipping"; \
	fi
	@if [ ! -f .secrets/minio_app_access_key ]; then \
		openssl rand -hex 16 > .secrets/minio_app_access_key; \
		echo "Generated .secrets/minio_app_access_key"; \
	else \
		echo ".secrets/minio_app_access_key already exists, skipping"; \
	fi
	@if [ ! -f .secrets/minio_app_secret_key ]; then \
		openssl rand -hex 16 > .secrets/minio_app_secret_key; \
		echo "Generated .secrets/minio_app_secret_key"; \
	else \
		echo ".secrets/minio_app_secret_key already exists, skipping"; \
	fi
	@echo ""
	@echo "WARNING: MinIO credentials in .secrets/ are for LOCAL DEVELOPMENT only."
	@echo "Replace before first production start."
	@echo ""
	@echo "Dev credentials (Dex local users):"
	@echo "  kai@example.com        / changeme  (instance_admin)"
	@echo "  compliance@example.com / changeme  (compliance_officer)"
	@echo "  alex@example.com       / changeme  (user)"

## test-unit-go: REMOVED — the Go layer no longer exists (full-elixir-stack migration).
test-unit-go:
	@echo "Error: Go layer has been removed in the full-elixir-stack migration. See docs/stories/full-elixir-stack/go-removal-cleanup.md" && exit 1

## test-unit-elixir: Run Elixir unit tests inside container
test-unit-elixir:
	$(DOCKER_ELIXIR) sh -c "cd server && mix local.hex --force && mix deps.get && mix test --warnings-as-errors"

## test-integration: Run full stack integration tests against the live Elixir stack.
## go-removal-cleanup (full-elixir-stack): the Go integration runner was removed — the server
## now serves the public Matrix endpoint (server:8008) and admin (server:4000). The Elixir
## integration tests (mix test --include integration) run against the live stack.
test-integration: setup
	NEBU_RATE_LIMIT_DISABLED=true docker compose up -d --wait && \
	docker run --rm -v $(PWD):/workspace -w /workspace \
		--network=nebu_default \
		-e NEBU_DB_URL=postgresql://nebu_app:nebu_app_dev_pw@postgres:5432/nebu \
		-e NEBU_TEST_MATRIX_URL=http://server:8008 \
		-e NEBU_TEST_SERVER_URL=http://server:4000 \
		-e NEBU_TEST_DEX_URL=http://dex:5556 \
		elixir:1.19-alpine \
		sh -c "cd server && mix local.hex --force && mix deps.get && mix test --include integration --warnings-as-errors"; \
	ELIXIR_EXIT=$$?; \
	docker compose down; \
	exit $$ELIXIR_EXIT

## test-integration-elixir: Run Elixir integration tests only (mix test --include integration).
## Requires the full stack to be running (docker compose up -d --wait).
## Connects to the nebu_default network to reach PostgreSQL at postgres:5432.
test-integration-elixir: setup
	docker compose up -d --wait && \
	docker run --rm -v $(PWD):/workspace -w /workspace \
		--network=nebu_default \
		-e NEBU_DB_URL=postgresql://nebu_app:nebu_app_dev_pw@postgres:5432/nebu \
		elixir:1.19-alpine \
		sh -c "cd server && mix local.hex --force && mix deps.get && mix test --include integration --warnings-as-errors"; \
	EXIT=$$?; docker compose down; exit $$EXIT

## test-integration-ci: Run full stack integration tests using pre-built registry images (CI only).
## Requires CI_REGISTRY_IMAGE and CI_COMMIT_SHA to be set (injected automatically by GitLab CI).
## The caller must run `docker login` before invoking this target.
## go-removal-cleanup (full-elixir-stack): runs the Elixir integration tests against the server
## (server:8008 Matrix, server:4000 admin) — the Go integration runner was removed.
test-integration-ci: setup
	docker compose -f docker-compose.yml -f docker-compose.ci.yml up -d --wait --no-build && \
	docker run --rm -v $(PWD):/workspace -w /workspace \
		--network=nebu_default \
		-e NEBU_DB_URL=postgresql://nebu_app:nebu_app_dev_pw@postgres:5432/nebu \
		-e NEBU_TEST_MATRIX_URL=http://server:8008 \
		-e NEBU_TEST_SERVER_URL=http://server:4000 \
		-e NEBU_TEST_DEX_URL=http://dex:5556 \
		elixir:1.19-alpine \
		sh -c "cd server && mix local.hex --force && mix deps.get && mix test --include integration --warnings-as-errors"; \
	EXIT=$$?; docker compose -f docker-compose.yml -f docker-compose.ci.yml down; exit $$EXIT

## test-matrix-compat: Matrix SDK compatibility smoke test (optional CI gate — not part of test-integration)
## Validates that a real matrix-js-sdk client can connect, create a room, send a message, and
## receive it back via the room timeline. Requires the full stack to be running (docker compose up -d --wait).
test-matrix-compat:
	docker compose up -d --wait && \
	docker run --rm -v $(PWD):/workspace -w /workspace/tests/matrix_compat \
		--network=nebu_default \
		-e NEBU_MATRIX_URL=http://server:8008 \
		-e NEBU_DEX_URL=http://dex:5556 \
		node:22-alpine \
		sh -c "npm ci && node smoke_test.js"

## test-load-silber: Silber-Tier load test — 500 concurrent VUs via k6 (optional gate — not part of test-integration)
## Requires: running stack (docker compose up -d --wait called automatically)
## Override: NEBU_LOAD_TARGET_URL=http://my-host:8008 make test-load-silber
test-load-silber:
	docker compose up -d --wait && \
	docker run --rm -v $(PWD)/tests/load:/scripts \
		--network=nebu_default \
		-e NEBU_LOAD_TARGET_URL=$${NEBU_LOAD_TARGET_URL:-http://server:8008} \
		-e NEBU_DEX_URL=$${NEBU_DEX_URL:-http://dex:5556} \
		grafana/k6:0.50.0 run /scripts/k6_chat.js

## test-e2e: Run all Playwright E2E tests (BDD + legacy) against a running stack.
## Requires: 127.0.0.1 dex in /etc/hosts for OIDC redirect flows
## Story 9-26 AC5: runs bddgen first, then all projects including element-web + admin-ui.
## Reset DB to bootstrap state first:
##   docker compose exec postgres psql -U nebu -d nebu -c \
##     "DELETE FROM server_config WHERE key IN ('bootstrap_completed','oidc_issuer','oidc_client_id','oidc_client_secret','instance_name');"
test-e2e:
	cd e2e && \
	npm install --silent && \
	npx playwright install chromium --with-deps && \
	npx bddgen && \
	npx playwright test --reporter=list

## build-element-e2e: Build the Element Web E2E Docker image (uses official vectorim/element-web)
## Fast build (~5s) — no Rust/Flutter compilation required.
build-element-e2e:
	docker build -t nebu-element-e2e:dev -f docker/Dockerfile.element-e2e .

## test-e2e-element: Run Element Web Browser-First BDD tests (story 9-26, Phase 2).
## Story 9-26 AC5: canonical target name (also aliased as test-e2e-element-bdd).
## Requires: stack running (`make dev`) + `127.0.0.1 dex` in /etc/hosts
test-e2e-element:
	cd e2e && npm install --silent && \
	npx playwright install chromium --with-deps && \
	npx bddgen && \
	npx playwright test --project=element-web --reporter=list

## test-e2e-element-legacy: Run old Element Web E2E tests (non-BDD, pre-story-9-26).
## Requires: stack running + element sidecar via --profile e2e.
test-e2e-element-legacy:
	docker compose --profile e2e up -d --wait && \
	cd e2e && npm install --silent && \
	npx playwright install chromium --with-deps && \
	npx playwright test tests/element_e2e.spec.ts; \
	EXIT=$$?; exit $$EXIT

## test-e2e-admin: Run Admin UI BDD tests (story 9-26, Phase 3).
## Story 9-26 AC5: canonical target name (also aliased as test-e2e-admin-bdd).
## Requires: playwright-bdd installed + stack running
test-e2e-admin:
	cd e2e && npm install --silent && \
	npx playwright install chromium --with-deps && \
	npx bddgen && \
	npx playwright test --project=admin-ui --reporter=list

## test-e2e-refresh: Run the @short-ttl OIDC session-refresh scenarios (story
## e2e-session-refresh-suites) against a DEDICATED short-session-TTL stack. These cannot run
## in the shared 8h stack (admin past-lifetime, Matrix survives-past-lifetime). The target:
##   1. recreates the server with short NEBU_*_SESSION_TTL_SECONDS,
##   2. sets admin_oidc_refresh_mode=offline (Dex issues a refresh token only with
##      offline_access — required for the admin silent refresh),
##   3. runs ONLY @short-ttl scenarios (NEBU_E2E_TAGS) across element-web + admin-ui.
## Requires: stack up (`make dev`) + a server image with the refresh code (`make redeploy`)
## + `127.0.0.1 dex` in /etc/hosts. Tune the TTL via NEBU_E2E_TTL (default 30s).
NEBU_E2E_TTL ?= 30
test-e2e-refresh:
	NEBU_MATRIX_SESSION_TTL_SECONDS=$(NEBU_E2E_TTL) \
	NEBU_ADMIN_SESSION_TTL_SECONDS=$(NEBU_E2E_TTL) \
	  docker compose up -d --no-deps --force-recreate server
	docker compose exec -T postgres psql -U nebu -d nebu -c \
	  "INSERT INTO server_config (key, value, set_at) VALUES ('admin_oidc_refresh_mode','offline',(EXTRACT(EPOCH FROM NOW())*1000)::bigint) ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, set_at=EXCLUDED.set_at;"
	cd e2e && npm install --silent && \
	  npx playwright install chromium --with-deps && \
	  NEBU_E2E_TAGS='@short-ttl and not @pending-feature' \
	  NEBU_MATRIX_SESSION_TTL_SECONDS=$(NEBU_E2E_TTL) \
	  NEBU_ADMIN_SESSION_TTL_SECONDS=$(NEBU_E2E_TTL) \
	  npx bddgen && \
	  NEBU_E2E_TAGS='@short-ttl and not @pending-feature' \
	  NEBU_MATRIX_SESSION_TTL_SECONDS=$(NEBU_E2E_TTL) \
	  NEBU_ADMIN_SESSION_TTL_SECONDS=$(NEBU_E2E_TTL) \
	  npx playwright test --reporter=list

## build-fluffychat-e2e: Build the FluffyChat Web E2E Docker image (Flutter multi-stage — slow first build)
## Requires: tmp/fluffychat/ to contain the FluffyChat source checkout.
build-fluffychat-e2e:
	docker build -t nebu-fluffychat-e2e:dev -f docker/Dockerfile.fluffychat-e2e .

## test-e2e-fluffychat: Run Playwright E2E tests against FluffyChat Web (real Matrix client)
## Requires: 127.0.0.1 dex in /etc/hosts (for SSO redirect via Dex)
## Starts full stack + fluffychat sidecar via --profile e2e.
## Does NOT run docker compose down after tests — leaves stack for debugging.
test-e2e-fluffychat:
	docker compose --profile e2e up -d --wait && \
	cd e2e && npm install --silent && \
	npx playwright install chromium --with-deps && \
	npx playwright test tests/fluffychat_e2e.spec.ts; \
	EXIT=$$?; exit $$EXIT

## test-e2e-element-bdd: Alias for test-e2e-element (story 9-26 AC5 compatibility).
test-e2e-element-bdd: test-e2e-element

## test-e2e-admin-bdd: Alias for test-e2e-admin (story 9-26 AC5 compatibility).
test-e2e-admin-bdd: test-e2e-admin

## test-e2e-all: Alias for test-e2e (runs all BDD + legacy tests).
test-e2e-all: test-e2e

## test-compose-ports: CI smoke test — assert that port 9000 is NOT published by the server service.
## Story 5.29a AC8: gRPC port must not be bound to the host.
## Fallback for CI runners where the Go integration test cannot use Docker SDK.
test-compose-ports:
	@echo "Checking that the server service does NOT publish port 9000 to the host..."
	@if docker compose config --format json 2>/dev/null | python3 -c \
		"import json,sys; cfg=json.load(sys.stdin); ports=cfg.get('services',{}).get('server',{}).get('ports',[]); \
		bound=[p for p in ports if str(p.get('target',''))==str(9000) and str(p.get('published','')) not in ('','0')]; \
		sys.exit(1) if bound else print('PASS: port 9000 not published on host')"; then \
		true; \
	else \
		echo "FAIL: server service still publishes port 9000 to the host. Remove '- \"9000:9000\"' from docker-compose.yml."; \
		exit 1; \
	fi

## test-compose-minio: CI smoke test — assert that MinIO service and secrets are configured correctly.
## Story 12.1 AC1+AC2: verifies minio service exists with minio_root_user + minio_root_password secrets.
## Story 12.3 AC2+AC3: verifies nebu-app IAM credentials present; createbuckets does NOT set public bucket policy.
test-compose-minio:
	@echo "Checking MinIO service configuration in docker-compose.yml..."
	@docker compose config --format json 2>/dev/null | python3 -c "\
	import json,sys; cfg=json.load(sys.stdin); \
	svc=cfg.get('services',{}); \
	assert 'minio' in svc, 'FAIL: minio service missing from docker-compose.yml'; \
	secrets=cfg.get('secrets',{}); \
	assert 'minio_root_user' in secrets, 'FAIL: minio_root_user secret missing from docker-compose.yml'; \
	assert 'minio_root_password' in secrets, 'FAIL: minio_root_password secret missing from docker-compose.yml'; \
	assert 'minio_app_access_key' in secrets, 'FAIL: minio_app_access_key secret missing (Story 12.3 AC2)'; \
	assert 'minio_app_secret_key' in secrets, 'FAIL: minio_app_secret_key secret missing (Story 12.3 AC2)'; \
	ports=svc.get('minio',{}).get('ports',[]); \
	targets=[str(p.get('target','')) for p in ports if isinstance(p,dict)]; \
	assert '9000' in targets, 'FAIL: MinIO S3 API port 9000 not published'; \
	assert '9001' in targets, 'FAIL: MinIO Console port 9001 not published'; \
	cb_ep=svc.get('createbuckets',{}).get('entrypoint',''); \
	ep_str=cb_ep if isinstance(cb_ep,str) else ' '.join(cb_ep); \
	assert 'mc anonymous set' not in ep_str, 'FAIL: createbuckets entrypoint must NOT set public bucket policy (Story 12.3 AC3)'; \
	print('PASS: MinIO service+secrets+IAM configured correctly; no public bucket policy (ports 9000+9001 published)')"

# proto: REMOVED — grpc-removal (ADR-021). The gRPC/protobuf stack was removed; the
# former Core.* protobuf DTOs are now hand-maintained plain Elixir structs in
# server/lib/pb/core.pb.ex (no protoc generation). proto/core.proto is kept only as a
# historical reference of the former wire contract — it is no longer generated from.

## assets: Build the Admin UI stylesheet (Tailwind + DaisyUI, "nebu"/Obsidian theme) into
## server/priv/static/assets/app.css. Runs in a Node container — no local npm required.
## Run after changing the admin LiveView templates or server/assets/{tailwind.config.js,css/app.css}.
## (The server Docker image rebuilds this automatically via its `assets` stage.)
assets:
	docker run --rm -v $(PWD):/workspace -w /workspace/server/assets node:20-alpine \
		sh -c "npm ci --no-audit --no-fund && npm run build"

## gen-api: REMOVED — Go server stub generation is obsolete (full-elixir-stack migration).
gen-api:
	@echo "Error: Go layer has been removed in the full-elixir-stack migration. See docs/stories/full-elixir-stack/go-removal-cleanup.md" && exit 1

## test-iac-validate: Validate OpenTofu IaC files + Helm chart + k6 load test syntax.
## Runs tofu fmt -check (formatting) and tofu validate (syntax/types) for all example directories.
## Also runs helm lint and helm template on deploy/helm/nebu/ (Story 13-4a AC1+AC2, Story 13-4b AC3+AC5).
## If kubectl is available, runs helm template | kubectl apply --dry-run=client (Story 13-4c AC2).
## Also runs k6 inspect on load test scenarios and validates docker-compose.scale.yml (Story 13-5 AC1+AC3+AC4).
## No cloud credentials required — tofu validate checks syntax only, not provider resources.
## Story 13-1 AC3 + AC7, Story 13-4a AC1 + AC2, Story 13-4b AC3 + AC5, Story 13-4c AC3, Story 13-5 AC1+AC3+AC4: equivalent to the validate-iac CI job.
test-iac-validate: test-load-syntax
	@echo "==> OpenTofu: fmt check (recursive)"
	$(DOCKER_TOFU) -c "tofu fmt -check -recursive deploy/tofu/"
	@echo "==> OpenTofu: validate deploy/tofu/examples/aws"
	$(DOCKER_TOFU) -c "cd deploy/tofu/examples/aws && tofu init -backend=false && tofu validate"
	@echo "==> OpenTofu: validate deploy/tofu/examples/stackit"
	$(DOCKER_TOFU) -c "cd deploy/tofu/examples/stackit && tofu init -backend=false && tofu validate"
	@echo "==> OpenTofu: validate deploy/tofu/examples/k8s"
	$(DOCKER_TOFU) -c "cd deploy/tofu/examples/k8s && tofu init -backend=false && tofu validate"
	@echo "==> Helm: lint deploy/helm/nebu/"
	$(DOCKER_HELM) -c "helm lint deploy/helm/nebu/"
	@echo "==> Helm: template render check deploy/helm/nebu/ (default values)"
	$(DOCKER_HELM) -c "helm template nebu deploy/helm/nebu/ --set server.image.tag=validate > /dev/null"
	@echo "==> Helm: template render check deploy/helm/nebu/ (ingress + HPA enabled)"
	$(DOCKER_HELM) -c "helm template nebu deploy/helm/nebu/ --set server.image.tag=validate --set ingress.enabled=true --set ingress.hostname=nebu.example.com --set autoscaling.server.enabled=true > /dev/null"
	@if command -v kubectl >/dev/null 2>&1 && kubectl get nodes -o name >/dev/null 2>&1; then \
		echo "==> Helm: template dry-run: renders chart and validates against k8s API schema (requires kubectl in PATH)"; \
		$(DOCKER_HELM) -c "helm template nebu deploy/helm/nebu/ \
			-f deploy/helm/nebu/values-dev.yaml \
			--set server.image.tag=validate" \
			| kubectl apply --dry-run=client -f -; \
	else \
		echo "==> Helm: no reachable cluster — skipping kubectl dry-run (run against a live kind cluster to enable)"; \
	fi
	@echo "==> IaC validation passed."

## test-load-syntax: Validate k6 load test scenario syntax and docker-compose.scale.yml config.
## Uses Docker-based k6 (no local k6 installation required).
## Story 13-5 AC1+AC3+AC4: syntax gate for gold-tier.js, silver-tier.js, and compose scale override.
## Runs: k6 inspect (syntax-only, no network, no VUs started) + docker compose config --quiet.
test-load-syntax:
	@echo "==> k6: inspect k6/scenarios/gold-tier.js"
	docker run --rm -v $(PWD)/k6:/scripts grafana/k6:0.55.0 inspect /scripts/scenarios/gold-tier.js
	@echo "==> k6: inspect k6/scenarios/silver-tier.js"
	docker run --rm -v $(PWD)/k6:/scripts grafana/k6:0.55.0 inspect /scripts/scenarios/silver-tier.js
	@echo "==> Docker Compose: validate scale override config"
	docker compose -f docker-compose.yml -f docker-compose.scale.yml config --quiet
	@echo "==> Load test syntax validation passed."
