---
title: "Getting Started"
---

# Getting Started with Nebu

This guide walks you through setting up a local Nebu development environment from scratch.

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| Docker Desktop | 4.x+ | Runs all services in containers |
| `make` | Any | Runs dev targets |
| `git` | Any | Clone the repository |

**No local Elixir or buf installation is needed.** All builds run inside Docker containers.

---

## 1. Clone and Initial Setup

```bash
git clone <your-fork-url> nebu
cd nebu
make setup
```

`make setup` does two things:
- Generates `.secrets/internal_secret` (32-byte random hex, the PSK for node registration) if absent
- Prints the dev OIDC credentials (Dex local users, see step 4 below)

The `.secrets/` directory is in `.gitignore` - never commit it. If you need a custom
`POSTGRES_PASSWORD`, copy `.env.example` to `.env` manually before `make dev`.

---

## 2. Start the Stack

```bash
make dev
```

This runs `docker compose up` and starts:

| Service | URL | Purpose |
|---|---|---|
| Nebu (Matrix API + Admin UI) | http://localhost:8008 | Main endpoint for clients |
| Dex (OIDC provider) | http://localhost:5556 | Dev identity provider |
| PostgreSQL | localhost:5432 | Database (user: `nebu`, db: `nebu`) |
| MinIO | http://localhost:9001 | S3-compatible media storage (dev) |

Wait until you see `Nebu.Application started` in the server logs:

```bash
docker compose logs -f server
```

---

## 3. /etc/hosts Setup (One-Time)

Dex (the development OIDC provider) must be reachable as `dex` in your browser for the OIDC
redirect to work correctly:

```bash
sudo sh -c 'echo "127.0.0.1 dex" >> /etc/hosts'
```

You only need to do this once.

---

## 4. Bootstrap Wizard

Open http://localhost:8080/admin in your browser.

If this is a fresh installation (empty database), you will be redirected to the Bootstrap Wizard.
Complete the following steps:

**Step 1 - Server Name:**
Enter a server name (e.g., `localhost`). This becomes part of all Matrix user IDs
(`@user:localhost`). It cannot be changed after setup without a full data migration.

**Step 2 - OIDC Provider:**
Enter the development Dex configuration:

| Field | Value |
|---|---|
| OIDC Issuer | `http://dex:5556/dex` |
| Client ID | `nebu-admin` |
| Client Secret | `nebu-admin-secret` |
| Role Claim Name | `nebu_role` |

**Step 3 - First Login:**
You will be redirected to Dex. Log in with one of the pre-configured dev users:

| Email | Password | Role |
|---|---|---|
| `kai@example.com` | `changeme` | `instance_admin` |
| `compliance@example.com` | `changeme` | `compliance_officer` |
| `alex@example.com` | `changeme` | `user` |

Log in as `kai@example.com` for the first admin setup.

After login, you will be redirected to the Admin Dashboard. Bootstrap mode is now permanently
disabled.

---

## 5. Connect a Matrix Client

### Element Web

1. Open https://app.element.io (or a self-hosted instance)
2. Click **Sign In** → **Edit** (to change server)
3. Under "Other homeserver", enter: `http://localhost:8008`
4. Click **Continue** → you will be redirected to Dex for SSO login
5. Log in with `alex@example.com` / `changeme`

You are now connected as a Matrix user on your local Nebu instance.

**Create a test room:** Click the `+` next to "Rooms" → give it a name → Create.

**Test messaging:** You can log in with a second account in a separate browser profile or incognito
window and join the same room.

---

## 6. Common make Targets

| Target | Description |
|---|---|
| `make setup` | Generate secrets and dev credentials (run once, then again after `make clean`) |
| `make dev` | Start full stack via docker compose |
| `make test-unit-elixir` | Run Elixir unit tests in container |
| `make test-integration` | Full stack + Playwright/Gherkin integration tests |
| `make build-server` | Compile Elixir app inside the build container (`mix compile`) |
| `make redeploy` | Rebuild the `server` Docker image and recreate the container |

---

## 7. Troubleshooting

### "Server not ready" or 502 errors on first start

**Cause:** The Elixir server takes ~30s to start (OTP release compilation + DB migrations).

**Fix:** Wait for the server health check to pass:
```bash
docker compose logs -f server | grep "Nebu.Application started"
```

---

### "dex: connection refused" during OIDC login

**Cause:** Missing `/etc/hosts` entry for `dex`.

**Fix:**
```bash
sudo sh -c 'echo "127.0.0.1 dex" >> /etc/hosts'
```
Then retry. If you are in a corporate VPN, the VPN may intercept DNS - disable VPN for local dev.

---

### Bootstrap Wizard does not appear; I see a login page

**Cause:** The database already has a `bootstrap_active=false` entry (previous setup).

**Fix:** Reset the database:
```bash
docker compose down -v   # removes volumes
make setup               # regenerate secrets
make dev
```

---

### "Unable to set up keys" or E2EE warnings in Element

**Expected behavior.** Nebu does not implement E2EE. The `keys/upload` and `keys/device_signing/upload`
endpoints return stubs that silence the dialog. If you see the dialog, try refreshing the page.
The UIA flow (m.login.dummy) should dismiss it automatically.

---


### PostgreSQL migration fails on startup

**Cause:** Database schema version mismatch (downgrade attempted, or `.secrets/` was regenerated
without clearing the database).

**Fix:**
```bash
docker compose down -v
make setup
make dev
```

_Source: `README.md`, §Quick Start; `CLAUDE.md`, §Commands; `_bmad-output/planning-artifacts/architecture.md`, §Build-Container-Strategie_
