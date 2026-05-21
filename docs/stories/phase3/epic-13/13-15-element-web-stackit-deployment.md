---
status: done
epic: 13
story: 15
security_review: required
matrix: false
ui: false
atdd: not-applicable
---

# Story 13.15: Element Web Client Option for Stackit IaC Deployment

Status: done

## Story

As a system operator deploying Nebu to Stackit,
I want to optionally include the Element Web Matrix client in the deployment by setting `enable_element_web = true` in my `terraform.tfvars`,
so that end-users can access Nebu via a browser without installing a separate client.

**Size:** S

---

## Background & Motivation

The existing Stackit IaC (`deploy/tofu/examples/stackit/`) deploys the Nebu gateway and core as Docker Compose services, but does not bundle a web client. Operators who want to offer browser-based access to Nebu currently have to deploy Element Web separately and configure it manually.

This story adds an optional `enable_element_web` flag that:
1. Adds the `vectorim/element-web:v1.12.15` Docker service to the cloud-init-rendered `docker-compose.yml`.
2. Writes `/opt/nebu/element-config.json` with correct `base_url` pointing at the gateway.
3. Configures nginx (when TLS is enabled) to route `/` → Element on loopback port 7070 while forwarding `/_matrix/`, `/.well-known/matrix/`, and `/admin/` to the gateway on port 8008.
4. Adds a `lifecycle precondition` that blocks `tofu apply` if `enable_element_web = true` AND `enable_tls = false` - enforcing the CORS constraint documented below.

### CORS Constraint - Why enable_tls is required

When `enable_element_web = true` but `enable_tls = false`:
- Element Web is served by its own container at `http://<server_name>:7070` (a distinct origin).
- The Nebu gateway responds at `http://<server_name>:8008` (different port = different origin).
- Browsers enforce the Same-Origin Policy for XHR/`fetch` requests: Element's Matrix API calls to port 8008 trigger CORS preflight (`OPTIONS`) requests that fail because the gateway does not emit `Access-Control-Allow-Origin: http://<server_name>:7070`.
- **Result: every Matrix API call from Element silently fails** with a CORS error in the browser console.

When `enable_tls = true`, nginx terminates TLS and unifies both services under `https://<server_name>` (one origin):
- `https://<server_name>/` → nginx → Element container at `127.0.0.1:7070`
- `https://<server_name>/_matrix/` → nginx → gateway at `127.0.0.1:8008`

Because both paths are served from the same origin (`https://<server_name>`), no CORS preflight is needed. This is the only supported configuration for `enable_element_web = true`.

---

## Acceptance Criteria

**AC1 - `enable_element_web` variable:**
Given `deploy/tofu/examples/stackit/variables.tf`,
When it is inspected,
Then:
- `variable "enable_element_web"` is present with `type = bool` and `default = false`
- The description explains the CORS constraint (TLS required)

**AC2 - CORS lifecycle precondition in `server.tf`:**
Given `deploy/tofu/examples/stackit/server.tf`,
When it is inspected,
Then a `lifecycle { precondition { ... } }` block exists that:
- Has `condition = !var.enable_element_web || var.enable_tls`
- Has an `error_message` that explains the CORS/nginx requirement

**AC3 - `enable_element_web` passed to `templatefile()` in `server.tf`:**
Given `deploy/tofu/examples/stackit/server.tf`,
When the `templatefile()` call in `user_data` is inspected,
Then `enable_element_web = var.enable_element_web` is passed as a template variable.

**AC4 - Element Docker service in `cloud-init.tftpl`:**
Given the rendered `docker-compose.yml` section in `cloud-init.tftpl` with `enable_element_web = true`,
When it is inspected,
Then:
- An `element` service using image `vectorim/element-web:v1.12.15` is present
- Port binding is `127.0.0.1:7070:80` when `enable_tls = true` (loopback only - no direct public access)
- Port binding is `0.0.0.0:7070:80` when `enable_tls = false` (direct public, no-TLS path)
- `/opt/nebu/element-config.json` is mounted as `/app/config.json:ro`
- `depends_on: gateway: condition: service_healthy` is present
- A `healthcheck` polling `http://localhost/` is present

