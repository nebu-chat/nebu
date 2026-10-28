---
story_id: oauth-metadata-dcr-admin-approval
title: "Metadaten + DCR + Admin-Freigabe"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: true
created: 2026-10-09
branch: feature/oauth-broker
---

## Summary

Nebu becomes a Matrix OAuth 2.0 authorization server (broker model) that stands in front of the corporate IdP.
Story 1 introduces the foundational metadata and registration infrastructure required by the spec:

1. **Authorization-Server Metadata** (`GET /_matrix/client/v1/auth_metadata`): RFC 8414 / OIDC discovery document exposing all required OAuth endpoints and capabilities.
2. **Dynamic Client Registration** (RFC 7591): Open registration endpoint (`POST /oauth2/register`) with metadata-hash-based deduplication; registrations start as `pending` and are usable only after admin approval.
3. **Admin-UI Approval Flow**: Admin interface to list, approve, and reject pending client registrations by metadata hash.

NO login/authorize/token endpoints are implemented in this story (those are stories 2–4). Both the metadata endpoint and registration endpoint are only active when OAuth is enabled; disabled instances return `404 M_UNRECOGNIZED`.

Authoritative source: `_bmad-output/planning-artifacts/oauth-broker-spec.md` (sections 3, 3a, 4, 10, 11, 13, 14) and `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`.

## Story

As a **Nebu operator**,
I want Matrix clients to discover Nebu as an OAuth 2.0 authorization server with Dynamic Client Registration and admin-controlled approval,
so that clients can register themselves and operators have visibility and control over which applications are allowed to access their users.

## Acceptance Criteria

### AC1 — Auth Metadata Endpoint (RFC 8414)

`GET /_matrix/client/v1/auth_metadata` returns a JSON object with all required and relevant OAuth 2.0 metadata fields:

