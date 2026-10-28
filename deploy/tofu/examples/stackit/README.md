# Nebu — STACKIT Deployment Example

Deploys Nebu to STACKIT using VMs, Docker Compose, Stackit Application Load Balancer, and DBaaS PostgreSQL.
See [ADR-014](../../docs/architecture/adr/ADR-014-deployment-strategy-iac.md) for the full architecture.

## Quick Start

```bash
# 1. Configure backend and variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Initialise OpenTofu
tofu init -backend-config=backend.hcl

# 3. Review the plan
tofu plan

# 4. Apply
tofu apply
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.6.0
- STACKIT CLI configured (`stackit auth login`)
- STACKIT Object Storage bucket for remote state (see `deploy/README.md`)

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
