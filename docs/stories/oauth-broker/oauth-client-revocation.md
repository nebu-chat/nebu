---
story_id: oauth-client-revocation
title: "Withdraw an approved OAuth client (status `revoked`, same-transaction cascade teardown, admin list + Revoke) and same-origin hardening of /admin approvals and /account reset approval (gates aj, ag incl. E-3)"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-12
branch: feature/migrate-to-oauth2
---

## Summary

Phase-2 story P4 of epic `oauth-broker`. Closes two activation gates of `follow-ups.md`:

- **aj (epic SEC gate E-1, MEDIUM):** an approved client can never be withdrawn. The 000040 guard trigger
  freezes decided rows, DELETE is limited to `pending` rows (FORCE RLS), `matrix_sessions.client_id` is
  `ON DELETE RESTRICT` (000042) and the admin UI lists only pending rows. The only remedies today are
  global (`oauth_enabled = false`, which only suspends: item ai) or owner DDL.
- **ag + "(ag) extended" (story-6 F-1 / I-1, epic E-3, MEDIUM):** Element Web, `/account` and `/admin`
  share one origin in the reference deployments. A same-origin script (XSS in Element Web) can fetch the
  approval page, read the CSRF token and POST an approval of a client registration or of a cross-signing
  reset: Origin and `Sec-Fetch-Site` say `same-origin`, nothing proves a human, no fresh admin login.

Folded in: the revoke runbook SQL of `07-deployment.md` that deletes only `matrix_sessions` rows (an / ai)
is replaced by supported operations; the cheap part of ai (operator "revoke all OAuth sessions") ships as
an RPC function without UI.

`oauth_enabled` stays OFF. No Matrix CS API change. SO7 states honestly what code cannot stop: the real
fix of ag is a separate origin for Element Web (deployment, P5 / operator).

## Story

As an **instance administrator**, I want to revoke an approved OAuth client (sessions, devices and
in-flight codes die, it is never usable again) and approvals/revocations to need a fresh sign-in and a
real form submission, so that a mistaken approval can be undone and a same-origin script in Element Web
cannot approve a client or a cross-signing reset on my behalf.

## Decisions

Prefix `CR` (client revocation) / `SO` (same origin); no collision with D/T/R/C/A/V/TP/AH in ADR-033.

- **CR1 (status `revoked`, additive migration 000046).** Columns `revoked_by TEXT`, `revoked_at
  TIMESTAMPTZ`, `revoked_reason TEXT` (<= 500 chars, non-NULL only when revoked). Status CHECK gains
  `revoked`. Decision CHECK re-created: pending = every decision column NULL (incl. `revoked_*`);
  approved = `approved_*` set, `rejected_*`/`revoked_*` NULL; rejected = 000040 shape + `revoked_*` NULL;
  revoked = `approved_*` set (it WAS approved, attribution kept), `revoked_by`/`revoked_at` set,
  `rejected_*` NULL. Number 000046 because 000044 (P2, adds `client_domain`/`source_key` to
  `oauth_clients`) and 000045 (P3) may be taken; **renumbering at integration is allowed** if the order
  "after 000043" holds and no committed migration is edited.
- **CR2 (guard trigger: approved -> revoked is the ONLY new transition).** `CREATE OR REPLACE FUNCTION
  oauth_clients_guard_status()` keeps every 000040 rule and allows exactly `OLD.status = 'approved' AND
  NEW.status = 'revoked'` with `approved_*`/`rejected_*` unchanged, `OLD.revoked_*` NULL and
  `NEW.revoked_by`/`revoked_at` set. Everything else on a decided row raises `check_violation`
  (revoked -> any status, re-attribution, reason edit; approved -> rejected; pending/rejected -> revoked).
  Identity/metadata immutability unchanged; still not SECURITY DEFINER, reads no other table. P2's new
  columns are not trigger-guarded (P2 AH6), so replacing the function does not conflict.
- **CR3 (RLS unchanged, FORCEd).** DELETE policy stays `status = 'pending'` (a revoked row is never deleted:
  it keeps the metadata hash occupied, CR6). INSERT policy re-created with `revoked_* IS NULL`.
  `config_update_mutable` is NOT touched (parallel migrations may re-create it; doing it here could drop
  their keys).
- **CR4 (one transaction, lock order oauth_clients -> devices -> matrix_sessions).**
  `Nebu.OAuth.ClientStore.revoke/3`, ONE `repo.transaction` (timeout 120 s):
  1. `UPDATE oauth_clients SET status='revoked', revoked_by=$2, revoked_at=now(), revoked_reason=$3 WHERE
     client_id=$1 AND status='approved' RETURNING client_id` (0 rows => rollback `:not_approved`);
  2. new facade `Nebu.Matrix.oauth_end_client_sessions(client_id, repo)`, runs INSIDE the caller's
     transaction: `SELECT DISTINCT user_id, device_id FROM matrix_sessions WHERE client_id=$1 ORDER BY 1,2`,
     then per pair the EXISTING locked teardown `OAuthSessionStore.end_device/3` (devices row `FOR UPDATE`,
     every `matrix_sessions` row of the device of any `auth_api`, device tables with E2EE keys; the nested
     transaction joins the outer one), then `SELECT count(*) ... WHERE client_id=$1` must be 0 (else
     rollback `:race`). Sessions are deleted and the client row is only UPDATEd, so the RESTRICT FK never
     fires. Returns `[{user_id, device_id}]`;
  3. `UPDATE oauth_codes SET used_at=now() WHERE client_id=$1 AND used_at IS NULL` (the only UPDATE the
     000041 guard allows; live codes cannot be deleted);
  4. `DELETE FROM oauth_authz_requests WHERE client_id=$1` (the callback then answers `invalid_state`);
  5. the caller's `:audit` function (approve/reject pattern: a failed audit rolls everything back).
  After the commit `Nebu.Matrix.oauth_after_device_teardown(pairs)` (the private `after_commit/2` of
  `Nebu.Matrix.OAuthSession`, exposed: JWT denylist + binding deletion, legacy per-device cleanup), best
  effort, as for `/oauth2/revoke`.
- **CR5 (issuance and rotation lock the client row `FOR SHARE` FIRST).** Else a token request that read
  `approved` before the revoke committed could insert a session after the teardown listed the devices.
  `OAuthSessionStore.insert_replacing_device/1` and `rotate/1` run, as their FIRST statement inside their
  transaction, `SELECT status FROM oauth_clients WHERE client_id=$1 FOR SHARE` (rotation: read
  `client_id` together with `user_id/device_id` in `lock_device_of/2`, lock the client, then the device)
  and roll back `:client_not_approved` unless `approved`. `FOR SHARE` conflicts with the revoke's UPDATE:
  either the issuance commits first and the revoke's step 2 (new statement, new snapshot) deletes the new
  session, or the revoke commits first and the issuance re-reads the locked row (READ COMMITTED) as
  `revoked`. One lock order everywhere => no deadlock. The SQL is inline in the Matrix store (ADR-018)
  and reads one OAuth column, the coupling the 000042 FK already has (ADR-020 note, AC12). Facades:
  `oauth_issue_session/1` gains `{:error, :client_not_approved}`; `oauth_refresh_session/4` maps it to
  `{:error, :invalid_grant}`.
