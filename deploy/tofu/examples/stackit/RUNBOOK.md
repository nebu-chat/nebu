# Nebu on Stackit — Operator Runbook

This runbook covers day-1 deploy and day-2 operations for Nebu hosted on a Stackit VM using Docker Compose, bootstrapped via cloud-init.

> **SECURITY WARNING — Terraform State:** The cloud-init `user_data` rendered by `templatefile()` — including all injected secrets — is stored in Terraform state. The PostgresFlex database password (`stackit_postgresflex_user.nebu.password`) is also stored in state. Always use an encrypted remote state backend (Stackit Object Storage with server-side encryption) in production. Never commit `.tfstate` files to version control. See the commented `backend "s3"` block in `main.tf` for the recommended configuration. To retrieve the database password after apply: `tofu output -json | jq` — note the password is intentionally not an output; read it from state via `tofu state show stackit_postgresflex_user.nebu`.

---

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.6
- A Stackit service account key JSON (download: STACKIT portal → IAM → Service Accounts → Keys)
- SSH key pair (the public key goes into `terraform.tfvars`)
- Values for all required variables in `terraform.tfvars` (copy from `terraform.tfvars.example`)
- Container image (`nebu-server`) pushed to your registry at the correct tag
  (go-removal-cleanup: server now serves public Matrix + media + admin — there is no
  separate `nebu-gateway` / `nebu-media` image)

---

## OIDC Profiles

Nebu on Stackit supports two OIDC deployment modes, configured via `oidc_mode` in `terraform.tfvars`.

### `oidc_mode = "dex"` — Bundled Dex (test/demo)

