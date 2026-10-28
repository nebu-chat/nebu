## Security Review — oauth-broker / oauth-metadata-dcr-admin-approval (story 1 of the Matrix OAuth 2.0 broker)

**Diff scope:** staged diff (`git diff --staged`, 55 files). In scope: `GET /_matrix/client/v1/auth_metadata` (`Nebu.OAuth.Http` + `Nebu.OAuth.Metadata` + `Nebu.OAuth.Config`), unauthenticated `POST /oauth2/register` (`Nebu.OAuth.Registration`, `Nebu.OAuth.ClientStore`, `Nebu.Web.Plugs.JsonBody` 128 KiB branch, `Nebu.Web.Plugs.RateLimit.take/3`), migration 000040 (oauth_clients, RLS/FORCE, delete-pending policy, status-guard trigger, `config_update_mutable` widening), `Nebu.Workers.OAuthPendingPurgeWorker` + Oban cron, admin approval page (`OAuthRegistrationsController`/`HTML`/HEEx, admin router `accepts_formats` and CSP, `?logos=1` CSP widening), `AuditWriter` allowlist, `PayloadRedactor` additions, ADR-033, tests and e2e.
**Date:** 2026-10-09
**Reviewer:** Kassandra (story-level SEC Gate 1)
**Context read:** story ACs, both "ATDD Decisions" sections, "Decisions after code-review cycle 0"; spec sections 3, 4, 10, 11; code-review cycle 0 and cycle 2 and UX-gate findings. Those were re-checked against the code, not taken on trust.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/oauth/http.ex:65-67,177-186,280`; `client_store.ex:38-45` | **Unauthenticated DoS of client registration, which becomes a login DoS once stories 2-4 ship.** The per-IP bucket uses `conn.remote_ip`. Both reference deployments (UpCloud and Stackit cloud-init) put nginx in front, so every client shares ONE per-IP bucket: 50 registrations per hour for the whole server. The global 500/h bucket can be drained by anyone. The limits are checked before dedup, so known and approved clients are throttled too. Spec §4 says clients register on EVERY flow. The pending cap (5000) can be filled in about 10 h on one node and only empties after the 30-day TTL. There is no bulk reject. | Get the client IP through a trusted-proxy allowlist (CIDR-gated XFF/`Forwarded`). Charge the buckets only when a request would INSERT a new row: validate, look up by hash, answer dedup hits under a separate, looser limit. Cap pending rows per `client_uri` host. Add bulk reject. **Gate: must be closed before `oauth_enabled` can be true / before story 2 merges.** |
| 2 | LOW | `server/lib/nebu/web/router.ex:67-69,87-93` (`auth_issuer` v1 + unstable msc2965 `auth_issuer`/`auth_metadata`) | **Two different issuers are advertised once OAuth is enabled.** The stable `auth_metadata` names Nebu as issuer. `v1/auth_issuer` and both unstable MSC2965 paths still pass through the IdP, including the pre-existing made-up `registration_endpoint`/`revocation_endpoint` (pattern M-2, oidc-public-endpoint-urls). Spec §3 gave the `auth_issuer` decision ("remove or switch to the Nebu issuer") to THIS story. It was not made. ADR-033 only postpones the *unstable* paths. Clients that use the older discovery skip the DCR admin-approval gate entirely, because they go to the IdP directly (legacy coexistence). | Decide and record in ADR-033. When `oauth_enabled` is true, `auth_issuer` (v1 + unstable) should return Nebu's issuer or `404 M_UNRECOGNIZED`, and the unstable `auth_metadata` should be served by `Nebu.OAuth.Http` (spec §3 lists it as an alias). Record "approval gate bypassable through legacy discovery until legacy shutdown" as an explicit accepted risk. |
| 3 | LOW | `server/priv/migrations/000040_oauth_clients_and_auth_metadata.up.sql:81,83,91-104` | **The database does not enforce "every registration starts pending" or "approved metadata is immutable".** The INSERT policy is `WITH CHECK (true)`, so the runtime role can insert `status='approved'` directly. The trigger fires only on `UPDATE OF status`, so an approved row's `metadata`/`redirect_uris`/`metadata_hash` can be rewritten without re-approval. Approval is per metadata hash, so this is the obvious escalation path for any future SQL-reachable bug. | INSERT policy `WITH CHECK (status = 'pending' AND approved_by IS NULL AND approved_at IS NULL AND rejected_by IS NULL AND rejected_at IS NULL)`. Extend the guard trigger (`BEFORE UPDATE`, no column list) to refuse changes to `client_id`, `metadata`, `metadata_hash`, `application_type` and `token_endpoint_auth_method`. Add a CHECK: `status='approved'` requires `approved_by`/`approved_at` NOT NULL, same for rejected. E2E fixtures that seed decided rows must insert pending and then UPDATE. |
| 4 | LOW | `server/lib/nebu/oauth/registration.ex:69,334-339`; `server/lib/nebu/admin/oauth_registrations_html.ex:37` | **The "host under `client_uri`" rule is weaker than it sounds.** The LDH check accepts single-label hosts (`https://com`, which then allows redirects to any `*.com`), public suffixes (`github.io`), and all-numeric/IPv4-literal hosts (`https://0.1` passes `host_under?` for `https://127.0.0.1`; `https://10.0.0.5`). With `?logos=1`, an IPv4-literal `logo_uri` widens the admin CSP to an intranet origin and makes the admin's browser send a GET to it (code-review I5 confirmed). | Require at least 2 labels and reject a host whose last label is all digits (IPv4 literal) in `ascii_dns_host?/1`. Reject IP literals in `logo_origin/1` as well. Optionally add a public-suffix check, or at least show a warning badge when the client host is a public suffix. |
| 5 | LOW | `server/lib/nebu/admin/templates/oauth_registrations/index.html.heex:50-96`; `oauth_registrations_html.ex:85-93` | **The approval page lacks the information needed to spot impersonation by native clients.** `application_type` is loaded but not shown. Loopback (`http://localhost`) and private-use-scheme redirect URIs are not tied to the `client_uri` host, so name, `client_uri` and logo are unverified claims for those clients (e.g. "Element" / `app.element.io` / `http://localhost`). The page does not say this. The confirm text puts the attacker-chosen name first, and that name can contain a fake "(app.element.io)". | Show `application_type` and a badge per redirect URI: "host-bound" (web / claimed https) or "NOT host-bound: client identity unverified" (loopback / private scheme). Put the verified host first in `confirm_text`, e.g. `Approve client at <host> (name "<name>")?`. Highlight redirect hosts that differ from the client host. |
| 6 | LOW | `server/lib/nebu/admin/oauth_registrations_controller.ex:184-192,263-270` | **An admin can make a decision that is never audited.** `reason` is only trimmed and sliced. A `%00` in the form decodes to NUL. `jsonb` refuses `\u0000`, so the audit insert fails AFTER the reject UPDATE has already been committed. The result: a rejected registration with no `audit_log` row, triggered on purpose from the admin's own input. More generally, decision and audit are not written in one transaction (code-review I6). | Refuse or strip `\p{Cc}\p{Cf}\p{Co}\p{Cs}` in `normalize_reason/1` (reuse the `client_name` regex). Run the decision UPDATE and the audit INSERT in one `Nebu.Repo.transaction/1` so a failed audit rolls the decision back. Both live in the same database, so this is possible. |
| 7 | LOW | `server/lib/nebu/oauth/client_store.ex:122-131`; migration `:39-40` | **Personal data is kept without a purpose.** `created_from_ip` and `user_agent` of the FIRST registrant are stored forever on approved/rejected rows. Because clients register on every flow, the first registrant of e.g. Element Web is usually an end user's browser. The values are never shown, never used, have no retention and are not covered by GDPR erasure (no user link). | Set both to NULL in the approve/reject UPDATEs, or do not store them at all. Otherwise, purge them after a short retention period. Document this in ADR-033. |

