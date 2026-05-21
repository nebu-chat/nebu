---
status: ready-for-dev
epic: 16
story: 5
security_review: not-needed
matrix: false
ui: false
---

# Story 16.5: Custom Domain nebuchat.eu + TLS

Status: ready-for-dev

## Story

As a visitor,
I want the Nebu project website to be reachable at https://nebuchat.eu,
So that the site has a professional, memorable URL with valid TLS.

**Size:** S

## Acceptance Criteria

**Given** the GitLab Pages Custom Domain configuration for the project,
**When** it is inspected,
**Then** `nebuchat.eu` is listed as a verified custom domain with a Let's Encrypt TLS certificate (NFR-16.4)

**Given** the DNS configuration for nebuchat.eu,
**When** a DNS lookup for `nebuchat.eu` is performed,
**Then** a CNAME record points to the GitLab Pages endpoint (or an A record if CNAME is not permitted at the apex)

**Given** the site is deployed and DNS has propagated,
**When** `https://nebuchat.eu` is visited in a browser,
**Then** the Nebu landing page renders with a valid TLS certificate and no certificate warnings

**Given** `http://nebuchat.eu` (without TLS),
**When** visited,
**Then** the request redirects to `https://nebuchat.eu`

**Given** the GitLab Pages deployment,
**When** the CI pipeline completes,
**Then** the website is accessible at both the GitLab Pages default URL and `https://nebuchat.eu`

## Technical Notes

- GitLab Pages custom domain: configure in GitLab project settings → Pages → Domains
- Let's Encrypt TLS: GitLab Pages handles this automatically when domain is verified
- DNS: domain owner must set CNAME (or A record for apex) at registrar
- Apex domain CNAME limitation: many registrars do not support CNAME at apex (`@`) — may need A record instead
- HTTP→HTTPS redirect: enabled by default in GitLab Pages when Force HTTPS is checked
- DNS propagation: can take up to 48h — story acceptance requires propagation to complete

**Note:** DNS configuration (CNAME/A record) must be set by the domain owner in the nebuchat.eu registrar. Story acceptance requires DNS propagation to complete.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. [GitLab Pages custom domain config test] — Manual GitLab UI verification
   - Given: GitLab project → Pages → Domains settings
   - When: inspected
   - Then: `nebuchat.eu` is listed as verified custom domain with Let's Encrypt certificate active

2. [DNS resolution test] — Manual DNS lookup
   - Given: DNS propagation has completed
   - When: `dig nebuchat.eu` or `nslookup nebuchat.eu` is run
   - Then: response points to GitLab Pages endpoint

3. [HTTPS reachability test] — Manual browser/curl verification
   - Given: DNS has propagated and GitLab Pages is deployed
   - When: `curl -I https://nebuchat.eu` is run
   - Then: HTTP 200 with valid TLS, no certificate errors

4. [HTTP redirect test] — Manual curl verification
   - Given: site deployed with HTTPS forced
   - When: `curl -I http://nebuchat.eu` is run
   - Then: HTTP 301/302 redirect to `https://nebuchat.eu`