- **CR6 (every entry point refuses `revoked`; nothing resurrects it).** authorize: `client_status/1`
  answers `revoked` like `rejected` (403 page `client_rejected`, no redirect); callback `recheck_client/1`
  already does. Token (both grants): lookup-time `revoked` => `401 invalid_client`; revoked between lookup
  and issuance/rotation => `400 invalid_grant`. `/oauth2/revoke`: the sessions are gone => `200 {}`,
  byte-identical to an unknown token (RFC 7009; test only). Resource server: `401 M_UNKNOWN_TOKEN`
  (rows gone). DCR dedup: identical metadata maps to the revoked row => `201` with the SAME `client_id`,
  exactly like a rejected dedup hit; status stays `revoked`, no new row, no audit, never pending or
  auto-approved again. A client wanting back must register CHANGED metadata (new hash, pending, new
  approval): a revocation is final for that metadata (owner DDL is the only override).
- **CR7 (Admin UI: new controller, dead render).** `Nebu.Admin.OAuthClientsController`: `GET
  /admin/oauth/clients` (approved, newest approval first, 50/page, real total), `GET
  /admin/oauth/clients/revoked`, `GET /admin/oauth/clients/:client_id/revoke` (confirm page), `POST
  /admin/oauth/clients/:client_id/revoke`. Rows: claimed name (labelled unverified), verified
  `client_host`, `application_type`, approved by/at, `last_used_at`, live session count (devices with a row
  whose `session_expires_at > now()`, new facade `Nebu.Matrix.oauth_client_session_counts/1`; a read error
  shows `?`, never `0`). Revoked rows: revoked by/at, reason. Sidebar "OAuth" gains "Approved Clients" and
  "Revoked Clients". A separate controller keeps P2's bulk-reject edits of
  `OAuthRegistrationsController` apart.
- **CR8 (confirm step = typed host).** The confirm page names client, verified host, device count and the
  consequences (sessions end, devices and E2EE keys deleted, never re-approvable with this metadata). The
  POST needs `confirm_host` equal (trimmed, case-insensitive) to `client_host` (or to `client_id` when the
  host is NULL) plus an optional `reason` (reject-reason normalisation, max 500). Mismatch => 303 back,
  nothing changed. Stops misclicks, NOT a same-origin script (it can read the host, SO7).
- **CR9 (audit).** `oauth_client_revoked` (added to `AuditWriter` `@known_actions`), target_type
  `oauth_client`, target_id = client_id, metadata `{"reason"?, "devices": n, "reauth": "auth_time" | "flow"
  | "rpc"}`, in the revoke transaction. Approve audit metadata gains `"reauth"`. Never client metadata,
  never user/device ids.
- **CR10 (operator RPC, replaces the runbook SQL).** `Nebu.Release.revoke_oauth_client(client_id,
  reason)` (same `Nebu.OAuth.revoke_client/3`, actor `"operator:rpc"`, `reauth: "rpc"`) and
  `Nebu.Release.revoke_all_oauth_sessions/0` (every `(user_id, device_id)` with an `auth_api = 'oauth'`
  row, batches of 500, each via `Nebu.Matrix.end_device_session/2`; clients stay approved; audit
  `oauth_sessions_revoked_all` with the count; run AFTER the switch-off). Invoked as `bin/nebu rpc '...'`
  in the running node (shell access = strong operator auth; also the escape hatch when the admin IdP is
  down or cannot pass SO4). No UI for revoke-all.
- **CR11 (scale).** One transaction per client, 120 s timeout; a timeout rolls back completely (error
  flash, retry). Tested with 200 devices; very large clients: open question 2.
- **CR12 (logging).** INFO `OAuth admin: client revoked client_id=<id> devices=<n>`; WARNING on rollback with
  the error TYPE only; the reason text is never logged.

Same-origin hardening (gate ag incl. E-3):

- **SO1 (decision: code hardening now, separate origin recommended).** Code cannot enforce a separate
  origin (issuer, `/account` and `/admin/callback` derive from the public host). The code side ships with
  safe defaults (SO2-SO6); the deployment side is documented (SO8); the operator acknowledges SO7 before
  `oauth_enabled`.
