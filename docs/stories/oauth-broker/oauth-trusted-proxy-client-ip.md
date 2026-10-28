---
story_id: oauth-trusted-proxy-client-ip
title: "Trusted-proxy client-IP resolution: CIDR-gated X-Forwarded-For, one resolution plug, one helper for every per-IP consumer (gate item 1, HARD GATE)"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-12
branch: feature/migrate-to-oauth2
---

## Summary

Phase-2 story P1 of epic `oauth-broker`. Closes the server side of `follow-ups.md` item 1 (Kassandra
F-1, HARD GATE before `oauth_enabled`) and the confirmations (a) of stories 2, 3 and 4 (and the
per-source wording of story-6 A19 / (aa)): today every per-IP decision uses `conn.remote_ip`, the
directly connected peer. On both reference deployments that peer is nginx, so every per-IP bucket is
effectively ONE global bucket and one abusive client throttles everybody.

Affected today (all keyed by the peer-IP string, verified by grep on HEAD):

| Consumer | Where | Key / use |
|---|---|---|
| RateLimit plug (`key: :ip` and the `:user` fallback) | `server/lib/nebu/web/plugs/rate_limit.ex` `ip_key/1` (~l.205) | login, refresh (`http_public.ex` ~l.106-119), sync, account-data writes, mutual rooms (`router/protected.ex` ~l.38-63, 771-989, 1695), media upload / URL preview (`router/media.ex` ~l.48-73) |
| `Nebu.OAuth.Authorize` private `ip_string/1` | `server/lib/nebu/oauth/authorize.ex` ~l.471 | `{"oauth_authorize", ip}` (~l.101), `{"oauth_callback", ip}` (~l.280) |
| `Nebu.OAuth.Http` private `ip_string/1` | `server/lib/nebu/oauth/http.ex` ~l.566 | `{"oauth_jwks", ip}` (~l.215), `{"oauth_register_loose"\|"oauth_register_invalid"\|"oauth_register", ip}` (~l.395-430, the 429 abuse control), `created_from_ip` of `oauth_clients` (`store/2` ~l.487) |
| `Nebu.OAuth.FormPost.ip_string/1` (public) | `server/lib/nebu/oauth/form_post.ex` ~l.113 | used by `token.ex` (`{"oauth_token", ip}`, `{"oauth_token_refresh", ip}` ~l.128, via private `ip_string/1` ~l.498), `revoke.ex` (`{"oauth_revoke", ip}` ~l.90), `account.ex` (`{"oauth_account", ip}` ~l.121, ~l.498) |
| `Protected` private `client_ip/1` | `server/lib/nebu/web/router/protected.ex` ~l.2216 | `devices.last_seen_ip` (`touch_device_last_seen/1`) |
| `HttpPublic` private `client_ip/1` | `server/lib/nebu/matrix/http_public.ex` ~l.570 | `devices.last_seen_ip` at login (`register_device/4`) |

Not affected (checked): `Nebu.Web.Plugs.RequestLogger` does not log an IP; compliance audit rows
have no IP column; the admin session (`Nebu.Admin.Endpoint`, cookie session) is NOT bound to an IP;
the LiveView socket does not request `peer_data`; `media/http_fetch.ex` / `media/ssrf.ex` use
`:inet` for OUTBOUND target addresses (unrelated).

`NEBU_TRUSTED_PROXY` (the "existing env"): it is read NOWHERE in `server/` (grep: only `CHANGELOG.md`,
`07-deployment.md` l.184/656, `08-concepts.md` l.441, Kassandra memory, and the pin in
`adr_033_test.exs` l.481). It is a leftover of the removed Go gateway. The `Secure` cookie flag /
https detection is `Nebu.Web.RequestScheme` (first `X-Forwarded-Proto` value, unconditional). This
story leaves `RequestScheme` and `NEBU_TRUSTED_PROXY` (unread) unchanged (TP12) and corrects the
docs that claim otherwise.

The fix: an explicit, fail-closed CIDR allowlist `NEBU_TRUSTED_PROXY_CIDRS` (default empty =
behaviour identical to today), a right-to-left `X-Forwarded-For` walk that is honoured only when the
direct peer is trusted, ONE plug in `Nebu.Web.Router` that stores the result in `conn.private`, and
ONE helper `Nebu.Web.ClientIP.get/1` that every consumer above calls (the duplicated `ip_string` /
`client_ip` / `ip_key` copies are deleted).

`oauth_enabled` stays OFF. No migration, no `server_config` key, no UI, no Matrix API change.

## Story

As an **operator running Nebu behind nginx / a cloud load balancer**,
I want Nebu to resolve the real client address from `X-Forwarded-For`, but ONLY from proxies I have
explicitly listed,
so that per-IP rate limits, the DCR abuse control, `created_from_ip` and `last_seen_ip` apply per
client instead of per proxy, and a client that reaches Nebu directly can never choose its own bucket.

## Decisions

Prefix `TP` (no collision with D/T/R/C/A/V in ADR-033). ADR-033 gets a section with TP1-TP14 (AC10).

- **TP1 (config: one env var, explicit CIDRs).** `NEBU_TRUSTED_PROXY_CIDRS`: entries separated by
  `,` and/or whitespace; each entry is an IPv4 or IPv6 address literal with an optional `/prefix`
  (`10.0.0.0/8`, `172.18.0.0/16`, `192.0.2.10`, `2001:db8::/32`, `::1`). A bare address means `/32`
  (IPv4) or `/128` (IPv6). Unset / empty / whitespace-only => NO trusted proxy (default, identical to
  today, no log line). A NEW name on purpose: the legacy boolean `NEBU_TRUSTED_PROXY` is not reused
  (a stale `true` in an old `.env` must never mean "trust everyone").
