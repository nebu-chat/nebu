---
story_id: oauth-account-management
title: "Account-management page (`devices_list`, `device_delete`, `cross_signing_reset`) + `m.oauth` UIA for cross-signing reset"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: true
created: 2026-10-10
branch: feature/migrate-to-oauth2
---

## Summary

Story 6 of epic `oauth-broker` (spec section 13 row 6; spec sections 3 (`GET /account`,
`account_management_uri`, `account_management_actions_supported`), 8 (UIA table, `auth_time`), 14
decisions 4 and 6). OAuth sessions cannot do User-Interactive Authentication (spec 8; story 5 C7
refuses `DELETE /devices` / `POST /delete_devices` for them with `403 M_FORBIDDEN`). This story gives
OAuth users the two things the Matrix spec (v1.18 "OAuth 2.0 API", MSC4191 account management, the
`m.oauth` UIA stage) expects instead:

1. **An account-management web page** under the Nebu origin, `GET <issuer>/account`, server-rendered
   HTML, signed in through the corporate IdP (the SAME IdP client and the SAME shared callback as
   story 2, own state tag), with a short-lived, DB-backed, hashed browser session (not a Matrix
   device), CSRF-protected POSTs and an IdP re-authentication (`max_age=0`) for destructive actions.
   Actions: `org.matrix.profile` (read only), `org.matrix.devices_list`, `org.matrix.device_view`,
   `org.matrix.device_delete` (atomic locked device teardown, legacy and OAuth devices), and
   `org.matrix.cross_signing_reset` (approval of a pending reset request).
2. **`m.oauth` UIA on `POST /_matrix/client/v3/keys/device_signing/upload`** for OAuth callers that
   REPLACE existing cross-signing keys: `401` with `flows: [{"stages": ["m.oauth"]}]`,
   `params["m.oauth"].url = <issuer>/account?action=org.matrix.cross_signing_reset` and `session`;
   after the user approved the request on the account page the client retries with
   `auth: {"session": ...}` and the keys are replaced (single use, short TTL, bound to user, UIA
   session and requesting device, cluster safe). Legacy callers keep today's behaviour byte for byte.
3. **Truthful metadata:** `account_management_uri` and `account_management_actions_supported` join
   the `auth_metadata` document (the page is live under exactly the same predicate as the document).
4. **Docs:** ADR-033 section (decisions A1-A27), `docs/matrix-api-scope.md`, follow-ups (gate (m)
   extended with `/account`, new items y-ab), Gherkin e2e feature + step definitions, UX gate notes.

`oauth_enabled` stays `false` by default and nothing in this story enables it. Out of scope: account
deactivation, password / 3PID, profile editing, any legacy behaviour change, `/versions` (story 9),
a consent screen (follow-ups (b)/(i)), admin UI changes (follow-up (v)), every open follow-ups item.