INFO (no action required by this gate):

- **I-1** `oauth_enabled` (and `oauth_issuer_url`) can only be set via SQL (verified: no admin toggle, no env path). While enabled, the metadata advertises `/oauth2/authorize|token|revoke`, which do not exist yet and answer 404. This fails closed: no Nebu token can be issued, so the "revocation endpoint that revokes nothing" problem has nothing to apply to. However, Element Web and other OAuth-preferring clients would lose login entirely. Recommendation: a code-level guard so the endpoints cannot be advertised before story 4, plus a release note.
- **I-2** `Cache-Control: public, max-age=259200` on metadata is required by the spec, but it means switching OAuth off (kill-switch) or changing the issuer stays invisible to clients/CDNs for up to 3 days. Document this in the operator runbook.
- **I-3** `RateLimit` ETS buckets are never evicted, and the per-IP key is written BEFORE the global check. On directly exposed deployments, rotating IPv6 sources grow the table without bound. The lookup/insert is also not atomic. The plug already had this problem; this is a new bucket family of the same kind.
- **I-4** The `CORSPlug` defaults (`origin "*"`, `credentials: true`) are pre-existing. Browsers refuse credentialed requests with `*`, `Nebu.OAuth.Http` sets ACAO `*` explicitly, and neither endpoint reads cookies. Not exploitable.
- **I-5** `Config.get/0` runs one uncached `server_config` query per unauthenticated `GET auth_metadata` and per non-POST `/oauth2/register`, with no rate limit. The query is tiny and indexed, so the amplification is minor.
- **I-6** FORCE RLS and the guard trigger protect against application bugs. They do not protect against a compromised owner role (`ALTER/DROP POLICY`, `DISABLE TRIGGER`, and `TRUNCATE`, which is not covered by RLS). This matches the existing `server_config` posture.
- **I-7** The pre-existing unstable MSC2965 issues (issuer-provenance M-1 and made-up endpoints M-2 from oidc-public-endpoint-urls) are still present and unchanged by this diff. See Finding 2.
- **I-8** If a CHECK constraint failed, the `Logger.error(... inspect(reason))` in `Http.store/2` would log Postgres' "Failing row contains (…)", which includes IP, user agent and metadata. This cannot currently happen: `application_type` and `status` are validated before the INSERT. Keep it that way, or log only `pg_code`.