- **Required (MUST):** `issuer` (Nebu's public HTTPS URL, no query/fragment), `authorization_endpoint`, `token_endpoint`, `revocation_endpoint`, `registration_endpoint`, `response_types_supported` (min. `["code"]`), `grant_types_supported` (min. `["authorization_code", "refresh_token"]`), `response_modes_supported` (min. `["query", "fragment"]`), `code_challenge_methods_supported` (min. `["S256"]`).
- **Optional:** `prompt_values_supported`, `account_management_uri`, `account_management_actions_supported` (omitted in this story; account page does not exist). Do NOT advertise `device_authorization_endpoint` or `prompt_values_supported` until implemented.
- **Nebu enforcement rule (https-for-all-URLs):** All URLs in the metadata must be `https` (stricter than spec, which requires only `issuer` to be https).
- **Response headers:** `Cache-Control: public, max-age=259200` (3 days for Dart SDK caching).
- **Disabled behavior:** When `oauth_enabled = false` (default), return `404 M_UNRECOGNIZED` with Matrix error format `{"errcode":"M_UNRECOGNIZED","error":"..."}` (not 503, not passthrough to IdP).
- **OPTIONS preflight:** Respond to OPTIONS requests with CORS headers and no endpoint logic (RFC 7231).
- **Schema validation:** Every required field is present, no unknown/deprecated fields, all URLs are `https`.

### AC2 — Dynamic Client Registration Endpoint (RFC 7591)

`POST /oauth2/register` accepts a client metadata object and creates a registration:

- **Disabled behavior:** When `oauth_enabled = false`, return `404 M_UNRECOGNIZED` (same as metadata endpoint).
- **Request validation (per RFC 7591 + spec extensions):**
  - `redirect_uris`: All must follow exact format matching per application type:
    - **Web clients:** `https` URL, no fragment, no userinfo, host must be under (or equal to) the `client_uri` host, any port/path/query allowed.
    - **Native clients with reverse-DNS scheme:** scheme derived from reverse-DNS of `client_uri` host (e.g., `com.example` -> `com.example:/oauth`), no authority component (single slash or none), no fragment.
    - **Native clients with loopback:** `http://localhost/`, `http://127.0.0.1/`, or `http://[::1]/` (no port at registration; any port accepted at authorize time), no fragment, no userinfo.
    - **Native clients with claimed https:** same rules as web clients.
  - `application_type`: `web` or `native` (default `web`).
  - `client_uri`: Required per spec, must be `https` URL, no userinfo.
  - `logo_uri`, `tos_uri`, `policy_uri` if present: must be `https` URLs under the same host as `client_uri` (port/path/query may differ).
  - `response_types` and `grant_types`: unknown types are **ignored** (not rejected). If the request omits `response_types` or they do not contain `code`, apply server default `["code"]` (except reject if explicitly excludes `code`). If the request omits `grant_types` or lacks `authorization_code`, apply server default `["authorization_code", "refresh_token"]` (except reject with `invalid_client_metadata` if explicitly excludes `authorization_code`). The response includes only supported values.
  - `token_endpoint_auth_method=none` **MUST** be supported.
- **Response:** `201 Created` with registered client metadata (filtered to only registered/supported values), including server-generated `client_id`.
- **Error response format:** RFC 7591 3.2.2 `{"error":"<error_code>","error_description":"..."}` (NOT Matrix error format).
- **Error codes:**
  - `invalid_redirect_uri`: redirect_uri(s) fail format validation.
  - `invalid_client_metadata`: client_uri invalid, logo/tos/policy off-host or http, unknown application_type, unsupported token_endpoint_auth_method, or response_types/grant_types explicitly exclude required values.
  - `invalid_request`: other validation failures.
- **Rate limiting:** `POST /oauth2/register` is rate-limited per IP (e.g., 50 reqs/hour) and globally (500 reqs/hour). Exceed → `429 Too Many Requests` with response body `{"error":"too_many_requests"}` and `Retry-After` header (OAuth-style, not Matrix). *[Superseded by review cycles 4 and 5: three bucket families, see "Rate limits (final shape)" in the Dev Agent Record and ADR-033 "Registration rate limits": junk has own buckets (600/h per IP, 5000/h global), every valid request pays a loose 600/h per-IP bucket, and only a request that would INSERT a new row pays 50/h per IP + 500/h global.]*
- **OPTIONS preflight:** Respond to OPTIONS requests with CORS headers and no endpoint logic. Include `Access-Control-Allow-Methods: GET, POST, OPTIONS` and `Access-Control-Allow-Headers: X-Requested-With, Content-Type, Authorization`.

### AC3 — Metadata Hash Deduplication

Each registration is assigned a `metadata_hash` (SHA-256 of the normalized metadata JSON):

- **Normalization:** Sort all JSON keys alphabetically; filter out `client_id`, timestamps (`created_at`, `approved_at`, `rejected_at`), and audit fields (`approved_by`, `rejected_by`, `last_used_at`, `created_from_ip`, `user_agent`). Drop localized metadata keys with `#lang` suffix (e.g., `client_name#en` is dropped; `client_name` is kept); document this in the schema.
- **Deduplication:** Identical registrations (same metadata hash) share a single `oauth_clients` row and are **not duplicated**.
- **Status per hash:** Approval is granted per metadata hash, not per individual `client_id`. All clients with the same metadata hash share the same approval status.
- **Collision handling:** If the same client registers twice with identical metadata, the second request returns `201` with the same `client_id` (idempotent), status unchanged. If metadata was previously rejected, the same `client_id` is returned (still rejected).

### AC4 — Admin-Controlled Approval (DCR Policy)

Clients with `status = pending` cannot be used in authorization flows (story 2 will reject them with a user-friendly error page, per RFC 6749 4.1.2.1 behavior).

- **Admin-UI list:** Displays pending registrations with client name, client URI, redirect URIs, logo, creation time, and Approve/Reject buttons.
- **Approval:** Admin clicks "Approve" → `status` changes to `approved`, `approved_by` (admin user ID) and `approved_at` (current timestamp) recorded.
- **Rejection:** Admin clicks "Reject" → `status` changes to `rejected`, `rejected_by` (admin user ID) and `rejected_at` (current timestamp) recorded. Logs the action. Clients fail at authorize time.
- **Active sessions:** When rejecting a client with active sessions (implemented in later stories), the registration is NOT deleted. The registration remains with `status = rejected` and the active session is marked for cleanup/revocation. This honors the spec rule "Server MUST NOT delete registrations with an active session."
- **No auto-approval (decision Phil, 2026-10-07):** DCR is open, but every registration starts as `pending` and is usable only after admin approval (per metadata hash). There is deliberately NO `dcr_policy` switch and no auto-approve mode; an allowlist refinement would be a separate decision.

### AC5 — OAuth Clients Table

New table `oauth_clients` in `server/priv/migrations/000040_oauth_clients_and_auth_metadata.up.sql`:

```sql
CREATE TABLE oauth_clients (
  client_id TEXT PRIMARY KEY,
  metadata JSONB NOT NULL,
  metadata_hash TEXT NOT NULL UNIQUE,
  application_type TEXT NOT NULL DEFAULT 'web',
  status TEXT NOT NULL DEFAULT 'pending',
  approved_by TEXT,
  approved_at TIMESTAMP,
  rejected_by TEXT,
  rejected_at TIMESTAMP,
  token_endpoint_auth_method TEXT NOT NULL DEFAULT 'none',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TIMESTAMP,
  created_from_ip TEXT,
  user_agent TEXT
);
```

- **Indexes:** `(status, created_at DESC)` for listing pending/rejected approvals, `(metadata_hash)` for dedup.
- **Cluster safety (ADR-020):** Inserts use `ON CONFLICT (metadata_hash) DO NOTHING` for atomic dedup.
- **No foreign keys to users:** registrations are independent of user identity.
- **#lang handling:** Document in migration comment that localized metadata keys with `#lang` suffix are dropped before hashing; only the base key is stored in the `metadata` JSONB.

### AC6 — Rate Limiting and CORS

- **Rate limiting:** `POST /oauth2/register` is rate-limited per IP (e.g., 50 reqs/hour) and globally (500 reqs/hour). Exceed → `429 Too Many Requests` with OAuth-style error body `{"error":"too_many_requests"}` and `Retry-After` header (seconds). *[Superseded by review cycles 4 and 5: three bucket families, see "Rate limits (final shape)" in the Dev Agent Record and ADR-033 "Registration rate limits": junk has own buckets (600/h per IP, 5000/h global), every valid request pays a loose 600/h per-IP bucket, and only a request that would INSERT a new row pays 50/h per IP + 500/h global.]*
- **CORS:** `GET /_matrix/client/v1/auth_metadata`, `POST /oauth2/register`, and `OPTIONS` on both endpoints include `Access-Control-Allow-Origin: *`. All responses include standard CORS headers per RFC 7231. Other OAuth endpoints (authorize, token, revoke, etc. in later stories) also allow CORS per spec. All other Matrix endpoints unaffected.

### AC7 — Payload Redaction (Security)

- **Log redaction:** The `payload_redactor` extension is extended to redact any plaintext credentials/tokens from request/response logging. In this story: no new secrets exist, but prepare the extension for story 2–4 (`code`, `code_verifier`, `refresh_token`, `client_secret`).
- **Metadata logging:** Client metadata in logs (including `redirect_uris`, `client_name`, `logo_uri`) are app identifiers and NOT redacted at INFO level. At DEBUG level, apply the payload_redactor rule to redact unknown nested secrets (future-proofing). Never log the full metadata object in INFO logs; log only `client_id` and `metadata_hash`.
- **Admin logs:** Approval/rejection actions are logged in the compliance audit table with the admin user ID, timestamp, action type (approve/reject), and optionally a rejection reason. The full client metadata is NOT included in the audit log.

### AC8 — ADR-033: "Nebu ist Authorization Server (Broker)"

A new ADR (ADR-033) documents the architectural decision that Nebu acts as an OAuth 2.0 authorization server (broker model O2) in front of the corporate IdP:

- **Roles:** Nebu (Authorization Server + Resource Server), Corporate IdP (Identity Provider only).
- **Token issuance:** Only Nebu issues Matrix access/refresh tokens; IdP-issued JWTs are NOT accepted as Bearer tokens (legacy exception only).
- **Scope management:** All Matrix scopes are Nebu-internal; the IdP sees only a single Nebu client (OIDC).
- **Https-for-all-URLs enforcement:** All OAuth endpoints and metadata URLs must be `https`; this is a Nebu rule stricter than RFC 6749.
- **Implications:** Deprecates legacy `/refresh` and background workers for OAuth sessions (future); coexistence is temporary.

## Acceptance Tests

### Metadata Endpoint Tests (Unit + Integration)

```gherkin
Feature: OAuth 2.0 Server Metadata Discovery
  
  Scenario: Metadata endpoint returns compliant RFC 8414 document
    Given OAuth is enabled in the instance config
    When a client calls GET /_matrix/client/v1/auth_metadata
    Then the response is 200 with Content-Type application/json
    And the response includes all required fields:
      | Field | Example |
      | issuer | https://nebu.example.com |
      | authorization_endpoint | https://nebu.example.com/oauth2/authorize |
      | token_endpoint | https://nebu.example.com/oauth2/token |
      | revocation_endpoint | https://nebu.example.com/oauth2/revoke |
      | registration_endpoint | https://nebu.example.com/oauth2/register |
      | response_types_supported | ["code"] |
      | grant_types_supported | ["authorization_code", "refresh_token"] |
      | response_modes_supported | ["query", "fragment"] |
      | code_challenge_methods_supported | ["S256"] |
    And Cache-Control header is set to "public, max-age=259200"
    And device_authorization_endpoint is NOT present (not yet implemented)
    And prompt_values_supported is NOT present (not yet implemented)
    And account_management_uri is NOT present (account page does not exist)
  
  Scenario: Metadata endpoint returns 404 when OAuth is disabled
    Given OAuth is disabled (oauth_enabled = false)
    When a client calls GET /_matrix/client/v1/auth_metadata
    Then the response is 404 with Matrix error format
    And the response body is: {"errcode":"M_UNRECOGNIZED","error":"..."}
  
  Scenario: OPTIONS preflight on metadata endpoint
    Given OAuth is enabled
    When a client sends OPTIONS /_matrix/client/v1/auth_metadata
    Then the response is 200 with Access-Control headers
    And Access-Control-Allow-Origin header is *
    And no endpoint logic is executed
```

### Dynamic Client Registration Tests

```gherkin
Feature: Dynamic Client Registration (RFC 7591)

  Scenario: Web client registers successfully (pending approval)
    Given OAuth is enabled
    When a web client POSTs to /oauth2/register with:
      | Field | Value |
      | client_name | TestApp |
      | client_uri | https://testapp.example.com |
      | logo_uri | https://testapp.example.com/logo.png |
      | redirect_uris | ["https://testapp.example.com/callback"] |
      | application_type | web |
    Then the response is 201 Created
    And the response includes client_id (generated by server)
    And the response includes only REGISTERED metadata (no unknown fields)
    And the status in database is "pending"
  
  Scenario: Registration endpoint returns 404 when OAuth is disabled
    Given OAuth is disabled (oauth_enabled = false)
    When a client POSTs to /oauth2/register with valid metadata
    Then the response is 404 with Matrix error format
    And the response body is: {"errcode":"M_UNRECOGNIZED","error":"..."}
  
  Scenario: Native client with reverse-DNS redirect scheme
    Given OAuth is enabled
    When a native client POSTs with:
      | Field | Value |
      | client_name | MobileApp |
      | client_uri | https://mobileapp.example.io |
      | application_type | native |
      | redirect_uris | ["io.example.mobileapp:/oauth2/callback"] |
    Then the response is 201 Created
    And the registration is stored with application_type = "native"
  
  Scenario: Native client with loopback (http://localhost, no port at registration)
    Given OAuth is enabled
    When a native client POSTs with:
      | Field | Value |
      | client_name | DesktopApp |
      | client_uri | https://desktopapp.example.com |
      | application_type | native |
      | redirect_uris | ["http://localhost/oauth2/callback"] |
    Then the response is 201 Created
    And the registration is stored with application_type = "native"
    # a loopback URI WITH a port (http://localhost:8080/...) is rejected: 400 invalid_redirect_uri
    # (the port is only accepted at authorize time, story 2)
  
  Scenario: Metadata hash deduplication
    Given OAuth is enabled
    And a client already registered with metadata hash M1
    When another client POSTs identical metadata to /oauth2/register
    Then the response is 201 Created
    And the returned client_id is the SAME as the first registration
    And the database has only ONE oauth_clients row for that metadata_hash
  
  Scenario: Dedup with key order normalization
    Given OAuth is enabled
    And a client registered with keys in order: {"client_name":"App","redirect_uris":[...]}
    When another client POSTs with same metadata but keys in different order: {"redirect_uris":[...],"client_name":"App"}
    Then the response is 201 Created
    And the returned client_id is the SAME (hash is order-independent)
  
  Scenario: Re-registering a rejected client returns same client_id
    Given OAuth is enabled
    And a client was registered and rejected
    When the same metadata is POSTed again
    Then the response is 201 Created
    And the returned client_id is the SAME
    And the status in database remains "rejected" (not reset to pending)
  
  Scenario: Every new registration starts pending (no auto-approval)
    Given OAuth is enabled
    When a client POSTs valid metadata
    Then the response is 201 Created
    And the status in database is "pending"
  
  Scenario: Valid redirect URI formats (web)
    Given OAuth is enabled
    When a web client POSTs with redirect_uris:
      | URI |
      | https://example.com/callback |
      | https://sub.example.com/callback |
      | https://example.com:5173/callback |
      | https://example.com/callback?state=123 |
    Then the response is 201 Created
  
  Scenario: Valid redirect URI formats (native)
    Given OAuth is enabled
    When a native client POSTs with redirect_uris:
      | URI |
      | com.example.app:/oauth2/callback |
      | http://localhost/callback |
      | http://127.0.0.1/callback |
      | http://[::1]/callback |
    Then the response is 201 Created
  
  Scenario: Invalid redirect URI format (web with http)
    Given OAuth is enabled
    When a web client POSTs with redirect_uri = "http://example.com/callback"
    Then the response is 400 with error code "invalid_redirect_uri"
    And the response body is: {"error":"invalid_redirect_uri","error_description":"..."}
    And the registration is NOT created
  
  Scenario: Invalid redirect URI format (web with fragment)
    Given OAuth is enabled
    When a web client POSTs with redirect_uri = "https://example.com/callback#state"
    Then the response is 400 with error code "invalid_redirect_uri"
    And the registration is NOT created
  
  Scenario: Invalid redirect URI format (native with userinfo)
    Given OAuth is enabled
    When a native loopback client POSTs with redirect_uri = "http://user:pass@localhost/callback"
    Then the response is 400 with error code "invalid_redirect_uri"
    And the registration is NOT created
  
  Scenario: Invalid redirect URI format (wrong host for web)
    Given OAuth is enabled
    When a web client POSTs with client_uri = "https://example.com" and redirect_uri = "https://other.com/callback"
    Then the response is 400 with error code "invalid_redirect_uri"
    And the registration is NOT created
  
  Scenario: Invalid client_uri (http instead of https)
    Given OAuth is enabled
    When a client POSTs with client_uri = "http://example.com"
    Then the response is 400 with error code "invalid_client_metadata"
    And the response body is: {"error":"invalid_client_metadata","error_description":"..."}
    And the registration is NOT created
  
  Scenario: Invalid client_uri (with userinfo)
    Given OAuth is enabled
    When a client POSTs with client_uri = "https://user:pass@example.com"
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  Scenario: Invalid logo_uri (http instead of https)
    Given OAuth is enabled
    When a client POSTs with client_uri = "https://example.com" and logo_uri = "http://example.com/logo.png"
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  Scenario: Invalid logo_uri (off-host)
    Given OAuth is enabled
    When a client POSTs with client_uri = "https://example.com" and logo_uri = "https://other.com/logo.png"
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  Scenario: Unknown application_type
    Given OAuth is enabled
    When a client POSTs with application_type = "custom"
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  Scenario: Unsupported token_endpoint_auth_method
    Given OAuth is enabled
    When a client POSTs with token_endpoint_auth_method = "client_secret_basic"
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  Scenario: Unknown response_types are ignored, not rejected
    Given OAuth is enabled
    When a client POSTs with response_types = ["code", "token", "unknown_type"]
    Then the response is 201 Created
    And the response includes response_types = ["code"] (only supported ones)
  
  Scenario: Missing response_types defaults to ["code"]
    Given OAuth is enabled
    When a client POSTs without response_types field
    Then the response is 201 Created
    And the response includes response_types = ["code"]
  
  Scenario: Missing grant_types defaults to ["authorization_code", "refresh_token"]
    Given OAuth is enabled
    When a client POSTs without grant_types field
    Then the response is 201 Created
    And the response includes grant_types = ["authorization_code", "refresh_token"]
  
  Scenario: Explicit exclusion of code rejects with invalid_client_metadata
    Given OAuth is enabled
    When a client POSTs with response_types = ["token"]
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  Scenario: Explicit exclusion of authorization_code rejects with invalid_client_metadata
    Given OAuth is enabled
    When a client POSTs with grant_types = ["implicit"]
    Then the response is 400 with error code "invalid_client_metadata"
    And the registration is NOT created
  
  # NOTE (superseded in review cycles 4/5): 50/h per IP now applies to NEW registrations only; see
  # "Rate limits (final shape)" in the Dev Agent Record. The implemented, tested limits are in
  # oauth_dcr_dedup_limits_test.exs and oauth_dcr_rate_limit_cors_test.exs.
  Scenario: Rate limiting on /oauth2/register (per IP)
    Given the IP-level rate limit is 50 reqs/hour
    When the same IP POSTs to /oauth2/register 51 times in rapid succession
    Then the 51st request receives 429 Too Many Requests
    And the response body is: {"error":"too_many_requests"}
    And a Retry-After header is included
  
  Scenario: Rate limiting on /oauth2/register (globally)
    Given the global rate limit is 500 reqs/hour for /oauth2/register
    When 501 requests are made from different IPs in rapid succession
    Then the 501st request receives 429 Too Many Requests
    And the response body is: {"error":"too_many_requests"}
    And a Retry-After header is included
  
  Scenario: OPTIONS preflight on /oauth2/register
    Given OAuth is enabled
    When a client sends OPTIONS /oauth2/register with CORS headers
    Then the response is 200 with CORS headers
    And Access-Control-Allow-Origin header is *
    And Access-Control-Allow-Methods includes POST, OPTIONS
    And Access-Control-Allow-Headers includes Content-Type, Authorization
    And no endpoint logic is executed
```

### Admin-UI Approval Flow (Gherkin - UI Tests)

```gherkin
Feature: Admin Dashboard — Pending Client Approvals

  Scenario: Admin views list of pending client registrations
    Given OAuth is enabled
    And 3 clients are registered with status = "pending"
    And 2 clients are registered with status = "approved"
    And the user is an admin
    When the admin navigates to Admin UI > OAuth > Pending Clients
    Then the page displays only the 3 pending registrations
    And each row shows:
      | Field | Content |
      | Client Name | from metadata.client_name |
      | Client URI | clickable link |
      | Redirect URIs | comma-separated list |
      | Logo | thumbnail if logo_uri present |
      | Created | registration timestamp |
      | Actions | Approve button, Reject button |
  
  Scenario: Admin approves a pending registration
    Given a pending registration is displayed
    When the admin clicks the "Approve" button
    Then the status in database changes to "approved"
    And approved_by = <admin user id>
    And approved_at = <current timestamp>
    And the client is now usable in OAuth flows (story 2)
    And an audit log entry is created (Admin Action: approved client)
  
  Scenario: Admin rejects a pending registration
    Given a pending registration is displayed
    When the admin clicks the "Reject" button
    And optionally adds a rejection reason (text field)
    Then the status in database changes to "rejected"
    And rejected_by = <admin user id>
    And rejected_at = <current timestamp>
    And an audit log entry is created with rejection reason (if provided)
  
  Scenario: Approved client no longer appears in pending list
    Given a client is approved
    When the admin returns to Pending Clients list
    Then the approved client is NOT shown (only pending remain)
  
  Scenario: Rejected client no longer appears in pending list
    Given a client is rejected
    When the admin returns to Pending Clients list
    Then the rejected client is NOT shown (only pending remain)
  
  Scenario: Admin cannot approve/reject without proper permissions
    Given a non-admin user
    When they try to access the OAuth Admin panel
    Then they receive a 403 Forbidden or are redirected to login
```

### Security & Cluster Safety Tests

```gherkin
Feature: Security and Cluster-Safe Registration

  Scenario: Metadata hash prevents double-insert race condition
    Given two simultaneous requests with identical metadata
    When both POSTs reach /oauth2/register at nearly the same time
    Then one receives 201 with client_id A
    And the other receives 201 with the SAME client_id A
    And no duplicate row is created (ON CONFLICT handled)
  
  Scenario: Concurrent identical registrations are idempotent
    Given three simultaneous POSTs with identical metadata
    When all three reach /oauth2/register at nearly the same time
    Then all three receive 201
    And all three receive the SAME client_id
    And only ONE row exists in oauth_clients for that metadata_hash
  
  Scenario: Metadata hash ignores key order
    Given metadata registered with keys in order A, B, C
    When the same metadata is re-registered with keys in order C, B, A
    Then the second request returns the SAME client_id
    And only ONE row exists in oauth_clients
  
  Scenario: Metadata hash drops #lang suffixed keys
    Given metadata with client_name and client_name#de
    When the metadata is hashed
    Then only client_name is used in the hash (client_name#de is dropped)
    And future registrations with the same base metadata match the hash
  
  Scenario: CORS headers on metadata endpoint
    Given a browser client makes a CORS request
    When it calls GET /_matrix/client/v1/auth_metadata with Origin: https://client.example.com
    Then the response includes Access-Control-Allow-Origin: *
    And the client receives the 200 response
  
  Scenario: CORS headers on register endpoint
    Given a browser client makes a CORS request
    When it POSTs to /oauth2/register with Origin: https://client.example.com
    Then the response includes Access-Control-Allow-Origin: *
    And the client receives the 201 response
  
  Scenario: No sensitive data in INFO logs
    Given a client registration request
    When logs are captured at INFO level
    Then the logs contain client_id and metadata_hash (for audit)
    And logs do NOT contain the full client metadata object
    And logs do NOT contain any plaintext secrets (future story)
  
  Scenario: Redacted metadata at DEBUG level
    Given a client registration request
    When logs are captured at DEBUG level
    Then the logs apply payload_redactor rules
    And any nested secrets are redacted (future-proofing for client_secret)
    And the logs do NOT expose plaintext credentials
```

## Dev Notes

### High-Level Implementation Flow

1. **ADR-033 Creation:** Write the architectural decision document explaining broker model O2, roles, token issuance rules, and https-for-all-URLs enforcement. Place in `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`.

2. **Migration 000040:** Create `server/priv/migrations/000040_oauth_clients_and_auth_metadata.up.sql` and `.down.sql`:
   - `oauth_clients` table with columns: `client_id`, `metadata`, `metadata_hash`, `application_type`, `status`, `approved_by`, `approved_at`, `rejected_by`, `rejected_at`, `token_endpoint_auth_method`, `created_at`, `last_used_at`, `created_from_ip`, `user_agent`.
   - Indexes on `(status, created_at DESC)` and `(metadata_hash)`.
   - RLS grants if RLS is enabled (check existing patterns in earlier migrations).
   - Migration comment documenting #lang key handling (dropped before hashing).
   - `.down.sql` drops the table.

3. **Metadata Endpoint Handler:**
   - Route: `GET /_matrix/client/v1/auth_metadata`
   - Reads config (`oauth_enabled`, `issuer_url`)
   - Returns 404 with Matrix error format if OAuth disabled
   - Generates JSON with all required RFC 8414 fields (excluding device_authorization_endpoint, prompt_values_supported, account_management_uri)
   - Sets `Cache-Control: public, max-age=259200` (3 days for Dart SDK)
   - Supports OPTIONS preflight with CORS headers

4. **DCR Endpoint Handler:**
   - Route: `POST /oauth2/register`
   - Returns 404 with Matrix error format if OAuth disabled
   - Validates request per RFC 7591 + spec extensions (redirect URIs, application_type, client_uri, response_types/grant_types with defaults)
   - Normalizes and filters metadata (sorts keys, drops #lang keys, filters unknown values)
   - Computes SHA-256 `metadata_hash` of normalized, filtered metadata
   - Inserts into `oauth_clients` with `ON CONFLICT (metadata_hash) DO NOTHING` (returns existing `client_id`)
   - Always inserts with `status = pending` (no auto-approval)
   - Rate limits per IP and globally; returns 429 with OAuth-style error body on limit exceeded
   - Supports OPTIONS preflight with CORS headers
   - Returns response with only REGISTERED (filtered) metadata values

5. **Admin-UI Backend Routes:**
   - `GET /admin/oauth/registrations` — list pending registrations (HTML page like the other admin pages; `Accept: application/json` additionally returns JSON)
   - `POST /admin/oauth/registrations/:client_id/approve` — approve a registration
   - `POST /admin/oauth/registrations/:client_id/reject` — reject with optional reason
   - All routes require admin role (`require_admin` plug)

6. **Admin-UI Frontend:**
   - New page: Admin Dashboard > OAuth > Pending Clients
   - Table of pending registrations with Approve/Reject buttons
   - Modal confirmation on approval/rejection
   - Toast notification on success/error
   - Polite refresh (auto-refresh or manual reload)

7. **Payload Redactor Extension:**
   - Extend `Nebu.Compliance.PayloadRedactor` to prepare for story 2–4 redactions
   - At INFO level: never log full metadata; log client_id and metadata_hash only
   - At DEBUG level: apply redactor rules to nested fields (future: code, code_verifier, client_secret)
   - Document the extension point for future stories

8. **Config & Environment:**
   - Add `oauth_enabled` (boolean, default false)
   - Add `issuer_url` (read from public server URL or explicit config)
   - Document in bootstrap wizard and `server_config` table

### File Locations

- **Migrations:** `server/priv/migrations/000040_oauth_clients_and_auth_metadata.up.sql`, `.down.sql`
- **ADR:** `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`
- **Handler:** `server/lib/nebu/web/handlers/oauth_metadata_handler.ex`, `oauth_register_handler.ex`
- **Admin Routes:** `server/lib/nebu/web/routes/admin_oauth_routes.ex` (or extend existing admin routes)
- **Admin UI:** `server/assets/js/admin/oauth` (new directory with components for pending clients list, approve modal, etc.)
- **Config:** `server/lib/nebu/oauth/config.ex` (new module to load and validate OAuth settings)
- **Tests:**
  - Unit: `server/test/nebu/oauth/oauth_metadata_test.exs`, `oauth_dcr_test.exs`, `oauth_admin_test.exs`
  - Integration: `server/test/nebu/web/handlers/oauth_*_integration_test.exs`
  - Gherkin (Admin UI): `server/test/features/admin/oauth_approvals.feature` (if using feature files with Gherkin runner)
  - Migration: `server/test/nebu/migration/000040_oauth_clients_test.exs` (verify table, indexes, RLS)

### Inline SQL & ADR-018 Compliance

- All `oauth_clients` queries are written as inline SQL in `Nebu.OAuth.ClientStore` module (see ADR-018 "No Domain Model").
- Exposed functions: `register/1`, `get_by_client_id/1`, `get_pending_registrations/0`, `approve/3`, `reject/3`, `dedup_insert/2`.
- No ORM layer; queries use Postgrex directly via the existing `Repo` module pattern.

### Cluster Safety (ADR-020)

- The metadata-hash deduplication uses PostgreSQL `ON CONFLICT (metadata_hash) DO NOTHING` to ensure atomic, cluster-safe insertion.
- Admin approval/rejection uses `WHERE status = 'pending' AND client_id = $1` with a return check to prevent race conditions.
- No application-level locks; rely on database transactions and constraints.

### Security Notes

- **Redirect URI validation:** Implement per RFC 7591 spec strictly; web clients require `https`, native reverse-DNS clients have no authority, native loopback clients use http://localhost/127.0.0.1/[::1] without port at registration.
- **Metadata normalization:** Sort JSON keys alphabetically, drop #lang-suffixed keys and system fields (client_id, timestamps, audit fields) before hashing.
- **Error response format:** Return RFC 7591 3.2.2 format (`{"error":"...","error_description":"..."}`, not Matrix error format) for DCR errors; return Matrix error format (`{"errcode":"M_UNRECOGNIZED",...}`) for disabled OAuth.
- **Rate limiting:** Use the existing `Nebu.RateLimit` module (or create if missing) with per-IP and global limits. Return OAuth-style error body on limit exceeded.
- **CORS:** Add headers to metadata, register, and OPTIONS endpoints only; other Matrix endpoints unaffected.
- **Payload redaction:** At INFO level, never log full metadata. At DEBUG level, apply redactor rules to nested fields (future stories). Log client_id and metadata_hash for audit purposes.

### Gate items before `oauth_enabled` can be true / before story 2 merges (security review cycle 4)

Recorded from Kassandra's story-level review (`docs/stories/oauth-broker/security-reports/oauth-metadata-dcr-admin-approval-security-review-2026-10-09.md`), deliberately NOT implemented in story 1; tracked in `docs/stories/oauth-broker/follow-ups.md` and ADR-033 ("Gate items"):

1. **Trusted-proxy client-IP resolution (F-1, MEDIUM, HARD GATE).** CIDR-gated `X-Forwarded-For` / `Forwarded` allowlist (default: none). Until it exists, behind nginx (both reference deployments) all clients share ONE per-IP bucket, so the strict per-IP limit is effectively global.
2. **Bulk reject in the admin UI (F-1).** Without it, recovering from a full pending list is one confirm-and-reject click per row (or SQL).
3. **Public-suffix check (F-4)** for `client_uri` hosts (`github.io`), a warning badge on the approval page, and registrable-domain grouping for the per-host pending cap.
4. **Per-host cap keyed on an attacker-asserted host (N-1, MEDIUM, deferred in cycle 5).** An attacker can fill the cap (20) for a real host with distinct metadata and block that host's new registrations for up to 30 days; fix: key on `(client_host, created_from_ip)` after item 1, or evict the oldest pending row of the host on a cap hit; add "bulk reject by host" to item 2. See follow-ups.md item 4 and ADR-033.

Done in cycle 4 instead (see Dev Agent Record): F-2 discovery one issuer, F-3 DB invariants, F-4 host rule (>= 2 labels, non-numeric TLD), F-5 approval page impersonation hints, F-6 reason sanitising + atomic decision/audit, F-7 IP/UA retention, F-1 partial (dedup before strict buckets, per-host pending cap).

### Testing Strategy

- **Unit tests:** Metadata generation, DCR validation, hash computation, dedup logic, metadata normalization, #lang key handling.
- **Integration tests:** Full HTTP request/response cycles for metadata and register endpoints, OPTIONS preflight, admin API, error codes.
- **Database tests:** Migration, table structure, indexes, RLS grants, concurrent inserts with ON CONFLICT.
- **Feature tests (Gherkin):** Admin UI approval flow, pending list, approve/reject actions (use Playwright or equivalent for UI).
- **Security tests:** Rate limiting enforcement, CORS headers, no secrets in logs, redirect URI validation (all formats), error code verification.

### Must be test-covered (from oracle)

- Metadata enabled: 200 with every required field; issuer = Nebu https URL; no device_authorization_endpoint, prompt_values_supported, account_management_uri; Cache-Control present.
- Metadata disabled: 404 errcode M_UNRECOGNIZED; OPTIONS preflight returns CORS headers.
- DCR success: 201 + client_id; unknown response_types/grant_types omitted; auth method none accepted; application_type omitted defaults to web.
- Valid redirect URIs (201): com.example.app:/callback, com.example:callback, http://localhost/cb, http://[::1]/cb, https://app.example.com/cb (subdomain), https://example.com:5173/?q=v.
- Invalid redirect URIs (400 invalid_redirect_uri): #fragment, web http://, web http://localhost/, https://app.com/cb (other host), userinfo, example:/cb (not reverse-DNS), com.example.app://cb (authority), https://localhost/cb (native), http://localhost:1234/cb (native with port at registration).
- 400 invalid_client_metadata: non-https/userinfo client_uri; logo/tos/policy off-host or http; unknown application_type; unsupported token_endpoint_auth_method; response_types explicitly excludes code; grant_types explicitly excludes authorization_code.
- Dedup: same metadata different key order → same client_id, one row; concurrent identical POSTs → one row; rejected client re-registered → same client_id, status stays rejected.
- 429 + Retry-After on register (OAuth-style body, no errcode).
- /oauth2/register with OAuth off → 404 M_UNRECOGNIZED.

## Dev Agent Record

### Implementation Status

This story creates the foundational infrastructure for OAuth 2.0 support in Nebu. It is scoped to metadata discovery and client registration with admin-controlled approval. No login or token flows are implemented; those are in stories 2–4.

### Key Decisions

1. **Metadata per RFC 8414:** The `issuer` field points to Nebu's own public HTTPS URL, not the IdP. This is a key architectural shift from the current passthrough model.
2. **Https-for-all-URLs (Nebu rule):** All OAuth endpoints and metadata URLs must be `https` (stricter than spec).
3. **Dedup by metadata hash:** Clients registering with identical metadata are deduplicated to allow shared approval per application, not per device.
4. **Approval required by default:** New registrations start as `pending`; operators must explicitly approve them. This is a security-first default.
5. **Rate limiting on register:** Protects against registration spam; configured per instance.
6. **CORS on metadata/register:** Browser-based clients (Element Web, FluffyChat) need CORS to fetch metadata and register.
7. **No auto-approval:** DCR is open, but every registration starts `pending`. No `dcr_policy` switch or auto-approve mode.
8. **Metadata normalization:** Hash ignores key order and drops localized (#lang) and system fields for consistent dedup.
9. **Defaults for response_types/grant_types:** Missing values default to [code] and [authorization_code, refresh_token]; only reject if explicitly excluded.
10. **Rejection preserves registration:** Rejecting a client does NOT delete the registration; status stays rejected on re-registration. Active sessions are NOT deleted (respected in later stories).

### Completion Notes (dev-story, 2026-10-09)

Implemented AC1-AC8 per the "ATDD Decisions" sections. Namespace `Nebu.OAuth` (public API module `Nebu.OAuth`, ADR-020/033).

- **Migration 000040** (`oauth_clients` + indexes + GRANT SELECT/INSERT/UPDATE to `nebu_app` [superseded: the grant also has DELETE, confined to pending rows by RLS, and INSERT is pending-only, see cycles 2 and 4]; re-creates `config_update_mutable` with `oauth_enabled` and `oauth_issuer_url` added, all 000020 keys/LIKE families kept; `.down.sql` restores 000020's policy). Timestamps are `TIMESTAMPTZ` (story sketch says `TIMESTAMP`).
- **`Nebu.OAuth.Config`** (`server/lib/nebu/oauth/config.ex`): `oauth_enabled` read from `server_config` on every call (no cache, fail closed), `oauth_issuer_url` (explicit key; absent => metadata 404), test seam `:oauth_config_source`.
- **`Nebu.OAuth.Metadata`**: RFC 8414 document built from the issuer; non-https issuer => unavailable (404 M_UNRECOGNIZED, never echoed).
- **`Nebu.OAuth.Registration`**: RFC 7591 validation (redirect URI rules web/native/loopback/private-use/claimed-https, client_uri, logo/tos/policy, types/defaults), normalization, canonical-JSON SHA-256 `metadata_hash` (#lang keys + unknown + system fields dropped).
- **`Nebu.OAuth.ClientStore`**: inline SQL; `register/1` (`ON CONFLICT (metadata_hash) DO NOTHING` + select by hash), `get_by_client_id/1`, `get_pending_registrations/0`, `approve/2`, `reject/2` (`WHERE status = 'pending'`, returned-row check) [superseded: `get_pending_registrations/1` is paginated, `approve/3` / `reject/3` take an `:audit` option and run in one transaction with the audit row, `find_by_hash/1` exists, see cycles 2 and 4]. Never deletes decided rows (cycle 2 adds the pending-only TTL purge).
- **`Nebu.OAuth.Http`** forwarded from `Nebu.Web.Router` for `GET /_matrix/client/v1/auth_metadata` (REPLACES the IdP passthrough on the stable path; unstable msc2965 path untouched) and `POST /oauth2/register` (rate limit first: 50/h per IP + 500/h global via the new `Nebu.Web.Plugs.RateLimit.take/3`, then enabled check, body, validation, store) [superseded: the unstable msc2965 paths and `auth_issuer` are fronted by `Nebu.Web.Plugs.OAuthDiscovery` since cycle 4, and the rate-limit order and limits changed in cycles 4 and 5, see "Rate limits (final shape)"].
- **Admin UI**: `Nebu.Admin.OAuthRegistrationsController` + HEEx (`/admin/oauth/registrations`, approve/reject PRG, native confirm via `data-confirm`, always-visible reject `reason` input, `[data-role="toast"]`, empty state, JSON via `Accept: application/json` => `{"registrations": [...]}`), nav group "OAuth" > "Pending Clients" (placed after Configuration so the pinned Spaces > Media > Configuration order holds), audit actions `oauth_client_approved` / `oauth_client_rejected` added to the `AuditWriter` allowlist. (Cycle 1 state: the page widened CSP `img-src` to `https:`; replaced in review cycle 2 by logos-on-click.)
- **PayloadRedactor**: `code`, `code_verifier`, `device_code` added (map keys + form/query strings); OAuth extension point documented.
- **ADR-033** + row in `docs/architecture/09-decisions.md` + `_meta.yaml`; `docs/matrix-api-scope.md` and `08-concepts.md` updated.
- **Tests adapted**: `matrix_router_test.exs` (v1 passthrough tests replaced by disabled-404/enabled-own-document tests; retained passthrough tests repointed to the unstable msc2965 path), `release_test.exs` (count `> 39` + 000040 note), `oauth_admin_test.exs` (setup installs the REAL audit writer because `config/test.exs` globally installs `NoOpAuditWriter`; fixture ids get a random suffix because `audit_log` is append-only and the runtime role cannot delete registrations, so ids from earlier runs collided on a non-fresh DB).
- Verification: `oauth_*` 196/196, `000040_oauth_clients_test` 21/21, `matrix_router_test` 40/40, `release_test` 12/12, nav/layout + admin http controller + web plug suites green; full `mix test --include integration` on a fresh throwaway DB: 3471/3507, 36 failures that are the same pre-existing environment/ordering-dependent families (Trace Map/War Room/Rooms fallback/sync load/capture manager/retention) that fail on the untouched baseline (38 failures there).

### Review cycle 1 (2026-10-09) — code-review MINOR 2-10 + UX gate V1/A2-A9

- **Registration hardening:** `client_name` rejects control/bidi/zero-width/format/separator/private-use characters and invalid UTF-8 (NUL would otherwise be a jsonb error => 503); all URIs reject whitespace/control/format/separator chars; every https host must be ASCII LDH (no IDN, no `xn--`, no look-alike solidus/full-stop/at, no IPv6 literal). `ClientStore.register/1` maps PostgreSQL SQLSTATE class 22 (data exception) to `{:error, :invalid_metadata}` => `400 invalid_client_metadata`.
- **Body limits:** `JsonBody` caps `POST /oauth2/register` at 128 KiB (flag `:body_too_large` => `413 {"error":"invalid_request"}`); `Http` refuses bodies nested deeper than 8 levels with `400 invalid_request`; the 201 carries `Cache-Control: no-store`; `Http` moduledoc no longer claims the limiter precedes body parsing.
- **Admin list:** `Nebu.OAuth.pending_registrations/0` now returns `{:ok, list} | {:error, reason}`; a DB failure renders an error flash (HTML) / 503 (JSON) instead of the empty state. Audit write result is checked: on failure (error tuple or raise) the decision stands, an error is logged and the admin sees an error flash that the audit entry is missing. Success flash names the client.
- **Template:** name cell `<th scope="row">`, width-capped break-anywhere cells for name/client URI, redirect URIs as `<ul><li>`, client URI host shown prominently, "(opens in new tab)", "No logo", visible "Reason (optional, max 500)" label, confirm text with client URI host, `table-zebra`.
- **Migration 000040 (still unreleased, edited in place):** named CHECK constraints for `status` and `application_type`.
- **Config module moved** to `server/lib/nebu/oauth/config.ex` (ADR-020 layout).
- **Test seam:** `:nebu_http, :oauth_repo` (default `Nebu.Repo`) in `ClientStore`, used to simulate an unavailable DB.
- NOT done in cycle 1 (user decision pending then): code-review MAJOR 1 (pending cap/TTL/pagination), CSP `img-src https:` widening (A1/#11). Both implemented in review cycle 2 below.

### Review cycle 2 (2026-10-09) — decisions after code-review cycle 0 (Phil)

**Decision 1 — pending-row protection (TTL purge + pagination + cap): done.**
- **Purge mechanism:** Oban cron job `Nebu.Workers.OAuthPendingPurgeWorker` (hourly `23 * * * *`, new queue `oauth_cleanup: [limit: 1]` in `config/config.exs`) — the repo's existing periodic-job pattern (`Oban.Plugins.Cron`, leader-only enqueue; the older `Sweeper` GenServer runs on every node and is the legacy style). Work = `Nebu.OAuth.ClientStore.purge_expired_pending/1`: batched `DELETE ... WHERE status = 'pending' AND client_id IN (SELECT ... ORDER BY created_at LIMIT 1000 FOR UPDATE SKIP LOCKED)`, max 20 batches per run. Cluster-safe by an atomic DELETE (no advisory lock, no node-local state): concurrent runs split the rows, a row being approved is skipped, `status = 'pending'` is re-checked after the row lock.
- **Migration 000040 (unreleased, edited in place):** `GRANT SELECT, INSERT, UPDATE, DELETE`; `ENABLE` + `FORCE ROW LEVEL SECURITY` on `oauth_clients` (FORCE because in the single-role dev setup `nebu_app` owns the table and an owner bypasses RLS); policies `oauth_clients_select/insert/update` (open) and `oauth_clients_delete_pending` `FOR DELETE USING (status = 'pending')`; trigger `oauth_clients_guard_status` (a decided row can never be set back to `pending`, otherwise RLS could be dodged by flipping the status first); `config_update_mutable` gains `oauth_pending_ttl_days` and `oauth_pending_cap` (all earlier keys kept). `.down.sql` drops the guard function and restores 000020's policy. Verified: down/up round trip with psql; runtime role cannot delete approved/rejected rows, can delete (expired) pending ones (integration tests).
- **Config:** `Nebu.OAuth.Config.pending_limits/0` (`%{ttl_days, cap}`, defaults 30 / 5000; invalid, non-positive or absurd values fall back to the defaults, never "unlimited"; seam keys `:pending_ttl_days` / `:pending_cap` in `:oauth_config_source`).
- **Cap:** part of the INSERT in `ClientStore.register/1` (`INSERT ... SELECT ... WHERE (SELECT count(*) ... status = 'pending') < cap ON CONFLICT (metadata_hash) DO NOTHING`, then select by hash). A dedup hit (any status) is answered even when the cap is reached; NEW metadata above the cap => `{:error, :capacity}` => `503 {"error":"temporarily_unavailable","error_description":...}` + `Retry-After: 3600` + CORS. Count + insert race: READ COMMITTED does not serialise concurrent counts, so N in-flight registrations can overshoot by at most N-1 (pool size x nodes, also bounded by the rate limits) — accepted and documented in ADR-033.
- **Pagination:** `Nebu.OAuth.pending_registrations(page)` => `{:ok, %{registrations, total, page, page_size: 50, total_pages}}` (newest first, like the other admin tables; `?page=N`, invalid => 1, past the end => last page). HTML: `[data-role="pending-summary"]` (total), `[data-role="more-pending"]` ("N more pending on later pages"), nav `[data-role="pagination"]` with `page-prev` / `page-next`; JSON adds `total/page/page_size/total_pages`. Decision forms carry hidden `page`/`logos` so the PRG redirect returns to the same page (values sanitised before they reach the Location header). The old silent `LIMIT 500` is gone.

**Decision 2 — logos only on click, strict CSP by default: done.**
- Default page: no `<img>`, no contact to client-hosted URLs, CSP unchanged (`img-src 'self' data:`; the router no longer widens anything). The logo URL is shown as text (`[data-role="logo-url"]`, host in `[data-role="logo-host"]`, full URL small/breakable).
- "Load logos" (`[data-role="load-logos"]`, GET `?logos=1`, per page, not sticky; "Hide logos" returns): renders `<img>` (https only, `referrerpolicy="no-referrer"`, `loading="lazy"`) and ONLY that response widens `img-src` to the exact origins of the logos on the page (`Nebu.Admin.OAuthRegistrationsHTML.logo_origin/1`, strict validation because the value goes into a header; unsafe origins are neither rendered nor allowed; CSP also covers redirects). Set in the controller on top of the router's strict policy.
- ADR-033 documents both decisions and the trade-offs (new sections "Pending registrations" and "Client-hosted logos"); `09-decisions.md` row and `docs/matrix-api-scope.md` updated.

**Tests (test-first):** new `server/test/nebu/oauth/oauth_pending_protection_test.exs` (limits, cap + dedup bypass + 503 shape, purge incl. batching/concurrency/race with approval, RLS delete guard + status guard trigger, cron wiring, logo_origin/list_href units); `oauth_admin_test.exs` (default page: no `<img>` + strict CSP; `?logos=1`: `<img>` + exact-origin CSP, per-request widening, unsafe origins, pagination of 55 rows, page clamping, return-to-page redirect, JSON totals); `000040_oauth_clients_test.exs` (RLS/policies/trigger/new keys static + integration); `oauth_client_store_test.exs` (the only DELETE is the pending purge); `adr_033_test.exs`; `oauth_test_support.exs` (random suffix in `web_body` names: decided rows survive across runs). E2E: updated `@ac4-list` (logo URL as text, no image), new `@ac4-logos-on-click` and `@ac4-pagination` scenarios + steps; `fixtures/db.ts` gained `insertPendingOAuthClients` (the DCR rate limit of 50/hour/IP makes >1 page impossible through the real endpoint — documented exception) and its cleanup comment was corrected. `tsc --noEmit` and `bddgen` are clean on a scratch copy; the Playwright run itself needs the full compose stack and was NOT run.

### Review cycle 4 (2026-10-09) — Kassandra (SEC Gate 1) findings F-1 partial, F-2 .. F-7

- **F-2 (discovery split-brain):** decision Phil 2026-10-07 (spec section 14 #7). New `Nebu.Web.Plugs.OAuthDiscovery` fronts `v1/auth_issuer`, `unstable/org.matrix.msc2965/auth_issuer` and `unstable/org.matrix.msc2965/auth_metadata`: OAuth enabled => `Nebu.OAuth.Http` (`{"issuer": "<Nebu>"}` / the same document as the stable path, invalid issuer => 404 M_UNRECOGNIZED); OAuth disabled => the unchanged legacy IdP passthrough. This is the DECISION (Phil, 2026-10-09; spec section 14 #7 amended: Nebu's issuer only while OAuth is enabled, no 404 when disabled, because 404 would break Element/FluffyChat for every non-OAuth deployment; the stable `v1/auth_metadata` stays a 404 while disabled). Accepted risk "approval gate bypassable through legacy discovery until legacy shutdown" is recorded in ADR-033.
- **F-3 (DB invariants):** migration 000040 (edited in place): INSERT policy `WITH CHECK (status = 'pending' AND approved_by/approved_at/rejected_by/rejected_at IS NULL)`; guard trigger now `BEFORE UPDATE` (no column list) and also refuses changes to `client_id`, `metadata`, `metadata_hash`, `application_type`, `token_endpoint_auth_method`, `client_host`; CHECK `oauth_clients_decision_check` ties approved/rejected rows to their `*_by`/`*_at` and keeps pending rows clean. Test helper `T.insert_row!/6` inserts pending and then UPDATEs a decision.
- **F-4:** `ascii_dns_host?/1` (registration.ex) and `logo_origin/1` (admin HTML) require >= 2 labels and a last label that is not all digits (no `https://com`, no `10.0.0.5`, no `0.1`). Public-suffix check is a gate item.
- **F-5:** approval page shows `application_type`, an "unverified claims" note, a per-redirect-URI badge (`data-role="redirect-host-bound"` / `"redirect-not-host-bound"`, `"redirect-other-host"`, row-level `"identity-unverified"`), and `confirm_text` is `Approve client at <host> (name "<name>")? ...`. Existing selector contract kept; the e2e list scenario got one step for the new hooks.
- **F-6:** `normalize_reason/1` strips `\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Zl}\p{Zp}`; `Nebu.OAuth.approve_registration/3` / `reject_registration/3` take an `:audit` fun executed in the SAME `Repo.transaction` as the decision UPDATE: an audit failure rolls the decision back (`{:error, {:audit, reason}}`, flash "not saved ... still pending"). The old tests that asserted "the decision stands" were changed to the rollback contract.
- **F-7:** approve/reject UPDATEs set `created_from_ip` / `user_agent` to NULL; retention documented in ADR-033.
- **F-1 partial:** `POST /oauth2/register` order is now loose bucket (600/h per IP, 5000/h global; every request) -> enabled? -> body -> validate -> hash lookup (`ClientStore.find_by_hash/1`); a dedup hit is answered without touching the strict buckets; a NEW registration pays the strict buckets (50/h per IP, 500/h global) and then the pending caps. New per-`client_uri`-host pending cap `oauth_pending_host_cap` (default 20; `oauth_clients.client_host` + partial index; key allowlisted in 000040; `Config.pending_limits/0` gained `host_cap`; seam key `:pending_host_cap`): over the cap => `503 temporarily_unavailable` + `Retry-After`, dedup hits bypass it. This supersedes the "50/h per IP, 500/h global before validation" ATDD decision above (the strict numbers now apply to new rows only). I-8 also done: store errors are logged by SQLSTATE/type only.
- **Tests:** new `oauth_dcr_dedup_limits_test.exs` (strict/loose buckets, dedup-first, host cap); changed `oauth_dcr_rate_limit_cors_test.exs` (loose 600/5000), `oauth_admin_test.exs` (F-5/F-6/F-7, rollback contract), `oauth_metadata_test.exs` (F-2), `000040_oauth_clients_test.exs` (F-3), `oauth_dcr_hardening_test.exs` (F-4), `oauth_pending_protection_test.exs` (logo origin, confirm text, host_cap config).

### Review cycle 5 (2026-10-09) — code-review cycle 4 MINOR + Kassandra re-review (cycle 4): N-2, N-3, N-4, F-1 remainder

- **Rate limits (final shape), F-1 remainder:** `POST /oauth2/register` now has THREE bucket families (`Nebu.OAuth.Http`). INVALID (own buckets, 600/h per IP + 5000/h global): charged only by junk (unparsable/oversize/invalid body, or any request while OAuth is disabled); when exhausted the junk request is answered 429 instead of its 4xx. LOOSE (600/h per IP, NO global bucket): charged by every valid request, the only budget of a dedup hit. STRICT (50/h per IP + 500/h global): only a request that would INSERT a new row. Order: enabled? -> body -> validate -> loose -> hash lookup -> strict -> store. So junk can no longer starve the dedup hits every login depends on. The old "loose 600/5000 charged by every request first" description (cycle 4) is superseded.
- **N-2:** the last label of a `client_uri` / `logo_uri` / redirect host must not match `~r/\A(0x[0-9a-f]*|[0-9]+)\z/i` (WHATWG "ends in a number"; `127.0.0.0x1`, `10.0.0.0x5`, `0x7f.0x1`, `0.0x1`) in `registration.ex` and `oauth_registrations_html.ex`.
- **N-3:** the guard trigger of migration 000040 (edited in place) refuses, once `OLD.status <> 'pending'`, every change of `status`, `approved_by`, `approved_at`, `rejected_by`, `rejected_at` (no rejected -> approved, no approved -> rejected, no re-attribution); `last_used_at` and the NULLing of `created_from_ip` / `user_agent` stay possible.
- **N-4 / Discovery:** `Nebu.OAuth.Config.get/0` is three-state (`state: :enabled | :disabled | :unknown`; `enabled` stays the boolean). `Nebu.Web.Plugs.OAuthDiscovery` takes the IdP passthrough ONLY on a positively read `:disabled`; on `:unknown` (unreadable `server_config`) the three discovery paths answer `503 {"errcode":"M_UNKNOWN"}` + `Cache-Control: no-store`, no `issuer`, no passthrough (503 rather than 404: the state is transient). The stable `auth_metadata` and `/oauth2/register` stay fail-closed 404 on `:unknown`. "No repository process" counts as `:disabled` (pre-broker behaviour; unit runs). The IdP passthrough while OAuth is disabled is the DECISION (Phil, 2026-10-09; spec #7 amended), not a deviation. The weak `status in [404, 405]` assertion of `oauth_metadata_test.exs` is pinned to the exact 404 + `M_UNRECOGNIZED`.
- **Code-review MINORs:** stale test names/comments of `oauth_dcr_rate_limit_cors_test.exs` recomputed; `AuditWriter` moduledoc carve-out for the `Nebu.OAuth` decisions; ADR-033 "Database guard" (INSERT policy is pending-only) + migration comment section 3 + ADR heading level of "Client-hosted logos"; `Nebu.OAuth` moduledoc names `Nebu.Web.Plugs.OAuthDiscovery` as second HTTP-edge forwarder; superseded story prose marked; e2e "ATDD, written FIRST (RED)" prose; `oauth_registrations_controller.ex` `{:error, other}` clause logs type/SQLSTATE only.
- **Runbook:** migration 000040 is unreleased and was edited in place (again in cycle 5). A database that applied an earlier shape (dev volume, CI cache) must be reset: drop the volume, or run the down migration and then the up migration. See follow-ups.md and ADR-033 "Operations note".
- **Deferred (recorded, not implemented):** N-1 per-host cap keyed on an attacker-asserted host (follow-ups.md item 4, ADR-033 gate item 4). INFO: I-10 (quote/escape `"` in the confirm text) and I-11 ("host-bound" badge wording) recorded in follow-ups.md; I-12 (cache `Config.get/0`) recorded.
- **Tests (test-first for behaviour; see the final report for the red/green notes):** `oauth_dcr_dedup_limits_test.exs` (junk cannot starve dedup hits, no global dedup bucket), `oauth_dcr_rate_limit_cors_test.exs` (renamed to 600/5000, disabled requests charged to the junk bucket), `oauth_dcr_hardening_test.exs` + `oauth_pending_protection_test.exs` (N-2), `000040_oauth_clients_test.exs` (N-3, static + DB), `oauth_metadata_test.exs` (N-4, pinned 404), `oauth_config_test.exs` (three states), `oauth_test_support.exs` (`unreadable_oauth_config/0`).

### File List

New:
- server/priv/migrations/000040_oauth_clients_and_auth_metadata.up.sql
- server/priv/migrations/000040_oauth_clients_and_auth_metadata.down.sql
- server/lib/nebu/oauth.ex
- server/lib/nebu/oauth/http.ex
- server/lib/nebu/oauth/metadata.ex
- server/lib/nebu/oauth/registration.ex
- server/lib/nebu/oauth/client_store.ex
- server/lib/nebu/oauth/config.ex (moved from server/lib/nebu/config/oauth_config.ex in review cycle 1; module name unchanged)
- server/test/nebu/oauth/oauth_dcr_hardening_test.exs (review cycle 1)
- server/lib/nebu/workers/oauth_pending_purge_worker.ex (review cycle 2)
- server/test/nebu/oauth/oauth_pending_protection_test.exs (review cycle 2)
- server/lib/nebu/admin/oauth_registrations_controller.ex
- server/lib/nebu/admin/oauth_registrations_html.ex
- server/lib/nebu/admin/templates/oauth_registrations/index.html.heex
- docs/architecture/adr/ADR-033-authorization-server-broker-model.md
- server/lib/nebu/web/plugs/oauth_discovery.ex (review cycle 4)
- server/test/nebu/oauth/oauth_dcr_dedup_limits_test.exs (review cycle 4)
- docs/stories/oauth-broker/follow-ups.md (review cycle 4)

Modified:
- server/lib/nebu/web/router.ex
- server/lib/nebu/web/plugs/rate_limit.ex
- server/lib/nebu/web/plugs/request_logger/payload_redactor.ex
- server/lib/nebu/compliance/audit_writer.ex
- server/lib/nebu/admin/router.ex
- server/lib/nebu/admin/layouts.ex
- server/lib/nebu/web/plugs/json_body.ex (review cycle 1: 128 KiB body cap for POST /oauth2/register)
- review cycle 2: server/config/config.exs (Oban cron entry + `oauth_cleanup` queue), server/priv/migrations/000040_*.up/down.sql (RLS, DELETE grant, status guard trigger, TTL/cap keys), server/lib/nebu/oauth.ex, oauth/client_store.ex, oauth/config.ex, oauth/http.ex, server/lib/nebu/admin/oauth_registrations_controller.ex, oauth_registrations_html.ex, templates/oauth_registrations/index.html.heex, admin/router.ex (CSP widening removed), server/test/nebu/oauth/oauth_admin_test.exs, oauth_client_store_test.exs, adr_033_test.exs, oauth_test_support.exs, server/test/nebu/migration/000040_oauth_clients_test.exs, e2e/features/admin/oauth-client-approvals.feature, e2e/step-definitions/admin/oauth-client-approvals.steps.ts, e2e/fixtures/db.ts, docs/architecture/adr/ADR-033-*.md, docs/architecture/09-decisions.md, docs/matrix-api-scope.md
- server/test/nebu/matrix/matrix_router_test.exs
- server/test/nebu/release_test.exs
- server/test/nebu/oauth/oauth_admin_test.exs
- server/test/nebu/oauth/oauth_dcr_integration_test.exs, oauth_client_store_test.exs, oauth_test_support.exs, server/test/nebu/migration/000040_oauth_clients_test.exs (review cycle 1)
- server/test/nebu/oauth/oauth_config_test.exs, adr_033_test.exs, oauth_metadata_test.exs, oauth_dcr_validation_test.exs, oauth_dcr_rate_limit_cors_test.exs, oauth_payload_redaction_test.exs (review cycle 1: moduledocs reworded)
- docs/architecture/09-decisions.md
- review cycle 5: server/lib/nebu/oauth/http.ex, oauth/config.ex, oauth/registration.ex, server/lib/nebu/oauth.ex, server/lib/nebu/web/plugs/oauth_discovery.ex, server/lib/nebu/compliance/audit_writer.ex, server/lib/nebu/admin/oauth_registrations_controller.ex, oauth_registrations_html.ex, server/priv/migrations/000040_*.up.sql, server/test/nebu/oauth/{oauth_dcr_dedup_limits_test,oauth_dcr_rate_limit_cors_test,oauth_dcr_hardening_test,oauth_pending_protection_test,oauth_metadata_test,oauth_config_test,oauth_test_support}.exs, server/test/nebu/migration/000040_oauth_clients_test.exs, docs/architecture/adr/ADR-033-authorization-server-broker-model.md, docs/stories/oauth-broker/follow-ups.md, e2e/features/admin/oauth-client-approvals.feature, e2e/step-definitions/admin/oauth-client-approvals.steps.ts, _bmad-output/nebu/epics/oauth-broker/pipeline-state.yaml (comment wording)
- docs/architecture/adr/_meta.yaml
- docs/architecture/08-concepts.md
- docs/matrix-api-scope.md
- review cycle 4: server/priv/migrations/000040_*.up/down.sql, server/lib/nebu/web/router.ex, oauth.ex, oauth/http.ex, oauth/client_store.ex, oauth/config.ex, oauth/registration.ex, admin/oauth_registrations_controller.ex, admin/oauth_registrations_html.ex, admin/templates/oauth_registrations/index.html.heex, ADR-033, docs/matrix-api-scope.md, docs/architecture/08-concepts.md, e2e/features/admin/oauth-client-approvals.feature, e2e/step-definitions/admin/oauth-client-approvals.steps.ts; tests: oauth_test_support.exs, oauth_admin_test.exs, oauth_metadata_test.exs, oauth_dcr_rate_limit_cors_test.exs, oauth_dcr_hardening_test.exs, oauth_pending_protection_test.exs, 000040_oauth_clients_test.exs
- docs/stories/oauth-broker/oauth-metadata-dcr-admin-approval.md (status, checklist, Dev Agent Record, Change Log)

### Related Stories

- **Story 0c (prerequisite):** Token hashing in `matrix_sessions` — uses the same table pattern, should merge before this story.
- **Stories 2–4:** Authorize, token, revocation endpoints — depend on the metadata and registration tables created here.
- **Story 5:** Legacy coexistence — adds `auth_api` column to `matrix_sessions` and enables both APIs in parallel.
- **Story 6:** Account management UI — uses client metadata and scope information.

### Risks & Mitigations

- **Migration numbering collision:** If another branch adds migration 000040 in parallel, renumber at merge time (keep gap-free).
- **Admin UI complexity:** The Approve/Reject flow is straightforward; use existing admin patterns (role checks, audit logging).
- **Rate limiting implementation:** Verify existing `Nebu.RateLimit` module supports per-IP limits; if not, implement a simple token-bucket or sliding-window counter in Redis/Postgres.
- **Metadata caching:** Clients cache for 3 days; changes to metadata (e.g., enabling OAuth) are visible only after cache expiry. Document in release notes.

### Testing Checklist

- [x] ADR-033 is written (broker model, https-for-all-URLs, https enforcement); review is the pipeline's code-review/SEC gate.
- [x] Migration 000040 applies via `Nebu.Release.migrate/0` and its `.down.sql` + `.up.sql` re-apply cleanly (psql, throwaway PostgreSQL 16).
- [x] Metadata endpoint returns all required RFC 8414 fields with correct values (no device_authorization_endpoint, prompt_values_supported, account_management_uri).
- [x] Metadata endpoint returns 404 M_UNRECOGNIZED when OAuth disabled.
- [x] OPTIONS preflight on metadata returns 200 with CORS headers (no logic).
- [x] DCR endpoint returns 404 M_UNRECOGNIZED when OAuth disabled.
- [x] DCR endpoint validates redirect URIs per spec (web https, native reverse-DNS/loopback, no userinfo, no fragment).
- [x] DCR endpoint returns REGISTERED (filtered) metadata, not submitted metadata.
- [x] Metadata hash deduplication works (same metadata = same client_id, no duplicates).
- [x] Metadata hash ignores key order (normalization).
- [x] Metadata hash drops #lang-suffixed keys.
- [x] Re-registering rejected client returns same client_id (status stays rejected).
- [x] response_types/grant_types handling: unknown values ignored, missing values default, explicit exclusion of code/authorization_code rejects.
- [x] Error codes: invalid_redirect_uri for redirect failures, invalid_client_metadata for other validation, invalid_request for others.
- [x] Admin panel lists only pending registrations and allows approve/reject.
- [x] Admin approval records approved_by and approved_at.
- [x] Admin rejection records rejected_by and rejected_at.
- [x] Rate limiting is enforced on /oauth2/register (per IP and globally).
- [x] 429 response includes OAuth-style error body and Retry-After header.
- [x] CORS headers are present on metadata, register, and OPTIONS endpoints.
- [x] Logs do NOT contain full metadata at INFO level; do NOT expose secrets.
- [x] Integration tests pass (metadata 200/404 based on oauth_enabled, register returns 201/4xx/429).
- [ ] Feature tests (Gherkin) for Admin UI approval flow are green. (NOT run: the Playwright e2e needs the full compose stack with Dex; verified statically only: `tsc --noEmit` clean, `bddgen` generates the feature without undefined/duplicate steps, HEEx markup matches the step contract. Run `oauth-client-approvals.feature` in the integration stage.)

## Change Log

- **2026-10-09:** Initial story created for Story 1 of oauth-broker epic. Scope: auth_metadata, DCR, admin approval, migration 000040, ADR-033.
- **2026-10-09 (oracle-amended):** Resolved all story deviations from spec v1.18: added rejected_by/rejected_at columns, fixed error codes (errcode field, invalid_redirect_uri vs invalid_client_metadata), added response_types/grant_types default handling, defined #lang key handling (drop them), added OPTIONS preflight support, added 429 + Retry-After, fixed logging inconsistency (never log full metadata at INFO), added /oauth2/register 404 when OAuth disabled, clarified metadata normalization for hashing, documented rejection behavior with active sessions, removed device_authorization_endpoint/prompt_values_supported/account_management_uri from this story, marked https-for-all-URLs as Nebu rule, added native loopback and claimed-https examples, expanded Gherkin with comprehensive test cases.
- **2026-10-09 (dev-story):** Implemented story: migration 000040, `Nebu.OAuth` (Config, Metadata, Registration, ClientStore, Http), DCR + auth_metadata endpoints, rate limiting, admin approval UI, audit actions, redactor extension, ADR-033. Status -> review.

- **2026-10-09 (review cycle 2):** Implemented the binding decisions after code-review cycle 0: pending-row protection (hourly Oban purge of expired pending rows, RLS-confined DELETE + status guard trigger, pending cap with 503 + Retry-After, dedup bypass, `server_config` keys `oauth_pending_ttl_days`/`oauth_pending_cap`, paginated approval list with totals) and logos only on click (no `<img>` and strict CSP by default, `?logos=1` renders images and widens `img-src` to the exact logo origins for that response only). ADR-033, tests and e2e updated.
- **2026-10-09 (review cycle 1):** Addressed code-review MINOR 2-10 and UX gate V1/A2-A9 (hostile client_name/host rejection, body caps, admin list DB-error + audit-failure surfacing, markup hardening, CHECK constraints, Config module move); MAJOR 1 and the CSP img-src decision deliberately left open.

- **2026-10-09 (review cycle 4):** Addressed Kassandra SEC Gate 1 (0 CRITICAL / 0 HIGH / 1 MEDIUM / 6 LOW): F-2 discovery names one issuer once OAuth is enabled, F-3 database-enforced lifecycle invariants, F-4 stricter host rule, F-5 impersonation hints on the approval page, F-6 sanitised reason + atomic decision/audit, F-7 IP/UA erased on decision, F-1 partial (dedup before the strict rate limit, per-host pending cap). Recorded as gate items, not implemented: trusted-proxy client-IP resolution, bulk reject, public-suffix check.
- **2026-10-09 (review cycle 5):** Addressed code-review cycle 4 MINOR 1-8 and Kassandra re-review (cycle 4): F-1 remainder (junk has its own rate-limit buckets, a dedup hit pays only a per-IP bucket), N-2 (hex-notation IPv4 hosts rejected), N-3 (a decision is final in the database), N-4 (three-state config: 503 instead of IdP passthrough when `server_config` is unreadable), IdP passthrough while disabled documented as the decision, exact 404 pinned, doc/prose/runbook fixes. N-1 deferred and recorded (follow-ups.md, ADR-033 gate item 4).

## ATDD Decisions (2026-10-09, binding for dev-story)

Seams and names fixed by the red-phase tests (change `server/test/nebu/oauth/oauth_test_support.exs` in ONE place if a name must change):
- Config seam: `Application.put_env(:nebu_http, :oauth_config_source, fn -> %{enabled: bool, issuer_url: url} end)`; default `enabled: false`. A non-https `issuer_url` fails closed (never 200).
- Rate limit reuses the `:nebu_http_rate_limit_buckets` ETS table and the `:rate_limit_clock_fn` seam. [Superseded: it no longer runs before validation and the limits are no longer 50/h per IP + 500/h global for every request; see "Rate limits (final shape)" in the Dev Agent Record.]
- Audit actions `oauth_client_approved` / `oauth_client_rejected` (add to the `AuditWriter` allowlist), target_type `oauth_client`, target_id = client_id, reason in `metadata.reason`. `approved_by`/`rejected_by` = session `matrix_user_id`.
- Admin markup: `data-page="oauth-registrations"`, rows `data-role="oauth-client-row"` + `data-client-id`, empty state `no-pending-clients`, nav key `oauth-pending-clients` under an "OAuth" group. Admin UI is HEEx controllers (not `server/assets/js/admin/oauth`); Gherkin lives in `e2e/features/admin/`.
- `oauth_enabled` lives in `server_config` (update-allowlist RLS: the migration/config module must permit the key).
- `GET /_matrix/client/v1/auth_metadata` is REPLACED (old IdP passthrough; disabled → 404 M_UNRECOGNIZED). The dev step must update the old passthrough tests in `matrix_router_test.exs`. The unstable `org.matrix.msc2965` path was out of scope originally [superseded: since cycle 4 it is Nebu's alias document while OAuth is enabled and the IdP passthrough while it is disabled, see "Discovery" in the Dev Agent Record].
- OPTIONS preflight: 200 or 204 accepted. Missing `redirect_uris`: `invalid_redirect_uri` or `invalid_client_metadata`; missing `client_uri`: `invalid_client_metadata`.
- Open (untested): only-unknown `response_types`; subdomain `logo_uri`.

### ATDD Decisions — test-review follow-up (2026-10-09, pre-dev; binding for dev-story)

Admin UI confirmation contract (test-review M1). The existing admin flows (device revoke in `users/show.html.heex`, `device-management.steps.ts`) use a NATIVE `confirm()` wired from the form's `data-confirm` message by the external `/admin/static/assets/app.js` (CSP `script-src 'self'`, dead controller render — no LiveView, no modal). The OAuth approvals page follows the same pattern; the Gherkin steps assert that the confirm dialog actually fires (the story's "modal confirmation" wording means this native confirmation step):
- Approve / Reject are `<button type="submit">` in per-row forms (`[data-role="approve-client"]` / `[data-role="reject-client"]`) posting to `/admin/oauth/registrations/:client_id/approve|reject`, each form with `data-confirm`.
- Because a native `confirm()` cannot collect text, the reject form carries an ALWAYS-VISIBLE optional text input `[name="reason"]` (filled before clicking Reject).
- Sidebar: parent toggle `button[data-navkey="oauth"]` (label "OAuth", expanded by default, via `Layouts.nav_item` with `children`), child link `a[data-navkey="oauth-pending-clients"]` ("Pending Clients").
- Success feedback: `[data-role="toast"]` after the redirect back to the list.
- E2E hygiene: an `@oauth-approvals` After hook resets `oauth_enabled` to `'false'` and deletes this feature's `e2e-oauth-*` registrations through the privileged `nebu` DB role (failures are loud). The empty-state scenario never decides foreign pending registrations; it fails with a clear message if the DB has any.

`oauth_enabled` / config (test-review m2):
- `Nebu.OAuth.Config.get/0` (`server/lib/nebu/oauth/config.ex`) returns `%{enabled: boolean, issuer_url: ...}`. With NO seam installed it reads `oauth_enabled` from `server_config` on every call (no cache): `"true"` => true; `"false"`, any other value, or an absent key => false (fail closed). Pinned by `oauth_config_test.exs` (integration).
- Migration 000040 MUST re-create `config_update_mutable` with `'oauth_enabled'` added and every key/LIKE family of 000020's policy retained; `.down.sql` restores 000020's policy (static + runtime-role UPDATE tests in `000040_oauth_clients_test.exs`; precedent `migration_oidc_scopes_mutable_test.exs`).
- The `server_config` key the issuer URL is read from is NOT pinned (dev's choice); https-only/fail-closed issuer handling is tested via the seam. A non-https issuer => `404 M_UNRECOGNIZED` on `auth_metadata` (treated as unavailable, no document, no http URL echoed).
- Dev adds an ADR-033 row to the decisions table in `docs/architecture/09-decisions.md` (asserted by `adr_033_test.exs`).

Behaviour notes (test-review i3):
- A malformed, empty, or non-object (array/scalar) JSON body on `POST /oauth2/register` => `400 invalid_request` (OAuth error shape, never the Matrix shape).
- Order on `POST /oauth2/register`: rate limiter FIRST, then the enabled-check (disabled => 404 M_UNRECOGNIZED), then body parsing/validation. A request over the limit is therefore 429 even when OAuth is disabled or the body is invalid.
- The limiter must survive loss of the `:nebu_http_rate_limit_buckets` table at runtime (lazily recreated, per-IP and GLOBAL bucket; no 500).
- `GET /admin/oauth/registrations` with `Accept: application/json` returns either a bare JSON list or an object wrapping the list under `"registrations"` or `"clients"`; every entry carries `"client_id"` (test accepts all three shapes — dev picks one).

## Decisions after code-review cycle 0 (Phil, 2026-10-09) — binding

1. **Pending-row protection (TTL purge + pagination + cap):** `pending` registrations are purged automatically after a TTL (default 30 days; they never have sessions, so this does not violate the Matrix "MUST NOT delete" rule — `approved`/`rejected` rows are NEVER purged). The approval list is paginated (page size 50) with a total pending count and "N more pending" indicator, oldest-first or newest-first as consistent with the existing admin tables, never silently truncated. A global cap on pending rows (default 5000): above it, new registrations of NEW metadata are refused with 503 `temporarily_unavailable` + `Retry-After` (OAuth-shaped); a re-registration of already-known metadata (dedup hit) still returns the existing client_id. The purge is cluster-safe (single winner, e.g. advisory lock / `DELETE ... WHERE status='pending' AND created_at < now() - interval`), needs a runtime DELETE grant ONLY for pending rows (RLS policy `status = 'pending'`; the runtime role must still be unable to delete approved/rejected rows). TTL and cap are `server_config` keys (migration 000040 allowlist) with the defaults above.
2. **Logos only on click:** the approval page renders NO `<img>` and makes no network contact to client-hosted URLs by default; CSP stays strict (`img-src 'self' data:`) on the default page. A "Load logos" control (GET `?logos=1`, per page) re-renders with `<img>` tags (https only, `referrerpolicy="no-referrer"`, lazy) and ONLY that request widens `img-src` (preferably to the exact origins of the logos shown on that page, otherwise `https:`). The logo URL is always visible as text (host prominent). ADR-033 documents the trade-off and the choice. A decision made via an unloaded-logo page is fully possible (logos are informational).
