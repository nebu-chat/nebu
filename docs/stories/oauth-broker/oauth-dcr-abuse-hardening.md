---
story_id: oauth-dcr-abuse-hardening
title: "DCR and flow-state abuse hardening: per-source pending caps on the registrable domain, public-suffix check, bulk removal of pending registrations, per-source caps on live authorization/account-login requests (gates 2, 3, 4, h, aa)"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-12
branch: feature/migrate-to-oauth2
depends_on: oauth-trusted-proxy-client-ip
---

## Summary

Phase-2 story P2 of epic `oauth-broker`. Closes `follow-ups.md` gate items **2** (bulk reject),
**3** (public suffix), **4** (N-1) and **h** (per-source live authz cap), plus the login-request half
of **aa**. Depends on P1 (`oauth-trusted-proxy-client-ip`): the client IP is ALWAYS
`Nebu.Web.ClientIP.get/1`; never `conn.remote_ip` / `X-Forwarded-For` (P1 contract test AC6.2).

| Gate | Where (HEAD) | Problem |
|---|---|---|
| 4 / N-1 | `client_store.ex` `@sql_insert` l.47-55 | Per-host cap counts pending rows per `client_host` only: 20 attacker registrations for `element.company.com` block every NEW registration of the real client for 30 days. |
| 3 | `registration.ex` `ascii_dns_host?/1` l.346, `host_under?/2` l.359 | `https://github.io` / `https://co.uk` are valid `client_uri`s, making every `*.github.io` redirect "host-bound"; the cap key is the exact host (subdomain rotation). |
| 2 | `oauth_registrations_controller.ex` | Flood recovery = one confirm-and-reject click per row, or SQL. |
| h | `authz_store.ex` `@live_cap 10_000` l.24 / l.48 | With real IPs (P1) ~15 IPs (burst 600/h, IPv6 per full address) fill the global cap: no OAuth login. |
| aa | `account_store.ex` `@login_cap 10_000` l.41 / l.50-55 | Same for `oauth_account_login_requests`. |

Fix: pure modules `Nebu.OAuth.PublicSuffix` (built-in list, no network) and `Nebu.OAuth.SourceKey`
(IPv4 /32, IPv6 /64, SHA-256); additive migration **000044** (nullable columns, CHECKs, indexes; no
RLS change); caps inside the existing INSERTs; admin "Remove pending registrations" (preview,
confirm, CSRF, one audit row, batch 500) and warning badges.

`oauth_enabled` stays OFF. No `server_config` key, no route outside `/admin`, no Matrix API change.
The approval page is a dead controller render (controller + HEEx), NOT a LiveView: "LiveView tests"
means endpoint-level tests in the style of `server/test/nebu/oauth/oauth_admin_test.exs`.

## Story

As an **operator of a Nebu instance with OAuth enabled**,
I want registrations and in-flight logins capped per source and per registrable domain, shared
hosting domains recognised, and pending floods removable in bulk,
so that an unauthenticated attacker can neither block the first OAuth login of my organisation's
real client nor exhaust the flow-state tables, and I recover from a flood in a few clicks.

## Decisions

Prefix `AH` (no collision with D/T/R/C/A/V/TP of ADR-033).

- **AH1 (gate 4: key = (registrable domain, source); REFUSE, never evict).** `oauth_pending_host_cap`
  (default 20, name kept) counts pending rows with the same `client_domain` (AH6) AND `source_key`
  (AH3); above it the unchanged `503 temporarily_unavailable` + `Retry-After`. Rejected: (a)
  evict-oldest-of-host lets an unauthenticated registrant delete rows of a DIFFERENT source (a legit
  row could vanish right before approval); (b) evict-oldest-of-same-(domain, source) churns rows under
  the admin's hands and gains nothing once the source is in the key. Element Web registers from each
  user's browser, so the real client has another source than the attacker, who only fills its own
  slots. Residual: an attacker sharing the source (same NAT or /64) can fill that source's slots;
  recovery = bulk removal by domain (AH8). Dedup hits stay uncapped.
- **AH2 (per-source total cap, global cap kept).** NEW: at most 100 pending rows per `source_key`
  over all domains (`@pending_source_cap 100`, attr seam `:pending_source_cap`): filling the global
  `oauth_pending_cap` (5000, unchanged) needs >= 50 sources. All counts are conditions of the ONE
  INSERT (READ COMMITTED overshoot <= N-1, as today).
- **AH3 (source key).** `SourceKey.from_ip/1`, `for_conn/1` (= `from_ip(ClientIP.get(conn))`).
  Normalise via `:inet.parse_strict_address/1`: IPv4 => `"v4:a.b.c.d"`; IPv6 => `"v6:"` + first 64
  bits as 16 lowercase hex chars; IPv4-mapped => IPv4 form; unparseable (P1 TP10 fallback) =>
  `"raw:"` + input truncated to 64 bytes. Key = lowercase hex SHA-256 of `"nebu-oauth-source-v1|" <>
  normalised`. A fixed-length grouping key, pseudonymous, not anonymous (IPv4 is enumerable). Not
  keyed with the internal secret: DCR does not need the secret today and per-purpose subkeys are gate
  (al); exposure is bounded (`created_from_ip` already holds the clear IP of pending rows, authz/login
  rows live <= 10 min, decided rows carry no key, AH7). Never logged.
- **AH4 (public-suffix list: built-in, no network).** `Nebu.OAuth.PublicSuffix`: two compile-time
  `MapSet`s, hand-picked names (not a copy of the PSL file). `:icann`: `co.uk org.uk ac.uk gov.uk me.uk
  ltd.uk plc.uk net.uk com.au net.au org.au edu.au gov.au co.nz org.nz co.jp ne.jp or.jp com.br net.br
  org.br gov.br edu.br com.cn com.mx co.za co.in com.tr com.sg co.kr com.tw com.hk com.ar co.il org.il
  ac.il gov.il net.il muni.il com.pl net.pl org.pl co.th ac.th or.th go.th in.th net.th co.id ac.id or.id
  go.id web.id com.ua net.ua org.ua gov.ua com.ph com.pk com.eg com.sa com.my com.vn com.ng co.ke com.co
  com.pe co.at or.at`. `:private` (multi-tenant hosting): `github.io githubusercontent.com gitlab.io
  bitbucket.io vercel.app now.sh netlify.app herokuapp.com pages.dev workers.dev trycloudflare.com
  azurewebsites.net azurestaticapps.net cloudapp.net blogspot.com appspot.com web.app firebaseapp.com
  fly.dev onrender.com glitch.me surge.sh readthedocs.io ngrok.io ngrok-free.app ngrok.app
  s3.amazonaws.com cloudfront.net amplifyapp.com duckdns.org wordpress.com wixsite.com myshopify.com
  r2.dev deno.dev up.railway.app loca.lt elasticbeanstalk.com cloudapp.azure.com github.dev` (extended in
  review cycle 1). No wildcard/exception rules. The LONGEST listed suffix equal to the host or a
  dot-suffix of it wins; none => default rule (last label). Registrable domain = suffix + one label.
  Extending (moduledoc): add the lowercase suffix to the right set + a test row + the ADR list. A missing
  platform only means coarser grouping (harmless with the source in the key) and no badge; vendoring the
  full PSL stays follow-up (ar).
