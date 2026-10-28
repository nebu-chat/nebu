---
story_id: admin-oauth-switch
title: "Admin UI switch for the OAuth 2.0 authorization server: oauth_enabled checkbox and oauth_issuer_url field on /admin/config, strict fetch metadata + fresh re-authentication + activation acknowledgement + audit row + non-blocking precondition status"
type: feature
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-14
branch: feature/migrate-to-oauth2
---

# Story: Admin UI writer for `oauth_enabled` / `oauth_issuer_url`

Owner requirement (2026-10-14, verbatim): "für `oauth_enabled` brauche ich in den OIDC-Einstellungen in der Admin UI einen Haken.
Sonst kann ich das an meiner laufenden Instanz auf Upcloud nicht nachträglich aktivieren."

Today there is no Admin UI writer for the `server_config` keys `oauth_enabled` and `oauth_issuer_url`: the activation is SQL
only (`docs/architecture/07-deployment.md`, "Activating OAuth", step 1; `dev/tls/oauth.sh` for the local stack). An instance
that runs on UpCloud / Stackit behind a load balancer has no convenient database console, so the owner cannot activate OAuth
later. The switch decides whether every user of the instance is offered a second login API and whether the issuer origin is
trusted by the legacy SSO login, so it is a privileged action and gets the protection of the SSO trust lists.

## Story

As an instance administrator I want to switch the OAuth 2.0 authorization server on and off, and to set its public issuer
URL, on the Configuration page of the Admin UI, with the same protection as the other trust-widening settings and with an
honest overview of the preconditions the server can see itself, so that I can activate OAuth (and roll it back) on a running
instance without database access.

## Decisions

- **D1 (where).** A new section "OAuth 2.0 authorization server" on `/admin/config` (the page that already carries the OIDC
  scopes, the SSO trust lists and the OIDC refresh mode): form `#oauth-switch-form`, `POST /admin/config/oauth-switch` ->
  `Nebu.Admin.ConfigController.save_oauth_switch/2`. The path segment `oauth-switch` joins the unframed config segments of
  the router (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `Cache-Control: no-store`). `dev/tls/oauth.sh` stays.
- **D2 (fields).** A hidden `oauth_enabled=false` followed by the checkbox `oauth_enabled=true` ("Offer the OAuth 2.0 API",
  checked = on; unchecked = off = the kill switch), the text field `oauth_issuer_url` (label "Issuer URL"), the checkbox
  `oauth_activation_ack` and the submit button "Save OAuth settings". Only the values `true` / `false` are accepted for
  `oauth_enabled` (anything else is a validation error, never a silent "off").
- **D3 (issuer validation).** Non-empty input is validated by the ONE runtime function (`Nebu.OAuth.Metadata.normalize_issuer/1`,
  reached through the public module as `Nebu.OAuth.normalize_issuer/1`): https only, a host, no userinfo, no query, no fragment,
  empty path (a single trailing `/` is stripped). The stored value is the normalized one. Form-only additions (stricter than
  the runtime check, never looser): no whitespace or control character inside, an ASCII host (punycode for IDN) or a bracketed IPv6
  literal, an optional numeric port 1..65535 (`URI.parse` reads `https://host:` and `https://host:abc` as the default port), at most
  255 bytes (inclusive). The host case is kept as typed (the runtime function does not normalize it); `localhost` and IP literals
  are allowed. The message for an invalid issuer while switching ON is the "cannot be switched on without a valid https issuer URL"
  text, while off the plain "not valid" text. An EMPTY issuer is allowed
  only while the switch is off (it stores `""`, which the runtime reads as "no issuer"); an invalid non-empty issuer is
  refused also while the switch is off (a junk value is never persisted). Enabling without a valid issuer is refused with a
  clear message and nothing is written. The field is pre-filled with the stored value; when nothing is stored it is
  pre-filled with the suggestion `https://<NEBU_SERVER_NAME>` (only when `admin_session_secure` is true and the name is not
  `localhost`; the page says "suggested, not saved yet").
- **D4 (protection = the SSO trust lists).** `Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, "/admin/config")` runs after
  `require_admin` (the instance admin role, `instance_admin` claim or the configured admin group claim) and the Phoenix CSRF
  check and BEFORE anything is validated or written: strict fetch metadata (WebKit: the click proof `_click_proof` of
  `Nebu.Web.ClickProofScript`, a notice page instead of a 403), then a fresh admin re-authentication marker bound to
  `/admin/config`. The marker is consumed after a SUCCESSFUL write only. BOTH directions (on and off) are protected: a script
  that switches OAuth off is an availability attack on every OAuth client; the always-available emergency path is the SQL
  rollback of 07-deployment. The refusal pages, the response headers and the click-proof field are the existing mechanism (no
  third mechanism).
