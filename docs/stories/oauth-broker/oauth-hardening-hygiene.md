---
story_id: oauth-hardening-hygiene
title: "OAuth hardening and hygiene: per-node config cache + discovery rate limits, __Host- binding cookies, supervised signing-key cache + rotation tooling, seam guard and admin wording (non-gating follow-ups)"
type: feature
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-13
branch: feature/migrate-to-oauth2
---

## Summary

Phase-2 story P8 of epic `oauth-broker`. It bundles the NON-GATING follow-ups of
`docs/stories/oauth-broker/follow-ups.md` and of the epic SEC Gate 2 report
(`security-reports/epic-oauth-broker-security-review-2026-10-12.md`, E-5, E-6, INFO) that are worth doing
before activation, each as a small, independently testable AC group:

| Group | Follow-up ids | ACs |
|---|---|---|
| A. Config cache + discovery rate limits | am / E-6 / I-12 (I-3 sweeper exists since P1) | AC1-AC3 |
| B. Hygiene | an (seam guard; `inspect(other)` part already done by P4), I-10, I-11, I-13, stale 07-deployment lines | AC4-AC7 |
| C. `__Host-` binding cookies | j / ah | AC8 |
| D. Signing keys | p, story-3 (b) | AC9-AC12 |
| Docs, logging law | — | AC13-AC14 |

Deferred (table "Deferred"): (t) IdP-side refresh-token revocation and (al / E-5) SecretBox v2 (design
in HY17). `oauth_enabled` stays OFF; nothing enables it. Changes visible while OAuth is off: the config
cache (also serves `/versions`, `GET /login`), the GET /login rate limit, the admin wording. Already
closed elsewhere (do NOT redo): consent cookie `__Host-nebu_oauth_consent` (P3), account session cookie
`__Host-nebu_account` (story 6), `ClientStore` `inspect(other)` (P4), RateLimit sweeper (P1).
Deferred by orchestrator decision: (o) rotated-row cap (shortens reuse detection). Migration: **000047**
(the device-lists story is deferred and does not use it; highest committed is 000046; re-check `ls
server/priv/migrations` at ATDD time and take the next free number). ATDD/dev starts only AFTER
`oauth-room-summary-unrecognized` (in dev; edits `Router`, `HttpPublic`, `OAuth.Http`) is committed.

## Story

As an **operator preparing to enable OAuth**, I want discovery without per-request DB reads,
origin-locked binding cookies and a tested signing-key rotation tool, so that
activation adds no avoidable load, cookie-tossing or hand-written-SQL risk.

## Decisions

Prefix `HY` (no collision with D/T/R/C/A/V/TP/AH/FR/CR/SO/LL/RU in ADR-033). ADR-033 gets a section
"Hardening and hygiene (story oauth-hardening-hygiene)" with HY1-HY17 (AC13).

- **HY1 (per-node TTL cache of the switch state).** `Nebu.OAuth.Config.get/1` (and therefore
  `live_state/1`, `enabled?/0`, `Nebu.OAuth.oauth_aware?/1`, `Nebu.OAuth.config/0`) serves the
  normalized `%{enabled, issuer_url, state}` from a per-node ETS entry `{:config, map, loaded_at_ms}`
  while `now - loaded_at < ttl`. TTL = `:nebu_http, :oauth_config_cache_ms`, set from
  `NEBU_OAUTH_CONFIG_CACHE_MS` in `config/runtime.exs` (integer `0..5000`; absent / junk / out of range =>
  **2000**; `0` disables the cache). `config/test.exs` sets `0` (ExUnit stays read-through; the cache
  tests set it explicitly, `async: false`). ONLY a successful read (`{:ok, rows}` -> `:enabled` /
  `:disabled`) is cached; `:unknown` (read error, timeout, exception) and `:no_repo` are NEVER cached
  (every request during an outage re-reads and fails closed exactly as today). The `:oauth_config_source`
  seam bypasses the cache entirely. `pending_limits/0` and `token_settings/0` stay uncached (rate
  limited / authenticated callers, values must apply on the next registration / refresh).
- **HY2 (kill-switch semantics, ADR-020).** Node-local state is accepted here as BOUNDED staleness, the
  same class as `Nebu.Web.OidcConfig` (ETS) and the 60 s JWT denylist cache: an operator write of
  `oauth_enabled` / `oauth_issuer_url` takes effect on every node within the TTL (default 2 s, max 5 s),
  never later; no correctness property (single-use codes, rotation, revocation) depends on the cached
  value (those stay atomic SQL). "Next request on every node" in docs becomes "within
  `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node". `/versions` keeps `bounded: true`: a hit
  answers without DB; a miss does the bounded 500 ms read, a success fills the cache, a failure is
  `:unknown` => v1.1-v1.11 (fail closed, never 5xx). The bounded read MAY fill the cache with its
  result; an unbounded read MAY serve a `/versions` request (same value).
- **HY3 (discovery rate limits: only where the spec allows a 429).** Matrix v1.18 marks
  `GET /_matrix/client/v3/login` "Rate-limited: Yes" and `auth_metadata` "Rate-limited: No"
  (oracle spec copy v1.18). Therefore per-source buckets (`ClientIP.bucket/1`) on `GET /_matrix/client/v3/login` (`{"login_flows", bucket}`, 300/min,
  burst 300; Matrix `429 M_LIMIT_EXCEEDED` + `retry_after_ms` + `Retry-After`) and on the live branch of
  `GET /.well-known/openid-configuration` (`{"oauth_openid_configuration", bucket}`, 600/min, burst 600;
  same 429 shape as JWKS: `too_many_requests` + CORS + `Retry-After`; generous: matrix-js-sdk fetches it before every refresh). NO 429 on `auth_metadata`, `auth_issuer`, the unstable
  aliases or `/versions` (spec / load-balancer health check): those rely on the HY1 cache (zero DB reads
  on a hit). Own `RateLimit.take/3` keys, never the plug's bare-IP key (shared by `POST /login` and `/refresh`).
  The disabled openid-configuration branch takes no token (unchanged 404).
- **HY4 (one supervised owner for the OAuth ETS caches).** New `Nebu.OAuth.CacheOwner` (GenServer,
  started in `Nebu.Application` before Bandit, after the Repo) creates both named public tables in
  `init/1`: `:nebu_oauth_config_cache` (`read_concurrency: true`) and `:nebu_oauth_signing_key_cache`.
  Request processes never create tables (today the first request process owns the signing-key table,
  which dies with it). Table absent => miss, read-through, no crash; owner restart => empty tables.
- **HY5 (compile-guarded config seams).** The `:oauth_config_source` and `:oauth_config_repo` reads in
  `Nebu.OAuth.Config` go through a private `seam/2` defined under `if Mix.env() == :test` (idiom of
  `oauth_session.ex` ~l.759); in other envs it returns the default. (A stray prod `Application.put_env` could switch OAuth on, epic I-6.)
- **HY6 (I-10 confirm text).** `confirm_text/3` renders the name with `Jason.encode!/1` (escaped `"`,
  `\`, control characters as `\uXXXX`) instead of plain `"` wrapping; truncated to 80 graphemes before
  encoding (`…` appended). The verified host still comes first.
