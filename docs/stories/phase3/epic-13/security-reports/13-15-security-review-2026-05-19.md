## Security Review — Story 13.15: Element Web Client Option for Stackit IaC Deployment

**Diff scope:** Commit `b77e54e` + staged changes — `deploy/tofu/examples/stackit/cloud-init.tftpl`, `server.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars.example`, `docker/element-config.json`
**Date:** 2026-05-19
**Reviewer:** Kassandra (nebu-agent-kassandra)

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | HIGH | `cloud-init.tftpl:189–219` | `/api/v1/` gateway paths missing from nginx routing — proxied to Element instead | Add `location /api/v1/ { proxy_pass http://127.0.0.1:8008; ... }` before `location /` |
| 2 | MEDIUM | `cloud-init.tftpl:169–206` | Upgrade/Connection headers not forwarded to Element's `location /` block | Add `proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade;` to Element `location /` |
| 3 | LOW | `cloud-init.tftpl:91–130` | `element-config.json` permissions are `0644` (world-readable on VM) | Acceptable — file contains no secrets; `0644` is correct. Advisory only. |
| 4 | LOW | `docker/element-config.json` staged change | `sso_redirect_options.immediate` changed from `true` → `false` | Positive change — no finding. Noted as hardening improvement. |

---

### Detail

**Finding #1 — `/api/v1/` routes silently routed to Element Web** [HIGH]

The nginx configuration added by this story (cloud-init.tftpl lines 166–219) defines four `location` blocks for the Element Web deployment path:
- `location /dex/` → gateway (conditional, oidc_mode=dex)
- `location /_matrix/` → gateway (port 8008)
- `location /.well-known/matrix/` → gateway (port 8008)
- `location /admin/` → gateway (port 8008)
- `location /` → Element Web (port 7070, catch-all)

The Nebu gateway exposes the following authenticated routes that are **not covered by any of the above prefix blocks**:

```
GET  /api/v1/admin/bootstrap/import-status
POST /api/v1/compliance/access-requests
GET  /api/v1/compliance/access-requests
POST /api/v1/compliance/access-requests/{requestId}/approve
POST /api/v1/compliance/access-requests/{requestId}/reject
POST /api/v1/compliance/access-requests/{requestId}/session
GET  /api/v1/compliance/export
POST /api/v1/admin/compliance/sessions/{sessionId}/revoke
DELETE /api/v1/admin/users/{userId}/keys
POST /api/v1/admin/users/{userId}/anonymize
DELETE /api/v1/admin/users/{userId}
GET  /api/v1/openapi.yaml
```

These are all admin and compliance endpoints (Epic 14, GDPR delete, SCIM import, compliance officer flows). `location /admin/` covers `/admin/*` only — it does NOT match `/api/v1/admin/*` because nginx prefix-match only matches the exact prefix `/admin/`, not a prefix containing `/admin/` as a substring.

**Impact:** When `enable_element_web = true`, all `/api/v1/` requests are reverse-proxied to the Element container on port 7070 instead of the gateway on port 8008. The Element container returns HTML/JS (404 page or its React app), not a JSON API response. The admin and compliance APIs are completely non-functional.

**Why this is HIGH, not CRITICAL:** The routes are protected by session auth middleware at the gateway level. Since requests never reach the gateway when nginx sends them to Element, there is no authentication bypass — but the APIs are silently broken (admin operations appear to fail or return HTML error responses rather than gateway 4xx/5xx). In environments where operators assume `enable_element_web = true` does not break other paths, this silently disables compliance and admin audit functionality.

**Concrete remediation:**

Add a `location /api/v1/` block immediately before `location /` in the `enable_element_web` nginx section (cloud-init.tftpl lines 195–206):

```nginx
          location /api/v1/ {
              proxy_pass         http://127.0.0.1:8008;
              proxy_http_version 1.1;
              proxy_set_header   Host              $host;
              proxy_set_header   X-Real-IP         $remote_addr;
              proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
              proxy_set_header   X-Forwarded-Proto https;
          }

          # Everything else — Element Web client.
          location / {
              ...
          }
```

This must come BEFORE `location /` to have higher prefix specificity. nginx's longest-prefix-wins rule will route `/api/v1/...` to the gateway while `/` catches everything else for Element.