**AC5 - `element-config.json` written by cloud-init:**
Given `cloud-init.tftpl` with `enable_element_web = true`,
When the rendered `/opt/nebu/element-config.json` is inspected,
Then:
- `m.homeserver.base_url` is `${gateway_scheme}://${server_name}${gateway_port}` (resolves correctly for both TLS and no-TLS)
- `m.homeserver.server_name` is `${server_name}`
- `brand` is `"Nebu"`
- `disable_custom_urls`, `disable_guests`, `disable_3pid_login`, `default_federate` all set to their hardened values (true/true/true/false)
- `UIFeature.registration` and `UIFeature.passwordReset` are disabled (`false`) - Nebu uses OIDC-only auth
- The file is absent when `enable_element_web = false`

**AC6 - nginx routing for Element (TLS path):**
Given `cloud-init.tftpl` with `enable_tls = true` and `enable_element_web = true`,
When the nginx config section is inspected,
Then:
- `location /_matrix/` → `proxy_pass http://127.0.0.1:8008` (gateway)
- `location /.well-known/matrix/` → `proxy_pass http://127.0.0.1:8008` (gateway)
- `location /admin/` → `proxy_pass http://127.0.0.1:8008` (gateway)
- `location /` → `proxy_pass http://127.0.0.1:7070` (Element)
- Dex routing (`/dex/`) is still present when `oidc_mode = "dex"` (no regression)

**AC7 - `element_url` output in `outputs.tf`:**
Given `deploy/tofu/examples/stackit/outputs.tf`,
When it is inspected,
Then an `element_url` output:
- Returns `https://<server_name>/` when `enable_element_web = true` AND `enable_tls = true`
- Returns `http://<server_name>:7070/` when `enable_element_web = true` AND `enable_tls = false`
- Returns `"disabled"` when `enable_element_web = false`

**AC8 - `terraform.tfvars.example` documents the option:**
Given `deploy/tofu/examples/stackit/terraform.tfvars.example`,
When it is inspected,
Then:
- An `# ── Element Web client ──` section exists
- `enable_element_web = false` is shown (commented out or as a default)
- The section explains the nginx routing and the `enable_tls` requirement

---

## Implementation Notes (DONE - Documentation Story)

**This story documents already-implemented changes.** All code was committed in `b77e54e` (`feat(deploy/stackit): add optional Element Web client deployment`). The story file serves as the formal specification and audit trail for the BMAD pipeline.

### Files Modified

All changes are confined to `deploy/tofu/examples/stackit/`:

| File | Change |
|---|---|
| `variables.tf` | Added `variable "enable_element_web"` (bool, default false) |
| `server.tf` | Added `enable_element_web = var.enable_element_web` to `templatefile()` call; added CORS `lifecycle precondition` |
| `cloud-init.tftpl` | Added `element-config.json` write_files block (conditional); added `element` Docker service (conditional); added Element nginx routing blocks (conditional) |
| `outputs.tf` | Added `element_url` output with three-way conditional |
| `terraform.tfvars.example` | Added `# ── Element Web client ──` documentation section |

**Reference file:** `docker/element-config.json` - committed as a static reference for local dev (used by `make dev`), NOT deployed by OpenTofu. The cloud-init template renders its own copy at `/opt/nebu/element-config.json` with values interpolated at apply time.

### Key Design Decisions

**Element image version:** `vectorim/element-web:v1.12.15` - pinned for reproducibility. Update the pin in `cloud-init.tftpl` when upgrading.

**Port binding strategy:**
- TLS enabled: `127.0.0.1:7070:80` - Element is loopback-only; nginx (port 443) is the public entry point. Port 7070 is never reachable from the internet.
- TLS disabled: `0.0.0.0:7070:80` - Element is directly accessible on port 7070. This is the no-TLS fallback, but the CORS precondition in `server.tf` blocks `enable_element_web = true` without `enable_tls = true`, making this path unreachable in practice via OpenTofu. The conditional is present in the template for completeness/future use.

**nginx ordering:** The `location /` block for Element MUST come after all specific Matrix path blocks (`/_matrix/`, `/.well-known/matrix/`, `/admin/`). nginx evaluates `location` blocks in order (prefix match wins longest prefix), so this ordering ensures Matrix API paths are never accidentally proxied to Element.

**Dex coexistence:** When `oidc_mode = "dex"` AND `enable_element_web = true`, nginx serves:
- `/dex/` → Dex (port 5556 loopback)
- `/_matrix/` → gateway (port 8008)
- `/.well-known/matrix/` → gateway (port 8008)
- `/admin/` → gateway (port 8008)
- `/` → Element (port 7070)

No conflicts. All four path prefixes are distinct.

