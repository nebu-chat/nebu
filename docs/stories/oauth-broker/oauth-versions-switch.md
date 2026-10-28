---
story_id: oauth-versions-switch
title: "`/versions` switch to v1.12-v1.15 on the shared OAuth liveness predicate, metadata conformance contract, operator activation checklist (last story of the epic)"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-12
branch: feature/migrate-to-oauth2
---

## Summary

Story 9 of epic `oauth-broker`, the LAST story of the epic (spec section 13 row 9; spec section 3a
"`/versions` (final, nach Pflichten-Audit)"; spec section 14 decisions 3 and 10 and the "Folgerungen").
Stories 1-5 are committed; story 6 (`oauth-account-management.md`, account page +
`account_management_uri` / `account_management_actions_supported` in the metadata + `m.oauth` UIA) is
in dev and is treated as existing code here (rebase on it before ATDD). Stories 7 (Device Grant) and 8
(mTLS / `private_key_jwt`) are deliberately NOT part of this epic (V15); story 10 (appservice API) is a
separate epic.

1. **The `/versions` switch (spec 3a rule).** `GET /_matrix/client/versions` lists `v1.1` ... `v1.15`
   (the consecutive set, adding `v1.12`, `v1.13`, `v1.14`, `v1.15`) IF AND ONLY IF the instance offers
   OAuth conformantly, i.e. exactly while `GET /_matrix/client/v1/auth_metadata` answers `200`: the
   SAME predicate `Nebu.OAuth.oauth_aware?/0` (= `Nebu.OAuth.Config.live_state/0` `{:live, _}`) that
   story 5 already uses for `oauth_aware_preferred` and the SSO `action`. Otherwise the response is
   today's `v1.1` ... `v1.11` body byte for byte (and `auth_metadata` keeps answering `404
   M_UNRECOGNIZED`). `unstable_features` is unchanged in both states: only
   `uk.half-shot.msc2666.query_mutual_rooms`; `org.matrix.msc2964/2965/2966/2967/3861` are NOT added
   (stable since v1.15). The `oauth_aware_preferred` half of spec row 9 is already done (story 5 C1-C3).
2. **Consistency of the predicate (one predicate, one place).** No second implementation:
   `/versions`, `GET /login` flags, SSO `action`, `auth_metadata`, `auth_issuer`, the unstable
   alias, `/.well-known/openid-configuration`, token/JWKS kill switch and the story-6 account page are
   all decided by `Config.live_state/0` per request (no cache), so an operator toggle flips all of
   them on the next request on every node. Fail closed: disabled, invalid issuer, unreadable
   `server_config`, no repo or an exception => `v1.11`, never a 5xx (the reference load balancers
   health-check `/_matrix/client/versions`). The two remaining copies of the condition
   (`Nebu.OAuth.Authorize.live_issuer/0`, `Nebu.OAuth.Http.auth_issuer/1`) are made to delegate to
   `Config.live_state/0` (no behaviour change). `POST /oauth2/register` keeps its `Config.enabled?/0`
  check (no behaviour change for register: it stays live with an enabled switch and an invalid issuer;
  the deviation is recorded in the parity table, test review M1 option A).
3. **Conformance contract test suite.** For every URL and capability field the LIVE metadata
   advertises (incl. story 6's `account_management_uri` and actions) the route exists and behaves (never
   the router's `404 "not found"` fall-through, never Protected's `404 M_NOT_FOUND`), plus a
   matrix-js-sdk 41.3.0 replay (`validateAuthMetadataAndKeys`, `getAuthMetadata()` choosing the STABLE
   prefix once `/versions` lists v1.15) from a scratchpad copy of `tests/matrix_compat`.
4. **Operator activation checklist + rollback story** in `docs/architecture/07-deployment.md` (and a
   README pointer): every open gate item of `follow-ups.md` with its status, nginx routes
   (`/oauth2/`, `/account`, `/account/`, `/.well-known/openid-configuration`), issuer constraints,
   trusted-proxy status, IdP `auth_time` / `max_age` behaviour (gate y), kill-switch semantics, the
   3-day metadata cache and what clients cache (`Cache-Control` of the metadata and of `/versions`).
5. **Docs:** ADR-033 section "`/versions` switch and activation (story 9)" (V1-V19, the
   v1.12-v1.15 obligations table, out-of-epic stories 7/8/10), `docs/matrix-api-scope.md` versions row,
   arc42 hooks, `follow-ups.md` (new items ac-af), and a final epic doc consistency pass (stale
   statements listed in Dev Notes).

Oracle gate 2026-10-12 (`_bmad-output/nebu/epics/oauth-broker/step-results/oauth-versions-switch/oracle-context.md`)
is folded in: option (b), honest variant. `GET /_matrix/client/v1/room_summary` (G1) is CORE in v1.15
and absent: it is NOT implemented here but becomes follow-up (ac), a GATE before `oauth_enabled = true`
and before any release that claims v1.15; (af) (`M_UNRECOGNIZED` for unrouted paths) ships together
with (ac). The 15 consecutive entries stay (advertising only v1.15 would break clients that test
`versions.includes("v1.4")` / `"v1.11"`). Spec 3a is corrected (AC8). O1-O8 resolved (see "Open
questions"); extra tests Must #39-#50.

`oauth_enabled` stays `false` by default and NOTHING in this story enables it (not in code, config,
compose files, cloud-init or tests outside the `:oauth_config_source` seam). With the switch off the
new code path is dormant: `/versions` is exactly today's response. Out of scope: closing any
follow-ups item (append only), Device Grant / mTLS (7/8), appservice (10), nginx template edits (gate
m), the I-12 config cache, implementing any GAP found by the obligations audit.

Authoritative sources: `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 3, 3a, 8, 13,
14; `docs/architecture/adr/ADR-033-authorization-server-broker-model.md` (D1-D23, T1-T33, R1-R24,
C1-C20, story 6 adds A1-A27); story 3 `oauth-token-endpoint.md` (T22, T30, T31, matrix_compat C6),
story 4 `oauth-token-revocation-logout.md` (R13), story 5 `oauth-legacy-coexistence.md` (C1, C2, O5,
"Handover to story 9"), story 6 `oauth-account-management.md` (A2, A3, A18, gate y, items y-ab);
`docs/stories/oauth-broker/follow-ups.md` (items 1-4, I-1, I-2, I-12, a-ab); Kassandra reports in
`docs/stories/oauth-broker/security-reports/` (story 1 I-2/I-5/I-12/N-4, story 5 I-6); Matrix CS API
v1.11 and v1.15 ("API Versions", "Authentication API discovery", "Server metadata discovery",
changelogs v1.12-v1.15; local copies under the session scratchpad `spec/cs-v1.11.txt`,
`spec/cs-v1.15.txt`, `spec/changelog-v1.1{2,3,4,5}.txt`, fetched from spec.matrix.org on 2026-10-12);
`_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`; matrix-js-sdk 41.3.0 `src/client.ts`
(`getVersions` ~6202, `getAuthMetadata` ~8863), `src/version-support.ts`, `src/feature.ts`.

## Story

As an **operator of a Nebu instance that has finished the OAuth broker preconditions**,
I want Nebu to announce Matrix v1.15 exactly while its OAuth 2.0 API is live and conformant, and a
checklist that tells me what must be true before I switch `oauth_enabled` on and what happens when I
switch it off again,
so that OAuth-capable clients (FluffyChat / Dart SDK 13, Element Web / matrix-js-sdk) discover and use
Nebu's authorization server, and legacy-only deployments keep today's behaviour byte for byte.

## Decisions

Prefix `V` (versions story), so the IDs never collide with D (story 2), T (3), R (4), C (5) and A (6)
in ADR-033. ADR-033 gets a new section with V1-V19 (AC8).

- **V1 (exact version lists).** OAuth offered: `["v1.1", "v1.2", "v1.3", "v1.4", "v1.5", "v1.6",
  "v1.7", "v1.8", "v1.9", "v1.10", "v1.11", "v1.12", "v1.13", "v1.14", "v1.15"]` (15 entries, in this
  numeric order, consecutive; spec 3a "v1.12 bis v1.15", the epic never audited v1.16+). Not offered:
  today's `["v1.1", ..., "v1.11"]`, and the whole body `Jason.encode!` byte-identical to today's (map
  key order of a small map is term order: `unstable_features` before `versions`, unchanged). Nothing
  above v1.15 (v1.16 extended profiles, v1.17/v1.18 duties were not audited; the v1.18 OAuth-aware flag
  of story 5 needs no v1.18 entry, oracle story 5). The list is two module attributes, never computed
  from a range (lexicographic sorting would put `v1.10` before `v1.2`). Basis: the obligations table
  (Dev Notes) — every MUST introduced in v1.12-v1.15 is done or not applicable, except G1 (core
  `room_summary`, gate (ac)) and the pre-existing non-gating G2/G3 (ad). The spec does not require a
  consecutive list, but clients test single entries (`includes("v1.4")`, `"v1.11"`, `"v1.15"`), so
  the full consecutive set is advertised (oracle O1).
- **V2 (one predicate, one place; ADR-020).** The Matrix side asks ONLY `Nebu.OAuth.oauth_aware?/0`
  (story 5 C1), once per request, wrapped by the existing private `oauth_aware?/0` of
  `Nebu.Matrix.HttpPublic` (rescue/catch => `false`). Consolidation (no behaviour change):
  `Nebu.OAuth.Authorize.live_issuer/0` becomes `case Config.live_state() do {:live, issuer} -> {:ok,
  issuer}; _ -> :error end`, and `Nebu.OAuth.Http.auth_issuer/1` uses `Config.live_state/0` instead of
  `config.enabled` + `Metadata.normalize_issuer/1`; no behaviour change for `/oauth2/register`
  (`Config.enabled?/0` stays, deviation recorded in the parity table). Afterwards
  `Metadata.normalize_issuer/1` is called
  only by `Config.live_state/0` and `Metadata.build/1` (static test). `Nebu.Web.Plugs.OAuthDiscovery`
  KEEPS its state-only switch (`:enabled` => `Nebu.OAuth.Http`, `:disabled` => IdP passthrough,
  `:unknown` => 503): that is decision 7 (passthrough only on a positively read `:disabled`), and for
  `:enabled` + invalid issuer it already reaches `Nebu.OAuth.Http`, which answers 404 through
  `live_state/0`. No cache, no `:persistent_term`, no process dictionary (I-12 stays a follow-up).
- **V3 (placement).** The route stays `get "/_matrix/client/versions"` in `Nebu.Web.Router` (exact
  path, GET only, before `forward "/_matrix"`, no `OidcPlug`); its body becomes a one-line call of
  the new public `Nebu.Matrix.HttpPublic.versions/1 :: Plug.Conn.t() -> Plug.Conn.t()` (`@doc`,
  `@spec`), which builds the response through the pure `Nebu.Matrix.HttpPublic.versions_body/1 ::
  boolean() -> map()`. The Matrix domain owns the Matrix versions list; HttpPublic already owns the
  other OAuth-aware Matrix answer (`login_flows/1`), so both consumers of the predicate sit in one
  module. Not a `forward` (a forward would also capture `/_matrix/client/versions/...`, which today
  reaches Protected).