Deploys [Dex IdP](https://dexidp.io/) as a Docker Compose sidecar alongside Nebu. Dex uses a static YAML configuration — no database is required.

**When to use:** Development, demo, or integration test environments where you do not have an external OIDC provider.

**Traffic routing (dex mode):**

go-removal-cleanup: server binds host port 8008 (mapped to its container port 4000) and serves the public Matrix CS API + media + admin directly (same as external mode). The NLB targets port 8008 — no configuration change required between modes.

Dex is exposed on host port 5556 (plain HTTP). The SG rule `inbound_dex` is created conditionally in dex mode to allow browsers to follow OIDC redirects directly to port 5556.

Server performs OIDC discovery via a Docker hairpin: it calls `http://<server_name>:5556/dex/.well-known/openid-configuration` using the VM's public IP. Standard Linux SNAT/masquerade handles this routing correctly.

> **Note:** Host-based routing via nginx (`dex.<server_name>`) is a planned improvement for when TLS is configured. This will be implemented in a follow-up story.

**What gets deployed:**

```bash
sudo docker compose ps
# NAME     IMAGE                        STATUS
# dex      dexidp/dex:v2.45.1           Up (healthy)
# server   <registry>/nebu-server:...   Up (healthy)
```

The Dex config file is at `/opt/nebu/dex/config.yaml`. It contains a static OIDC client (`nebu-gateway`) and a static user (`operator@example.com` — in the `instance_admin` group).

> **Admin access:** The static Dex user is placed in the `instance_admin` group claim. For admin access to work, the Nebu Bootstrap Wizard must be configured with `admin_group_claim = "groups"` and the claim value `instance_admin`. Complete the Bootstrap Wizard after first deploy to enable admin login.

> **Security:** The `dex_static_password_hash` variable is required when using this mode. Generate a unique bcrypt hash with: `htpasswd -bnBC 12 '' 'yourpassword' | tr -d ':' | sed 's/$2y/$2a/'`. Never share or reuse password hashes across environments.

The OIDC issuer is automatically set to `http://<server_name>:5556/dex`. You do not need to set `oidc_issuer` in `terraform.tfvars` when using this mode.

> **Note on HTTP (not HTTPS) for Dex:** Dex runs on port 5556 with plain HTTP. **Dex mode is intended for test/demo environments only — not for production deployments where HTTPS for the IdP is required.**

To confirm Dex is reachable (port 5556, plain HTTP):

```bash
curl http://<server_name>:5556/dex/.well-known/openid-configuration
# Expected: {"issuer":"http://<server_name>:5556/dex", ...}
```

To confirm server is reachable on port 8008:

```bash
curl http://<server_name>:8008/_matrix/client/versions
# Expected: Matrix version list served by server
```

### `oidc_mode = "external"` — External OIDC Provider (production)

No bundled IdP is deployed. You must provide:

- `oidc_issuer` — the OIDC issuer URL of your external provider (Keycloak, Authentik, Azure AD, etc.)
- `oidc_client_secret` — the client secret issued to `nebu-gateway` by your provider

**When to use:** Production deployments where you already manage an OIDC provider or use a cloud IdP service.

Configure the external IdP client using the Nebu Bootstrap Wizard (step 3 — OIDC configuration), then copy the issued client secret into `terraform.tfvars` as `oidc_client_secret`.

---

## First Deploy

```bash
# 1. Initialise providers
tofu init

# 2. Preview changes
tofu plan -out=tfplan

# 3. Apply — provisions VM, networking, ALB, injects cloud-init
tofu apply tfplan
```

`tofu apply` outputs the floating IP:

```
floating_ip = "185.x.x.x"
```

---

## Checking VM Boot Status

After `tofu apply`, the VM boots and cloud-init runs in the background (typically 2–5 minutes).

```bash
# SSH to the VM (use your private key matching the public key in tfvars)
ssh ubuntu@<floating_ip>

# Check cloud-init progress
sudo cloud-init status --wait

# Once cloud-init reports 'done', check Nebu services
cd /opt/nebu
sudo docker compose ps
```

Expected output once healthy (`oidc_mode = "dex"`):

```
NAME       IMAGE                           STATUS
dex        dexidp/dex:v2.45.1              Up (healthy)
server     <registry>/nebu-server:<ver>    Up (healthy)
```

Expected output once healthy (`oidc_mode = "external"`):

```
NAME       IMAGE                           STATUS
server     <registry>/nebu-server:<ver>    Up (healthy)
```

> Note: the `postgres` container is no longer present — the database is now managed by Stackit PostgresFlex. Nebu services connect to the PostgresFlex instance directly via the private network.

If cloud-init fails, check the log:

```bash
sudo cat /var/log/cloud-init-output.log
```

---

## Smoke Test

Verify the Matrix API is reachable through the ALB:

```bash
curl https://<floating_ip>/_matrix/client/versions
```

Expected response:

```json
{"versions":["v1.1","v1.2","v1.3","v1.4","v1.5"]}
```

> Note: in `tls_mode = "none"` / `"acme"` the NLB uses TCP passthrough (`PROTOCOL_TCP`); in `tls_mode = "alb"` the Stackit ALB terminates TLS and forwards to the VM nginx proxy. In `oidc_mode = "dex"`, the Dex OIDC endpoint (`http://<server_name>:5556/dex/`) is plain HTTP — no TLS. go-removal-cleanup: the Matrix API on port 8008 is served directly by the server container (Bandit listener on container port 4000).

---

## Reverse-proxy routes, client-IP trust and access logs (OAuth gates m, k, ap1)

The VM nginx (Docker Compose `proxy` container for `alb`, host nginx for `acme`) routes, when
`enable_element_web = true`, these paths to the Nebu server instead of Element Web:
`/_matrix/`, `/.well-known/matrix/`, `/.well-known/openid-configuration` (exact), `/oauth2/`,
`/account` (exact) and `/account/`, `/admin/`, `/api/v1/`. Without `enable_element_web` every path
goes to the server. Check after deploy (the OAuth routes answer their documented 404 while
`oauth_enabled` is off; what matters is that the answer comes from Nebu, not from Element's HTML):

```bash
curl -si https://<server_name>/.well-known/openid-configuration | head -1
curl -si https://<server_name>/oauth2/jwks | head -1
curl -si https://<server_name>/account | head -1
```

**Access log without query strings.** nginx logs with `log_format nebu_noquery` (the normalised
path `$uri`, no `$request`, no `$http_referer`), so `/oauth2/authorize`, the SSO callback and
`/account` never log `state`, `code` or device ids. nginx's `error_log` would print the full request
line (query string, referrer) on upstream errors (502/504), so it is set to level `crit`
(`error_log /dev/stderr crit;` in the proxy container, `/var/log/nginx/nebu-error.log crit` for
the `acme` host nginx): neither the journal nor Loki receives request lines. Residual: upstream
failures are no longer diagnosable from the nginx error log (use the access log's status and `rt=`
plus the server logs). In `acme` mode certbot adds a plain-HTTP redirect server block and
`/var/log/nginx/access.log` keeps the distribution's default (combined) format with the query
string: do not send OAuth traffic over plain HTTP.

**Plain HTTP.** `alb`: the VM nginx has two listeners. `:8081` carries the LB's
TLS-terminated traffic and is the only listener that can ever carry the realip directives; `:80`
(the LB's plain-HTTP traffic and health probe) trusts no `X-Forwarded-For` and answers everything
except `/_matrix/client/versions` with a 308 to `https://<server_name>`.
The provider has no ALB redirect action, so the redirect lives in nginx `:80`. `acme`: if
certbot never succeeded (cloud-init logs `[nebu-bootstrap] WARNING: certbot did not succeed`),
the plain-HTTP vhost serves everything with `X-Forwarded-Proto https`; check
`curl -sI http://<server_name>/` answers 301 to https after bootstrap.

**Client-IP trust.** nginx is the single trusted hop. Every proxied location sets
`X-Forwarded-For $remote_addr` (it overwrites, it does not append), so Nebu always receives exactly
one address written by nginx and a client-supplied `X-Forwarded-For` can never choose its rate-limit
bucket. `NEBU_TRUSTED_PROXY_CIDRS` in `/opt/nebu/.env` is derived by OpenTofu:

| `tls_mode` | Published server ports | `NEBU_TRUSTED_PROXY_CIDRS` | `$remote_addr` in nginx |
|---|---|---|---|
| `alb` | `127.0.0.1:8008`, `127.0.0.1:8080` (nginx `:80`, `:8081` for the ALB) | `<compose_subnet .10>/32` (the pinned nginx container) | the Stackit ALB (shared bucket) unless `lb_real_ip_cidrs` is set (applies to `:8081` only) |
| `acme` | `127.0.0.1:8008`, `127.0.0.1:8080` | `<compose_subnet .1>/32` (bridge gateway = host nginx) | the TCP-mode LB or the client, whichever the LB preserves |
| `none` | `8008`, `8080` public (the LB targets 8008) | unset: no trusted proxy | not applicable (no nginx) |

Variables: `compose_subnet` (default `172.30.0.0/24`), `trusted_proxy_cidrs` (override, default empty),
`lb_real_ip_cidrs` (default empty). Validation: `trusted_proxy_cidrs` and `lb_real_ip_cidrs` must be valid
CIDRs and narrow (IPv4 prefix /16 or longer, IPv6 /48 or longer; `0.0.0.0/0` and `::/0` are refused),
`lb_real_ip_cidrs` must lie inside `network_cidr` and only works with the HTTP-level LB modes,
`trusted_proxy_cidrs` must be empty for `tls_mode = "none"`, and `compose_subnet` (prefix /16 to /27) must not overlap
`network_cidr`. Docker's dynamic address pool is the upper half of `compose_subnet` (`ip_range`), so the
gateway (.1) and the pinned proxy (.10) can never be handed to another container. Rules: only list a hop that APPENDS or overwrites the client
address; never an LB that merely forwards a client-written `X-Forwarded-For`; never a network from
which untrusted clients can open connections to the server (the Docker gateway is only safe because
the published ports are loopback-bound). Changing `compose_subnet` on a running VM needs
`sudo systemctl restart nebu.service` (it recreates the compose network).

**Negative test (required before `oauth_enabled`).** From outside, over IPv4 and IPv6 and through the
Stackit ALB, over `https://` AND plain `http://` (port 80):

```bash
curl -si -H 'X-Forwarded-For: 203.0.113.7' https://<server_name>/_matrix/client/versions >/dev/null
curl -si -H 'X-Forwarded-For: 203.0.113.7' http://<server_name>/_matrix/client/versions >/dev/null   # 301/308, never the app
# then sign in and look at the device's last_seen_ip (admin UI device list or /account):
# it must NEVER show 203.0.113.7. Also confirm that http://<vm_public_ip>:8008 and :8080 do not answer from outside.
```

On the VM: `sudo docker compose -f /opt/nebu/docker-compose.yml exec proxy nginx -T | grep -E 'real_ip|X-Forwarded-For'`
(`alb`) and `sudo grep -E 'TRUSTED' /opt/nebu/.env`. Setting `lb_real_ip_cidrs` is only correct once you
have confirmed that the Stackit ALB appends the client address to `X-Forwarded-For`; if it merely
forwards a client-written header, leave it empty (shared bucket: safe against spoofing, NOT safe for availability; do NOT enable `oauth_enabled` in this state). List exact LB `/32`
addresses (the ALB addresses in the network), never the whole `network_cidr`. Confirm the peer address
nginx sees on `:8081` (`docker compose logs proxy`, `$remote_addr` is the first field) matches what you listed.

**Positive test (required before `oauth_enabled`, GATING).** The negative test shows that a client cannot
choose its address; it does NOT show that Nebu sees the REAL client address. With an empty
`lb_real_ip_cidrs` on `alb` nginx sees only the Stackit ALB, so every client shares ONE rate-limit
bucket and per-source cap (safe against spoofing, NOT safe for availability: one anonymous source can
lock every user out of OAuth login). Run it from two clients on different networks (for example a laptop
on the office network and a phone on mobile data) through the real public path (DNS name, Stackit ALB, proxy;
never a direct port):

1. Sign in from both clients, then look at `last_seen_ip` of the two devices (admin users page or
   `GET /_matrix/client/v3/devices`). The two values must be DISTINCT real client addresses, never the
   LB or proxy address.
2. Hammer `POST /_matrix/client/v3/login` (wrong password, until it answers `429`) from one client; the
   other client must still get normal answers.

If either step fails, do NOT enable `oauth_enabled`: set `lb_real_ip_cidrs` (only after the negative
test and only for an LB that appends the client address) and repeat both tests.

Two aids exist, and neither replaces this test (their absence proves nothing): `tofu plan` prints a
client-IP `check` warning for the configurations that are known to collapse the address, and the server
logs two `client IP:` WARNINGs. W2, `client IP: all N devices ...` (every 6 hours), appears when all
recently active devices were seen from at most two addresses (a real single-NAT deployment can ignore
it); the gate requires that this line is absent. W1, `client IP: a request carried X-Forwarded-For`
(at most once per 10 minutes), appears when a request carries that header from an untrusted peer; it
only has to be EXPLAINED (your own negative test against a direct port fires it, and so does a
client-written header on a direct deployment) and must NEVER be silenced by widening
`NEBU_TRUSTED_PROXY_CIDRS`: list only an exact proxy address you verified. W1 cannot fire for the
`alb` collapse with an empty `lb_real_ip_cidrs` (nginx is a trusted peer there); only W2 (after 24 h
of traffic from at least 5 users) and the `tofu plan` check see that case.

---

## Update Strategy

To deploy a new Nebu version without reprovisioning the VM:

```bash
# SSH to the VM
ssh ubuntu@<floating_ip>

# Pull new images and recreate containers (zero config change, data preserved)
cd /opt/nebu
sudo docker compose pull
sudo docker compose up -d --force-recreate
```

To deploy updated config (e.g. new environment variable):

1. Update `terraform.tfvars` with the new values.
2. Run `tofu apply` — the `user_data` change will trigger VM replacement (data loss; see backup first).
   - Alternatively: SSH to the VM, edit `/opt/nebu/.env` directly, then `sudo docker compose up -d`.

---

## Database Backup (PostgresFlex)

Backups are handled automatically by the Stackit PostgresFlex platform. Daily backups run at 02:00 UTC (as configured in `backup_schedule`). Point-in-time recovery (PITR) is available via the STACKIT portal.

For manual dumps or cross-environment restores, connect to the PostgresFlex instance from the VM using the credentials stored in Terraform state:

```bash
# SSH to the VM
ssh ubuntu@<floating_ip>

# Retrieve connection details from Terraform state (run on your local machine)
tofu state show stackit_postgresflex_user.nebu

# Dump via pg_dump (install postgresql-client on the VM if needed)
pg_dump "postgresql://<pg_user>:<pg_password>@<pg_host>:<pg_port>/nebu" | \
  gzip > /tmp/nebu-backup-$(date +%Y%m%d-%H%M%S).sql.gz

# Upload to Stackit Object Storage
rclone copy /tmp/nebu-backup-*.sql.gz stackit:<your-bucket>/backups/
```

---

## Teardown

> **Data loss warning:** `tofu destroy` deletes all Stackit resources including the VM boot volume and all Docker volumes. Back up your database first.

```bash
tofu destroy
```

Confirm the prompt. This removes: VM, network, security group, ALB, floating IP, and SSH key pair.

---

## DNS Configuration

Nebu supports two DNS modes, configured via `dns_mode` in `terraform.tfvars`.

### `dns_mode = "external"` (default) — Manual DNS Registration

OpenTofu does not create DNS records. After `tofu apply`, retrieve the floating IP:

```bash
tofu output dns_name
```

Register this value in your DNS provider:
- **Stackit:** Create an A-record pointing `<server_name>` to the floating IP shown in `dns_name`.

### `dns_mode = "default"` — Managed DNS (Stackit DNS)

OpenTofu creates DNS records automatically in Stackit DNS.

**Stackit DNS:**
- Creates a DNS zone + A-record for `server_name` pointing to the floating IP.
- Requires Stackit DNS service to be enabled in your project.
- If a zone for `server_name` already exists: import it before apply:
  ```bash
  tofu import stackit_dns_zone.nebu <zone_id>
  ```
- `dex_subdomain_enabled = true` additionally creates `dex.<server_name>` pointing to the floating IP (useful for future host-based Dex routing).

---

## Troubleshooting

| Symptom | Check |
|---|---|
| cloud-init hangs | `sudo tail -f /var/log/cloud-init-output.log` |
| Docker not installed | `sudo apt-get install -y docker-ce docker-compose-plugin` (manual fallback) |
| nebu.service failed | `sudo systemctl status nebu.service` + `sudo journalctl -u nebu.service -n 50` |
| Server unhealthy | `sudo docker compose logs server` — check OIDC issuer and DB connectivity |
| `/_matrix/client/versions` returns 502 | LB target not healthy; check `sudo docker compose ps` — server must be `Up (healthy)` |
| TLS certificate error | See `variables.tf` — for `tls_mode = "alb"`, `tls_certificate_pem` / `tls_private_key_pem` must be set for HTTPS termination at the ALB |