### Verified clean (adversarially re-checked, not trusted from prior cycles)

- **SSRF:** none. The OAuth domain makes no outbound fetch; `client_uri`, `logo_uri`, `tos_uri`, `policy_uri` and `redirect_uris` are only stored and rendered.
- **Injection:** all SQL is parameterized (`$n`). The purge interval is `$1::int * INTERVAL '1 day'`, with TTL bounded to 1..3650.
- **Redirect-URI validation:**
  - userinfo and backslash are rejected.
  - Whitespace, control, format/bidi, separator, private-use and surrogate characters are rejected.
  - Fragments are rejected.
  - Trailing-dot hosts are rejected (empty label).
  - `example.com.evil.com` and `evilexample.com` are rejected by the suffix check.
  - IDN, punycode and Unicode look-alikes of `/`, `.` and `@` are rejected (LDH checked on the RAW host).
  - The loopback regex is anchored and port-less (`localhost.evil` and `localhost:1@` are refused).
  - A private-use scheme must be reverse-DNS of the client host and must have no authority (`//`).
  - The scheme is lower-cased by `URI.parse`, so `HTTPS:` is handled consistently.
- **JSON bomb:** 128 KiB parse cap for this exact path, then a depth limit of 8. Non-object, empty and wrong-content-type bodies get a 400 in OAuth shape. The `:body_too_large` flag is only set for `oauth2/register` paths, which all go to `Nebu.OAuth.Http`; that module checks the flag before using the body, so it does not fail open (pattern "shared plug error→flag").
- **Hash canonicalization:** sorted keys, Jason-escaped strings, set-like lists sorted, `#lang` keys dropped before validation. Squatting identical metadata gives no advantage: the redirect set is identical.
- **client_id:** 192-bit CSPRNG, server-generated, never client-supplied.
- **Response contents:** the 201 echoes only REGISTERED metadata; dedup does not reveal the approval status. All error descriptions are static strings.
- **auth_metadata:** the issuer comes only from `server_config` (not from Host or XFF, unlike the pre-existing well-known watch-flag). It must be https with no userinfo/query/fragment, otherwise the endpoint answers 404 without echoing the value. Every advertised URL derives from it, so all are https. No IdP field leaks through.
- **Migration 000040:**
  - ENABLE + FORCE RLS.
  - DELETE is allowed only when `status='pending'`.
  - The status trigger blocks decided→pending, so a row cannot be flipped back and then deleted. The trigger function is not SECURITY DEFINER and references no tables.
  - CHECK constraints exist for status and application_type.
  - `config_update_mutable` was diffed against 000020: a pure widening, and all prior keys and LIKE families are preserved. The `.down.sql` restores 000020 verbatim.