- **V4 (fail closed, never 5xx).** `oauth_aware?/0 == false` for `:disabled`, `:enabled` with a
  missing / http / path-carrying / query-carrying issuer, `:unknown` (unreadable `server_config`),
  no repository process (unit runs, early boot) and any exception or exit => the v1.11 response with
  status 200. `/versions` never answers 503 because of the OAuth config: the stackit (`alb.tf`) and
  upcloud (`loadbalancer.tf`) load balancers health-check `GET /_matrix/client/versions`, and a client
  cannot start without it. Consequence (documented): during a `server_config` outage while OAuth is on,
  `/versions` reports v1.11, consistent with `auth_metadata` (404 `no-store` on `:unknown`) and the
  `GET /login` flags (absent). Oracle O5: acceptable (js-sdk memoizes
  `/versions` until `setAccessToken`, so a running client does not flap). The existing `Nebu.OAuth.Config` WARNING on a read error is the
  only log line (no token, no value).
- **V5 (`unstable_features`).** Exactly `%{"uk.half-shot.msc2666.query_mutual_rooms" => true}` in
  BOTH states. Never `org.matrix.msc2964`, `org.matrix.msc2965`, `org.matrix.msc2966`,
  `org.matrix.msc2967`, `org.matrix.msc3861`, `org.matrix.msc4191`, `org.matrix.msc3824*` or any
  `*.oauth*` key (spec 3a: stable since v1.15, clients discover OAuth through `auth_metadata`; MSC3824
  is a `GET /login` flow field, story 5 C3). Static and runtime test.
- **V6 (authentication ignored).** matrix-js-sdk sends `/versions` AUTHENTICATED (MSC4026,
  `getVersions` uses `authedRequest`). Nebu's answer is independent of the `Authorization` header:
  absent, valid legacy, valid OAuth, expired, revoked or junk bearer => the same 200 body for the
  same config state (the route never runs `OidcPlug`; no per-user features; never 401). Pinned, also
  with a raising config seam (=> v1.11). The preflight `OPTIONS` with `Access-Control-Request-Headers:
  authorization` must allow `Authorization` (browser js-sdk). A query string
  (`/_matrix/client/versions?x=1`) gives the same answer. Oracle: a uniform answer is legal.
- **V7 (caching).** `Cache-Control: no-store` on the 200 in BOTH states (new header; the body of the
  off state stays byte-identical). Rationale: a flip in either direction must be visible on the next
  fetch through any intermediary; clients keep `/versions` in memory anyway (matrix-js-sdk until the
  access token changes or the page reloads; Dart SDK per session, [A]). Parity: the
  `auth_metadata` 404 is `no-store` too. The 3-day `public, max-age=259200` of the metadata 200 is
  unchanged (spec: clients cache metadata by HTTP caching; I-2) and is documented in the rollback
  story (AC7). No `Vary` header (the answer does not vary). Oracle O6: `no-store` confirmed.
- **V8 (rate and read cost).** No rate limit (spec "Rate-limited: No"; health checks). Cost: one
  indexed `SELECT key, value FROM server_config WHERE key IN (7 keys)` per request (the
  `live_state/0` read), the same as `GET /login` since story 5 (Kassandra story-5 I-6). Follow-up I-12
  (per-node TTL cache of `Config.get/0`) is extended to name `/versions` and the LB health checks;
  not implemented here (ADR-020: no node-local switch state without a decision).
- **V9 (parity matrix and runtime toggle).** For each config state (S1 `:enabled` + valid issuer, S2
  `:enabled` + invalid issuer, S3 `:disabled`, S4 `:unknown`, S5 raising seam) the surfaces answer as
  in the parity table (Dev Notes). Invariant tested per state: `/versions` lists `v1.15` IFF
  `GET /_matrix/client/v1/auth_metadata` is 200 IFF the `GET /login` SSO flow carries both OAuth-aware
  keys IFF `/.well-known/openid-configuration` is 200 IFF `GET /account` is not the `unavailable`
  page. Toggling the seam between two requests flips every surface on the next request (no restart,
  no cache).
- **V10 (conformance contract).** A dedicated integration suite proves that the LIVE document is
  truthful: (a) **crawler**: every string value of the document that starts with the issuer (and
  `<issuer>/.well-known/openid-configuration`) is mapped to a router path and requested with the
  method the field implies; the answer is never the router fall-through (`404` text/plain `"not
  found"`) nor Protected's `404 M_NOT_FOUND`, and never `M_UNRECOGNIZED`; (b) **field semantics**
  (one test per field, table in Dev Notes): `response_types_supported`, `grant_types_supported`,
  `response_modes_supported`, `code_challenge_methods_supported`,
  `token_endpoint_auth_methods_supported`, `revocation_endpoint_auth_methods_supported`,
  `authorization_response_iss_parameter_supported`, `id_token_signing_alg_values_supported`,
  `jwks_uri`, `account_management_uri`, `account_management_actions_supported`, `issuer`;
  (c) **key guard**: the set of top-level keys equals the contract's known set (a new key without a
  contract entry fails the suite; `device_authorization_endpoint`, `prompt_values_supported` and the
  `urn:ietf:params:oauth:grant-type:device_code` grant are asserted ABSENT: stories 7 not in the epic,
  D11); (d) the three discovery paths (`v1`, unstable alias, `/.well-known/openid-configuration`)
  are byte-identical. Unvalued claims are never asserted on the router's structure (the suite must
  survive a refactor of the routes).
- **V11 (matrix-js-sdk replay).** The story-3 node test is extended (never `npm ci` in the main
  checkout; run from a scratchpad copy with `node_modules` from a scratchpad install): the fixture
  written by the ExUnit side additionally carries `versions_on` / `versions_off` and the story-6
  fields; the node test asserts `validateAuthMetadataAndKeys` passes on the live document incl.
  `account_management_uri`/actions, and that `MatrixClient.getAuthMetadata()` with a stubbed
  `fetchFn` requests `/_matrix/client/v1/auth_metadata` when `/versions` = `versions_on` and
  `/_matrix/client/unstable/org.matrix.msc2965/auth_metadata` when `versions_off`
  (`isVersionSupported("v1.15")`, client.ts ~8866). Not runnable in the isolated env => written,
  recorded as "not executed", the ExUnit suite covers the same rules.
- **V12 (activation checklist and rollback, docs only).** `docs/architecture/07-deployment.md` gets
  the section "Activating OAuth (`oauth_enabled`): preconditions, checklist, rollback" (content
  fixed in AC7); README "Matrix API Scope" gets one sentence pointing to it. Rollback semantics
  (switch off): next request => `/versions` v1.11, `auth_metadata` 404, flags gone, token / JWKS /
  openid-configuration / authorize / register / account 404, revoke still live (R13), existing
  OAuth access tokens keep authenticating until they expire (C16) and their refresh then answers the
  T22 404 without `error` (js-sdk: retryable, not a logout); clients that cached the metadata
  (<= 3 days, I-2) still try `/oauth2/*` and get 404; users re-login through legacy SSO.
- **V13 (gates are not closed by this story).** Story 9 closes no follow-ups item and enables
  nothing. The flip is dormant while `oauth_enabled = false`, so the story can be implemented and
  merged into `feature/migrate-to-oauth2` while gate items are open; setting `oauth_enabled = true`
  on any instance (and merging the epic to `main` with a release note claiming OAuth support)
  requires every gate in the AC7 checklist to be closed: 1, 2, 4, h, i, l, m, n, r, y, ac, ag (in
  particular (r) `legacy-logout-per-device` and (ac) `room_summary`, without which the v1.15 claim
  is not honest; (af) ships together with (ac)). Oracle O7: the story-9 merge into the epic branch is
  fine while they are open (dormant); (r) and (ac) gate `oauth_enabled` and the merge to `main` with
  an OAuth release note.
- **V14 (obligations audit v1.12-v1.15).** The table in Dev Notes (MUSTs and required behaviours
  introduced in v1.12-v1.15, from the changelogs and a case-insensitive diff of every MUST/REQUIRED
  sentence of the v1.11 vs v1.15 CS API) goes into ADR-033. GAPs not covered by an existing
  follow-up are recorded as new follow-ups (ac, ad); oracle-confirmed: **G1** `GET
  /_matrix/client/v1/room_summary/{roomIdOrAlias}` (Added in v1.15, Rooms chapter "Room discovery":
  CORE, not an optional module; spec 3a was wrong to call it optional and is corrected, AC8) =>
  follow-up (ac), GATE before `oauth_enabled` / a release claiming v1.15 (minimal local-only summary:
  no federation, `via` ignored, authentication required); **G2** `POST /createRoom` ignores the `topic` parameter (pre-existing
  since v1.1; v1.15 adds "with a text/plain mimetype", i.e. an `m.topic` block); **G3** pre-existing
  gaps that are unrouted although `docs/matrix-api-scope.md` marks them done: core endpoints
  `POST /user_directory/search` and `GET|POST /publicRooms`; push-rule writes (Push Notifications is
  REQUIRED for the Mobile profile, i.e. FluffyChat: a real gap); `POST /keys/claim` (E2EE module,
  optional in every profile, Nebu excludes E2EE). Already present under the advertised v1.11, not
  introduced by v1.12-v1.15 => doc fix + non-gating follow-up (ad), oracle-confirmed. No GAP is
  implemented here.
- **V15 (out of epic scope, recorded in ADR-033).** Story 7 (Device Authorization Grant, RFC 8628,
  v1.18) and story 8 (mTLS / `private_key_jwt` for admin-created machine clients, incl. the setup CA)
  are deliberately NOT implemented in epic `oauth-broker`: no `device_authorization_endpoint`, no
  `device_code` grant, no certificate-bound tokens. The data-model hooks stay prepared
  (`oauth_clients.token_endpoint_auth_method`, policy fields, spec 9 / decision 9). Story 10
  (application-service API for bridges) is a separate epic. The `/versions` list does not depend on
  them (v1.15 does not require the device grant).
- **V16 (doc consistency pass).** Every stale statement listed in Dev Notes "Doc consistency pass"
  is fixed in the same commit (historic statements get a "(resolved: ...)" marker instead of being
  deleted).
- **V17 (no migration, no config, no env, no audit).** No schema change, no `server_config` key,
  no env variable (ADR-022), no `audit_log` row (C19/T29), no new rate-limit bucket, no new log line.
- **V18 (`/capabilities` unchanged).** `m.change_password: false`, `m.3pid_changes: false` (OAuth-aware
  duties, story 5 C10), room versions unchanged, no `m.get_login_token` (v1.12 documents it; absent =
  `false` for clients). No dependency on the OAuth state. Open question O4.