- **HY7 (I-11 wording).** Badge text `host-bound` -> `host matches client_uri`; `NOT host-bound: client
  identity unverified` -> `NOT tied to the client_uri host: client identity unverified`; the two
  explanatory sentences (index l.10, approve_confirm l.22) say "matches the client URI host" instead of
  "host-bound". `data-role` attributes and the `redirect_binding/1` atoms are unchanged (tests and e2e
  key on them).
- **HY8 (I-13).** `Nebu.Matrix.idp_complete_login/4` also catches `:exit` (`catch :exit, _ ->` WARNING
  "unexpected exit", `{:error, :idp_unavailable}`); only the exception module / the word `exit` is logged.
- **HY9 (`__Host-` binding cookies, j / ah).** On an https request (`Nebu.Web.RequestScheme.https?/1`)
  the per-flow binding cookies are `__Host-nebu_oa_<16 hex>` (authorize) and `__Host-nebu_acct_<16 hex>`
  (account login) with `Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600`; on plain http (dev/test)
  today's names and attributes (`Path=` the callback path, no `Secure`). The callback reads ONLY the name
  of its own scheme (no fallback to the legacy name: a fallback would re-open sibling-subdomain cookie
  tossing). Clearing uses the same name/path/secure. Same rule as `Consent.cookie_name/1`. A scheme mismatch between
  authorize and callback (inconsistent `X-Forwarded-Proto`, a flow in flight across the deploy) =>
  `400 invalid_state` (fail closed). `Path=/` sends the small cookie to the whole host for <= 10 min: accepted.
- **HY10 (DEFERRED: rotated-row cap, o).** Deleting consumed rows beyond the newest N per device
  bounds row growth but shortens the T11 reuse-detection window (an old stolen refresh token would answer
  `invalid_grant` instead of revoking the session): security-negative, so not done here (Deferred, bs).
- **HY11 (pre-published next key, migration 000047).** `oauth_signing_keys.status` gains `next`:
  CHECK `('active','next','retired')`; retired check becomes `(status IN ('active','next') AND
  retired_at IS NULL) OR (status = 'retired' AND retired_at IS NOT NULL)`; partial UNIQUE index
  `oauth_signing_keys_one_next` (`WHERE status = 'next'`); INSERT policy admits `status IN
  ('active','next') AND retired_at IS NULL AND not_after IS NULL`; guard trigger: `retired -> *`
  forbidden, `active -> next` forbidden, `next -> active` only when `OLD.created_at <= now() - interval
  '900 seconds'` (JWKS max-age 600 s + id_token lifetime 300 s), `next -> retired` needs `retired_at`.
  `published_keys/0` lists active, then next, then retired with `not_after > now()`. The lazy generator
  (`ensure_active_key/0`) is unchanged (a `next` row never conflicts with it).
- **HY12 (`Nebu.Release.rotate_oauth_signing_key/0`, two calls).** Call 1 (no `next` row): generate an
  ES256 key, insert it as `next`; returns `{:ok, {:published, kid, activate_after_iso8601}}`. Call 2
  (a `next` row older than 900 s that LOADS: decrypt + thumbprint + public-part check, as
  `load_row/3`): in ONE transaction retire the active key (`retired_at = now()`, `not_after = now() +
  900 s`) and promote `next` -> `active`; returns `{:ok, {:activated, new_kid, retired_kid}}`. Too early:
  `{:error, {:too_early, seconds_left}}`, no change. `next` row that does not load:
  `{:error, :next_key_unavailable}` (use HY13). Re-runnable; every call takes a transaction-scoped advisory lock first (`pg_advisory_xact_lock`), snapshots the `next` row before it and compares after it: a call whose picture changed meanwhile (another operator published, promoted or discarded) returns `{:error, :conflict}` and changes nothing; the unique indexes and the trigger stay the last line of defence. Each successful call
  writes one audit row (`oauth_signing_key_published` / `oauth_signing_key_rotated`, actor
  `operator:rpc`, target type `oauth_signing_key`, metadata = kids only). Run via `bin/nebu rpc`.
- **HY13 (emergency replacement of an undecryptable active key).**
  `Nebu.Release.replace_oauth_signing_key(:emergency)`: in ONE transaction retire the active key
  (`not_after = now() + 900 s`: its PUBLIC key still verifies id_tokens it signed) and any `next` row,
  and insert a freshly generated `active` key (never promotes a `next`, which may be undecryptable under
  the same secret change). Audit `oauth_signing_key_replaced`. Consequence (runbook): clients holding a
  cached JWKS (≤ 600 s) cannot verify new id_tokens until they refetch; no session is revoked. Any other
  argument => `{:error, :confirmation_required}` (no accidental call).
- **HY14 (no key material anywhere).** Rotation functions return and log kids and atoms only; never the
  JWK, the ciphertext or an exception struct with parameters (existing `query/2` rule).
- **HY15 (operator note, ah).** A TLS-terminating proxy that does not set `X-Forwarded-Proto: https`
  makes Nebu issue the non-`Secure`, non-`__Host-` cookies (consent, account, both binding cookies):
  07-deployment note; gating the header stays (ap2).
- **HY16 (e2e under the cache).** The e2e fixtures that write `oauth_enabled` / `oauth_issuer_url`
  wait until the running server reflects the write (poll `GET /_matrix/client/v1/auth_metadata`:
  200 when enabled with a valid issuer, 404 otherwise; 100 ms interval, 5 s timeout, then fail loudly).
  No compose change; the stack keeps the production default (2 s), so e2e exercises the cache.