- **Purge worker:**
  - `DELETE … WHERE status='pending' AND client_id IN (… FOR UPDATE SKIP LOCKED)`; the status is re-checked after the lock, so it never deletes a decided row.
  - Bounded to 20×1000 rows per run.
  - Leader-only cron, own queue (limit 1).
  - Logs only the row count.
- **Admin page:**
  - Authorization: `require_admin` plug.
  - CSRF: `:browser` with `protect_from_forgery`; the CSRF bypass is only set in `config/test.exs`.
  - XSS: HEEx escapes every client string, links are https-only (`safe_link`) with `rel=noopener noreferrer`, and `data-confirm` is consumed only by `window.confirm` (text, app.js:35-37).
  - CSP header injection is impossible: `logo_origin/1` allows only `[A-Za-z0-9.-]` hosts plus an integer port, so no `;`, space or `*`.
  - The `?logos=1` widening applies to that response only; the default page has no `<img>` and the strict CSP.
  - The Location header is rebuilt from a parsed integer page and a literal `logos=1`, so there is no open redirect or header injection.
  - Decisions are race-safe (`WHERE status='pending'` plus returned-row count), and a replay writes no second audit row.
  - The JSON variant is GET-only and admin-gated.
- **Audit (AC7):** one row per successful decision, containing the actor, `client_id` and an optional reason, and no client metadata. A failed audit write is shown to the admin (Finding 6 covers the transactional gap).
- **Logs (LAW: tokens/credentials AND chat content):** INFO lines carry only `client_id`, `metadata_hash`, status and counts. DCR metadata is public. `code`, `code_verifier` and `device_code` were added to both the key and query-string redaction lists. Over-redaction (e.g. `qrcode=`) is harmless. No chat content is on these paths.
- **Test seams:** `:oauth_config_source`, `:oauth_repo` and `:rate_limit_clock_fn` are never set in `lib/` or `config/` outside tests. `NEBU_RATE_LIMIT_DISABLED` defaults to false in `docker-compose.yml`. No hard-coded secrets in the diff (the only literal is a test-only `DbgSecret-<n>`).

### Detail

**Finding #1 — Registration rate-limit topology causes a server-wide login DoS** [MEDIUM]
`Http.rate_limit/1` takes from `{"oauth_register", ip}` (50/h) and then `{"oauth_register", :global}` (500/h). The IP comes from `conn.remote_ip`. The moduledoc admits the shortcut ("behind a reverse proxy all clients share one per-IP bucket"), but on the shipping topology (nginx in front of `server:4000` in `deploy/tofu/examples/upcloud/cloud-init.tftpl` and in the Stackit ALB→nginx setup) this is not an edge case; it is how the system always runs.

The effective limit for the whole server is therefore 50 registrations per hour, and the throttle runs BEFORE dedup, so it also applies to clients that are already approved. Spec §4: clients register on **every** flow. Two consequences follow once stories 2-4 make OAuth usable:
- Legitimate load above 50 logins per hour fails with 429.
- A single attacker sending one request every 72 s keeps the shared bucket empty forever, which blocks every OAuth login.

On a directly exposed node, IPv6 rotation defeats the per-IP bucket, and the global bucket becomes the shared resource instead. Separately, 500 distinct pending rows per hour fill the 5000 cap in about 10 h. After that, every NEW client gets a 503 for up to the 30-day TTL, and recovery needs 5000 individual confirm-and-reject clicks or SQL.

Fix:
1. Resolve the client IP from a trusted-proxy allowlist (see the existing XFF pattern: gate it behind an explicit trusted-proxy setting).
2. Move validation and the hash lookup in front of the throttle. Charge the per-IP and global buckets only when a new row would be inserted, and give dedup hits their own generous bucket.
3. Add a per-`client_uri`-host pending cap, so one registrant cannot use up the global cap.
4. Add bulk reject to the admin page.

This is not exploitable today, because `oauth_enabled` is off and can only be set via SQL. It is an epic-end gate item.

**Finding #2 — Discovery split-brain and the decision spec §3 left to this story** [LOW]
See the table. The approval gate is the only access control the epic adds for third-party apps, and it is only meaningful if no discovery path leads around it. Coexistence with legacy is an ADR-level decision, so this is not rated higher. The gap is that the decision the spec gave to this story was neither made nor recorded.

**Finding #3 — DB invariants: pending on insert, immutable approved metadata** [LOW]
The guard trigger was added for the reverse direction (decided→pending). The forward direction (insert already approved) and metadata mutation after approval are the same class and should be enforced in the database in the same way.

