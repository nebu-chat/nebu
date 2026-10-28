---
story_id: oauth-authorize-freshness
title: "Consent on every authorization, server-owned freshness, fail-closed account freshness, missing-IdP-RT detection, serialized IdP refresh, null cross-signing keys (gates i, y, E-2, l, n, ak(1))"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: true
created: 2026-10-12
branch: feature/migrate-to-oauth2
---

## Summary

Phase-2 story P3 of epic `oauth-broker`: closes `follow-ups.md` gates **i**, **y**, **E-2** ("(i)/(y)
sharpened"), **l**, **n**, **ak(1)** (+ ak(2)/(3), story-2 (b)). Today `Authorize.issue_code/5`
(`authorize.ex` ~l.365) mints the code right after `provision_login_user/1`: no freshness, consent or
device-holder check, and `auth_time` falls back to `iat`. Dex (`v2.45.1`) reportedly omits `auth_time`
and ignores `max_age` (oracle O5), so `login_required` on unproven freshness would lock Dex users out,
and freshness alone does not stop E-2 (a user who logs in after following the link still authorizes
the attacker's app). Fix: a **server-rendered consent screen on every authorization** before any code;
freshness feeds the consent text, the stored `auth_time` (raw only) and the account page (fail closed).
`oauth_enabled` stays OFF. Migration **000045** (000044 = P2; re-check). No config key, no metadata change.

## Story

As a **Matrix user signing in with an OAuth app**, I want Nebu to show which app asks, where I return
and which session is created or replaced, and to issue nothing until I click Allow, so that no link or
silent IdP session hands my account or a device to an app.

## Decisions

Prefix `FR` (no collision with D/T/R/C/A/V/TP/AH). ADR-033 gets FR1-FR21 (AC17); FR21 was added by review cycle 1.

- **FR1 Consent on EVERY authorization (safe variant).** Always shown after the verified IdP login and
  provisioning; no remembered grants, no skip, not even with a fresh `auth_time`. Why: RFC 6749 10.2 /
  RFC 8252 8.6 (no automatic processing for clients the AS cannot authenticate; all Matrix clients are
  public, loopback/private-use redirects are unattributable); a fresh IdP login proves presence, not
  which app (the IdP page names only Nebu); Matrix v1.15 "Scope" encourages consent; remembered grants
  need a table plus a lifecycle (P4 revocation, scope changes), each a fail-open risk. Cost: one click
  per interactive login (refreshes never use authorize). Supersedes **D5** and **A26**; remembered
  consent = follow-up ap.
- **FR2 Freshness helper.** A new pure module `Nebu.OAuth.Freshness`, extracted from `account.ex`
  `freshness/2` (~l.611). `auth_time(claims)` reads the `auth_time` claim ONLY (integer; a float is
  truncated; everything else, including `iat`, counts as absent). `evaluate(t, requested_at)` returns
  `{:fresh, min(t, now)}` when `t >= requested_at - @skew_seconds` (constant 60), `{:stale, t}` when
  older, and `:absent`. It never logs and never raises.
- **FR3 No `login_required` for unproven freshness.** At the authorize callback, absent or stale
  freshness does not end the flow. It sets `login_fresh = false` and shows a notice (FR9). FR1
  guarantees that no code exists without the user's click: this takes E-2's "or a consent screen"
  alternative, default on, with no way to switch it off. `login_required` remains for `prompt=none`
  only (D11), answered before the IdP and before consent. A client `max_age` stays ignored (D12, oracle
  correction 7): the id_token then may carry no `auth_time` (FR4); clients must not rely on it.
- **FR4 Stored `auth_time` = the raw claim or NULL.** On the OAuth path, `oauth_codes.auth_time`, and
  through it `matrix_sessions.auth_time` and the id_token `auth_time`, is `Freshness.auth_time(claims)`
  (clamped) or NULL. It is never `iat` and never the consent time. `id_token.ex` already omits nil.
  `provision_login_user/1` keeps its legacy return value; authorize ignores that field.
- **FR5 Callback order.** Unchanged up to `idp_complete_login/4`: bucket, live, state, consume,
  binding, `recheck_client`, IdP error, verifier, IdP login. Then: (a) gate l (FR13), before any side
  effect; (b) `provision_login_user/1` (deactivated => `access_denied`); (c) freshness; (d) device holder
  (FR11); (e) encrypt the IdP RT; (f) consent row INSERT (FR6); (g) `303 Location: /oauth2/consent` with
  the cookie. `CodeStore.insert` moves to Allow. Every failure after the consume is the existing RFC 6749
  error redirect, built from the consumed row only.
- **FR6 Consent state.** Table `oauth_consent_requests`, PK `binding_hash` (SHA-256 hex of the 256-bit
  cookie). Columns: every `CodeStore.insert` input (`client_id`, `redirect_uri`, `code_challenge`,
  `device_id`, `user_id`, `scope`, `scope_prefix`, `response_mode`, `client_state`, `client_nonce`,
  `openid_requested`, `idp_rt_enc` SecretBox, `auth_time` NULL-able), plus `login_fresh`, `created_at`,
  `expires_at` (CHECK at most 5 min). A soft cap of 10 000 live rows sits inside the INSERT
  (`AuthzStore` pattern) => `temporarily_unavailable`. Consumption is ONE `DELETE ... WHERE binding_hash
  = $1 RETURNING ..., (expires_at > now()) AS live`. Purged by `OAuthFlowPurgeWorker`. Module
  `Nebu.OAuth.ConsentStore`.
- **FR7 Routes (PRG).** `GET /oauth2/consent` renders from the live row (no mutation, reload-safe);
  `POST /oauth2/consent` (`csrf_token`, `decision=allow|deny`); other methods => `405` page (`Allow: GET,
  POST`), sub-paths => `404`. Live check first (`:off` => `404` page, `:unknown` => `503`), before the bucket
  `{"oauth_consent", ip}` (600/h, `Nebu.Web.ClientIP.get/1` once P1 landed) and any DB access. No CORS
  (`router.ex` `cors/2` like `/account`); `JsonBody` skips `["oauth2","consent"]` (`FormPost.parse/1`).
- **FR8 Binding and CSRF.** Cookie `__Host-nebu_oauth_consent` (`Path=/; Secure`) on https, else
  `nebu_oauth_consent` (`Path=/oauth2/consent`); `HttpOnly; SameSite=Lax; Max-Age=300` (Strict would not be
  sent on the `303` after the IdP's cross-site chain). One consent per browser (a second flow overwrites;
  the first Allow => `invalid_state`). CSRF token = `base64url(SHA-256("nebu-oauth-consent-csrf:" <>
  cookie))`, constant-time compare, nothing stored. POST order, all BEFORE consumption: `FormPost.parse/1`;
  `Origin` (absent, issuer origin, or `null` only with `Sec-Fetch-Site: same-origin`); `Sec-Fetch-Site`
  (absent / `same-origin`); `Sec-Fetch-Mode`/`-Dest`/`-User` (absent / `navigate`/`document`/`?1`); cookie;
  token. Failure => `403` page `forbidden`, nothing consumed, one value-free WARNING. The Origin/navigation
  checks move from `account.ex` (~l.686-713) into `Nebu.OAuth.BrowserPost` (one copy).
- **FR9 Page content** (`Nebu.OAuth.ConsentPage`, every value `Plug.HTML.html_escape/1`d): the signed-in
  `user_id`; "App name (claimed by the app)" (`client_name` / "No name given"); "App website (claimed by
  the app, approved by your administrator)" (`client_uri` host / "None given"); "Terms of service" /
  "Privacy policy" (claimed by the app): DCR `tos_uri`/`policy_uri` as escaped PLAIN TEXT, no link
  (correction 3), omitted when absent; "After you choose, you are sent to": the https host + "(part of the
  app website)" when it is the `client_uri` host or a subdomain, "an app on this device (localhost, port
  N)" for loopback, "an app on this device (`<scheme>:`)" for a private-use scheme, the last two + "Nebu
  cannot check which app on your device receives this."; the session line (FR11); "Full access to your
  account: read and send messages, and manage your rooms, devices and encryption keys."; if `login_fresh
  = false`: "You were not asked to sign in again. Your sign-in provider did not confirm a new sign-in for
  this request. If you did not just start signing in to this app yourself, choose Deny."; always: "Only
  allow this if you just started signing in to this app yourself." One form, two `<button type="submit"
  name="decision">` (`allow` "Allow", `deny` "Deny"), equal weight, no autofocus, no logo, no links, no
  script.
- **FR10 Headers.** `no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, `Referrer-Policy:
  same-origin` (`no-referrer` would make `Origin: null`), no CORS. CSP: `default-src 'none';
  style-src 'sha256-<css>'; img-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'
  <target>`. Chromium applies `form-action` to the redirect that follows a form POST, so `<target>` is
  the row's redirect target: the https origin `https://host[:port]`; for a LOOPBACK redirect
  (`localhost`, `127.0.0.1`, `[::1]`) NO host source but the scheme source `http:` (an IPv6 literal is
  not a valid CSP host-source; oracle correction 4); for a private-use scheme the scheme source
  `<scheme>:`. The scheme is lowercased first (correction 8); built only from parsed components (scheme
  `[a-z][a-z0-9+.-]*`, host `[a-z0-9.-]+`, numeric port). If it cannot be built, the answer is the
  `server_error` page with nothing consumed.