- **TP2 (fail-closed parsing).** An entry is INVALID and ignored when: it is not parseable by
  `:inet.parse_strict_address/1` (so `10.1`, `0x7f.1`, `1.2.3` shorthand are rejected); an IPv4 octet
  has a leading zero (`010.0.0.1`, octal ambiguity); it carries a zone (`fe80::1%eth0`), a port, or
  brackets; the prefix is not an integer in `0..32` / `0..128`; the address has HOST BITS SET for its
  prefix (`10.0.0.1/8`: rejected, not masked, the operator must write what they mean); it is an
  IPv4-mapped IPv6 entry (`::ffff:10.0.0.0/104`: write the IPv4 form); it is a keyword (`*`, `all`,
  `any`, `true`, `yes`, `0/0`). More than 64 entries, or a value longer than 4096 bytes => the WHOLE
  variable is ignored (no trusted proxy). Valid entries are kept even when others are invalid.
  Invalid entries produce exactly ONE boot `Logger.warning` line naming the count and up to 5
  offending entries (`inspect`ed, each truncated to 64 bytes); never "trust all" as a fallback.
- **TP3 (explicit catch-all is allowed but loud).** `0.0.0.0/0` or `::/0` written literally IS
  accepted (an operator who really has an L4 boundary in front may need it) but logs ONE boot
  `Logger.warning` "trusting X-Forwarded-For from every peer: any client that reaches Nebu directly
  can choose its rate-limit bucket". The danger is documented in `07-deployment.md` (AC9). A
  non-empty valid set logs one `Logger.info` with the number of trusted CIDRs (not the list).
- **TP4 (when the header is honoured).** Only if the normalised direct peer (`conn.remote_ip`) is in
  the trusted set. Untrusted peer => the client IP is the peer, every forwarding header is ignored.
- **TP5 (algorithm: right-to-left walk).** All `x-forwarded-for` header lines in request order are
  joined with `,` (RFC 9110 list semantics), split on `,`, each element trimmed. Walk from the RIGHT:
  each element must parse as an IP literal (TP2 address rules, no prefix); if it is trusted, skip it
  and continue; the FIRST untrusted element is the client IP. Elements LEFT of that one are never
  parsed (client-written garbage there cannot influence the result). Fallback to the direct peer
  when: no header / only empty values; an element reached by the walk is empty or malformed
  (`unknown`, `1.2.3.4:80`, `[::1]`, obfuscated identifiers, zone ids); every element is trusted
  (no client identified); the joined value exceeds 2048 bytes; more than 20 elements would have to be
  examined (hop cap). The fallback is the peer, never the leftmost element.