**Findings #4-#7** — see the table. All are hardening items without a direct exploit path today.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 — advisory, address before epic end. Finding 1 is a **hard gate before `oauth_enabled` can be turned on / before story 2 merges**.
LOW: 6 — advisory
INFO: 8

**Verdict:** APPROVED (CLEAN at story level: no CRITICAL/HIGH). Carry Finding 1 (MEDIUM) and Findings 2-3 forward to the oauth-broker epic-end review as gate items.

---

## Re-review (cycle 4)

**Diff scope:** the staged diff after cycle 4 (`git diff --staged`). Focus: the fixes for F-1 (partial scope), F-2 to F-7, and new code: `Nebu.Web.Plugs.OAuthDiscovery`, the loose/strict bucket split with a dedup-first lookup in `Nebu.OAuth.Http`, the per-host pending cap (`client_host`), migration 000040 (INSERT `WITH CHECK`, column-less `BEFORE UPDATE` guard, `oauth_clients_decision_check`, down migration), the atomic decision + audit transaction, the NULLing of `created_from_ip`/`user_agent`, reason sanitization, the approval-page badges, and the host-rule changes.
**Date:** 2026-10-09
**Reviewer:** Kassandra (SEC Gate 1, re-review)

### Fix verification

| Finding | Status | Evidence |
|---|---|---|
| F-1 (MEDIUM, partial scope) | **Partially fixed, residual open (gate stays).** | Dedup-first is implemented: validate, then `find_by_hash`, then the strict 50/500 buckets only for new rows (`http.ex:159-164,247-259`). The per-host cap is in the INSERT (`client_store.ex:47-55`). Residual: see "F-1 residual" below. The trusted-proxy item and bulk reject are correctly recorded as gate items (`follow-ups.md`, ADR-033). |
| F-2 (LOW) | **Fixed, with an acceptable deviation.** | While OAuth is enabled, all three paths serve Nebu's issuer/document (`oauth_discovery.ex:35-36`, `http.ex:140-153`). A misconfigured issuer gives 404 and is never echoed. The deviation (legacy IdP passthrough while OAuth is DISABLED instead of 404) is acceptable: with OAuth off there is no Nebu authorization server and no approval gate, so nothing can be bypassed, and the passthrough is the pre-existing behaviour (I-7 M-1/M-2 unchanged). ADR-033 records the legacy-login bypass as an accepted risk. One fault-mode gap: N-4. |
| F-3 (LOW) | **Fixed for the forward direction and metadata immutability. One residual gap: N-3.** | The INSERT policy admits only pending rows with all `*_by`/`*_at` NULL (`up.sql:109-114`). The guard is `BEFORE UPDATE` with no column list and refuses changes to `client_id`, `metadata`, `metadata_hash`, `application_type`, `token_endpoint_auth_method` and `client_host` (`:131-153`). The legitimate pending→approved and pending→rejected transitions still pass: they change only status/`*_by`/`*_at`/ip/ua, and the CHECK is satisfied. The decision CHECK is exact (`:55-66`). The down migration drops the table (and with it the trigger and policies) and the function, and restores the 000020 policy. `ON CONFLICT DO NOTHING` works under the SELECT policy `true`. |
| F-4 (LOW) | **Bypassable: N-2.** | At least 2 labels and a non-numeric last label are now required (`registration.ex:349-354`, `oauth_registrations_html.ex:53-56`), but a hex last label still produces an IPv4 literal. |
| F-5 (LOW) | **Fixed.** | `application_type` is shown, there is a per-URI `host-bound` / `NOT host-bound` badge, the unverified-claims note is present, other-host redirects are highlighted, and `confirm_text` puts the host first. The badge cannot be spoofed in the dangerous direction: the only `https://`-prefixed URIs that pass registration are claimed-https URIs validated against the `client_uri` host. An upper-case `HTTPS://` redirect is mis-labelled "NOT host-bound", which errs on the safe side. Everything is HEEx-escaped. `data-binding` is an atom. No new XSS sink. |
| F-6 (LOW) | **Fixed.** | `normalize_reason/1` strips `\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Zl}\p{Zp}` (this covers NUL) and drops invalid UTF-8. `ClientStore.decide/3` runs UPDATE and audit in one `repo.transaction`. `AuditWriter.log`'s own `repo().transaction` is NESTED, so it joins the outer transaction on the same `Nebu.Repo`. Any raise from the inner `insert!` (Postgrex errors are not caught by AuditWriter's `RuntimeError`-only rescue) is caught by the controller's `write_audit` rescue and turned into `repo.rollback({:audit, _})`. Failure modes checked: an audit failure rolls back the decision; a commit failure loses both together; a race loser rolls back with `:not_pending` and writes no audit row. No deadlock: the transaction locks one `oauth_clients` row and then inserts into `audit_log`, whose only trigger is the BEFORE INSERT `event_time` forcing trigger, which takes no locks. No reverse lock order exists. Audit contents: actor, action, `client_id`, sanitized reason; no metadata. The error log/flash carries only an atom or a struct name. Doc drift (INFO): AuditWriter's moduledoc still says "never inside the caller's transaction". |
| F-7 (LOW) | **Fixed.** | Both decision UPDATEs set `created_from_ip`/`user_agent` to NULL (`client_store.ex:97-109`). Pending rows are purged by TTL. ADR-033 has a "Retention" section. |