- **SO2 (strict fetch metadata on approval POSTs).** New shared helper `Nebu.Web.FetchMetadata`.
  `strict?/1`: exactly one value each of `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: navigate`,
  `Sec-Fetch-Dest: document`, `Sec-Fetch-User: ?1`; ABSENT headers are refused (Chrome 76+, Firefox 90+,
  Safari 16.4+ send all four for a user-activated form submit). Applied to `POST
  /admin/oauth/registrations/:id/approve`, `POST /admin/oauth/clients/:id/revoke` and `POST
  /account/cross_signing_reset/approve`. `lenient?/1`: absent allowed, a present header must have the
  strict value, `Sec-Fetch-Site` must not be `cross-site`/`same-site`; for admin reject (and P2's bulk
  reject) and the other `/account` POSTs (account's `navigation_ok?/2` delegates to it). Refusal: admin 403
  page `fetch_metadata`, account 403 `forbidden`; WARNING naming the failed header NAMES only; nothing
  changed, no audit. Order: `require_admin` -> Phoenix CSRF -> fetch metadata -> freshness (SO4) -> typed
  confirmation (CR8) -> decision.
- **SO3 (no JavaScript in the approval path).** `Sec-Fetch-User: ?1` is reliable only for a plain
  user-clicked submit. The list's Approve button becomes a link to a new confirm page `GET
  /admin/oauth/registrations/:client_id/approve` (verified host first, redirect URIs with host-bound badges,
  re-auth state) whose form posts WITHOUT `data-confirm`; same for the revoke confirm page. Reject keeps
  `data-confirm` (lenient).
- **SO4 (fresh admin re-authentication for approve and revoke).** `GET
  /admin/login/start?mode=reauth&return_to=<path>` (existing admin session only, else a normal login) adds
  `max_age=0` to the existing `prompt=login` and stores `mode`, `return_to` (allowlist
  `\A/admin/oauth/(registrations|clients)(/[A-Za-z0-9_-]{1,128}/(approve|revoke))?\z`, else
  `/admin/oauth/registrations`) and `started_at` in the signed login state. The callback (mode `reauth`)
  runs the normal admin path (state, nonce, admin claim, `put_current_user`, RT), then: `auth_time >=
  started_at - 30 s` (and <= now + 30 s) => fresh, kind `auth_time`; an older `auth_time` => NOT fresh
  (the IdP skipped the login; flash); absent => NOT fresh unless `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME=true`
  (kind `flow`, WARNING). Fresh => session key `admin_reauth = %{"sub", "at", "kind"}` (NOT inside
  `current_user`, which the silent refresh rebuilds), 303 to `return_to`; the POST is never replayed. A
  POST approve/revoke without a fresh marker (same `sub`, `now - at <= 300 s`, `at <= now + 5 s`) => 303 to
  the re-auth start with `return_to` = the confirm page. Reusable within 300 s (batch approvals); the silent
  refresh never writes it; logout drops it.
- **SO5 (`auth_time` fail closed by default, explicit opt-out).** An IdP without `auth_time` cannot prove a
  new sign-in (same rule as E-2 / gate y). Dex reportedly omits it, but with its local/LDAP connectors it
  has no SSO session (a completed flow IS an interactive login), hence the opt-out env (read in
  `config/runtime.exs`, only exact `true`; documented accepted risk). Dev/e2e `docker-compose.yml` sets it
  (Dex); production templates do not (P5 / operator). Revocation without a fresh login: CR10 rpc.
- **SO6 (no framing).** `/admin/oauth/*` responses send `frame-ancestors 'none'` (admin CSP replaced per
  response, like the logo widening) and `X-Frame-Options: DENY`; other admin pages keep `'self'`.
- **SO7 (honest residual risk).** Stopped: fetch/XHR posts (no `navigate`), hidden iframes (`Dest:
  iframe`, no framing), scripted `form.submit()` without a user activation in the submitting window (no
  `Sec-Fetch-User`; story-6 note: the navigation check alone does not stop it), cross-site/same-site posts,
  stale admin sessions. NOT stopped: a same-origin script can open a same-origin popup, read the page (CSRF
  token, host, session id) and submit while the admin clicks inside that popup (transient activation); it
  can trigger a re-auth the admin may complete (the IdP prompt is visible); with the SO5 opt-out and an IdP
  that silently reuses an SSO session the re-auth proves nothing; old browsers without fetch metadata are
  locked out of the strict actions (accepted). Element XSS already yields the user's access token: these
  checks protect the higher-trust actions only. Only a separate origin removes the class.
- **SO8 (deployment recommendation, release note).** Serve Element Web on its own hostname (e.g.
  `element.example.com`, an nginx `server` block with only the static files); the Nebu host keeps
  `/_matrix`, `/.well-known`, `/oauth2`, `/account`, `/admin`. A dedicated ADMIN hostname is impossible
  today (`/admin/callback` derives from `server_name`): new follow-up. Release note: shared origin =
  accepted risk SO7 until Element Web moves.

### P3 adaptation (ATDD, 2026-10-12: this story was written before P3 landed; where it conflicts, THIS wins)

- **a. Consent rows, codes, leases (follow-up ax).** CR4 step 4 also runs `DELETE FROM oauth_consent_requests WHERE client_id = $1`
  (the FK cascades only a client DELETE, which never happens to a revoked row). A consent row that exists at the revoke is gone, so
  its Allow answers `400 invalid_state`; a row that slips in afterwards (a callback that passed `recheck_client/1` before the commit)
  is refused by GET and Allow with the `403 client_rejected` page and no code (`Consent.approved_client/1` already does; now pinned)
  and expires within 5 minutes: accepted. Unused codes stay CR4 step 3; the token exchange of a pre-revoke code fails with `401
  invalid_client`. `oauth_idp_refresh_leases` die with the devices (FK cascade, asserted, no code).
- **b. ONE copy of the fetch-metadata checks.** There is NO `Nebu.Web.FetchMetadata` (SO2 text above is superseded): P3 moved the
  checks to `Nebu.OAuth.BrowserPost`, which is extended: `check/3` option `strict: true` (Origin rules + all four headers required,
  exactly once) for `/account/cross_signing_reset/approve`, and `check_fetch_metadata(conn, :strict | :lenient) :: :ok |
  {:refused, [header_name]}` (no Origin comparison) for the admin controllers; `:lenient` = today's `navigation: true` behaviour.
  Admin refusal: 403 page `data-error="fetch_metadata"`, WARNING with header NAMES only.
- **c. Coexistence with P2's admin page** (bulk removal, host badges, the bulk form below the list): the approve confirm page repeats
  the host badges and redirect-URI binding badges; reject and bulk removal use the lenient level; the list's reject form stays. The
  confirm link / form keep carrying `page` and `logos` so the redirect returns to where the list was opened (not pinned).
- **d. Follow-up ids.** This story closes aj, ag, "(ag) extended" and ax; it appends **ba** (configurable admin public URL /
  dedicated admin hostname, SO8), **bb** (batched revoke of very large clients, CR11), **bc** (optional UI for revoke-all). au-az
  and earlier are taken.
- **e. Migration 000046** is final (000044 = P2, 000045 = P3 exist; no renumbering). P2's `oauth_clients_source_key_pending_check`
  (source_key only while pending) is untouched; the revoke UPDATE never touches `source_key`.
- **f. Trap found by the ATDD run:** the CR2 "Trigger core" snippet lets `pending -> revoked` pass (neither branch applies, the
  CHECK accepts a revoked shape). Add `IF NEW.status = 'revoked' AND OLD.status <> 'approved' THEN RAISE ... check_violation`
  (pinned: pending / rejected -> revoked).
- **g. Redirect status.** Phoenix `redirect/2` answers `302`; the admin tests accept `302` or `303` wherever this story says "303".
- **h. Contracts pinned by the tests** (their moduledocs are authoritative): `Nebu.OAuth.revoke_client(client_id, actor, reason:, audit:)
  :: {:ok, %{devices: n}} | {:error, :not_approved | {:audit, _} | _}` (the audit fun gets the torn-down `{user_id, device_id}` pairs);
  test seams `:nebu_http, :oauth_session_lock_hook` (after the `FOR SHARE` in `insert_replacing_device/1` / `rotate/1`) and
  `:oauth_client_revoke_hook` (in `ClientStore.revoke/3` after step 1); the marker `"admin_reauth" => %{"sub", "at", "kind"}`;
  login state keys `mode`, `return_to`, `started_at`; approve audit metadata `%{"reauth" => kind}`; revoke audit `devices`,
  `reauth`, `reason`; `oauth_sessions_revoked_all` metadata `devices`; the session count is read through `OAuthSessionStore`
  (seam `:oauth_session_repo`) so an unreadable count shows `?`; HTML contract in `oauth_admin_clients_test.exs`
  (approve confirm page `data-page="oauth-approve-confirm"` + `[data-role="approve-confirm-form"]` / `approve-confirm`, revoke
  confirm `oauth-revoke-confirm` + `revoke-device-count` / `revoke-confirm`, `clients-summary`).

## Acceptance Criteria

### AC1 — Migration 000046 up/down (CR1-CR3)

1. Applies after 000043 (and after P2/P3 migrations); `.up.sql` + `.down.sql`; idempotent guards like 000040.
2. Table test: each status x wrong column shape refused by the CHECK; `revoked_reason` > 500 chars refused.
3. The runtime role cannot INSERT a row with status `revoked` or any `revoked_*` set.
4. Down without revoked rows restores 000040's CHECKs, insert policy and trigger function verbatim and
   drops the columns; down with a revoked row RAISES (never turns revoked into approved). Up -> down -> up
   inside a rolled-back privileged transaction (000041 pattern, `with_privileged_conn/1`).

### AC2 — Guard trigger (CR2)

1. approved -> revoked with `revoked_by`/`revoked_at` succeeds; `last_used_at` stays writable.
2. `check_violation` for: revoked -> approved/pending/rejected; changed `revoked_by`/`revoked_at`/
   `revoked_reason` on a revoked row; approved -> revoked with NULL `revoked_by` or changed `approved_by`;
   pending -> revoked; rejected -> revoked; approved -> rejected.
3. DELETE of a revoked row matches 0 rows (FORCE RLS); `oauth_pending_protection_test.exs` stays green.

### AC3 — Cascade teardown (CR4)

1. Fixture: approved client A with 3 devices of 2 users (rotated rows, one expired session), one unused and
   one used code, two authz requests; client B with 1 device. After `Nebu.OAuth.revoke_client/3`: no
   `matrix_sessions` row of A, A's 3 devices with device / one-time / fallback keys gone, both codes have
   `used_at`, no authz request of A, A `revoked` with attribution and reason; B untouched.
2. Bound raw-JWT credentials of a revoked device are denylisted after the commit.
3. `:audit` returns `{:error, _}` => everything rolled back (status, sessions, devices, codes, requests).
4. A teardown statement failing inside step 2 (repo seam) => rollback, `{:error, _}`, no partial state.
5. Pending / rejected / revoked / unknown client => `{:error, :not_approved}`, nothing changed.
6. 200 devices revoke in one call within the timeout.

### AC4 — Entry points refuse `revoked` (CR6)

1. `GET /oauth2/authorize` => 403 page `client_rejected`, no redirect.
2. An authz request created before the revoke => the callback answers `invalid_state`.
3. Code grant with a pre-revoke code and refresh grant with the former refresh token => `401
   invalid_client`, RFC 6749 shape, no `errcode`.
4. `POST /oauth2/revoke` with a former token => `200 {}`, byte-identical to an unknown token.
5. A Matrix request with the former access token => `401 M_UNKNOWN_TOKEN`.
6. DCR with identical metadata => `201`, same `client_id`, status still `revoked`, one row for the hash, no
   audit row; authorize with it => `client_rejected`.

### AC5 — Race: revoke vs issuance and rotation (CR5)

1. Issuance pauses (compile-guarded test hook in `insert_replacing_device/1` after the client lock) while
   a revoke starts: the revoke blocks; after release the issuance commits and the revoke then deletes that
   session and device. End: 0 sessions of the client.
2. Revoke pauses (hook after step 1, before commit) while a code grant starts: the issuance blocks on
   `FOR SHARE`; after release => `400 invalid_grant`, the code stays used, 0 sessions.
3. As 2 for a refresh rotation => `400 invalid_grant`, 0 sessions, device gone.
4. 20 parallel token requests + 1 revoke (no hook): 0 sessions at the end; every response is a 200 whose
   access token is afterwards `401 M_UNKNOWN_TOKEN`, or `invalid_client` / `invalid_grant`; no deadlock.

### AC6 — Admin lists and revoke (CR7-CR9, SO3)

1. `GET /admin/oauth/clients` lists only approved clients with the CR7 fields; counts correct; count read
   error => `?`; non-admin => redirect `/admin/login`.
2. `GET /admin/oauth/clients/revoked` lists revoked clients with revoked by/at and reason.
3. The confirm page shows host, device count, consequences, `confirm_host` + `reason` inputs, no
   `data-confirm`; the approve confirm page shows host and redirect URIs, no `data-confirm`.
4. Valid POST (CSRF, strict fetch metadata, fresh marker, right host) => 303 to the approved list with a
   success flash and exactly one `oauth_client_revoked` row with CR9 metadata.
5. Wrong/missing `confirm_host` => 303 to the confirm page, error flash, nothing changed, no audit.
6. Missing/wrong Phoenix CSRF token (no `admin_csrf_bypass`) => 403, nothing changed.
7. A second revoke of the same client => error flash, no second audit row.
8. HTML contract (shared with Gherkin): `data-page="oauth-clients"` / `"oauth-revoked-clients"`, rows
   `[data-role="oauth-approved-row"][data-client-id]` / `[data-role="oauth-revoked-row"]`, link
   `[data-role="revoke-client"]`, form `[data-role="revoke-confirm-form"]`, input `name="confirm_host"`,
   approve link `[data-role="review-approve"]`, approve confirm page `data-page="oauth-approve-confirm"` with form
   `[data-role="approve-confirm-form"]`, revoke confirm `data-page="oauth-revoke-confirm"` with
   `[data-role="revoke-device-count"]`, summary `[data-role="clients-summary"]`, sidebar `data-navkey="oauth-approved-clients"` /
   `"oauth-revoked-clients"`.

### AC7 — Fetch metadata and framing (SO2, SO6)

1. Table test of `BrowserPost.check_fetch_metadata/2` (`:strict` / `:lenient`) and `check/3 strict: true`: absent / correct / wrong / duplicated values per header; no second copy of the checks exists.
2. Admin approve and revoke: each header absent, wrong (`cors`, `iframe`, `?0`, `same-site`,
   `cross-site`, `none`) or duplicated => 403 `fetch_metadata`, nothing changed, no audit, WARNING without
   header values.
3. Admin reject: absent headers accepted; `cross-site` / `same-site` / `Dest: iframe` refused.
4. `POST /account/cross_signing_reset/approve` without fetch metadata => 403 `forbidden`, nothing approved;
   decline, device delete and logout keep their rules (existing tests green).
5. `/admin/oauth/*` responses carry `frame-ancestors 'none'` + `X-Frame-Options: DENY`; `?logos=1`
   widening still works; another admin page keeps `frame-ancestors 'self'`.

### AC8 — Fresh admin re-authentication (SO4, SO5)

1. POST approve/revoke without a marker, with one older than 300 s, or of another `sub` => 303 to
   `/admin/login/start?mode=reauth&return_to=<confirm page>`, nothing changed.
2. Mode `reauth` sends `prompt=login` and `max_age=0`; a `return_to` outside the allowlist (absolute URL,
   `//evil`, `/admin/users`, encoded `..`) becomes the default.
3. Callback (`:admin_oidc_token_override`): fresh `auth_time` => marker kind `auth_time`, 303 to
   `return_to`; older `auth_time` => no marker + error flash; no `auth_time` => no marker unless
   `:admin_reauth_allow_missing_auth_time` (then kind `flow` + WARNING); non-admin token => 403 as today.
4. The silent pre-expiry refresh and a normal login never create a marker.
5. Approve/revoke audit `reauth` equals the marker kind.
6. Story-1 approve tests in `oauth_admin_test.exs` use a new helper `fresh_admin_conn/3` (marker + strict
   headers); all other assertions there unchanged.

### AC9 — Operator RPC (CR10)

1. `Nebu.Release.revoke_oauth_client/2` = AC3 behaviour, actor `operator:rpc`; `{:ok, %{devices: n}}` /
   `{:error, :not_approved}`.
2. `Nebu.Release.revoke_all_oauth_sessions/0` ends every OAuth device (legacy sessions/devices untouched),
   `{:ok, n}`, one `oauth_sessions_revoked_all` audit row; a second call `{:ok, 0}`.

### AC10 — Gherkin e2e (written and typechecked only)

`e2e/features/admin/oauth-client-revocation.feature` (`@oauth-revocation`), real flows (DCR via the real
endpoint, UI clicks, re-auth through Dex, DB read-only):
1. Approve via the confirm page + re-auth; the client appears under Approved Clients with 0 sessions.
2. Revoke with the right host: success toast, listed under Revoked Clients, DB shows `revoked` and one
   `oauth_client_revoked` row; the client's authorize URL shows the not-approved page.
3. A wrong host changes nothing.
4. A `fetch()` POST to the revoke URL from an admin page is refused with 403.
The existing `oauth-client-approvals.feature` approve steps are adapted (confirm page + re-auth).
`tsc --noEmit` and `bddgen --tags "@oauth-revocation or @oauth-approvals"` pass.

### AC11 — Logging law

No token, code, CSRF token, cookie, reason text, header value or client metadata in any new log line
(`capture_log` in AC3/AC7/AC8).

### AC12 — Documentation

ADR-033 section "Client revocation and same-origin hardening (story oauth-client-revocation)" with CR1-CR12,
SO1-SO8, the lock order and the CR5 ADR-020 note; "Database invariants" and "Approval page" point to it;
07-deployment and follow-ups as in "Doc edits"; `adr_033_test.exs` pins updated if any pin "a decision is
final".

## Acceptance Tests

| File (new unless noted) | Kind | Covers |
|---|---|---|
| `server/test/nebu/migration/000046_oauth_client_revocation_test.exs` | static + integration | AC1, AC2 |
| `server/test/nebu/oauth/oauth_client_revocation_test.exs` | integration | AC3, AC4, AC9, AC11 (+ consent rows, leases) |
| `server/test/nebu/oauth/oauth_client_revocation_race_test.exs` | integration | AC5 |
| `server/test/nebu/oauth/oauth_admin_clients_test.exs` | integration | AC6, AC7(2,3,5), AC8(1,5), AC11 |
| `server/test/nebu/admin/admin_reauth_test.exs` | unit | AC8(2,3,4), SO5 config |
| `server/test/nebu/oauth/browser_post_strict_test.exs` | unit | AC7(1) |
| `server/test/nebu/oauth/oauth_account_hardening_test.exs` (modify) | integration | AC7(4) |
| `server/test/nebu/oauth/oauth_admin_test.exs` (modify) | integration | AC8(6), SO3 confirm page, approve audit `reauth` |
| `server/test/nebu/oauth/oauth_test_support.exs` (modify) | helpers | `mark_revoked!/3`, `fresh_marker/3`, `put_strict_fetch_headers/1`, `idp_refresh_for/1`, `insert_row!` status `revoked` |
| `e2e/features/admin/oauth-client-revocation.feature` + `e2e/step-definitions/admin/oauth-client-revocation.steps.ts` + `e2e/fixtures/oauth-admin.ts` (+ `db.ts`, adapted `oauth-client-approvals.*`) | e2e (typecheck + bddgen) | AC10 |

## Dev Notes

### Code pointers (read before coding)

- `server/priv/migrations/000040_*.up.sql`: CHECKs (~l.55-75), RLS/insert policy (~l.108-125), guard
  function (~l.140-170): copy it verbatim into 000046 up (plus the transition) and into 000046 down.
- `000041`: `oauth_codes` guard (only `used_at` NULL -> NOT NULL), delete only expired + 24 h;
  `oauth_authz_requests` DELETE allowed. `000042`: RESTRICT FK, index `idx_matrix_sessions_client_id`.
- `server/lib/nebu/oauth/client_store.ex`: `decide/3` (transaction + `:audit`, rescue list),
  `get_pending_registrations/1` (paging), `:oauth_repo` seam; also replace the `inspect(other)` log (~l.295, an).
- `server/lib/nebu/matrix/session/oauth_session_store.ex`: `insert_replacing_device/1` (~l.167), `rotate/1`
  + `lock_device_of/2` (~l.227-340), `end_device/3` (~l.439, takes `repo`); seam `:oauth_session_repo`.
- `server/lib/nebu/matrix/oauth_session.ex`: `end_device_session/2`, private `after_commit/2` (~l.490).
- `server/lib/nebu/matrix.ex`: `oauth_issue_session/1` (~l.215), `oauth_refresh_session/4`,
  `end_device_session/2` (~l.660); add `oauth_end_client_sessions/2`, `oauth_after_device_teardown/1`,
  `oauth_client_session_counts/1`, `oauth_end_all_sessions/0`.
- `server/lib/nebu/oauth/authorize.ex` `client_status/1` (~l.185), `recheck_client/1` (~l.330);
  `token.ex` `authenticate/3` (~l.156), issuance (~l.300-320), refresh (~l.400); `http.ex` `register/1`.
- `server/lib/nebu/oauth.ex`: add `revoke_client/3`, `approved_clients/1`, `revoked_clients/1`.
- `server/lib/nebu/admin/oauth_registrations_controller.ex`: `decide/5`, `write_audit/4`, `actor_id/1`,
  `normalize_reason/1` (share via a small `Nebu.Admin.OAuthAdminHelpers`); template
  `templates/oauth_registrations/index.html.heex` (approve becomes a link).
- `server/lib/nebu/admin/auth.ex`: `do_login_start/2` (~l.415), `callback/2`, `do_callback/3`,
  `normal_callback/3` (~l.480-560), `put_current_user/2` (~l.282, renews the session, also used by refresh).
- `server/lib/nebu/admin/router.ex` (`:browser` pipeline, `@csp`, OAuth routes ~l.235), `layouts.ex`
  `@oauth_nav_children` (~l.94).
- `server/lib/nebu/oauth/browser_post.ex` (P3's single shared copy: extend it, SO2 / P3 adaptation b) and
  `server/lib/nebu/oauth/account.ex` `checked_post/5` (pass `strict: true` for `["cross_signing_reset", "approve"]`); moduledocs
  of both (the navigation check does not stop a scripted submit by itself).
- `server/lib/nebu/compliance/audit_writer.ex` `@known_actions` (~l.117): add `oauth_client_revoked`,
  `oauth_sessions_revoked_all` with the usual comment. `server/lib/nebu/release.ex`: CR10 (release `nebu`).
- Tests: `oauth_test_support.exs` `insert_row!/6`, `oauth_client!/2`, `session!/4`, `refresh!/4`,
  `cleanup_clients/1` (privileged, sessions first; works for revoked rows), `with_privileged_conn/1`;
  `oauth_admin_test.exs` `admin_conn/3`, `audit_rows/2`; `oauth_device_teardown_test.exs` JWT binding helpers.

### Files

Create: `server/priv/migrations/000046_oauth_client_revocation.{up,down}.sql`;
`server/lib/nebu/admin/oauth_clients_controller.ex`, `oauth_clients_html.ex`,
`templates/oauth_clients/{index,revoked,revoke_confirm}.html.heex`,
`templates/oauth_registrations/approve_confirm.html.heex`; the tests and e2e files above.
Modify: `client_store.ex`, `oauth.ex`, `authorize.ex`, `token.ex`, `account.ex`, `browser_post.ex`, `consent` (nothing, already correct), `matrix.ex`,
`oauth_session.ex`, `oauth_session_store.ex`, `oauth_registrations_controller.ex` (+ template, action
`approve_confirm`), `auth.ex`, `router.ex`, `layouts.ex`, `audit_writer.ex`, `release.ex`,
`config/runtime.exs` (`NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME` -> `:nebu_http,
:admin_reauth_allow_missing_auth_time`), `docker-compose.yml` (server env `"true"` with comment "dev Dex
omits auth_time; production: see 07-deployment"), existing e2e approve steps, docs.

### Trigger core (000046)

```sql
IF OLD.status = 'approved' AND NEW.status = 'revoked'
   AND (NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at)
       IS NOT DISTINCT FROM (OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at)
   AND OLD.revoked_by IS NULL AND OLD.revoked_at IS NULL
   AND NEW.revoked_by IS NOT NULL AND NEW.revoked_at IS NOT NULL THEN
    NULL;  -- allowed; the identity/metadata immutability check below still runs
ELSIF OLD.status <> 'pending'
   AND (NEW.status, NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at,
        NEW.revoked_by, NEW.revoked_at, NEW.revoked_reason)
       IS DISTINCT FROM
       (OLD.status, OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at,
        OLD.revoked_by, OLD.revoked_at, OLD.revoked_reason) THEN
    RAISE EXCEPTION 'oauth_clients: a decision (%) is final; only approved -> revoked is allowed', OLD.status
        USING ERRCODE = 'check_violation';
END IF;
```

Keep the 000040 "cannot become pending again" test first; pending -> approved/rejected keeps `revoked_*`
NULL (CHECK). Down: `DO $$ BEGIN IF EXISTS (SELECT 1 FROM oauth_clients WHERE status = 'revoked') THEN
RAISE EXCEPTION ...; END IF; END $$;` before restoring.

### Traps

1. Nested `repo.transaction` joins the outer one only with the same repo module in the same process: pass
   the outer repo through `oauth_end_client_sessions/2` -> `end_device/3`; no Tasks inside.
2. `end_device/3` returns `{:error, _}` instead of raising: convert to `repo.rollback/1` inside the outer
   transaction, or a half teardown commits.
3. Never call `Nebu.Matrix.end_device_session/2` inside the transaction (its `after_commit` would run
   before the outer commit; its rescue hides errors).
4. The client `FOR SHARE` must be the FIRST lock in issuance and rotation; after the devices lock it
   deadlocks with the revoke.
5. Live `oauth_codes` cannot be deleted; a later presentation never reaches reuse detection (client lookup
   fails first).
6. Put the `admin_reauth` marker AFTER `put_current_user/2` (session renewal) in the callback.
7. CSRF tests must not set `admin_csrf_bypass` (real token from the GET form + session).
8. The admin CSP comes from the router plug: replace `frame-ancestors 'self'` per response in the OAuth
   controllers, keeping the logo widening working on the new value.
9. Session counts read `matrix_sessions`: via the facade, never SQL in `ClientStore`.
10. P2 edits `oauth_registrations_controller.ex` + template in parallel: keep the approve change small (new
    action + link); expect a merge at integration.

### Doc edits

- `docs/architecture/07-deployment.md`: preconditions row `aj` -> "closed by oauth-client-revocation
  (server)"; row `ag` -> "server side closed by oauth-client-revocation (strict fetch metadata, fresh admin
  re-auth, no framing); operator: acknowledge SO7 or move Element Web to its own origin". New "### Revoking a
  client" after "Activation steps" (UI path, what is removed, finality per metadata hash, `bin/nebu rpc
  'Nebu.Release.revoke_oauth_client("<client_id>", "<reason>")'`). "Kill switch": replace the
  `DELETE FROM matrix_sessions WHERE auth_api = 'oauth'` block, the one-device variant and the NOTE paragraph
  by `bin/nebu rpc 'Nebu.Release.revoke_all_oauth_sessions()'` (after the switch-off) and, for one device,
  the admin user page device delete. "Registrations": revoked rows are kept and never re-approvable. "Reverse
  proxy": SO8 with an example nginx `server` block for Element Web. OAuth configuration section:
  `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME` (default off, risk). "Accepted risks": SO7, the opt-out
  risk; (ai): revoke-all exists as rpc, automatic revocation on switch-off is still a follow-up.
- `docs/stories/oauth-broker/follow-ups.md`: aj, ag, "(ag) extended" closed (server) -> this story; an:
  runbook and `inspect(other)` parts resolved; ai: rpc revoke-all added; ax closed; append ba (configurable admin
  public URL / dedicated admin hostname, SO8), bb (batched revoke of very large clients, CR11), bc (optional UI for revoke-all).
- ADR-033: AC12.

### Architecture compliance

ADR-018 (inline SQL), ADR-019, ADR-020 (Admin -> `Nebu.OAuth` only; OAuth -> `Nebu.Matrix` facade; CR5
cross-table lock documented), cluster safety (row locks + guarded UPDATEs; the marker lives in the signed
session), logging law (AC11), no new secret at rest.

### Testing commands (isolated env, see the epic brief)

- After adding 000046: `docker rm -f nebu-oauth-pg`, then `quick.sh --migrate`.
- `quick.sh "mix test --include integration test/nebu/oauth/oauth_client_revocation_migration_test.exs test/nebu/oauth/oauth_client_revocation_test.exs test/nebu/oauth/oauth_client_revocation_race_test.exs test/nebu/oauth/oauth_admin_clients_test.exs test/nebu/web/fetch_metadata_test.exs"`
- `quick.sh "mix test --include integration test/nebu/oauth"` (pending protection, admin, device teardown,
  token, revoke, account hardening green).
- Full gate: `integration.sh` in the background after `cleanup.sh`; compare with `known.txt`.
- e2e: scratchpad copy of `e2e`, `npx tsc --noEmit`, `npx bddgen --tags "@oauth-revocation or @oauth-approvals"`.

### Out of scope

UI for revoke-all and for `oauth_*` keys (ai), automatic revocation on switch-off, a dedicated admin
hostname, bulk reject (P2), authorize freshness (P3), template changes (P5), account-page audit rows (ab).

## Manual verification

Fail closed until verified (the defaults refuse):

1. Dex v2.45.1: does the admin id_token carry `auth_time`; are `max_age=0` / `prompt=login` honoured? If
   `auth_time` is absent, approve/revoke need `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME=true` (SO5) or rpc.
2. Chrome, Firefox, Safari (current): mouse click AND Enter-key submit on the approve / revoke confirm pages
   and the `/account` reset approve send `Sec-Fetch-Site: same-origin`, `Mode: navigate`, `Dest:
   document`, `User: ?1` through the reference nginx (devtools).
3. Element X / FluffyChat open `/account` in a system browser tab that sends fetch metadata: approve a
   cross-signing reset end to end.
4. From a same-origin page: a `fetch()` POST and a hidden-iframe form submit to the revoke URL are refused.
5. Revoke a client with a live Element Web session: Element Web is logged out at its next request; the
   device disappears from the user's device list.
6. `bin/nebu rpc` works in the reference containers for both CR10 functions.

## Open questions

1. Offer the SO5 opt-out in the production templates while Dex is the reference IdP, or change the IdP
   (gate y)? Proposed: templates stay strict; P5 documents the choice.
2. Clients with > 10 000 devices: two-phase revoke (status first, then batched teardown)? Proposed:
   follow-up after a measurement.
3. The adapted e2e approval scenarios rely on the compose opt-out if the CI Dex omits `auth_time`.
   Acceptable for CI?

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (bmad-dev-story, phase 2, P4)

### Debug Log References

- Migration test needs a fresh throwaway DB (`docker rm -f nebu-oauth-pg` before the first `quick.sh` run after adding 000046).
- `Phoenix.Controller.assign/3` does not exist: the 403 page helper uses `Plug.Conn.assign/3`.
- A test name longer than the atom limit (~255 bytes) aborts compilation (`SystemLimitError`): keep ExUnit names short.
- The test env logs at `:warning`: tests that assert an INFO line (or that nothing leaks at `:debug`) call `Logger.configure(level: :debug)`.

### Completion Notes List

- Story created by bmad-create-story (phase 2, P4).
- **Migration 000046** (`.up` / `.down`): status `revoked`, `revoked_by/at/reason`, re-created status / decision / reason CHECKs, INSERT policy, guard function with `approved -> revoked` as the ONLY new transition and an explicit refusal of `pending -> revoked` / `rejected -> revoked` (trap f); `.down` refuses while a revoked row exists, restores 000040 verbatim.
- **Revocation core:** `Nebu.OAuth.revoke_client/3` -> `ClientStore.revoke/3` (one transaction, 120 s: status UPDATE, `Nebu.Matrix.oauth_end_client_sessions/2` (locked per-device teardown inside the transaction, repo-mismatch guard), `used_at` of unused codes, authz + consent requests deleted, audit fun) and `oauth_after_device_teardown/1` after the commit. `OAuthSessionStore.insert_replacing_device/1` and `rotate/1` lock the client row `FOR SHARE` first (CR5; `:client_not_approved` => `invalid_grant`); compile-guarded test seams `:oauth_session_lock_hook` / `:oauth_client_revoke_hook`.
- **Entry points:** authorize / callback / consent / token / revoke / DCR dedup already treated every non-approved status like a rejected client; asserted by the staged tests, only the token issuance branch for `:client_not_approved` was added.
- **Admin:** `OAuthClientsController` (+ HTML, templates `index`, `revoked`, `revoke_confirm`, `fetch_metadata`), approve confirm page + strict POST in `OAuthRegistrationsController` (list Approve is a link), `OAuthAdminHelpers` (gate order: fetch metadata, then marker; audit, actor, error type), sidebar entries, routes, path-aware CSP (`frame-ancestors 'none'` + `X-Frame-Options: DENY` under `/admin/oauth/`).
- **Fetch metadata:** ONE copy in `Nebu.OAuth.BrowserPost` (`check/3 strict: true`, `check_fetch_metadata/2 :strict | :lenient`); account reset approval strict, admin approve / revoke strict, reject and bulk removal lenient.
- **Fresh admin re-auth:** `Auth.login_start` mode `reauth` (admin session only; `prompt=login`, `max_age=0`, allowlisted `return_to`, `started_at`), callback marker `admin_reauth` after `put_current_user`, `reauth_fresh/1`, `reauth_start_path/1`; fail closed on absent `auth_time` unless `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME=true` (read exactly in `config/runtime.exs`; set only in the dev `docker-compose.yml`).
- **Operator RPC:** `Nebu.Release.revoke_oauth_client/2`, `revoke_all_oauth_sessions/0` (batches of 500; audit `oauth_sessions_revoked_all`, partial runs audited as `failure`); `Nebu.OAuth.normalize_reason/1` is the single copy of the reason normalisation (admin + release).
- **Logging:** error TYPES only; Phoenix `filter_parameters` extended with `reason`, `confirm_host`, `_csrf_token`, `csrf_token`; `ClientStore` no longer logs `inspect/1` of results (follow-up an).
- **Docs:** ADR-033 section (CR1-CR12, SO1-SO8) + pointers, 07-deployment (rows aj / ag, "Revoking a client", kill-switch rpc, SO8 nginx block, SO7 + opt-out risk, migration 000046), follow-ups (aj / ag / ax closed, ai / an updated, ba / bb / bc added).
- **Pre-dev test review (10 MINOR) fixed in the staged tests:** (1) race tests prove the blocked side by polling `pg_stat_activity` for a lock wait; (2) the failing delete targets the user of the LAST sorted pair (real partial rollback); (3) rollback fixtures bind a JWT and assert no denylist / binding kept; (4) log refutations match `header=value` forms; (5) revoked-client approve / reject paths and a bulk removal with approved / revoked rows added; (6) check-order tests (CSRF before fetch metadata, marker before the typed host); (7) e2e keyboard-only scenario [AC10.5] with label / aria assertions; (8) Dex grant wait races the grant button against the redirect; (9) the audit-failure flash is only asserted to be an error flash; (10) comma-merged duplicated header values for all four headers. INFO items: debug logging admitted where a test asserts it; the approve confirm page keeps "It will be able to sign in your users."; no `adr_033_test` pin said "a decision is final".
- **Existing tests adapted** (they approved a reset without fetch metadata): `oauth_account_test.exs` (`act!/3`), `oauth_account_ops_test.exs`.
- **Verification** (isolated env): story tests (migration 20, revocation + race + strict + admin_clients + admin_reauth + docs + hardening: all green), `test/nebu/oauth` + `test/nebu/migration` + admin_reauth: 2385 passed on a fresh DB; `test/nebu/web` + `test/nebu/admin` + compliance: only known families (RoomsFallbackName, TemporaryCapture, TraceMap, WarRoom, LogStore retention); `test/nebu/matrix`: known families (MutualRooms, SyncConcurrent, SsoLogin) plus `SpacesFoundationIntegrationTest` (order-dependent, 4/4 green alone); full `mix test --include integration`: 5809 / 5843 passed, the 34 failures are all known families (AdminOidcLogin / OidcPlug denylist / ConfigController sso-schemes are green on a fresh DB); prod compile: only the known `event_dispatcher/server.ex` warning; e2e `tsc --noEmit` and `bddgen --tags "@oauth-revocation or @oauth-approvals"` pass (not executed: needs the compose stack with Dex).
- **Deviations:** (a) the guard function raises explicitly for `pending/rejected -> revoked` (story trap f) instead of the story's "Trigger core" snippet; (b) `return_to` allowlist also admits `/admin/oauth/clients/revoked` (the test pins it); (c) the facade `oauth_end_client_sessions/2` refuses a repo that is not the session store's repo (`:repo_mismatch`), which is also what makes the `:oauth_session_repo` seam test fail closed; (d) `Nebu.OAuth.normalize_reason/1` replaces the planned `Nebu.Admin.OAuthAdminHelpers` copy of the normalisation (Release must not depend on Admin); (e) `ClientStore.fetch_by_client_id/1` also returns `client_host` and the `revoked_*` fields (the confirm pages need them).
- **Open items:** manual verification list of the story (Dex `auth_time` / `max_age`, browsers send all four fetch-metadata headers on click AND Enter, Element X / FluffyChat reset approval, `bin/nebu rpc` in the reference containers, Element Web logout after a revoke); SO8 / follow-ups ba, bb, bc; open question 3 (CI Dex relies on the compose opt-out).

### Review cycle 1 (code review 1 MAJOR + 5 MINOR, Kassandra 2 MEDIUM + 3 LOW, UX 1 blocking + advisories)

- **M1 (ADR-020):** `Nebu.OAuth.check_fetch_metadata/2` (`defdelegate` to `BrowserPost`); `OAuthAdminHelpers` no longer names `Nebu.OAuth.BrowserPost`.
- **m1 / Kassandra M-2:** `lock_client!` runs under `SET LOCAL lock_timeout = '2s'` (reset after the lock); a timeout rolls back as `:client_locked` => `unavailable` (503 + Retry-After, no `error` member). Two-phase revoke NOT done (not contained): ADR CR11 corrected, follow-up bb extended (rpc has the same limit; post-commit work and nginx's 60 s read timeout noted). New race test AC5.5 (refresh and code grant get 503 within the bound while a revoke holds the row).
- **m2:** `ClientStore.revoke/3` retries ONCE on a deadlock (SQLSTATE 40P01, surfaced as `:deadlock` / `Postgrex.Error`; the session store raises `DeadlockError` instead of the generic error); ADR lock-order caveat names `delete_for_user/1` and `delete_by_code_hash/1`. Tests: one deadlock retried, a persistent one gives up after one retry, other errors are not retried (the test hook `:oauth_client_revoke_hook` may now return `{:error, reason}`).
- **m3:** runbook commands wrap the rpc calls in `IO.inspect(...)`. **m4:** stale ATDD wording removed from four test moduledocs. **m5:** `e2e/fixtures/db.ts` comment (client ids are base64url).
- **i1:** cross-client takeover note in the ADR (CR4). **i2:** noted under CR11 / bb. **i5 / UX A11:** the 403 page back link names the page the admin came from (`gate/3` passes the confirm path).
- **Kassandra M-1:** the `admin_reauth` marker is path-bound (`"path"` = the confirm page of one client and action, taken from the allowlisted `return_to`) and consumed by a successful approve / revoke (a refused typed host keeps it); `Auth.reauth_fresh/2`, `Auth.consume_reauth/1`; `T.fresh_marker/4`, the `fresh_admin_conn` helpers and the e2e steps follow (one sign-in per decision). ADR SO4 / SO7 and the `BrowserPost` / `account.ex` moduledocs now say "any user click on the origin"; SO8 stays the only full fix.
- **Kassandra L-1:** `Cache-Control: no-store` on every `/admin/oauth/*` response. **L-2:** reject and bulk removal need the STRICT fetch metadata (no marker); tests and `oauth_admin_test` helpers send the four headers on POST. **L-3:** the approve confirm page warns "N revoked client(s) share this host" (`ClientStore.revoked_count_for_host/1`). INFO: the `/account` 403 text mentions browsers without fetch metadata (Safari before 16.4); 07-deployment notes Entra and `max_age=0`.
- **UX:** blocking WCAG 2.5.3 fixed (button name "Approve client <name>"); A1 unreadable count shows "? (could not be read)" and the revoke page says devices are removed anyway; A2 a host mismatch is shown with the field (`aria-invalid`, `aria-describedby`, one alert, flash key `confirm_host_error`); A3 re-auth notice above the revoke buttons; A4 static `role=status` removed; A6 autofocus on the typed host, Cancel before Revoke; A7 `h2` for the consequences; A8 "Host column"; A9 scroll regions are focusable `role=region` with a label; A10 aria-labels carry the host; A12 the approve page says Approve is not blocked by the shared-hosting / public-suffix badges. A5 (e2e copy) was not part of the list.
- **Verification:** see the Completion Notes of this cycle in the final report (story tests, `test/nebu/oauth` + migration, web/admin/matrix, full integration run, prod compile, e2e `tsc` + `bddgen`).

### File List

Server (lib): `server/lib/nebu/oauth/client_store.ex`, `server/lib/nebu/oauth.ex`, `server/lib/nebu/oauth/token.ex`, `server/lib/nebu/oauth/browser_post.ex`, `server/lib/nebu/oauth/account.ex`, `server/lib/nebu/oauth/account_pages.ex` (review cycle 1), `server/lib/nebu/matrix.ex`, `server/lib/nebu/matrix/oauth_session.ex`, `server/lib/nebu/matrix/session/oauth_session_store.ex`, `server/lib/nebu/compliance/audit_writer.ex`, `server/lib/nebu/release.ex`, `server/lib/nebu/admin/auth.ex`, `server/lib/nebu/admin/router.ex`, `server/lib/nebu/admin/layouts.ex`, `server/lib/nebu/admin/oauth_registrations_controller.ex`, `server/lib/nebu/admin/oauth_registrations_html.ex`, `server/lib/nebu/admin/templates/oauth_registrations/index.html.heex`; new: `server/lib/nebu/admin/oauth_admin_helpers.ex`, `server/lib/nebu/admin/oauth_clients_controller.ex`, `server/lib/nebu/admin/oauth_clients_html.ex`, `server/lib/nebu/admin/templates/oauth_clients/{index,revoked,revoke_confirm,fetch_metadata}.html.heex`, `server/lib/nebu/admin/templates/oauth_registrations/approve_confirm.html.heex`.

Server (config, migrations): `server/config/config.exs`, `server/config/runtime.exs`; new `server/priv/migrations/000046_oauth_client_revocation.{up,down}.sql`; `docker-compose.yml`.

Tests / e2e (staged by ATDD, fixed or extended here): `server/test/nebu/migration/000046_oauth_client_revocation_test.exs`, `server/test/nebu/oauth/{oauth_client_revocation_test,oauth_client_revocation_race_test,oauth_admin_clients_test,browser_post_strict_test,oauth_client_revocation_docs_test,oauth_account_hardening_test,oauth_admin_test,oauth_test_support}.exs`, `server/test/nebu/admin/admin_reauth_test.exs`; adapted: `server/test/nebu/oauth/{oauth_account_test,oauth_account_ops_test}.exs`; e2e `e2e/features/admin/{oauth-client-revocation,oauth-client-approvals}.feature`, `e2e/step-definitions/admin/{oauth-client-revocation,oauth-client-approvals}.steps.ts`, `e2e/fixtures/{oauth-admin,db}.ts`.

Docs: `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/architecture/07-deployment.md`, `docs/stories/oauth-broker/follow-ups.md`, this story file.

## Change Log

- 2026-10-12: story created (ready-for-dev).
- 2026-10-12: implemented (dev-story): migration 000046, revocation core with the CR5 lock, admin lists / revoke / approve confirm pages, strict fetch metadata and fresh admin re-authentication, operator rpc, documentation; status review.
- 2026-10-12: review cycle 1 addressed (ADR-020 delegate, lock timeout + deadlock retry, path-bound single-use marker, strict reject / bulk removal, no-store, revoked-host badge, UX fixes, docs); status review.