---

**Finding #2 — Missing WebSocket headers in Element `location /` block** [MEDIUM]

The `location /` block that proxies to Element (lines 199–206) does not forward the `Upgrade` and `Connection` headers:

```nginx
location / {
    proxy_pass         http://127.0.0.1:7070;
    proxy_http_version 1.1;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto https;
    # Missing: Upgrade + Connection headers
}
```

Compare with the `/_matrix/` block (lines 169–178), which does correctly forward WebSocket upgrade headers. The `location /` catch-all is the gateway-path fallback when Element is NOT deployed (the `%{ else ~}` branch at lines 209–218), and that fallback block DOES include WebSocket headers — this is correct for the Matrix sync long-poll.

For Element itself (port 7070), the Element Web client may need WebSocket connectivity for voice/video widget iframes or certain embedded content. While Element Web v1.12.15 does not require WebSocket upgrades at the proxy level for its core Matrix CS API communication (it uses long-poll HTTP, now handled by `/_matrix/` which has the correct headers), the missing `Upgrade`/`Connection` headers on `location /` could silently break SFU/Jitsi widget frames or future Widget API integrations that open WS connections to paths not under `/_matrix/`.

**Severity rationale — MEDIUM (not LOW):** The `map $http_upgrade $connection_upgrade` block is already defined at the top of the nginx config, indicating WebSocket support was intentionally designed. The omission from the Element location block is a gap that could silently break future features without any error signal.

**Concrete remediation:** Add to the Element `location /` block:

```nginx
proxy_set_header   Upgrade           $http_upgrade;
proxy_set_header   Connection        $connection_upgrade;
```

---

**Finding #3 — element-config.json file permissions** [LOW / Informational]

The cloud-init `write_files` block sets `element-config.json` to `permissions: "0644"` (world-readable on the VM). This is correct — the file contains no secrets, only UI configuration values (homeserver URL, feature flags). The gateway URL (`base_url`) is a public endpoint. There is no confidential information in the file. This is an informational note; no change required.

---

**Finding #4 — `sso_redirect_options.immediate: true → false`** [Positive hardening, no finding]

The staged change to `docker/element-config.json` corrects `sso_redirect_options.immediate` from `true` to `false`. With `immediate: true`, Element immediately redirects any unauthenticated user to the OIDC provider without showing a login button. This was flagged as a potential UX concern (accidental redirect loops if the OIDC provider is misconfigured or unreachable). The change to `false` shows the login button first, requiring explicit user action before the OIDC redirect. This is a hardening improvement and is correctly reflected in the cloud-init template (which already had `immediate: false`). No security concern.

---

### Security Focus Areas — Review Findings

The areas called out in the story's security scope were reviewed as follows:

| Area | Finding |
|------|---------|
| CORS guard completeness (`server.tf` precondition) | CLEAN — `!var.enable_element_web \|\| var.enable_tls` correctly blocks the misconfigured state at `tofu plan` time. Condition logic is sound. |
| nginx routing — Matrix API path shielding | HIGH F-1 — `/api/v1/` paths missing from nginx routing; caught by catch-all `location /` |
| Port binding (127.0.0.1 loopback) | CLEAN — `127.0.0.1:7070:80` used when `enable_tls = true`; precondition forces TLS for Element deployment |
| Port 7070 firewall (network.tf) | CLEAN — no `inbound_7070` security group rule exists; precondition blocks the non-TLS path via OpenTofu; SG has no rule for 7070 |
| element-config.json hardening | CLEAN — all 8 UIFeature flags set (`registration: false`, `passwordReset: false`, `identityServer: false`, `thirdPartyId: false`); `disable_custom_urls: true`, `disable_guests: true`, `disable_3pid_login: true`, `default_federate: false` |
| No secrets in element-config.json | CLEAN — file contains only public config values (homeserver URL is the public gateway endpoint) |
| SFU/TURN config not exposed | CLEAN — no `voip` or TURN/STUN configuration present in element-config.json |
| nginx WebSocket headers | MEDIUM F-2 — Upgrade/Connection headers missing from Element `location /` block |
| Content-Security-Policy headers | OUT OF SCOPE for this story — nginx does not add CSP headers in this config (pre-existing behavior); Element's own nginx container serves its static assets with appropriate headers internally |