- **TP6 (`Forwarded` and `X-Real-IP`: ignored).** XFF only. Neither reference proxy sets RFC 7239
  `Forwarded`; parsing its quoted-string / obfuscated-node grammar adds attack surface and a
  precedence question. Both `Forwarded` and `X-Real-IP` are ignored entirely, also when XFF is
  absent (on UpCloud `alb`, nginx's `X-Real-IP` is the LB address, not the client). A proxy that can
  only emit `Forwarded` must be configured to emit XFF (documented).
- **TP7 (normalisation).** IPv4-mapped IPv6 (`::ffff:a.b.c.d`, from the peer or an XFF element) is
  converted to IPv4 BEFORE matching and in the result. IPv4 CIDRs only match IPv4 addresses, IPv6
  CIDRs only IPv6 addresses. The output string is `:inet.ntoa/1` of the normalised tuple (lowercase,
  compressed IPv6), i.e. byte-identical to today's key for every IPv4 and native IPv6 peer. Today's
  listener (`{Bandit, plug: Nebu.Web.Router, port: ...}`, IPv4 only) never yields mapped peers, so the
  normalisation is the only and documented deviation from today's strings.
- **TP8 (bucket semantics unchanged).** Every bucket keeps its tag, rates and key shape; only the IP
  string inside it changes. IPv6 stays per full address (no /64 aggregation: no existing code does it;
  per-source /64 aggregation is the NEW cap of gate (h), story P2, which builds on this helper). The
  RateLimit plug keeps its shared bare-string key across tiers (login and sync share one bucket per
  client, as today).
- **TP9 (ONE resolution point, `conn.remote_ip` is NOT overwritten).** New plug
  `Nebu.Web.Plugs.ClientIP` runs in `Nebu.Web.Router` directly after `RequestId` (before
  `RequestLogger`, CORS, `JsonBody`, `:match`), so every forwarded sub-router (`HttpPublic`,
  `Protected`, `Media`, `ClientV1Media`, `Nebu.OAuth.Http`) and `Nebu.Admin.Endpoint.call/2` see the
  result. It stores `conn.private[:nebu_client_ip]` (string) and `conn.private[:nebu_client_ip_source]`
  (`:peer | :forwarded`). `conn.remote_ip` keeps the real TCP peer: Plug/Phoenix internals and any
  future diagnostic see the true socket peer, and nothing can accidentally re-resolve a
  rewritten value. Consequence per consumer: all of them switch to `Nebu.Web.ClientIP.get/1`
  (AC6); RequestLogger, audit rows and the admin session are unchanged (they use no IP); the admin UI
  device list and the account page show `last_seen_ip` = the resolved client IP (the intended fix).
- **TP10 (the helper).** `Nebu.Web.ClientIP.get(conn) :: String.t()` returns
  `conn.private[:nebu_client_ip]` when set; otherwise (a conn that never passed the plug, e.g. a unit
  test calling a sub-router directly) the normalised PEER string, never an XFF-derived value
  (fail closed: a path that bypasses the plug can never be spoofed). Non-tuple `remote_ip` =>
  `to_string/1` of it (parity with today's `ip_key/1`; `last_seen_ip` consumers get that string
  instead of `nil`: impossible under Bandit and `Plug.Test`, accepted).
- **TP11 (multi-node, no correctness state).** The resolution is a pure function of the request and
  the env. The parsed CIDR list is computed once at boot and cached in `:persistent_term` (derived
  from the env, identical on every node with the same env; no runtime writer except the test seam).
  The buckets themselves stay node-local ETS (unchanged, ADR-033 "node-local abuse control").
- **TP12 (`RequestScheme` / Secure flag unchanged).** `X-Forwarded-Proto` handling is NOT gated by
  the new CIDR list in this story (changing it could flip `Secure` / `__Host-` cookies on running
  deployments). Recorded as a new non-gating follow-up: consider gating `X-Forwarded-Proto` on the
  same trusted set.
- **TP13 (no IP in logs).** The plug logs nothing per request; the boot lines never print resolved
  client IPs. No new log field.
- **TP14 (cluster/proxy topology is the operator's job).** Nebu cannot detect a wrong CIDR list.
  Trusting a network from which untrusted clients can open connections to Nebu (e.g. the Docker
  bridge gateway while the published host port `8008` is reachable from outside) re-opens spoofing;
  documented as an operator rule and as Manual verification. Template changes (setting the variable,
  binding published ports to `127.0.0.1`, pinning compose subnets) belong to story P5 (gate m) and
  are appended to `follow-ups.md`.

## Acceptance Criteria

### AC1 — CIDR parsing (TP1-TP3)

1. `Nebu.Web.ClientIP.parse_cidrs/1` (pure, `@doc`, `@spec`) returns `{trusted, invalid}` where
   `trusted` is a list of `{family, network_int, prefix}` and `invalid` the list of rejected entries.
2. Accepted: `10.0.0.0/8`, `172.18.0.0/16`, `192.0.2.10` (=/32), `0.0.0.0/0`, `2001:db8::/32`,
   `2001:DB8::/32` (case-insensitive), `::1` (=/128), `::/0`, mixed separators
   `"10.0.0.0/8, 192.0.2.1  2001:db8::/48"`.
3. Rejected (each alone => `trusted == []`): `*`, `all`, `true`, `0/0`, `10.1`, `1.2.3`, `0x7f.0.0.1`,
   `010.0.0.1`, `10.0.0.0/33`, `10.0.0.0/-1`, `10.0.0.0/8a`, `10.0.0.1/8` (host bits),
   `2001:db8::1/32` (host bits), `2001:db8::/129`, `fe80::1%eth0`, `[::1]`, `10.0.0.1:80`,
   `::ffff:10.0.0.0/104`. An empty entry between separators (`"10.0.0.0/8,,"`) is skipped, not an
   error.
4. Mixed valid + invalid keeps the valid ones. 65 valid entries or a 4097-byte value => `trusted == []`
   and the whole variable reported invalid.
5. `nil`, `""`, `"   "` => `{[], []}`.

### AC2 — Boot configuration and warnings (TP2, TP3, TP11, TP13)

1. `config/runtime.exs` copies `System.get_env("NEBU_TRUSTED_PROXY_CIDRS")` into
   `config :nebu_http, trusted_proxy_cidrs: <raw string or nil>` (no parsing in runtime.exs).
2. `Nebu.Application.start/2` calls `Nebu.Web.ClientIP.load_config/0` before the Bandit child starts
   (next to `RateLimit.init_table()`, `application.ex` ~l.32); it parses, stores the result in
   `:persistent_term`, and logs: nothing for an empty value; one `info` with the count for a valid
   set; exactly ONE `warning` for any invalid entries (count + at most 5 entries, each <= 64 bytes);
   exactly ONE additional `warning` when a `/0` entry is trusted. Verified with `capture_log`.
3. Test seam `Nebu.Web.ClientIP.configure/1` (`String.t() | nil`) re-runs the same parse + store +
   log path; `configure(nil)` restores "no trusted proxy". Documented as TEST/boot-only in the
   moduledoc.
4. With no configuration ever loaded (`:persistent_term` key absent), the trusted set is `[]`.

### AC3 — Resolver (TP4-TP7)

`Nebu.Web.ClientIP.resolve(peer :: :inet.ip_address(), xff :: [String.t()], trusted) ::
{:peer | :forwarded, :inet.ip_address()}` is pure. With `trusted = 10.0.0.0/8, 2001:db8:1::/48`:

1. Untrusted peer `198.51.100.9`, XFF `["203.0.113.7"]` => `{:peer, {198,51,100,9}}` (spoof refused).
2. Trusted peer `10.0.0.5`, XFF `["203.0.113.7"]` => `{:forwarded, {203,0,113,7}}`.
3. Hop skipping: peer `10.0.0.5`, XFF `["198.51.100.1, 203.0.113.7, 10.0.0.9, 10.1.2.3"]` =>
   `203.0.113.7` (rightmost untrusted; the client-written `198.51.100.1` is ignored).
4. Multiple header lines `["203.0.113.7", "10.0.0.9"]` => `203.0.113.7`.
5. Garbage left of the client is ignored: `["foo, <script>, 203.0.113.7"]` => `203.0.113.7`.
6. Fallback to the peer (`{:peer, {10,0,0,5}}`): `[]`; `[""]`; `[" , "]`; `["unknown"]`;
   `["203.0.113.7:443"]`; `["[2001:db8::1]"]`; `["fe80::1%eth0"]`; `["10.0.0.9, , 10.0.0.8"]`
   (empty element reached); all elements trusted `["10.0.0.9, 10.0.0.8"]`; joined length 2049
   bytes; 21 trusted elements followed by nothing untrusted within the cap
   (`List.duplicate("10.0.0.9", 21)`), and a 25-element header whose untrusted element is the 21st
   from the right.
7. IPv6: peer `2001:db8:1::5`, XFF `["2001:db8:2::7"]` => `{:forwarded, {0x2001,0xdb8,2,0,0,0,0,7}}`;
   peer `2001:db8:2::5` (not in /48) => peer.
8. Mapped: peer `::ffff:10.0.0.5` is trusted by `10.0.0.0/8` and XFF `["::ffff:203.0.113.7"]`
   resolves to `{203,0,113,7}`; an IPv4 CIDR never matches a native IPv6 address and vice versa.
9. Boundaries: `10.0.0.0/8` matches `10.255.255.255`, not `11.0.0.0`; `/32` and `/128` match only
   the exact address; `0.0.0.0/0` matches every IPv4 and no IPv6.
10. Property-style test (ExUnit loop, >= 200 random cases, no new dependency): with an untrusted
    peer the result is ALWAYS the peer whatever XFF contains; with a trusted peer the result is either
    the peer or an untrusted element of the header such that every element to its right is a valid,
    trusted address.

### AC4 — The plug (TP9, TP10)

1. `Nebu.Web.Plugs.ClientIP` (`@behaviour Plug`) sets `conn.private[:nebu_client_ip]` (string,
   `:inet.ntoa/1` of the normalised tuple) and `[:nebu_client_ip_source]`; it never halts, never
   reads the body, never touches `conn.remote_ip`, and is placed in `Nebu.Web.Router` right after
   `plug Nebu.Web.Plugs.RequestId` (a test asserts the plug order of `Nebu.Web.Router` via
   `__info__`-free source inspection or a request through the router with a trusted peer whose
   `conn.private` is visible to a sub-router; pick one, document it in ATDD Decisions).
2. `Nebu.Web.ClientIP.get/1` returns the private value when present, else the normalised peer string
   even when an XFF header is present and the peer is in the configured trusted set (bypass = no
   spoof).
3. A crash-free guarantee: any header content (binary garbage, 10 000 commas) yields a conn, never a
   raise (the 2048-byte cap is checked before splitting).

### AC5 — Separate buckets behind one trusted proxy, no spoofing (integration through the router)

All with the limiter ENABLED following the setup of `server/test/nebu/web/rate_limit_test.exs`
(`Application.delete_env(:nebu_http, :rate_limit_disabled)`, assert the OS env
`NEBU_RATE_LIMIT_DISABLED != "true"`, clear the ETS table, frozen `:rate_limit_clock_fn`), `async:
false`, `configure/1` reset in `on_exit`.

1. `configure("10.0.0.0/8")`; peer `10.0.0.5`. Client A (`XFF: 203.0.113.7`) sends 11
   `POST /_matrix/client/v3/login` (burst 10): the 11th is `429 M_LIMIT_EXCEEDED`; client B
   (`XFF: 203.0.113.8`) through the same peer then gets a non-429 answer.
2. Same setup for an OAuth bucket: after one `GET /oauth2/jwks` (or `POST /oauth2/register` with
   junk) per client, the ETS table holds `{"oauth_jwks", "203.0.113.7"}` and
   `{"oauth_jwks", "203.0.113.8"}` and NO key containing `"10.0.0.5"` (assert keys directly; no
   need to exhaust 600/h). Repeat the key assertion for `{"oauth_register_invalid", ip}` and, with
   the story-2 seams of `oauth_test_support.exs`, `{"oauth_authorize", ip}`.
3. Spoof: untrusted peer `198.51.100.9`, 11 logins each with a DIFFERENT `XFF` value: the 11th is
   `429`; the only per-IP key is `"198.51.100.9"`.
4. Default regression: no `configure` (empty set), peer `10.0.0.5` with `XFF: 203.0.113.7`: the key
   is `"10.0.0.5"`, exactly as before the story. The existing suites
   (`rate_limit_test.exs`, every OAuth suite that passes `ip:` to `oauth_test_support.exs`
   `with_opts/2`, `media` rate-limit tests) stay green unchanged.
5. `@tag :integration` (DB): with `configure("10.0.0.0/8")` a `POST /oauth2/register` of new valid
   metadata through peer `10.0.0.5` with `XFF: 203.0.113.7` stores `created_from_ip = '203.0.113.7'`
   (read back via `ClientStore` / SQL); without configuration it stores `'10.0.0.5'`.

### AC6 — Every consumer uses the helper (contract test)

1. Deleted: `ip_key/1` in `rate_limit.ex`, `ip_string/1` in `authorize.ex`, `http.ex`, `token.ex`,
   the public `FormPost.ip_string/1`, `client_ip/1` in `protected.ex` and `http_public.ex`. Each call
   site calls `Nebu.Web.ClientIP.get/1` (alias allowed).
2. New static test `server/test/nebu/web/client_ip_contract_test.exs` scans `server/lib/**/*.ex`:
   - the token `remote_ip` occurs ONLY in `lib/nebu/web/client_ip.ex` and
     `lib/nebu/web/plugs/client_ip.ex` (moduledocs elsewhere say "direct peer");
   - `x-forwarded-for` (case-insensitive) occurs only in those two files;
   - no `def`/`defp` named `ip_string`, `client_ip` or `ip_key` exists anywhere;
   - `:inet.ntoa` occurs only in `client_ip.ex` and `lib/nebu/media/http_fetch.ex` (outbound,
     allowlisted with a comment);
   - the string literals `"forwarded"` (RFC 7239 header name) and `"x-real-ip"` occur nowhere.
3. `last_seen_ip` written by `protected.ex` `touch_device_last_seen/1` and by
   `http_public.ex` `register_device/4` comes from `ClientIP.get/1` (covered by the static rule; an
   additional DB test is optional).

### AC7 — Unchanged behaviour (TP8, TP12)

1. `Nebu.Web.RequestScheme` is byte-unchanged; the account-page and binding-cookie `Secure` tests
   stay green.
2. Bucket tags, rates, bursts and the `{tier, user}` key of `key: :user` are unchanged (diff review +
   existing tests).
3. No new migration, no `server_config` key, no new route, no response change.

### AC8 — RateLimit and OAuth moduledocs (requirement 6)

1. `Nebu.Web.Plugs.RateLimit` "IP extraction" section rewritten: the key is
   `Nebu.Web.ClientIP.get/1` (direct peer unless the peer is in `NEBU_TRUSTED_PROXY_CIDRS`, then the
   rightmost untrusted `X-Forwarded-For` element); spoofing rule; IPv6 per full address.
2. `Nebu.OAuth.Http` "Rate limits" moduledoc (~l.44-50) and the ADR-033 paragraph "Remaining
   weakness" (~l.169) no longer claim "the IP is the directly connected peer"; they reference the
   resolver and state that without configuration it still is.

### AC9 — Deployment documentation (requirement 5)

In `docs/architecture/07-deployment.md`:

1. New subsection "Client IP behind a reverse proxy (`NEBU_TRUSTED_PROXY_CIDRS`)" under "Activating
   OAuth" > "Reverse proxy": format and examples; default none; the algorithm in three sentences;
   reference-proxy requirement: every trusted hop must APPEND (nginx
   `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`) or, on the outermost proxy that
   faces the internet, OVERWRITE (`proxy_set_header X-Forwarded-For $remote_addr;`); list only the
   addresses of YOUR proxies (compose network subnet of the nginx container, the LB's private
   network), never client networks; the published host ports (`8008`, `8080`) must not be reachable
   from untrusted networks when the Docker gateway / bridge subnet is trusted; `0.0.0.0/0` / `::/0`
   danger; `Forwarded` / `X-Real-IP` are ignored; verification recipe (two clients, distinct
   `last_seen_ip` in `/admin` users or `GET /_matrix/client/v3/devices`).
2. Preconditions table row 1 updated: "Trusted-proxy client-IP resolution (HARD GATE):
   `NEBU_TRUSTED_PROXY_CIDRS` (story oauth-trusted-proxy-client-ip); `NEBU_TRUSTED_PROXY` is not
   read" | status "closed in the server; operator must configure and verify the CIDRs (Manual
   verification)" | owner "server / operator". (The pin in `adr_033_test.exs` l.481 still matches
   `NEBU_TRUSTED_PROXY`; update its message text.)
3. The stale env line `NEBU_TRUSTED_PROXY — For X-Forwarded-* header handling via nginx` (~l.656)
   and the `{"oauth_account", ip}` sentence (~l.160) are corrected; the Stackit/UpCloud variable
   lists name `NEBU_TRUSTED_PROXY_CIDRS` as "not set by the templates yet (gate m, story P5)".

### AC10 — ADR-033, follow-ups

1. ADR-033 new section "Trusted-proxy client IP (phase 2, story oauth-trusted-proxy-client-ip)" with
   TP1-TP14 and the topology table of the Manual verification section; gate list item 1 marked
   "resolved in the server by this story; activation needs the operator verification".
2. `follow-ups.md`: item 1 and the (a) confirmations of stories 2/3/4 marked resolved (server) with a
   pointer to this story; append new items: (P5 / gate m) set `NEBU_TRUSTED_PROXY_CIDRS` in both
   cloud-init templates, pin the compose network subnet, bind published ports to `127.0.0.1`;
   (non-gating) TP12 `X-Forwarded-Proto` gating; (non-gating) PROXY-protocol support for TCP-mode
   load balancers (UpCloud `acme` / `none`), without which the client IP is lost at the LB.
3. `adr_033_test.exs` gets pins for the new ADR section headline and TP1/TP5/TP9 keywords, and for
   the 07-deployment subsection headline (ATDD role decides the exact regexes).

## Acceptance Tests

- New `server/test/nebu/web/client_ip_test.exs` (unit, `async: false` because of
  `:persistent_term`): AC1, AC2 (with `capture_log`), AC3 (incl. property loop), AC4.
- New `server/test/nebu/web/client_ip_integration_test.exs`: AC5.1-5.4 (unit, no DB, router level),
  AC5.5 `@tag :integration`.
- New `server/test/nebu/web/client_ip_contract_test.exs` (static): AC6.2.
- Changed: `server/test/nebu/oauth/adr_033_test.exs` (AC10.3; l.481 message).
- Regression (unchanged, must stay green): `rate_limit_test.exs`, all `server/test/nebu/oauth/*`,
  `matrix_router_test.exs`, media upload/preview tests, `request_logger_test.exs`.
- No Gherkin (`ui: false`, nothing visible changes).

## Must be test-covered

1. Default config: every bucket key equals today's peer string (IPv4 and IPv6 peers).
2. Untrusted peer + any XFF => peer (unit + router + property loop).
3. Trusted peer + XFF => rightmost untrusted element; trusted hops skipped; multi-line headers.
4. Malformed / empty / oversized / hop-cap / all-trusted => peer.
5. CIDR boundaries, IPv6, mapped normalisation, host bits, keywords, cap of 64 entries / 4096 bytes.
6. One warning line for invalid entries, one for `/0`, none for empty.
7. Two clients behind one trusted peer get two buckets (login 429 isolation; OAuth bucket keys).
8. `created_from_ip` stores the resolved IP (integration).
9. No consumer reads `conn.remote_ip` or XFF outside `client_ip.ex` (static).

## Dev Notes

### Current state (read before coding)

- `Nebu.Web.Router` (`server/lib/nebu/web/router.ex` l.13-28): `RequestId`, `RequestLogger`,
  `:security_headers`, `:cors`, `JsonBody`, `:match`, `:dispatch`; everything (incl. `/admin` via
  `Nebu.Admin.Endpoint.call/2` ~l.220) is dispatched from here, so one plug covers all endpoints.
  There is exactly one Bandit listener (`application.ex` ~l.165).
- `RateLimit.call/2` -> `bucket_key/2` -> `ip_key/1`; `take/3` takes an explicit key (OAuth
  modules build `{tag, ip_string(conn)}`). Both stay; only the IP source changes.
- `oauth_test_support.exs` `with_opts/2` (~l.174) sets `remote_ip: Keyword.get(opts, :ip,
  unique_ip())` per request: with the default (empty) trusted set every existing test keeps its own
  bucket. Add an optional `:xff` option there (header `x-forwarded-for`) for AC5.2.
- `rate_limit_test.exs` builds `%{conn(...) | remote_ip: ip}` and calls the plug WITHOUT the router:
  the helper's peer fallback (TP10) keeps it green.
- `ClientStore.register/1` (`client_store.ex` ~l.50) inserts `created_from_ip` from `attrs.ip`;
  unchanged, `http.ex` `store/2` passes `ClientIP.get(conn)`.

### Implementation sketch

`server/lib/nebu/web/client_ip.ex` (`Nebu.Web.ClientIP`):

```elixir
@spec get(Plug.Conn.t()) :: String.t()
@spec resolve(:inet.ip_address(), [String.t()], [cidr]) :: {:peer | :forwarded, :inet.ip_address()}
@spec parse_cidrs(String.t() | nil) :: {[cidr], [String.t()]}
@spec load_config() :: :ok          # boot: Application.get_env(:nebu_http, :trusted_proxy_cidrs)
@spec configure(String.t() | nil) :: :ok   # boot/test seam, same path
@spec trusted() :: [cidr]           # :persistent_term.get({__MODULE__, :trusted}, [])
```

- Address -> integer: IPv4 `<<a,b,c,d>>` as 32-bit, IPv6 eight 16-bit words as 128-bit;
  match = `Bitwise.bsr(addr_int, bits - prefix) == Bitwise.bsr(net_int, bits - prefix)` (prefix 0 =>
  always true within the family). Host-bit check at parse time: `net_int` masked == `net_int`.
- Parse IP literals with `:inet.parse_strict_address(String.to_charlist(s))` after rejecting `%`,
  `[`, `]`, and IPv4 octets with a leading zero (regex on the dotted form) and anything longer than
  45 bytes. Never `String.to_atom`.
- Normalise `{0,0,0,0,0,0xFFFF,hi,lo}` -> `{hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255}`.
- XFF read: `Plug.Conn.get_req_header(conn, "x-forwarded-for")`; check `byte_size` of the joined
  value BEFORE `String.split/2`; split from the right with `Enum.reverse/1` and a counter capped at
  20.
- `server/lib/nebu/web/plugs/client_ip.ex` (`Nebu.Web.Plugs.ClientIP`): `init/1` returns opts;
  `call/2` reads `ClientIP.trusted()`, only reads the header when the peer is trusted, `put_private/3`
  both keys.

### Files to create

- `server/lib/nebu/web/client_ip.ex`, `server/lib/nebu/web/plugs/client_ip.ex`
- `server/test/nebu/web/client_ip_test.exs`, `client_ip_integration_test.exs`,
  `client_ip_contract_test.exs`

### Files to modify

- `server/lib/nebu/web/router.ex` (plug after `RequestId`, comment in the "Order matters" block)
- `server/lib/nebu/application.ex` (`ClientIP.load_config()` next to `RateLimit.init_table()`)
- `server/config/runtime.exs` (raw env -> `:nebu_http, :trusted_proxy_cidrs`)
- `server/lib/nebu/web/plugs/rate_limit.ex` (delete `ip_key/1`, moduledoc AC8)
- `server/lib/nebu/oauth/{authorize,http,form_post,token,revoke,account}.ex` (delete copies, call
  helper; `http.ex` moduledoc)
- `server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/matrix/http_public.ex` (delete
  `client_ip/1`)
- `server/test/nebu/oauth/oauth_test_support.exs` (`:xff` option), `adr_033_test.exs`
- Docs: `docs/architecture/07-deployment.md`, `docs/architecture/adr/ADR-033-...md`,
  `docs/stories/oauth-broker/follow-ups.md`, optionally `docs/architecture/08-concepts.md` l.441
  (historic Go `NEBU_TRUSTED_PROXY` sentence: add "superseded by `NEBU_TRUSTED_PROXY_CIDRS`").

### What must be preserved

- Default (unset) behaviour byte for byte (keys, responses, logs) except TP7 for mapped peers.
- `RateLimit` disabled semantics (`NEBU_RATE_LIMIT_DISABLED` / `:rate_limit_disabled`): resolution
  still runs (cheap) but no bucket is charged; tests that assert bucket keys force the limiter on.
- `RequestScheme` (TP12). CORS, `JsonBody` and the `/account` no-CORS branch are untouched.
- `oauth_enabled` stays OFF; nothing in this story reads or writes it.

### Traps

- `:inet.parse_address/1` accepts `"10.1"` and `"127.1"` shorthand: use `parse_strict_address`.
- `:inet.ntoa/1` of a mapped tuple prints `::ffff:1.2.3.4`: normalise first.
- Do not trim/match XFF by regex over the whole header (ReDoS / cost); split once after the length
  cap.
- `Plug.Router` `forward` keeps `conn.private`; a test that calls `Nebu.OAuth.Http.call/2` directly
  bypasses the plug and gets the peer (TP10), so AC5 tests must go through `Nebu.Web.Router.call/2`.
- `:persistent_term.put/2` triggers a global GC: only at boot and in tests, never per request.
- Docker's userland proxy makes every connection to a published port appear from the bridge
  gateway: trusting that gateway is only safe if the published port is unreachable from outside
  (TP14, AC9).
- Kassandra memory: "XFF rate-limit spoofing on directly-exposed services" (story 12): the CIDR gate
  on the direct peer is exactly that lesson; AC3.1 / AC5.3 prove it.

### Architecture compliance

ADR-018 (no SQL here; `ClientStore` unchanged), ADR-019 (plain modules in `:nebu`), ADR-020 (helper
in shared web infrastructure `Nebu.Web`, used by `Nebu.Matrix`/`Nebu.OAuth`/`Nebu.Media` routers; no
cross-domain call added), cluster safety (TP11), logging law (TP13), no new dependency (no
`remote_ip` hex package: its default trusts private ranges and it overwrites `remote_ip`, both
against TP1/TP9).

### Testing commands (isolated env, see the epic brief)

- `quick.sh "mix test test/nebu/web/client_ip_test.exs test/nebu/web/client_ip_contract_test.exs test/nebu/web/client_ip_integration_test.exs test/nebu/web/rate_limit_test.exs"`
- `quick.sh "mix test --include integration test/nebu/web/client_ip_integration_test.exs test/nebu/oauth"`
- Full gate: `integration.sh` in the background, compare with `known.txt`.

### Out of scope

`Forwarded` parsing (TP6), PROXY protocol, `X-Forwarded-Proto` gating (TP12), /64 aggregation and
per-source caps (gate h / aa, story P2), cloud-init template changes (P5), ETS bucket eviction (I-3).

## Manual verification

Must be done by the operator on the real deployment before `oauth_enabled` (fail closed until then:
an empty or wrong list = today's shared buckets, never spoofable):

| Deployment (`tls_mode`) | Path | Expected XFF at Nebu / peer | CIDRs to trust | Status |
|---|---|---|---|---|
| UpCloud `alb` / `dynamic` | client -> UpCloud LB (HTTP mode) -> compose nginx -> `server:4000` | `<client>, <LB private IP>` if the LB adds XFF, else only `<LB private IP>`; peer = nginx container IP | compose network subnet + `upcloud_network.nebu` CIDR | VERIFY whether the UpCloud LB adds/forwards `X-Forwarded-For` (if not, the client IP is unrecoverable: activation blocked) |
| UpCloud `acme` | LB TCP passthrough -> host nginx (TLS) -> `127.0.0.1:8008` -> docker-proxy | nginx `$remote_addr` = LB private IP (no PROXY protocol); peer = docker gateway | none useful | client IP lost at the LB: not supported without PROXY protocol (follow-up) |
| UpCloud `none` | LB TCP -> `server:8008` | no XFF; peer = LB | none | not supported |
| Stackit `alb` | Stackit ALB (HTTPS) -> compose nginx -> `server:4000` | as UpCloud `alb` | compose subnet + ALB network CIDR | VERIFY ALB XFF behaviour |
| Stackit `acme` | (NLB?) -> host nginx -> `127.0.0.1:8008` | `<client>` if the NLB preserves the source IP; peer = docker gateway | docker gateway /32 (only if `8008`/`8080` are unreachable from outside) | VERIFY source-IP preservation and port exposure |

Checks: count the real hops (`tcpdump` / a temporary nginx `log_format` with
`$http_x_forwarded_for` and `$remote_addr`), `docker network inspect` for the compose subnet (Docker
picks it at random unless pinned, P5), confirm `8008`/`8080` are not reachable from the internet,
then two clients from different networks must show different `last_seen_ip` values and independent
`429`s on `/login`.

## Open questions

1. Should `X-Forwarded-Proto` (TP12) be gated by the same list before activation? Proposed: no
   (non-gating follow-up), because it only affects attributes of the requester's own response.
2. UpCloud LB HTTP-mode XFF behaviour is undocumented in the repo; if it does not add XFF, the
   UpCloud `alb` topology cannot satisfy gate 1 and P5 must decide (PROXY protocol or a different LB
   mode).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (bmad-dev-story, phase 2 / P1).

### Debug Log References

- Targeted: `client_ip_test.exs` + `client_ip_contract_test.exs` + `client_ip_integration_test.exs` + `rate_limit_test.exs` (`--include integration`): 183 passed, 0 failed.
- `test/nebu/oauth test/nebu/web test/nebu/matrix` (`--include integration`): 3524/3529 passed, 2 skipped, 3 failures, all in known families (`MatrixSsoTest` callback loginToken, `OidcPlugTest` denylisted jti, `RegressionSyncLoadTest` 200 concurrent /sync).
- Prod-mode compile (`MIX_ENV=prod mix compile --force`): only the pre-existing warning `event_dispatcher/server.ex:4840`; nothing from this story.
- Full `mix test --include integration`: 5093/5122 passed, 3 skipped, 80 excluded, 26 failures, all known families (RoomsFallbackName x10, TemporaryCaptureManager, LogsLive.WarRoom, LogStore.Retention, AdminStaleRooms, MatrixSso/SsoLogin, OidcPlugTest, RegressionSyncLoad) plus `MediaOrphanDetectionWorkerTest` (1, not in known.txt; green alone, 9/9, order-dependent). OAuth / migration / discovery / session / web rate-limit failures: 0.

### Completion Notes List

- New `Nebu.Web.ClientIP` (`server/lib/nebu/web/client_ip.ex`): `parse_cidrs/1`, `resolve/3`, `get/1`, `load_config/0`, `configure/1`, `trusted/0`; parsed list cached in `:persistent_term`; boot log lines (one info with the count, one warning for invalid entries, one for a `/0` entry). The byte-wise parsing (`:erlang.binary_to_list` + `:inet.parse_strict_address/1`, no `String.to_charlist` on header bytes) makes invalid UTF-8 never raise; the 2048-byte cap is computed from the byte sizes before any join / split.
- New `Nebu.Web.Plugs.ClientIP` in `Nebu.Web.Router` right after `RequestId`; reads the header only for a trusted peer; stores `conn.private[:nebu_client_ip]` / `[:nebu_client_ip_source]`; `conn.remote_ip` untouched.
- `application.ex` calls `ClientIP.load_config()` next to `RateLimit.init_table()`; `config/runtime.exs` copies the raw env.
- Deleted the copies `ip_key/1` (RateLimit), `ip_string/1` (authorize, http, token, public `FormPost.ip_string/1`) and `client_ip/1` (protected, http_public); all call `Nebu.Web.ClientIP.get/1`. Docs of RateLimit / `OAuth.Http` rewritten (AC8).
- Docs: `07-deployment.md` (new subsection, precondition row 1, stale env line, `oauth_account` sentence, UpCloud note), `08-concepts.md`, ADR-033 (new section TP1-TP14 + Manual verification table, gate item 1, "Remaining weakness"), `follow-ups.md` (item 1 and the (a) confirmations resolved, new items ap1-ap3).
- Applied the pre-dev test review findings in the staged tests: m-2 (`configure(nil)` in `setup`), m-3 (more CIDR rejections incl. bare / hex mapped, upper-case keywords, invalid UTF-8 / NUL), m-4 (log counting restricted to feature lines), m-5 (65 entries / >4096 bytes log tests, TP13 plug-logs-nothing test, `configure("true")` wrapped in `capture_log`), m-7 (router-level duplicated header lines, invalid UTF-8 left of the client and as an intermediate hop, unit equivalents), i-4 (Logger level / env restored, not hard-coded), i-5 (`T.NoSuchRepo`, blanket rescue dropped), i-7 (IPv6 per-full-address test via the plug / `get/1`). m-1: moduledocs of consumers say "forwarding header" / "direct peer" so the static scan and the AC8 pins hold together.

### Deviations

- m-6 (optional DB test that a router login writes `devices.last_seen_ip`) not added: a login needs a full OIDC flow; the static contract (AC6.3) covers it.
- `last_seen_ip` consumers now get the string of a non-tuple `remote_ip` instead of `nil` (TP10, accepted: impossible under Bandit / Plug.Test).
- Two doc words in `plugs/client_ip.ex` and `config/runtime.exs` were reworded so the contract test's `:inet.ntoa` / `parse_cidrs` text scans stay satisfiable.
- The story has no Tasks/Subtasks section; the ACs were the work list.

### Review cycle 1 (code review 3 MINOR + Kassandra 2 MEDIUM / 2 LOW)

- Code review: MINOR 1 stale RED prose removed from the four test files; MINOR 2 the contract test now also forbids `get_peer_data` / `peer_data` / `x_forwarded_for` outside the two `client_ip.ex` files; MINOR 3 the property loop counts the verified `:forwarded` results and asserts >= 20 of 250. INFO: I1 `peer_string/1` uses `to_string/1` for any `String.Chars` term (parity with the old `ip_key/1`), I2 a CIDR prefix with a leading zero (`/08`) is rejected, I3 the whole-value-ignored cases are reported as `whole value ignored (...)`, I7 the TP13 test filters feature lines instead of `log == ""`; I8 left as is.
- Kassandra #2 (code): new `Nebu.Web.ClientIP.bucket/1` (IPv4 = `get/1`; native IPv6 = canonical /64 network, e.g. `2001:db8:1:2::/64`; stored in `conn.private[:nebu_client_bucket]` by the plug, derived from `get/1` when the plug did not run). `RateLimit` and every OAuth `take/3` key (authorize, callback, token, refresh, jwks, register loose / invalid / strict, revoke, account) use `bucket/1`; `devices.last_seen_ip` and `oauth_clients.created_from_ip` keep the exact `get/1`. The contract test checks both sets of consumers and forbids `RateLimit.take(...ClientIP.get(...)`. New `Nebu.Web.RateLimitSweeper` (supervised, stateless, interval `:rate_limit_sweep_interval_ms` default 10 min, `:infinity` in the test env) calls `RateLimit.sweep_idle/0` (rows `{key, tokens, last_ms}` idle > 1 h; every bucket refills within an hour, so eviction grants nothing). The table is not owned by the sweeper; `sweep_idle/0` re-creates it. TP8 of the story is superseded by the ADR text (story text kept as written).
- Kassandra #1 / #3 / #4 (docs): 07-deployment and ADR-033 (TP8, TP14, alb / acme rows, Manual verification) reworded (empty or invalid list is safe, too-broad is not; LB trusted only when verified to append / overwrite; pinned nginx /32; ports on `127.0.0.1` before trusting the gateway; corrected Docker source-address description; IPv6; NEGATIVE test with `X-Forwarded-For: 203.0.113.99`; privacy / retention note); follow-ups: (am) ETS sweeping done, new ap4 (fallback to the proxy bucket, accepted residual) and ap5 (personal data). Pins added in `adr_033_test.exs` (non-vacuous: extracted sections and rows, `refute` of the old wording).
- Tests added: `rate_limit_sweeper_test.exs` (sweep of all key shapes, boundary, vanished table, fresh-bucket equivalence, timer-driven sweep, kill / restart with the table intact, supervised child), `bucket/1` unit tests, IPv6 /64 integration tests (shared login bucket within a /64, independent across /64, OAuth key, exact `created_from_ip`).

### File List

- server/lib/nebu/web/client_ip.ex (new)
- server/lib/nebu/web/plugs/client_ip.ex (new)
- server/lib/nebu/web/router.ex
- server/lib/nebu/application.ex
- server/config/runtime.exs
- server/lib/nebu/web/plugs/rate_limit.ex (cycle 1: `bucket/1` keys, `sweep_idle/0`)
- server/lib/nebu/web/rate_limit_sweeper.ex (new, cycle 1)
- server/config/test.exs (cycle 1: sweep interval `:infinity`)
- server/test/nebu/web/rate_limit_sweeper_test.exs (new, cycle 1)
- server/lib/nebu/oauth/{authorize,http,form_post,token,revoke,account}.ex
- server/lib/nebu/web/router/protected.ex
- server/lib/nebu/matrix/http_public.ex
- server/test/nebu/web/client_ip_test.exs, client_ip_integration_test.exs, client_ip_contract_test.exs
- server/test/nebu/oauth/adr_033_test.exs, oauth_test_support.exs
- docs/architecture/07-deployment.md, docs/architecture/08-concepts.md, docs/architecture/adr/ADR-033-authorization-server-broker-model.md
- docs/stories/oauth-broker/follow-ups.md, docs/stories/oauth-broker/oauth-trusted-proxy-client-ip.md
- _bmad-output/nebu/epics/oauth-broker/sprint-status.yaml

## Change Log

- 2026-10-12: story created (ready-for-dev).
- 2026-10-12: implemented (dev-story), status review.
- 2026-10-12: review cycle 1 (code review MINOR 1-3, Kassandra #1-#4): `bucket/1` (IPv6 /64), idle-bucket sweeper, doc and pin fixes.