### New findings (cycle 4)

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| N-1 | MEDIUM | `server/lib/nebu/oauth/client_store.ex:52-53`; `config.ex` (default `host_cap` 20) | **The per-host pending cap can be used against a legitimate client host.** `client_host` is an unverified, attacker-chosen string: no DNS lookup and no proof of ownership. An attacker therefore sends 20 unauthenticated registrations with distinct metadata (e.g. different `client_name` or redirect paths) under `client_uri=https://element.company.com`, using no more than the strict 50/h per-IP budget. From then on, every NEW registration for that host gets `503` for up to 30 days (TTL), or until an admin rejects all 20 rows one by one. The attacker refills them at will. That blocks the first OAuth login of the organisation's real Element deployment, and of every new client version whose metadata changed. In the other direction, the cap does NOT stop an attacker: rotating made-up hosts (`r1.com`, `r2.com`…) needs no domain at all. Net: the cap restricts legitimate clients and does not bound attackers. | Key the cap on `(client_host, created_from_ip)`: it only becomes meaningful once trusted-proxy IP resolution (follow-up #1) exists, so put it under the same gate. Alternatively, on a host-cap hit, evict the OLDEST pending row of that host instead of refusing the new one: a legitimate client re-registers on every flow, so it re-appears. Make bulk reject **by host** part of follow-up #2. Document the targeted-DoS property in ADR-033. Gate: before `oauth_enabled` (same as F-1). |
| N-2 | LOW | `server/lib/nebu/oauth/registration.ex:349-354`; `server/lib/nebu/admin/oauth_registrations_html.ex:53-56` | **The F-4 IPv4-literal check can be bypassed with hex notation.** Only an all-decimal last label is rejected. The WHATWG URL parser also treats a last label of the form `0x…` as a number. Verified with Node: `https://127.0.0.0x1` → `127.0.0.1`, `https://10.0.0.0x5` → `10.0.0.5`, `https://0x7f.0x1` → `127.0.0.1`. All of these pass `ascii_dns_host?/1`. The `https://0.1` suffix trick also survives as `client_uri=https://0.0x1` + `redirect_uri=https://127.0.0.0x1/cb`, and `host_under?` accepts it. The logo side is mostly self-limiting: the CSP host-source `0x7f.0x1` is string-matched against the normalised host `127.0.0.1` and does not match, so the image load is blocked. The redirect side is not affected by that. | Reject the host when its last label matches `~r/\A(0x[0-9a-f]*|[0-9]+)\z/i` (WHATWG "ends in a number"), in both functions. Add tests for `127.0.0.0x1`, `0x7f.0x1` and `0.0x1`. |
| N-3 | LOW | `server/priv/migrations/000040_oauth_clients_and_auth_metadata.up.sql:131-148` | **The database does not make a decision final.** The guard only blocks decided→pending. `approved→rejected` and **`rejected→approved`** (which would bypass the admin gate) pass the trigger. The decision CHECK is also satisfied as long as the UPDATE clears the other pair. Re-attributing a decision (overwriting `approved_by`/`approved_at`) passes too. ADR-033 claims "a decision is only ever an UPDATE of a pending row". That is true of the application but not enforced by the database: it is the same SQL-reachable-bug class that F-3 set out to close. | In the trigger: `IF OLD.status <> 'pending' AND (NEW.status, NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at) IS DISTINCT FROM (OLD.status, OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at) THEN RAISE`. Still allow `last_used_at` (story 2) and the NULLing of ip/ua. Add a migration test for rejected→approved. |
| N-4 | LOW | `server/lib/nebu/web/plugs/oauth_discovery.ex:35`; `server/lib/nebu/oauth/config.ex:132-133,164-166` | **A transient config read error re-opens the F-2 split-brain.** `Config.get/0` maps "server_config unreadable" to `enabled: false`. That is fail-closed for `Nebu.OAuth.Http`, but `OAuthDiscovery` reacts to it by switching to the **legacy IdP passthrough**. While OAuth is enabled, any DB timeout (e.g. pool exhaustion, which unauthenticated GETs on these paths can help cause because each one does an uncached DB read, see I-5) makes `auth_issuer` and the unstable `auth_metadata` advertise the IdP issuer. Clients are steered onto the legacy path. That path is an accepted risk, so the impact is low, but the plug's own invariant ("must never advertise both at once") does not hold. | Make the config tri-state (`enabled` / `disabled` / `unknown`). In `OAuthDiscovery`, take the legacy branch only on a positively read `disabled`. On `unknown`, answer `503` (or `404 M_UNRECOGNIZED`, `no-store`) without passthrough. |