- **AH5 (a `client_uri` host that IS a public suffix is refused).** `Registration.validate/1` =>
  `400 invalid_client_metadata` ("client_uri must not be a public suffix such as github.io; use your
  own site, e.g. name.github.io"). Closes the root of the `*.github.io` hole (redirect/logo/tos/policy
  hosts and private-use schemes all derive from the client host). Validation precedes dedup, so an
  existing suffix-host row also gets 400 on re-registration (none in a release; fail closed).
  `name.github.io` is accepted with a badge (AH7).
- **AH6 (registrable domain stored, not trigger-guarded).** `oauth_clients.client_domain`, set by
  `ClientStore.register/1` from `validate/1`'s new `client_domain` (else derived from `client_uri`).
  It drives only pending-row caps; NOT added to the 000040 guard trigger (that would re-state
  000040's function body in 000044; a runtime-role SQL bug rewriting it gains nothing). Pre-000044
  rows: NULL, count only globally (unreleased, they age out).
- **AH7 (minimisation).** `source_key` only on pending rows: approve/reject NULL it with
  `created_from_ip` / `user_agent`; CHECK `oauth_clients_source_key_pending_check (status =
  'pending' OR source_key IS NULL)`. The guard trigger does not list `source_key`, so it allows this.
- **AH8 (bulk = DELETE of pending rows, not "reject").** RLS policy `oauth_clients_delete_pending`
  (000040) already allows it for the runtime role: no RLS change. Not bulk `rejected`: a rejection is
  FINAL (guard trigger, N-3), so one wrong bulk click would permanently block a legit client's
  metadata, and rejected rows are never purged (5000 x up to 60 KB forever). A deleted legit
  registration re-appears as pending on the next flow. Per-row Reject is unchanged. UI wording:
  "Remove pending registrations".
- **AH9 (criteria, preview, snapshot, bounds, audit).** Criteria AND-combined, >= 1 required:
  `host` + `match` (`exact`: `client_host = h`; `domain`: `client_host = d OR right(client_host,
  length(d) + 1) = '.' || d`, `d` = registrable domain of the input; no `LIKE`; also matches
  pre-000044 rows) and `older_than_days` (integer 1..3650). Host input: trimmed, lowercased, the
  registration's LDH rule (new public `Registration.valid_host?/1`); `domain` on a public suffix is
  refused. GET preview (read only): count, first 20 rows, snapshot `as_of` (server UTC ISO 8601);
  POST removes only rows with `created_at <= as_of` (later registrations are never swept); `as_of`
  older than 1 h or in the future => "preview expired", nothing removed. <= 500 rows per POST
  (`ORDER BY created_at LIMIT 500 FOR UPDATE SKIP LOCKED`, outer `status = 'pending'` re-check: the
  purge idiom); more => "500 removed, N still match; run again". ONE transaction: DELETE + ONE audit
  row `oauth_clients_bulk_removed` (target_type `oauth_client`, target_id `"bulk"`, metadata
  `criteria`, `as_of`, `removed`, `client_ids`; no client metadata); audit failure rolls back (the
  `decide/3` contract). Zero matches => no delete, no audit row. Add the action to `AuditWriter`
  `@known_actions` (l.117) or every bulk action rolls back with `:audit_unknown_action`.
- **AH10 (gate h).** `oauth_authz_requests.source_key`; the INSERT also requires `(SELECT count(*)
  ... WHERE source_key = $src AND expires_at > now()) < 300` (`@source_live_cap 300`, seam
  `:source_cap`): the "smaller burst" (300 live rows instead of the 600 the rate burst allows; raised from
  50 in review cycle 1, Kassandra #1: /authorize is a mandatory unauthenticated step of every login, so
  a tight cap lets a co-tenant of a shared NAT address block logins). Global
  10 000 kept as memory bound (filling needs >= 34 sources). Never evict: `{:error, :capacity}` =>
  existing `temporarily_unavailable` redirect. NULL-source rows never count per source. Rate bucket
  `{"oauth_authorize", ip}` unchanged (P1 TP8).
- **AH11 (aa).** Same column + cap 300 (`@source_login_cap`) on `oauth_account_login_requests` (seam `:source_cap`), same
  `unavailable` answer. Account SESSIONS need no per-source cap (authenticated, 20 per user): (aa)
  closed with that rationale.
- **AH12 (caps independent of proxy config).** Behind nginx WITHOUT `NEBU_TRUSTED_PROXY_CIDRS` all
  clients share one source: the per-source caps become small GLOBAL caps (300 in-flight logins, 100
  pending registrations). Availability failure, never a security gap; the activation checklist makes
  "P1 configured and verified" a precondition.
- **AH13 (no `server_config` key).** Constants + attr seams. Re-creating `config_update_mutable` in
  parallel migrations (P3/P4) risks losing keys. `oauth_pending_host_cap` keeps name and range; its
  meaning changes (AH1, documented).
- **AH14 (residuals, non-gating follow-ups).** (1) a /48 holder owns 65 536 /64 sources: coarser
  tier; (2) per-IP rate buckets stay per full IPv6 address (P1 TP8); (3) keyed source hash (al).
- **AH15 (logging).** No line carries a source key, IP, client host or registrable domain. Cap hits
  keep their lines (text "global or per source"). Bulk: `INFO "OAuth admin: bulk removal
  removed=<n> actor=<admin id>"`.
- **AH16 (cluster safety).** Caps are conditions of one INSERT; bulk is one `SKIP LOCKED` statement
  in one transaction; the suffix list is compile-time data; no node-local state, no advisory lock.
- **AH17 (rolling deploy).** 000044 adds only nullable columns, CHECKs existing rows satisfy and
  indexes; old nodes insert NULL sources, which never count per source. One exception, failing closed
  (code review M1): while an OLD node still runs, its approve/reject of a pending registration that a NEW
  node registered (it carries a `source_key`) violates `oauth_clients_source_key_pending_check`, because
  the old SQL does not NULL the key. The decision fails with an error and nothing changes; repeating it
  on a new node succeeds.
- **AH18 (review cycle 1).** (a) The bulk snapshot `as_of` and its 1 h / future window use the DATABASE
  clock (`created_at` is a database timestamp; code review M2). (b) The audit row records the effective
  registrable domain next to the host as typed (M3). (c) The pending-cap counts use `(p IS NULL AND col IS
  NULL) OR col = p` so the partial btree index is usable (M5). (d) A refusal by a PER-SOURCE cap on
  authorize / account login is told apart from the global cap and logged as ONE throttled line per node
  and minute without address, key, host or client id ("per-source ... cap reached ... check
  NEBU_TRUSTED_PROXY_CIDRS"); `server_config` keys for the caps stay a follow-up (as). (e) The suffix list
  is extended (AH4; more ICANN 2LDs, more private platforms); a /48 tier is follow-up (at).

## Acceptance Criteria

### AC1 — `Nebu.OAuth.PublicSuffix` (pure, AH4)

1. `classify(host) :: {:ok, %{domain:, suffix:, kind: :icann | :private | :default,
   public_suffix?: boolean}} | {:error, :invalid_host}`; wrappers `registrable_domain/1`,
   `public_suffix?/1`, `shared_hosting?/1` (matched suffix `:private` and host BELOW it). Lowercases;
   empty label, trailing dot, single label or > 253 bytes => `{:error, :invalid_host}`.
2. Table: `example.com` => `example.com` (`:default`); `a.b.example.com` => `example.com`;
   `foo.co.uk`, `x.foo.co.uk` => `foo.co.uk`; `co.uk`, `github.io`, `GitHub.IO` => `public_suffix?`;
   `name.github.io`, `a.name.github.io` => `name.github.io` (`shared_hosting?`);
   `bucket.s3.amazonaws.com` => itself (longest match); `notgithub.io` => `notgithub.io`.
3. Static: every entry lowercase LDH, >= 2 labels, no duplicates across sets (`suffixes/0`).

### AC2 — Registration (AH5, AH6)

1. `client_uri` hosts `github.io`, `co.uk`, `vercel.app`, `GITHUB.IO` via `POST /oauth2/register` =>
   `400 invalid_client_metadata`, charged to the invalid budget, no row.
2. `https://name.github.io` (redirect `https://name.github.io/cb`) => 201, `client_domain =
   'name.github.io'`; `https://app.example.com` => `client_domain = 'example.com'`.
3. `validate/1` returns `client_domain`; public `valid_host?/1` is the predicate `parse_https/1`
   uses (no copy); metadata hash vectors unchanged.

### AC3 — `Nebu.OAuth.SourceKey` (pure, AH3)

1. Deterministic, 64 lowercase hex; `203.0.113.7` != `203.0.113.8`.
2. `2001:db8:1:2::1` == `2001:db8:1:2:ffff:ffff:ffff:ffff` != `2001:db8:1:3::1`;
   `::ffff:203.0.113.7` == `203.0.113.7`.
3. `"garbage"` yields a key, never raises; > 64 bytes truncated; static: no `remote_ip` /
   `x-forwarded-for` in the module.
4. Vector test pins the keys of `203.0.113.7` and `2001:db8:1:2::1`.

### AC4 — Migration `000044_oauth_abuse_hardening.{up,down}.sql`

1. Up (`IF NOT EXISTS`): `oauth_clients` + `client_domain TEXT`, `source_key TEXT`, CHECKs
   `oauth_clients_source_key_format_check (source_key IS NULL OR source_key ~ '^[0-9a-f]{64}$')` and
   `oauth_clients_source_key_pending_check`; partial indexes `oauth_clients_pending_domain_source_idx
   (client_domain, source_key) WHERE status = 'pending'`, `oauth_clients_pending_source_idx
   (source_key) WHERE status = 'pending'`. `oauth_authz_requests` and `oauth_account_login_requests`
   + `source_key TEXT`, same format CHECK, index `(source_key, expires_at)`.
2. No GRANT, policy, trigger or `server_config` change (table grants cover new columns);
   000040-000043 untouched (static: they do not mention `source_key` / `client_domain`).
3. Down drops indexes, CHECKs and columns only.
4. `server/test/nebu/migration/000044_oauth_abuse_hardening_test.exs` mirrors
   `000041_oauth_authz_codes_test.exs`: static checks; `:integration` as the runtime role (columns,
   CHECK violations: malformed key, decided row with key; RLS unchanged: decided row not deletable,
   pending row deletable); down/up round trip on the privileged role in a rolled-back transaction.

### AC5 — `ClientStore.register/1` caps (`:integration`, AH1, AH2)

Distinct metadata per call; caps via attr seams.

1. `pending_host_cap: 3`: 3 x `app.example.com` from source A => created; 4th from A => `:capacity`;
   the same new metadata from B => created; A for `other.example.com` => `:capacity` (domain
   grouping); A for `app.example.org` => created.
2. `pending_source_cap: 2`: A's 3rd domain => `:capacity`; B unaffected.
3. Global cap still refuses (derive it from the current pending count, as existing tests do).
4. Dedup hits never refused (also from a capped source).
5. Approve/reject NULL `source_key` (+ ip, ua) and free the slots.
6. Without `:ip` `source_key` is NULL: per-source condition skipped, the domain condition counts
   NULL-source rows of that domain (`IS NOT DISTINCT FROM`; the HTTP path always passes a source).

### AC6 — N-1 through `POST /oauth2/register` with distinct client IPs (`:integration`)

`T.register/2` with `ip:` and P1's `:xff` + `Nebu.Web.ClientIP.configure/1` (reset in `on_exit`).

1. Default host cap 20: attacker peer `198.51.100.9` registers 20 distinct metadata for
   `element.company.example`; the 21st => `503` + `Retry-After`; legit `203.0.113.7` with NEW
   metadata for the same host => `201` pending.
2. Same through trusted peer `10.0.0.5` (`configure("10.0.0.0/8")`) with `XFF: 198.51.100.9` vs
   `XFF: 203.0.113.7`: legit => `201`.
3. Spoof: untrusted peer `198.51.100.9`, 21 registrations each with a different `XFF` => 21st `503`.
4. IPv6: 20 from `2001:db8:1:2::1..20` => 21st from `2001:db8:1:2::99` `503`, from `2001:db8:1:3::1`
   `201`.
5. Response shapes unchanged (RFC 7591, CORS `*`, `no-store`).

### AC7 — Approval page badges (through `Nebu.Admin.Endpoint`)

1. Host below a `:private` suffix => `[data-role="shared-hosting-warning"]` (badge-warning, text
   "shared hosting domain (github.io): anyone can create sites here"); `[data-role="client-domain"]`
   shows the registrable domain when it differs from the host.
2. A legacy pending row (SQL) whose host IS a suffix => `[data-role="public-suffix-error"]`
   (badge-error, "client URI host is a public suffix").
3. Ordinary domains: no badge. Text, not colour only; HEEx-escaped. The HTML module uses
   `Nebu.OAuth.host_info/1` (ADR-020), never `Nebu.OAuth.PublicSuffix` (static test).
4. Each row with a host has `[data-role="bulk-remove-domain"]` linking to the preview
   (`?host=<domain>&match=domain`, `URI.encode_query/1`), `aria-label="Remove all pending
   registrations of <domain>"`.

### AC8 — Bulk store function (`:integration`, runtime role, AH8, AH9)

`Nebu.OAuth.bulk_remove_pending(criteria, as_of, opts)` (=> `ClientStore.bulk_delete_pending/3`)
and `Nebu.OAuth.bulk_remove_preview(criteria, as_of)` (count + first 20, newest first).

1. Only pending rows matching ALL criteria and `created_at <= as_of` are deleted; approved/rejected
   rows of the host survive; a raw `DELETE ... WHERE client_host = $1` (no status filter) as the
   runtime role via `T.sql!` also leaves them (RLS defence in depth).
2. `exact` vs `domain` incl. a NULL-`client_domain` row; `example.com` never matches
   `notexample.com`.
3. 501 matches => 500 removed (oldest first), `{:ok, %{removed: 500, remaining: 1, client_ids: _}}`.
4. A row created after `as_of` is never removed.
5. Two concurrent calls remove each row once in total, no error.
6. `:audit` runs in the transaction with the removed ids; `{:error, _}` => rollback, `{:error,
   {:audit, _}}`, rows present.
7. Invalid criteria (none, bad host, days 0 / 3651 / "x", `domain` on a suffix) =>
   `{:error, {:invalid_criteria, reason}}`, no query.

### AC9 — Bulk UI (through `Nebu.Admin.Endpoint`)

Routes in the existing `:browser` + `require_admin` scope, ABOVE the `:client_id` posts:
`GET` and `POST /admin/oauth/registrations/bulk-remove`.

1. List page form `[data-form="bulk-remove"]` (GET to the preview): labelled `host`, radio group
   `match` in fieldset + legend (default `domain`), `older_than_days` (`type=number min=1
   max=3650`), help text via `aria-describedby`.
2. Preview: `h1` "Remove pending registrations"; `role="status"` summary
   `[data-role="bulk-match-count"]` (`data-count`); table (caption, `scope`) of <= 20 rows; criteria
   in words; note "At most 500 are removed per run. Removed registrations are deleted; a legitimate
   client that registers again appears as a new pending registration."; POST form
   `[data-form="bulk-remove-confirm"]` (hidden criteria, `as_of`, `_csrf_token`) with
   `data-confirm` ("Remove N pending registrations matching <criteria>? This cannot be undone.",
   existing `app.js` native confirm) and button `[data-role="bulk-remove-confirm"]`. Zero matches =>
   `[data-role="bulk-no-match"]`, no form.
3. Invalid criteria => preview re-rendered, inputs preserved, `role="alert"` error with
   `aria-invalid="true"` + `aria-describedby`; no DB write.
4. POST => redirect to the list with flash "N pending registrations removed." / "500 removed, N still
   match. Run the removal again." / "No pending registration matched; nothing was removed."; expired
   `as_of` => error flash, nothing removed.
5. With `:admin_csrf_bypass` OFF a POST without/with a wrong token is refused and deletes nothing;
   a non-admin session is redirected to login; no audit row.
6. Exactly ONE audit row per successful POST with the AH9 metadata (seam
   `:compliance, :audit_writer`; one `:integration` test reads the real `audit_log` row); no client
   name/URI in it. Failing audit writer => error flash "nothing was removed", rows present.
7. HTML only (no JSON) on the bulk routes; the list JSON is unchanged.

### AC10 — Gate h: live authorization requests (`:integration`, AH10)

1. `AuthzStore.insert/1` with `source_cap: 3`: 4th live row of a source => `:capacity`; another
   source `:ok`; expired and NULL-source rows do not count.
2. `T.authorize/2` for an approved client: seed 300 live rows with the key of `203.0.113.7`
   (privileged SQL); request from `203.0.113.7` => error redirect `temporarily_unavailable` (`state`,
   `iss`), nothing inserted; from `203.0.113.8` => 302 to the IdP, row `source_key =
   SourceKey.from_ip("203.0.113.8")`.
3. IPv6 /64 as AC6.4; XFF variant as AC6.2 (key = forwarded client).
4. The existing 10 000-row tests (`oauth_idp_delegation_test.exs` ~l.318-350) stay green; static:
   the only DELETEs in `authz_store.ex` remain `consume/1` and `purge_expired/0` (no eviction).

### AC11 — aa: account login requests (`:integration`, AH11)

1. `AccountStore.insert_login_request/1` with `source_cap: 2`: 3rd live row of a source =>
   `:capacity`; other source `:ok`.
2. `GET /account` login start from a capped source => `unavailable` page; other source => 302 to the
   IdP; `oauth_account_hardening_test.exs` global-cap test (~l.480) stays green.

### AC12 — Logging (AH15)

`capture_log` over AC6.1, AC8 and AC10.2: no source key, test IP, client host or domain in the
output; the bulk line has only count and admin id.

### AC13 — No regressions

`oauth_dcr_dedup_limits_test.exs` F-1b tests (l.200-260) use a fresh `unique_ip()` per request:
"above the host cap" now needs the SAME `ip:` for all calls; add "another source is not refused".
Everything else in `server/test/nebu/oauth/*`, migration tests 000040-000043, `oauth_admin_test.exs`
and the e2e feature stays green.

### AC14 — Documentation

1. ADR-033 section "DCR and flow-state abuse hardening (phase 2, story oauth-dcr-abuse-hardening)"
   with AH1-AH17 + the suffix list; rewrite "Pending registrations" > "Per-host cap"; update the
   "Approval page" bullet "No public-suffix check yet (gate item 3)"; mark gate items 2, 3, 4
   "resolved by story oauth-dcr-abuse-hardening"; extend the story-2 "at most 10 000 live
   `oauth_authz_requests` rows" sentence by the per-source cap.
2. Moduledocs: `ClientStore` (caps; bulk delete is the second DELETE), `AuthzStore`, `AccountStore`,
   `Registration` (replace "No public-suffix check is done"), `Nebu.OAuth.Http` (register order step
   6), controller (bulk routes, AH8).
3. Apply the 07-deployment and follow-ups edits of the Dev Notes; `adr_033_test.exs` pins the new
   headline, AH1/AH8/AH10 keywords and the new `oauth_pending_host_cap` row (ATDD picks regexes);
   the pins at l.92-98 must still match (keep "Bulk reject" and "Public-suffix" in the gate list).

### AC15 — E2E (Gherkin + TS, typecheck only, epic brief)

In `e2e/features/admin/oauth-client-approvals.feature` (`@oauth-approvals`):

1. `@ac-bulk-remove-host`: 3 clients for one test domain + 1 for another via the REAL DCR endpoint;
   the row link "Remove all pending registrations of <domain>" shows "3 pending registrations
   match"; confirm (native confirm fires); success toast; the 3 rows are gone, the other remains; one
   `oauth_clients_bulk_removed` audit row with `removed = 3` (DB read).
2. `@ac-bulk-remove-age`: rows seeded 40 days old via `fixtures/db.ts` (age cannot be produced
   through the endpoint; same exception as the pagination scenario) + one fresh real registration;
   "older than 30 days" removes only the seeded rows.
3. `@ac-public-suffix`: `client_uri=https://github.io` => 400 `invalid_client_metadata`;
   `https://e2e-<rand>.github.io` is listed with the shared-hosting badge.
4. Keyboard-only variant of 1 (Tab/Enter only); axe check on the preview page if the suite has an
   axe helper (else a TODO comment).
5. The After hook also cleans this feature's rows; `tsc --noEmit` + `bddgen --tags
   "@oauth-approvals"` pass.

## Acceptance Tests

- Unit: `server/test/nebu/oauth/public_suffix_test.exs` (AC1), `source_key_test.exs` (AC3).
- DB/RLS: `server/test/nebu/migration/000044_oauth_abuse_hardening_test.exs` (AC4).
- Integration: `server/test/nebu/oauth/oauth_abuse_caps_test.exs` (AC2, AC5, AC6, AC10-AC12),
  `oauth_bulk_remove_test.exs` (AC8).
- Extended: `oauth_admin_test.exs` (AC7, AC9), `oauth_dcr_dedup_limits_test.exs` (AC13),
  `oauth_dcr_validation_test.exs` (AC2.1), `adr_033_test.exs` (AC14.3). E2E: AC15.
- None of the caps is a RateLimit bucket: `NEBU_RATE_LIMIT_DISABLED=true` (CI) does not disable
  them; rate-limited paths keep fresh `unique_ip()` sources.

## Must be test-covered

1. 20 attacker registrations for a host never block another source's NEW registration (peer, XFF, IPv6 /64).
2. Same source + registrable domain capped across subdomains; dedup never capped.
3. Per-source total and global pending caps.
4. Suffix host refused; subdomain of a private suffix accepted + badge.
5. Bulk: pending only, `as_of`, bounded, concurrent-safe, audited in-transaction, CSRF, admin-only.
6. Per-source caps on live authz and login requests; no eviction; global caps intact.
7. Decided rows carry no `source_key`. 8. No source key / IP / host in logs.

## Dev Notes

### Current state and change points

- `ClientStore.register/1` (l.131-162), `@sql_insert` l.47-55: add `$11 client_domain`,
  `$12 source_key`, `$13 pending_source_cap`; host condition becomes `(SELECT count(*) FROM
  oauth_clients WHERE status = 'pending' AND client_domain IS NOT DISTINCT FROM $11 AND source_key
  IS NOT DISTINCT FROM $12) < $10`; add `($12::text IS NULL OR (SELECT count(*) FROM oauth_clients
  WHERE status = 'pending' AND source_key = $12) < $13)`. `@sql_approve` / `@sql_reject` l.97-109:
  `source_key = NULL`.
- `Nebu.OAuth.Http.store/2` (l.484): add `source_key: SourceKey.for_conn(conn)`.
- `Registration.validate/1` (l.93-124): refuse suffix hosts after `client_uri/1`, return
  `client_domain`; `ascii_dns_host?/1` (l.346) becomes public `valid_host?/1`.
- `AuthzStore.insert/1` (l.79-90, SQL l.37-48): `$17 source_key`, `$18 cap`;
  `Authorize.delegate/5` (~l.211) passes `source_key: SourceKey.for_conn(conn)`.
- `AccountStore.insert_login_request/1` (l.131-150, SQL l.50-55) and `Account.start_login/4`
  (l.438): the same.
- Admin: `Nebu.Admin.Router` l.235-239 (bulk routes above the `:client_id` posts); controller
  (`decide/5`, `write_audit/4` = audit pattern; reuse `actor_id/1`, `error_type/1`); template
  `templates/oauth_registrations/index.html.heex` (bulk form above the table, badges in the
  `data-field="client-uri"` cell, row link in Actions); new `bulk_preview.html.heex`; helpers in
  `oauth_registrations_html.ex`.
- `Nebu.Compliance.AuditWriter` `@known_actions` (l.117): `oauth_clients_bulk_removed`.
- `server/lib/nebu/oauth.ex` (registration block l.181-214): `bulk_remove_preview/2`,
  `bulk_remove_pending/3`, `host_info/1`.
- Seams: `oauth_test_support.exs` `register/2`, `authorize/2`, `with_opts/2` (`ip:`; P1 adds
  `:xff`), `insert_row!/6` (add optional `client_domain`/`source_key`), `with_privileged_conn/1`,
  `sql!/2`; admin tests: `Nebu.Admin.Endpoint.admin_session/2` + `put_session("current_user", ...)`,
  `:admin_csrf_bypass` (OFF for AC9.5).

### Bulk SQL (one statement)

```sql
DELETE FROM oauth_clients
WHERE status = 'pending' AND client_id IN (
  SELECT client_id FROM oauth_clients
  WHERE status = 'pending' AND created_at <= $1                       -- as_of
    AND ($2::text IS NULL OR client_host = $2)                         -- exact host
    AND ($3::text IS NULL OR client_host = $3
         OR right(client_host, length($3) + 1) = '.' || $3)            -- registrable domain
    AND ($4::int IS NULL OR created_at < now() - ($4 * interval '1 day'))
  ORDER BY created_at LIMIT $5 FOR UPDATE SKIP LOCKED)                 -- 500
RETURNING client_id
```

`remaining` = the same predicate counted after the DELETE, in the transaction.

### Exact doc edits (applied by this story's dev run)

`docs/architecture/07-deployment.md`:
- Row `oauth_pending_host_cap` (~l.114): "Maximum number of `pending` registrations per
  (registrable domain of the `client_uri` host, client source); the source is the resolved client IP
  (`NEBU_TRUSTED_PROXY_CIDRS`), IPv6 per /64. A source is also limited to 100 pending registrations
  over all domains (built-in). Same response as the global cap. A `client_uri` host that is a public
  suffix (`github.io`, `co.uk`) is refused at registration." (GATE sentence removed).
- Preconditions (~l.185-187): row 2 "Bulk removal of pending registrations (by host/registrable
  domain, by age; audited)" | "closed (story oauth-dcr-abuse-hardening)"; row 4 "Per-host pending
  cap keyed on (registrable domain, client source)" | "closed (story oauth-dcr-abuse-hardening);
  effective only with item 1 configured"; row h "Per-source caps on live `oauth_authz_requests` (300
  per source, /64) and `oauth_account_login_requests`" | same status; new row 3 "Public-suffix check
  (built-in list; suffix hosts refused; warning badge)" | "closed" | "server".
- Activation checklist step: "With `NEBU_TRUSTED_PROXY_CIDRS` verified, two clients on different
  networks get independent per-source caps; without it the per-source caps act as small global caps
  (300 in-flight logins, 100 pending registrations)."

`docs/stories/oauth-broker/follow-ups.md`:
- Items 2, 3, 4: append "**RESOLVED by story oauth-dcr-abuse-hardening** (AH8-AH9 / AH4-AH5 /
  AH1)"; (h): "**RESOLVED** (AH10)"; (aa): "**RESOLVED** for login requests (AH11); sessions need no
  per-source cap (authenticated, 20 per user)".
- New section "From story oauth-dcr-abuse-hardening (2026-10-12)", non-gating: (ao) coarser IPv6
  tier (/48); (ap) /64 aggregation of the per-IP rate buckets; (aq) keyed source hash (with al); (ar)
  suffix-list maintenance / optional vendored PSL.

### Gate status (plan, after merge)

| Gate | Before | After |
|---|---|---|
| 2 | open | closed (AH8/AH9) |
| 3 | open (epic-end) | closed (AH4/AH5/AH7) |
| 4 / N-1 | open (with 1) | closed in the server; effective only with gate 1 configured |
| h | open (with 1) | closed in the server; same condition |
| aa | non-gating | closed (login requests); sessions need no cap |

### Must be preserved

Response codes/shapes of `/oauth2/register`, `/oauth2/authorize`, `/account`; dedup-first order and
every RateLimit bucket; 000040 RLS/guard semantics; per-row approve/reject; admin CSP (no inline
script; native confirm via `app.js` `data-confirm`), logos-on-click, pagination; `oauth_enabled` OFF.

### Traps

- Never `conn.remote_ip` / XFF; never `inspect` a Postgrex error (failing row = IP/metadata): reuse
  `log_reason/1` / `error_type/1`.
- `right(...) = '.' || $3` is NULL for NULL `$3` (guarded). Never build `LIKE` from admin input.
- `FOR UPDATE` in the bulk subquery uses the existing UPDATE grant on `oauth_clients`;
  `oauth_authz_requests` has none (do not add row locks there).
- `as_of`: `DateTime.to_iso8601/1` (microseconds kept) / `from_iso8601/1`.
- Audit `client_ids` bounded by the 500 batch (~17 KB jsonb).
- F-1b tests fail under AH1 by design: update them (AC13), never weaken AH1.

### Architecture compliance

ADR-018 (inline SQL in the stores), ADR-019, ADR-020 (admin -> `Nebu.OAuth` only; `SourceKey` uses
shared `Nebu.Web.ClientIP`), cluster safety (AH16), logging law (AH15), additive migration
(000040-000043 never edited), no new dependency (PSL hex packages bundle or fetch the full list).

### Accessibility (skills/nebu-agent-ux)

`<label for>` on every input; radios in `<fieldset><legend>`; help/errors via `aria-describedby`;
errors `role="alert"` + `aria-invalid`; preview summary `role="status"`; tables with `<caption>` and
`scope`; badges carry text, DaisyUI tokens for contrast; links/buttons name the domain; full keyboard
path (AC15.4); no positive `tabindex`; DOM-order focus.

### Testing commands (isolated env)

- After adding the migration: `docker rm -f nebu-oauth-pg`, then
  `quick.sh "mix test --include integration test/nebu/migration/000044_oauth_abuse_hardening_test.exs test/nebu/oauth"`.
- Full gate: `cleanup.sh`, `integration.sh` in the background, compare with `known.txt`.
- E2E from a scratchpad copy: `npx tsc --noEmit`, `npx bddgen --tags "@oauth-approvals"`.

### Out of scope

AH14 residuals, a vendored full PSL, revoking approved clients (P4, aj), same-origin protection of
`/admin` POSTs (P4, ag/E-3: the bulk POST sits in the same controller and gets the same treatment),
`server_config` keys for the new limits.

## Manual verification

Fail closed until done (the caps then act as small global caps, AH12):

1. On each reference deployment with `NEBU_TRUSTED_PROXY_CIDRS` verified (P1): client A registers 20
   new metadata for one test host through the public URL => 21st `503`; client B on another network
   => `201` for the same host.
2. Real browser: badges for a `*.github.io` registration; bulk removal by domain and by age; native
   confirm; toast; one `oauth_clients_bulk_removed` row in the `/admin` audit log; keyboard-only and
   VoiceOver pass on the preview page.
3. Element Web + real Dex: after 300 abandoned authorize requests from another network, a real login
   still succeeds.

## Open questions

1. Are 300 live flows / 100 pending registrations per source enough for a large office behind one NAT
   IP? Proposed: yes (only unfinished flows within 10 min count); otherwise a later migration adds
   `server_config` keys and re-creates `config_update_mutable` with the union of all keys.
2. Raise the global authz cap (e.g. 50 000) now that it is a memory bound? Proposed: not here
   (existing 10 000-row tests; 34 sources needed to fill it).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev-story, phase 2, P2).

### Debug Log References

- Migration reset: `docker rm -f nebu-oauth-pg` before the first run after adding 000044.
- Story tests (public_suffix, source_key, 000044 migration, abuse caps, bulk remove, admin, ADR pins): all green.
- `mix test --include integration test/nebu/oauth test/nebu/migration test/nebu/web test/nebu/admin`: 3201
  tests, 25 failures, all in the known families of `scratchpad/known.txt` (RoomsFallbackName, LogsLive
  WarRoom / TraceMapNodeControls, TemporaryCaptureManager, LogStore.Retention, AdminOidcLogin / OidcPlug
  reused-DB, ConfigController sso-schemes); 0 OAuth / migration / admin-oauth failures.
- Full `mix test --include integration` on a fresh DB: 5345 tests, 20 failures (RoomsFallbackName 11,
  LogsLive TraceMapNodeControls 3 + WarRoom 2, TemporaryCaptureManager 2, RegressionSyncLoad 1,
  MediaScanWorkerKillSwitch 1 = a `GenServer.stop` teardown flake, 102/102 green alone); 0 OAuth /
  migration / web-OAuth / admin-OAuth failures.
- `MIX_ENV=prod mix compile --force`: only the pre-existing `upgrade_room/2` type warning
  (`event_dispatcher/server.ex:4840`); nothing from this story.
- E2E (scratchpad copy of `e2e`, node_modules symlinked): `tsc --noEmit` exit 0, `bddgen --tags
  "@oauth-approvals"` generates the spec (AC15 scenarios present).

### Completion Notes List

- AC1 `Nebu.OAuth.PublicSuffix` (two compile-time sets, longest suffix wins, `classify/1` plus
  wrappers, `suffixes/0`); AC3 `Nebu.OAuth.SourceKey` (`from_ip/1`, `for_conn/1` through
  `Nebu.Web.ClientIP.get/1`, vectors pinned).
- AC2 `Registration.validate/1` refuses suffix hosts (400 `invalid_client_metadata`) and returns
  `client_domain`; `ascii_dns_host?/1` is the public `valid_host?/1` (no copy).
- AC4 migration `000044_oauth_abuse_hardening` (nullable columns, three format CHECKs, the pending-only
  CHECK on `oauth_clients`, partial / composite indexes, no grant/policy/trigger/server_config change).
- AC5/AC6 `ClientStore.register/1`: `client_domain`, `source_key`, (domain, source) cap
  `oauth_pending_host_cap` (`IS NOT DISTINCT FROM`), per-source `@pending_source_cap 100`, all in the
  ONE INSERT; approve/reject also NULL `source_key`; `Http.store/2` passes `SourceKey.for_conn/1`.
- AC8 `ClientStore.normalize_criteria/1`, `bulk_preview/2`, `bulk_delete_pending/3` (one statement,
  `ORDER BY created_at LIMIT 500 FOR UPDATE SKIP LOCKED`, outer `status = 'pending'`, audit function in
  the SAME transaction; a raising/aborting audit rolls back); facade `Nebu.OAuth.bulk_remove_preview/2`,
  `bulk_remove_pending/3`, `host_info/1`; `AuditWriter` `@known_actions` += `oauth_clients_bulk_removed`.
- AC7/AC9 admin: routes `GET|POST /admin/oauth/registrations/bulk-remove` above the `:client_id` posts;
  controller `bulk_preview/2` / `bulk_remove/2` (server-UTC `as_of` snapshot, expired when missing, future
  or older than 1 h, one audit row, flash texts per AC9.4, log line `bulk removal removed=<n> actor=<id>`
  only); `bulk_preview.html.heex` + the criteria form component (`<label for>`, fieldset/legend radios,
  `aria-describedby`, `role="alert"` + `aria-invalid`, `role="status"` count, table caption/`scope`,
  native `data-confirm`); badges and the per-row bulk link on the list (through `Nebu.OAuth.host_info/1`,
  never `PublicSuffix` directly). A legacy row whose host IS a public suffix links to `match=exact`
  (a `domain` match on a suffix is refused by AH9).
- AC10/AC11 `AuthzStore.insert/1` and `AccountStore.insert_login_request/1`: `source_key` column,
  `@source_live_cap 300` / `@source_login_cap 300` conditions inside the INSERT, `:source_cap` seams;
  `Authorize.delegate/5` and `Account.start_login/4` pass `SourceKey.for_conn(conn)`; no eviction (the
  only DELETEs of `authz_store.ex` stay `consume/1` and `purge_expired/0`).
- AC14 docs: ADR-033 section "DCR and flow-state abuse hardening (phase 2, story
  oauth-dcr-abuse-hardening)" (AH1-AH17, suffix list, Manual verification), "Per-host cap" bullet rewritten,
  approval-page bullet, gate items 2/3/4 marked resolved, D19 sentence, phase-2 update line;
  `07-deployment.md` (host-cap row, preconditions rows 2/3/4/h, activation sentence); `follow-ups.md`
  (2, 3, 4, h, aa resolved; new items ao-ar); moduledocs of ClientStore, AuthzStore, AccountStore,
  Registration, Http, the controller, AuditWriter, Config.
- Pre-dev test review findings M1-M10 fixed in the staged tests (1200-row / 3-caller concurrency test,
  attacker rows asserted present, valid-CSRF positive control, escaped-form asserts, singular flash pin,
  `async: false` + restore of the `ClientIP` trusted set, deterministic source keys, behaviour/word-bound
  static pins, comment-stripped purity check, separate `:oauth_repo` restore).

### Deviations and findings

- Staged tests that contradicted the story / schema were corrected: `valid_host?/1` is the strict
  registration rule (the test listed `localhost` and an `xn--` host as valid, but `parse_https/1` rejects
  both; they now sit in the "invalid" list); the account login-request fixtures used non-hex
  `state_hash` / `binding_hash` (000043 CHECKs need 64 hex); the migration test now asserts the
  `source_key` CHECK name instead of any check violation.
- `oauth_dcr_integration_test.exs` (not part of ATDD): two tests approve/reject an endpoint-registered
  row by raw SQL; under the 000044 pending-only CHECK they must set `source_key = NULL` in the same
  UPDATE (as `approve/3` / `reject/3` do).
- Preview `as_of` is strict: no clock-skew allowance for a future timestamp (AH9: "in the future =>
  preview expired"); a user retries.
- Not run here (no real IdP/browser): the Manual verification section of the story.

### Review cycle 1 (code review M1-M5, UX gate, Kassandra #1-#3)

- M1: migration header, AH17 and ADR corrected (an old node's approve/reject of a new-node registration
  fails closed on the pending-only CHECK; repeating on a new node works). M2: `as_of` and the 1 h / future
  window now come from the DATABASE clock (`ClientStore.db_now/0`, `snapshot_age_us/1`, facade
  `bulk_remove_snapshot/0`, `bulk_remove_snapshot_age_us/1`); tests: window judged on the DB clock (59 min
  accepted, 61 min and +5 s expired), snapshot >= a row created just before, static pin that the controller
  never reads `DateTime.utc_now`. A truly skewed app clock cannot be simulated without a clock seam, which
  would only exist for the test, so the app clock is removed from the path instead. M3: audit criteria add
  `domain` (effective registrable domain) next to `host` as typed and the parsed `older_than_days`
  (`Nebu.OAuth.bulk_remove_criteria/1`). M4: stale test moduledoc. M5: `(p IS NULL AND col IS NULL) OR col
  = p` instead of `IS NOT DISTINCT FROM`.
- UX: blocking contrast fixed (row link is `link link-primary text-sm`, the colour used by the other links
  of the table); A1 bulk form moved below the list and pagination (no extra tab stops before Approve/Reject;
  not a collapsed `<details>` because the e2e steps need the form visible); A2 h2 "Matching registrations";
  A3 `input-error`; A4 fieldset id + `aria-describedby` to the error for match / public-suffix errors; A5
  "at least one criterion is required" in the help text; A6 badges in a `flex flex-wrap` wrapper with
  visible "Warning:" / "Error:" prefixes (outside the badge elements, whose text is pinned); A8 Cancel link
  next to the confirm button; A10 fieldset classes as in the bootstrap page; A12 new e2e scenario
  `@ac-bulk-invalid` (label / aria-invalid / aria-describedby / group wiring). NOT applied: A7 (the
  `aria-label` of the row link is pinned by AC7.4 and its test; the visible text equals it, so it is
  consistent), and `role="status"` stays on the count (pinned by AC9.2).
- Kassandra #1: default per-source live caps for `oauth_authz_requests` and `oauth_account_login_requests`
  raised 50 -> 300 (AH10, AH11, ADR, 07-deployment, tests with 300 seeded rows); a per-source refusal is
  told apart from the global cap (`AuthzStore.source_capped?/2`, `AccountStore.source_capped?/2`, one extra
  count on the refusal path only) and logged as ONE throttled source-free line per node and minute
  (`RateLimit.take`, no address / key / host / client id; global-cap lines unchanged); tests for the
  wording, the throttle and the absence of identifiers. `server_config` configurability -> follow-up (as).
  #2 /48 tier -> follow-up (at). #3 suffix list extended (ICANN: net/org/gov/edu.br, co/org/ac/gov/net/muni.il,
  com/net/org.pl, co/ac/or/go/in/net.th, co/ac/or/go/web.id, com/net/org/gov.ua, com.ph/pk/eg/sa/my/vn/ng/co/pe,
  co.ke, co.at, or.at; private: wordpress.com, wixsite.com, myshopify.com, r2.dev, deno.dev, up.railway.app,
  loca.lt, elasticbeanstalk.com, cloudapp.azure.com, github.dev); PSL vendoring stays (ar). Code-review I5
  (NAT64 aggregation) noted under (ao).
- Runs after cycle 1: story tests + oauth/migration/web/admin dirs: 3206 tests, 17 failures, all known
  families (RoomsFallbackName 11, LogsLive 4, TemporaryCaptureManager 2). E2E `tsc --noEmit` 0 and `bddgen`
  ok. Full suite and prod compile: see the final report of this cycle.

### File List

- server/lib/nebu/oauth/public_suffix.ex (new)
- server/lib/nebu/oauth/source_key.ex (new)
- server/priv/migrations/000044_oauth_abuse_hardening.up.sql (new)
- server/priv/migrations/000044_oauth_abuse_hardening.down.sql (new)
- server/lib/nebu/admin/templates/oauth_registrations/bulk_preview.html.heex (new)
- server/lib/nebu/oauth.ex, oauth/client_store.ex, oauth/registration.ex, oauth/http.ex,
  oauth/authz_store.ex, oauth/account_store.ex, oauth/authorize.ex, oauth/account.ex, oauth/config.ex
- server/lib/nebu/compliance/audit_writer.ex
- server/lib/nebu/admin/router.ex, admin/oauth_registrations_controller.ex,
  admin/oauth_registrations_html.ex, admin/templates/oauth_registrations/index.html.heex
- Tests: server/test/nebu/oauth/{public_suffix,source_key,oauth_abuse_caps,oauth_bulk_remove,oauth_admin,
  oauth_dcr_integration,adr_033,oauth_client_store,oauth_dcr_dedup_limits,oauth_dcr_validation,
  oauth_pending_protection}_test.exs, oauth_test_support.exs;
  server/test/nebu/migration/000044_oauth_abuse_hardening_test.exs
- E2E: e2e/features/admin/oauth-client-approvals.feature,
  e2e/step-definitions/admin/oauth-client-approvals.steps.ts, e2e/fixtures/db.ts
- Docs: docs/architecture/adr/ADR-033-authorization-server-broker-model.md,
  docs/architecture/07-deployment.md, docs/stories/oauth-broker/follow-ups.md, this story

## Change Log

- 2026-10-12: story created (ready-for-dev).
- 2026-10-12: implemented (dev-story): status review.
- 2026-10-12: review cycle 1 (code-review M1-M5, UX gate, Kassandra #1-#3) applied.
