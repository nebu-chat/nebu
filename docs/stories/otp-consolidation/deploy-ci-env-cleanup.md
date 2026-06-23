---
story_id: deploy-ci-env-cleanup
title: "Deployment & CI Env Cleanup — Drop Gateway/gRPC-era ENV across all deploy options"
epic: otp-consolidation
status: done
security_review: required
created: 2026-06-17
branch: feature/otp-consolidation
---

## Summary

The Go gateway/media removal (ADR-021) + single-OTP-app consolidation reduced the
runtime ENV contract. Several env vars set by the deploy options and GitLab CI are no
longer read by the Elixir app. This story aligns **all deploy options** (docker-compose,
OpenTofu AWS/Stackit, Helm/K8s) and `.gitlab-ci.yml` with the actual live contract.

## Live ENV contract (what `core` actually reads — source of truth)

`grep System.get_env core/lib core/config`: admin OIDC (`NEBU_ADMIN_OIDC_CLIENT_ID|SECRET|_FILE|REDIRECT_URI|SCOPE`, `NEBU_ADMIN_SECRET_KEY_BASE`), Matrix OIDC (`NEBU_OIDC_ISSUER|AUDIENCE|JWKS_URI|JWKS_TTL|DISPLAY_NAME|CLIENT_ID`), DB (`NEBU_DB_URL`, `NEBU_DB_URL_MIGRATE`), MinIO (`NEBU_MINIO_*`), `NEBU_PII_ENCRYPTION_KEY`, `NEBU_INTERNAL_SECRET(_FILE)`, `NEBU_SERVER_NAME`, `NEBU_HTTP_PORT`, `NEBU_RATE_LIMIT_DISABLED`, clustering (`CLUSTER_STRATEGY`, `KUBERNETES_*`, `RELEASE_*`), build meta (`GIT_COMMIT`, `BUILD_TIME`, `RELEASE_VERSION`).

## Obsolete vars to remove (NOT in the live contract)

| Var | Why obsolete |
|---|---|
| `NEBU_CORE_GRPC_ADDR` | gateway→core gRPC address; no gateway, no inter-process gRPC |
| `NEBU_ENV` | not read by the Elixir app (Go-era flag) |
| `NEBU_KEY_ENCRYPTION_KEY` | not read (distinct from `NEBU_PII_ENCRYPTION_KEY`, which is read) |
| `NEBU_OIDC_EXTRA_SCOPES` | not read (admin uses `NEBU_ADMIN_OIDC_SCOPE`) |
| `NEBU_STORAGE_BACKEND` | not read (media selects backend via `NEBU_MINIO_*`) |
| `NEBU_TRUSTED_PROXY` | not read by the Elixir rate limiter (Go-era XFF gate) |
| `NEBU_OIDC_CLIENT_SECRET` | not read — the **admin** login reads `NEBU_ADMIN_OIDC_CLIENT_SECRET(_FILE)`. **Map, don't just drop:** where a deploy sets `NEBU_OIDC_CLIENT_SECRET` for admin login, rename it to `NEBU_ADMIN_OIDC_CLIENT_SECRET` (or `_FILE`) so admin OIDC keeps working. |

Keep: `NEBU_OIDC_CLIENT_ID` (read; admin client-id default), and everything in the live contract.

## Acceptance Criteria

1. **Given** `.gitlab-ci.yml`, **When** searched, **Then** no obsolete var above is set in any job/env block (CI test-stack env reflects the single core service).
2. **Given** `docker-compose.yml` and `docker-compose.scale.yml`, **When** searched, **Then** the `core` service env contains only live-contract vars; obsolete vars removed; `NEBU_OIDC_CLIENT_SECRET` mapped to `NEBU_ADMIN_OIDC_CLIENT_SECRET` if it was feeding admin login.
3. **Given** the OpenTofu options (`deploy/tofu/examples/{aws,stackit,k8s}`, `deploy/tofu/modules/*`), **When** searched, **Then** obsolete vars are removed from source `.tf`/`.tftpl`/`variables.tf` (and any now-orphaned `variable` declarations + their wiring). `terraform.tfstate` files are NOT hand-edited (generated state).
4. **Given** the Helm chart (`deploy/helm/nebu/`), **When** searched, **Then** `values*.yaml`, `configmap.yaml`, `secrets.yaml`, and `NOTES.txt` carry only live-contract vars; `NEBU_CORE_GRPC_ADDR` gone from the configmap; OIDC secret mapped correctly.
5. **Given** the admin OIDC login path, **When** a deploy is rendered, **Then** the client secret the app reads (`NEBU_ADMIN_OIDC_CLIENT_SECRET`/`_FILE`) is actually provided — i.e. removing `NEBU_OIDC_CLIENT_SECRET` did not orphan admin auth.
6. **Given** the repo, **When** `make build-core` + `make test-unit-elixir` run, **Then** still green (config-only change; no code regression).

## Acceptance Tests

Infra/config story — no ATDD (per the project gate). Verification by inspection + grep guard:
- `grep -rn "NEBU_CORE_GRPC_ADDR\|NEBU_ENV\|NEBU_KEY_ENCRYPTION_KEY\|NEBU_OIDC_EXTRA_SCOPES\|NEBU_STORAGE_BACKEND\|NEBU_TRUSTED_PROXY\|NEBU_OIDC_CLIENT_SECRET" deploy .gitlab-ci.yml docker-compose*.yml` returns only `terraform.tfstate` (generated) hits.
- Each deploy option still sets every live-contract var its platform needs (admin OIDC secret present).

## Implementation Notes

- Do NOT edit `*.tfstate` (generated; regenerated on `tofu apply`).
- Removing a tofu `variable` requires removing its declaration AND every reference (module input, tfvars example).
- `NEBU_INTERNAL_SECRET(_FILE)` stays — still used for the admin `secret_key_base` derivation and the at-rest key, independent of node registration.