**F-1 residual (carried, MEDIUM, gate unchanged).** The loose buckets are charged by EVERY request before anything else (`http.ex:160,220-230`), including garbage, invalid and disabled-path requests, and that includes the GLOBAL 5000/h loose bucket. This is the only budget a dedup hit has (i.e. every login). On a directly exposed node, about 9 rotating IPs × 600/h of junk empty the global loose bucket and block every OAuth login. Behind nginx (the shipping topology), one IP sending one junk POST every 6 s does the same through the shared per-IP bucket. That is 12× better than before cycle 4, but structurally the same self-DoS (pattern "per-flow-mandatory unauth endpoint throttle"). Fix together with follow-up #1:
- charge unparseable/invalid requests to their OWN bucket;
- dedup hits pay a per-IP loose bucket only, with no global bucket (a dedup hit is one indexed SELECT).

### INFO (cycle 4)

- **I-9** Dedup-first lookup oracle: once a caller has used up its own strict per-IP bucket, known metadata answers `201` and unknown metadata `429`, so the caller learns whether metadata is already registered without creating a row. This is negligible: a dedup hit already returns the `client_id` (public client, no secret, `token_endpoint_auth_method` is fixed to `none`), the approval status is never revealed, and the `find_by_hash` timing is a single indexed lookup.
- **I-10** `confirm_text/3` quotes the name with plain `"`. A name such as `Element") at app.element.io (name "x` can fake a second "at <host>" clause. The real host still comes first. Escape `"` (e.g. use `inspect/1`) or strip quotes from the displayed name.
- **I-11** The green "host-bound" badge certifies only that the redirect URI shares a host with the `client_uri` host, which is itself an attacker-chosen claim. The note at the top of the page explains this. Consider wording such as "bound to <host>" so the badge does not read as "verified".
- **I-12** I-5 now covers three more unauthenticated GET paths: every `auth_issuer` / unstable `auth_metadata` request reads `server_config` uncached, including while OAuth is disabled (previously the passthrough needed no DB read). Cache `Config.get/0` for a few seconds (per node, e.g. `:persistent_term` with a TTL). This also reduces N-4.
- **I-13** E2E fixture rows are inserted with `client_host` NULL and so do not count against the per-host cap. This is test-only; production rows always get the host from `Registration.validate/1`.

### Summary (cycle 4)

New findings: CRITICAL 0, HIGH 0, MEDIUM 1 (N-1), LOW 3 (N-2, N-3, N-4), INFO 5.
Carried: F-1 residual MEDIUM (gate). F-2, F-3, F-5, F-6 and F-7 are closed. F-4 has a bypass (N-2). N-3 completes F-3.

**Verdict:** APPROVED. CLEAN at story level (no CRITICAL/HIGH). N-1 and the F-1 residual join the **hard gate before `oauth_enabled` / story 2 merge**. N-2, N-3 and N-4 are cheap fixes and should be made in this story or tracked in `docs/stories/oauth-broker/follow-ups.md`.