- **V19 (other methods unchanged, pinned as measured).** `OPTIONS /_matrix/client/versions` is
  answered by `CORSPlug` (204, CORS headers) before the route; `POST` / `PUT` / `HEAD` keep today's
  outcome (they fall to `forward "/_matrix"` => Protected); measured on HEAD and pinned: `POST` / `PUT`
  / `HEAD` => `401 M_MISSING_TOKEN`, `OPTIONS` => `204` allowing `Authorization`.
  Oracle: the spec expects `405 M_UNRECOGNIZED` for an unsupported method on an implemented path;
  Protected's current answer is a non-gating deviation, pinned as measured and recorded under (af).
  Also pinned as measured: `/_matrix/client/versions/` (trailing slash) => the same answer as
  `/_matrix/client/versions` (Plug.Router normalises it), `/_matrix/client/v3/versions` => `401
  M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN` (unrouted, item ae).

**Review cycle 1 amendments (Kassandra F-1..F-4, code review):** V4/V8: the `/versions` path runs an uncached `server_config`
read in EVERY deployment (also with the switch off: only the OAuth surface is dormant), so that read is bounded
(`Config.live_state(bounded: true)`, 500 ms pool checkout + query timeout, fail closed to v1.11; every other caller keeps the
default timeouts) and its warning is throttled to one per minute per node; a per-node TTL cache stays I-12. V12: switch-off
SUSPENDS OAuth, it does not revoke (access tokens keep working until they expire, re-enabling revives unexpired sessions);
AC7 gets exact activation / rollback SQL (no Admin UI writer for `oauth_*`), a revoke runbook and an "Accepted risks and release notes"
block; gate (ag) is part of the gate list in V13 / AC7 / AC8; new follow-up (ai).

## Acceptance Criteria

### AC1 — The versions switch (V1, V3, V5, V6)

- `Nebu.Matrix.HttpPublic.versions/1` and `versions_body/1` exist (`@doc`, `@spec`);
  `Nebu.Web.Router`'s `get "/_matrix/client/versions"` only calls `versions/1`.
- S1 (OAuth offered): `200`, `application/json`, `versions` == the V1 on-list exactly (order and
  length), `unstable_features` == `{"uk.half-shot.msc2666.query_mutual_rooms": true}`.
- S2-S5: `200`, the body is byte-identical to `Jason.encode!(%{"versions" => ~w(v1.1 ... v1.11),
  "unstable_features" => %{"uk.half-shot.msc2666.query_mutual_rooms" => true}})`.
- `versions_body(true)` / `versions_body(false)` return exactly these maps (pure, no I/O).
- With any `Authorization` header (absent, legacy opaque, OAuth AT, expired OAuth AT, revoked, junk
  `Bearer x`, `Basic ...`) the answer equals the no-header answer of the same state.
- `unstable_features` never contains a key matching `msc2964|msc2965|msc2966|msc2967|msc3861|msc3824|
  msc4191|oauth` (case-insensitive), in any state.

### AC2 — Fail closed and robustness (V4, V7, V8, V19)

- S2 (each: nil, `http://`, `https://h/path`, `https://h?q`, `https://h#f`, userinfo), S3, S4
  (`T.unreadable_oauth_config/0`), S5 (seam fun raises / exits) and "no repo" => v1.11, status 200;
  no 5xx in any state.
- `Cache-Control: no-store` on both 200 variants; no `Set-Cookie`; `X-Content-Type-Options: nosniff`
  (router-level, unchanged).
- No rate-limit token is taken (100 sequential requests from one IP => 100 x 200).
- Exactly one `server_config` read per request (counted through the `:oauth_config_repo` seam or the
  config-source seam call count).
- `OPTIONS` (preflight) and `POST` / `HEAD` on the path: same status and body as before the story
  (V19, pinned relatively).
- No new log line; with S4 only the existing `OAuth.Config` WARNING (no value).
- Preflight `OPTIONS` with `Origin` + `Access-Control-Request-Headers: authorization` => the CORS
  answer allows `Authorization`; `?x=1` => same body; `/_matrix/client/versions/` and
  `/_matrix/client/v3/versions` pinned as measured (V19, ae); no `Vary`.
- Issuer variants `https://h/` (trailing slash), `https://h:8448` (explicit port), `https://H.EXAMPLE`
  (uppercase host): all three are valid issuers (measured: `auth_metadata` 200, issuer echoed without
  the trailing slash, port and host case kept), so `/versions` lists v1.15 for each.

### AC3 — Predicate parity and runtime toggle (V2, V9)

- For S1-S5 the parity table (Dev Notes) holds, asserted in ONE test per state over all surfaces:
  `/versions`, `GET /_matrix/client/v1/auth_metadata`, `GET .../unstable/org.matrix.msc2965/auth_metadata`,
  `GET /_matrix/client/v1/auth_issuer`, `GET /_matrix/client/v3/login` (OAuth-aware keys), the SSO `action=register` prompt,
  `GET /.well-known/openid-configuration`, `GET /oauth2/jwks`, `POST /oauth2/token` (empty form),
  `POST /oauth2/register` (`{}`), `GET /oauth2/authorize` (no params), `GET /account` (story 6),
  `POST /oauth2/revoke` (R13: live in S1-S3).
- Invariant: `"v1.15" in versions` <=> `auth_metadata` 200 <=> both OAuth-aware keys on the SSO flow
  <=> openid-configuration 200 <=> `/account` not `data-error="unavailable"`.
- Runtime toggle: S3 -> S1 -> S3 between consecutive requests flips `/versions` and every surface on
  the very next request (no restart, no cache); the same for S1 -> S4 -> S1.
- Integration variant: with the REAL `server_config` read (seam removed), an `UPDATE server_config SET
  value = 'true' WHERE key = 'oauth_enabled'` (+ issuer row) flips `/versions` on the next request;
  the test restores the rows (shared integration DB).

### AC4 — Predicate consolidation (V2)

- `Nebu.OAuth.Authorize.live_issuer/0` delegates to `Config.live_state/0` (`{:live, i}` => `{:ok,
  i}`, else `:error`); `Nebu.OAuth.Http.auth_issuer/1` uses `Config.live_state/0`; responses of
  `/oauth2/authorize`, `/account` and `auth_issuer` unchanged in S1-S5 (their existing suites stay
  green).
- Static: in `server/lib/**`, `Metadata.normalize_issuer(` is called only in `config.ex`
  (`live_state/0`) and `metadata.ex`; no file under `server/lib/nebu/matrix/` or
  `server/lib/nebu/web/` names `Nebu.OAuth.Config` / `Nebu.OAuth.Metadata` (ADR-020; the router's
  existing `forward ... to: Nebu.OAuth.Http` lines are the allowed HTTP edge); `router.ex` contains no
  version literal `v1.1` (the list lives in `http_public.ex`); no `:persistent_term` /
  `Process.put` in the predicate path.

### AC5 — Conformance contract of the live metadata (V10)

- Note: the contract suite is green before AND after the story-9 change (stories 1-6 made the document
  truthful); it guards the refactor and must not be edited to make story-9 code pass.
- New integration suite `oauth_conformance_contract_test.exs` (S1 seam with the test issuer, an
  approved test client, story-2/3/6 fixtures) implements V10 (a)-(d) with the field table of Dev
  Notes; every row is one named test.
- Crawler: for each advertised URL the answer is not the router fall-through, not `M_NOT_FOUND`, not
  `M_UNRECOGNIZED`; GET URLs (authorization, jwks, account, openid-configuration) are requested with
  GET, POST endpoints (token, revoke, registration) with an empty POST of the right content type and
  with GET (=> 405 + `Allow`).
- Key guard: the top-level key set equals the contract set (story 6 fields included); absent:
  `device_authorization_endpoint`, `prompt_values_supported`, `auth_issuer`, any IdP field.
- Byte identity of `v1/auth_metadata`, the unstable alias and `/.well-known/openid-configuration`.
- The suite also runs once in S3 and asserts every crawled URL is the documented disabled answer (404
  `M_UNRECOGNIZED` / T22 404 without `error` / the account `unavailable` page; revoke stays live).
- Spec-REQUIRED fields present (`issuer`, `authorization_endpoint`, `token_endpoint`,
  `registration_endpoint`, `revocation_endpoint`, `response_types_supported`,
  `grant_types_supported`, `response_modes_supported`, `code_challenge_methods_supported`) and the
  "at least" MUSTs: `code`; `authorization_code` + `refresh_token`; `query` + `fragment`; `S256`.
- Re-registration per flow: a second login flow of the same client software registers again
  (spec: every flow), the dedup returns the same `client_id` for identical metadata, and an
  already approved registration is NOT sent back to manual approval (no approval loop); a changed
  metadata hash is pending again (documented in the AC7 smoke).
- "MUST NOT delete registrations with an active session": only `pending` rows are purged
  (`OAuthPendingPurgeWorker`, never approved/rejected); a test asserts an approved client with a
  live session survives the purge; noted in ADR-033.

### AC6 — matrix-js-sdk compatibility replay (V11)

- `oauth_signing_keys_test.exs` (fixture writer, `NEBU_OAUTH_FIXTURE_OUT`) adds `versions_on`,
  `versions_off` (real `/versions` bodies from S1/S3) to the fixture; the metadata in the fixture
  carries the story-6 fields.
- `tests/matrix_compat/oauth_metadata_test.js` gains: `validateAuthMetadataAndKeys` on the fixture
  metadata incl. account fields => pass; `getAuthMetadata()` with stubbed `fetchFn` hits the stable
  path for `versions_on`, the unstable path for `versions_off`; S4 replay: `versions_off` + unstable alias `503 M_UNKNOWN`
  => `getAuthMetadata()` throws (observed behaviour recorded, not "fixed"); S3 replay: the unstable
  alias is the IdP passthrough (decision 7): assert only the requested path and document it; exit
  codes unchanged (0/1/2). The
  existing checks stay. Run from a scratchpad copy only; the Dev Agent Record states "executed" with
  the result or "not executed" with the reason.

### AC7 — Operator activation checklist and rollback (V12, V13)

`docs/architecture/07-deployment.md` gets the section "Activating OAuth (`oauth_enabled`):
preconditions, checklist, rollback" containing:

- **Preconditions table** (item, what, status at story-9 time, owner): every follow-ups gate before
  `oauth_enabled`: 1 trusted-proxy client IP (HARD GATE; note: `NEBU_TRUSTED_PROXY` today only drives
  the Secure cookie flag, not client-IP resolution), 2 bulk reject, 4 per-host cap, h per-source cap
  on `oauth_authz_requests`, i interactive login / `auth_time` freshness at the authorize callback,
  l missing IdP refresh token at the callback, m reverse-proxy routes, n concurrent refresh false
  logout, r legacy `/logout` per device (`legacy-logout-per-device`), w (closed by story 6), y IdP
  `auth_time` / `max_age=0` (BLOCKING; Dex reportedly ignores `max_age`), ac `GET /v1/room_summary`
  (core in v1.15, GATE; af ships with it), ag same-origin approval of a cross-signing reset (story-6 review); plus the non-gating ones as a
  short list (3, j, o, p, s, t, u, v, x, z, aa, ab, story-3 (b) key rotation runbook, story-3 (f)).
  Status values are copied from `follow-ups.md` at implementation time, not invented.
- **Reverse proxy:** route `/oauth2/`, `/account` and `/account/`, `/.well-known/openid-configuration`
  (and keep `/_matrix/`, `/.well-known/matrix/`) to the server when Element Web is served on the
  same host; strip query strings of `/oauth2/authorize`, the SSO callback and `/account` in access
  logs (k); the reference cloud-init templates are NOT changed by this story (gate m).
