---
title: "PostgreSQL SSL CA Certificate Support for UpCloud Managed Database"
status: in-progress
epic: upcloud-deployment
slug: postgres-ssl-ca-cert
security_review: required
---

## Story

**As an** operator deploying Nebu on UpCloud,
**I want** the Nebu server to successfully establish an encrypted connection to the UpCloud managed PostgreSQL database,
**so that** the database is reachable at startup without "Unknown CA" TLS errors.

## Background

UpCloud managed PostgreSQL (Aiven-backed) uses a private CA that is not in the system trust store.
Previously, `NEBU_POSTGRES_SSL=true` passed `ssl: true` to Postgrex, which triggers Erlang TLS's
default `verify_peer` mode — causing a fatal `Unknown CA` error at connection time.

The fix has two parts:

1. **Elixir (`release.ex` + `runtime.exs`)**: When `NEBU_POSTGRES_CA_CERT_FILE` env var is set,
   pass `[verify: :verify_peer, cacertfile: path]` to Postgrex. Without the env var (but SSL
   enabled), fall back to `[verify: :verify_none]` — the connection is encrypted but the server
   certificate is not validated against a CA. This is equivalent to PostgreSQL's `sslmode=require`.

2. **Infrastructure (`cloud-init.tftpl` + `server.tf`)**: UpCloud VMs can reach the private DB host
   via SDN at boot time. A `runcmd` block (conditional on `fetch_postgres_ca = true`) extracts the
   full TLS certificate chain from the DB host using `openssl s_client -showcerts`, saves it to
   `/opt/nebu/postgres-ca.pem`, and appends `NEBU_POSTGRES_CA_CERT_FILE=/opt/nebu/postgres-ca.pem`
   to the container's `.env` before the Nebu service starts.

## Acceptance Criteria

AC-1: `postgres_ssl_opts/0` returns `[ssl: false]` when `NEBU_POSTGRES_SSL` is not set or is `"false"`.

AC-2: `postgres_ssl_opts/0` returns `[ssl: [verify: :verify_none]]` when `NEBU_POSTGRES_SSL=true`
and `NEBU_POSTGRES_CA_CERT_FILE` is not set.

AC-3: `postgres_ssl_opts/0` returns `[ssl: [verify: :verify_peer, cacertfile: ~c"/path/to/ca.pem"]]`
when `NEBU_POSTGRES_SSL=true` and `NEBU_POSTGRES_CA_CERT_FILE=/path/to/ca.pem` is set.

AC-4: The `runtime.exs` Ecto Repo config mirrors the same three-way logic: `false`, `verify_none`,
or `verify_peer` with `cacertfile`.

AC-5 (infra, non-automatable): When deployed on UpCloud with `fetch_postgres_ca = true`, the VM
boot log contains `[nebu-bootstrap] PostgreSQL CA cert saved` and
`/opt/nebu/postgres-ca.pem` exists before `nebu.service` starts.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. `postgres_ssl_opts/0 — SSL disabled` — ExUnit unit test
   - Given: `NEBU_POSTGRES_SSL` not set (or `"false"`)
   - When: `Nebu.Release.postgres_ssl_opts()` is called
   - Then: returns `[ssl: false]`

2. `postgres_ssl_opts/0 — SSL enabled, no CA cert` — ExUnit unit test
   - Given: `NEBU_POSTGRES_SSL=true`, `NEBU_POSTGRES_CA_CERT_FILE` not set
   - When: `Nebu.Release.postgres_ssl_opts()` is called
   - Then: returns `[ssl: [verify: :verify_none]]`

3. `postgres_ssl_opts/0 — SSL enabled with CA cert file` — ExUnit unit test
   - Given: `NEBU_POSTGRES_SSL=true`, `NEBU_POSTGRES_CA_CERT_FILE=/opt/nebu/postgres-ca.pem`
   - When: `Nebu.Release.postgres_ssl_opts()` is called
   - Then: returns `[ssl: [verify: :verify_peer, cacertfile: ~c"/opt/nebu/postgres-ca.pem"]]`

## Dev Notes

- `postgres_ssl_opts/0` is called from `Nebu.Release.run_migrations/0` and the
  `Nebu.Release.start_repo/0` helper. The `runtime.exs` change affects the Repo started by
  the Elixir application supervisor at runtime.
- `to_charlist/1` is used for the `cacertfile` path because Erlang SSL expects a charlist, not
  a binary string.
- The cloud-init extraction uses `sed` to grab all `BEGIN/END CERTIFICATE` blocks from
  `openssl s_client -showcerts`. All certs in the chain are written to the file; Erlang TLS
  uses whichever one is the trust anchor.
- StackIT PostgresFlex uses a Let's Encrypt certificate (globally trusted) — `fetch_postgres_ca`
  is `false` there and the existing behavior (`verify_none` fallback) is adequate.
- AC-5 cannot be automated in ExUnit — it requires a live UpCloud deployment. Covered by the
  operator running `tofu apply` and checking the cloud-init log via `journalctl -u cloud-init`.

## Files Changed

- `server/lib/nebu/release.ex` — `postgres_ssl_opts/0` rewritten
- `server/config/runtime.exs` — Ecto Repo ssl config updated
- `deploy/tofu/examples/stackit/cloud-init.tftpl` — `fetch_postgres_ca` conditional added
- `deploy/tofu/examples/upcloud/server.tf` — `fetch_postgres_ca = true`
- `deploy/tofu/examples/stackit/server.tf` — `fetch_postgres_ca = false`