- **D5 (activation acknowledgement).** When the submitted state is "on" and it differs from the stored state (the switch turns
  on, or the issuer changes while it is on), OR when a non-empty issuer is set or changed while the switch stays off (the issuer origin is a
  trusted `redirectUrl` of the legacy SSO login also with OAuth off, Kassandra M-1), the checkbox `oauth_activation_ack` ("I have read the activation checklist ...")
  must be ticked, else a validation error (200 re-render, nothing written, marker kept). The text points at the checklist
  (`docs/architecture/07-deployment.md`, "Activating OAuth"), names the rollback (clear the checkbox, effective on all nodes
  within `NEBU_OAUTH_CONFIG_CACHE_MS`) and says that running OAuth sessions stay valid after switching off until their access
  token expires (at most `oauth_access_token_ttl_seconds`, 1 h), and how to end them (`revoke_all_oauth_sessions`).
  Switching OFF needs no acknowledgement.
- **D6 (no change).** A submission whose normalized values equal the stored values writes nothing, audits nothing, keeps the
  marker and answers a "No change" notice.
- **D7 (audit, atomic).** One `audit_log` row per change: new action `oauth_switch_changed` (`@known_actions`), actor = the
  admin's Matrix id (else the `sub`), `target_type` `server_config`, `target_id` `oauth_enabled`, metadata `enabled_before`,
  `enabled_after`, `issuer_before`, `issuer_after`, `reauth` (`auth_time` | `flow`). The audit row is written INSIDE the
  transaction of the two `server_config` upserts (the F-6 carve-out pattern of the OAuth client decisions): a change is never
  unaudited and an audit row never describes a change that did not happen. Asymmetry on purpose: if the audit insert fails, a
  change that turns the switch ON (or edits the issuer while on) is refused (nothing written, "Failed to save"), a change whose
  RESULT is OFF with the issuer unchanged or cleared (the kill switch) is applied without the audit row (setting or changing an issuer needs its
  audit row, also while off, Kassandra M-1), with a value-free ERROR log
  and a flash that says so ("saved ... but the audit entry could not be written"); the refusal flash says "not saved: the audit entry
  could not be written" (the kill
  switch must never be blocked by an unwritable audit table).
- **D8 (cache).** The server keeps a per-node TTL cache of the switch (`Nebu.OAuth.Config`, `NEBU_OAUTH_CONFIG_CACHE_MS`,
  default 2 s, at most 5 s). After a commit the saving node drops its own cache entry (`Nebu.OAuth.Config.invalidate_cache/0`);
  every other node picks the change up within the TTL (bounded staleness, ADR-033 HY2). A read that started before the commit
  can refill the cache with the old value for at most one TTL: accepted, bounded. The page says so ("takes effect on all
  nodes within N seconds").
- **D9 (status, non-blocking).** The section shows a status list that the server can derive itself, each item with a visible
  word (`OK`, `Attention`, `Note`), never colour only: (1) stored switch and issuer; (2) whether THIS node answers
  `auth_metadata` with 200 right now (`Nebu.OAuth.oauth_aware?/0`), with the propagation note when it differs from the stored
  state; (3) `NEBU_TRUSTED_PROXY_CIDRS` empty: "per-IP limits are global behind a proxy (G3-2); empty is right only when clients
  reach Nebu directly"; (4) the issuer host differs from `NEBU_SERVER_NAME` (it may be right with a `.well-known` delegation);
  (5) `matrix_oidc_refresh_mode` is not `offline` while `oauth_idp_revalidation` is `per_refresh` (the default): sessions would
  fail at their first refresh; (6) `admin_session_secure` is false (the issuer must be https, the binding cookies are `Secure`);
  (7) `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME` is on (dev only). A standing text says honestly that the server cannot see
  the load balancer, the positive client-IP test, the IdP's `auth_time` and the clients, that those and the manual groups
  A-F stay the operator's job, and where the checklist is. None of this blocks saving.
- **D10 (no migration).** `oauth_enabled` and `oauth_issuer_url` are already in the `config_update_mutable` allowlist
  (migrations 000040 / 000042 / 000048) and `Nebu.Admin.DB.upsert_server_config/1` uses the same upsert as the SQL runbook.
- **D11 (the default is untouched).** Nothing in this story sets `oauth_enabled`; an absent key stays "off".
- **D12 (accessibility).** Label on every control, the status list is a plain list with text status words, the validation
  errors are `role="alert"` with `aria-invalid` / `aria-describedby`, the saved notice is the page flash (`role="status"`),
  nothing relies on colour, the section reflows at 320 px (no fixed widths).

## Acceptance Criteria

1. `GET /admin/config` renders the section `#oauth-switch` with the form `#oauth-switch-form` (`method=post`,
   `action=/admin/config/oauth-switch`, the CSRF field, the hidden `_click_proof` with `data-click-proof`, the hidden
   `oauth_enabled=false`, the checkbox `oauth_enabled` value `true` checked iff the stored switch is `true`, the field
   `oauth_issuer_url` with the stored value, the checkbox `oauth_activation_ack`, the button "Save OAuth settings" described
   by the fresh sign-in hint), the status list and the standing honest text. The page is still not frameable (`/admin/config/oauth-switch`
   too) and `no-store`.
2. `POST /admin/config/oauth-switch` runs `gate(conn, :marker, "/admin/config")` before validation: a missing / wrong fetch-metadata
   header (each of the four) answers the `403` "Request refused" page, a missing / stale / foreign-path / foreign-subject marker
   redirects to `Auth.reauth_start_path("/admin/config")`, a WebKit request without the click proof answers the notice page
   (200); in all of these nothing is written, no audit row, the marker is kept; a non-admin is redirected / refused by
   `require_admin` exactly like the other forms.
3. Validation (after the gate): `oauth_enabled` must be `true` / `false`; a non-empty issuer must pass `Nebu.OAuth.normalize_issuer/1`
   plus the form-only rules of D3; enabling needs a valid issuer ("OAuth cannot be switched on without a valid https issuer URL");
   the acknowledgement of D5. An error answers 200, re-renders the page with the SUBMITTED values, the error under the field
   (`role="alert"`, `aria-invalid`, `aria-describedby`), nothing written, nothing audited, the marker kept.
4. A valid change persists `oauth_enabled` (`"true"` / `"false"`) and `oauth_issuer_url` (normalized, `""` when empty) through ONE
   transaction together with the audit row of D7, consumes the marker, drops the local cache entry, flashes "OAuth settings
   saved" (plus the propagation sentence) and redirects to `/admin/config`. The audit-failure asymmetry of D7 holds (tests for
   both directions). "No change" (D6) writes nothing.