Oracle gate 2026-10-10 (`_bmad-output/nebu/epics/oauth-broker/step-results/oauth-account-management/oracle-context.md`,
Matrix v1.18 + matrix-js-sdk 41.3.0 + Element Web 1.12.22 source) is folded in: O1-O8 resolved (see
"Open questions"), corrections in A5, A12-A14, A17, A25, AC7, AC8, the e2e feature and the
Must-be-test-covered list (#41-#58).

Authoritative sources: `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 3, 8, 13, 14;
`docs/architecture/adr/ADR-033-authorization-server-broker-model.md` (D1-D23, T1-T33, R1-R24, story 5
adds C1-C20); story 2 `docs/stories/oauth-broker/oauth-authorize-idp-delegation-code.md` (D1-D5,
`Nebu.OAuth.Pages`), story 3 `oauth-token-endpoint.md` (T2, T7, `auth_time` on OAuth rows), story 4
`oauth-token-revocation-logout.md` (R2, R11, Trap 1), story 5 `oauth-legacy-coexistence.md` (C7, C9,
C12 `Nebu.Matrix.end_device_session/2`, C15, handover to story 9, gate (w)); story 1
`oauth-metadata-dcr-admin-approval.md` (UI/e2e conventions); `follow-ups.md` (items 1, b, i, j, m, s,
v, w; story-3 (c), (d)); Kassandra reports in `security-reports/` (story 2 F-2/F-3, story 3 I-5,
story 4 I-1); Matrix CS API v1.18 "OAuth 2.0 API" (account management URL + actions, "OAuth 2.0
aware clients"), "User-Interactive Authentication API" (`m.oauth` stage), `POST
/keys/device_signing/upload`; MSC4191, MSC4312; `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`
("Account management (1.18, MSC4191)", checklist 9).

## Story

As a **user of an OAuth-capable Matrix client (Element Web/X, FluffyChat later) on a Nebu instance**,
I want a Nebu web page where I sign in with my company account, see all my devices, sign out a device
and approve resetting my cross-signing identity,
so that I can manage my devices and recover my encryption identity although my OAuth client cannot
perform the old interactive-auth flows, and nobody who only holds one of my access tokens can do
either of these things in my name.

## Decisions

Prefix `A` (account story), so the IDs never collide with D1-D23 (story 2), T1-T33 (story 3), R1-R24
(story 4) and C1-C20 (story 5) in ADR-033. ADR-033 gets a new section with A1-A27 (AC14).

### Module boundaries and routing

- **A1 (module boundaries, ADR-020).** OAuth domain (new): `Nebu.OAuth.Account` (HTTP
  orchestration of every `/account` request and of the account branch of the IdP callback),
  `Nebu.OAuth.AccountStore` (inline SQL, ADR-018: login requests + browser sessions, migration
  000043), `Nebu.OAuth.AccountPages` (the HTML renderer). Matrix domain (owner of `devices`,
  `uia_sessions`, cross-signing keys, profiles, the IdP client) gains facade functions in
  `Nebu.Matrix` ONLY (`@doc` + `@spec`, never raise): `account_identity/1`, `account_devices/1`,
  `account_profile/1`, `cross_signing_reset_requests/1`, `approve_cross_signing_reset/2`,
  `decline_cross_signing_reset/2`, `purge_expired_uia_sessions/0`; reused: `idp_authorize_location/2`,
  `idp_complete_login/4` (story 2), `end_device_session/2` (story 5 C12). Matrix -> OAuth: ONE new
  function `Nebu.OAuth.cross_signing_reset_url/0 :: {:ok, String.t()} | :unavailable` (the m.oauth
  URL, live predicate A3) used by `protected.ex`. The static test of story 3 (`lib/nebu/oauth/*.ex`
  names no Matrix-internal module) must stay green for the three new OAuth files.
- **A2 (path).** `account_management_uri = <issuer>/account` (spec section 3 proposal `GET
  /account`; the issuer has an empty path, T31, so the page sits at the host root like every OAuth
  endpoint). Routes (all forwarded by `Nebu.Web.Router` with `forward "/account", to:
  Nebu.OAuth.Http, init_opts: [action: :account]`, placed with the other OAuth forwards, before
  `forward "/_matrix"` and `match _`):
  - `GET /account` — every action, selected by the query (`action`, `device_id`; A5)
  - `GET /account/reauth` — starts an IdP (re-)authentication for a return target (A10)
  - `POST /account/devices/delete` — device deletion (A13)
  - `POST /account/cross_signing_reset/approve` and `.../decline` — reset approval (A16)
  - `POST /account/logout` — ends the browser session (A8)
  - anything else under `/account` => 404 page; a wrong method => 405 page with `Allow`.
  `/account` collides with nothing (Element Web uses hash routing; the Matrix account endpoints live
  under `/_matrix/client/v3/account/*`; the admin UI under `/admin`). Rejected alternative
  `/oauth2/account` (would ride on the gate-(m) `/oauth2/` proxy route) for the user-facing URL the
  spec proposes; open question O1. The reverse proxies must route `/account` AND every `/account/*` sub-path to
  the server (oracle O1: required whenever Element Web is served on the same host): gate item (m) is
  EXTENDED (follow-ups), the cloud-init templates are not changed here.
- **A3 (liveness, kill switch).** The page is live iff `Nebu.OAuth.Config.live_state/0` is
  `{:live, issuer}` (OAuth `:enabled` AND a valid issuer — the SAME predicate as `auth_metadata` 200,
  story 5 C1/O5; reuse the shared helper, no copied condition). Disabled / invalid issuer => `404`
  page `unavailable` without a rate-limit token or DB access beyond the config read; `:unknown`
  config => `503` page `unavailable` (`Retry-After: 5`). The OAuth branch of the IdP callback for an
  account state follows the same rule (A6). Consequence (documented, consistent with C16): OAuth
  sessions that survive an operator switching OAuth off cannot use the page; they can still
  `/logout` / revoke.
- **A4 (no CORS, own body parsing).** `/account*` is browser navigation only: `Nebu.Web.Router`'s
  `cors/2` skips `CORSPlug` for `path_info: ["account" | _]` (no preflight answer, no
  `access-control-*` header on any response; a stray `OPTIONS` gets the 405 page), and
  `Nebu.Web.Plugs.JsonBody` skips the path (the POST handlers read their raw body exactly once through
  `Nebu.OAuth.FormPost.parse/1`: form-encoded, 16 KiB, no query string, duplicates / control
  characters refused; parse errors are rendered as the `invalid_request` HTML page, never the JSON
  envelope). Every response carries `Nebu.OAuth.Pages.put_flow_headers/1` (`Cache-Control:
  no-store`, `Pragma: no-cache`, `Referrer-Policy: same-origin` (review cycle 1 M1, see A9), CORS headers deleted) plus the A20
  CSP and `X-Frame-Options: DENY`.

### Actions

- **A5 (actions and parameters, MSC4191 / Matrix v1.18).** Query parsed from the RAW query string
  (story 2 D13 helper `Nebu.OAuth.AuthorizeRequest.parse_query/1`; form decoding, so `+` is a space
  and `%2B` a plus, as Element's `URLSearchParams` encodes; `/`, `%2F` and non-ASCII device ids are
  decoded and then validated like any other value): a malformed encoding or a
  duplicated `action` / `device_id` => the overview page with the fixed notice `invalid_request`
  (never a 4xx that breaks a deep link, never the raw value echoed).
  - Supported and advertised (pinned order): `org.matrix.profile`, `org.matrix.devices_list`,
    `org.matrix.device_view`, `org.matrix.device_delete`, `org.matrix.cross_signing_reset`.
  - `org.matrix.profile` => read-only profile view: Matrix user id and display name
    (`Nebu.Matrix.account_profile/1`), a note that the name is changed in the app and that
    deactivation / password are managed by the administrator / the company account. No editing.
  - absent or unknown `action` (also `org.matrix.account_deactivate`, which is NOT advertised) =>
    the default page = profile summary + device list. This is a Nebu choice (the spec lets the server
    decide; oracle O2), never an error. Element's "Manage account" opens the bare URI without
    `action` and lands here.
  - `device_id` on an action that does not take one (`profile`, `devices_list`,
    `cross_signing_reset`, default page) is IGNORED (spec: actions not supporting `device_id` ignore
    it), also when it is invalid.
  - `org.matrix.device_view` / `org.matrix.device_delete` REQUIRE `device_id` (1..255 bytes, valid
    UTF-8, no control characters); missing, invalid, unknown or another user's id => the device list
    with the fixed notice `device_not_found` (one answer for all four: no IDOR / existence oracle).
  - `org.matrix.device_view` is THE sign-out entry point of Element (its device links use
    `device_view` + `device_id`): the device page shows a PROMINENT "Sign out this device" control
    (a primary-styled link to the delete confirmation, first action on the page,
    `data-role="device-sign-out"`), not a secondary link.
  - Input aliases (never advertised; oracle O2, Element's fallbacks): `org.matrix.sessions_list`,
    bare `sessions_list` => `devices_list`; `org.matrix.session_view`, bare `session_view` =>
    `device_view`; `org.matrix.session_end`, bare `session_end` => `device_delete`.
  - `org.matrix.cross_signing_reset` => the pending-reset page (A16).
  - Additional Nebu-internal parameter `notice` (fixed codes only: `device_deleted`,
    `reset_approved`, `reset_declined`, `signed_out`, `device_not_found`, `invalid_request`,
    `reset_not_found`, `stale`), set only by Nebu's own 303 redirects; an unknown value is ignored.

### Browser authentication

- **A6 (IdP login through the shared callback, own state tag).** A request without a valid account
  session (A8) to `GET /account` (any action) or `GET /account/reauth` starts an IdP login:
  - IdP URL from `Nebu.Matrix.idp_authorize_location(conn, %{state: state, prompt: nil})` — the ONE
    IdP client (ADR-022), the shared registered callback `/_matrix/client/v3/login/sso/redirect/oidc`
    (story 2 D1, no new redirect URI at the IdP), the OIDC Scopes Law scope unchanged (no new
    scope), PKCE S256, `prompt=login` AND `max_age=0` (always, story 2 F-2 behaviour of that
    builder). The admin login (`Nebu.Admin.Auth`, `/admin/callback`, signed cookie session, admin
    scope family) is deliberately NOT reused: it is admin-only, uses its own redirect URI and scope
    family and keeps no server-side session.
  - State = `"o2.acct."` + 43 base64url chars (32 random bytes). It starts with `o2.`, so
    `Nebu.OAuth.oauth_idp_state?/1` is already true and `Nebu.Matrix.SsoLogin.callback/1` needs NO
    change; `Nebu.OAuth.handle_idp_callback/1` (today a `defdelegate` to `Authorize`) dispatches
    `"o2.acct." <> _` to `Nebu.OAuth.Account.handle_idp_callback/1` FIRST and everything else to
    `Nebu.OAuth.Authorize` unchanged (an account state can never match Authorize's anchored
    `@state_regex`, a story-2 state can never start with `o2.acct.`: base64url has no `.`).
  - Flow state in `oauth_account_login_requests` (migration 000043; NOT the node-local `SsoStore`,
    story 2 D3): `state_hash` (SHA-256 hex), SecretBox-encrypted IdP PKCE verifier, IdP nonce,
    browser-binding hash, `return_action`, `return_device_id` (validated, A5; review cycle 1:
    no `return_session_id`, it was never used), `replaces_session_hash` (the hash of a still-presented old account session cookie, or
    NULL), `created_at`, `expires_at = now() + 600 s`; consumed by ONE atomic `DELETE ... RETURNING
    ..., (expires_at > now()) AS live`; soft cap 10 000 live rows inside the INSERT (AuthzStore idiom).
  - Browser binding (story 2 D4): cookie `nebu_acct_<16 hex of state_hash>` (32 random bytes,
    `HttpOnly; SameSite=Lax`, `Path=` the callback path, `Max-Age=600`, `Secure` on https), only its
    hash stored, constant-time compare at the callback, cleared on every outcome except 429.
  - Callback order (account branch): rate limit (A19) => live check (A3, nothing consumed) => state
    format => atomic consume => binding => IdP `error` param (mapped page, IdP text never shown) =>
    `Nebu.Matrix.idp_complete_login/4` => `Nebu.Matrix.account_identity/1` (A7) => freshness (A7)
    => new session (A8) => `303` to the server-built return URL `/account?action=...` (never a value
    from the callback query: open-redirect safe). The IdP refresh token is discarded (never stored,
    never logged).
- **A7 (identity, no provisioning, `auth_time`).** `Nebu.Matrix.account_identity(claims) ::
  {:ok, %{user_id: String.t(), auth_time: integer() | nil}} | {:error, :unknown_user | :deactivated
  | :unavailable}`: the user id is derived EXACTLY like the login (`Nebu.Matrix.UserId.from_claims/2`
  with the configured `server_name`), then an ERROR-AWARE `SELECT is_active FROM users` (never the
  fail-closed `Nebu.Matrix.active?/1`: a DB error is `:unavailable` => 503 page, story 3 T19 idiom).
  NO provisioning: the page manages existing Matrix accounts; an unknown user gets the page
  `no_account` ("Sign in with a Matrix app first"), a deactivated user the page `deactivated`.
  `auth_time` is the id_token's `auth_time` claim ONLY (`iat` is NOT a substitute: it proves token
  issuance, not authentication). Freshness: claim present => it must be `>= login_request.created_at
  - 60 s` (60 s clock skew), else page `reauth_failed` ("Your identity provider did not ask you to
  sign in again") and no session; claim absent => accepted, the session's `auth_time` = the callback
  time and one WARNING per login without PII ("IdP returned no auth_time; freshness relies on
  max_age=0"). OIDC Core 3.1.2.1 obliges an IdP to return `auth_time` when `max_age` was requested,
  so absence is an IdP deviation: recorded as gate item (y), which is BLOCKING before `oauth_enabled`
  (oracle O5: Dex reportedly ignores `max_age` and omits `auth_time`; then a re-auth proves no
  freshness). The e2e feature checks the real Dex behaviour (scenario `@ac2-freshness`).
- **A8 (browser session).** Table `oauth_account_sessions` (migration 000043): `session_hash` PK
  (SHA-256 hex of a 32-byte random cookie value; plaintext never stored or logged), `user_id`,
  `auth_time` (unix seconds, A7), `csrf_hash` (A9), `created_at`, `last_seen_at`, `idle_expires_at`,
  `expires_at`. Lifetimes (code constants, no new `server_config` key, ADR-022): idle 900 s,
  absolute 3600 s (CHECK `expires_at <= created_at + interval '1 hour'`). Lookup = ONE atomic
  sliding `UPDATE oauth_account_sessions SET last_seen_at = now(), idle_expires_at = LEAST(now() +
  900 s, expires_at) WHERE session_hash = $1 AND idle_expires_at > now() AND expires_at > now()
  RETURNING user_id, auth_time, csrf_hash` (cluster safe, any node), followed by the error-aware
  `is_active` read (deactivated => the row is deleted, page `deactivated`). Rotation: every
  successful login / re-auth creates a NEW session and deletes `replaces_session_hash` in the same
  transaction (session-fixation defence; a re-auth as a DIFFERENT IdP account simply yields that
  account's session). `POST /account/logout` (CSRF) deletes the row, clears the cookie, renders the
  `signed_out` page (the one exception to A11's PRG: rendered directly with `200`). Cookie: on an
  https request — `conn.scheme == :https` OR the first `X-Forwarded-Proto` value is `https` (the SAME
  helper as `SsoLogin.callback_url/1` / `.well-known`; `live_issuer/0` already implies an https issuer)
  — `__Host-nebu_account` (`Path=/; Secure; HttpOnly;
  SameSite=Lax`, follow-up (j) rationale: no sibling-subdomain cookie tossing); on plain http
  (dev/test only) `nebu_account` (`Path=/account; HttpOnly; SameSite=Lax`, a `__Host-` cookie
  requires `Secure`). `SameSite=Lax`, not `Strict`: the cookie is set on the IdP callback, which is
  reached through a cross-site redirect chain, and the next top-level GET of `/account` must carry
  it. No `Max-Age` (session cookie); the server-side row is authoritative. On an https request ONLY the
  `__Host-` cookie is read (an unprefixed `nebu_account` cookie is ignored: cookie tossing); the
  binding cookie carries `Secure` on https; logout clears the cookie with the same name / path /
  attributes (`Max-Age=0`). Sliding the idle timeout never changes `auth_time`. The browser session is
  NOT a Matrix device: no `devices` / `matrix_sessions` row, it never authenticates `/_matrix/*`
  (OidcPlug never looks at the cookie).
- **A9 (CSRF).** Every state-changing request is a `POST` with a hidden `csrf_token` (32 random bytes,
  generated with the session, only its hash stored, constant-time compare; the page renders the token
  derived from the session cookie, see the Dev Agent Record). Additionally: an `Origin`
  header, when present, must equal the issuer origin (`scheme://host[:port]` of the normalized
  issuer), and `Sec-Fetch-Site`, when present, must not be `cross-site`. Review cycle 1 (M1): the pages
  send `Referrer-Policy: same-origin` (under `no-referrer` browsers send `Origin: null` for the page's own
  form POSTs, which would refuse every legitimate POST); `Origin: null` is accepted ONLY together with
  `Sec-Fetch-Site: same-origin` (and the valid token), as a fallback for privacy settings that strip the
  header; this MUST be verified in a real browser before the gate (Playwright, follow-up). Kassandra F-1
  (b): on the destructive POSTs (device delete, reset approve / decline) fetch metadata, when present,
  must describe a user-activated document navigation (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest:
  document`, `Sec-Fetch-User: ?1`); browsers that omit it keep working through Origin + token. Any failure => `403` page
  `forbidden`, nothing changed, the session stays. `SameSite=Lax` is the first line, the token the
  authoritative one. GET never mutates anything (A11).
- **A10 (re-authentication for destructive actions).** Device deletion and the cross-signing-reset
  approval/decline require a FRESH session: `now - session.auth_time < 300 s` (code constant). The
  confirmation page of a stale session shows a "Confirm it's you" LINK (an `<a>`, not a form, A20
  `form-action`) to `GET /account/reauth?action=...&device_id=...|session_id=...`, which starts a new
  IdP login (A6, `max_age=0`) with that return target; after the callback the user lands on the SAME
  confirmation page, now fresh. The POST handlers re-check freshness themselves (never trust the page):
  stale => `303` to the confirmation page with notice `stale`, nothing changed. Since every login sends
  `max_age=0`, a user arriving through a deep link who just signed in is already fresh (one IdP login
  for "open deep link, delete device").
- **A11 (GET never mutates; PRG).** Destructive operations: GET shows a confirmation page with the
  form, POST executes and answers `303 See Other` to `/account?action=...&notice=...`. A POST never
  renders the result page directly (no resubmission on reload) — exception: `POST /account/logout`
  renders the `signed_out` page directly with `200` (there is no session left to redirect into). Every
  POST checks CSRF (A9) BEFORE freshness (A10).

### Device list and deletion

- **A12 (device list).** `Nebu.Matrix.account_devices(user_id) :: {:ok, [map()]} | {:error,
  :unavailable}` (error-aware, unlike `list_user_devices/1` which returns `[]` on errors and would
  render "no devices" for a DB outage): one inline-SQL read (Matrix domain) of the user's `devices`
  rows plus, per device, `auth_api` and `client_id` of its newest live `matrix_sessions` row (any
  `auth_api`; `nil` when none). Fields shown: display name (else "Unnamed device"), device id, the
  OAuth app (`client_id` resolved through `Nebu.OAuth.ClientStore` in the OAuth domain to the
  registration's `client_name`, labelled "App (name claimed by the app)", escaped; follow-up story-3
  (c) is not solved, only made visible), "Last active" (`last_seen_ts`, UTC, `YYYY-MM-DD HH:MM UTC`,
  or "Never"), last IP (`last_seen_ip`, the user's own data, as the Matrix `GET /devices` exposes it),
  "Added" (`created_at`). Sorted by `last_seen_ts DESC NULLS LAST, device_id`. Bound: at most 500
  devices rendered, with a visible "N more devices not shown" note (never silently truncated).
  Legacy and OAuth devices are both listed (decision 6: both APIs in parallel). There is no "this
  device" marker (the browser is not a device). Every row links to its `device_view` page and has a
  direct "Sign out" link to the delete confirmation.
- **A13 (device deletion).** `GET /account?action=org.matrix.device_delete&device_id=X` => the
  confirmation page ("Sign out <name>?", consequences: the app on that device is signed out and its
  encryption keys for that device are deleted). `POST /account/devices/delete` (`device_id`,
  `csrf_token`; A9, A10) => ownership by membership in `account_devices/1` (foreign / unknown =>
  `303` notice `device_not_found`) => `Nebu.Matrix.end_device_session(user_id, device_id)` (story 5
  C12: `devices` row lock `FOR UPDATE`, every `matrix_sessions` row of the device of ANY `auth_api`,
  the device tables with keys, one transaction; post-commit JWT kill-switch and
  `SessionSupervisor.destroy_session/2`) => `303` notice `device_deleted`; `{:error, :unavailable}`
  => `500` page `server_error` ("Nothing was changed, try again"). Idempotent (a second POST =>
  `device_not_found`). Afterwards the deleted device's access token is `401 M_UNKNOWN_TOKEN` without
  `soft_logout` and its refresh token `invalid_grant` (story 4 R20). Decision 4 fulfilled: OAuth
  sessions delete devices ONLY here; the own session still ends through revocation (story 4).
  Deleting the device of the client that opened the page (e.g. the current Element device) is allowed:
  that device's token is dead afterwards, the page keeps working (the browser session is independent).
  **Legacy-only users** (oracle coexistence finding): once `oauth_enabled` is on, Element shows its
  "Manage account" / device links whenever the metadata carries `account_management_uri`, also for
  LEGACY sessions, and hides native sign-out / deactivation; so a user with ONLY legacy devices (no
  OAuth session ever) MUST be able to sign in (A6/A7 need only an existing `users` row) and sign out
  legacy devices here (same teardown).
  `device_lists.changed` for peers stays follow-up (s).

### `m.oauth` UIA for cross-signing reset

- **A14 (`POST /keys/device_signing/upload`, exact behaviour).** In `do_device_signing_upload/1` /
  `do_persist_cross_signing/3` (`protected.ex`), order unchanged up to the replacement branch:
  1. key-id collision with a device id => `400 M_INVALID_PARAM` (unchanged, before anything else);
  2. no stored master key => store, `200 {}` (first upload needs no UIA, unchanged, also for OAuth);
  3. "unchanged" re-upload => `200 {}` (also with an `auth` block, and BEFORE step 6, so a
     lost-response retry of an approved request with the SAME body is a `200` without consuming
     anything). FIX of a pre-existing deviation (`cross_signing_unchanged?/2`, protected.ex ~2271,
     compares all three keys): spec v1.18 exempts a request whose `master_key` matches the stored one
     AND every additionally SUPPLIED key matches. New rule: the request carries `master_key`, it equals
     the stored master key, and every supplied `self_signing_key` / `user_signing_key` equals the stored
     one; keys not supplied are not compared. A request WITHOUT `master_key` while a master is stored
     (e.g. SSK-only) is a replacement (steps 4-7). Applies to legacy callers too (a master-only /
     master+SSK re-upload with a stored USK was answered 403 before, now 200: spec-correct, recorded
     in the Change Log and `docs/matrix-api-scope.md`; the 403 for genuine legacy replacements stays);
  4. REPLACEMENT by a LEGACY caller (`conn.assigns[:auth_api] != "oauth"`, decided at authentication
     time, story 4 Trap 4) => today's `403 M_FORBIDDEN "Cannot replace existing cross-signing keys"`,
     byte-identical (an `auth` block is ignored as today);
  5. REPLACEMENT by an OAuth caller while `Nebu.OAuth.cross_signing_reset_url/0` is `:unavailable`
     (OAuth not live, A3) => the same `403` as (4) (never a challenge pointing at a dead page);
  6. REPLACEMENT by an OAuth caller with `auth.session` (binary; `auth.type` absent, `"m.oauth"` or
     `"org.matrix.cross_signing_reset"` (Element sends `{type: "m.oauth", session}`, oracle O3); any
     other type, e.g. `m.login.sso` => step 7) => ONE transaction: `Uia.consume(session,
     user, "cross_signing_reset", params)` (atomic single use, approved = `stage_complete`, unexpired,
     same user, same params) and, on `:ok`, `CrossSigningKeyStore.put_keys/2` (sets the consume-once
     `cross_signing_changed` flag, so peers see `device_lists.changed`) => `200 {}`. A failed key write
     rolls the consume back (the approval is not burned) => `500 M_UNKNOWN`. Consume `:error` => step 7;
  7. otherwise => `401` UIA challenge: `{"flows":[{"stages":["m.oauth"]}],"params":{"m.oauth":{"url":
     "<issuer>/account?action=org.matrix.cross_signing_reset"}},"session":"<id>"}` (the url byte-equal
     to `account_management_uri` + `?action=org.matrix.cross_signing_reset`, https by the issuer rule).
     `session`: the caller's still-PENDING (not approved, not consumed, unexpired) reset session for
     the SAME `(user, params)` is reused (idempotent challenges, bounded rows; a retry before approval
     gets the same id), else a new one is minted with a CHECKED insert (`{:ok, id} | :error`; `:error`
     => `500 M_UNKNOWN`, never a challenge for a session that does not exist). An APPROVED but
     not-yet-consumed session is never re-issued for an `auth`-less request (the client must present
     it). No `errcode` in the challenge body (same shape as the legacy `Uia.challenge_body/1`; `completed`
     omitted). The pending-session reuse is load-bearing: Element first calls `makeRequest(null)`,
     then its `InteractiveAuthDialog` makes a SECOND auth-less request without passing the session,
     and finally retries with `{type: "m.oauth", session}` after the user clicks Retry (no polling).
  `params` = `Uia.canonical_params(%{"device_id" => caller_device_id, "keys_sha256" => <hex SHA-256 of
  the canonical JSON (`Nebu.Matrix.CanonicalJson`) of the map of ALL SUPPLIED keys (`master_key`,
  `self_signing_key`, `user_signing_key`, whichever are present)>})` (`conn.assigns[:device_id]` is always
  set for OAuth sessions): the approval is bound to the requesting device AND to the exact key set
  (test-review M7 design decision; oracle hardening extended from the master key to every supplied
  key: Element's retry reuses the same body, and swapping the SSK/USK after the approval is refused).
  A retry with the approved session but a DIFFERENT key set (any supplied key) does not match `params` =>
  `consume` fails => step 7 (a new challenge for the new body; the approved session stays unconsumed
  until it expires). Pending-session reuse in step 7 matches on the full `params`, so a different body
  gets its own pending request. The replaced keys are the request's keys; a partial body keeps the stored keys that were
  not supplied (review cycle 1, Kassandra F-2: `Map.merge(Map.take(stored, keys), supplied)`; explicit `null` values and the stale-read window are follow-up (ai)). `m.oauth` appears ONLY in this endpoint's challenge, never in the
  flows of `DELETE /devices`, `/delete_devices` or the legacy fallback (they keep `m.login.sso`).
  Known, unchanged legacy deviation (oracle): a legacy replacement answers `403` instead of a UIA
  challenge (the spec requires UIA); out of scope, recorded in `docs/matrix-api-scope.md`.
  **Review cycle 1 amendments (Kassandra F-2 / F-3, code review m3):** (1) an approved PARTIAL replacement
  keeps the stored keys that were not supplied (the write is `stored` merged with the supplied keys; `put_keys/2`
  alone would store NULL for the absent ones and reopen the UIA-free first-upload branch). (2) The challenge is
  serialized per `(user, device)` (`pg_advisory_xact_lock`) and keeps at most ONE pending `cross_signing_reset`
  request per `(user, device)`: a new request consumes the device's older pending ones (an APPROVED one is
  never touched), and the user's pending requests are capped at 5. (3) `400 M_MISSING_PARAM` for an OAuth
  replacement that supplies no key at all (an approval must never wipe the keys).
- **A15 (approval record = the UIA session row).** Reuse `uia_sessions` (migration 000012, Matrix
  domain, DB-backed, single use by `consumed = TRUE WHERE consumed = FALSE`) with `op =
  "cross_signing_reset"`; `stage_complete = TRUE` means "approved on the account page". TTL: the row's
  900 s; an approval additionally sets `expires_at = LEAST(expires_at, now + 600)` (approval valid at
  most 10 minutes). Separation from the legacy SSO stage: `Uia.complete/2` (legacy `m.login.sso`
  fallback completion) gains `AND op <> 'cross_signing_reset'` and `Uia.load/1` (fallback start)
  refuses such rows, so an IdP login in the legacy fallback can never approve a reset; conversely the
  approval functions touch ONLY `op = 'cross_signing_reset'` rows. A new index
  `uia_sessions (user_id, op) WHERE consumed = FALSE` (migration 000043) serves the per-user listing.
- **A16 (approval page).** `GET /account?action=org.matrix.cross_signing_reset` lists the user's
  pending requests (`Nebu.Matrix.cross_signing_reset_requests(user_id) :: {:ok, [%{session_id,
  device_id, device_display_name, requested_at, expires_at}]} | {:error, :unavailable}`; unexpired,
  not consumed, not yet approved; newest first; at most 20). Each request shows WHICH device asked
  (name + id) and when, the warning "Only approve if you started resetting your identity in that app
  just now. Your other devices and your contacts will have to verify you again.", an "Approve reset"
  form and a "Decline" form (`session_id`, `csrf_token`). No pending request => "There is no pending
  request. Start 'Reset identity' in your app first, then come back." (request-first design: an
  approval always names ONE concrete UIA session; a user-level "allow resets for 10 minutes" window
  like MAS is rejected because any holder of an access token of the user could use it; open question
  O4). `POST /account/cross_signing_reset/approve` (A9, A10) => `Nebu.Matrix.approve_cross_signing_reset
  (user_id, session_id) :: :ok | {:error, :not_found | :unavailable}` (`UPDATE uia_sessions SET
  stage_complete = TRUE, expires_at = LEAST(expires_at, $now + 600) WHERE session_id = $1 AND user_id
  = $2 AND op = 'cross_signing_reset' AND stage_complete = FALSE AND consumed = FALSE AND expires_at >
  $now`, atomic) => `303` notice `reset_approved` ("Return to your app and continue"); `:not_found`
  => notice `reset_not_found`. `.../decline` => `decline_cross_signing_reset/2` (`consumed = TRUE`,
  same WHERE without the `stage_complete` condition) => notice `reset_declined`; the client's retry
  then gets a NEW challenge. Approving request A never authorises another pending request B (a
  different device of the same user, or a different master key): each row is approved individually.
  A request whose UIA session expired (900 s after mint) is no longer listed; approving a stale form
  => `reset_not_found`, and the client's retry gets a new challenge. Request-first is conformant
  (oracle O4).
  **Review cycle 1 amendments (F-3, UX A1-A4):** the page shows, per request, the requesting device, its app
  (the app's OWN claim, labelled "name chosen by the app"), the device's last activity, the request and expiry
  time (`<time datetime>` plus a relative hint) and a short reference (first 8 hex characters of the key
  hash); Decline is first in the DOM / focus order; while SEVERAL requests are pending the page shows a
  warning and no Approve button (decline the unknown ones first; the POST itself stays per session, so a
  deliberate API call can still approve one). 
- **A17 (`auth_time` of OAuth sessions, spec 8 [A]).** The account login / re-auth does NOT write
  `matrix_sessions.auth_time`. Story 3 sets it at issuance (IdP login time) and story 5 C9 keeps the
  legacy UIA refresh away from OAuth rows; a browser re-authentication proves the user is at THIS
  browser, not that the Matrix client holding a token is, so refreshing token rows would grant
  freshness to a possibly stolen token. Freshness for destructive OAuth-era actions lives on the
  account session (A10) and the explicit approval (A15). Recorded in ADR-033 as a
  DELIBERATE DEVIATION from the epic spec's section 8 sentence "`auth_time` muss auch bei
  OAuth-Sessions gesetzt werden (Login bzw. Re-Auth über die Account-Seite)" (oracle O7), and that
  sentence of `_bmad-output/planning-artifacts/oauth-broker-spec.md` (section 8, ~line 211) is amended
  to: "`auth_time` wird bei OAuth-Sessions beim Login gesetzt (Story 3); eine Re-Auth über die
  Account-Seite aktualisiert nur die Account-Sitzung, nicht die Token-Zeilen (Story 6, A17)".

### Metadata, look, abuse bounds, logging

- **A18 (metadata truthfulness).** `Nebu.OAuth.Metadata.build/1` adds `"account_management_uri" =>
  issuer <> "/account"` and `"account_management_actions_supported" => ["org.matrix.profile",
  "org.matrix.devices_list", "org.matrix.device_view", "org.matrix.device_delete",
  "org.matrix.cross_signing_reset"]` (exactly these, this order). Truthful by construction: the
  document answers 200 under the A3 predicate and so does the page. The same document is served at
  the unstable alias and `/.well-known/openid-configuration` (byte-identical, T31). Metadata caching
  (3 days) makes the new fields visible to clients only after the cache expires (operator note I-2).
  Story 1's "not advertised" assertions for these two fields become stale and are changed
  deliberately (Trap 7).
- **A19 (abuse bounds).** Node-local bucket `{"oauth_account", ip}` (600/h per IP, burst 600) charged
  by EVERY `/account*` request and by the account branch of the IdP callback, after the live check and
  before any DB access; exhausted => `429` page `rate_limited` + `Retry-After`. At most 10 000 live
  login requests (soft cap in the INSERT, A6); at most 20 live account sessions per user (the INSERT
  of the 21st deletes the user's oldest session in the same transaction: a user is never locked out,
  an attacker cannot grow the table per user). Trusted-proxy gate item 1 applies (behind nginx all
  browsers share one bucket); gate (h)-style per-source caps are follow-up (aa).
- **A20 (look, accessibility, headers).** Standalone renderer like story 2's `Nebu.OAuth.Pages`, NOT
  DaisyUI/the admin layout: the page lives outside the Admin endpoint (no admin session, no
  `/admin/static` assets for non-admin users, a different and stricter CSP, no LiveView). Templates:
  `EEx` compiled with `Phoenix.HTML.Engine` (auto-escaping; `phoenix_html` is already a dependency of
  the admin UI) under `server/lib/nebu/oauth/account_templates/*.html.eex`; ONE compile-time CSS
  string allowed by its SHA-256. CSP: `default-src 'none'; style-src 'sha256-<css>'; img-src 'none';
  form-action 'self'; base-uri 'none'; frame-ancestors 'none'`; `X-Frame-Options: DENY`
  (clickjacking of the destructive buttons); no script, no inline handlers, no external resources, no
  link to any client-controlled URL (app names are text only). WCAG 2.1 AA: `lang="en"`, charset +
  viewport, a page-specific `<title>`, ONE `<main>`, ONE `<h1>`, a `<nav aria-label="Account">` with
  the sections (Profile, Devices, Reset identity) and `aria-current="page"`, the device list as a
  `<table>` with `<caption>` and `<th scope="col">` / `<th scope="row">` (device name), action
  controls with accessible names that include the device ("Sign out <name>"), notices in a
  `role="status"` region (errors `role="alert"`), visible focus outline, text contrast >= 4.5:1, touch
  targets >= 24x24 px, no colour-only meaning, layout usable at 320 px width and 200 % zoom, buttons
  are real `<button type="submit">`, the destructive one labelled as such in text. E2E hooks:
  `<main data-page="account" data-action="<action>">`, rows `data-role="account-device"
  data-device-id=...`, `data-role="delete-device-confirm"`, `data-role="reset-request"`,
  `data-role="approve-reset"`, `data-role="decline-reset"`, `data-role="reauth"`, `data-role="notice"
  data-notice=...`, `data-role="sign-out"`. Error pages use `<main data-page="account-error"
  data-error="<code>">` (codes: `unavailable`, `rate_limited`, `method_not_allowed`, `not_found`,
  `invalid_request`, `invalid_state`, `forbidden`, `no_account`, `deactivated`, `reauth_failed`,
  `access_denied`, `server_error`). Status per code: `access_denied`, `no_account`, `deactivated`,
  `reauth_failed`, `forbidden` 403; `invalid_state`, `invalid_request` 400; `server_error` 500;
  `rate_limited` 429; `method_not_allowed` 405; `not_found` 404; `unavailable` 404 (OAuth not live) /
  503 (`:unknown` config, DB or IdP failure). The default page is `data-action="default"`; notices use
  `role="status"` (success) / `role="alert"` (errors) with `data-notice`.
  **Review cycle 1 amendments (UX V1-V3, advisories):** `Referrer-Policy: same-origin` (A9); reflow at 320
  px (`overflow-wrap:anywhere`, wrapping buttons, the device table stacks its rows below 40 rem with
  `content: attr(data-label)`, the scrollable table wrapper is a focusable `role="region"`); label-in-name
  (the accessible name of every control contains its visible text); `<meta name="color-scheme"
  content="light">` and a forced-colors rule; `aria-current` only where a nav entry IS the page (none on the
  default page); the delete confirmation names the device in `<title>` / `<h1>`, offers "Cancel - keep this
  device signed in"; "Sign out of the account page"; plain-language error texts; hook
  `data-role="device-row-sign-out"` on the row link; e2e `@a11y` scenarios (axe + no horizontal scroll at 320 px).
- **A21 (no audit rows, minimal logging).** Consistent with T29 / R21 / C19 (no `audit_log` rows for
  user logins, logouts or device deletions): INFO lines `OAuth account: signed in user_id=...`,
  `... device signed out user_id=... device_id=...`, `... cross-signing reset approved|declined
  user_id=... device_id=...`, `... signed out user_id=...`; WARNING for A7's missing `auth_time` and
  for CSRF failures (no values). NEVER logged: cookie values, the CSRF token, state, IdP code / tokens /
  claims, UIA session ids, hashes. Open question for Kassandra / the oracle: should a cross-signing
  reset approval be an audit row (compliance) — default no (C19 consistency).
- **A22 (redaction).** `PayloadRedactor` gains `csrf_token` (map keys and form strings); the account
  POST bodies are never captured anyway (JsonBody skip, A4); the callback query stays names-only
  (story 2 D20); `RequestLogger` logs `/account` query strings with parameter NAMES only (add
  `/account` and `/account/reauth` to `@names_only_query_paths`: `device_id` / `session_id` are
  identifiers that need not appear in access logs).
- **A23 (purge).** `Nebu.Workers.OAuthFlowPurgeWorker` (every 10 min) also calls
  `Nebu.OAuth.purge_expired_account_state/0` (batched deletes of expired login requests and sessions,
  `{:ok, %{login_requests: n, sessions: m}}`; the existing `purge_expired_flow_state/0` shape is NOT
  changed) and `Nebu.Matrix.purge_expired_uia_sessions/0` (delegates to the existing, so far never
  scheduled `Nebu.Matrix.Uia.cleanup_expired/0`: expired rows only, so legacy UIA behaviour is
  unchanged).
- **A24 (migration 000043, `oauth_account_sessions`).** New files
  `server/priv/migrations/000043_oauth_account_management.{up,down}.sql` (000040-000042 untouched):
  `oauth_account_login_requests` (A6; CHECK `expires_at <= created_at + interval '10 minutes'`,
  `return_action` NULL (= default page, the callback redirects to `/account`) or one of the five
  actions (CHECK), lengths bounded), `oauth_account_sessions` (A8;
  CHECKs on lifetimes and hex lengths), index `uia_sessions_user_op_pending_idx` (A15), expiry
  indexes for the purge. Grants to `nebu_app` following 000041: login requests `SELECT, INSERT,
  DELETE` (no UPDATE: rows are never updated), sessions `SELECT, INSERT, UPDATE, DELETE`; `ENABLE` +
  `FORCE ROW LEVEL SECURITY` with open policies per granted command (000041 pattern; the table owner
  would otherwise bypass RLS in the single-role dev setup). No `server_config` key (no change of the
  `config_update_mutable` policy). `.down.sql` drops exactly what `.up.sql` created.

### Interactions with earlier decisions and follow-ups

- **A25 (OAuth-aware clients, decision 4).** OAuth-aware clients MUST deep-link to the account page for
  signing out other devices (`action=org.matrix.device_delete&device_id=<id>`) and for deactivation;
  Nebu lands them on the confirmation page directly (after at most one IdP login). Deactivation is not
  supported (not advertised; default page with the administrator note). Element also shows these links for LEGACY sessions once the metadata carries
  `account_management_uri`, so the page serves legacy-only users too (A13). Gate item (w) (OAuth
  sessions cannot delete devices until the page exists) is CLOSED by this story; story 5's C7 403 stays (UIA
  endpoints remain unusable for OAuth tokens).
- **A26 (Kassandra story-3 I-5 / gate (i), consent).** No consent screen is added (follow-ups (b)/(i)
  stay open). The device list names the OAuth app of each device, so a take-over of a device id by an
  approved client (C15) becomes visible to the user; the account login itself is protected by
  `max_age=0` + the A7 freshness check where the IdP emits `auth_time`. The same freshness check at
  the AUTHORIZE callback remains gate (i) (not changed here; A7's helper is written so story/gate (i)
  can reuse it).
- **A27 (`/logout/all` and admin).** `/logout/all` keeps working without UIA (story 4 I-1, spec
  conformant; it also ends nothing on the account page, whose sessions are not Matrix sessions — a
  user who wants to end the account page session signs out there or waits <= 15 min idle).
  Admin deactivation makes the next account request delete the session (A8). No admin UI change
  (follow-up (v) stays).

## Acceptance Criteria

### AC1 — Routing, liveness, methods, headers (A2-A4, A19, A20)

- `forward "/account"` exists in `Nebu.Web.Router` (with the OAuth forwards, before `/_matrix`);
  `Nebu.OAuth.Http` action `:account` dispatches to `Nebu.OAuth.Account`.
- OAuth disabled / invalid issuer => every `/account*` path => `404` page `unavailable`, no DB access
  beyond the config read, no rate-limit token; `:unknown` => `503` page + `Retry-After: 5`.
- Methods: `GET /account`, `GET /account/reauth`; `POST` on the four POST paths; anything else =>
  `405` page with `Allow`; unknown sub-path => `404` page `not_found`; `OPTIONS` => `405` (no CORS
  preflight answer).
- Every response: `text/html; charset=utf-8` (pages) or `303`/`302` with `Location`, `Cache-Control:
  no-store`, `Pragma: no-cache`, `Referrer-Policy: same-origin`, `X-Frame-Options: DENY`, the A20 CSP,
  NO `access-control-*` header (also with an `Origin` request header).
- Rate limit `{"oauth_account", ip}`: the 601st request in a burst => `429` page + `Retry-After`,
  before any DB access.

### AC2 — Sign-in through the IdP (A6, A7, A8)

- `GET /account` (any action) without a session => `302` to the IdP authorization endpoint with the
  parameter set of the story-2 OAuth leg (`response_type=code`, `client_id`, `redirect_uri` = the
  shared callback, `scope` = the OIDC Scopes Law scope, `state` starting `o2.acct.`, `nonce`,
  `code_challenge`, `code_challenge_method=S256`, `prompt=login`, `max_age=0`), the binding cookie
  set (`HttpOnly; SameSite=Lax; Path=/_matrix/client/v3/login/sso/redirect/oidc; Max-Age=600`), one
  `oauth_account_login_requests` row (hash only; verifier ciphertext; return target).
- IdP discovery / config failure => `503` page `unavailable`, nothing persisted.
- Callback with the account state: success => `303` to `/account?action=<return action>[&device_id=
  ...]` built from the ROW, a session cookie (A8 attributes per scheme), one `oauth_account_sessions`
  row, the login request consumed, the binding cookie cleared; a presented old session row is
  deleted (rotation).
- Callback failures (each with its page and NO session): rate limited (cookie kept, nothing consumed),
  OAuth not live (nothing consumed), malformed / unknown / expired / replayed state => `invalid_state`
  (`400`), missing / mismatching binding cookie => `invalid_state` (row consumed), IdP `error` param
  => `access_denied` (IdP text never shown), IdP exchange / verification failure => `access_denied`
  or `unavailable` (`idp_unavailable`), unknown user => `no_account` (no `users` row created),
  deactivated => `deactivated`, DB error => `unavailable`, `auth_time` present and older than the
  request - 60 s => `reauth_failed`.
- `auth_time` absent => session created with `auth_time` = callback time and one WARNING (log
  capture: no user id, no token).
- An `o2.`-tagged story-2 state still takes the authorize branch unchanged (story-2 callback suites
  green); a legacy and a UIA-fallback state are untouched.
- The admin login (`/admin/login`, `/admin/callback`) is unchanged.

### AC3 — Session lifecycle (A8)

- Sliding idle timeout: a request 1 s before `idle_expires_at` succeeds and extends it (never beyond
  `expires_at`); after idle expiry or absolute expiry => treated as no session (new IdP login), the
  stale row is not reused.
- The cookie value is 43 base64url chars; only its SHA-256 is stored; a tampered / unknown cookie =>
  no session (IdP login), no error page.
- Deactivating the user (admin) => the next account request deletes the session and renders
  `deactivated`.
- `POST /account/logout` with a valid CSRF token => row deleted, cookie cleared (`Max-Age=0`, same
  name / path / attributes), `signed_out` page; a second use of the old cookie => IdP login.
- At most 20 live sessions per user: a 21st login deletes the oldest.
- The account cookie never authenticates a Matrix request (`GET /_matrix/client/v3/account/whoami`
  with only the cookie => `401 M_MISSING_TOKEN`).

### AC4 — CSRF (A9)

- EVERY POST endpoint (`/account/devices/delete`, `.../cross_signing_reset/approve`, `.../decline`,
  `/account/logout`) x every variant: without `csrf_token`, with a wrong one, with a token of ANOTHER
  session, with a foreign `Origin` (incl. a look-alike host `https://<host>.evil.com`, another
  scheme, another port), or with `Sec-Fetch-Site: cross-site` => `403` page `forbidden`, nothing changed
  (row snapshots), the session stays valid. The token check is independent of the Origin check (same
  Origin + wrong token => 403), and CSRF is checked before freshness (stale + wrong token => 403, not
  `stale`).
- `Origin` absent and `Sec-Fetch-Site` absent with a valid token => accepted (older browsers /
  privacy settings).
- The token is never in a URL, never logged, rendered only in hidden form fields of the user's own pages.

### AC5 — Actions and default page (A5, A20)

- `action` absent / unknown / `org.matrix.account_deactivate` => default page (profile summary + device
  list), `200`; the raw unknown value is not echoed.
- `org.matrix.profile` => user id + display name, no form, the administrator note.
- `org.matrix.devices_list` => the device list (AC6). `org.matrix.device_view&device_id=X` => one
  device's details + a "Sign out this device" link to the delete confirmation.
- `device_id` missing / invalid / unknown / foreign for `device_view` / `device_delete` => device list
  with notice `device_not_found` (identical HTML for the four cases, modulo the CSRF token).
- Aliases `org.matrix.sessions_list` / `org.matrix.session_view` / `org.matrix.session_end` and the
  bare `sessions_list` / `session_view` / `session_end` map to their spec names; the bare URI
  (no query) renders the default page.
- `device_view` shows the prominent `device-sign-out` control; `device_id` on `profile`,
  `devices_list` and `cross_signing_reset` is ignored (also an invalid one); device ids with `+`
  (space), `%2B`, `/`, `%2F` and non-ASCII characters are decoded and handled consistently (found /
  `device_not_found`).
- Duplicated `action` or `device_id`, malformed percent-encoding => default page with notice
  `invalid_request`.
- Each action page has the A20 hooks, exactly one `<h1>`, a specific `<title>`, the nav with
  `aria-current`.

### AC6 — Device list (A12)

- A user with one legacy device (named), one OAuth device (no name, client "Element") and one device
  without any session: all three listed with the A12 fields, sorted by last activity; the OAuth device
  shows the app name as escaped text (a client name containing `<script>` renders inert).
- Another user's devices never appear.
- Storage failure in `account_devices/1` => `503` page `unavailable` (never "no devices").
- 501 devices => 500 rows + "1 more device not shown".

### AC7 — Device deletion (A10, A11, A13)

- Fresh session: `GET ...device_delete&device_id=X` => confirmation page with the form; `POST
  /account/devices/delete` => `303` notice `device_deleted`; the device's `devices` row, keys, every
  `matrix_sessions` row (OAuth and legacy) and JWT bindings are gone; its OAuth access token => `401
  M_UNKNOWN_TOKEN` without `soft_logout`, refresh token => `invalid_grant`; the user's OTHER devices
  and sessions are untouched.
- Legacy device deletion through the page works the same way (story 5 C12 teardown); a
  LEGACY-ONLY user (only legacy devices, no OAuth session ever) can sign in and sign out a legacy
  device (its opaque token and bound JWTs are dead afterwards).
- Deleting the device whose client opened the page: that token `401`, the account page keeps working.
- Stale session (auth_time older than 300 s): the confirmation page shows the `reauth` link instead of
  the form; a POST anyway => `303` notice `stale`, nothing deleted; after `GET /account/reauth?...` and
  the IdP login the user lands on the same confirmation page with the form.
- Foreign / unknown / already deleted device id => `303` notice `device_not_found`, nothing deleted.
- `end_device_session/2` `{:error, :unavailable}` (seam / `T.block_session_deletes!/1`) => `500` page,
  the device and its session intact.
- Concurrency (story-4/5 idiom): holding the device's `devices` row `FOR UPDATE`, the POST waits, a
  hand-made OAuth rotation commits, then the POST completes => zero `matrix_sessions` rows of the
  device; the rotated-in access token `401`.

### AC8 — `m.oauth` challenge on `/keys/device_signing/upload` (A14)

- OAuth caller, existing keys, DIFFERENT keys, no `auth` => `401` with EXACTLY `flows`, `params`,
  `session` (no `errcode`); `params["m.oauth"]["url"]` == the metadata's `account_management_uri` +
  `"?action=org.matrix.cross_signing_reset"` and starts with `https://`; one `uia_sessions` row
  (`op = 'cross_signing_reset'`, params bound to the caller's device, `stage_complete = FALSE`).
- A second `auth`-less replacement attempt before approval => the SAME `session` id, no new row; an
  APPROVED but unconsumed session is never re-issued to an `auth`-less request (a new session is minted).
- Concurrency: two parallel approvals of one session => exactly one `:ok`; two parallel uploads with
  the same approved session => one consume, never `500`.
- Key-combination binding: after approval a retry with a different SSK or USK (same master) => new
  challenge, keys unchanged, the approved row unconsumed; master matches + different SSK/USK, USK-only,
  or a body without `master_key` => replacement (OAuth challenge / legacy `403`); malformed `auth`
  (non-binary session, not a map) => challenge, never `500`.
- A retry with `auth: {"session": id}` before approval => `401` with the same session id, keys
  unchanged.
- After approval on the page: retry with `auth: {"session": id}` without `type`, with `"type":
  "m.oauth"` and with `"type": "org.matrix.cross_signing_reset"` (three tests) => `200 {}`, keys
  replaced (`/keys/query` returns the new master key), `cross_signing_changed` set; `"type":
  "m.login.sso"` => re-challenge, keys unchanged.
- Replay after a successful replacement, SAME body (lost-response retry) => `200 {}` as an identical
  re-upload (step 3 before step 6), nothing consumed; replay with a DIFFERENT body => `401` with a NEW
  session id, keys unchanged.
- Approved session presented with a different master key than the approved request => re-challenge
  (new session), keys unchanged, the approved row stays unconsumed.
- Partial uploads: master-only matching the stored master (stored USK/SSK present) => `200` without
  UIA (legacy and OAuth); SSK-only with a stored master => replacement (OAuth: challenge; legacy:
  `403`).
- `m.oauth` never appears in the flows of `DELETE /devices`, `/delete_devices` (legacy challenge) or
  the legacy UIA fallback.
- Approval bound: the session presented by ANOTHER device of the same user, by another user, or for
  `delete_devices` => not accepted (`401` re-challenge, keys unchanged); an expired approval (> 600 s
  after approval) => re-challenge.
- Key write failure after a successful consume => `500 M_UNKNOWN`, keys unchanged, the approval still
  consumable (transaction rolled back).
- Mint failure (seam) => `500 M_UNKNOWN`, no challenge.
- OAuth not live => `403 M_FORBIDDEN "Cannot replace existing cross-signing keys"` (no challenge).
- Unchanged for OAuth callers: key-id collision `400`, first upload `200`, identical re-upload `200`.
- Legacy callers (opaque legacy, raw JWT): byte-identical to today for all four branches, with and
  without an `auth` block (snapshot of status + body), no `uia_sessions` row.

### AC9 — Approval page (A15, A16)

- `action=org.matrix.cross_signing_reset` lists the user's pending requests with device name / id and
  time; none => the "no pending request" text; another user's requests never appear; storage failure
  => `503` page.
- Approve (fresh, CSRF) => `303` notice `reset_approved`; the row `stage_complete = TRUE`, `expires_at
  <= now + 600`; approving twice / an unknown / foreign / expired / consumed / non-reset session =>
  notice `reset_not_found`, nothing changed.
- Decline => row `consumed = TRUE`, notice `reset_declined`; the client's next attempt gets a new
  challenge.
- Stale session => `reauth` link instead of the forms; POST anyway => notice `stale`, nothing changed.
- A legacy SSO UIA fallback (`/auth/m.login.sso/fallback/web?session=<reset session>`) => `400
  "Unknown or expired UIA session"`; `Uia.complete/2` on a reset session => `:error`, row unchanged.

### AC10 — Metadata (A18)

- `auth_metadata`, the unstable alias and `/.well-known/openid-configuration` contain
  `account_management_uri` (`<issuer>/account`) and `account_management_actions_supported` (the five
  values, pinned order), byte-identical across the three paths; still `404` while disabled.
- Every URL in the document is https (story 1 rule); the `account_management_uri` is live (`GET` =>
  `302` to the IdP / `200` with a session) whenever the document answers `200`.

### AC11 — Migration 000043 (A24)

- Up/down round trip on a throwaway PostgreSQL 16 (psql); 000040-000042 byte-unchanged (git diff).
- Tables, CHECKs, indexes, grants (`nebu_app`: login requests without UPDATE), RLS enabled AND forced,
  policies as specified; `.down.sql` restores the pre-000043 schema exactly (incl. the
  `uia_sessions` index removal).
- Runtime role tests: insert/consume/delete login requests and sessions work as `nebu_app`; `UPDATE`
  of a login request is refused; a login request with `expires_at > created_at + 10 min` and a session
  with `expires_at > created_at + 1 h` are refused by CHECK.

### AC12 — Purge (A23)

- One worker run deletes expired login requests and sessions (batched) and expired `uia_sessions`;
  live rows of all three are kept; `purge_expired_flow_state/0` keeps its return shape.

### AC13 — Logging and redaction (A21, A22, No Sensitive Data law)

- Log capture over the whole AC2-AC9 matrix: no cookie value, CSRF token, state, IdP code / token,
  UIA session id, hash or `Authorization` value in any log line; `csrf_token` redacted by
  `PayloadRedactor`; `/account` query strings logged with names only.

### AC14 — Documentation

- ADR-033: new section "Account management and `m.oauth` (story 6)" with A1-A27; the "Gate items"
  paragraph gets "Story 6 update: the account page is live under the auth_metadata predicate; gate
  (w) closed; (m) extended to `/account`; new items y-ab; `oauth_enabled` stays false (gate items 1,
  h, i, l, m, n, r, y; story 9)"; T30/T31 sentences unchanged; the Metadata moduledoc's "deliberately
  NOT advertised" list loses the two account fields.
- `docs/matrix-api-scope.md`: rows `GET /account` (+ sub-paths, aliases, default page as a Nebu
  choice), `POST /keys/device_signing/upload` (`m.oauth` for OAuth callers; the corrected "unchanged"
  rule; KNOWN DEVIATION: a legacy replacement answers `403` instead of the UIA challenge the spec
  requires), `auth_metadata` (the two new fields).
- `_bmad-output/planning-artifacts/oauth-broker-spec.md` section 8 (~line 211): the `auth_time`
  sentence amended per A17.
- ADR-033 states A17 as a deliberate deviation from the spec-section-8 sentence and that the page
  serves legacy-only users (A13/A25).
- `docs/stories/oauth-broker/follow-ups.md`: section "From story oauth-account-management": (w)
  RESOLVED; story-3 (d) RESOLVED (`m.oauth`); (m) extended ("and `/account`, `/account/` in both
  cloud-init templates"); (b)/(i) note "account page has no consent screen; A7 freshness check is
  account-only"; (m) also routes `/account*`; new rows **(y)** IdP without `auth_time` despite
  `max_age=0` (A7; **BLOCKING gate before `oauth_enabled`**, together with (i): Dex reportedly ignores
  `max_age` and omits `auth_time`, so a re-auth would prove no freshness; resolve by an IdP that
  honours `max_age` / emits `auth_time` or a decision to fail closed), **(z)** the account page cannot deactivate the account nor edit
  the profile (non-gating, product decision), **(aa)** per-source caps for account login requests /
  sessions after item 1 (non-gating, epic-end), **(ab)** audit rows for cross-signing reset approvals
  and account-page device deletions (compliance decision, non-gating).
- Moduledocs: `Nebu.OAuth` (account entry points, `cross_signing_reset_url/0`), `Nebu.OAuth.Metadata`,
  `Nebu.Matrix` (new facade functions), `Nebu.Matrix.Uia` (`m.oauth` separation), `protected.ex`
  comment of the replacement branch (the "Full UIA is out of scope" comment is replaced).
- arc42 (by the arc42 step; Dev Notes list the hooks). UX gate notes (Dev Notes) are input for the
  UX review step.

## Acceptance Tests

### ExUnit matrix (unit = pure, integration = `@tag :integration`, DB)

- New `server/test/nebu/oauth/oauth_account_test.exs` (integration): AC1-AC7, AC9 (Plug.Test conns
  through `Nebu.Web.Router`; IdP stubbed with the story-2 seams `stub_idp_exchange/1` /
  `sign_id_token/2`, discovery stub; sessions created through the real callback or the
  `T.account_session!/2` helper).
- New `server/test/nebu/oauth/oauth_account_cross_signing_test.exs` (integration): AC8, AC9 legacy
  separation, transaction rollback seam.
- New `server/test/nebu/oauth/oauth_account_pages_test.exs` (unit): A20 structure (one `main`, one
  `h1`, `lang`, title per page, nav `aria-current`, table caption/scopes, accessible button names, no
  `<script>`, no `on*=` attribute, no external URL), escaping of display names / client names, CSP hash
  == the CSS actually inlined, every error code renders.
- New `server/test/nebu/oauth/oauth_account_static_test.exs` (unit/static): A1 (OAuth files name no
  Matrix-internal module; `protected.ex` decides OAuth by `conn.assigns[:auth_api]`), A4 (router `cors/2`
  skip, JsonBody skip), A15 (`Uia.complete/2` / `load/1` exclude the reset op).
- New `server/test/nebu/migration/000043_oauth_account_management_test.exs`: AC11 (static + DB).
- Changed deliberately (Trap 7): `oauth_metadata_test.exs` / story-1 assertions that
  `account_management_uri` / `account_management_actions_supported` are absent; story-5
  `oauth_legacy_coexistence_test.exs` AC5 "`/keys/device_signing/upload` with an OAuth token
  unchanged (different keys 403)" => now the AC8 challenge; `adr_033_test.exs` (AC14 pins);
  `oauth_test_support.exs` section "Story 6" (below); `payload_redactor` tests (`csrf_token`);
  `request_logger` names-only tests (`/account`); `oauth_flow_purge_worker` test (the two new calls).
- Extended: `server/test/nebu/matrix/cross_signing*_test.exs` (legacy byte-identity snapshots),
  `server/test/nebu/matrix/uia*_test.exs` (op separation), `server/test/nebu/web/router*_test.exs`
  (no CORS on `/account`).

### matrix_compat node test (optional, like stories 3-5)

If runnable without touching the main checkout: replay Nebu's real `401` body through matrix-js-sdk
41.3.0's `InteractiveAuth` (the `m.oauth` stage is recognised, `params["m.oauth"].url` extracted, the
retry sends `auth: {session}`) and `validateAuthMetadataAndKeys` on the extended metadata. Otherwise
"not executed" in the Dev Agent Record.

### Gherkin (UI, `ui: true`)

`e2e/features/oauth/oauth-account-management.feature` + `e2e/step-definitions/oauth/oauth-account-management.steps.ts`
(playwright-bdd, admin-ui project, real Dex, written FIRST in the ATDD step; cannot run in the isolated
env: verified with `bddgen --tags "@oauth-account"` + `tsc --noEmit`, like stories 1 and 2):

```gherkin
Feature: OAuth account management page
  As a user of an OAuth-capable Matrix client
  I want to manage my devices and approve an identity reset on a Nebu web page
  So that I keep control of my account although my client cannot do interactive auth

  # Story: oauth-broker / oauth-account-management. Real Dex, real Nebu; the OAuth client is played by
  # the step file (authorize + token through APIRequestContext, PKCE, approved fixture client inserted
  # via fixtures/db.ts insertOAuthClient). Hygiene After hook (@oauth-account): oauth_enabled back to
  # 'false', prior oauth_issuer_url restored, e2e-oauth-acct-* clients, their sessions/devices and the
  # account sessions of the test user deleted through the privileged role.
  # Page contract (shared with oauth_account_pages_test.exs): <main data-page="account" data-action=...>,
  # one <h1>, no <script>, CSP default-src 'none'.

  Background:
    Given OAuth is enabled with an https issuer
    And an approved native client "e2e-oauth-acct-native" with redirect URI "http://localhost/cb"
    And the test user has an OAuth session on device "E2EACCTDEV1" through "e2e-oauth-acct-native"

  @oauth-account @ac2 @ac6
  Scenario: Signing in shows the device list
    When the browser opens the account page with action "org.matrix.devices_list"
    And the user signs in at the IdP
    Then the account page shows the action "org.matrix.devices_list"
    And the device list contains "E2EACCTDEV1" with the app "e2e-oauth-acct-native"
    And the page has exactly one level-1 heading
    And the page contains no script element
    And the page has no detectable accessibility violations

  @oauth-account @ac7
  Scenario: The device page is the sign-out entry point
    Given the test user has an OAuth session on device "E2EACCTDEV3" through "e2e-oauth-acct-native"
    When the browser opens the account page with action "org.matrix.device_view" for device "E2EACCTDEV3"
    And the user signs in at the IdP
    And the user follows the sign-out control of the device page
    And the user confirms signing out the device
    Then the account page shows the notice "device_deleted"
    And the access token of device "E2EACCTDEV3" is rejected

  @oauth-account @ac7
  Scenario: A legacy-only user signs out a legacy device
    Given the legacy test user has a legacy session on device "E2EACCTLEG1" and no OAuth session
    When the browser opens the account page with action "org.matrix.devices_list"
    And the legacy test user signs in at the IdP
    Then the device list contains "E2EACCTLEG1"
    When the user signs out device "E2EACCTLEG1" from the list and confirms
    Then the access token of device "E2EACCTLEG1" is rejected

  @oauth-account @ac2 @ac2-freshness
  Scenario: Re-authentication at the real IdP is observed for freshness (gate y)
    Given the user is signed in on the account page
    When the browser opens the re-authentication link
    Then the IdP re-authentication outcome is recorded as gate (y) evidence
    And the account session's auth_time is not older than the re-authentication request

  @oauth-account @ac7
  Scenario: Deep link signs out a device after confirmation
    Given the test user has an OAuth session on device "E2EACCTDEV2" through "e2e-oauth-acct-native"
    When the browser opens the account page with action "org.matrix.device_delete" for device "E2EACCTDEV2"
    And the user signs in at the IdP
    Then the confirmation for signing out "E2EACCTDEV2" is shown
    And the page has no detectable accessibility violations
    When the user confirms signing out the device
    Then the account page shows the notice "device_deleted"
    And the device list does not contain "E2EACCTDEV2"
    And the access token of device "E2EACCTDEV2" is rejected
    And the access token of device "E2EACCTDEV1" still works

  @oauth-account @ac8 @ac9
  Scenario: Resetting cross-signing keys needs an approval on the account page
    Given the client of device "E2EACCTDEV1" has uploaded cross-signing keys
    When the client of device "E2EACCTDEV1" uploads different cross-signing keys
    Then the client receives an m.oauth challenge pointing at the account page
    When the browser opens the challenge URL
    And the user signs in at the IdP
    Then a pending reset request from device "E2EACCTDEV1" is shown
    And the page has no detectable accessibility violations
    When the user approves the reset request
    Then the account page shows the notice "reset_approved"
    When the client retries the upload with the challenge session
    Then the upload succeeds
    And the client's cross-signing master key is the new key
    When the client retries the same upload again
    Then the upload succeeds without a challenge

  @oauth-account @ac9
  Scenario: Declining a reset request keeps the old keys
    Given the client of device "E2EACCTDEV1" has uploaded cross-signing keys
    And the client of device "E2EACCTDEV1" received an m.oauth challenge for different keys
    When the browser opens the challenge URL
    And the user signs in at the IdP
    And the user declines the reset request
    Then the account page shows the notice "reset_declined"
    When the client retries the upload with the challenge session
    Then the client receives a new m.oauth challenge

  @oauth-account @ac4
  Scenario: A form post without the CSRF token is refused
    Given the user is signed in on the account page
    When a same-origin form without the CSRF token is posted to sign out device "E2EACCTDEV1"
    Then the account error page "forbidden" is shown
    And the access token of device "E2EACCTDEV1" still works

  @oauth-account @ac4
  Scenario: A cross-site form post with a valid CSRF token is refused
    Given the user is signed in on the account page
    When a form with a valid CSRF token is posted cross-site to sign out device "E2EACCTDEV1"
    Then the account error page "forbidden" is shown
    And the access token of device "E2EACCTDEV1" still works

  @oauth-account @ac3
  Scenario: Signing out of the account page
    Given the user is signed in on the account page
    When the user signs out of the account page
    Then the account page shows the signed-out message
    And opening the account page again redirects to the IdP

  @oauth-account @ac1
  Scenario: The account page is unavailable while OAuth is disabled
    Given OAuth is disabled
    When the browser opens the account page with action "org.matrix.devices_list"
    Then the account error page "unavailable" is shown with status 404
```

Accessibility check: `@axe-core/playwright` (already an e2e dev dependency) with tags `wcag2a`,
`wcag2aa`, `wcag21a`, `wcag21aa` on the device list, the delete confirmation and the reset page (each
scenario step asserts it). The freshness scenario always attaches the observation (`gate-y-evidence.json`
+ a log line) and FAILS when `auth_time` is absent / older than the re-auth request unless the explicit
`gate-y` annotation records that Dex did not re-prompt. The After hook also removes the legacy
`E2EACCTLEG*` devices. `approveConsentIfShown` is a heuristic (Dex default theme).

## Must be test-covered (Matrix CS API v1.18 OAuth 2.0 API / account management / `m.oauth`, spec 3/8, decisions 4/6, RFC 6265bis, OWASP session management)

1. `auth_metadata` (and alias, openid-configuration) carries `account_management_uri` = `<issuer>/account` (https) and exactly the five actions in order; absent while disabled (404).
2. The page is live iff `auth_metadata` answers 200 (same predicate, runtime toggle effective on the next request); disabled 404 page, unknown 503 page, both before any rate-limit token / DB access.
3. `GET /account` without session => 302 to the IdP with `prompt=login`, `max_age=0`, the OIDC Scopes Law scope (no new scope), the shared callback, state `o2.acct.`+43, binding cookie attributes.
4. Account callback: binding cookie required (constant time), atomic single consume (replay => `invalid_state`), redirect target only from the row (open-redirect safe).
5. Story-2 authorize callback, legacy SSO login and the UIA fallback are unaffected by the new state tag.
6. Unknown IdP user => `no_account` page, no `users` row created; deactivated => `deactivated`; DB error => 503 (error-aware read).
7. `auth_time` older than request - 60 s => `reauth_failed`, no session; absent => accepted + WARNING without PII.
8. Session cookie: 256-bit, hash-only storage, `__Host-` + `Secure` + `Path=/` on https, `Path=/account` without `Secure` on http, `HttpOnly`, `SameSite=Lax`, no `Max-Age`.
9. Idle (900 s) and absolute (3600 s) timeout enforced in SQL; sliding never beyond `expires_at`; expired / tampered cookie => new login.
10. Session rotation on every login; the replaced session is deleted; at most 20 sessions per user.
11. Logout deletes the row and clears the cookie; the cookie never authenticates `/_matrix/*`.
12. CSRF: missing / wrong / foreign-session token, foreign `Origin`, `Sec-Fetch-Site: cross-site` => 403, nothing changed; absent `Origin`/`Sec-Fetch-Site` with a valid token accepted.
13. GET never mutates (every action GET leaves all row snapshots unchanged); POSTs answer 303 (PRG).
14. Destructive POSTs require `now - auth_time < 300 s`; stale => 303 `stale`, nothing changed; re-auth returns to the same confirmation page.
15. Unknown / absent / `account_deactivate` action => default page 200; aliases mapped; duplicated params => `invalid_request` notice; raw values never echoed.
16. `device_view` / `device_delete` with missing / invalid / unknown / foreign `device_id` => identical `device_not_found` answer (no IDOR / oracle).
17. Device list: legacy + OAuth + session-less devices, A12 fields, sort order, escaped app / device names, 500-row bound with the "more" note, DB error => 503 (never "no devices").
18. Device deletion ends the device completely (all `matrix_sessions` rows of any `auth_api`, device row, keys, bindings): AT 401 without `soft_logout`, RT `invalid_grant`; other devices untouched; legacy device deletable too.
19. Device deletion vs a concurrent OAuth rotation (locked teardown): no surviving row.
20. Device deletion storage failure => 500 page, device intact; second POST => `device_not_found`.
21. OAuth caller replacing keys without `auth` => 401 `flows:[{stages:["m.oauth"]}]`, `params["m.oauth"].url` == `account_management_uri?action=org.matrix.cross_signing_reset`, `session`; no `errcode`.
22. Repeated challenges before approval reuse the same session (no new rows); a not-yet-approved `auth.session` => 401 with the same session.
23. Approved session + retry => 200, keys replaced, `cross_signing_changed` set; replay => new challenge, keys unchanged.
24. Approval bound to user + session + requesting device: another device / user / op => re-challenge.
25. Approval TTL (<= 600 s after approval, <= 900 s after mint) enforced.
26. Consume + key write in ONE transaction: write failure => 500 and the approval stays consumable.
27. Checked mint: persistence failure => 500, never a challenge for a non-existent session.
28. OAuth not live => replacement 403 (no dead URL); first upload / identical re-upload / key-id collision unchanged for OAuth.
29. Legacy callers: byte-identical status + body for all branches, with and without `auth`; no `uia_sessions` row.
30. Approval page lists only the user's pending reset requests with the requesting device; approve / decline atomic; double approve / foreign / expired => `reset_not_found`.
31. Legacy SSO fallback and `Uia.complete/2` can never complete a `cross_signing_reset` session; approval functions touch only that op.
32. `matrix_sessions.auth_time` of OAuth rows is NOT changed by account login / re-auth (A17).
33. Pages: one `main`, one `h1`, `lang`, specific titles, nav `aria-current`, table caption/scopes, accessible names with device names, `role="status"`/`alert` notices, no script / inline handler / external resource, CSP hash matches, `X-Frame-Options: DENY`; axe WCAG 2.1 AA clean (e2e).
34. No CORS headers on any `/account*` response (also with `Origin`), no preflight answer; JsonBody does not parse `/account` bodies; body limits (16 KiB, form-encoded, duplicates) => `invalid_request` page.
35. Rate limit `{"oauth_account", ip}` => 429 page + `Retry-After` before DB access; login-request soft cap => `unavailable`.
36. Migration 000043: up/down round trip, CHECKs, grants (no UPDATE on login requests), forced RLS, earlier migrations untouched.
37. Purge removes only expired login requests, sessions and UIA rows; `purge_expired_flow_state/0` shape unchanged.
38. Logging: no cookie, CSRF token, state, IdP data, UIA session id or hash in any log line; `csrf_token` redacted; `/account` query names only.
39. No cross-domain call from `lib/nebu/oauth/account*.ex` into Matrix internals; no node-local state decides any A-behaviour (rate-limit buckets are abuse control only).
40. `oauth_enabled` stays false in every committed config.
41. Two consecutive auth-less uploads (Element's `makeRequest(null)` + dialog request) get the SAME session; the retry with it after approval => 200.
42. Retry `auth:{session}` without `type` => 200; `type: "org.matrix.cross_signing_reset"` => 200; `type: "m.oauth"` => 200; `type: "m.login.sso"` => re-challenge.
43. `m.oauth` never in the flows of `DELETE /devices`, `/delete_devices` or the legacy SSO fallback.
44. Same approved session with a DIFFERENT master-key body => new challenge, keys unchanged (master-key binding).
45. Lost-response retry with the SAME body after a successful replacement => 200 identical re-upload, nothing consumed; different body => new challenge.
46. Corrected "unchanged" rule: master-only matching re-upload with stored USK/SSK => 200 without UIA (legacy and OAuth); SSK-only with a stored master => replacement (OAuth challenge / legacy 403).
47. `device_id` with `+`, `%2B`, `/`, `%2F`, non-ASCII is decoded and handled consistently.
48. `device_id` on `profile`, `devices_list`, `cross_signing_reset` is ignored.
49. Aliases `org.matrix.session_view`, bare `session_view`, `org.matrix.session_end` (and the sessions_list forms) map correctly.
50. The bare URI (no `action`) renders the default page.
51. `device_view` shows the prominent sign-out control leading to the delete confirmation (e2e step "device_view then sign out").
52. Deleting the CURRENT client's device from the page: its token 401, the page keeps working.
53. A legacy-only user can sign in and sign out a legacy device.
54. Approval after the client's UIA session expired (900 s) => `reset_not_found`; the client's retry gets a new challenge.
55. Approving request A does not authorise a pending request B of another device of the same user.
56. The extended metadata passes matrix-js-sdk `validateAuthMetadata` / `validateAuthMetadataAndKeys` (matrix_compat test, or a fixture-based assertion of the required shape).
57. The challenge body has no `errcode`, `error` or `completed` (Element would enter its error state).
58. e2e against real Dex: whether a re-auth with `max_age=0` yields an `auth_time` / a fresh login is observed and recorded (gate (y)); cannot run in the isolated env.
59. M1: https detection honours `X-Forwarded-Proto` (`__Host-` cookie, Secure binding cookie, unprefixed cookie ignored on https, logout clears the `__Host-` cookie).
60. M2: the callback target and `/account/reauth` targets are server-built, relative and encoded (hostile query params, `&`, `#`, `//`, CRLF in `device_id`).
61. M3: CSRF matrix on every POST endpoint (see AC4), token check independent of Origin, CSRF before freshness.
62. M4: absolute timeout alone ends the session; sliding never changes `auth_time`; freshness boundary (< 300 s fresh, >= 300 s stale).
63. M5/M6: approved sessions never re-issued; parallel approvals / uploads / callbacks are single use.
64. M7: supplied-keys-only "unchanged" matrix; the approval is bound to ALL supplied keys.
65. M8: every attacker-controlled name (client name, device display name, device id, profile name) is escaped on every page.

## Dev Notes

### Files to create

- `server/lib/nebu/oauth/account.ex` — `Nebu.OAuth.Account` (`handle/2` for `/account*`,
  `handle_idp_callback/1`), A2-A16 orchestration.
- `server/lib/nebu/oauth/account_store.ex` — `Nebu.OAuth.AccountStore` (inline SQL: `insert_login_request/1`,
  `consume_login_request/1`, `create_session/1` (rotation + per-user cap in one transaction),
  `touch_session/1` (sliding UPDATE), `delete_session/1`, `purge_expired/0`; repo seam
  `:nebu_http, :oauth_repo` like `AuthzStore`).
- `server/lib/nebu/oauth/account_pages.ex` + `server/lib/nebu/oauth/account_templates/{layout,overview,
  profile,devices,device,delete_confirm,reset,error}.html.eex` (Phoenix.HTML.Engine, compile time).
- `server/priv/migrations/000043_oauth_account_management.{up,down}.sql`.
- Tests listed above; helpers ONLY in `server/test/nebu/oauth/oauth_test_support.exs` section
  "Story 6": `account_login!/2` (drives `GET /account` + the stubbed callback, returns
  `%{cookie, csrf, conn}`), `account_session!/2` (direct insert with a chosen `auth_time`),
  `account_get/2`, `account_post/4`, `oauth_device!/2` (story-3 issuance helper reuse),
  `cross_signing_keys/1` (deterministic key objects), `fail_key_write!/0` (seam on
  `CrossSigningKeyStore.put_keys/2` inside the transaction), `fail_uia_mint!/0`.
- `e2e/features/oauth/oauth-account-management.feature`, `e2e/step-definitions/oauth/oauth-account-management.steps.ts`;
  `e2e/fixtures/db.ts` gains `clearAccountSessions(userId)` and `clearOAuthSessionsByClientPrefix(prefix)`
  (privileged role, loud failures).

### Files to modify

- `server/lib/nebu/web/router.ex` — `forward "/account"`; `cors/2` skip for `["account" | _]`.
- `server/lib/nebu/web/plugs/json_body.ex` — skip `["account" | _]`.
- `server/lib/nebu/web/plugs/request_logger.ex` — `@names_only_query_paths` += `/account`, `/account/reauth`.
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` — `csrf_token`.
- `server/lib/nebu/oauth.ex` — `handle_idp_callback/1` dispatch (A6), `cross_signing_reset_url/0`,
  `purge_expired_account_state/0`, moduledoc.
- `server/lib/nebu/oauth/http.ex` — action `:account` (live check A3, then `Nebu.OAuth.Account`).
- `server/lib/nebu/oauth/metadata.ex` — the two fields + moduledoc (A18).
- `server/lib/nebu/matrix.ex` — the A1 facade functions; their reads use the test-only, compile-time
  guarded repo seam `:nebu_http, :account_matrix_repo` (`if Mix.env() == :test do`; a static test checks
  that every lib file reading it guards it, so prod builds never read it).
- `server/lib/nebu/matrix/uia.ex` — op separation in `complete/2` / `load/1`; checked
  `mint_session_checked/3` (or `{:ok, id} | :error` variant), `find_pending/3`, `approve_oauth/2`,
  `decline_oauth/2`, `list_pending/2`; `consume/4` usable inside a caller transaction.
- `server/lib/nebu/matrix/device_key_store.ex` — `list_devices_checked/1` with the session join (A12),
  or inline in the facade (Matrix domain either way).
- `server/lib/nebu/web/router/protected.ex` — `do_persist_cross_signing/3` replacement branch (A14).
- `server/lib/nebu/workers/oauth_flow_purge_worker.ex` — A23.
- `server/lib/nebu/web/router/protected.ex` `cross_signing_unchanged?/2` — the corrected rule (A14 step 3).
- `_bmad-output/planning-artifacts/oauth-broker-spec.md` section 8 (~line 211) — the A17 wording.
- Tests per Trap 7; docs per AC14.

### Current state of the code this story builds on (read before coding)

- `protected.ex` ~455 `post "/client/v3/keys/device_signing/upload"` -> `do_device_signing_upload/1`
  (~2230: key-id collision guard via `DeviceKeyStore.device_ids/1` + `CrossSigningKeyStore.key_ids_in_upload/1`)
  -> `do_persist_cross_signing/3` (~2248: no master => `put_keys` 200; unchanged => 200; else `403
  "Cannot replace existing cross-signing keys"`, comment "Full UIA is out of scope"). `uia_gate/4`
  (~2037) / `challenge/4` / `caller_auth_time/1` serve only the device-delete handlers (story 5 C7
  puts the OAuth refusal in front of them). `put_cross_signing_device_lists/3` (~226) consumes
  `CrossSigningKeyStore.consume_changed_flag/1` on incremental `/sync`.
- `Nebu.Matrix.Uia`: DB rows in `uia_sessions` (BIGINT unix seconds), `mint_session/3` best effort
  (ignores the insert result), `consume/4` atomic, `complete/2` identity-bound (+
  `refresh_auth_time/2`, legacy-only after story 5 C9), `load/1`, `cleanup_expired/0` (no caller in
  `lib/` today), `canonical_params/1` (lists sorted; other terms `Jason.encode!`: pass a map with
  one key so the encoding is stable).
- `Nebu.Matrix.CrossSigningKeyStore.put_keys/2` upserts the supplied keys and sets
  `cross_signing_changed = TRUE`; `get_keys/1`.
- `Nebu.Matrix.SsoLogin.callback/1` (~396): `Nebu.OAuth.oauth_idp_state?(state)` FIRST =>
  `Nebu.OAuth.handle_idp_callback(conn)`; `oauth_idp_authorize_location/2` (~328) always adds
  `max_age=0`; `callback_url/1` derives the callback from Host / `X-Forwarded-Proto`.
- `Nebu.OAuth.Authorize` (story 2): `live_issuer/0`, the delegate/callback pattern to copy
  (binding cookie, `put_flow_headers`, `encrypt/decrypt` rescue, `ip_string/1`, `log_reason/1`);
  `@state_regex ~r/\Ao2\.[A-Za-z0-9_-]{43}\z/`. `Nebu.OAuth.AuthzStore` = the insert-with-cap /
  atomic-consume idiom for `AccountStore`.
- `Nebu.OAuth.Pages` (story 2): standalone CSS + CSP hash, `put_flow_headers/1` (reuse it; do not
  duplicate). `Nebu.OAuth.FormPost.parse/1` (stories 3/4) for the POST bodies.
- `Nebu.OAuth.Metadata.build/1` (no account fields; moduledoc lists them as "deliberately NOT
  advertised").
- `Nebu.Matrix.list_user_devices/1` -> `DeviceKeyStore.list_devices/1` (`[]` on error);
  `devices` (000010): `display_name`, `last_seen_ts`/`last_seen_ip`/`created_at` (BIGINT ms).
- `Nebu.Matrix.end_device_session/2` (story 5 C12, implemented by the story-5 dev step on this
  branch before story 6 starts): verify it exists and its contract `:ok | {:error, :unavailable}`.
- `Nebu.Admin.Auth` (signed cookie session, `/admin/callback`, admin scopes): NOT reused (A6).
- `Nebu.Web.Router` `cors/2`: CORSPlug (credentials: true) for every path except the four
  credentials-free OAuth paths; `match _` => plain `404 "not found"`.

### What must be preserved

- Every story-1..5 behaviour not named in an A-decision (D1-D23, T1-T33, R1-R24, C1-C20), in
  particular: the story-2 authorize callback branch, C7 (403 for OAuth device deletion via the Matrix
  API), C9, C12, R17 (`/logout/all` without UIA), T22 kill switch, R13.
- Legacy `/keys/device_signing/upload` byte for byte; the legacy UIA `m.login.sso` flow for device
  deletion; admin login; `GET /login` (story 5 flags).
- The `purge_expired_flow_state/0` return shape; `Uia.mint_session/3` best-effort semantics for its
  existing callers.

### Traps

1. **Decide OAuth vs legacy by `conn.assigns[:auth_api]`** in the device-signing handler (story 4
   Trap 4); never by a token lookup.
2. **Never turn GET into a mutation** (A11): the reauth start is a GET that only creates a login
   request; deep links land on confirmation pages; the CSP `form-action 'self'` would also block a
   form whose submission redirects to the IdP, so "Confirm it's you" is an `<a>`.
3. **Return target from the DB row only** (A6): never read `action` / `device_id` from the callback
   query; validate them when the login request is created (A5 rules) — an invalid target becomes the
   default page.
4. **Op separation** (A15): without the `op <> 'cross_signing_reset'` filter the legacy SSO fallback
   (an IdP login) would approve a reset; without the `op = 'cross_signing_reset'` filter the approval
   page could complete a pending device-deletion UIA session.
5. **Consume and write in one transaction** (A14 step 6), lock-free otherwise; the uia consume and
   `put_keys` must use the same connection (`Repo.transaction/1`; `Uia.safe_query` must not open a
   second connection inside it).
6. **CORS default is `credentials: true`** (router): `/account` must skip CORSPlug, otherwise the
   preflight answers with credentials and a cross-origin page could at least probe it; and
   `put_flow_headers/1` alone would not stop the preflight.
7. **Stale tests (change deliberately, same commit):** any cross-signing test that pins a `403`
   for a master-only / master+SSK MATCHING re-upload (corrected "unchanged" rule, A14 step 3); story-1/3 metadata assertions that the account
   fields are absent (`oauth_metadata_test.exs`, `oauth_token_*` metadata snapshots, the T31
   byte-identity tests keep passing because all three paths change together); story-5 AC5/Must #16
   (`device_signing/upload` OAuth "different keys 403") => AC8; `adr_033_test.exs`.
8. **SameSite** must be `Lax` (A8) or the first navigation after the IdP callback has no cookie;
   `__Host-` requires `Secure` and `Path=/` (only on https).
9. **Clock units:** `uia_sessions` and `auth_time` are unix SECONDS, `devices.last_seen_ts` /
   `created_at` epoch MILLISECONDS, account tables `timestamptz`; convert explicitly.
10. **`auth_time` claim only** (A7): do not reuse `SsoLogin.login_auth_time/1` (it falls back to
    `iat`); `Nebu.Matrix.account_identity/1` returns the raw claim.
11. **No provisioning** (A7): do NOT call `Nebu.Matrix.provision_login_user/1` (it creates users and
    runs post-login provisioning).
12. **`oauth_enabled` stays false** in every committed config; tests use `T.enable_oauth/1`.
13. **IDOR:** every device / UIA lookup is scoped by the session's `user_id` in SQL, and the
    not-found answers are identical (A5, A13, A16).
14. **Unique fixture ids** (reused DB, IDOR guard, append-only audit): random suffixes for users,
    devices and clients, as in stories 1-5.

### Architecture compliance

ADR-018 inline SQL (`AccountStore`, Matrix facade reads/updates); ADR-019 single app; ADR-020
facade-only cross-domain calls (A1) and no node-local state for correctness (login requests,
sessions, approvals are DB rows with atomic consumption; ETS rate-limit buckets are abuse control);
ADR-022 no new env / `server_config` key, the one IdP client and its registered callback; ADR-033
broker model (the IdP is only an identity source; Nebu decides). OIDC Scopes Law (no new scope),
No Sensitive Data law (A21/A22), https-for-all-URLs (A18). Migration 000043 (next free number;
000040-000042 untouched).

### Library / client notes

- Matrix v1.18 "OAuth 2.0 API" account management: metadata `account_management_uri` (string, URL)
  and `account_management_actions_supported` ([string]); URL query parameters `action` and
  `device_id`; actions `org.matrix.profile`, `org.matrix.devices_list`, `org.matrix.device_view`,
  `org.matrix.device_delete`, `org.matrix.account_deactivate`, `org.matrix.cross_signing_reset`
  (oracle reference); OAuth-aware clients MUST use the page for deactivation and for signing out other
  devices. `m.oauth` UIA stage (MSC4312, spec v1.17+): `params["m.oauth"].url`, retry with the
  `session` only. matrix-js-sdk 41.3.0 knows `m.oauth` (oracle 2026-10-10); whether Element Web
  1.12.30 still needs the unstable `org.matrix.cross_signing_reset` stage is open question O3.
- `Phoenix.HTML.Engine` for EEx: `EEx.function_from_file(:defp, :render_x, path, [:assigns], engine:
  Phoenix.HTML.Engine)` returns safe iodata; convert with `Phoenix.HTML.safe_to_string/1`.
- Plug cookies: `put_resp_cookie(conn, name, value, http_only: true, same_site: "Lax", secure: ..., path: ...)`;
  `__Host-` names need `secure: true` and `path: "/"` and no `domain`.

### UX gate notes (input for the UX review step)

- Information architecture: one page per action with a persistent nav (Profile / Devices / Reset
  identity); the default page combines a short profile header and the device list (the most common
  task). Deep links land directly on the task (confirmation), with a "Back to all devices" link.
- Copy: plain language ("Sign out", not "delete session"; "Reset identity" with the explanation of the
  consequence); destructive buttons say what they do ("Sign out Element on iPhone"); the reset warning
  names the requesting device and time; every error page has "What you can do" (story 2 pattern).
- States to review: signed-out redirect, empty device list, many devices (500 bound), stale session
  (reauth link), device not found, nothing pending, approved, declined, server error, rate limited,
  OAuth disabled, no Matrix account yet, deactivated.
- Accessibility (A20) and responsive behaviour (320 px, 200 % zoom); no JavaScript at all (works with
  JS disabled); times in UTC with the "UTC" suffix (no client-side localisation without script).
- Visual: neutral standalone CSS consistent with story 2's pages (system font, max-width ~48rem,
  visible focus ring, high-contrast destructive button with a text label); no logos (no
  client-hosted images, A20 `img-src 'none'`).

### Testing commands (isolated env, see the epic brief)

New migration: `quick.sh --migrate` first, then `quick.sh "mix test --include integration
--warnings-as-errors test/nebu/oauth test/nebu/matrix test/nebu/web test/nebu/migration"`; full gate via
`integration.sh` in the background (run `cleanup.sh` first if an earlier run applied an older shape of
000043); compare failures with `scratchpad/known.txt` by name; `MIX_ENV=prod mix compile`. E2E:
`cd e2e && npx bddgen --tags "@oauth-account" && npx tsc --noEmit` (the Playwright run needs the full
stack and is NOT executed here; whole-suite `bddgen` has the pre-existing duplicate-step issue,
follow-ups "E2E tooling note").

### Docs to touch (arc42 step and dev)

ADR-033 (AC14), `docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`;
`docs/architecture/05-building-blocks.md` (`Nebu.OAuth.Account`, `AccountStore`, `AccountPages`, the
Matrix facade functions), `06-runtime.md` (account sign-in through the shared callback, device sign-out,
`m.oauth` reset sequence), `08-concepts.md` (browser session vs Matrix session, CSRF, re-auth window),
`11-risks.md` (IdP without `auth_time` (y), shared nginx bucket (item 1), no consent screen (b/i)).

### Out of scope

Account deactivation, password / 3PID, profile editing, consent screen, admin UI changes (v), legacy
changes (r, f), `/versions` (story 9), device grant (7), mTLS (8), `device_lists.changed` on device
deletion (s), the authorize-callback `auth_time` check (gate (i)), nginx template edits (gate (m)),
enabling OAuth, every other open follow-ups item (1-4, h, j-l, n-q, t, u, x).

## Open questions

Resolved by the oracle gate (2026-10-10, `_bmad-output/nebu/epics/oauth-broker/step-results/oauth-account-management/oracle-context.md`):

- **O1 (A2):** `/account` is fine; gate (m) must route `/account*` when Element Web is on the same host.
- **O2 (A5):** the five stable names are correct; bare `session_view` / `sessions_list` /
  `session_end` added as input aliases; "unknown action => default page" is a Nebu choice (citation
  fixed); read-only profile is fine; `device_view` is Element's sign-out entry (prominent control +
  e2e step).
- **O3 (A14):** params `{"m.oauth": {"url"}}` only, `session` top level, no `errcode` / `completed`;
  the retry accepts no `type`, `m.oauth` and `org.matrix.cross_signing_reset`; an extra unstable flow is
  optional (not added); first upload without UIA is conformant.
- **O4 (A15/A16):** request-first, individually bound approval is conformant.
- **O5 (A7):** Dex reportedly ignores `max_age` and omits `auth_time`: verify with real Dex in e2e
  (`@ac2-freshness`, not runnable here); gate (y) is BLOCKING before `oauth_enabled`.
- **O6 (A8/A10):** lifetimes OK.
- **O7 (A17):** epic spec section 8 sentence amended and A17 recorded as a deliberate deviation in ADR-033.
- **O8 (A21):** audit rows are a product decision: follow-up (ab).

Also folded in: AC8 split (same-body replay = identical re-upload 200, different body = new
challenge); `cross_signing_unchanged?/2` fixed to compare only supplied keys with the master required;
the legacy 403-instead-of-UIA deviation documented in `docs/matrix-api-scope.md`; legacy-only users
supported (A13, AC7, e2e, ADR); master-key hash binding of the UIA session adopted; the oracle's extra
tests (Must #41-#58). No open questions remain.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev-story, non-interactive, 2026-10-12).

### Debug Log References

Isolated env (`scratchpad/oauth/quick.sh`, throwaway PostgreSQL 16, MIX_ENV=test):

- story-6 files alone (`oauth_account*`, migration 000043, metadata / redaction / logger / ADR / coexistence): green (65 + 109 + 57 +
  41 + the changed files; the 184 formerly red tests all pass);
- targeted run (`test/nebu/oauth test/nebu/migration test/nebu/matrix test/nebu/web test/nebu/admin`, `--warnings-as-errors`):
  4166 tests, 36 failures: 34 in the known families, 2 NEW (`TokenHashingTest` grep guards: SQL on `matrix_sessions` in the new
  Matrix module, SHA-256 in `protected.ex`), fixed (deviation 7) and re-run green;
- final FULL run (`mix test --include integration`, after the fix): 4931 tests, 43 failures, NONE new: RoomsFallbackNameTest 12 (the
  admin endpoint is not started in this env: they fail in isolation too), TraceMap / TraceMapNodeControls(+Contract) / WarRoom /
  TemporaryCaptureManager / LogStore.Retention 22, `AdminOidcLoginTest` 3, `ConfigControllerTest` sso-schemes route 1 (admin endpoint),
  `SsoLoginTest` AC12.2 1, `MatrixSsoTest` loginToken 1, `OidcPlugTest` denylist 1 (reused DB), `RegressionSyncLoadTest` 1,
  `MediaScanWorkerKillSwitchTest` teardown flake 1 (`GenServer.stop` in `on_exit`; green alone);
- `MIX_ENV=prod mix compile --force`: only the pre-existing `upgrade_room/2` type warning (no warning from the story-6 files, the
  `:account_matrix_repo` seam is compiled out);
- e2e in a scratchpad copy: `bddgen --tags "@oauth-account"` generates the 11 scenarios, `tsc --noEmit` passes (Playwright not run).

### Completion Notes List

All 184 red story-6 tests (and the 11 Gherkin scenarios as generated tests) are green; no test was weakened.

**Implementation (decisions A1-A27 as written; deviations listed at the end).**

- Migration `000043_oauth_account_management.{up,down}.sql` (000040-000042 untouched): `oauth_account_login_requests`,
  `oauth_account_sessions`, `uia_sessions_user_op_pending_idx`, grants, RLS enabled + forced with open per-command policies.
- OAuth domain: `Nebu.OAuth.Account` (routing, live check, bucket, sessions, CSRF, IdP callback branch, pages, PRG),
  `Nebu.OAuth.AccountStore` (inline SQL, atomic consume / sliding UPDATE / rotation + per-user cap transaction / batched purge),
  `Nebu.OAuth.AccountPages` + `account_templates/*.html.eex` (compile-time `Phoenix.HTML.Engine`, one CSS block with its CSP hash),
  `Nebu.OAuth` (`handle_idp_callback/1` dispatches `o2.acct.` first, `cross_signing_reset_url/0`, `purge_expired_account_state/0`),
  `Nebu.OAuth.Http` (action `:account`), `Nebu.OAuth.Metadata` (the two fields, truthful by the shared predicate).
- Matrix domain: facade functions in `Nebu.Matrix` backed by the private `Nebu.Matrix.AccountManagement` (compile-time guarded
  test seam `:account_matrix_repo`); `Nebu.Matrix.Uia` (`complete/2` / `load/1` exclude `cross_signing_reset`,
  `mint_session_checked/3`, `find_pending/3`); `OAuthSessionStore.device_sessions/1` (the only module family that may read
  `matrix_sessions`, the token-hashing guard pins it); `CanonicalJson.sha256_hex/1`.
- `protected.ex`: the replacement branch decides by `:auth_api` (legacy `403` byte-identical, OAuth not live `403`, OAuth `m.oauth`
  challenge / one-transaction consume + key write), the corrected "unchanged" rule (supplied keys only, master required).
- Router: `forward "/account"`, `cors/2` skip; `JsonBody` skip; `RequestLogger` names-only for `/account*`; `PayloadRedactor`
  `csrf_token` (+ the `session` of a UIA challenge response); `OAuthFlowPurgeWorker` runs the three purges.
- Docs: ADR-033 section "Account management and `m.oauth` (story 6)" (A1-A27, A17 deliberate deviation, legacy-only users) +
  "Story 6 update" gate paragraph; `docs/matrix-api-scope.md`; `follow-ups.md` (w resolved, (m) extended, y-ab with y BLOCKING);
  `oauth-broker-spec.md` section 8 sentence amended.

**Deviations from the story text / gaps resolved while implementing (all small, none weakens a test).**

1. *CSRF token rendering.* The story says "generated with the session, only its hash stored". A stored hash cannot be rendered
   into the forms of later requests, so the page renders `HMAC-SHA256("nebu-account-csrf-v1", session cookie)` (256 bits only
   the browser knows, stable across tabs and back-button use) and the session stores `csrf_hash = sha256(token)` (A9 in the ADR).
   The verification is exactly the story's (hash compare, constant time).
2. *Migration `REVOKE UPDATE`.* The development database role setup (`dev/postgres/init/01-roles.sql`) grants `nebu_app` every
   privilege on new tables by default; `000043` therefore revokes `UPDATE` on `oauth_account_login_requests` so "no UPDATE
   grant" (A24, pinned by the migration test as `permission denied`) holds in every environment.
3. *Three fixture / test fixes (genuinely wrong tests, minimal):* `oauth_account_test.exs` cap test: the `oldest` fixture
   (created 30 min ago, expires in 1 h) violated the pinned `expires_at <= created_at + 1 hour` CHECK, now `expires_sql: now() +
   30 minutes`; `oauth_account_ops_test.exs` (2 places): the "dead" session fixture had `idle_expires_at > expires_at`,
   violating the pinned `idle <= absolute` CHECK, idle is now 2 s earlier; `oauth_account_static_test.exs`: `Code.ensure_loaded(Nebu.OAuth)`
   before `function_exported?/3` (an isolated run of the file saw the module unloaded).
4. *Profile page has no form at all* (the test pins `refute "<form"`), so the sign-out control lives on every other page.
5. *POST without a valid session* answers `303 /account` (sign in first); *an OAuth replacement with an empty key set* answers
   `400 M_MISSING_PARAM` (an approval must never wipe the keys); the worker runs all three purges and returns the first error.
6. *Redaction:* `PayloadRedactor` also redacts the `session` of a UIA CHALLENGE response (`flows` + `session`): the ops log test
   (Must #38) captures the DEBUG response body of the challenge.
7. *Token-hashing guards:* the `matrix_sessions` read for the device list moved into `OAuthSessionStore.device_sessions/1` and the
   canonical hash into `CanonicalJson.sha256_hex/1` (two existing grep guards of `token_hashing_test.exs` pin where
   `matrix_sessions` is read and where SHA-256 may be computed).

**Not executed / limits.** Playwright (needs the full stack): `bddgen` + `tsc` only. The reverse-proxy routes for `/account*`
(gate (m)) are documented, the cloud-init templates are not changed. matrix_compat: the replay of Nebu's real `m.oauth` 401
(captured from the router in a throwaway ExUnit test) through matrix-js-sdk 41.3.0 `InteractiveAuth` (stage recognised,
`params["m.oauth"].url` extracted, retry `{type: "m.oauth", session}`) and `validateAuthMetadataAndKeys` on the extended metadata ran
green in a scratchpad copy (not committed: the fixture producer was a throwaway test).

### Review cycle 1 (2026-10-12)

Findings: `step-results/oauth-account-management/code-review-findings.md` (1 MAJOR, 7 MINOR, INFO), Kassandra
`security-reports/oauth-account-management-security-review-2026-10-12.md` (F-1 gate (ag), F-2, F-3, I-6), UX review V1-V3 +
advisories. Tests first: `server/test/nebu/oauth/oauth_account_review_test.exs` (13 tests); deliberate changes to pinned
tests: `oauth_account_pages_test.exs` and `oauth_test_support.exs` (`Referrer-Policy: same-origin` instead of `no-referrer`),
`000043` migration test (no `return_session_id` column), story-6 test moduledocs reworded (m1).

- M1: `Referrer-Policy: same-origin` on every `/account*` response; `Origin: null` accepted only with `Sec-Fetch-Site: same-origin`
  + valid token; Kassandra F-1 (b) fetch-metadata check on delete / approve / decline.
- m2 / I-6 `auth_time` clamped to now; m3 / F-3 one pending request per (user, device), cap 5, advisory-lock serialized
  (`Uia.open_reset_request/3`), reset page refuses Approve while several are pending, shows app / last activity / reference;
  m5 `return_session_id` column and the unused accessors removed (000043 edited in place, uncommitted); m6 binding cookie cleared only
  after the live check; m7 `ClientStore.client_names/1` (one query); F-2 approved partial replacement keeps the unsupplied keys.
- INFO: i3 `Nebu.Web.RequestScheme` (first `X-Forwarded-Proto` value, used by router / SsoLogin / Authorize / Account); i5 "At least N
  more devices" at the 5000-row read limit; i7 `400 M_MISSING_PARAM` documented; i8 story A3 text.
- UX: V1 reflow CSS, V2 label-in-name, V3 stacked rows + focusable region; advisories A1-A6, A9-A11, A13 (A5's "back to the device
  page" not done: it needs an origin parameter).
- e2e: 6 new `@a11y` scenarios (Scenario Outline over profile / device list / device / delete confirmation / reset + signed-out; axe plus
  no horizontal scroll at 320 px), row sign-out through `data-role="device-row-sign-out"`; `bddgen --tags "@oauth-account"` now generates 17 tests, `tsc --noEmit` passes (Playwright not run).
- Documented limits: gate (ag) (same-origin approval risk) and (ah) are in `follow-ups.md`; the `Origin: null` fallback needs a
  real-browser POST check before the gate.

### File List

New: `server/priv/migrations/000043_oauth_account_management.{up,down}.sql`, `server/lib/nebu/oauth/account.ex`,
`server/lib/nebu/oauth/account_store.ex`, `server/lib/nebu/oauth/account_pages.ex`,
`server/lib/nebu/oauth/account_templates/{layout,error,device_table,overview,profile,devices,device,delete_confirm,reset}.html.eex`,
`server/lib/nebu/matrix/account_management.ex`.

Modified: `server/lib/nebu/oauth.ex`, `server/lib/nebu/oauth/http.ex`, `server/lib/nebu/oauth/metadata.ex`,
`server/lib/nebu/matrix.ex`, `server/lib/nebu/matrix/uia.ex`, `server/lib/nebu/matrix/canonical_json.ex`,
`server/lib/nebu/matrix/session/oauth_session_store.ex`, `server/lib/nebu/web/router.ex`,
`server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/web/plugs/json_body.ex`,
`server/lib/nebu/web/plugs/request_logger.ex`, `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex`,
`server/lib/nebu/workers/oauth_flow_purge_worker.ex`, `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`,
`docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`,
`_bmad-output/planning-artifacts/oauth-broker-spec.md`, this story file; tests fixed minimally:
`server/test/nebu/oauth/oauth_account_test.exs`, `oauth_account_ops_test.exs`, `oauth_account_static_test.exs`.

## Change Log

- **2026-10-10:** Story created (create-story, non-interactive) for story 6 of epic oauth-broker:
  account-management page (`/account`, IdP sign-in through the shared callback with the `o2.acct.`
  state tag, DB-backed hashed browser session, CSRF, re-auth window), device list / deletion via the
  story-5 locked teardown, `m.oauth` UIA for cross-signing replacement with session- and device-bound
  approvals in `uia_sessions`, truthful `account_management_*` metadata, migration 000043, decisions
  A1-A27, open questions O1-O8.
- **2026-10-10 (oracle-amended):** O1-O8 resolved; input aliases incl. bare names; `device_view` as the
  sign-out entry; retry `type` none / `m.oauth` / `org.matrix.cross_signing_reset`; UIA params bound to
  device + master-key hash; `cross_signing_unchanged?/2` corrected (supplied keys only, master
  required; also changes legacy matching partial re-uploads from 403 to 200, spec-correct); AC8 split;
  legacy 403-vs-UIA deviation documented; legacy-only users on the page; gate (y) BLOCKING with a real
  Dex e2e check; A17 as deliberate deviation + epic spec section 8 amendment; gate (m) covers
  `/account*`; Must #41-#58.
- **2026-10-10 (atdd):** red-phase acceptance tests written (ATDD role, non-interactive) for AC1-AC14
  and Must #1-#58 (7 new ExUnit files, 7 extended files, Gherkin feature + steps, story-6 helpers in
  `oauth_test_support.exs`); section "ATDD Decisions (story 6)" appended.
- **2026-10-12 (dev-story):** implementation of A1-A27 (migration 000043, `Nebu.OAuth.Account` / `AccountStore` / `AccountPages`,
  Matrix facade + `Nebu.Matrix.AccountManagement`, `m.oauth` UIA on `POST /keys/device_signing/upload`, corrected "unchanged" rule:
  a master-only / master+SSK matching re-upload with stored SSK/USK is now `200` for legacy callers too instead of `403` (spec-correct,
  `docs/matrix-api-scope.md`), truthful metadata, purge, redaction, docs); status `review`.

## ATDD Decisions (story 6)

Written by the ATDD role (2026-10-10, red phase). Run line at the end. All calls into new code go
through `apply/3` (or HTTP), so `--warnings-as-errors` compiles. The dev MUST implement against these
names; changing one means changing the tests in the same commit.

### Test files

New: `server/test/nebu/oauth/oauth_account_test.exs` (AC1-AC7, AC9 page), `oauth_account_cross_signing_test.exs`
(AC8, AC9 separation, A1 facade contracts), `oauth_account_pages_test.exs` (A20 renderer, unit),
`oauth_account_static_test.exs` (A1, A14, A15, A18, A23), `oauth_account_ops_test.exs` (AC12 purge,
AC13 log capture), `server/test/nebu/migration/000043_oauth_account_management_test.exs` (AC11),
`e2e/features/oauth/oauth-account-management.feature` (the story's Gherkin verbatim, 10 scenarios) +
`e2e/step-definitions/oauth/oauth-account-management.steps.ts`; `e2e/fixtures/db.ts` gains
`clearAccountSessions`, `clearOAuthSessionsByClientPrefix` (also deletes those sessions' devices/keys,
before the client cleanup: FK RESTRICT) and three privileged read/cleanup helpers
(`deleteOAuthSessionsOfUser`, `queryAccountSessionAuthTime`, `queryDbEpochSeconds`). E2E verified in a
scratchpad copy only: `bddgen --tags "@oauth-account"` (10 tests generated) and `tsc --noEmit` pass;
Playwright not run (isolated env). Steps reused from story 2 (not redefined): "OAuth is enabled with an
https issuer", "an approved native client ... with redirect URI ...", "the user signs in at the IdP",
"the page contains no script element"; "OAuth is disabled" is new.
Extended: `adr_033_test.exs` (AC14), `oauth_metadata_test.exs` (AC10), `oauth_payload_redaction_test.exs`
(`csrf_token`), `oauth_request_logger_redaction_test.exs` (`/account` names-only), `oauth_test_support.exs`
section "Story 6". The story's suggested extensions of `test/nebu/matrix/cross_signing*`, `uia*` and
`web/router*` tests are covered inside the new oauth files instead (legacy byte-identity, op separation,
no CORS on `/account`).

### Deliberately changed tests (Trap 7)

- `oauth_metadata_test.exs`: `@forbidden_fields` loses `account_management_uri` /
  `account_management_actions_supported`; the allowed-field set gains both.
- `oauth_legacy_coexistence_test.exs` (story 5) "Must #16 ... different 403" => "different keys =>
  m.oauth challenge (story 6)".

### Pinned APIs / schema / texts (beyond the story)

- Cookies: account session `nebu_account` (plain http REQUEST: `Path=/account; HttpOnly;
  SameSite=Lax`, no `Secure`, no `Max-Age`) / `__Host-nebu_account` (https REQUEST, `conn.scheme ==
  :https`: `Path=/; Secure; HttpOnly; SameSite=Lax`, no `Domain`); cookie value 43 base64url;
  binding cookie `nebu_acct_<16 hex>`; hidden field `csrf_token`; logout clears with `Max-Age=0`.
- Schema (shared with the migration test): `oauth_account_sessions(session_hash, user_id, auth_time
  BIGINT, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at)`, `session_hash` / `csrf_hash`
  = SHA-256 hex of the cookie / token; `oauth_account_login_requests(state_hash, idp_verifier_enc,
  idp_nonce, binding_hash, return_action (NULL = default page), return_device_id,
  replaces_session_hash, created_at, expires_at)`; indexes `uia_sessions_user_op_pending_idx`,
  `oauth_account_login_requests_expires_idx`, `oauth_account_sessions_expires_idx`,
  `oauth_account_sessions_user_idx`; policies `<table>_<command>` per granted command.
- Pages: `<main data-page="account" data-action="default">` for the default page (else the spec action
  name; aliases render the spec name); notices `data-notice="<code>"`; `Nebu.OAuth.AccountPages.error_codes/0`
  and `send_error(conn, status, code)`. Error statuses: `unavailable` 404 (not live) / 503 (unknown,
  DB/IdP failure), `rate_limited` 429, `method_not_allowed` 405, `not_found` 404, `invalid_request` 400,
  `invalid_state` 400, `forbidden` 403, `access_denied` 403, `no_account` 403, `deactivated` 403,
  `reauth_failed` 403, `server_error` 500. `POST /account/logout` => 200 page with `signed_out`. Texts:
  "There is no pending request", "1 more device not shown", "Unnamed device", "IdP returned no
  auth_time", INFO "OAuth account: signed in"; the profile page mentions the "administrator".
- Redirects: the callback `303 Location` is a RELATIVE path (`/account?action=...[&device_id=...]`,
  query order action then device_id); an invalid recorded target => `/account`.
- m.oauth: challenge body keys exactly `flows`, `params`, `session`; `params["m.oauth"]["url"] ==
  "https://nebu.example.com/account?action=org.matrix.cross_signing_reset"`; `uia_sessions.params` contains
  the device id and `T.master_hash/1` (SHA-256 hex of `Nebu.Matrix.CanonicalJson.encode!/1` of the
  supplied master key) — superseded by the test review M7: `T.keys_hash/1` (SHA-256 hex of the
  canonical JSON of ALL supplied keys, params key `keys_sha256`); key-write failure / mint failure =>
  `500 M_UNKNOWN`.
- Facades: `Nebu.Matrix.approve_cross_signing_reset/2 :: :ok | {:error, :not_found | :unavailable}`,
  `decline_cross_signing_reset/2` (same), `cross_signing_reset_requests/1 :: {:ok, [%{session_id,
  device_id, device_display_name, requested_at, expires_at}]}` (unix seconds), `Nebu.OAuth.cross_signing_reset_url/0
  :: {:ok, url} | :unavailable`, `Nebu.OAuth.purge_expired_account_state/0 :: {:ok, %{login_requests:,
  sessions:}}`; the worker's `perform/1` returns `:ok` and runs all three purges.

### Seams (test support, section "Story 6")

- NEW `:nebu_http, :account_matrix_repo` (compile-time guarded): repo of the Matrix account facade
  reads/updates (identity, devices, profile, reset requests, approve/decline); NoSuchRepo =>
  `{:error, :unavailable}` (identity => 503 at the callback, devices / requests => 503 page).
- `:oauth_repo` NoSuchRepo is the `AccountStore` repo (story pins it); `T.block_session_deletes!/1`
  (teardown failure), privileged triggers `T.block_cross_signing_writes!/1` (key write) and
  `T.block_uia_inserts!/1` (mint failure) instead of the story's `fail_key_write!/0` /
  `fail_uia_mint!/0` seams (no production seam needed).
- Helpers: `account_get/2`, `account_post/3`, `account_session!/2` (direct insert, chosen
  `auth_time` / lifetimes), `account_start!/2`, `account_finish/4` (IdP stub with `auth_time`, `nil`
  omits it), `account_login!/3`, `csrf_from/1`, `assert_account_page/3`, `assert_account_error/3`,
  `assert_account_headers/1`, `notice_of/1`, `oauth_device!/5`, `cross_signing_keys/2`,
  `device_signing_upload/2`, `stored_master/1`, `master_hash/1`, `uia_row/1`, `uia_count/2`.
- Concurrency (AC7): the story-4/5 idiom (held `devices` lock, `Task.yield(task, 500) == nil`).

### Contradictions / gaps with the story (proposed text)

0. **Resolved by the test review (2026-10-10):** items 1-5 below are folded into A8, A11, A20, A6/A24
   and the Dev Notes; M7 changed A14 (binding to ALL supplied keys, `keys_sha256`).
1. **A8 "on https".** Not said how the scheme is decided. Pinned: the REQUEST scheme (`conn.scheme`).
   Proposed A8: "on an https request (`conn.scheme == :https`; behind a proxy as resolved by the
   trusted-proxy gate item 1) `__Host-nebu_account` ...; on a plain http request `nebu_account` ...".
2. **Error-page statuses.** The story names codes but few statuses. Proposed A20 addition: the status
   list of "Pinned" above (`access_denied` / `no_account` / `deactivated` / `reauth_failed` /
   `forbidden` 403, `invalid_state` / `invalid_request` 400, `server_error` 500, `rate_limited` 429).
3. **Seam names.** The story's `fail_key_write!/0` / `fail_uia_mint!/0` are privileged triggers here;
   the NEW repo seam `:account_matrix_repo` is needed for "storage failure in account_devices/1 => 503"
   and the error-aware identity read. Proposed Dev Notes "Files to modify": "`server/lib/nebu/matrix.ex`
   — the account facade reads use the test-only, compile-time guarded repo seam `:account_matrix_repo`".
4. **`return_action` for the default page.** Pinned NULL (migration test). Proposed A6: "`return_action`
   NULL = default page".
5. **Logout page.** "renders the `signed_out` page" without a status: pinned `200`. Proposed A8: "...
   renders the `signed_out` page (200)".
6. **E2E (from the step file):** the challenge URL uses the configured https issuer, so the step opens
   the Nebu base URL with the challenge's path + query (asserting the URL is https `/account` with the
   reset action); with a fresh session no "re-authentication link" is rendered, so the freshness step
   opens `/account/reauth?action=org.matrix.devices_list` directly; the CSRF scenario posts through
   `page.request` (cookie carried) with a foreign `Origin` + `Sec-Fetch-Site: cross-site`.


### Test review follow-up (2026-10-10)

New `server/test/nebu/oauth/oauth_account_hardening_test.exs` (M1-M8 + the cheap MINORs: a11y hooks,
A12 fields, AC2 gaps incl. the not-live callback, the story-2 `o2.` branch, nonce mismatch, the encrypted
verifier, the 10 000-row soft cap, plaintext CSRF never stored; malformed `auth`; purge of an
idle-expired session; failure-path log capture). `oauth_account_cross_signing_test.exs`: params bound to
`T.keys_hash/1`, mint row `expires_at <= now + 900`, stranger keys unchanged. `oauth_account_test.exs`:
logout pins `data-notice="signed_out"`, idle margin 5 s. `oauth_account_static_test.exs`: the
`:account_matrix_repo` seam read is compile-time guarded. e2e: axe on three pages, the freshness evidence
rule, two CSRF scenarios (11 scenarios), the After hook cleans `E2EACCTLEG*`. Must #40 (`oauth_enabled`
false in committed config) stays covered by `oauth_config_test.exs`.

### Run (after the test review)

`quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth test/nebu/migration
test/nebu/matrix test/nebu/web"`: 3365 tests, 190 failures. 184 are story-6 tests (account 64,
hardening 32, pages 26, migration 000043 19, cross-signing 18, static 11, ADR/docs 5, metadata 3, ops 3,
redaction 2, the changed story-5 Must #16 1), all failing for the right reason (`/account` unrouted,
000043 tables missing, missing modules / functions / files, the replacement branch still `403`, no
metadata fields, no redaction, docs missing). The other 6 are pre-existing, order-dependent and in the
known.txt families (2 sync load tests, `MatrixSsoTest` loginToken, the `OidcPlugTest` denylist-on-reused-DB
test, 2 `LogStore.RetentionTest`). E2E: `bddgen --tags "@oauth-account"` (11 tests) and `tsc --noEmit`
pass in the scratchpad copy.

### Run (first ATDD pass, superseded)

`quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth test/nebu/migration
test/nebu/matrix test/nebu/web"`: 3330 tests, 154 failures. 151 are story-6 tests (account 64, pages 26,
migration 000043 19, cross-signing 18, static 10, ADR/docs 5, metadata 3, ops 3, redaction 2, the
changed story-5 Must #16 1), all failing for the right reason: `/account` unrouted (router plain
`404 "not found"`), missing tables of 000043 (`relation ... does not exist`), missing modules /
functions (`UndefinedFunctionError`, missing files), the replacement branch still answering `403`
instead of the `m.oauth` challenge, metadata without the two fields, `csrf_token` / `/account` not
redacted, docs missing. The other 3 are pre-existing and unrelated (2 sync load tests and
`LogStore.RetentionTest`, known.txt family). Stories 1-5 stay green except the 2 deliberate changes.