- **Issuer:** `oauth_issuer_url` = the public https origin clients use, empty path, no query /
  fragment / userinfo, same host as the IdP callback (story 2 (g)); a misconfigured issuer silently
  keeps everything off (fail closed) — the checklist says how to verify (`curl .../auth_metadata`
  200 and `/versions` lists v1.15).
- **IdP:** `matrix_oidc_refresh_mode = offline` when `oauth_idp_revalidation = per_refresh`; IdP must
  honour `max_age=0` and emit `auth_time` (gate y), `prompt=create` only if advertised.
- **Activation steps + smoke test:** set issuer, set `oauth_enabled = true`, verify `/versions`
  (v1.15), `auth_metadata` 200, `/.well-known/openid-configuration` 200, `/oauth2/jwks` 200, `GET
  /account` 302 to the IdP, approve the first client registration in `/admin/oauth/registrations`,
  log in with Element Web and FluffyChat, `/whoami`; log in a second time with the same client
  (new registration per flow) and confirm no new approval is required; then a rollback rehearsal
  on a test instance: switch off, observe `/versions` v1.11 and the OAuth session's forced re-login.
- **Kill switch and rollback:** V12 semantics; what clients cache: metadata `public, max-age=259200`
  (3 days, Dart SDK 3 days, also browsers / CDNs), JWKS `max-age=600`, `/versions` `no-store` but held
  in client memory per session (js-sdk until reload / token change); existing OAuth sessions keep
  working until their AT expires (C16); revoke and `/logout` stay live. **Forced re-login:** the two
  APIs are mutually incompatible, so after a rollback an OAuth session can NEVER continue as a
  legacy session: every OAuth user must log in again (legacy SSO) once their access token expires;
  waiting ("drain") does not avoid this (oracle O8). Communicate it to users before switching off.
- README "Matrix API Scope": one sentence (OAuth 2.0 API, Matrix v1.15, opt-in; `/versions` lists
  v1.15 only while it is enabled; link to the checklist).

### AC8 — Documentation (V14-V16)

- ADR-033: new section "`/versions` switch and activation (story 9)" with V1-V19, the obligations
  table and the parity table (Dev Notes); a paragraph "Out of epic scope" (V15); the gate paragraph
  gets "Story 9 update: `/versions` lists v1.12-v1.15 exactly while `Nebu.OAuth.oauth_aware?/0`; the
  flip is dormant while `oauth_enabled` is false; `oauth_enabled` stays false until the AC7 checklist
  is green (gate items 1, 2, 4, h, i, l, m, n, r, y, ac, ag); story 9 closes no gate"; the rollback /
  forced re-login semantics (V12, O8) and the registration-purge rule (pending only); the stale statements of
  the doc consistency pass are fixed.
- `docs/matrix-api-scope.md`: row `GET /_matrix/client/versions` => "v1.1-v1.11; v1.1-v1.15 while the
  OAuth 2.0 API is offered (`oauth_enabled` + valid issuer, the `auth_metadata` 200 predicate);
  `unstable_features` only `uk.half-shot.msc2666.query_mutual_rooms`; `Cache-Control: no-store`;
  answer independent of authentication"; the coexistence note loses "until story 6" / "before the
  story-9 flip" wording per the actual status; the stale rows of G3 are corrected to 🔲 with
  "unrouted (follow-up ad)".