5. The status list of D9 is rendered with the right items for the cases: empty trusted-proxy list, issuer host != server name,
   refresh mode not offline with per_refresh, insecure admin session, the re-auth opt-out, node answers 200 vs 404 vs stored
   differs; each item carries its status word; the honest standing text is always present.
6. Round trip: after a save "on" with a valid issuer the live predicate (`Nebu.OAuth.oauth_aware?/0`, hence `auth_metadata`
   200, `/versions` v1.15) is true on the saving node immediately, after a save "off" it is false (integration test against the
   database, `NEBU_OAUTH_CONFIG_CACHE_MS` > 0 so that the cache drop is exercised).
7. Fail-closed lockout checks: a wrong issuer (valid https but not the public host) with the switch on keeps every guard working
   (the runtime still serves only for a valid issuer; an invalid stored issuer is "off"); the kill switch (uncheck + save)
   works while the database and the IdP (the fresh sign-in) are up, otherwise the SQL rollback of 07-deployment applies; the form never writes any other key.
8. `Nebu.Compliance.AuditWriter` knows `oauth_switch_changed` (the audit log page lists every action, it has no action allowlist; the DB
   integration test reads the row back).
9. Documentation: `07-deployment.md` ("OAuth 2.0 Authorization Server Configuration" intro, "Activating OAuth" step 1 "Flip" per Admin
   UI OR SQL, "Manual verification before activation" group D: the checkbox flow in Safari / Firefox / Chrome and on a running
   instance incl. rollback, "Kill switch, caches and rollback"), ADR-033 (a new section "Admin UI switch": decisions D1-D12,
   correction of every "no Admin UI writer" statement), `dev/tls/oauth.sh` comment and `dev/tls/README.md`, `README.md` if it
   says SQL only, arc42 05-building-blocks / 08-concepts where the admin configuration is described, `follow-ups.md` (status
   line, new rows), `docs/security`-style mentions if any.
10. Tests: unit (validation, status), controller (gate order, 403 / redirect / notice, validation errors, persistence, audit,
    audit asymmetry, no-change), Safari cases (click proof, notice), router headers, template / accessibility markup,
    integration (the transaction, the cache drop, the RLS upsert as `nebu_app`), an e2e feature (static check: `bddgen` + `tsc`).

## Out of scope

- Any change of the default of `oauth_enabled` (stays off) and of the runtime predicate (`Nebu.OAuth.Config.live_state/1`).
- Verifying the load balancer, the positive client-IP test or the IdP behaviour: the server cannot see them (D9 says so).
- The sweep of the other admin forms (story `cw`, next) and the SO7 same-origin residual (accepted, SO8 is the fix).
- A UI for the other `oauth_*` keys (`oauth_pending_*`, `oauth_access_token_ttl_seconds`, `oauth_idp_revalidation`): SQL as before.

## Follow-ups recorded by this story

Ids `da` onward (see `follow-ups.md`).