- **FR11 Device holder.** New facade `Nebu.Matrix.oauth_device_holder(user_id, device_id)` => `{:ok,
  :none}` | `{:ok, %{display_name, last_seen_ts, auth_api, client_id}}` (newest live session, nil when none)
  | `{:error, :unavailable}` (one-row variant of `AccountManagement.devices/1`). Cases: `:none` => "A new
  session (device `ID`) will be created."; same app => "Continues your existing session NAME (device ID),
  last active DATE."; legacy or no live session => "Replaces your existing session NAME (device ID), last
  active DATE, signed in without this app. That session will be signed out." (`data-device="replace"`);
  a live OAuth session of ANOTHER app => **refused**: no row, `403` page `device_in_use` ("This app asked
  to take over a session that another app is using. This is not allowed. Close this window and start
  signing in again from your app."), no `Location`, no `state`/`iss`. A **Nebu policy stricter than the
  spec** ("Relationship between access tokens and devices"), reason RFC 9700 4.11 / RFC 6749 10.12, not
  the "Device ID allocation" MAY (length/charset only); recorded in ADR-033 (correction 1).
  **Same app (correction 2):** clients re-register via DCR, so `client_id` can change; same app = equal
  `client_id` OR equal deduped identity = normalized `client_uri` (lowercase scheme/host, default port and
  trailing `/` dropped) + the SORTED, de-duplicated `redirect_uris` (new `ClientStore.client_identity/1`,
  one query; no `client_uri` => only an equal `client_id` counts). A re-registration of the same app is
  not refused. Re-checked at Allow. `:unavailable` => `temporarily_unavailable` redirect at the callback,
  `503` page at Allow.
- **FR12 POST outcomes.** No live row => `400` page `invalid_state`. The cookie is cleared except on
  429; the page says "Close this window and start signing in again from your app" (correction 11).
  Both decisions redirect with **`303 See Other`** (never 302/307, correction 6). `deny` =>
  `access_denied` (fixed description, `state`, `iss`). `allow` => client still
  `approved` (else the `403 client_rejected` page; P4's `revoked` counts as rejected), then FR11 again,
  then `CodeStore.insert`, then `303` with `code`, `state`, `iss` in the row's `response_mode`. Every
  `error_description` is fixed ASCII without `"` or `\`. A failed
  INSERT => `server_error` redirect.
- **FR13 Gate l.** With `Config.token_settings().idp_revalidation == :per_refresh` and no IdP RT (nil or
  ""): before provisioning, a `server_error` redirect (the fixed ASCII description "The server
  encountered an unexpected error.", no config detail; correction 12) and nothing persisted. One WARNING per node per
  10 min, throttled with `RateLimit.take({"oauth_config_warning", :no_idp_rt}, ...)` (the
  `Config.warn/2` pattern): "OAuth: oauth_idp_revalidation is per_refresh but the IdP returned no
  refresh token; OAuth logins are refused. Set matrix_oidc_refresh_mode=offline and let the IdP issue
  refresh tokens, or set oauth_idp_revalidation=off." No claims, no tokens; visible in the admin log
  viewer. T6 at the token endpoint stays. An unreadable config parses as `per_refresh` (fail closed).
- **FR14 Gate y, account fail closed.** `sign_in/3` uses `Freshness`: `:absent` => session `auth_time
  NULL` (never fresh; WARNING throttled 1/h per node instead of per login with the callback time);
  `{:stale,_}` => `403 reauth_failed` (unchanged). On a NULL session the delete and reset pages show notice
  `freshness_unavailable` ("Your sign-in provider does not report when you last signed in, so Nebu cannot
  confirm it is you. Signing out devices and approving key resets are not available here. Ask your
  administrator.") WITHOUT a reauth link (no loop); the destructive POSTs `303` with it, changing nothing;
  viewing works. Without IdP `auth_time`, OAuth users cannot delete devices / approve resets (aq).
- **FR15 Gate n: per-device IdP refresh lease, not an advisory lock** (an xact lock would hold a pool
  connection + transaction across the IdP call: pool exhaustion on a slow IdP). Table
  `oauth_idp_refresh_leases (user_id, device_id, holder, acquired_at, lease_until)`, PK `(user_id,
  device_id)`, FK `devices` CASCADE, CHECK `lease_until <= acquired_at + 120 s`; `per_refresh` only. Claim:
  `INSERT ... ON CONFLICT DO UPDATE ... WHERE oauth_idp_refresh_leases.lease_until <= now() RETURNING
  holder` (128-bit hex holder; TTL `@idp_lease_seconds` = IdP HTTP timeout + 5 s, >= 20 s). Holder:
  re-validate, rotate, release (`DELETE ... WHERE holder = $3` in `after`). Others: poll every 100 ms, at
  most `@idp_lease_wait_ms 5000` (test seam `:oauth_idp_lease_wait_ms`), re-resolving the RT: changed
  active row => `lost_race_replay/2` path, no IdP call; `{:reused,_}` while waiting => `{:unavailable, 2}`,
  NEVER revocation/`invalid_grant` (correction 5; a later request goes through T11); free lease => claim;
  budget exhausted => `{:unavailable, 2}` (`503 {}`, `Retry-After: 2`); lease SQL error =>
  `{:unavailable, 5}`. T28 stays for an expired lease; `:off` takes no lease; the IdP never sees two
  redemptions of one RT.
- **FR16 ak(1)-(3).** (1) `do_device_signing_upload/1` (`protected.ex` ~l.2280) normalizes the keys
  BEFORE guard, digest and merge, for every caller: an explicit `null` key is dropped (absent); a
  non-object value => `400 M_BAD_JSON` "Invalid cross-signing key". Nebu choice (oracle correction 9):
  a body that is `{}` or all-null after normalization while a master is stored => `400 M_MISSING_PARAM`
  without UIA for EVERY caller (legacy today answers 403). The "unchanged" rule compares the supplied
  keys only, after normalization: `{"master_key": stored, "self_signing_key": null}` => `200 {}`, no UIA. (2) `replace_with_approval/8` re-reads the keys INSIDE the
  transaction, after consuming the approval, via a new error-aware `CrossSigningKeyStore.get_keys_for_
  update/1` (`FOR UPDATE`, `{:ok, map} | {:error, _}` => rollback => 500). (3) Fix the `account.ex`
  moduledoc (~l.40-46): the `Origin: null` + `Sec-Fetch-Site: same-origin` fallback and the navigation
  check, which stops fetch/XHR but not a scripted `form.submit()` (gate ag).
- **FR17 Logging.** INFO `OAuth callback: consent requested client_id= user_id= device_id= fresh=
  device=` and `OAuth consent: allowed|denied|refused ...`; never cookie, CSRF, code, state, nonce,
  verifier, claims, names, redirect URI. `/oauth2/consent` joins `@names_only_query_paths`; body never captured.
- **FR18 No leak.** The client sees only `code` or a fixed-description `access_denied` /
  `server_error` / `temporarily_unavailable`. `device_in_use`, `invalid_state`, `forbidden` and
  `client_rejected` are user pages, never redirects.
- **FR19 Migration 000045 `oauth_consent_and_refresh_leases`.** (a) `oauth_consent_requests` (CHECKs
  hex64, `scope_prefix`, `response_mode IN ('query','fragment')`, TTL; FK `oauth_clients` CASCADE; index
  `expires_at`; `GRANT SELECT, INSERT, DELETE` + `REVOKE UPDATE`; ENABLE + FORCE RLS, 000043 policies);
  (b) `oauth_idp_refresh_leases` (four grants/policies, FORCE RLS); (c) `oauth_account_sessions.auth_time
  DROP NOT NULL`. Down: drop (a)(b), delete NULL sessions, `SET NOT NULL`. No `config_update_mutable` change.
- **FR20 ADR-020.** New facade `oauth_device_holder/2`. The lease lives in the Matrix domain
  (`OAuthSession`, `OAuthSessionStore`); `get_keys_for_update/1` is Matrix-internal.

- **FR21 Double clickjacking (review cycle 1, Kassandra M-1; changes the "no script" part of FR9/AC3).** The
  page carries exactly ONE inline script pinned by CSP `script-src 'sha256-...'` (no `'unsafe-inline'`).
  Allow is rendered `disabled` and enabled only after real interaction (pointer move of >= 4 px from the
  first position, key press, wheel or scroll) AND >= 600 ms after load; Deny is never disabled and comes
  first in DOM and visual order; without JavaScript Allow stays disabled (fail closed, documented in ADR-033
  and 07-deployment); `Cross-Origin-Opener-Policy: same-origin`. The server never trusts the button state.
  Other review-cycle-1 changes: lease TTL 60 s (M1); the UIA-free first-upload branch uses the locked
  error-aware read (M2 / L-4); per-user (5) and per-source (20) consent caps (L-2); the device holder is
  re-checked at redemption under the devices lock (L-1, follow-up ay resolved); the website line says "not
  verified by Nebu", an https destination outside the claimed website gets a warning and "part of the app
  website" needs a real registrable name (L-5); UX advisories A1-A10 (see the Dev Agent Record).

## Acceptance Criteria

### AC1 No code without consent (FR1, FR5)
1. Every successful callback (fresh / stale / absent `auth_time`; new / same-client / legacy device)
   answers `303 /oauth2/consent` + cookie, with no `code`, no client redirect, no `oauth_codes` row and
   one consent row.
2. A static test checks that `CodeStore.insert` is called only from the consent module.
3. Deactivated user, IdP error, missing code and verification failure behave as before (story 2).

### AC2 Freshness (FR2, FR4)
1. Unit table: int, float, string, nil, missing, `iat`-only; `requested_at - 60` is fresh and `- 61`
   stale; a future value is clamped.
2. A code minted via consent stores the raw claim or NULL. Its id_token omits `auth_time` when NULL;
   `matrix_sessions.auth_time` is NULL.

### AC3 Page content and a11y (FR9, FR11)
1. Contract: `<main data-page="oauth-consent" data-device=... data-fresh=...>`, `lang="en"`, a static
   `<title>`, one `<h1>` "Allow this app to use your Matrix account?", a `<dl>`, two submit buttons, and
   exactly ONE hash-pinned inline script (FR21), no other `<script>`, no `<img>`, `autofocus` or inline handlers;
   Deny first and Allow `disabled` until armed; COOP `same-origin`; CSP `script-src` is that one hash.
2. All FR9/FR11 texts appear (incl. `tos_uri`/`policy_uri` as plain text, never `<a>`). Hostile
   `client_name`, `display_name`, device id and `tos_uri` values (`<script>`, `"`, `&`) are escaped.
3. The notice appears exactly when `login_fresh = false`. e2e: axe clean, no horizontal scroll at 320 px.

### AC4 Headers (FR10)
1. FR10 headers on GET. CSP `form-action`: `'self' https://host[:port]` for https; `'self' http:` and NO
   host source for `http://localhost:p`, `http://127.0.0.1:p` and `http://[::1]:p` (test asserts no
   `[::1]` in the CSP); `'self' <scheme>:` for a private-use scheme, also with an upper-case scheme
   (lowercased); `frame-ancestors 'none'`; CSS hash matches; no `access-control-*`.
2. A redirect URI failing the source check (test row with `;` or a space) gives the `server_error`
   page, the row stays, no code.

### AC5 Allow (FR12)
1. `303` (never 302/307) to the row URI with `code`, `state` (present and absent cases) and `iss`
   byte-equal to the metadata `issuer`: in the query (`&code=` when the registered URI has a query) or
   the fragment; for an https, a private-use, a `127.0.0.1:p`, a `localhost:p` and a `[::1]:p` URI. The code redeems (story-3 flow incl. the id_token
   `nonce`).
2. The row is gone and the cookie cleared. A repeated POST gives `400 invalid_state` and no second code.
3. A client no longer approved gives the `403 client_rejected` page and no code.

### AC6 Deny
A `303` with `error=access_denied`, the fixed ASCII description (no `"`/`\`), `state` and `iss`, no
`code`, no `errcode`, in both modes incl. a registered URI with a query. No code row, no session.

### AC7 CSRF / binding / fetch metadata (FR8)
Each of these gives `403 forbidden` (or `400 invalid_state` for the cookie cases) with the row intact
and no code: a missing/wrong token; a missing or foreign cookie; `Origin: https://evil.example`;
`Origin: null` without `Sec-Fetch-Site: same-origin`; `Sec-Fetch-Site: cross-site|same-site`;
`Sec-Fetch-Mode: cors`; `Sec-Fetch-Dest: empty`. A malformed or duplicated body, a non-form content
type, an unknown `decision` or a query string gives `400 invalid_request`, nothing consumed.

### AC8 Lifetime, cap, purge, concurrency
A row older than 5 min gives `invalid_state` (GET and POST). At the cap, `temporarily_unavailable`. The
purge worker removes expired rows (its result gains `consents:`). Two concurrent Allows give exactly one
code and one `invalid_state`.

### AC9 Device takeover (FR11)
The holder cases `:none`, same `client_id`, a DCR re-registration of the same app (different
`client_id`, same normalized `client_uri` + redirect set: `data-device="same_client"`, not refused),
legacy (after Allow and the exchange, the legacy token is
rejected; T7/T26) and no live session each pass. Another app (other `client_uri` OR other redirect set) gives `403
device_in_use` at the callback (no row, no `Location`, no `state`/`iss` in the body, the close-window
text, no code), and the same holder change made between GET and Allow is
refused at Allow (row consumed, no code). `:unavailable` gives a `temporarily_unavailable` redirect.

### AC10 Gate l (FR13)
With `per_refresh` and an IdP RT of nil or "": a `server_error` redirect (`state`, `iss`, the fixed
description, no config words), no `users`
row for a new `sub`, and no consent or code row. Two callbacks produce one WARNING (skip the count
assertion under `NEBU_RATE_LIMIT_DISABLED`); it has no token or claim. With `off`, the flow reaches
consent.

### AC11 Gate y (FR14)
1. No `auth_time` gives a session with `auth_time IS NULL` and a throttled WARNING.
2. On it, the delete and reset pages show `freshness_unavailable` without a reauth link. The
   delete/approve/decline POSTs answer `303` with the notice; the device, its tokens and the pending
   UIA survive.
3. The fresh and stale paths are unchanged (story-6 regression). The migration down/up round trip
   passes.

### AC12 Gate n (FR15), integration
1. A rotating IdP stub with a barrier: the first call with X blocks, then returns Y; later calls with X
   return `{:token_endpoint_status, 400}`. Two parallel refreshes of one Nebu RT result in one IdP call,
   both `200`, the session alive, the final AT working on `/whoami`, and a later refresh succeeding.
2. With the wait seam at 200 ms and the holder blocked: the second answers `503 {}` + `Retry-After: 2`
   (body exactly `{}`, no `error` member, never 429/`invalid_grant`); a retry after release is a replay
   without an IdP call. A follower always gets the replay, never `{:reused, _}` handling or revocation.
   A follower that sees `{:reused,_}` while waiting (a third refresh used the successor) gets 503 and the
   session survives.
3. A stale lease (`lease_until` in the past) does not block. A genuine single IdP rejection still
   revokes. `:off` creates no lease. A device delete cascades the lease.
4. The T28 tests (`oauth_token_refresh_grant_test.exs` ~l.540-630) nest a refresh inside the IdP stub,
   which now gets 503. Rewrite them; prove the T28 rules through an expired lease set by the stub.

### AC13 Cross-signing (FR16)
1. An approved OAuth `{"master_key": null}` (or all-null) gives `400 M_MISSING_PARAM`, with the keys
   unchanged and the approval not consumed. `{"master_key": new, "self_signing_key": null}` merges
   master-only and keeps the SSK. `{"master_key": stored, "self_signing_key": null}` gives `200 {}`
   without UIA. `{}` / all-null with a stored master gives `400 M_MISSING_PARAM` for legacy AND OAuth
   (pinned Nebu choice).
2. A string, list or number key gives `400 M_BAD_JSON` (legacy and OAuth). A first upload with a null
   SSK stores the others.
3. The merge base is read `FOR UPDATE` inside the transaction; a failing locked read gives a 500 with
   the approval not consumed.
4. A static test pins the moduledoc text.

### AC14 Logging (FR17)
`CaptureLog` over authorize, callback, GET, Allow/Deny and the refresh race contains no cookie, CSRF,
code, state, nonce, verifier, display or client name, redirect URI or IdP RT. `RequestLogger` logs
`/oauth2/consent` with names only and no body.

### AC15 Kill switch, rate limit, routing
OAuth off gives a `404` page on GET and POST before any bucket or DB access; an unreadable config gives
`503`. The bucket gives a `429` page with `Retry-After`, the cookie kept and nothing consumed.
`OPTIONS` gives `405` with no CORS; `/oauth2/consent/x` gives `404`. Metadata, `/versions` and the
conformance contract are unchanged.

### AC16 Regression
Green: authorize validation D10-D14 (`response_mode=form_post` gives `invalid_request` in the default
mode, without the IdP and without a code; `prompt=none` gives `login_required` before the IdP and
without consent; a client `max_age` is ignored); story-2 pages; story-3
T6/T19/T26 (T28 per AC12.4); story-4; story-5; story-6 (fresh path, `m.oauth`, CSRF). Tests that
reached a code via `finish_flow`/`flow_code!` now go through consent.

### AC17 Documentation
The "Doc edits" below are made, and the `adr_033_test.exs` pins are updated.

### AC18 Tests and e2e
The suites below are green in the isolated env. The new and updated features pass `tsc --noEmit` and
`bddgen --tags "@oauth-authorize or @oauth-account or @oauth-consent"`.

## Acceptance Tests

New (`server/test/nebu/oauth/`): `oauth_freshness_test.exs` (AC2.1), `oauth_consent_page_test.exs`
(AC3, AC4 incl. CSP source builder), `oauth_consent_flow_test.exs` (AC1, AC2.2, AC5, AC6, AC8, AC9,
AC15), `oauth_consent_csrf_test.exs` (AC7), `oauth_refresh_lease_test.exs` (AC12),
`oauth_consent_logging_test.exs` (AC14). Updated: `oauth_idp_callback_test.exs` (consent, AC10),
`oauth_account_test.exs` + `oauth_account_hardening_test.exs` (AC11), `oauth_token_refresh_grant_test.exs`
(AC12.4), `oauth_account_cross_signing_test.exs` (AC13), `oauth_request_logger_redaction_test.exs`,
`adr_033_test.exs` (AC17).

Seams (test support, ATDD role): `finish_flow/3` returns the `303`; new `consent!(conn_or_cookies,
decision, opts)` (GET + POST with cookie, CSRF, fetch-metadata headers); `flow_code!/4` = `finish_flow` +
`consent!(:allow)`; `rotating_idp_with_barrier/1` on `stub_idp_refresh/1`; seam `:oauth_idp_lease_wait_ms`;
absent `auth_time` = claims without the key.

### Gherkin: new `e2e/features/oauth/oauth-consent.feature` (real Dex)

```gherkin
Feature: OAuth consent screen
  As a Matrix user I want to decide myself which app gets my account
  So that no link and no silent sign-in hands my account or a device to an app

  Background:
    Given OAuth is enabled with an https issuer
    And an approved web client "e2e-oauth-consent-web" named "Consent Test App" with client URI "https://app.e2e.example" and redirect URI "https://app.e2e.example/cb"

  @oauth-consent @ac1 @ac3 @ac5
  Scenario: Allowing the app ends at the client with a code
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSNEW1"
    And the user signs in at the IdP
    Then the consent page names the app "Consent Test App" as claimed by the app
    And the consent page names the website "app.e2e.example"
    And the consent page says a new session "E2ECONSNEW1" will be created
    And the page has exactly one level-1 heading
    And the consent page has one hash-pinned script and Allow starts disabled
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    When the user allows the app
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"
    And the redirect query has the request's "state"
    And the redirect query has "iss" = the Nebu issuer

  @oauth-consent @ac6
  Scenario: Denying the app sends access_denied and no code
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "fragment" and device "E2ECONSNEW2"
    And the user signs in at the IdP
    And the user denies the app
    Then the redirect fragment has "error" = "access_denied"
    And the redirect fragment has the request's "state"
    And the redirect fragment has no "code"

  @oauth-consent @ac9
  Scenario: Replacing a legacy session is announced and signs that session out
    Given the test user has a legacy session on device "E2ECONSLEG1"
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSLEG1"
    And the user signs in at the IdP
    Then the consent page says the existing session "E2ECONSLEG1" will be replaced and signed out
    When the user allows the app
    And the client exchanges the code
    Then the legacy access token of device "E2ECONSLEG1" is rejected

  @oauth-consent @ac9
  Scenario: A device used by another app cannot be taken over
    Given an approved native client "e2e-oauth-consent-other" with redirect URI "http://localhost/cb"
    And the test user has an OAuth session on device "E2ECONSOTH1" through "e2e-oauth-consent-other"
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSOTH1"
    And the user signs in at the IdP
    Then the page is marked as OAuth error "device_in_use"
    And the browser is not redirected to "https://app.e2e.example/cb"
    And the access token of device "E2ECONSOTH1" still works

  @oauth-consent @ac4 @ac8
  Scenario: The consent page cannot be framed, survives a reload and is single use
    Given the consent page for "e2e-oauth-consent-web" is shown
    Then the response has the header "x-frame-options" = "DENY"
    And the response has a Content-Security-Policy containing "frame-ancestors 'none'"
    When the browser reloads the page
    Then the consent page is shown
    When the user allows the app
    And the same consent form is posted again
    Then the page is marked as OAuth error "invalid_state"

```

Updates to existing e2e: `oauth-authorize.feature` happy paths + `And the user allows the app`;
`oauth-account-management.steps.ts` APIRequestContext client follows the `303` and POSTs Allow (cookie,
CSRF, `Origin`); `@ac2-freshness` asserts fresh OR (NULL + `freshness_unavailable`, no delete control),
never absent-but-fresh; fresh-session scenarios (`@ac7`, `@ac8`/`@ac9`) start with `Given the IdP reports
the sign-in time` (`$test.skip()` + `gate-y` annotation when Dex sent none); the After hook deletes the
e2e clients' consent rows.

## Oracle gate (2026-10-12: 0 BLOCKER, 5 MAJOR, 7 MINOR; `step-results/oauth-authorize-freshness/oracle-context.md`)

| # | Correction | Applied in |
|---|---|---|
| 1 MAJOR | cross-client refusal = recorded Nebu policy (RFC 9700 4.11 / RFC 6749 10.12), not "MAY reject" | FR11, ADR edit, open question 3 |
| 2 MAJOR | "same client" robust against DCR re-registration | FR11: deduped identity = normalized `client_uri` + sorted `redirect_uris` (`ClientStore.client_identity/1`); AC9 |
| 3 MAJOR | show `tos_uri` / `policy_uri` | FR9 escaped plain text, no link; AC3.2 |
| 4 MAJOR | `[::1]` is no valid host-source | FR10: loopback => scheme source `http:` only, no host source; AC4.1 test |
| 5 MAJOR | `{:reused,_}` while waiting must not revoke | FR15: 503, never revoke; AC12.2 |
| 6 MINOR | `303` after POST | FR12, AC5.1, AC6 |
| 7 MINOR | client `max_age` | FR3: ignored (D12), id_token may lack `auth_time`; AC16 |
| 8 MINOR | lowercase scheme for CSP | FR10, AC4.1 |
| 9 MINOR | pin `{}`/all-null with stored master | FR16: `400 M_MISSING_PARAM` without UIA for every caller; supplied-only compare; AC13.1 |
| 10 MINOR | scripted parallel refreshes | Manual verification 5 |
| 11 MINOR | pages say "close the window, restart in the app" | FR11, FR12 |
| 12 MINOR | gate l fixed ASCII description | FR13, AC10 |

Extra gate test obligations: folded into AC4-AC6, AC9, AC12, AC16.

## Manual verification

Fail closed in code; verify before `oauth_enabled`, record in the Dev Agent Record:
1. **Dex v2.45.1:** is `auth_time` in the id_token? Is there a re-prompt on `max_age=0`/`prompt=login`
   (two logins in one browser)? If `auth_time` is absent, the consent notice must show and `/account`
   delete/reset must show `freshness_unavailable`.
2. **An IdP that emits `auth_time`** (Keycloak): no notice, and `/account` destructive actions work
   after reauth.
3. **Element Web** (Chrome, Firefox, Safari): login through consent; the `form-action` CSP must not
   block the post-Allow redirect; reload and back button behave per FR7/FR12.
4. **FluffyChat** (Android Custom Tab, iOS ASWebAuthenticationSession): the POST, then a 302 to the
   private-use scheme, reaches the app.
5. **Refresh race, scripted:** a script fires two parallel `POST /oauth2/token` refreshes of one RT
   (`per_refresh`) against Dex (`refreshTokens.reuseInterval`) and against an IdP with reuse detection:
   no logout, one IdP redemption; then two Element tabs as a smoke test.
6. `per_refresh` with an IdP client that issues no RT: `server_error`, and one WARNING in the admin log
   viewer.
7. Cross-origin iframe of the consent page blocked; screen-reader pass.

## Dev Notes

### Current state
Pointers are in the FRs. Also: `AuthzStore` `@sql_consume` (~l.44) lacks `created_at` (add `extract(epoch
FROM created_at)::bigint`); `AccountStore.create_session/1` must accept nil `auth_time`; `pages.ex` has
`form-action 'none'`, so the consent page is a NEW renderer (Pages gains codes `device_in_use`, `forbidden`).

### Files to create / modify
Create: `server/lib/nebu/oauth/{freshness,consent,consent_store,consent_page,browser_post}.ex`, migration
`000045_oauth_consent_and_refresh_leases.{up,down}.sql`, the tests above, `e2e/features/oauth/oauth-consent.feature`
+ `e2e/step-definitions/oauth/oauth-consent.steps.ts`. Modify: `oauth/{authorize,authz_store,account,
account_pages,account_store,pages,http,client_store}.ex` (`client_identity/1`), `oauth.ex`,
`workers/oauth_flow_purge_worker.ex`, `web/router.ex` (forward + `cors/2`), `web/plugs/{json_body,
request_logger}.ex`, `matrix.ex` (`oauth_device_holder/2`), `matrix/account_management.ex` or
`matrix/session/oauth_session_store.ex` (holder + lease SQL), `matrix/oauth_session.ex`,
`matrix/cross_signing_key_store.ex`, `web/router/protected.ex`, test support, e2e steps.

### What must be preserved
- Redirect targets come only from consumed rows.
- D4 binding; atomic single use; `iss` on every response; kill switch before the bucket.
- T6/T19/T26/T28; the story-6 CSRF behaviour (now one copy).
- `provision_login_user/1`'s return value.
- The legacy `m.login.sso` login has no consent (an accepted risk until legacy shutdown).

### Traps
1. Chromium enforces `form-action` on the post-submit redirect (FR10). 2. `no-referrer` makes `Origin:
null`. 3. Strict cookie not sent on the post-IdP `303`. 4. Never mint from `provision_login_user/1`'s
`auth_time`. 5. Gate l before provisioning. 6. No lease/transaction across the IdP call; release in
`after`; re-resolve the RT while waiting. 7. Rewrite (not delete) the T28 nested-refresh tests. 8.
`get_keys/1` errors look like "no master". 9. `NEBU_RATE_LIMIT_DISABLED` disables the warning
throttles. 10. `__Host-` needs `Path=/` + `Secure`. 11. P4 must delete consent rows of revoked clients.

### Architecture compliance
ADR-018/019/020 (FR20)/021/022, OIDC Scopes Law (no scope added), logging law (FR17), cluster safety
(FR6/FR15). Out of scope: ap, ag/E-3 (P4), j, client `prompt=consent|login` (D12), t.

### Doc edits (made by the dev, AC17; NOT in story creation)
- **ADR-033:** new section "Consent, freshness and refresh serialization (story oauth-authorize-freshness)"
  with FR1-FR20; D5 and A26 "Superseded by FR1" (A26: "/FR14"); A7 "absent `auth_time` => session
  `auth_time` NULL, never fresh (FR14)"; T28 "extended by FR15; remains for an expired lease"; story-3
  `auth_time` "raw claim or NULL, never `iat` (FR4)"; gate list: i, y, l, n, ak(1) closed; accepted risk:
  legacy `m.login.sso` has no consent; Nebu policy (correction 1): a device id held by another app
  (deduped identity) is refused, stricter than the spec, reason RFC 9700 4.11 / RFC 6749 10.12.
- **follow-ups.md:** rows i, y, l, n, "(i)/(y) sharpened": prefix the Gate cell "**RESOLVED by
  oauth-authorize-freshness (FR1-FR3 / FR14 / FR13 / FR15)**"; ak: "(1)-(3) RESOLVED (FR16); (4) open";
  story-2 (b) "RESOLVED (FR1)"; story-6 "(b) / (i)" "closed by FR1/FR14". New section "From story
  oauth-authorize-freshness (2026-10-12)": **ao** `persist_single/3` rewrites all three columns from an
  unlocked read and can revert an approved replacement (own-column compare-and-set; non-gating);
  **ap** optional remembered consent (non-gating); **aq** release note: without IdP `auth_time` OAuth
  users cannot delete devices / approve key resets on `/account`; **ar** P4 deletes consent rows of a
  revoked client and treats `revoked` as rejected at Allow.
- **07-deployment.md:** table ~l.188-199: rows i, l, n, ak(1), "i / y (server-owned)" => "closed (story
  oauth-authorize-freshness)"; row y => "Login no longer needs `auth_time` (consent on every
  authorization); without it `/account` destructive actions are unavailable (fail closed); release note
  aq", owner "server (done)". ~l.213: replace "The IdP must honour `max_age=0` and emit `auth_time` (gate
  y)" with "An IdP that emits `auth_time` enables `/account` device deletion and key-reset approval for
  OAuth users". Schema list ~l.139-150: both new tables, "`oauth_account_sessions.auth_time` nullable
  (000045)". Checklist: `@oauth-consent` e2e run + manual items 1-7.

### Testing commands (isolated env)
1. `docker rm -f nebu-oauth-pg` (the migration is new).
2. `quick.sh "mix test --include integration test/nebu/oauth"` and `quick.sh "mix test test/nebu/web"`.
3. The full suite once with `integration.sh`, in the background, after `cleanup.sh`.
4. e2e from a scratchpad copy: `npx tsc --noEmit` and `npx bddgen --tags "@oauth-authorize or
   @oauth-account or @oauth-consent"`.

## Open questions
1. Per-client "first-party, no consent" flag? Not here (FR1); revisit with ap.
2. `@idp_lease_seconds` must be derived from the real IdP HTTP timeout in
   `HttpPublic.revalidate_with_idp/1`; record the value found.
3. (Resolved by the oracle gate: FR11 refusal is a recorded Nebu policy, see "Oracle gate".)

## Dev Agent Record

### Agent Model Used
Claude Sonnet 5.5 (dev-story, 2026-10-12).

### Debug Log References
- Isolated env: `quick.sh` (throwaway Postgres, test env). Story suites (15 files: the new freshness / consent page, flow, csrf, logging / refresh lease / migration 000045 files plus the updated ADR, account, hardening, cross-signing, callback, redaction, refresh-grant and pages files): 587 passed. `test/nebu/oauth test/nebu/migration`: 2140 passed, 0 failed. Full `mix test --include integration` on a fresh DB: 5564 of 5587 passed, 3 skipped, 23 failed, all in known families (RoomsFallbackName 11, AdminOidcLogin 3, LogsLive TraceMap 3, TemporaryCaptureManager 2, WarRoom 2, RegressionSyncLoad 1, LogStore Retention 1); 0 OAuth / migration / consent failures. `test/nebu/web`, `test/nebu/admin`, `test/nebu/matrix` run separately: only the known families (RetentionTest, OidcPlugTest denylist, RoomsFallbackName, AdminOidcLogin, LogsLive/TraceMap/WarRoom, TemporaryCaptureManager, ConfigController, SsoLogin/MatrixSso order-dependent, SyncConcurrent / RegressionSyncLoad). Running web + admin + matrix + oauth in ONE mix invocation crashes the application supervisor mid-run (Repo / Admin endpoint / Horde gone, 1287 cascade failures): not caused by this story (each directory alone is clean), the same order dependence as the known reused-DB family. Prod compile: only the known warning at `event_dispatcher/server.ex`.
- `docker builder prune -f --filter until=72h` was needed once ("No space left on device" at Postgres initdb).
- e2e: `node_modules/.bin/tsc --noEmit` (note: `npx tsc` resolved another tsc and printed syntax errors) and `bddgen --tags "@oauth-consent or @oauth-authorize or @oauth-account"` exit 0 from the scratchpad copy; nothing could run against a real Dex.

### Completion Notes List
- Story context created 2026-10-12; amended after the oracle gate (same day).
- **Implemented (FR1-FR20):** migration 000045 (`oauth_consent_requests`, `oauth_idp_refresh_leases`, `oauth_account_sessions.auth_time` nullable); `Nebu.OAuth.{Freshness, BrowserPost, ConsentStore, ConsentPage, Consent}`; callback order of FR5 in `Authorize` (gate l before provisioning, freshness, device holder, consent row, `303 /oauth2/consent`); `GET|POST /oauth2/consent` (router forward, `cors/2` and `JsonBody` skips, `RequestLogger` names-only); `Nebu.Matrix.oauth_device_holder/2` + `ClientStore.client_identity/1`; the IdP refresh lease in `Matrix.OAuthSession` (claim / wait / release, no transaction across the IdP call); account page fail closed (`freshness_unavailable`, no reauth link); ak(1)-(3) in `protected.ex` + `CrossSigningKeyStore.get_keys_for_update/1`; the purge gained `consents:`; docs (ADR-033 section FR1-FR20 + D5/A26/A7/T28/D16 edits + gate paragraph, `follow-ups.md` rows and the new section with ids au-ay, `07-deployment.md` rows / schema / checklist, `matrix-api-scope.md`).
- **Decisions where the story left room:** (1) `@idp_lease_seconds` = 25 (open question 2; raised to 60 in review cycle 1): the IdP leg is discovery + token endpoint + JWKS fetch, each bounded by a 5 s `:httpc` timeout (`OidcMetadata`, `OidcTokenExchange`), so 3 x 5 s + 10 s margin; the table CHECK allows 120 s. (2) A vanished device row (FK violation on the lease claim) proceeds WITHOUT a lease (nothing to serialize). (3) The holder re-resolves the refresh token AFTER claiming the lease, so a previous holder's rotation is never redeemed twice. (4) `BrowserPost` is stricter than the story-6 code for `Sec-Fetch-Site: same-site` (refused on `/account` too: one copy, FR8). (5) A POST on a row whose redirect target yields no valid CSP source consumes the row and answers `500 server_error` (the GET leaves it); no code. (6) The Matrix domain keeps its own `auth_time/1` claim reader (ADR-020: no call into a private OAuth module); `Nebu.OAuth.Freshness` is the OAuth domain's copy of the same rule. (7) New test-only seam `:oauth_idp_lease_wait_notify` (a pid receives `{:lease_wait, follower_pid}`), compile-time guarded like the other seams. (8) New Pages codes `device_in_use`, `forbidden`, `not_found`; `invalid_state` now says "Close this window. Start signing in again from your app.".
- **Test-review findings fixed in the staged tests:** MAJOR 1 (lease tests wait for the follower's `{:lease_wait, _}` instead of sleeping; the `consent_logging` race test too); MAJOR 2 (endpoint test: `REVOKE UPDATE` makes the locked read fail => 500, approval unconsumed, keys intact, works again after restore); MAJOR 3 (the FOR UPDATE test waits on an ungranted lock in `pg_locks`, no `Task.yield(500)`); MINOR 4 (token endpoint refuses the IdP code / state / consent cookie / csrf before Allow, GET with `decision=allow` mints nothing, Deny then Allow, grep for a raw `INSERT INTO oauth_codes`); MINOR 5 (e2e: keyboard-only scenario, axe + 320 px on the replace page, the `device_in_use` page and the freshness-notice variant); MINOR 6 (look-alike hosts); MINOR 7 (concrete assertions, `on_exit` split, per-case status, honest titles, max_age test reaches consent and checks the id_token); MINOR 8 (POST with unreadable config => 503); MINOR 9 (`expire_lease!` asserts one row); MINOR 10 (mixed null-key cases still need UIA). Other test fixes that were wrong in the staged tests: `assert_allow_redirect` / `assert_deny_redirect` compared a registered query wrongly (base / parameter order); a `{:reused, _}` test consumed the token with `whoami` before the follower started; the device-cascade test used a function that does not delete the device; the "N parallel callbacks" test used an IdP without a refresh token (now refused by gate l); the holder-race test counted the setup's code.
- **Not done / open:** the Manual verification items 1-7 (real Dex, Keycloak, Element Web, FluffyChat, scripted refresh race, screen reader) cannot run in the isolated env: they must be recorded before `oauth_enabled`. Follow-ups au-ay appended (holder re-check at redemption is ay). `oauth_enabled` stays off; nothing enables it.

### Review cycle 1 (2026-10-12)
Inputs: code review M1-M4 + INFO, Kassandra M-1 / L-1..L-5, UX advisories (`step-results/oauth-authorize-freshness/review-cycle1.md`). All implemented; migration 000045 (still uncommitted) was edited in place.
- **M-1 / FR21 (double clickjacking):** `ConsentPage` carries ONE inline script pinned by `script-src 'sha256-..'`; Allow is rendered `disabled`, armed after a pointer move >= 4 px (from the first position), a key press, a wheel or a scroll event AND 600 ms after load; Deny first and never disabled; no JavaScript => Allow stays disabled (fail closed, documented in ADR-033 FR21, 07-deployment and the manual list item 8); `Cross-Origin-Opener-Policy: same-origin`. Wheel / scroll also arm (touch users who only scroll): a small extension of the requested pointermove / keydown. The AC3 / ATDD "no script" assertions now check one hash-pinned script, no `unsafe-inline`, Allow disabled, Deny first, COOP; the e2e `decide` helper arms Allow with real Playwright pointer movement, the keyboard scenario follows Deny-first / armed-by-keypress.
- **L-1 (done, follow-up ay resolved):** migration columns `oauth_codes.device_holder_checked` / `device_holder_client_id`; `Consent.mint` stores the holder the user accepted; `OAuthSessionStore.insert_replacing_device` re-checks it under the `devices` lock (`rollback(:device_in_use)`), `Token` answers `invalid_grant`; codes of older nodes (checked = false) are not re-checked.
- **L-2:** per-user (5) and per-source (20, `source_key` column + indexes) live caps inside the `ConsentStore` INSERT, `temporarily_unavailable` at the callback.
- **M1 / L-3:** lease TTL 60 s (every `:httpc` call has a 5 s connect plus a 5 s request timeout, three calls per IdP leg); the Dev Record claim of 25 s is superseded. A killed holder keeps its lease until the TTL (documented, covered by the live-foreign-lease tests); fencing = follow-up az.
- **M2 / L-4:** `do_persist_cross_signing` reads the stored keys with the error-aware `get_keys_for_update/1` in a transaction (first upload written in it); a failed read is `500`, never the UIA-free first-upload or idempotent branch (new tests incl. an outage for an idempotent upload and a first upload).
- **M3:** `/account` POST variants `Sec-Fetch-Site: same-site` and `none` are refused (hardening matrix). **M4:** stale RED-phase moduledocs fixed (freshness, flow, csrf, logging, page, lease, 000045 test, e2e steps / feature headers).
- **INFO1:** the consent cookie is cleared only after a definite consume outcome (a storage error keeps it, retry works). **INFO2:** migration header names the rolling-deploy 404 window (and 07-deployment). **INFO3:** documented in `OAuthSession`, ADR FR15, 07-deployment. **INFO5:** `ConsentStore` stores an `auth_time` outside 0..year 2100 as NULL.
- **L-5:** the website line reads "claimed by the app, not verified by Nebu"; an https destination outside the claimed website gets a warning block; "part of the app website" needs a registrable site (`PublicSuffix`, never a bare suffix); look-alike and public-suffix tests.
- **UX:** A1 replace-session warning block before the form, device name first; A2 stronger weight for app name and destination, permission row before Terms / Privacy; A5 notice is a `status` region, "You were not asked for your password just now.", shown for anything but an exactly fresh login (nil can never hide it); A6 `color-scheme` meta on error pages; A7 `not_found`, `invalid_request`, `server_error` and `device_in_use` end with "Close this window...", `device_in_use` gives an actionable hint; A10 device names cut at 80 characters; A11 the e2e scenarios cover axe + 320 px on the replace, `device_in_use` and the fresh=false variants and the keyboard-only decision (fresh=false variant and the keyboard run are IdP dependent, run only against the real stack).

Cycle-1 results (isolated env): `test/nebu/oauth test/nebu/migration` 2156 passed, 0 failed; web / admin / matrix run separately: only known families; full `mix test --include integration` on a fresh DB: 5582 of 5603 passed, 3 skipped, 21 failed, all known families (RoomsFallbackName 11, LogsLive TraceMap 3, TemporaryCaptureManager 3, WarRoom 1, LogStore Retention 1, RegressionSyncLoad 1) plus `MatrixClientCompatTest` N+1 query-count (a global query counter, flaky under load; 60 passed alone and in the matrix directory run). Prod compile: only the known warning. e2e `tsc --noEmit` and `bddgen` exit 0.

### File List
Server (new): `server/lib/nebu/oauth/{freshness,browser_post,consent_store,consent_page,consent}.ex`, `server/priv/migrations/000045_oauth_consent_and_refresh_leases.{up,down}.sql`.
Server (modified): `server/lib/nebu/oauth.ex`, `oauth/{account,account_pages,account_store,authorize,authz_store,client_store,code_store,http,pages,token}.ex`, `oauth/account_templates/{delete_confirm,reset}.html.eex`, `server/lib/nebu/matrix.ex`, `matrix/{account_management,cross_signing_key_store,oauth_session}.ex`, `matrix/session/oauth_session_store.ex`, `server/lib/nebu/web/router.ex`, `web/router/protected.ex`, `web/plugs/{json_body,request_logger}.ex`, `server/lib/nebu/workers/oauth_flow_purge_worker.ex`.
Tests (staged by ATDD, edited here): `server/test/nebu/migration/000045_oauth_consent_and_refresh_leases_test.exs`, `server/test/nebu/oauth/{oauth_account_hardening_test.exs,oauth_test_support.exs,oauth_consent_flow_test.exs,oauth_consent_page_test.exs,oauth_consent_csrf_test.exs,oauth_consent_logging_test.exs,oauth_refresh_lease_test.exs,oauth_idp_callback_test.exs,oauth_account_cross_signing_test.exs}`.
E2E: `e2e/features/oauth/oauth-consent.feature`, `e2e/step-definitions/oauth/{oauth-consent,oauth-authorize}.steps.ts`.
Docs: `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/architecture/07-deployment.md`, `docs/stories/oauth-broker/follow-ups.md`, `docs/matrix-api-scope.md`, this story.

## Change Log
- 2026-10-12: story created (ready-for-dev); oracle gate corrections 1-12 applied.
- 2026-10-12: implemented (dev-story): migration 000045, consent step, freshness, device holder, refresh lease, account fail closed, ak(1)-(3), docs; test-review findings fixed; status review.