- `docs/stories/oauth-broker/follow-ups.md`: section "From story oauth-versions-switch": I-1 marked
  RESOLVED (every advertised endpoint exists, contract-tested); I-2 "documented in 07-deployment.md
  rollback"; I-12 extended to `/versions` + LB health checks; item k "documented in the checklist";
  (r) note "the `/versions` flip code exists (story 9) and is dormant; (r) still MUST be closed before
  `oauth_enabled`"; new rows (text to be written by dev): **(ac)** "`GET /_matrix/client/v1/room_summary/{roomIdOrAlias}`
  is absent although it is CORE in Matrix v1.15 (Rooms chapter, Added in v1.15; spec 3a corrected):
  implement a minimal local-only summary (no federation, `via` ignored, authentication required,
  visibility like `/hierarchy`). Found by story oauth-versions-switch (G1). **GATE: before
  `oauth_enabled` and before any release that claims v1.15**; (af) ships together", **(ad)**
  "Pre-existing gaps already present under v1.11, marked done in `docs/matrix-api-scope.md`: core
  `POST /user_directory/search` and `GET|POST /publicRooms` unrouted; push-rule writes unrouted (Push
  Notifications is REQUIRED for the Mobile profile, FluffyChat); `POST /keys/claim` unrouted (E2EE
  optional, excluded); `POST /createRoom` ignores `topic` (v1.15 `m.topic` text/plain, G2).
  Non-gating; scope doc corrected in story 9", **(ae)** health
  checks / runbooks probe `/_matrix/client/v3/versions`, which is not routed (Protected answers 401
  without a token): `deploy/helm/nebu/templates/server-deployment.yaml` (liveness + readiness),
  `deploy/tofu/modules/nebu-aws/alb.tf`, `deploy/tofu/examples/{stackit,aws}/RUNBOOK.md`,
  `docs/architecture/07-deployment.md` AWS rows (pre-existing deploy bug, non-gating for the epic,
  must be fixed before those targets are used), **(af)** "Unrouted endpoints answer `404
  M_NOT_FOUND` and unsupported methods on implemented paths are not `405 M_UNRECOGNIZED`; the spec
  expects `M_UNRECOGNIZED` so clients can detect unsupported features (extends story-5 (e); V19).
  Ships together with (ac), i.e. before `oauth_enabled` / a v1.15 release". Letters a-ab are used by stories 1-6; if story 6 used more,
  continue after its last letter.
- Moduledocs/comments: `Nebu.OAuth` (`oauth_aware?/0` also gates `/versions`), `Nebu.OAuth.Config`
  (`live_state/0` consumers incl. `/versions`, `Authorize.live_issuer/0`, `auth_issuer`),
  `Nebu.Matrix.HttpPublic` (versions), `Nebu.Web.Router` comment of the versions route ("Nebu does
  not claim v1.19 compliance, so the list is left as-is" is replaced by the V1 rule).
- arc42 (by the arc42 step; Dev Notes list the hooks).
- `_bmad-output/planning-artifacts/oauth-broker-spec.md` section 3a (oracle-corrected): "Room
  Summaries" moves from "Nicht anwendbar oder optional" to the preconditions: `GET /v1/room_summary` is
  core in v1.15, follow-up (ac), gate before `oauth_enabled`; add "Push Notifications ist im
  Mobile-Profil Pflicht: Push-Rule-Schreibzugriffe fehlen (vorbestehend, (ad))".

## Acceptance Tests

### ExUnit matrix (unit = pure, integration = `@tag :integration`, DB)

- New `server/test/nebu/oauth/oauth_versions_switch_test.exs`: AC1, AC2 (unit, seam-driven S1-S5,
  no DB), AC3 parity per state + runtime toggle (unit, seam), AC3 integration variant (real
  `server_config` rows, `@tag :integration`).
- New `server/test/nebu/oauth/oauth_conformance_contract_test.exs` (integration): AC5.
- New `server/test/nebu/oauth/oauth_versions_static_test.exs` (static): AC4 static rules, V5
  (no forbidden `unstable_features` literal in `server/lib`), V1 (exactly one occurrence of the on-
  and off-lists, in `http_public.ex`).
- Changed deliberately: `server/test/nebu/matrix/matrix_router_test.exs` "does not widen the advertised
  versions list (v1.19 is NOT claimed)" becomes "OAuth not offered => v1.1-v1.11" WITH
  `T.disable_oauth/0` (or the Matrix-side equivalent seam) and a sibling "OAuth offered =>
  v1.1-v1.15"; the describe text "static route (no token, no DB)" is corrected (one config read).
  `server/test/nebu/web/plugs/request_logger_test.exs` keeps using `/versions` but its comment "without
  touching the DB" is corrected (unit runs have no repo => `:disabled`).
  `server/test/nebu/oauth/adr_033_test.exs`: AC8 pins (appended after story 6's changes).
  `oauth_test_support.exs`: section "Story 9" (helpers below).
- Regression (must stay green unchanged): story-5 `oauth_legacy_coexistence_test.exs` (flags),
  story-1 `oauth_metadata_test.exs` (as changed by story 6), story-2 authorize suites, story-6 account
  suites (A3 liveness after the `live_issuer/0` delegation), `oauth_config_test.exs`.

### matrix_compat node test (V11)

`tests/matrix_compat/oauth_metadata_test.js` extended per AC6 (inputs `NEBU_OAUTH_FIXTURE` or
`NEBU_MATRIX_URL`; neither => exit 2 "not executed"). Run only from a scratchpad copy:
`cp package.json package-lock.json oauth_metadata_test.js <scratch>/ && cd <scratch> && npm ci &&
NEBU_OAUTH_FIXTURE=<fixture> node oauth_metadata_test.js`. Never `npm ci` or write inside the main
checkout `open-chat`.

### Gherkin

None: no UI (`ui: false`). The story-6 e2e feature is unchanged.

## Must be test-covered (Matrix CS API v1.11/v1.15 "API Versions", "Authentication API discovery", spec 3a/14, story 5 O5)

1. OAuth offered (S1): `versions` is exactly `v1.1`..`v1.15`, numeric order, 15 entries, no `v1.16+`.
2. Not offered (S2 all issuer variants, S3, S4, S5, no repo): `versions` exactly `v1.1`..`v1.11`.
3. Not offered: body byte-identical to the pre-story body.
4. `unstable_features` exactly `{"uk.half-shot.msc2666.query_mutual_rooms": true}` in every state.
5. No `msc2964/2965/2966/2967/3861/3824/4191/oauth` key in `unstable_features` (runtime + static).
6. Status always 200, `application/json`; never 5xx (S4, S5, raising / exiting seam).
7. `Cache-Control: no-store` on both variants; no `Set-Cookie`.
8. Answer independent of the `Authorization` header (absent, legacy, OAuth, expired, revoked, junk,
   Basic).
9. No rate limiting: 100 requests from one IP all 200.
10. Exactly one config read per `/versions` request.
11. `OPTIONS` preflight, `POST`, `HEAD` on the path unchanged (relative pin).
12. Parity S1: `/versions` v1.15, `auth_metadata` 200, unstable alias 200 (identical), `auth_issuer`
    Nebu issuer, `/login` flags present, openid-configuration 200, JWKS 200, token not 404,
    register not 404, authorize not 404, `/account` live, revoke live.
13. Parity S2: v1.11, `auth_metadata` 404 `M_UNRECOGNIZED`, unstable alias + `auth_issuer` 404 (via
    `Nebu.OAuth.Http`), flags absent, openid-config / JWKS / token 404 without `error`, authorize 404,
    register LIVE (`400 invalid_request` for `{}`, `Config.enabled?/0`, recorded deviation), `/account`
    `unavailable` 404, revoke live.
14. Parity S3: v1.11, `auth_metadata` 404, unstable alias + `auth_issuer` = IdP passthrough (decision
    7), flags absent, token/JWKS/openid 404 without `error`, `/account` 404 page, revoke live.
15. Parity S4: v1.11, `auth_metadata` 404 `no-store`, unstable alias + `auth_issuer` 503 `M_UNKNOWN`,
    flags absent, token/JWKS/openid 503 `{}` + `Retry-After`, `/account` 503 page, revoke 503 `{}`.
16. Runtime toggle S3 -> S1 -> S3 and S1 -> S4 -> S1 flips every surface on the next request.
17. Integration: a real `server_config` UPDATE flips `/versions` on the next request (rows restored).
18. `Authorize.live_issuer/0` and `auth_issuer` decided by `Config.live_state/0`; `/oauth2/authorize`,
    `/account`, `auth_issuer` responses unchanged in S1-S5.
19. Static: `normalize_issuer(` only in `config.ex` / `metadata.ex`; Matrix/Web files name no
    `Nebu.OAuth.Config`/`Metadata`; version lists only in `http_public.ex`; no cache in the predicate.
20. Contract crawler: every advertised URL answers neither the router fall-through, nor `M_NOT_FOUND`,
    nor `M_UNRECOGNIZED` (S1).
21. Contract key guard: top-level keys == contract set; `device_authorization_endpoint`,
    `prompt_values_supported`, `auth_issuer` absent.
22. `response_types_supported` `["code"]`: authorize with `response_type=code` proceeds (302 to the IdP),
    `token` => error redirect `unsupported_response_type` with `iss`.
23. `grant_types_supported`: `authorization_code` and `refresh_token` with bogus values => `400
    invalid_grant` (never `unsupported_grant_type`); `client_credentials`, `password`,
    `urn:ietf:params:oauth:grant-type:device_code` => `unsupported_grant_type`.
24. `response_modes_supported` `query`, `fragment`: an error redirect is delivered in the requested
    mode (query string vs fragment), both with `state` and `iss`.
25. `code_challenge_methods_supported` `["S256"]`: `plain` / missing challenge => error redirect, `S256`
    proceeds.
26. `authorization_response_iss_parameter_supported: true`: success redirect of the IdP callback and
    every error redirect carry `iss` == issuer.
27. `token_endpoint_auth_methods_supported` `["none"]`: token request without client auth accepted
    (no `invalid_client` for an approved client); `Authorization: Basic` => `401 invalid_client` (T24).
28. `revocation_endpoint_auth_methods_supported` `["none"]`: revoke without client auth => 200.
29. `jwks_uri` => 200 `{"keys": [...]}`, every key `kty: EC`, `crv: P-256`, `alg: ES256`, public members
    only; `id_token_signing_alg_values_supported` `["ES256"]` matches the id_token header of a code
    grant with `openid`.
30. `registration_endpoint`: valid metadata => 201 + `client_id`; `{}` => 400 `invalid_request`
    (RFC 7591 shape, no `errcode`).
31. `revocation_endpoint`: POST unknown token => 200; GET => 405 `Allow: POST, OPTIONS`.
32. `token_endpoint`: GET => 405 `Allow: POST, OPTIONS`; empty POST => 400 `invalid_request`.
33. `account_management_uri` (story 6): GET without session => 302 to the IdP; each value of
    `account_management_actions_supported` with a session renders `data-action=<that action>` (never
    the default page for an advertised action).
34. `issuer` + `/.well-known/openid-configuration` (resolved like `new URL(".well-known/openid-configuration",
    issuer)`) => 200, byte-identical to `v1/auth_metadata` and the unstable alias.
35. Contract in S3: every crawled URL gives its documented disabled answer; revoke stays live (R13).
36. matrix-js-sdk: `validateAuthMetadataAndKeys` passes with the story-6 fields; `getAuthMetadata()`
    uses the stable prefix for `versions_on`, the unstable one for `versions_off` (or "not executed").
37. Docs pins: ADR-033 section + V1..V19 + "Out of epic scope" + "Story 9 update"; 07-deployment
    section heading + every gate letter of AC7 + `max-age=259200` + `no-store`; matrix-api-scope
    versions row (`v1.15`, `no-store`); follow-ups rows `| ac |`..`| af |`.
38. No new log line; S4 only the existing WARNING without a value.
39. Preflight `OPTIONS /versions` with `Access-Control-Request-Headers: authorization` allows
    `Authorization`.
40. `/_matrix/client/versions?x=1` == `/_matrix/client/versions`; no `Vary` header.
41. `/_matrix/client/versions/` and `/_matrix/client/v3/versions` pinned as measured (ae).
42. `POST`/`PUT` on `/versions` pinned as measured (deviation from `405 M_UNRECOGNIZED`, recorded (af)).
43. Issuer variants (trailing slash, explicit port, uppercase host): `/versions` v1.15 IFF
    `auth_metadata` 200, per variant.
44. Raising config seam + any `Authorization` header => 200 v1.11, never 401.
45. Spec-REQUIRED metadata fields present and the "at least" MUSTs (`code`; `authorization_code` +
    `refresh_token`; `query` + `fragment`; `S256`).
46. Re-registration per flow: identical metadata => same approved `client_id`, no approval loop.
47. Pending purge never deletes an approved client with a live session.
48. js-sdk S4 replay: unstable alias 503 => `getAuthMetadata()` throws (observed, recorded).
49. js-sdk S3 replay: request goes to the unstable alias path (IdP passthrough, decision 7).
50. Docs pins: gate lists contain `ac`; AC7 has the forced re-login paragraph; spec 3a names
    `room_summary` as core.

## Dev Notes

### Current state of the code this story builds on (read before coding)

- **Trap: the `/versions` handler is NOT in `http_public.ex`.** It is an inline `get
  "/_matrix/client/versions"` in `server/lib/nebu/web/router.ex` (~153-172), placed after the media
  forwards and before `forward "/.well-known/openid-configuration"` and `forward "/_matrix"`; static
  map, no DB, no `Cache-Control`; comment "Nebu does not claim v1.19 compliance, so the versions list
  below is left as-is" (stale after this story).
- `Nebu.OAuth.Config.live_state/0` (`config.ex` ~100): `{:live, issuer}` | `:unknown` | `:off`;
  `get/0` reads 7 `server_config` keys uncached (`load_raw/0`, rescue/catch => `:error` =>
  `:unknown`; no repo => `:disabled`); seam `:nebu_http, :oauth_config_source` (fun may return
  `:unknown` / `{:error, _}` / raise), `:oauth_config_repo`.
- `Nebu.OAuth.oauth_aware?/0` (`oauth.ex` ~102): `match?({:live, _}, Config.live_state())`, rescue/catch
  => false. `Nebu.Matrix.HttpPublic` wraps it again in private `oauth_aware?/0` (~238) and uses it in
  `login_flows/1` (~215).
- `Nebu.OAuth.Http`: `auth_metadata/1` (~283) uses `Config.live_state/0` + `Metadata.build/1`, 200 with
  `cache-control: public, max-age=259200`, else `unrecognized/1` (404 `M_UNRECOGNIZED`, `no-store`);
  `auth_issuer/1` (~304) still uses `Config.get/0` + `config.enabled` + `normalize_issuer/1` (copy of
  the predicate, V2); token/JWKS/openid-configuration use `live_state/0` (T22: `:off` => 404 without
  `error`, `:unknown` => 503 `{}`); revoke uses `Config.get().state` (R13).
- `Nebu.OAuth.Authorize.live_issuer/0` (`authorize.ex` ~85): `Config.get/0` + `normalize_issuer/1`
  (second copy); story 6 A3 makes `/account` use it.
- `Nebu.Web.Plugs.OAuthDiscovery` (`oauth_discovery.ex`): state-only switch for `auth_issuer` (v1 +
  unstable) and the unstable `auth_metadata` (keep, V2).
- `Nebu.OAuth.Metadata.build/1` (`metadata.ex`): today's fields (issuer, 4 endpoints,
  response_types, grant_types, response_modes, code_challenge_methods, both auth-method lists,
  `authorization_response_iss_parameter_supported`, `jwks_uri`, `id_token_signing_alg_values_supported`);
  story 6 A18 adds `account_management_uri` + `account_management_actions_supported` (5 values).
- Router fall-through: `match _ -> send_resp(conn, 404, "not found")` (text/plain); Protected:
  `404 {"errcode":"M_NOT_FOUND","error":"Unrecognized request"}`.
- Tests on `/versions` today: `test/nebu/matrix/matrix_router_test.exs` ~260-282 (pins the v1.11
  list), `test/nebu/web/plugs/request_logger_test.exs` ~140-191 (uses it as a deterministic endpoint);
  no OAuth test touches it.
- Test helpers to reuse (`oauth_test_support.exs`): `T.enable_oauth/1,2`, `T.disable_oauth/0`,
  `T.unreadable_oauth_config/0`, `T.clear_oauth_config/0`, `T.get/2`, `T.login_flows/1`,
  `T.token_request/2`, `T.jwks/1`, `T.oauth_client!/2`, `T.assert_error_redirect/6`,
  `T.account_get/2` (story 6), `T.raw_request/5`.
- Prerequisite bugfixes are in HEAD of `feature/migrate-to-oauth2` (rebased SHAs): media Content-Type /
  filename `c19ff333`, room account data / 405 / read_markers `e00eaa28`, room tags `4ca5cebd`,
  refresh retry `65e9f61e`, token hashing `3b1bc596`. Gate (r) (`legacy-logout-per-device`) has NO
  commit yet.

### Parity table (per config state; goes into ADR-033)

| Surface | S1 enabled + valid issuer | S2 enabled + invalid issuer | S3 disabled | S4 unknown |
|---|---|---|---|---|
| `GET /_matrix/client/versions` | v1.1-v1.15 | v1.1-v1.11 | v1.1-v1.11 | v1.1-v1.11 |
| `GET /v1/auth_metadata` | 200, 3-day cache | 404 `M_UNRECOGNIZED` | 404 | 404 `no-store` |
| unstable `auth_metadata` | 200 (same bytes) | 404 (OAuth.Http) | IdP passthrough | 503 `M_UNKNOWN` |
| `auth_issuer` (v1 + unstable) | Nebu issuer | 404 | IdP passthrough | 503 `M_UNKNOWN` |
| `GET /login` OAuth-aware keys | present | absent | absent | absent |
| SSO `action` honoured | yes | no | no | no |
| openid-configuration / JWKS / token | live | 404, no `error` | 404, no `error` | 503 `{}` |
| `/oauth2/authorize` | live | 404 | 404 | 404 |
| `/oauth2/register` | live | live (deviation: `Config.enabled?/0`, M1 option A) | 404 | 404 |
| `/account*` (story 6) | live | 404 page | 404 page | 503 page |
| `/oauth2/revoke` | live | live (R13) | live (R13) | 503 `{}` |

S5 (raising seam) behaves like S4 for `/versions` and the flags (fail closed); the endpoints' own
rescue behaviour is pinned as measured.

### Obligations audit v1.12-v1.15 (server MUSTs / required behaviours introduced; goes into ADR-033)

Method: changelogs v1.12-v1.15 (Client-Server API sections) plus a case-insensitive diff of every
MUST/REQUIRED sentence of the v1.11 vs the v1.15 CS API page. Client-only rules omitted.

| Ver. | Obligation (source) | Nebu status |
|---|---|---|
| 1.12 | Media download/thumbnail: `Content-Type` = upload or reasonably close; `Content-Disposition` required, `inline` only for the allowlist, filename when uploaded with one / requested in the path (MSC2701/2702) | done (`c19ff333`, bugfix 0a) |
| 1.12 | Historical push actions `dont_notify` / `coalesce` MUST be ignored, not rejected | not applicable: `GET /pushrules/` is a static stub, no push-rule writes routed, no push evaluation (if writes are added later: strip them) |
| 1.12 | Account locking (MSC3939): `401 M_USER_LOCKED` + `soft_logout` | not applicable (no lock feature, spec 6) |
| 1.12 | Unread markers `m.marked_unread` room account data (MSC2867) | done (`e00eaa28`; optional module) |
| 1.12 | Profile `403` (MSC4170), guest media (MSC4189), `via` on join/knock (MSC4156), device-specific push rules removed, `m.get_login_token` capability documented, login fallback `window.matrixLogin.onLogin` | MAY / not applicable (no federation, no guests, no login fallback page; capability absent = false) |
| 1.13 | `POST /rooms/{roomId}/report` (MSC4151) + MUST NOT restrict room reports by membership | not applicable (Reporting Content is optional; endpoint absent, answers `404 M_NOT_FOUND`, see (af)) |
| 1.13 | `M_USER_SUSPENDED` behaviour (MSC3823); requestToken error codes (MSC4178) | not applicable (no suspension, no 3PID) |
| 1.13 | CORS `Access-Control-Allow-Methods` covers additional methods (MSC4138) | recommendation; `CORSPlug` defaults unchanged |
| 1.13 | `/keys/claim`: OTKs in upload order, each at most once (MSC4225) | not applicable: `/keys/claim` is not routed (E2EE excluded, README); scope doc stale (ad) |
| 1.13 | Custom `PusherData` keys forwarded to the push gateway; async upload `404` cases | not applicable (no pushers) / done (`PUT /v3/upload/...` 404/403/409) |
| 1.14 | `POST /users/{userId}/report` (MSC4260) + MUST NOT restrict | not applicable (optional, absent) |
| 1.14 | `server_name` removed from join/knock (MSC4213); `instance_id` in thirdparty protocols; `initialSync` no longer deprecated; `/hierarchy` clarification | not applicable / not applicable / optional (route exists) / [ungeprüft] (spaces-elixir, clarification only) |
| 1.15 | OAuth 2.0 API (MSC3861 family), `auth_metadata`, "mutually incompatible" APIs, `404 M_UNRECOGNIZED` when unsupported (SHOULD) | done (stories 1-6), proven by AC5 |
| 1.15 | `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` (MSC3266, Rooms chapter "Room discovery") | **GAP G1** (absent; CORE, oracle-confirmed; spec 3a corrected); follow-up (ac), GATE before `oauth_enabled` |
| 1.15 | `m.topic` block; `createRoom` `topic` => `m.room.topic` "with a text/plain mimetype" (MSC3765) | **GAP G2, pre-existing**: `createRoom` ignores `topic` (`protected.ex` ~1127, `event_dispatcher/server.ex` emits only `m.room.name`); follow-up (ad) |
| 1.15 | `/hierarchy` optional `allowed_room_ids`, `encryption`, `room_version` | optional |
| 1.15 | "Public" rooms definitions for profile look-up / user directory / presence | profile: done (any local profile readable); user directory: **G3 pre-existing** (unrouted); presence: [ungeprüft] |
| 1.15 | Well-known URIs on the server name's host | done (`/.well-known/matrix/client`) |
| 1.15 | MSC4147 sender device keys in Olm events, MSC2781 reply fallbacks | client-only |

Pre-existing gaps already present under the advertised v1.11 (not introduced by v1.12-v1.15, listed
for honesty, G3, non-gating (ad)): core endpoints `POST /user_directory/search`, `GET|POST
/publicRooms`; push-rule writes (Push Notifications is REQUIRED for the Mobile profile); `POST
/keys/claim` (E2EE, optional) — unrouted although `docs/matrix-api-scope.md` marks most of them ✅.
Optional in every profile (oracle): Reporting Content, Read and Unread Markers, Client Config, E2EE,
Room Previews. js-sdk `getRoomSummary` always uses the unstable `im.nheko.summary` path without a
version check (Element unaffected by G1); Dart SDK unverified.

### Conformance contract field table (AC5)

| Field | Check (S1) |
|---|---|
| `issuer` | == `T.issuer()`; `<issuer>/.well-known/openid-configuration` 200, same bytes |
| `authorization_endpoint` | GET no params => 400 HTML page (`unknown_client`), not 404; approved client + valid params => 302 to the IdP |
| `token_endpoint` | GET => 405 + `Allow`; empty form POST => 400 `invalid_request`; grants per Must #23 |
| `revocation_endpoint` | GET => 405; POST unknown token => 200 |
| `registration_endpoint` | POST `{}` => 400 RFC 7591; valid => 201 + `client_id` |
| `jwks_uri` | Must #29 |
| `account_management_uri` | Must #33 |
| `account_management_actions_supported` | Must #33 |
| `response_types_supported` | Must #22 |
| `grant_types_supported` | Must #23 |
| `response_modes_supported` | Must #24 |
| `code_challenge_methods_supported` | Must #25 |
| `token_endpoint_auth_methods_supported` | Must #27 |
| `revocation_endpoint_auth_methods_supported` | Must #28 |
| `authorization_response_iss_parameter_supported` | Must #26 |
| `id_token_signing_alg_values_supported` | Must #29 |

### Files to create

- `server/test/nebu/oauth/oauth_versions_switch_test.exs`, `oauth_conformance_contract_test.exs`,
  `oauth_versions_static_test.exs`.
- Helpers ONLY in `server/test/nebu/oauth/oauth_test_support.exs`, section "Story 9":
  `versions/1` (GET with optional bearer, decoded body + headers), `parity_snapshot/0` (one map of all
  surfaces of AC3), `advertised_urls/1` (document => `[{field, url}]`), `router_path/1` (strips the
  issuer, keeps path + query), `set_oauth_rows!/2` and `restore_oauth_rows!/1` (integration variant,
  privileged SQL, restores the original values).

### Files to modify

- `server/lib/nebu/web/router.ex` — versions route body => `Nebu.Matrix.HttpPublic.versions(conn)`;
  comment rewritten (V1/V3).
- `server/lib/nebu/matrix/http_public.ex` — `versions/1`, `versions_body/1`, two list attributes,
  `Cache-Control: no-store`; moduledoc lists the endpoint.
- `server/lib/nebu/oauth/authorize.ex` — `live_issuer/0` delegates to `Config.live_state/0` (V2).
- `server/lib/nebu/oauth/http.ex` — `auth_issuer/1` via `Config.live_state/0` (V2).
- `server/lib/nebu/oauth.ex`, `server/lib/nebu/oauth/config.ex` — moduledocs (consumers).
- `tests/matrix_compat/oauth_metadata_test.js` (V11); fixture writer in
  `server/test/nebu/oauth/oauth_signing_keys_test.exs`.
- Tests per "Changed deliberately"; docs per AC7/AC8. NOT modified: `deploy/**` (gate m, item ae),
  migrations, `server_config` seeds, compose files.

### What must be preserved

- The off-state `/versions` body byte for byte; the `mutual_rooms` unstable flag in both states.
- Every story-1..6 behaviour not named in a V-decision: T22 kill switch shapes (404 without `error`,
  503 `{}`), R13 revoke liveness, decision 7 passthrough on `:disabled`, N-4 503 on `:unknown`, C2
  flags, A3 account liveness, the 3-day metadata cache, CORS of the OAuth endpoints.
- `/versions` stays unauthenticated, unrated, before `forward "/_matrix"`.

### Traps

1. **Wrong file:** the handler lives in `router.ex`, not `http_public.ex` (the story brief said the
   latter). Keep an exact `get`, do not `forward` (would swallow `/_matrix/client/versions/*`).
2. **Never 5xx, never slow-fail into a 503:** LB health checks use this path; every config failure
   must end in the v1.11 200. Do not add `OidcPlug` or any auth (js-sdk sends a bearer; an expired
   token must not 401 the client start).
3. **Version order:** literal lists, never sorted strings (`v1.10` < `v1.2` lexicographically).
4. **Shared integration DB:** tests that assert the off list MUST install `T.disable_oauth/0`; a
   leftover `oauth_enabled = 'true'` row from another test would flip an unseeded assertion. The
   integration toggle test restores the rows in `on_exit`.
5. **No second predicate, no cache:** do not read `Config` from the Matrix/Web side, do not memoize in
   `:persistent_term`, ETS or the process dictionary (ADR-020; I-12 is a follow-up).
6. **`OAuthDiscovery` is not a predicate copy** to "consolidate": its `:disabled` passthrough and
   `:unknown` 503 are decision 7 / N-4.
7. **Story 6 is concurrent:** rebase onto its commit before ATDD; its metadata fields, its
   `adr_033_test.exs` and `oauth_metadata_test.exs` changes are the baseline; the contract key guard
   includes the two account fields.
8. **Byte identity:** build the off body with the same map and `Jason.encode!/1`; compare bytes, not
   decoded maps. The new `Cache-Control` header is the only allowed difference.
9. **`oauth_enabled` stays false** in every committed config and fixture outside the seam; the
   contract suite uses the seam + test issuer, never a real `server_config` write except the
   restored integration toggle test.
10. **matrix_compat:** never `npm ci` / write in the main checkout; copy to the scratchpad.
11. **Contract tests must not be self-fulfilling:** derive the URLs from the LIVE document, not from
    constants; the key guard is the only list of known keys.
12. **No Sensitive Data law:** no token, code, cookie or Authorization value in any test log
    assertion or new log line (none is added).

### Doc consistency pass (stale statements story 9 must fix, V16)

- ADR-033 ~208 / ~318 ("unrouted (404) until stories 3/4", "`/oauth2/revoke` stays unrouted (until
  story 4)"), ~612-614 ("Also recorded: ... advertises `/oauth2/token|revoke`, which do not exist
  before stories 3/4"; "answered the router's 404 until story 4"): mark "(resolved: all advertised
  endpoints exist since story 4; contract-tested in story 9)".
- ADR-033 ~621 "stays false because of gate items 1, h, i, l, m, n, r and stories 5, 6, 9" and ~626
  "OAuth sessions cannot delete devices until story 6 (item w)", "MUST be closed before the story-9
  `/versions` flip": update to the final gate list (V13, story 6 closes w).
- ADR-033 C2 (~535) "`account_management_uri` stays absent until story 6" and C10/table (~543, ~571)
  "`m.oauth` is story 6": "(story 6: added)" unless story 6 already fixed them.
- `docs/architecture/05-building-blocks.md` ~1128 "story 9 flips `/versions` on the same predicate" =>
  present tense + `HttpPublic.versions/1`.
- `docs/architecture/06-runtime.md` ~1458 (historic revoke 404, mark resolved), ~1584 and ~1624
  ("closed by the bugfix ... before the story-9 flip") => actual status of (r).
- `docs/architecture/07-deployment.md` ~102 heading lists stories 1-4 only; ~110 "GATE: before story
  2 merges"; ~114 "GATE: before story 2, key on ..."; "Behavior while oauth_enabled = true" lacks
  `/versions`, flags and `/account`; ~399 / ~429 AWS health check `GET /_matrix/client/v3/versions`
  (item ae).
- `docs/architecture/08-concepts.md` ~505 "Fix (before story 2 merges)", ~641 (r wording).
- `docs/architecture/11-risks.md` ~45, ~48 (r "before the story-9 `/versions` flip") => "before
  `oauth_enabled`; the flip code is dormant".
- `docs/matrix-api-scope.md` ~21 (versions row), ~307 ("`account_management_uri` stays absent ...
  until story 6", "before the story-9 `/versions` flip"), G3 rows (~169, ~170, ~157-160, ~185, ~265).
- `docs/stories/oauth-broker/follow-ups.md`: item 1 "before story 2 merges" wording (k reconcile),
  I-1 open, story-4 (b) "stories 5, 6, 9", story-5 (c).
- `server/lib/nebu/web/router.ex` ~158-164 comment; `Nebu.OAuth` moduledoc ("The revocation endpoint
  follows in story 4").
- grep to re-run before committing: `not routed`, `404 until`, `until story`, `before story`,
  `stories 2-4`, `story 9 will`, `story-9`, `v1.11`, `stays absent`.

### Architecture compliance

ADR-018 (no SQL added; the integration test uses privileged SQL only in test support); ADR-019 single
app; ADR-020 facade-only cross-domain call (`Nebu.OAuth.oauth_aware?/0` from `Nebu.Matrix.HttpPublic`),
no node-local switch state, per-request DB truth on every node; ADR-022 no env / config key; ADR-033
broker model (this story adds section V); OIDC Scopes Law untouched; No Sensitive Data law (no new log
line). No migration.

### Library / client notes

- matrix-js-sdk 41.3.0: `getVersions()` is authenticated and memoized per client until
  `setAccessToken` (client.ts ~6202, ~6480); `getAuthMetadata()` uses `/_matrix/client/v1/auth_metadata`
  only when `isVersionSupported("v1.15")`, else the unstable MSC2965 path, and falls back to
  `auth_issuer` + the issuer's openid-configuration on `M_UNRECOGNIZED` (~8863-8885);
  `SUPPORTED_MATRIX_VERSIONS` ends at v1.13 (only a compatibility floor); no other js-sdk gate
  between v1.12 and v1.15 (only v1.16 extended profiles).
- Matrix Dart SDK 13 (oracle 2026-10-07, [V]): calls `auth_metadata` only if `/versions` >= v1.15,
  caches metadata 3 days, treats only `404 M_UNRECOGNIZED` as "no OAuth". Its reaction to a
  `/versions` downgrade with a stored OAuth session is unverified (O8).
- Element Web: discovery via the js-sdk; with v1.15 + metadata it offers OAuth (native OIDC) login.

### Testing commands (isolated env, see the epic brief)

No migration: `quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth
test/nebu/matrix/matrix_router_test.exs test/nebu/web/plugs/request_logger_test.exs"`; full gate via
`integration.sh` (background, output to a file); compare failures with `scratchpad/known.txt` by name.
`MIX_ENV=prod mix compile`. matrix_compat per AC6 from a scratchpad copy.

### Docs to touch (arc42 step and dev)

ADR-033 (AC8), `docs/architecture/07-deployment.md` (AC7), `README.md` (one sentence),
`docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`; arc42 hooks:
`05-building-blocks.md` (`Nebu.Matrix.HttpPublic.versions/1`, predicate consolidation in
`Authorize.live_issuer/0` / `auth_issuer`), `06-runtime.md` (scenario "client discovery after the
flip and after a rollback": `/versions` -> `auth_metadata` -> DCR; kill switch), `08-concepts.md`
("one liveness predicate for every OAuth surface", parity table), `10-quality.md` (quality scenario:
metadata conformance contract), `11-risks.md` (3-day metadata cache vs kill switch; `/versions` DB
read on LB health checks and fail-closed v1.11 during a DB outage; G1-G3 honesty of the version
claim), `09-decisions.md` ADR-033 row (story 9).

### Out of scope

Enabling OAuth; closing or implementing any follow-ups item (1-4, a-ab, I-x) or the new ac-af;
G1-G3 implementation; nginx / cloud-init / helm changes; Device Grant (7), mTLS / `private_key_jwt`
(8), appservice (10); I-12 cache; `/capabilities` changes; v1.16+.

## Open questions

Resolved by the oracle gate (2026-10-12,
`_bmad-output/nebu/epics/oauth-broker/step-results/oauth-versions-switch/oracle-context.md`):

- **O1 (V1):** option (b), honest variant: advertise the 15 consecutive entries v1.1-v1.15, nothing
  above; G1 is follow-up (ac), a gate before `oauth_enabled` / a v1.15 release; (af) ships with it.
- **O2 (V14):** table confirmed, except G1 is CORE (spec 3a corrected) and Push Notifications is
  REQUIRED for the Mobile profile (push-rule writes are a real, pre-existing gap, G3 wording fixed).
- **O3 (V5):** `unstable_features` msc2666 only.
- **O4 (V18):** `/capabilities` unchanged.
- **O5 (V4):** v1.11 on `:unknown` acceptable (js-sdk memoizes `/versions`); never 5xx.
- **O6 (V7):** `no-store` confirmed, no `Vary`; a uniform answer ignoring `Authorization` is legal,
  never 401.
- **O7 (V13):** merging story 9 into the epic branch is fine (dormant); (r) and (ac) gate
  `oauth_enabled` and the merge to `main` with an OAuth release note.
- **O8 (V12):** the APIs are mutually incompatible: after a rollback OAuth sessions cannot move to
  legacy; forced re-login documented (AC7), a drain does not help; rollback observation in the AC7
  smoke.

Also folded in: V19 `405 M_UNRECOGNIZED` deviation pinned as measured and recorded under (af); the
extra tests (Must #39-#50). No open questions remain.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev-story, non-interactive, 2026-10-12).

### Debug Log References

Isolated env (`scratchpad/oauth/quick.sh`, MIX_ENV=test). Story-9 files alone (`oauth_versions_switch`, `oauth_versions_static`,
`oauth_conformance_contract`, `matrix_router`, `request_logger`, `oauth_signing_keys`, `adr_033`): green. Targeted
`--warnings-as-errors` run and the full run: see the Completion Notes. `MIX_ENV=prod mix compile`: see the Completion Notes.
matrix_compat replay: EXECUTED from a scratchpad copy with the fixture written by `oauth_signing_keys_test.exs`
(`NEBU_OAUTH_FIXTURE_OUT`): "all checks passed", exit 0 (all story-3 checks, the story-6 account fields, `versions_on` =>
stable `/_matrix/client/v1/auth_metadata`, `versions_off` => unstable alias, S4 503 alias => `getAuthMetadata()` throws
`MatrixError M_UNKNOWN`, S3 => the unstable alias path).

### Completion Notes List

- `Nebu.Matrix.HttpPublic.versions/1` + `versions_body/1` (two literal list attributes, `Cache-Control: no-store`, the
  fail-closed wrapper of the existing private `oauth_aware?/0`); `Nebu.Web.Router`'s exact `get "/_matrix/client/versions"` only
  calls it (comment rewritten). Off-state body byte-identical.
- Predicate consolidation: `Authorize.live_issuer/0` and `Http.auth_issuer/1` delegate to `Config.live_state/0`
  (`Metadata.normalize_issuer/1` is now called only by `config.ex` and `metadata.ex`); `/oauth2/register` keeps
  `Config.enabled?/0` (option A).
- Docs: ADR-033 section "`/versions` switch and activation (story 9)" (V1-V19, parity and obligations tables, out of epic scope, rollback /
  forced re-login, pending purge) + "Story 9 update" in the gate paragraph + the stale statements marked "(resolved: ...)";
  `07-deployment.md` section "Activating OAuth (`oauth_enabled`): preconditions, checklist, rollback" (all gates incl. ag) and the stale
  gate wording / AWS health-check note (ae); README sentence; `matrix-api-scope.md` versions row and the G3 rows corrected to 🔲 (ad)
  (verified unrouted in the code: `publicRooms`, `user_directory/search`, `keys/claim`, single / write push rules); follow-ups section with
  I-1 resolved and rows ac-af; spec 3a corrected (room_summary core, push); arc42 stale statements (05, 06, 08, 11).
- Deliberate test fix (genuinely wrong, minimal): `oauth_versions_static_test.exs` "Must #5/V5" scanned the WHOLE of every file that
  contains `unstable_features` and so flagged `"org.matrix.msc3824.delegated_oidc_compatibility" => true` of the `GET /login` SSO flow
  in `http_public.ex` (story 5 C3; not an unstable feature); it now inspects only the `unstable_features` map literal.
- Documented, not fixed: gap G1 `room_summary` (gate (ac)), G2/G3 (ad), health checks (ae), `M_UNRECOGNIZED` (af); V19 measured pins
  stay; stories 7 / 8 / 10 are out of epic scope.

### Review cycle 1 (2026-10-12)

Findings: `step-results/oauth-versions-switch/code-review-findings.md` (0 MAJOR, 5 MINOR, INFO) and Kassandra
`security-reports/oauth-versions-switch-security-review-2026-10-12.md` (F-1 .. F-4). Tests first: `oauth_versions_bounded_test.exs`
(a real `LOCK TABLE server_config` held by a second connection: `/versions` answers `200` v1.1-v1.11 within the bound, the warning
is throttled, the next request reads the real state again, static: only `http_public.ex` asks for `bounded: true`).

- F-1: `Config.live_state/1` / `Config.get/1` / `Nebu.OAuth.oauth_aware?/1` accept `bounded: true` (500 ms pool checkout + query
  timeout, warning throttled to one per minute per node via the existing `RateLimit` bucket); only `HttpPublic.versions/1` uses it; the
  "dormant" wording is corrected in V4/V8, ADR and `07-deployment.md` (the OAuth surface is dormant, the `/versions` read is not).
- F-2: rollback text and ADR C16 / V12: switch-off SUSPENDS, it does not revoke; runbook SQL that really revokes (`DELETE FROM
  matrix_sessions WHERE auth_api = 'oauth'`, or per device); users log out manually; the "forced re-login once the access token expires"
  statements are reworded. F-3: exact activation / rollback SQL (no Admin UI writer for `oauth_*`). F-4: "Accepted risks and release
  notes to acknowledge" block; (q) and the new (ai) in the non-gating list and in `follow-ups.md`.
- MINOR 1: stale "before the story-9 flip" wording in `follow-ups.md` (stories 4/5 text); MINOR 2: gate (ag) in V13 / AC7 / AC8 and the
  `adr_033_test.exs` pins; MINOR 5: RED-phase prose reworded in the story-9 test moduledocs; INFO 8 / 9 / 11: `HttpPublic` moduledoc, `oauth.ex`
  parenthesis, ADR gate heading marked "(resolved: story 2 merged)". Test fixes: `adr_033_test.exs` pins extended by `ag` (deliberate).

### File List

Modified: `server/lib/nebu/matrix/http_public.ex`, `server/lib/nebu/web/router.ex`, `server/lib/nebu/oauth/authorize.ex`,
`server/lib/nebu/oauth/http.ex`, `server/lib/nebu/oauth.ex`, `server/lib/nebu/oauth/config.ex`,
`server/test/nebu/oauth/oauth_versions_static_test.exs` (see above), `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`,
`docs/architecture/07-deployment.md`, `05-building-blocks.md`, `06-runtime.md`, `08-concepts.md`, `11-risks.md`, `README.md`,
`docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`, `_bmad-output/planning-artifacts/oauth-broker-spec.md`, this story file.

## Change Log

- **2026-10-12:** Story created (create-story, non-interactive) for story 9 of epic oauth-broker:
  `/versions` switch on `Nebu.OAuth.oauth_aware?/0`, predicate consolidation, conformance contract,
  js-sdk replay, activation checklist + rollback, v1.12-v1.15 obligations audit (GAP candidates
  G1-G3), doc consistency pass; decisions V1-V19, open questions O1-O8.
- **2026-10-12 (oracle-amended):** O1-O8 resolved (option (b) honest variant: G1 `room_summary` core =>
  gate (ac) with (af); 15 consecutive entries kept; spec 3a corrected; Push Notifications Required for
  Mobile in G3; forced re-login on rollback; V19 pinned as measured); extra tests Must #39-#50;
  follow-ups texts ac-af in AC8.
- **2026-10-12 (atdd):** red-phase acceptance tests written (ATDD role, non-interactive) for AC1-AC8 and
  Must #1-#50 (3 new ExUnit files, 5 extended files, the matrix_compat replay); section "ATDD Decisions
  (story 9)" appended.

- **2026-10-12 (dev-story):** `/versions` switch on the shared predicate, predicate consolidation, activation checklist / rollback, ADR-033
  section V1-V19, obligations audit, doc consistency pass, follow-ups ac-af; status `review`.

## ATDD Decisions (story 9)

Written by the ATDD role (2026-10-12, red phase). All calls into new code go through `apply/3` or HTTP,
so `--warnings-as-errors` compiles. No new production seam is needed.

### Test files

- New `server/test/nebu/oauth/oauth_versions_switch_test.exs`: AC1, AC2 (unit, seam-driven S1-S5 incl.
  a raising AND an exiting seam and "no repo"), AC3 parity per state + runtime toggle (integration:
  `/account` and the authorize/register surfaces need the DB and the IdP stub), the AC3 integration
  variant with the REAL `server_config` rows (privileged write, restored in `on_exit`), V18
  `/capabilities`.
- New `server/test/nebu/oauth/oauth_conformance_contract_test.exs` (AC5): crawler over the LIVE
  document, key guard, byte identity, one named test per field, the S3 crawl, re-registration without
  an approval loop, the pending purge. GREEN today by design (stories 1-6 made the document truthful):
  it is the contract guard that must stay green through the story-9 refactor (`live_issuer/0` /
  `auth_issuer` delegation).
- New `server/test/nebu/oauth/oauth_versions_static_test.exs` (AC4 static, V1, V5).
- Extended: `adr_033_test.exs` (AC7/AC8 docs: ADR section, gate paragraph, stale statements,
  07-deployment checklist with every gate letter, README, matrix-api-scope versions + G3 rows,
  follow-ups ac-af, spec 3a), `oauth_signing_keys_test.exs` (fixture `versions_on` / `versions_off`
  written BEFORE the new assertion that `versions_on` lists v1.15), `oauth_test_support.exs` section
  "Story 9", `tests/matrix_compat/oauth_metadata_test.js` (checks 4-7).
- Changed deliberately (complete list): `test/nebu/matrix/matrix_router_test.exs` "does not widen the advertised
  versions list (v1.19 is NOT claimed)" => "OAuth not offered => v1.1-v1.11" (seam pinned to disabled)
  + "OAuth offered => v1.1-v1.15"; the describe text "no DB" => "one config read".
  `test/nebu/web/plugs/request_logger_test.exs`: comment only ("without touching the DB" corrected).
  `server/test/nebu/oauth/oauth_signing_keys_test.exs`: the fixture writer gains `versions_on` /
  `versions_off` and the v1.15 assertion. `tests/matrix_compat/oauth_metadata_test.js`: checks 4-7; a
  fixture without the versions pair now FAILS (no silent skip). `oauth_config_test.exs` is NOT touched.

### Measured pins (probe on HEAD fc1ea38f, 2026-10-12, OAuth disabled and enabled)

- `OPTIONS /_matrix/client/versions` (preflight with `Access-Control-Request-Headers: authorization`)
  => `204`, `access-control-allow-headers` contains `Authorization`, ACAO `*` (CORSPlug).
- `POST` / `PUT` / `HEAD` => `401 M_MISSING_TOKEN` (fall to `forward "/_matrix"` => Protected); pinned,
  deviation from `405 M_UNRECOGNIZED` recorded under (af).
- `/_matrix/client/versions/` (trailing slash) => the SAME `200` body as `/versions` (Plug.Router
  normalises the trailing slash); `/_matrix/client/versions?x=1` => the same body.
- `/_matrix/client/v3/versions` => `401 M_MISSING_TOKEN` without a token, `401 M_UNKNOWN_TOKEN` with a
  junk bearer (unrouted, item ae).
- Issuer variants `https://nebu.example.com/`, `https://nebu.example.com:8448`, `https://NEBU.EXAMPLE.COM`
  => `auth_metadata` 200 (issuer echoed as `https://nebu.example.com`, `...:8448`,
  `https://NEBU.EXAMPLE.COM`): all three are LIVE, so `/versions` must list v1.15 for each.
- Today's `/versions` carries Plug's default `cache-control: max-age=0, private, must-revalidate`;
  the story replaces it with `no-store` (V7).

### Pinned (beyond the story)

- `Nebu.Matrix.HttpPublic.versions_body(true | false)` == exactly `%{"versions" => [...], "unstable_features"
  => %{"uk.half-shot.msc2666.query_mutual_rooms" => true}}`; the off body bytes ==
  `T.versions_off_bytes/0`.
- "Exactly one config read" is counted through a counting `:oauth_config_source` fun
  (`T.counting_config_source/1`), not the repo.
- Static: the version LIST literals (`~w(... v1.11 | v1.15 ...)` or `"v1.11"` / `"v1.15"`) appear only in
  `lib/nebu/matrix/http_public.ex`; prose in moduledocs is allowed.
- Helpers (`oauth_test_support.exs`, "Story 9"): `versions/1`, `versions_on/0`, `versions_off/0`,
  `versions_off_bytes/0`, `versions_on_map/0`, `versions_off_map/0`, `counting_config_source/1`,
  `drain_config_reads/0`, `parity_snapshot/0`, `advertised_urls/1`, `router_path/1`,
  `unimplemented_answer?/1`, `set_oauth_rows!/1`, `restore_oauth_rows!/1`.

### matrix_compat replay (AC6)

Executed from a scratchpad copy (node_modules from the scratchpad install): every existing story-3
check passes; the new checks pass except the three `versions_on` checks (`versions_on` lists v1.15,
`getAuthMetadata()` requests the stable `v1/auth_metadata`, and the metadata validated through that
path), which fail because `versions_on` is still the v1.11 body: the intended red. S4 observed:
`getAuthMetadata()` throws `MatrixError M_UNKNOWN` on the unstable alias 503. S3: the unstable alias
path is requested. With a copy of the fixture whose `versions_on` lists v1.12-v1.15 every check
passes (exit 0).

### Test review follow-up (2026-10-12)

- M1 (option A, decided): `/oauth2/register` stays on `Config.enabled?/0`; the S2 parity test pins it LIVE
  (`400 invalid_request` for `{}`); V2, AC4, the parity table and Must #13 updated.
- M2: parity per state with EXACT statuses measured on 9d4b57bb (S1: token `401 invalid_client`, register
  `400`, authorize `400` HTML, account `302`, auth_issuer = the Nebu issuer on both paths; S2: alias +
  auth_issuer 404, jwks / openid / token 404 without `error`; S3: alias + both auth_issuer paths = the IdP
  passthrough, register / authorize `404 M_UNRECOGNIZED`; S4: alias + auth_issuer `503 M_UNKNOWN`,
  openid / jwks / token / revoke `{}` + `Retry-After: 5` + `no-store`, metadata `404 no-store`, register /
  authorize `404`, account `503`; S5: `/versions`, flags and SSO action fail closed, the OAuth endpoints
  propagate the seam's raise, pinned as measured); the SSO `action=register` prompt is a parity row in
  every state; the S1 -> S4 -> S1 toggle compares every surface.
- M3: the V5 static check matches real `"key" => true|false` entries (it could never match before) plus a
  runtime guard on `versions_body/1`.
- MINORs: structured docs assertions (table rows / lines, the G3 rows must exist, no German-sentence pin),
  AC7/AC8 content pins, `code/1` strips only doc heredocs and full-line comments (no interpolation
  cutting), exactly one on-/off-list, Authorization independence + content type + `no-store` in every off
  state, issuer echo pins, contract value types (every URL-looking value under the issuer and https,
  non-empty string lists), a positive control for the pending purge, the node test fails on a fixture
  without the versions pair and has no duplicate S3 check, `set_oauth_rows!/1` registers its restore
  before the first write.

### Contradictions / gaps with the story (proposed text; 1-4 resolved by the test review)

1. **Parity S2 `/oauth2/register`.** (resolved: option A, register stays live, deviation recorded) Measured: with `oauth_enabled = true` and an INVALID issuer,
   `POST /oauth2/register` is live today (`Nebu.OAuth.Http.register/1` checks only `Config.enabled?/0`),
   while the parity table says `404`. The S2 parity test asserts `404` (red). Proposed V2 addition:
   "`Nebu.OAuth.Http.register/1` (`ensure_enabled/0`) also decides by `Config.live_state/0` (an invalid
   issuer => `404 M_UNRECOGNIZED`, like authorize / token)"; AC4 adds register to the list of delegating
   surfaces.
2. **V19 measured outcomes** (above) replace "same status and body as on HEAD before the change":
   proposed V19 text: "`POST` / `PUT` / `HEAD` => `401 M_MISSING_TOKEN` (Protected), the trailing
   slash => the `/versions` answer, `/v3/versions` => `401` (ae) — pinned as measured on fc1ea38f".
3. **Issuer variants** are all live today (uppercase host is not normalised, echoed as given):
   proposed AC2 text: "... outcome pinned as measured (all three are valid issuers: `/versions` lists
   v1.15 and `auth_metadata` answers 200; the uppercase host is echoed unchanged)".
4. **The contract suite is green today** (no story-9 code is needed for it): it guards the refactor.
   Proposed AC5 note: "the suite is expected to be green before and after the story-9 change".