- **HY17 (SecretBox v2 design, DEFERRED, al / E-5).** Blob `"v2:" <> key_id <> ":" <> hex(nonce ‖ ct ‖
  tag)`, `key_id` = 8 hex of SHA-256("nebu-kid" ‖ secret); per-purpose key = HKDF-SHA256(secret, salt
  "nebu-secretbox-v2", info = purpose: `idp_refresh_token`, `pkce_verifier`, `signing_key`,
  `admin_client_secret`, `scim_token`, `storage_secret`); AAD = purpose ‖ stable row identity (`user_id ‖
  device_id` for IdP RTs, `kid` for signing keys; never the token hash, the RT ciphertext is copied across
  rotated rows). Decrypt: `v2:` -> v2 (unknown key_id -> `NEBU_INTERNAL_SECRET_PREVIOUS[_FILE]`), else v1.
  Two releases: N reads v1+v2 and writes v1, N+1 writes v2 (rollback-safe); lazy re-encryption plus
  `Nebu.Release.reencrypt_secrets/0`; signing keys re-keyed via HY12. Call sites: `BootstrapLive` (own
  key derivation copy), `Media.StorageConfig`, Matrix session stores, OAuth stores.

## Acceptance Criteria

### AC1 — Config cache (HY1, HY4)
1. With TTL 2000 and the cache table present, two `Config.get/0` calls within the TTL issue ONE
   `server_config` query (count via a counting `:oauth_config_repo` fake or telemetry); after the TTL
   (injected clock seam `:oauth_config_cache_clock_fn`, test-only, compile-guarded) the next call reads again.
2. A write of `oauth_enabled` is visible after the TTL, not before (test with the clock seam).
3. `:unknown` is never cached: repo error -> `:unknown`; next call with a healthy repo -> fresh read.
   `:no_repo` is never cached.