---

### MEMORY.md Patterns — Prior Findings Applied to This Review

- **`/admin/*` security-headers carve-out misses `/api/v1/admin/*`** (Epic 14 pattern): Applied — finding F-1 is the deployment-topology manifestation of this same gap. The gateway correctly gates auth, but now nginx silently routes `/api/v1/` away from the gateway entirely.
- **Per-story CLEAN reviews can stack into combined HIGH at epic-end** (Epic 12 pattern): This story introduces a gateway routing gap that is invisible in isolation (the gateway itself is unchanged) but observable at the deployment level. F-1 would not appear in a pure code review of gateway source.

---

### Summary

CRITICAL: 0
HIGH: 1 — `/api/v1/` gateway paths missing from nginx routing (F-1) — blocks commit
MEDIUM: 1 — WebSocket headers missing from Element `location /` block (F-2) — advisory, address before story marked done
LOW: 1 — Informational only, no action required (F-3)

**Verdict: BLOCKED**

F-1 is a HIGH finding that silently disables all admin and compliance API endpoints when `enable_element_web = true`. The fix is a single additional `location /api/v1/` block in the nginx config. The story cannot be marked `done` until F-1 is remediated. F-2 should be addressed in the same fix commit.

---

### Required Fix

Edit `deploy/tofu/examples/stackit/cloud-init.tftpl`, in the `%{ if enable_element_web ~}` nginx section, add before the `location / {` catch-all block:

```nginx
          location /api/v1/ {
              proxy_pass         http://127.0.0.1:8008;
              proxy_http_version 1.1;
              proxy_set_header   Host              $host;
              proxy_set_header   X-Real-IP         $remote_addr;
              proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
              proxy_set_header   X-Forwarded-Proto https;
          }
```

And add to the existing `location / {` (Element) block:

```nginx
              proxy_set_header   Upgrade           $http_upgrade;
              proxy_set_header   Connection        $connection_upgrade;
```

---

## FOLLOW-UP: Fix Verification

**Verification date:** 2026-05-19
**Verifier:** Kassandra (nebu-agent-kassandra)
**Diff reviewed:** `git diff --staged deploy/tofu/examples/stackit/cloud-init.tftpl`

### F-1 — HIGH: `/api/v1/` routing gap — RESOLVED

`location /api/v1/` is present at line 199 of `cloud-init.tftpl`, inside the `%{ if enable_element_web ~}` block. It appears **before** `location /` (line 209), satisfying nginx's longest-prefix-wins rule. The block proxies to `http://127.0.0.1:8008` with the standard gateway headers (`Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`). All admin and compliance API paths under `/api/v1/` now route to the gateway when Element Web is enabled.

### F-2 — MEDIUM: Missing WebSocket headers in Element `location /` — RESOLVED

`proxy_set_header Upgrade $http_upgrade` and `proxy_set_header Connection $connection_upgrade` are present at lines 216–217 of the Element `location /` block (lines 209–218). The `map $http_upgrade $connection_upgrade` variable was already defined at the nginx config top level; these headers are now forwarded correctly to the Element container.

### New-issue scan of the fix diff

The diff introduces no new security issues:

- The `location /api/v1/` block uses identical header forwarding to the existing `/_matrix/`, `/.well-known/matrix/`, and `/admin/` blocks. No novel headers or behaviors are added.
- No secrets, credentials, or environment variable interpolations are present in the new lines.
- The comment `# Internal/compliance API paths — routed to gateway (not Element).` is documentation-only; no functional impact.
- A doc-comment was added to the Element healthcheck line (`# vectorim/element-web is nginx-alpine-based...`). This is informational only; no security impact.
- The accidental trailing `# zez` artifact in line 1 (`# Variables injected at apply time; no hardcoded secrets. zez`) was removed. No security impact; positive housekeeping.
- The non-Element (Gateway-only) `location /` block (lines 221–230) already had `Upgrade`/`Connection` headers and was not modified.

### Final verdict

**CLEAN — story 13-15 is cleared for merge.**

Both HIGH and MEDIUM findings from the original review are fully remediated. No new issues introduced. The nginx routing configuration for `enable_element_web = true` is now correct: `/api/v1/` routes to the gateway; `location /` routes to Element with WebSocket header forwarding.