**Security hardening in `element-config.json`:**
- `disable_custom_urls: true` - prevents users from pointing Element at a different server
- `disable_guests: true` - no anonymous access
- `disable_3pid_login: true` - email/phone login disabled (OIDC-only)
- `default_federate: false` - no federation by default
- `UIFeature.registration: false` - self-registration UI hidden (OIDC handles provisioning)
- `UIFeature.passwordReset: false` - password reset UI hidden (OIDC handles credentials)
- `UIFeature.identityServer: false` - Matrix identity server disabled (no federation)
- `UIFeature.thirdPartyId: false` - third-party ID association disabled

**`sso_redirect_options.immediate: false`** - on first load Element shows the SSO login button rather than immediately redirecting. Set to `true` if all users should be auto-redirected to the OIDC provider.

### Firewall Notes

Port 7070 is NOT added to the Stackit security group rules (`network.tf`). When `enable_tls = true` (the only supported config for `enable_element_web = true`), the port binding is `127.0.0.1:7070:80` - the port is not reachable from outside the VM. The existing security group rules (`inbound_https` port 443, `inbound_http` port 80) are sufficient.

If an operator were to manually use `enable_element_web = true` with `enable_tls = false` (bypassing the OpenTofu precondition), port 7070 would be exposed on `0.0.0.0` but blocked by the security group (no rule for 7070). Element would be unreachable, but so would the CORS-broken Matrix API calls. The precondition prevents this configuration from being applied.

---

## Acceptance Tests

**Note:** This is a pure IaC/infrastructure story. There are no Go, Elixir, or web browser components. The IaC changes deploy to a remote Stackit VM via `tofu apply` - not testable with Playwright or Godog. Acceptance validation is by code inspection (`tofu validate`, `tofu fmt`) and manual smoke-test on the deployed VM.

### Validation Approach

1. **Static analysis:** `tofu validate` passes - no HCL syntax errors, all variable references resolve.
2. **Format check:** `tofu fmt -check deploy/tofu/examples/stackit/` - exit 0.
3. **Precondition test (manual):** Set `enable_element_web = true`, `enable_tls = false` → `tofu plan` fails with the CORS error_message. ✓ Verified in implementation.
4. **Deployed smoke-test (manual):** With `enable_element_web = true`, `enable_tls = true` → `https://<server_name>/` loads Element Web; `https://<server_name>/_matrix/client/versions` returns a JSON response from the gateway.

### Why no ATDD / Playwright

IaC tests require a live Stackit project and incur infrastructure costs. The test surface (nginx routing, Docker Compose rendering) is exercised by the deployed VM, not by a browser automation framework. The `atdd: not-applicable` frontmatter flag is correct per CLAUDE.md conventions (pure infrastructure story, no observable browser behavior on CI).

---

## Security Classification

`security_review: required` - per BMAD Gate 4 rules (new nginx routing, CORS enforcement logic, firewall implications).

**Security review scope for this story:**
- CORS guard completeness: does the `lifecycle precondition` in `server.tf` reliably prevent the misconfigured state?
- nginx routing: are Matrix API paths (`/_matrix/`, `/.well-known/matrix/`, `/admin/`) correctly shielded from the Element fallback `location /`?
- Port binding: is `127.0.0.1:7070:80` used (not `0.0.0.0:7070:80`) when TLS is enabled?
- Firewall: is port 7070 NOT opened in the security group when Element is deployed behind nginx?
- `element-config.json` hardening: are all UIFeature flags set to prevent OIDC bypass via the UI?

---

## Dev Agent Record

### Agent Model Used

Implementation was performed directly by the user (Philipp) - not via a dev agent. Story file created by claude-sonnet-4-6 (bmad-create-story skill).

### Completion Notes List

- Implementation committed: `b77e54e feat(deploy/stackit): add optional Element Web client deployment`
- All 5 files modified are in `deploy/tofu/examples/stackit/` - no application code changed
- `docker/element-config.json` committed as reference (not deployed by OpenTofu)
- The `enable_element_web = true` + `enable_tls = false` precondition was manually verified

### File List

- `deploy/tofu/examples/stackit/variables.tf` - `enable_element_web` variable
- `deploy/tofu/examples/stackit/server.tf` - `templatefile()` arg + CORS precondition
- `deploy/tofu/examples/stackit/cloud-init.tftpl` - Element service, element-config.json, nginx routing
- `deploy/tofu/examples/stackit/outputs.tf` - `element_url` output
- `deploy/tofu/examples/stackit/terraform.tfvars.example` - documentation section
- `docker/element-config.json` - reference config (local dev use only)