4. TTL `0` => every call reads (today's behaviour). `NEBU_OAUTH_CONFIG_CACHE_MS` parsing: `"0"`,
   `"5000"`, `"abc"`, `"-1"`, `"5001"`, unset -> `0`, `5000`, `2000`, `2000`, `2000`, `2000` (pure function,
   e.g. `Nebu.OAuth.Config.parse_cache_ms/1`).
5. With the `:oauth_config_source` seam installed the cache is neither read nor written.
6. Table absent (CacheOwner not running) => read-through, no exception, no table created by the caller.

### AC2 — `/versions`, discovery and the kill switch under the cache (HY2)
1. `/versions` with a warm cache (`enabled`) answers v1.1-v1.15 with ZERO DB queries; with a broken
   repo and a cold cache it answers v1.1-v1.11 within the bounded budget (existing V-tests stay green).
2. `auth_metadata`, `auth_issuer`, the unstable aliases (`Nebu.Web.Plugs.OAuthDiscovery`), openid-
   configuration, `GET /login` flags and the token/JWKS/authorize/account kill switch all observe the
   SAME cached state within one TTL window (one parametrised test over the paths: flip via DB, assert old
   answer before / new answer after the TTL).
3. An enabled -> `:unknown` transition while a cached `enabled` value is younger than the TTL serves the
   cached value (documented bounded staleness); once expired, `:unknown` answers (503 on the
   OAuthDiscovery paths, 503 `{}` on token/JWKS/openid-configuration, v1.1-v1.11 on `/versions`).

### AC3 — Discovery rate limits (HY3)
1. `GET /_matrix/client/v3/login`: burst exhaustion (frozen `:rate_limit_clock_fn`) => `429`,
   `{"errcode":"M_LIMIT_EXCEEDED","error":...,"retry_after_ms":N}`, `Retry-After`; another source
   (`ClientIP` bucket) is unaffected; the bucket is NOT shared with `POST /login` (draining GET leaves a
   POST answered normally and vice versa).
2. Live `GET /.well-known/openid-configuration`: exhaustion => `429` `too_many_requests` with CORS and
   `Retry-After`; disabled => unchanged 404 without consuming a token.
3. `auth_metadata`, `auth_issuer`, unstable aliases and `/versions` never answer 429 (1 000 requests
   from one source with the limiter enabled).
4. With `NEBU_RATE_LIMIT_DISABLED=true` none of them limits.

### AC4 — Seam guard (HY5)
1. Static test: in `server/lib`, `:oauth_config_source` and `:oauth_config_repo` appear only inside an
   `if Mix.env() == :test do` block of `config.ex` (source scan, same style as the existing
   `*_static_test.exs`).
2. All existing tests using the seam stay green.

### AC5 — Admin confirm text (HY6)
1. Name `x" at evil.example (name "y` renders `Approve client at <host> (name "x\" at evil.example (name \"y")?`
   (escaped); a name with `\n` renders `\n` escaped; an 81-grapheme name is cut to 80 + `…`; no-host
   and unnamed variants keep today's structure.

### AC6 — Badge wording (HY7)
1. Pending list and approve-confirm page show `host matches client_uri` /
   `NOT tied to the client_uri host: client identity unverified`; the string `host-bound` no longer
   appears in any rendered admin page; `data-role="redirect-host-bound"` / `redirect-not-host-bound`
   unchanged. Update text assertions in `oauth_admin_test.exs` / `oauth_admin_clients_test.exs` if any.

### AC7 — `idp_complete_login` rescue / exit (HY8, I-13)
1. OAuth authorize callback with `:matrix_sso_token_override` = `fn -> raise "boom" end` => redirect
   to the client with `error=temporarily_unavailable` (consent flow: the documented error page / redirect
   of FR, whichever the callback produces today for `:idp_unavailable`); log has
   `unexpected RuntimeError` and not `boom`.
2. Same with `fn -> exit(:boom) end` => same outcome, no crash, log line without `:boom`.
3. Account login callback (`Nebu.OAuth.Account`) with the raising seam => its `:idp_unavailable` page.

### AC8 — `__Host-` binding cookies (HY9, HY15)
1. https (`X-Forwarded-Proto: https`) authorize: `set-cookie` is `__Host-nebu_oa_<16 hex>=…; path=/;
   max-age=600; secure; HttpOnly; SameSite=Lax` and carries no `Domain`.
2. The callback accepts only that name on https; a request carrying only `nebu_oa_<16 hex>` (legacy name)
   answers `400 invalid_state`; the cookie is cleared (`max-age=0`, `path=/`, `secure`) on every outcome
   that cleared it before.
3. Plain http: today's name and attributes byte for byte (existing tests unchanged).
4. 1-3 analogously for the account login binding cookie (`__Host-nebu_acct_`).
5. Scheme mismatch (authorize https, callback http) => `400 invalid_state`.

### AC9 — Supervised cache owner (HY4)
1. `Nebu.OAuth.CacheOwner` is a child of `Nebu.Supervisor`; both tables exist after boot and are owned
   by its pid; killing a request process that loaded a key leaves the signing-key cache intact.
2. `SigningKeyStore` no longer calls `:ets.new/2` (static check); with the owner absent, signing still
   works uncached.
3. Update any children-count assertion of the application tests deliberately (comment
   `# story oauth-hardening-hygiene`).

### AC10 — Migration 000047 (HY11)
1. `000047_oauth_signing_key_next.up.sql` / `.down.sql`, RLS/grants pattern of 000042/000046 (owner runs
   it; no new grants needed; FORCE RLS stays). The up migration is idempotent (`DROP ... IF EXISTS` /
   `CREATE OR REPLACE`).
2. Migration test (`server/test/nebu/migration/000047_oauth_signing_key_next_test.exs`): as `nebu_app`
   insert `next` OK; a second `next` fails (unique); insert `retired` fails (policy); `next -> active`
   younger than 900 s fails, older (row inserted with `created_at = now() - interval '901 seconds'`)
   succeeds when the old active is retired in the same transaction; `active -> next`, `retired -> next`
   fail; `next -> retired` without `retired_at` fails.
3. Down: deletes `next` rows, restores the 000042 CHECKs, policy, trigger function body and drops the
   index; up -> down -> up round trip green.

### AC11 — Rotation tool (HY12, HY14)
1. Call 1 returns `{:ok, {:published, kid, _}}`; JWKS lists active then next (both `use: sig`,
   `alg: ES256`); id_tokens are still signed with the active kid.
2. Call 2 before 900 s => `{:error, {:too_early, s}}`, no change; after (backdated row) =>
   `{:ok, {:activated, new, old}}`; the token endpoint now signs with `new`; JWKS lists new, then old
   (until `not_after`); old `not_after` within `now() + 900 s ± 5 s`.
3. A `next` row whose ciphertext does not load => `{:error, :next_key_unavailable}`, no change.
4. Two concurrent call-2 invocations: exactly one `:activated`, the other EXACTLY `{:error, :conflict}` (likewise two concurrent call-1: one `:published`, one `:conflict`); forced deterministically by holding the advisory lock.
5. Audit rows written as specified; `capture_log` contains no `"d":` / private JWK member, no ciphertext.

### AC12 — Emergency replacement (HY13)
1. Active key whose ciphertext was written under a different secret (`:admin_secret_at_rest` switched)
   => `ensure_active_key/0` is `{:error, :key_unavailable}` (unchanged); `replace_oauth_signing_key(:emergency)`
   => `{:ok, {:replaced, new_kid, old_kid}}`; the token endpoint signs again; the old public key stays in
   JWKS until `not_after`; an existing `next` row is retired.
2. `replace_oauth_signing_key(:yes)` / no argument => `{:error, :confirmation_required}`.

### AC13 — Documentation
Exactly the edits listed in Dev Notes "Doc edits" (ADR-033 HY section, 07-deployment, follow-ups,
`server_config`/env table, runbooks). `adr_033_test.exs` gains assertions that the HY section exists and
names `NEBU_OAUTH_CONFIG_CACHE_MS`, `rotate_oauth_signing_key`, `replace_oauth_signing_key`.

### AC14 — Logging law
No new log line contains a token, refresh token, binding cookie value, key material, ciphertext or the
client-supplied name in the confirm text path; cache and rate-limit paths log nothing per request (only
the existing throttled bounded-read warning).

## Acceptance Tests

New (under `server/test/nebu/oauth/`): `oauth_config_cache_test.exs` (`async: false`; AC1, AC2, AC4),
`oauth_discovery_rate_limit_test.exs` (`async: false`, `reset_rate_limits/0`; AC3), `oauth_hygiene_test.exs`
(AC5-AC7, AC14), `oauth_binding_cookie_test.exs` (AC8),
`oauth_signing_key_rotation_test.exs` (`@tag :integration`; AC9-AC12), plus
`server/test/nebu/migration/000047_oauth_signing_key_next_test.exs`. Changed: `adr_033_test.exs`, the
application children test, `e2e/fixtures/db.ts` (HY16; `tsc --noEmit` + `bddgen --tags` of the OAuth
features). Regression: all `server/test/nebu/oauth/*`, `rate_limit_test.exs`, `client_ip_*`,
`request_logger_test.exs`. No Gherkin feature (ui: false).

## Must be test-covered

Every numbered AC item above (AC1.1-AC14); in particular the negative cases: `:unknown` never cached, no
429 on spec-unlimited paths, legacy cookie name refused on https, the 900 s
promotion rule enforced by the database, no key material in logs.

## Dev Notes

**Sequencing:** ATDD/dev of this story starts only after `oauth-room-summary-unrecognized` is committed
(it edits `Nebu.Web.Router`, `Nebu.Matrix.HttpPublic`, `Nebu.OAuth.Http`); rebase on it first.

### Current state (read before coding; line numbers approximate)

- `server/lib/nebu/oauth/config.ex`: `get/1` -> `load_from_db/1` -> `load_raw/1` (bounded 500 ms variant,
  throttled warning); seam reads l.87/145/194; rewrite the "uncached" moduledoc paragraph (HY1/HY2).
  Callers: `Nebu.OAuth.config/0` / `oauth_aware?/1` (`oauth.ex`), `Nebu.OAuth.Http` (token l.187, revoke
  l.206, JWKS l.218, openid-configuration l.250, auth_metadata l.303, auth_issuer l.324),
  `Authorize.live_issuer/0`, `Nebu.Web.Plugs.OAuthDiscovery`, `Nebu.OAuth.Account`,
  `Nebu.Matrix.HttpPublic` (`login_flows/1` l.261, `versions` l.306 with `bounded: true`).
- `server/lib/nebu/web/plugs/rate_limit.ex` `take/3`; the plug's `bucket_key/2` ignores `tier` for `key: :ip`.
- `server/lib/nebu/oauth/signing_key_store.ex`: `ensure_table/0` (HY4), `@sql_published` (HY11), `load_row/3`
  (reuse for HY12 call-2 validation).
- `server/priv/migrations/000042_oauth_sessions_and_signing_keys.up.sql` l.59-124 (extend in 000047, never edit 000042).
- Cookies: `authorize.ex` (`@cookie_prefix` l.64, set l.255, read l.334, clear l.530); `account.ex`
  (`@binding_prefix` l.83, set l.496, read l.572, clear l.687); pattern: `consent.ex` l.69-376.
- Admin: `admin/oauth_registrations_html.ex` `confirm_text/3` l.109; templates
  `admin/templates/oauth_registrations/{index,approve_confirm}.html.heex` (l.10, 116-117; l.22, 57-58).
- `server/lib/nebu/matrix.ex` `idp_complete_login/4` l.173; seam `:matrix_sso_token_override`
  (`matrix/sso_login.ex` l.788; a raising 0-arity fun propagates to the facade rescue).
- `server/lib/nebu/release.ex` l.78-140 (`@operator`, `write_audit/4` with target type hard-coded
  `"oauth_client"`: add a parameter, existing output identical); `application.ex` children l.168.
- `server/config/runtime.exs` / `test.exs`: the HY1 env parsing must not override the test value.

### Files to create

`server/lib/nebu/oauth/cache_owner.ex`; `server/priv/migrations/000047_oauth_signing_key_next.{up,down}.sql`;
the test files listed above.

### Files to modify

The files of "Current state", `config/runtime.exs`, `config/test.exs`, `e2e/fixtures/db.ts` (HY16), docs.

### Traps

1. Do not cache inside `load_raw/1`: `pending_limits/0` and `token_settings/0` share it (HY1).
2. `Config.get/1` must still never raise: wrap ETS access (`ArgumentError` -> miss).
3. Cache tests and every test that writes `server_config` and expects the next request to see it need
   TTL 0; `config/test.exs` gives that, but a test that sets a TTL must restore it in `on_exit`.
4. GET `/login` lands in `HttpPublic` `get "/"` with `String.ends_with?(conn.request_path, "/login")`
   (the room-summary story is restructuring this root table: rebase first, keep its 405 / M_UNRECOGNIZED
   behaviour).
5. The 000047 guard must keep every 000042 rule (immutable key material, `not_after` only raised).
6. FORCE RLS binds the table owner too and there is no DELETE policy: the down migration's
   `DELETE ... WHERE status = 'next'` needs `ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` around it (restore
   FORCE afterwards) unless the migrator is a superuser; test it as the CI migrator role.
7. `bin/nebu rpc` prints nothing: runbook commands wrap the call in `IO.inspect/1` (as the revoke runbook).
8. `__Host-` requires `Secure` AND `Path=/` AND no `Domain`; Plug omits `Domain` unless set.
9. The audit writer is `Application.get_env(:compliance, :audit_writer, ...)`; tests use a fake.

### Doc edits (exact)

**ADR-033**: new section "Hardening and hygiene (story oauth-hardening-hygiene)" after "Client revocation
and same-origin hardening": HY1-HY17 condensed, HY2 as an explicit ADR-020 bounded-staleness note, HY10
as deferred, the rotation procedure, the Manual verification table. Wherever ADR-033 says "per
request (no cache)" / "per call (no cache)", append "(cached per node for at most
`NEBU_OAUTH_CONFIG_CACHE_MS`, HY1)". Story-3 section: one line "Rotation tooling: HY12/HY13".

**07-deployment.md**:
- l.102 heading: append `, oauth-hardening-hygiene`.
- l.110 `oauth_enabled` row: replace the bold "GATE: ... must be implemented ..." sentence with
  "**Trusted-proxy client-IP resolution is implemented (`NEBU_TRUSTED_PROXY_CIDRS`); the operator verifies
  it before activation (gate item 1).** A change takes effect on every node within
  `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s)." Add an env row `NEBU_OAUTH_CONFIG_CACHE_MS` (0..5000, default 2000, 0 = off).
- l.146 `oauth_signing_keys`: status `active`|`next`|`retired`, index `oauth_signing_keys_one_next`, 900 s
  promotion rule, migration 000047.
- l.173-174: binding cookies `__Host-nebu_acct_<16 hex>` / `__Host-nebu_oa_<16 hex>` (`Path=/; Secure`) on
  https; the `X-Forwarded-Proto` note covers all four cookies (HY15).
- l.191 and l.324: "per request on every node, no cache" / "on the next request on every node" -> "within
  `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node"; "Kill switch, caches and rollback" also
  names the GET /login and openid-configuration rate limits.
- l.218 non-gating list: drop (am), (an), (j)/(ah), (p), story-3 (b); mark (al), (t), (o) "deferred (P8)".
- New subsection "Rotating the id_token signing key" after "Revoking a client":
  `bin/nebu rpc 'IO.inspect(Nebu.Release.rotate_oauth_signing_key())'`, wait >= 15 min, run again; the
  emergency command `replace_oauth_signing_key(:emergency)` and its <= 10 min JWKS-cache gap; "rotating
  `NEBU_INTERNAL_SECRET` requires HY13 afterwards and logs out `per_refresh` OAuth sessions (al)".

**follow-ups.md**: append RESOLVED markers: (j) HY9; (ah) HY9+HY15; (p) HY4+HY13 ("SecretBox part = (al), deferred"); story-3 (b) HY11+HY12; I-10 HY6, I-11
HY7, I-12 HY1, I-13 HY8; (am) HY1-HY3 ("spec-unlimited discovery paths: cache only, (br)"); (an) HY5 +
doc edits. (al): "design in oauth-hardening-hygiene HY17; deferred (two-release rollout)". (t) and (o):
"re-assessed in P8: deferred" ((o): a cap shortens reuse detection, see (bs)). New section "From story oauth-hardening-hygiene (phase 2, P8, 2026-10-13)":

| # | Item | Finding | Gate |
|---|------|---------|------|
| bq | **Scheduled / UI signing-key rotation.** HY12 is manual (two rpc calls); no schedule, no Admin UI action, no alert on an old active key. | HY12 | non-gating |
| br | **Spec-unlimited discovery paths** (`auth_metadata`, `auth_issuer`, unstable aliases, `/versions`) have no per-source limit, only the HY1 cache; revisit if a flood shows CPU impact (503 + `Retry-After` would be spec compatible). | HY3 | non-gating |
| bs | **Rotated-row growth (o) without weakening reuse detection.** Options: move consumed refresh-token hashes to a compact hash-only tombstone table (kept until `session_expires_at`), and null `oidc_refresh_token` on rotated-away rows (they never use it) so old IdP RT ciphertexts do not accumulate. A plain row cap (P8 HY10) was rejected: it shortens T11. | HY10 | non-gating |
| bt | **`oauth_*` changes are eventual within `NEBU_OAUTH_CONFIG_CACHE_MS`**: scripts that flip and immediately probe must wait or poll (HY16). | HY2 | operator note |

### Architecture compliance

ADR-018 inline SQL (no repository layer); ADR-019 single app; ADR-020: OAuth -> Matrix only through
`Nebu.Matrix` (no new cross-domain call); the cache is the documented bounded-staleness exception (HY2); ADR-033 extended, not contradicted.

### Testing commands (isolated env, see the epic brief)

After adding 000047 `docker rm -f nebu-oauth-pg`; then
`quick.sh "mix test --include integration test/nebu/oauth test/nebu/migration/000047_oauth_signing_key_next_test.exs"`;
full gate: `cleanup.sh`, `integration.sh` in the background, compare with `known.txt`.

## Deferred

| Item | Why not in this story | Where recorded |
|---|---|---|
| (o) cap of rotated-away consumed rows per device | Security-negative: deleting consumed rows shortens the T11 reuse-detection window (a replayed old refresh token would no longer revoke the session). Alternative designs in (bs). | follow-ups (o), bs |
| (t) IdP-side revocation of the IdP refresh token at logout / revoke | Not contained: the ciphertext must outlive the teardown (new at-rest location: Oban args / queue table with retention), every teardown path (revoke, `/logout`, `/logout/all`, account page, admin, client revocation, GDPR, reuse revocation) must collect it, new outbound IdP code (client auth, `revocation_endpoint` discovery), behaviour only verifiable against a real IdP. Low benefit: Nebu deletes its copy; the IdP token is useless without Nebu's client secret. | follow-ups (t) |
| (al / E-5) SecretBox key id + HKDF subkeys + AAD | Cross-cutting (admin bootstrap, media storage config, Matrix and OAuth stores), AAD needs a stable row identity per call site, and writing v2 in the same release makes a rollback unreadable (mass logout, id_token outage): needs a two-release rollout. Design: HY17. | follow-ups (al) |
| (aq) keyed `SourceKey` hash | Depends on the (al) per-purpose subkeys. | follow-ups (aq) |
| (ap2) gate `X-Forwarded-Proto` on the trusted set | Only affects the requester's own cookie attributes; HY15 documents the operator side. | follow-ups (ap2) |
| 429 on `auth_metadata` / `auth_issuer` / aliases / `/versions` | Spec marks them not rate-limited; LB health check; the cache removes the DB load. | br |
| Caching `pending_limits/0` / `token_settings/0` | Rate-limited / authenticated callers; values must apply immediately. | HY1 |

## Manual verification

| Check | How | Expected |
|---|---|---|
| Cache TTL in the real cluster | Two nodes; flip `oauth_enabled` by SQL; poll `/versions` on each node | Both flip within 2 s (default) |
| Cookie attributes behind the real proxy | Browser devtools on an authorize and an account login over https | `__Host-nebu_oa_…` / `__Host-nebu_acct_…`, `Secure`, `Path=/`; if not `__Host-`, the proxy does not send `X-Forwarded-Proto: https` (HY15) |
| Rotation with real clients | Run HY12 call 1, wait 15 min, call 2 while Element Web / FluffyChat sessions refresh | No logout and no id_token validation error at login / refresh |
| Emergency replacement | Staging only: corrupt nothing, run HY13 | Logins work again; a client with a cached JWKS may reject new id_tokens for <= 10 min (record which clients refetch on an unknown `kid`) |

## Open questions

1. Should HY12 refuse while `oauth_enabled` is off? Proposed: no (lets operators rehearse).

## ATDD Decisions (adaptation, 2026-10-13)

Contracts the red tests pin (the implementation uses exactly these; the test files say where):

- **Config cache** (`oauth_config_cache_test.exs`): ETS `:nebu_oauth_config_cache`, entry `{:config, map, loaded_at_ms}`, TTL
  `:nebu_http, :oauth_config_cache_ms` (`config/test.exs` = 0), `Nebu.OAuth.Config.parse_cache_ms/1`, clock seam
  `:nebu_http, :oauth_config_cache_clock_fn` (0-arity, integer ms; entry served while `now - loaded_at < ttl`), seams via
  `seam/2` in an `if Mix.env() == :test do` block (call sites say `seam(:oauth_config_source, nil)`, `seam(:oauth_config_repo, ...)`,
  `seam(:oauth_config_cache_clock_fn, nil)`; the only literal `Application.get_env(:nebu_http, key, ...)` is inside the block).
  A cold `/versions` bounded read FILLS the cache (HY2).
- **CacheOwner**: child id `Nebu.OAuth.CacheOwner` (worker) of `Nebu.Supervisor`, after `Nebu.Repo`, before Bandit; owns both tables.
- **Rate limits**: keys `{"login_flows", ClientIP.bucket(conn)}` (300/min, burst 300, Matrix 429 envelope) and
  `{"oauth_openid_configuration", bucket}` (600/min, burst 600, JWKS 429 shape); disabled branch takes no token.
- **Binding cookies**: https `__Host-nebu_oa_<16 hex>` / `__Host-nebu_acct_<16 hex>` (`Path=/; Secure`, clear = same name/path/secure);
  each scheme reads only its own name. e2e runs over plain http, so its step only gained a tolerant regex.
- **Release**: `rotate_oauth_signing_key/0` returns `{:ok, {:published, kid, iso}} | {:ok, {:activated, new, old}} |
  {:error, {:too_early, s}} | {:error, :next_key_unavailable} | {:error, :conflict}`;
  `replace_oauth_signing_key/1` (default argument `nil`) `:emergency` => `{:ok, {:replaced, new, old}}`, anything else `{:error, :confirmation_required}`.
  Audit target_type `oauth_signing_key`, target_id = the NEW kid, metadata values = kids only, actor `operator:rpc`.
- **Migration 000047** (not 000048): constraint names `oauth_signing_keys_status_check` / `oauth_signing_keys_retired_check`,
  index `oauth_signing_keys_one_next`, policy `oauth_signing_keys_insert`, function `oauth_signing_keys_guard()`; created_at is immutable, so aged
  `next` rows are INSERTED backdated (tests and the DB rule alike).
- **e2e (HY16)**: `fixtures/db.ts` `upsertServerConfig` / `deleteServerConfig` block (sync) on `awaitOAuthConfigApplied(key)` for the two `oauth_*` switch keys.
- Changed by design: `oauth_admin_test.exs` (badge wording), `oauth_idp_delegation_test.exs` + `oauth_consent_flow_test.exs` (https flow: `__Host-`
  name, authorize and callback both https), `oauth_versions_static_test.exs` (Must #19 amended), `adr_033_test.exs` (non-gating list, AC13 pins).
- AC11.4 (review cycle 1): the loser is EXACTLY `{:error, :conflict}`; the test holds the rotation advisory lock until both callers are blocked on it.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (bmad-dev-story, phase 2, P8)

### Debug Log References

- Migration test needs a fresh throwaway DB (`docker rm -f nebu-oauth-pg` before the first `quick.sh` run after adding 000047).
- Legacy `auth_issuer` and the unstable `auth_metadata` alias answer `200` in BOTH states (the legacy IdP passthrough answers while OAuth is off): the staged AC2.2 probes tell the states apart by the advertised issuer (Nebu's vs the IdP's). The stable v1 `auth_metadata` is Nebu's own document, so `:unknown` is a `404` there (AC2.3 expected `503` only for the OAuthDiscovery paths).
- `oauth_legacy_coexistence_static_test.exs` forbids the string `Nebu.OAuth.Config` in the code (not comments) of `nebu/matrix/**`: the `HttpPublic` `@doc` says "per-node OAuth config cache".
- `config/runtime.exs` runs AFTER `config/test.exs` also in `:test`: the HY1 parse is gated with `config_env() != :test`.

### Completion Notes List

- **HY1-HY5 config cache + seams:** `Nebu.OAuth.Config` serves `{:config, map, loaded_at_ms}` from `:nebu_oauth_config_cache` while `now - loaded_at < ttl` (`parse_cache_ms/1`, `NEBU_OAUTH_CONFIG_CACHE_MS` 0..5000, default 2000, `config/test.exs` = 0, runtime.exs gated). `load_from_db/1` returns `{:cache, map} | {:nocache, map}`: only a successful read is written (`:unknown`, `:no_repo` never); `pending_limits/0` / `token_settings/0` stay uncached (the cache lives in `cached_load/1`, not in `load_raw/1`). Seams (`:oauth_config_source`, `:oauth_config_repo`, `:oauth_config_cache_clock_fn`) go through `seam/2` under `if Mix.env() == :test`. Absent table = miss (`ArgumentError` rescued), never created by a request.
- **HY4 `Nebu.OAuth.CacheOwner`:** GenServer in `Nebu.Application` after `Nebu.RateLimitSweeper` / the Repo children and before Bandit; owns both tables; `SigningKeyStore.ensure_table/0` removed.
- **HY3 rate limits:** `GET /login` (`{"login_flows", bucket}` 300/300, Matrix 429 via the new public `RateLimit.respond_limited/2`) and the live `GET /.well-known/openid-configuration` (`{"oauth_openid_configuration", bucket}` 600/600, JWKS 429 shape; the disabled branch and non-GET take no token). Nothing on `auth_metadata`, `auth_issuer`, aliases, `/versions`.
- **Hygiene:** `confirm_text/3` JSON-encodes the name after a 80-grapheme cut and replaces invalid UTF-8 first (never raises); badge wording (`host matches client_uri`, `NOT tied to the client_uri host: ...`, explanatory sentences; `data-role` untouched); `idp_complete_login/4` also catches `:exit` (`unexpected exit`). The `ClientStore` `inspect(other)` part was already closed by P4.
- **HY9 cookies:** `cookie_name(conn, hash)` / `cookie_path(conn)` in `Authorize` and `Account`: https => `__Host-nebu_oa_<16 hex>` / `__Host-nebu_acct_<16 hex>` with `Path=/; Secure`, http unchanged; read and clear use the name of the request's own scheme only.
- **HY11 migration 000047** (`next` status, CHECKs, `oauth_signing_keys_one_next`, insert policy, guard function with the DB-enforced 900 s rule; down with `NO FORCE` / `FORCE` around the DELETE and 000042's function verbatim).
- **HY12/HY13 rotation:** `SigningKeyStore.rotate/1` and `replace_emergency/1` (one transaction, `next` row `FOR UPDATE`, audit inside the transaction through the caller's hook, kids and atoms only), facade `Nebu.OAuth.rotate_signing_key/1` / `replace_signing_key/1`, `Nebu.Release.rotate_oauth_signing_key/0` / `replace_oauth_signing_key/1` (`write_audit/5` with a target type; the 4-arity form is unchanged), `AuditWriter` `@known_actions` + the three `oauth_signing_key_*` actions. `published_keys/0` lists active, next, retired. Call 1 without an active key answers `{:error, :no_active_key}` (nothing to rotate yet).
- **HY16 e2e:** `awaitOAuthConfigApplied` polls `auth_metadata`; review M12: it compares the advertised issuer with the stored one (no regex copy of the server's issuer validation).
- **Docs:** ADR-033 section HY1-HY17 + rotation procedure + manual verification, C2 / V2 / V8-V12 / story-3 T18 / D-cookie wording; 07-deployment (heading, `oauth_enabled` row, `NEBU_OAUTH_CONFIG_CACHE_MS` paragraph, signing-key row, migration 000047, cookies and the proxy note, kill-switch rate-limit paragraph and "within ... on every node", non-gating list, "Rotating the id_token signing key"); follow-ups (RESOLVED markers, (al) / (t) / (o) re-assessed, new section).
- **Pre-dev test review (12 MINOR) fixed in the staged tests:** M1 (`:sys.get_state` instead of sleeping), M2 (monitored dying process), M3 (no row-shape pin), M4 (forced overlap: a privileged transaction holds the `next` row lock until both callers are blocked), M5 (failure injection: a failing promote UPDATE / next INSERT / replacement INSERT / audit write rolls everything back, no audit row), M6 (`"d"\s*(:|=>)` plus the decoded `d` values), M7 (trusted proxy, IPv6 /64, OPTIONS preflight), M8 (variable-key reads in the guarded block, guard at module indent), M9 (000048 refutation removed, structural SQL regexes reduced to one idempotency check, SQLSTATE 42501 pinned for the retired insert), M10 (`rolsuper = false` asserted), M11 (rendered `data-confirm` of a hostile name in `oauth_admin_test.exs`, a no-raise test for odd input), M12 (e2e issuer compare).
- **Staged tests corrected by design:** `oauth_config_cache_test.exs` AC2.2 probes for `auth_issuer` / unstable alias (issuer comparison) and AC2.3 stable `auth_metadata` = 404; `adr_033_test.exs` follow-up ids (below).
- **Deviation (follow-up ids):** the story text and the ATDD pins named `bh`-`bk`, but `bf`-`bl` are already used by the room-summary section of `follow-ups.md` (and `bm`-`bo` by the planned device-lists story). The new items are `bq` (scheduled / UI rotation), `br` (spec-unlimited discovery paths), `bs` (rotated-row growth), `bt` (eventual `oauth_*` changes); the story text, ADR, 07-deployment and `adr_033_test.exs` use these ids (the story text was corrected in review cycle 1).
- **Verification** (isolated env, `quick.sh`): story tests + migration + admin + ADR (260 / 90 passed), `test/nebu/oauth` + `test/nebu/migration` (2578 passed after the one static-test fix), unit run without `NEBU_DB_URL` (3692 passed), prod compile (only the known `event_dispatcher/server.ex` warning), full `mix test --include integration` 6167 / 6192 passed, 25 failures all known families (RoomsFallbackName, TraceMap / WarRoom / TemporaryCapture, AdminOidcLogin, LogStore retention, SsoLogin `extra_redirect_schemes`, RegressionSyncLoad), e2e `tsc --noEmit` and `bddgen --tags` for the five OAuth tags clean.
- **Open items:** the manual verification table of the story / ADR (cache TTL on two nodes, `__Host-` names behind the real proxy, rotation with real clients, emergency replacement).

### Review cycle 1 (code review 5 MINOR, Kassandra 2 LOW)

- **M1 (concurrent rotation):** `SigningKeyStore.rotate/1` / `replace_emergency/1` take `pg_advisory_xact_lock(hashtext('nebu_oauth_signing_key_rotation'))`. `rotate/1` snapshots the `next` kid BEFORE the lock and compares it AFTER: a caller whose picture changed (another operator published, promoted or discarded) returns `{:error, :conflict}` and changes nothing; a call that simply starts after the other committed stays an ordinary call. Tests: the overlap is forced by a privileged transaction holding the same advisory lock until both callers are blocked (`pg_locks`); call 2 twice => `:activated` + EXACTLY `:conflict`, call 1 twice => `:published` + EXACTLY `:conflict`. Docs consistent (ADR HY12, 07-deployment, `Release` and store docs, story AC11.4 and ATDD note).
- **M2:** the story text uses `bq`-`bt` everywhere; deviation note updated.
- **M3:** stale RED-phase moduledocs of the five new test files reworded. **M4:** ADR T18 (JWKS lists active, `next`, retired) and D4 (path = the callback only on http). **M5:** the static cache-owner tests moved to `oauth_cache_owner_static_test.exs`.
- **INFO2:** `:audit` is REQUIRED (`Keyword.fetch!`) in `SigningKeyStore.rotate/1` / `replace_emergency/1` and the `Nebu.OAuth` facade (no default argument).
- **Kassandra L-1:** 07-deployment states that the `GET /login` bucket is shared wherever the client IP is not resolved, in every deployment; follow-up `bu` (Helm value, optional boot WARNING). **L-2:** the `Path=/` widening is documented next to HY9 (ADR, 07-deployment). **INFO3:** runbook text for `:conflict` fixed.
- **Verification:** story tests 126 passed; `test/nebu/oauth` + `test/nebu/migration` 2580 passed; unit run without DB 3692 passed; prod compile only the known warning; full integration run 6164 / 6194, 30 failures all known families (RoomsFallbackName, TraceMap / WarRoom / TemporaryCapture, AdminOidcLogin, ConfigController, MatrixSso / SsoLogin, MatrixClientCompat, OidcPlug, LogStore retention, RegressionSyncLoad); e2e `tsc --noEmit` clean.

### File List

Server (lib): `server/lib/nebu/oauth/config.ex`, `server/lib/nebu/oauth/cache_owner.ex` (new), `server/lib/nebu/oauth/signing_key_store.ex`, `server/lib/nebu/oauth.ex`, `server/lib/nebu/oauth/http.ex`, `server/lib/nebu/oauth/authorize.ex`, `server/lib/nebu/oauth/account.ex`, `server/lib/nebu/release.ex`, `server/lib/nebu/application.ex`, `server/lib/nebu/matrix.ex`, `server/lib/nebu/matrix/http_public.ex`, `server/lib/nebu/web/plugs/rate_limit.ex`, `server/lib/nebu/web/plugs/oauth_discovery.ex`, `server/lib/nebu/compliance/audit_writer.ex`, `server/lib/nebu/admin/oauth_registrations_html.ex`, `server/lib/nebu/admin/templates/oauth_registrations/{index,approve_confirm}.html.heex`.

Config / migrations: `server/config/runtime.exs`, `server/config/test.exs`, new `server/priv/migrations/000047_oauth_signing_key_next.{up,down}.sql`.

Tests / e2e (staged by ATDD, fixed or extended here): `server/test/nebu/migration/000047_oauth_signing_key_next_test.exs`, `server/test/nebu/oauth/oauth_cache_owner_static_test.exs` (new, review M5), `server/test/nebu/oauth/{oauth_config_cache_test,oauth_discovery_rate_limit_test,oauth_hygiene_test,oauth_binding_cookie_test,oauth_signing_key_rotation_test,oauth_admin_test,adr_033_test}.exs`, `e2e/fixtures/db.ts`.

Docs: `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/architecture/07-deployment.md`, `docs/stories/oauth-broker/follow-ups.md`, this story file.

### Change Log

- 2026-10-13: review cycle 1 (advisory-lock rotation, required audit hook, docs, test hygiene).
- 2026-10-13: implemented HY1-HY17 (HY10 and HY17 are documented decisions, deferred), migration 000047, rotation tooling, docs; fixed the 12 pre-dev test review findings; status review.
