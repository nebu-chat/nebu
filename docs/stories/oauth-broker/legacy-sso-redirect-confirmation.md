---
story_id: legacy-sso-redirect-confirmation
title: "Legacy SSO redirectUrl: confirmation page for unlisted https targets, origin allowlist, stricter redirectUrl parsing (epic SEC gate 3, G3-3)"
type: feature
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: true
created: 2026-10-13
branch: feature/migrate-to-oauth2
---

## Summary

Epic SEC gate 3 (`docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-2026-10-13.md`,
finding **G3-3**, MEDIUM, pre-existing; follow-up row `by`, owner decision 2026-10-13: implement, including the
legacy behaviour change). The legacy SSO login (`GET /_matrix/client/v3/login/sso/redirect[/{idpId}]?redirectUrl=...`
-> IdP -> shared callback `.../sso/redirect/oidc` -> 30 s single-use `loginToken` -> `302 <redirectUrl>?loginToken=...`
-> `POST /login {"type":"m.login.token"}` = full session) accepts ANY `https` `redirectUrl`, with no approved client,
no device id and no consent, independent of `oauth_enabled`. A link
`https://<nebu>/_matrix/client/v3/login/sso/redirect?redirectUrl=https://evil.example/` plus an IdP login (often
silent: the IdP only sees `prompt=login`, which several IdPs ignore) hands the victim's `loginToken` to
`evil.example`: account takeover. The Matrix spec (CS API v1.18, "Handling the callback from the Authentication
server", Security considerations) says homeservers SHOULD confirm with the user that they want to grant access to
the site named in `redirectUrl`, and MAY allowlist known-trusted client URLs. Synapse does exactly this
(`sso.client_whitelist` + the `sso_redirect_confirm` page after the IdP login).

This story builds that mitigation:

1. **Stricter `redirectUrl` parsing at the redirect leg** (still `400`, byte-compatible bodies): closes parser
   differentials between `URI.parse/1` and browsers that are open redirects TODAY, among them
   `http://evil.example\@localhost/` (accepted today as "loopback", the browser goes to `evil.example` over plain
   http with the `loginToken`), `https://evil.example\@<listed host>/`, `https:evil.example` and `https:\\evil.example`;
   numeric-looking hosts must be canonical dotted-decimal IPv4.
2. **A confirmation page for every https target that is not listed**, placed after the IdP login and BEFORE a
   `loginToken` exists (Synapse model): "Continue sign-in to `https://host`?" with Continue / Cancel. Only Continue
   mints the `loginToken` and sends the browser to the target (`303`).
3. **An exact-origin allowlist** that skips the page: the server's own origin (`https://<server_name>`), the origin of
   `oauth_issuer_url` when configured, the REGISTERED https redirect URIs (and everything below them) of OAuth clients in status `approved`, and a new
   operator list `server_config.sso_redirect_allowed_origins` (Admin UI `/admin/config`, next to "SSO redirect
   schemes"). Listed targets, loopback `http://localhost|127.0.0.1[:port]`, the default deep-link schemes and the
   operator's extra schemes behave byte-identically to today (except that pre-existing `loginToken` parameters of
   the `redirectUrl` are now removed before the new one is appended, spec "should", D20).
4. **Migration 000048**: the `config_update_mutable` RLS allowlist gains `sso_redirect_allowed_origins` AND the
   pre-existing gap `sso_extra_redirect_schemes` (today a SECOND save of the SSO schemes form raises an RLS error).

### Operator impact (must appear in the release note, D-h)

Legacy (`m.login.sso`) clients whose `redirectUrl` is an https origin that is NOT the server's own origin, NOT the
configured `oauth_issuer_url` origin, NOT an approved OAuth client's redirect origin and NOT in
`sso_redirect_allowed_origins` show the confirmation page on EVERY login until the operator lists the origin.
Typical cases: a separately hosted Element Web (`https://element.example.com` while `server_name` is
`example.com`), `https://app.element.io`, SchildiChat / Cinny / Hydrogen / FluffyChat web builds served from other
hosts. Not affected: Element Web served on `https://<server_name>` (the reference deployment, cloud-init
`deploy/tofu/examples/*/cloud-init.tftpl`), Element Desktop (`element://`), SchildiChat (`schildichat://`), FluffyChat
native (`im.fluffychat.auth://`), operator-configured extra schemes, and every loopback native client. The INFO log line
`matrix SSO: redirect confirmation shown host=<host>` tells the operator which hosts to list.

> Note (2026-10-14): the order of checks and the per-IP bucket described in D9 / AC11 below are superseded by story `sso-confirm-bucket-order` (ADR-033 L9): the binding cookie is classified first and requests are counted per binding / per address for misses.

## Story

As a Matrix user of a Nebu server with legacy SSO login,
I want Nebu to ask me before it hands a sign-in token for my account to a web address it does not know,
so that a link someone sent me cannot silently log an attacker's site into my account.

As an operator,
I want to list the web client origins my users actually use,
so that those logins stay one click shorter and the confirmation only appears for unexpected targets.

## Decisions

- **D1 Classification of a `redirectUrl` (one function, two call sites).** New module `Nebu.Matrix.SsoRedirect`
  (Matrix-private, plain functions, no state) owns `classify/1`:
  `{:reject, reason_atom}` | `:direct` | `{:confirmable, target}` where `target = %{origin: "https://host[:port]",
  host: "host", port: integer | nil (nil = 443), path: String.t()}`.
  `:direct` = loopback http, a default deep-link scheme (`element`, `schildichat`, `im.fluffychat.auth`) or an operator
  extra scheme (`sso_extra_redirect_schemes`): unchanged behaviour, never a confirmation. Every syntactically valid
  `https` URL is `{:confirmable, target}`; whether it is LISTED is decided at the callback (D3, D4), not here (the
  allowlist may change during the 10 min IdP window; the decision uses the state at callback time).
  `SsoLogin.redirect_url_allowed?/1` stays (boolean, `@doc false`, used by existing tests) and becomes
  `classify(raw) != {:reject, _}`. The redirect leg (`SsoLogin.redirect/1`) calls `classify/1` exactly where it calls
  `redirect_url_allowed?/1` today; the error order (`M_MISSING_PARAM` first, then the rejection, then `action`) and the
  rejection representation (`reject_redirect/2`: JSON `400 M_INVALID_PARAM "redirectUrl scheme is not permitted"`, or
  the HTML page when `Accept` clearly prefers HTML, `render_html_error(scheme)`) are byte-identical; the WARNING
  `matrix SSO: redirectUrl rejected by allowlist` is unchanged (value-free).

- **D2 Stricter syntax (decided per case; "reject" = the unchanged `400`).** Rules, evaluated on the raw string (the
  SAME string that is stored in the SSO state and later used for the `Location`, so there is no differential between
  the checked and the used value):

  | Input | Today | Now | Why |
  |---|---|---|---|
  | longer than 2048 bytes (any scheme) | accepted | reject | bounded state/store entries; no real client sends more (oracle Q9) |
  | any byte `0x00-0x20` or `0x7F` (space, tab, CR, LF, NUL ...) anywhere, any scheme | partly accepted (`https://example.com\t/`, CR/LF in host) | reject | header injection / parser differential; browsers strip tab/LF silently |
  | backslash `\` anywhere, any scheme (whole-URL rule, like the control-byte and non-ASCII rules) | accepted | reject | WHATWG treats `\` as `/` in special-scheme URLs: `https://evil.example\@listed.example/` parses (Elixir) with host `listed.example`, the browser goes to `evil.example` |
  | `http`/`https` with any byte > 0x7F | accepted (`https://bücher.example/`) | reject | browsers convert the host to punycode (`xn--`); the page and the allowlist must see the ASCII form; clients send serialized (ASCII) URLs |
  | `http`/`https` not followed by exactly `//` (`https:evil.example`, `https:/evil.example`, `https:\\evil.example`) | accepted (scheme https) | reject | WHATWG accepts them as `https://evil.example/`; `URI.parse/1` sees no host |
  | `https://` with empty host (`https:///evil`) | accepted | reject | same |
  | userinfo (`@` inside the AUTHORITY, i.e. between `//` and the first `/`, `?` or `#`) for `http`/`https` (`https://element.example.com@evil/`, `http://127.0.0.1@evil/`, `http://x@localhost/`) | https accepted, http partly accepted | reject | classic display trick; no client sends userinfo. An `@` in the path, query or fragment is NOT checked (oracle m1: Element Web fragments such as `#/user/@bob:ex.org`) |
  | `%` inside the AUTHORITY (`https://%65vil.example/`) | accepted | reject | browsers percent-decode hosts; the displayed host would differ from the visited one. `%` in path / query / fragment stays accepted (oracle m1) |
  | numeric-looking https host (ONLY when the LAST label is all digits or `0x`/`0X`-prefixed hex: `https://0x7f.0.0.1/`, `https://2130706433/`, `https://10.1/`, `https://010.0.0.1/`, `https://1.2.3.256/`) | accepted | reject unless it is CANONICAL dotted-decimal IPv4 (exactly four labels, each `0..255`, no leading zero): `https://10.0.0.5:8443/` stays confirmable | oracle m2: WHATWG parses such hosts as IPv4 (hex, octal, fewer than four parts), so the displayed / compared host would differ from the visited address. Normal hosts (last label not numeric): `https://1.example/`, `https://a-1.example/`, `https://0xample.example/` (confirmable); `https://10.0.0.0/` is canonical IPv4 (confirmable); `https://example.123/` is rejected (numeric last label, not canonical IPv4) |
  | https host not matching `[a-z0-9-]+(\.[a-z0-9-]+)*` (case-insensitive; this rejects `_`, a trailing dot `evil.example.`, empty labels, IPv6 literals `[::1]`) | accepted | reject | the target must be a valid CSP host-source for `form-action` (D9) and must compare exactly against the allowlist; IPv4 literals stay accepted (confirmable) |
  | port not `1..65535` decimal (`:0`, `:99999`, `:` empty, non-digits) | accepted (`URI.parse` tolerates) | reject | browsers reject or normalize differently |
  | `https://host:443/...`, `https://HOST/`, `HTTPS://host/` | accepted | confirmable, origin `https://host` (lower-case, default port dropped) | default-port and case equivalence; the raw string is still the one used in `Location` |
  | `http://localhost[:port]`, `http://127.0.0.1[:port]` (host compared case-insensitively, no userinfo, no backslash, valid port) | accepted | `:direct` (unchanged) | RFC 8252 native clients; residual: a local process on the victim's own machine (D18) |
  | `http://localhost:/` (empty port), `http://localhost%2f@evil/` (`%`/`@` in the authority) | accepted | reject | authority rules apply to loopback too |
  | `http://localhost.evil.example/`, `http://127.1/`, `http://0x7f000001/`, `http://0x7f.0.0.1/`, `http://2130706433/`, `http://localhost./`, `http://[::1]:8080/` | rejected | reject (unchanged) | loopback lookalikes; `[::1]` is NOT added (no widening in a security story, follow-up) |
  | deep-link / extra scheme (`element://...`, `im.fluffychat.auth://...`) | accepted | `:direct` (unchanged, plus the length / control / backslash rules) | |
  | accepted shapes the stricter rules must NOT break (oracle m1): `https://app.ex/#/user/@bob:ex.org`, `https://app.ex/#/room/#a:ex.org`, `https://app.ex/p%20q?x=%2F`, `https://app.ex?x=1#/login`, `https://app.ex?next=a@b/c`, `https://app.ex#@x/y`, `https://app.ex/p@q`, `https://app.ex/?e=a@b` (the authority ends at the first `/`, `?` or `#`), `element://vector/webapp/?element-desktop-ssoid=abc#/login`, `http://localhost:3001//login` | accepted | unchanged (confirmable / `:direct` / `:direct` respectively) | real client shapes (Element Web, Element Desktop, FluffyChat desktop) |
  | denylisted schemes (`javascript`, `data`, `file`, `vbscript`, `blob`), unknown schemes, relative URLs | rejected | reject (unchanged) | |
  | `redirectUrl[]=...` / map value | `400 M_MISSING_PARAM` | unchanged | not a binary |
  | repeated `redirectUrl=a&redirectUrl=b` | Plug: last wins | unchanged (last wins); the checked value IS the stored value | pinned by a test (the LAST value is classified and confirmed) |
  | internal UIA marker `https://uia.local/complete` | never classified (`uia_fallback/1` calls `do_redirect/3` directly) | unchanged: never classified, never confirmed (D16); a CLIENT-supplied `redirectUrl=https://uia.local/complete` is an ordinary unlisted https target (confirmation) | |

  The HTML rejection page keeps naming only the parsed scheme (for a malformed https URL it says "https"; accepted
  wording imprecision, byte-compatibility wins).

- **D3 Placement: callback, after the IdP login, before any `loginToken`; PRG to a GET page (refinement of the brief).**
  In `SsoLogin.do_callback/3`, in the non-UIA branch, BEFORE `SsoStore.put_login_token/4`:
  `classify(entry.redirect_url)`: `:direct` -> today's code path (`302`, `cache-control: no-store`,
  `location: append_login_token(...)`; byte-identical except the D20 removal of pre-existing `loginToken`
  parameters); `{:confirmable, t}` and `listed?(t.origin)` -> the same `302`;
  `{:confirmable, t}` and not listed -> NO `loginToken` is minted, NO redirect to the target: a pending-confirmation
  entry is stored (D7), the binding cookie is set (D8) and the callback answers `303 See Other`
  `Location: /_matrix/client/v3/login/sso/confirm` (relative path, flow headers D9). `GET /_matrix/client/v3/login/sso/confirm`
  renders the page from the live entry (peek, mutates nothing; a reload is safe), `POST` on the same path decides.
  Deviation from the brief ("renders a confirmation page" at the callback): the PRG step mirrors the OAuth consent
  flow (`Nebu.OAuth.Authorize` -> `303 /oauth2/consent`), keeps the IdP `code`/`state` out of the address bar, the
  history and the page's `Referer`, and makes a reload work (re-requesting the callback URL would hit a consumed
  state). A stored `redirect_url` that no longer classifies (cannot happen for states created after the deploy; a
  state created by an older node during a rolling deploy can) -> the `403 M_FORBIDDEN "SSO login failed"` JSON of
  today's failure branch, no token, one value-free WARNING.

- **D4 Allowlist: exact ORIGIN match, evaluated in this order, first hit wins, fail closed.** Match = equality of
  the normalized origin string `https://<lower-case host>[:<port> unless 443]`; no wildcards, no paths, no subdomain
  rule, no `http`. Sources:
  1. AUTO, no I/O: `https://<server_name>` from `Application.get_env(:nebu_http, :server_name)` (Matrix
     `server_name` may carry a port: `host[:port]`; an unparsable value contributes nothing). The request `Host`
     header is NEVER used (an attacker domain pointing at the same IP could otherwise list itself). Oracle m4:
     `https://<server_name>` is trusted AUTOMATICALLY, so it must be an origin the operator controls. With
     `.well-known` delegation (`server_name` = `example.com`, Nebu at `matrix.example.com`) the apex
     `https://example.com` (often a marketing site / CMS) receives login tokens without confirmation; the Admin help
     text (D14) and the 07-deployment runbook say so explicitly.
  2. EXPLICIT, no I/O: the operator list `sso_redirect_allowed_origins` (D5), read through the
     `Nebu.Web.OidcConfig` ETS cache.
  3. AUTO, only when 1 and 2 did not match: `Nebu.OAuth.trusted_redirect_url?(origin, raw_redirect_url)` (D6): the
     ORIGIN of `oauth_issuer_url` when configured (also while `oauth_enabled` is off; no DB read), and, by REGISTERED
     URI rather than by origin (security review SEC #1), the https `redirect_uris` of `oauth_clients` rows in status
     `approved`: the raw `redirectUrl` must equal a registered redirect URI or extend it at a path boundary (D6).
     `pending`, `rejected`, `revoked` never count. Any error, timeout or exception => `false` => confirmation page.
  Independent of `oauth_enabled`. The legacy login's own login fallback does not exist in Nebu (Synapse lists it),
  nothing else is auto-listed.

- **D5 Operator list `server_config.sso_redirect_allowed_origins` (ADR-022: server_config only, no env var).**
  Stored as normalized, comma+space separated origins (`https://chat.example.com, https://web.example.com:8443`);
  absent or `""` = empty list. Validation in ONE place, `Nebu.Matrix.SsoRedirect.normalize_origin_list/1`
  (`{:ok, normalized_string}` | `{:error, message}`), exposed to the Admin domain ONLY as
  `Nebu.Matrix.normalize_sso_redirect_origins/1` (ADR-020). Rules per comma-separated token (split WITHOUT trim;
  each token trimmed of ASCII space and tab ONLY, as `trim_space_only/1` in `ConfigController`, so `\n` is caught):
  empty token -> error; the regex is `\z`-anchored (codebase rule); scheme `https` only (case-insensitive); no
  userinfo, query, fragment, wildcard `*`, path other than an optional single trailing `/` (dropped); host = the D2
  https host rule (ASCII only, `xn--` allowed, no trailing dot, no IPv6 literal); port `1..65535`, `:443` dropped;
  lower-cased; duplicates removed (first occurrence kept, order preserved); at most 50 origins and 4096 characters
  overall. Error messages name the offending token truncated to 80 characters (rendered escaped by HEEx; never
  logged). At request time the stored string is parsed with the SAME normalizer per token; a token that does not
  normalize (hand-edited DB) is ignored (never widens). Cache: `Nebu.Web.OidcConfig` gains the key in
  `@empty_config`, `@sql_load_oidc_config`, `load_from_db/0` (via `nilify/1`) and a getter
  `get_sso_redirect_allowed_origins/0` (same shape and ETS fallback as `get_sso_extra_redirect_schemes/0`);
  `Nebu.Admin.DB.@scope_cache_keys` gains the key, so a save triggers `OidcConfig.refresh/0` + the `:pg`
  invalidation broadcast to every node (the existing cluster-wide path). DB read failure in `load_from_db/0` ->
  `@empty_config` -> empty list -> confirmation (fail closed).

- **D6 Issuer origin and approved clients' REGISTERED URIs through the OAuth public API (ADR-020; amended by security
  review SEC #1, cycle 1).** New `Nebu.OAuth.trusted_redirect_url?(origin, raw_redirect_url) :: boolean` with `@doc`
  (the Matrix domain's only new question to the OAuth domain besides `parse_form_post/1` and the existing
  `check_fetch_metadata/2`; it replaced the cycle-0 `trusted_redirect_origin?/1`). `origin` is the normalized origin
  the caller derived from the SAME parse as the raw URL (`https://host[:port]`, lower case, default port dropped);
  both must be well-formed https values, else `false`. Implementation in the OAuth domain: (a) the issuer, read through
  `Nebu.OAuth.Config.configured_issuer/1` (bounded, normalized with `Metadata.normalize_issuer/1` inside `config.ex`),
  matched by ORIGIN for any URL on it, with no DB read; (b) approved clients by REGISTERED URI: an approval covers an
  exact redirect URI (scoped code, consent, device), not its whole origin, so trusting the origin would let an
  approval of `https://storage.example/<bucket>/cb` turn `https://storage.example/<attacker-bucket>/x.html` into a
  silent loginToken sink. The raw URL is trusted when a registered `https` redirect URI has the same normalized
  origin and the part after the authority EQUALS the registered one or starts with it where the next character is `/`,
  `?` or `#` (or the registered URI itself ends with `/`); the path is compared case-sensitively; a URL whose path has
  dot segments or an encoded dot / slash / backslash (`%2e`, `%2f`, `%5c`) never matches (it could climb out of the
  registered path). `ClientStore.approved_redirect_uris/1`: ONE query with `timeout: 500, pool_timeout: 500`
  (the `Config` bounded idiom) that expands the jsonb array `metadata->'redirect_uris'` with
  `jsonb_array_elements_text` (production stores an object-typed jsonb; any other shape contributes nothing), narrowed
  by host with an escaped `lower(u) LIKE 'https://<host>%' ESCAPE '\'`, `status = 'approved'`, `LIMIT 50`; the exact
  comparison happens in Elixir. Errors / timeouts / exceptions => `false` + ONE value-free WARNING `OAuth: trusted
  redirect origin lookup failed` (never the origin or the URL). No cache (an approve or revoke takes effect
  immediately). Oracle Q12: acceptable; caveat recorded in D19 (a legacy loginToken yields a full, unscoped session,
  broader than what the OAuth approval granted, which is why the match is the registered URI, not the origin). The
  test seam `:sso_trusted_origin_check` is a 2-arity `fn origin, raw_url -> boolean | raise`.

- **D7 Pending entry in `Nebu.Matrix.SsoStore` (recorded decision, no migration table).** New tag `:confirm`:
  `put_confirm(key, entry, ttl_seconds) :: :ok | {:error, :store_full}`, `peek_confirm(key) :: {:ok, entry} |
  :error`, `pop_confirm(key) :: {:ok, entry} | :error` (single-use delete + tombstone broadcast, exactly
  `do_pop/2`). Key = `{:confirm, SHA-256(cookie value)}` as the RAW 32-byte digest (`:crypto.hash(:sha256, cookie)`, no hex; the
  cookie itself is never stored).
  Entry = `%{id_token, oidc_refresh_token, redirect_url, origin, host, port, path, user_id}` (`user_id` derived for
  display with `Nebu.Matrix.UserId.from_claims(claims, server_name)`, the derivation `complete_uia/3` uses; no
  provisioning happens before Continue + `POST /login`). TTL **300 s**, cap **10 000** `:confirm` entries per node
  (own counter, like `@max_token_entries`; `store_full` or `{:error, :unavailable}` -> the callback answers the `503 unavailable` page, nothing
  minted). Same cluster properties as the loginToken store: `pg`-replicated to every node, single-use atomic per
  node, best-effort across nodes (two POSTs of the SAME browser racing on two nodes inside the replication window
  could both mint a loginToken for the same target the user confirmed; bounded by possession of the binding
  cookie, D8), volatile (a full restart loses pending confirmations: the user restarts the login). This deviates
  from the epic hard rule "single-use consumption must be atomic SQL" in the same way the existing `loginToken`
  store does; the confirm entry guards a LESS powerful artefact than the loginToken it precedes. The IdP refresh token
  stays in memory only (as in the loginToken store today), never at rest, never logged.
  **Hardening of the store (small, in scope):** `SsoStore` implements `format_status/1` (OTP 25+ / Elixir
  `GenServer` callback) so a crash report never prints a `:put_token` / `:put_confirm` / `:replicate_put` message
  payload or table contents (pre-existing exposure for the loginToken message, now also for the confirm entry).
  Review cycle 1 (security review SEC #2, Logging Law): every `SsoStore` call catches the `:exit` of its
  `GenServer.call` (default 5000 ms; compile-guarded seam `:nebu_http, :sso_store_call_timeout_ms`): `put_*` answers
  `{:error, :unavailable}`, `pop_*` / `peek_*` answer `:error`, so a flooded or missing store can never crash the
  REQUEST process with the call message (id_token, IdP refresh token, redirect URL, loginToken) in its crash report.
  The redirect leg answers `503 M_UNAVAILABLE`, the callback and confirm routes their existing 503 / 400 pages.

- **D8 Binding cookie and CSRF (mirrors `Nebu.OAuth.Consent`, FR8).** Value = 32 random bytes, base64url without
  padding (43 chars, checked with `\A[A-Za-z0-9_-]{43}\z`). On an https request (`Nebu.Web.RequestScheme.https?/1`)
  `__Host-nebu_sso_confirm` (`Path=/; Secure`), else `nebu_sso_confirm` (`Path=/_matrix/client/v3/login/sso/confirm`);
  always `HttpOnly; SameSite=Lax; Max-Age=300` (Strict would not be sent on the `303` that ends the IdP's cross-site
  redirect chain). On https ONLY the `__Host-` name is read (cookie tossing). CSRF token =
  `base64url(SHA-256("nebu-sso-confirm-csrf:" <> cookie))`, rendered in the form, compared with
  `Plug.Crypto.secure_compare/2`, nothing stored. One pending confirmation per browser: a second flow overwrites the
  cookie (the first entry expires unused). The cookie is cleared on Continue, Cancel and every definite
  `invalid_state` answer; it stays on `forbidden`, `invalid_request` and `rate_limited` (nothing was consumed, a
  retry from the same page can work). `unavailable` AFTER Continue (the loginToken store is full or does not answer, SEC #2): the entry was
  already consumed (D7: pop before mint), so the cookie is CLEARED, the entry is never re-inserted, and a following
  Continue answers `400 invalid_state`. The callback-side `503` (confirm store full, AC4.4) happens before any cookie
  exists, so there is nothing to clear.

- **D9 Page and POST hardening (as the consent page, story oauth-authorize-freshness / P3).**
  New Matrix-private modules `Nebu.Matrix.SsoConfirm` (request handling) and `Nebu.Matrix.SsoConfirmPage`
  (rendering, standalone HTML, no admin layout, no external resource, no image, no link to the target, no
  `autofocus`). Headers of every response of the route (page, cancel page, error pages and the `303`s; also the
  callback's `303`): `Cache-Control: no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, NO
  `access-control-*` header on the page, the cancel page, the error pages and the `303`s (the only exception is the
  existing fall-through answer to `OPTIONS`, D11), `text/html; charset=utf-8` for pages, and NO `Cross-Origin-Opener-Policy` header
  (oracle M1, deviation from the consent page: popup-based web clients such as FluffyChat web open the SSO flow with
  `window.open` and receive the result through `window.opener.postMessage` from their own target page; COOP
  `same-origin` on any response of the chain severs `window.opener` and breaks their login. Framing stays blocked by
  `X-Frame-Options` + `frame-ancestors`; the opener-based attacks COOP would stop are covered by the arming of D9's
  script and by the page naming the target).
  - CSP of the confirm page: `default-src 'none'; style-src 'sha256-<css>'; script-src 'sha256-<script>'; img-src
    'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self' https://host[:port]`. `form-action` is KEPT
    (not omitted): Chromium applies it to the redirect after the form POST, and the only redirect target of this
    form is the confirmable https origin (built ONLY from the parsed components of D2, so a hostile value can never
    reach the header); Cancel answers on `'self'`. The cancel and error pages: `default-src 'none'; style-src
    'sha256-<css>'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, no script.
  - `Referrer-Policy: same-origin` on the confirm page (deviation from the brief's `no-referrer`: with `no-referrer`
    the page's OWN form POST carries `Origin: null`, which the Origin check could then only accept via
    `Sec-Fetch-Site`; the page URL carries no secret), `no-referrer` on every other response including the `303` to
    the client target (the target never learns the confirm URL).
  - Arming against double-click / multi-gesture clickjacking (G3-5 class), extended per oracle m5. ONE inline
    script, pinned by its SHA-256 in the CSP, defined ONCE in a new shared-infrastructure module
    `Nebu.Web.ArmScript` (`script/0`, `css_hint/0` if needed; `Nebu.Web` is shared by all domains, so the later
    G3-5 change of the consent page can use the byte-identical script without a Matrix <-> OAuth dependency; the
    consent page itself is NOT changed by this story). The script is generic: it arms the single element marked
    `data-arm` (here Continue, `id="continue"`) and shows / hides the element `data-arm-hint`. Rules:
    (a) Continue is rendered `aria-disabled="true"` (never the `disabled` property: UX B1, a screen-reader
    touch-exploration user must be able to reach it and hear why it is not available), aria-described by the hint
    (`id="arm-hint"`, visible by default, hidden on arming), the target origin and the notice; it becomes ARMED
    (`aria-disabled="false"`) only >= 600 ms after load AND after real interaction on the page that is NOT on Continue
    itself: a pointer move of >= 4 px (mouse / pen), a key press, a wheel or scroll event, a `focusin` on another
    element, or (touch devices, which emit no `pointermove` without contact) a `touchstart` or a `pointerdown` with
    `pointerType == "touch"` whose target is not Continue. A polite live region `<p role="status" data-arm-status>`
    (empty in the markup) announces "Continue is now available." and, for a blocked click, why (B2). The button also
    carries `form="sso-confirm-armed"` (no such form) which arming removes, so with JavaScript off Continue stays inert
    (fail closed, D19c) although it is not `disabled`.
    (b) G3-5 hardening for mouse / pen: after arming, an activation of Continue is accepted only if a `pointerenter`
    on Continue (pointerType `mouse` or `pen`) happened AFTER the arming moment; otherwise the script calls
    `preventDefault()` on the `click` (the pointer must visibly travel onto the button after it became active, which
    a double-click lure that parks the pointer on the spot cannot provide).
    (c) Touch: a tap on Continue after arming is accepted (touch has no hover; the arming touch had to land
    elsewhere, rule a). Keyboard (security review SEC #4): an activation without a pointer (`click` with `detail ==
    0`, Enter / Space on the focused button) is accepted only when the focus moved ONTO Continue after the arming
    moment (a `focusin` on it); otherwise the click is cancelled and the live region says so, so a blind "Tab, Tab,
    Enter" lure cannot hit it. Residual: multi-tap touch lures (follow-up `cp`).
    (d) Cancel is never disabled and comes FIRST in DOM and visual order; `<noscript>` explains that Continue needs
    JavaScript (fail closed: only Cancel; recorded in D19). Every page has its own static `<title>` (UX N5). Plain ES5, no network, no DOM injection, NO comments in
    the pinned script bytes (comments live in the Elixir module). The server
    never trusts the button state.
  - POST checks, ALL before anything is consumed, in this order: per-IP bucket -> form parse (`400
    invalid_request`) -> `decision in ["continue", "cancel"]` (`400 invalid_request`) -> Origin + fetch metadata
    (`403 forbidden`) -> binding cookie present and well-formed (`400 invalid_state`) -> CSRF token (`403
    forbidden`) -> `SsoStore.pop_confirm/1` (single use, BEFORE minting).
  - Form parse: `Nebu.OAuth.FormPost.parse/1` semantics (non-empty query string, wrong content type, body > 16 KiB,
    malformed encoding, duplicated parameter, control characters => error) reached through a NEW public delegate
    `Nebu.OAuth.parse_form_post/1` (`@doc`; ADR-020: the Matrix domain never names `Nebu.OAuth.FormPost`). The raw
    body is read exactly once there; `Nebu.Web.Plugs.JsonBody` skips the path (so `body_params` stays `Unfetched`
    and `RequestLogger` never captures the CSRF token).
  - Fetch metadata: the existing public `Nebu.OAuth.check_fetch_metadata(conn, :lenient)` (absent allowed, a
    present `Sec-Fetch-Site` must be `same-origin`, `-Mode` `navigate`, `-Dest` `document`, `-User` `?1`, each at
    most once). The Origin rule is local to `Nebu.Matrix.SsoConfirm` (the page has no OAuth issuer): no `Origin`
    header -> ok; `Origin: null` -> ok only with `Sec-Fetch-Site: same-origin`; one `Origin` -> ok when it equals the
    request's own origin (`Nebu.Web.RequestScheme.scheme/1` + `://` + the `Host` header, lower-cased, default port
    dropped; using `Host` is correct HERE: it is a same-origin test of a request that must carry the `__Host-`
    cookie set by this very origin), OR `https://<server_name>` (with its port), OR the browser sends `Sec-Fetch-Site:
    same-origin` (code review MIN-2: behind a reverse proxy the `Host` may differ from the one the browser used; the
    reference nginx sets `Host $host`, which drops the port; operators must forward the original `Host`; a
    cross-site request still fails the fetch-metadata rule whatever its Origin); several `Origin` headers ->
    refused. (Alternative considered: moving
    `BrowserPost` to `Nebu.Web`: larger refactor of the consent / account code for no security gain.)
  - Rate limit: `Nebu.Web.Plugs.RateLimit.take({"sso_confirm", Nebu.Web.ClientIP.bucket(conn)}, 10, 600)` (600/h,
    the consent numbers) for GET and POST; `429` page with `Retry-After`; nothing consumed, cookie kept.
  - Pages never render a request value except the D15 display fields (escaped with `Plug.HTML.html_escape/1`);
    error pages render no value at all.

- **D10 Outcomes.**
  - **Continue**: `pop_confirm` -> `SsoStore.put_login_token(opaque, id_token, 30, oidc_refresh_token: rt)`
    exactly as the callback does today (if it returns `{:error, :store_full}`: the `503 unavailable` page, no
    redirect) -> `303 See Other` (never 302/307), `Location: SsoLogin.append_login_token(redirect_url, opaque)`
    (fragment aware, with the D20 removal of pre-existing `loginToken` parameters), D9 flow headers, cookie cleared.
    The client then continues with today's `POST /login` (`m.login.token`), unchanged.
  - **Cancel**: `pop_confirm` -> `200` page `data-page="sso-confirm" data-result="cancelled"`, h1 "Sign-in
    cancelled", "No access was given. You can close this window.", no token, cookie cleared.
  - Missing / unknown / expired / consumed entry -> `400 invalid_state` page ("This sign-in link has expired or was
    already used. Start signing in again from your app."), cookie cleared.
  - Listed and `:direct` targets never see any of this (D3).

- **D11 Routing.** `Nebu.Matrix.HttpPublic` gains `get "/sso/confirm"` and `post "/sso/confirm"` (the router
  forwards `/_matrix/client/v3/login`; place them with the other `/sso/*` clauses, BEFORE the
  `match _, private: %{nebu_unrecognized: true}` fall-through; `/sso/confirm` cannot collide with
  `/sso/redirect/:_idp`). Other methods on the exact path get the existing fall-through answer `405 M_UNRECOGNIZED`
  with `Allow: GET, POST, OPTIONS` (the probe finds both clauses; no new code), a non-preflight `OPTIONS` `204`,
  sub-paths `404 M_UNRECOGNIZED`. `Nebu.Web.Router.cors/2` gets a skip clause for
  `["_matrix", "client", "v3", "login", "sso", "confirm" | _]` (browser navigation, no `access-control-*` headers,
  a preflight is not answered by CORSPlug; it reaches the existing fall-through, which answers `204` + `Allow: GET,
  POST, OPTIONS` and keeps its existing `access-control-allow-origin: *`: inert without `allow-methods` /
  `allow-headers`, and the same-origin form POST needs no preflight; NO new code in `Nebu.Web.Unrecognized`).
  `Nebu.Web.Plugs.JsonBody` gets a skip clause for the same path. The
  route lives under `/_matrix/`, which every reference nginx template already proxies
  (`deploy/tofu/examples/*/cloud-init.tftpl`, `docker/nginx-*-e2e.conf`); no proxy change. A Nebu-specific path in
  the spec's `/_matrix/client/v3/login` namespace is a recorded choice (oracle Q6).

- **D12 Logging (Logging Law).** Never logged: `loginToken`, `id_token`, IdP refresh token, the binding cookie, its
  hash, the CSRF token, the redirect URL's path / query / fragment, the `Location` header. New lines:
  `INFO matrix SSO: redirect confirmation shown host=<host>` (callback), `INFO matrix SSO: redirect confirmation
  confirmed host=<host>` / `... declined host=<host>` (POST), where `<host>` is the D2-validated ASCII host (charset
  `[a-z0-9.-]`, so no escaping issue; truncated to 253 chars) with `:port` when not 443. Value-free WARNINGs:
  `matrix SSO: confirmation request refused (the origin, fetch-metadata or CSRF check failed)`, `matrix SSO:
  confirmation store full`. `Nebu.Web.Plugs.RequestLogger`: add `/_matrix/client/v3/login/sso/confirm` to
  `@names_only_query_paths`; the request body is never captured (JsonBody skip, D9); responses are HTML (not
  captured) or bodiless `303`s; `Location` / `Set-Cookie` are not part of the capture today (pin it with a test).
  The existing `sso_redirect_path?` masking of `action` (story oauth-legacy-coexistence L-2) is unchanged; the
  callback path stays names-only.

- **D13 Migration `000048_config_sso_redirect_keys_mutable` (`.up.sql` + `.down.sql`; 000048 is free, 000047 is the
  latest; committed migrations are never edited).** Up: `DROP POLICY IF EXISTS config_update_mutable ON
  server_config; CREATE POLICY config_update_mutable ON server_config FOR UPDATE USING (key IN (<list>) OR key LIKE
  'log\_min\_level\_%' OR key LIKE 'log\_retention\_days\_%');` with `<list>` = **000042's list VERBATIM** (the latest
  re-creation of the policy; the brief named 000040, but 000042 added `oauth_access_token_ttl_seconds` and
  `oauth_idp_revalidation`, which must not be dropped) plus `'sso_extra_redirect_schemes'` (pre-existing gap: the
  key was never added; `upsert_server_config/1`'s `INSERT ... ON CONFLICT DO UPDATE` on an existing row then fails
  the UPDATE `USING` check, which PostgreSQL raises as an RLS error for `ON CONFLICT DO UPDATE`, so the second save
  of the SSO schemes form crashes today) plus `'sso_redirect_allowed_origins'`. Down: restores 000042's policy
  verbatim (existing rows of the two keys stay, write-once again). No `INSERT` of values, no `BEGIN`/`COMMIT`, no
  `CONCURRENTLY`, no other object touched. Header comment: rationale, rolling-deploy safety (old nodes never write
  the new key), the reset hint for the throwaway DB.

- **D14 Admin UI.** `/admin/config` gets a form `id="sso-origins-form"` (POST `/admin/config/sso-origins`, Phoenix CSRF
  token, `Nebu.Admin.Auth :require_admin` like every action of the controller) directly after the "SSO redirect
  schemes" form: h2 "SSO redirect origins", one text input `name="sso_redirect_allowed_origins"`, visible label
  "Allowed SSO redirect origins" (also `aria-label`), placeholder `https://element.example.com,
  https://app.element.io`, help text: "Comma-separated https origins (scheme, host and optional port; no path or
  wildcard). Only list origins you control. Legacy SSO logins that return to one of these origins skip the
  confirmation page and receive a sign-in token with full access to the account. Always allowed without listing:
  https://<server_name> (rendered with the configured value; it must be an origin you control, which matters when
  the server name is delegated via .well-known to another host), the OAuth issuer origin when configured, and the
  redirect origins of approved OAuth clients (their legacy logins get a full, unscoped session). Other https origins
  see a confirmation page on every login." Button "Save SSO origins".
  `ConfigController.save_sso_origins/2` mirrors `save_sso_schemes/2`: validate (via `Nebu.Matrix.
  normalize_sso_redirect_origins/1`) BEFORE any write; error -> `200` re-render with the flash error, nothing
  persisted; ok -> persist the NORMALIZED string through the seam `:admin_config_sso_origins_writer` (a NEW seam, so
  compile-guarded with `if Mix.env() == :test` per AC17; the controller's three existing writer seams stay as they
  are) or `Nebu.Admin.DB.upsert_server_config/1`, flash "SSO origins
  saved", redirect `/admin/config`; persistence failure -> flash "Failed to save SSO origins". `ConfigHTML` gains
  `sso_origins_value/2`. The page keeps WCAG 2.1 AA (label, focus, no colour-only meaning).

- **D15 What the page shows (display rules).** `<main data-page="sso-confirm" data-result="pending">`, static
  `<title>Confirm sign-in</title>`, ONE `<h1>` "Continue signing in to this app?", then:
  "You are signed in as <strong data-role="user-id">@alice:example.com</strong>.";
  a `<dl>`: "The app asks to be sent to" -> `<dd class="key" data-role="target-origin">https://host[:port]</dd>`
  (ASCII host as validated by D2, so an IDN appears in its `xn--` form, plus the line "This address contains an
  internationalized name, shown in its xn-- form." when any label starts with `xn--`; port only when not 443);
  "Path" -> the raw path (as received, percent-encoded form) truncated to 60 characters + "..." , omitted when empty
  or `/`; NEVER the query or fragment.
  A notice (text label "Warning:", not colour only): "Continuing gives the app at this address full access to your
  Matrix account: it can read and send messages as you. Only continue if you just started signing in to this app
  yourself and you recognise the address. If you did not, choose Cancel." Form `method="post"
  action="/_matrix/client/v3/login/sso/confirm"` with hidden `csrf_token` and two equal-weight
  `<button type="submit" name="decision" value="cancel">Cancel</button>` then
  `<button ... value="continue" id="continue" disabled>Continue</button>`. 44 px touch targets, visible focus
  outline, works at 320 px, `lang="en"`, viewport meta. Error pages: `<main data-page="sso-confirm-error"
  data-error="invalid_state|forbidden|invalid_request|rate_limited|unavailable">`, one h1, a plain explanation, "What
  you can do" list, no request value.

  Review cycle 1 amendments (UX gate N8-N10, security review SEC #5): the field has a real `<label for="sso-origins-input">` (no
  `aria-label`) and is aria-described by the help block `<div id="sso-origins-help">` (short sentence, a bold "Only list origins you
  control.", the always-allowed sources as a list: `https://<server_name>` in `<code>` with the delegation caveat, the OAuth issuer origin,
  the REGISTERED redirect URIs of approved OAuth clients and the paths below them (D6), then the cross-reference to the SSO redirect schemes
  form); a rejected save re-renders the SUBMITTED text in the field with `aria-invalid="true"` and the error in `<p id="sso-origins-error"
  role="alert">` (the flash stays); a successful save writes ONE compliance audit row through the `:compliance, :audit_writer` seam
  (`sso_redirect_origins_changed`, target `server_config` / `sso_redirect_allowed_origins`, metadata `origins` = the new normalized list and
  `count`, actor = the admin's Matrix id; a rejected value or a failed write writes none; a failing writer never undoes the save).

- **D15 amendments (cycle 1, UX gate B1 / B2 / N1-N6).** The notice no longer carries `role="status"` (only `[data-arm-status]` is a
  live region) and says why the page appears, what Cancel does and that the request expires in 5 minutes; the target origin is a `<code>`
  (`id="target-origin" data-role="target-origin"`); the IDN note reads "This address uses special characters, which can be used to imitate
  another address. It is shown in a technical form starting with xn--. Check it carefully."; the noscript text is "JavaScript is off, so Continue
  stays unavailable. Turn on JavaScript or use another browser. You can still choose Cancel."; every page has its own static `<title>`
  (Confirm sign-in / Sign-in cancelled / Sign-in link expired / Sign-in request refused / Too many requests / Sign-in unavailable).

- **D16 UIA fallback and OAuth branch untouched.** The `o2.`-tagged state still goes to
  `Nebu.OAuth.handle_idp_callback/1` before anything of the legacy branch; a state with `uia_session` still renders
  the UIA completion page (`complete_uia/3`) and is never classified or confirmed (the marker
  `https://uia.local/complete` is only a placeholder in the state entry). `POST /login` (`m.login.token`, `do_login`
  -> `SsoStore.pop_login_token/1`) is unchanged.

- **D17 Docs (written by the orchestrator after dev; listed in Dev Notes, not part of the dev diff).**

- **D18 Accepted residuals (named in ADR-033 and 07-deployment).** (a) Loopback `http://localhost|127.0.0.1` and
  deep-link / extra schemes are NOT confirmed: a malicious LOCAL process on the victim's machine listening on a
  loopback port, or an app that registered a listed custom scheme, can still receive a loginToken (RFC 8252 class;
  same as today). (b) A user who reads the page and clicks Continue for an attacker origin is not protected
  (social engineering; the page names the origin prominently and warns). (c) Every login to an unlisted origin
  shows the page until the operator lists it (the price of the fix). (d) Cross-node single use is best effort (D7).
  (e) A listed origin hosting attacker-controlled content (e.g. a shared hosting origin) is trusted by listing it:
  the help text says "origins you control"; the same holds for the automatically trusted `https://<server_name>`
  (D4, oracle m4). (f) No COOP on this flow (D9, oracle M1): an opener relationship survives by design.

- **D19 Oracle INFO items (recorded, no further change).** (a) Route `/_matrix/client/v3/login/sso/confirm` is not
  forbidden by the spec; kept under `/_matrix/` because a vendor prefix would need nginx template changes (D11).
  (b) loginToken lifetime 30 s (spec: SHOULD be around 5 s) is kept; the deviation is recorded in
  `docs/matrix-api-scope.md`. (c) Continue requires JavaScript; JS-off WebViews can only Cancel (fail closed).
  (d) Auto-listing approved OAuth clients for the legacy flow is acceptable, with the caveat that a legacy
  loginToken yields a full, unscoped session: stated in the Admin help text (D14) and the docs. (e) The HTML 400
  page keeps its old "scheme not permitted" wording for every rejection (byte-compatibility). (f) An unknown
  `{idpId}` is redirected to the one IdP instead of answering 404 (pre-existing, unchanged; noted in
  `docs/matrix-api-scope.md`).

- **D20 Remove pre-existing `loginToken` parameters (oracle m3, spec "should be removed before adding the new
  one").** `SsoLogin.append_login_token/2` drops every `loginToken` query parameter of the base (the part before the
  first `#`) before appending the new one; a `loginToken=` that appears inside the FRAGMENT (`#/login?loginToken=old`,
  Element Web's hash routing) is removed as well (in the fragment's own `?` query part). Only parameters whose name
  is exactly `loginToken` (after percent-decoding the name) are removed; every other parameter, its order and its
  encoding stay byte-identical; when the removal leaves an empty query the `?` is dropped and the separator logic of
  today applies. Applies to every target (direct, listed and confirmed), so the "byte-identical" statements of
  D3 / AC3 hold for URLs without a `loginToken` parameter. Closes the login-CSRF / account-confusion vector of a
  client that reads the first `loginToken` value. (Formerly proposed follow-up `bz`; done here, `bz` stays unused.)

## Acceptance Criteria

### AC1 Classification (unit, `Nebu.Matrix.SsoRedirect.classify/1`)
1. Every row of the D2 table yields the stated result; each rejected row also gives `redirect_url_allowed?/1 ==
   false`, each accepted row `true`.
2. `{:confirmable, t}` normalizes: `https://Example.COM:443/a?b#c` -> `origin: "https://example.com", host:
   "example.com", port: nil, path: "/a"`; `https://example.com:8443` -> `origin: "https://example.com:8443"`;
   `https://example.com:0443/` -> port `nil`.
3. Exactly 2048 bytes is accepted, 2049 rejected (for an https and a deep-link URL).
4. Each D2 parser-differential example is a test row with a comment naming the browser interpretation
   (`https://evil.example\@listed.example/`, `http://evil.example\@localhost/`, `https:evil.example`,
   `https:/evil.example`, `https:\\evil.example`, `https:///evil.example`, `https://%65vil.example/`,
   `https://evil.example%2f@listed.example/`, `https://element.example.com@evil/`, `https://evil.example./`,
   `https://bücher.example/`, `https://xn--bcher-kva.example/` (confirmable), `https://[::1]:8443/`,
   `http://[::1]:8080/`, `http://127.0.0.1@evil.example/`, `http://localhost.evil.example/`,
   `https://example.com\r\nX: y`, `https://example.com\t/`, `https://example.com:99999/`, `https://example.com:/`,
   `https://0x7f.0.0.1/`, `https://2130706433/`, `https://10.1/`, `https://010.0.0.1/`, `https://1.2.3.256/`,
   `http://0x7f.0.0.1/`, `http://2130706433/`, `https://example.123/`, `http://localhost:/`,
   `http://localhost%2f@evil/`).
5. (oracle m1) Accepted (the authority ends at the first `/`, `?` or `#`; `@` / `%` after it are allowed):
   `https://app.ex/#/user/@bob:ex.org`, `https://app.ex/#/room/#a:ex.org`,
   `https://app.ex/p%20q?x=%2F`, `https://app.ex?x=1#/login` (confirmable, origin `https://app.ex`, path `""`),
   `https://app.ex?next=a@b/c`, `https://app.ex#@x/y`, `https://app.ex/p@q`, `https://app.ex/?e=a@b` (confirmable,
   origin `https://app.ex`), `https://1.example/`, `https://a-1.example/`, `https://0xample.example/`,
   `https://10.0.0.0/` (confirmable),
   `element://vector/webapp/?element-desktop-ssoid=abc#/login` and `http://localhost:3001//login` (`:direct`),
   `https://10.0.0.5:8443/` (confirmable, canonical IPv4).
6. (oracle m3, D20) `append_login_token/2` unit rows: `https://a.ex/cb?loginToken=old` -> `https://a.ex/cb?loginToken=NEW`;
   `https://a.ex/cb?x=1&loginToken=old&y=2` -> `...?x=1&y=2&loginToken=NEW`; `https://a.ex/cb?loginToken=a&loginToken=b`
   -> one `loginToken=NEW`; `https://a.ex/#/login?loginToken=old` -> `https://a.ex/?loginToken=NEW#/login`;
   `https://a.ex/cb?logintoken=keep` (other case) and `?xloginToken=keep` kept; URLs without the parameter are
   byte-identical to the pre-story output (regression rows from the existing tests).

### AC2 Redirect leg (plug level)
1. A D2-rejected URL answers `400` with the byte-identical JSON body `{"errcode":"M_INVALID_PARAM","error":"redirectUrl
   scheme is not permitted"}` (and, with `Accept: text/html`, the byte-identical HTML page of `render_html_error/1`
   for the parsed scheme), stores no SSO state, contacts no IdP; the WARNING text is unchanged.
2. `redirectUrl[]=x` and a missing `redirectUrl` still answer `400 M_MISSING_PARAM`; `redirectUrl=https://a.example/&redirectUrl=https://b.example/` stores `https://b.example/` and (after the callback) confirms `b.example` (AC4).
3. Legitimate shapes still `302` to the IdP: `http://localhost:7070/#/home`, `http://127.0.0.1:9000/cb`,
   `element://vector/webapp/`, `schildichat://login`, `im.fluffychat.auth://login`, an operator extra scheme,
   `https://app.example.com/#/home`, `https://app.example.com/?updated=1#/login`, `https://10.0.0.5:8443/`, and the
   AC1.5 rows.
5. (oracle m6) `GET /_matrix/client/v3/login/sso/redirect/oidc-or-any-idp?redirectUrl=<accepted URL>` (the
   `/{idpId}` form) answers `302` to the IdP exactly like the plain form; a rejected URL there gives the same `400`.
4. The `action` handling of story oauth-legacy-coexistence (error order, prompt mapping) is unchanged (existing
   tests stay green).

### AC3 Listed and direct targets are byte-identical to today (D20 aside)
1. With the callback completing successfully (redirect URLs without a `loginToken` parameter, D20), these targets
   answer exactly today's response: status `302`, headers
   `cache-control: no-store` and `location: append_login_token(redirect_url, token)`, NO `set-cookie` of the
   confirm cookie, NO `content-security-policy` / `x-frame-options` added by this story, empty body; the loginToken
   redeems via `POST /login`:
   (a) loopback `http://localhost:7070/#/home` (the existing fixtures), (b) `element://vector/webapp/`, (c)
   `https://<server_name>/...` with `server_name` set to `chat.example.test` (and `chat.example.test:8448` ->
   `https://chat.example.test:8448/` listed, `https://chat.example.test/` NOT listed), (d) an origin in
   `sso_redirect_allowed_origins`, also with different case and an explicit `:443` in the `redirectUrl`, (e) the
   origin of `oauth_issuer_url` with `oauth_enabled` OFF, (f) the registered https redirect URI of an `approved` client and everything at a path boundary below it (the same origin with another path is NOT listed: SEC #1).
2. NOT listed (each gets the confirmation, AC4): the origin of a `pending`, a `rejected` and a `revoked` client; an
   origin that only differs in port or by a subdomain from a listed one; `https://<request Host header>` when the
   `Host` differs from `server_name` (Host-spoof test). (A listed origin given as `http://` is not a confirmation
   case: a non-loopback `http://` URL is rejected at the redirect leg (D2); a stored state carrying one, which cannot
   exist after the deploy, gets today's `403 M_FORBIDDEN "SSO login failed"` per D3.)
3. The per-request cost: for (a)-(d) no DB query is issued by the classification (assert with a seam / query
   counter or by running the classification with `Nebu.Repo` unavailable).

### AC4 Unlisted https target: no token, a pending confirmation
1. The callback for an unlisted https target answers `303` `Location: /_matrix/client/v3/login/sso/confirm`, sets
   the binding cookie (https: `__Host-nebu_sso_confirm; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=300`; http:
   `nebu_sso_confirm; Path=/_matrix/client/v3/login/sso/confirm; HttpOnly; SameSite=Lax; Max-Age=300`), carries the
   D9 flow headers, and mints NO loginToken (the SsoStore token count is unchanged; no `Location` contains
   `loginToken` or the target host).
2. A pending `:confirm` entry exists under SHA-256 of the cookie, holding the verified `id_token`, the IdP refresh
   token (nil when none), the raw `redirect_url` and the display fields; the SSO state was consumed (a replay of the
   callback URL answers today's `400 M_UNKNOWN "Invalid or expired SSO state"`).
3. `Nebu.OAuth.trusted_redirect_url?/2` failing (DB error / timeout seam / exception) -> confirmation (fail
   closed) and one value-free WARNING; with `Nebu.Repo` unavailable the listed sources 1 and 2 still work.
4. The confirm store full -> `503` `unavailable` page, no token, no cookie, WARNING `matrix SSO: confirmation store full`.
5. IdP error / failed code exchange / nonce mismatch keep today's answers (no entry, no cookie).

### AC5 The page (GET)
1. With a valid cookie: `200`, the D15 structure: `data-page="sso-confirm" data-result="pending"`, exactly one h1,
   `data-role="target-origin"` = the normalized origin, `data-role="user-id"` = the Matrix id derived from the claims,
   the path line truncated at 60 chars for a long path and absent for `/`, NO query or fragment of the redirect URL
   anywhere in the body (test with `?secret=q1#frag1`), the IDN notice for an `xn--` host, Cancel before Continue,
   Continue `disabled`, the hidden `csrf_token`, exactly one `<script>` whose SHA-256 is in the CSP, a `<noscript>`.
2. Every displayed value is HTML-escaped (a test injects `<`/`"` through the user id claim).
3. GET mutates nothing: two GETs render the same page; the entry is still there.
4. Missing cookie, malformed cookie, unknown entry, expired entry -> `400 invalid_state` page, cookie cleared; on
   https a non-`__Host-` cookie alone counts as missing.
5. axe (e2e): no detectable accessibility violations; no horizontal scroll at 320 px.
6. (oracle m5) The script is `Nebu.Web.ArmScript.script/0` byte-for-byte (its hash in the CSP); it references the
   button only through `data-arm` (no page-specific id inside the script). Browser behaviour (e2e, Playwright):
   mouse: Continue stays disabled before 600 ms and without interaction; after a >= 4 px move it is enabled, but a
   click that was not preceded by a `pointerenter` on Continue after arming does NOT submit (still on the page),
   moving onto it and clicking submits; touch (`hasTouch: true` context): a tap elsewhere >= 600 ms after load arms,
   a tap on Continue then submits, and a first tap directly on Continue does NOT arm it; keyboard: Tab to Continue +
   Enter after a key press submits once armed.
7. (oracle M1) A popup opener survives: e2e, a stub client page on an https origin opens the SSO flow with
   `window.open`; after Continue the popup lands on the client target and its `window.opener` is not `null`.

### AC6 Headers
1. The confirm page: `cache-control: no-store`, `pragma: no-cache`, `x-frame-options: DENY`,
   NO `cross-origin-opener-policy` header (oracle M1; asserted ABSENT), `referrer-policy: same-origin`, the D9 CSP with `form-action 'self'
   https://host[:port]` built from the parsed target (port present iff not 443), `frame-ancestors 'none'`, the CSS
   and script hashes matching the served bytes; no `access-control-*` header (also with an `Origin` request header).
2. Cancel / error pages: the D9 CSP with `form-action 'none'` and no `script-src`, `referrer-policy: no-referrer`,
   the other headers as in 1, no script element.
3. The `303`s (callback -> page, Continue -> target): `cache-control: no-store`, `pragma: no-cache`,
   `referrer-policy: no-referrer`, no `access-control-*`.
4. No response of the flow (callback `302`/`303`, page, cancel page, every error page, the Continue `303`) carries
   `cross-origin-opener-policy` (one parameterized test over all of them).

### AC7 Continue
1. A valid POST (`decision=continue`, correct `csrf_token`, cookie, `Origin` = own origin, `Sec-Fetch-Site:
   same-origin`, `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`, `Sec-Fetch-User: ?1`) answers `303` (never
   302/307) with `Location` = `append_login_token(redirect_url, token)` for: a URL without query, with a query (`&loginToken=`),
   with a fragment (`?loginToken=` before `#`), with an upper-case scheme/host (the RAW string is kept), and with a
   pre-existing `loginToken=old` in the query and in the fragment (exactly one `loginToken`, the new one, D20).
2. The token redeems once via `POST /login {"type":"m.login.token"}` (200, the user id of AC5) and is a 30 s token;
   with an IdP refresh token captured and `refresh_token: true` the opaque-session path works as today.
3. The entry is gone, the cookie is cleared; a second POST (replay) gives `400 invalid_state` and no token.
4. INFO `matrix SSO: redirect confirmation confirmed host=<host>`.
5. Also valid without any fetch-metadata / Origin headers (old browsers, lenient level).

### AC8 Cancel
`decision=cancel` -> `200` cancelled page, the entry is gone, cookie cleared, no token minted (store count
unchanged), INFO `... declined host=<host>`; a following Continue POST gives `400 invalid_state`.

### AC9 CSRF, binding, fetch metadata, parsing
Each of these answers `403 forbidden` (or `400 invalid_state` for the cookie cases, `400 invalid_request` for parse /
decision cases) with the entry INTACT, no token, the cookie kept (except cleared on the definite invalid_state of a
missing entry), one value-free WARNING for the 403s: missing / wrong / other browser's `csrf_token`; missing cookie,
malformed cookie, a cookie of another pending flow (its own CSRF token does not match); on https an unprefixed
`nebu_sso_confirm` cookie (ignored); `Origin: https://evil.example`; `Origin: null` without `Sec-Fetch-Site:
same-origin`; two `Origin` headers; `Sec-Fetch-Site: cross-site` and `same-site`; `Sec-Fetch-Mode: cors`;
`Sec-Fetch-Dest: empty` / `iframe`; `Sec-Fetch-User: ?0`; a query string on the POST; a non-form content type; a
duplicated `decision` or `csrf_token`; an unknown `decision`; a body > 16 KiB. The checks run in the D9 order (a
test with BOTH a bad Origin and a bad body gets `400 invalid_request`).

### AC10 Lifetime, single use, concurrency, cap, cluster
1. An entry older than 300 s gives `invalid_state` on GET and POST (store-level TTL; test inserts with a short TTL).
2. N (>= 10) concurrent Continue POSTs of the same browser on one node: exactly one `303` with a loginToken, the
   others `400 invalid_state`; exactly one loginToken minted.
3. Cap: with 10 000 live `:confirm` entries the next callback for an unlisted target gets the `503` page; expired
   entries are evicted first (`evict_expired`), and the `:state` / `:token` caps are unaffected by `:confirm`
   entries (and vice versa).
4. Replication: `put_confirm` / `pop_confirm` broadcast `{:replicate_put, {:confirm, _}, _}` /
   `{:replicate_delete, {:confirm, _}}` to the other `nebu_matrix_sso_store` group members (a test process joined to
   the group receives them); an entry replicated from a peer is served by GET and consumed by POST on this node.
5. `SsoStore.format_status/1`: a crash report of the store (forced in a test) contains neither an `id_token`, a
   refresh token, nor a redirect URL put into the store.

### AC11 Rate limit
GET and POST share the bucket `{"sso_confirm", ClientIP.bucket(conn)}`: with the bucket exhausted (test seam /
small limits) the answer is `429` page + `Retry-After`, nothing consumed, cookie kept; another client address is
unaffected; the callback and `POST /login` buckets are unchanged.

### AC12 Routing
`PUT`/`DELETE`/`PATCH`/`HEAD` on `/_matrix/client/v3/login/sso/confirm` -> `405 M_UNRECOGNIZED` with `Allow: GET,
POST, OPTIONS`; a non-preflight `OPTIONS` -> `204` + the same `Allow`; a CORS preflight (`OPTIONS` with `Origin` +
`Access-Control-Request-Method`) -> `204` + `Allow: GET, POST, OPTIONS` and NONE of `access-control-allow-methods`,
`-allow-headers`, `-allow-credentials`, `-max-age`, `-expose-headers` (the fall-through's existing
`access-control-allow-origin: *` may stay, D11); the page, cancel / error pages and the `303`s carry no
`access-control-*` header at all (AC6); `/_matrix/client/v3/login/sso/confirm/x` -> `404 M_UNRECOGNIZED`;
`/sso/redirect/confirm` is still an IdP-id redirect (unchanged); `JsonBody` leaves `body_params` `Unfetched` for
the path (a JSON body is not parsed: `400 invalid_request`); the existing `unrecognized_routes_test.exs` matrix stays
green and lists the new path.

### AC13 Logging
With DEBUG enabled for a full flow, scoped FROM THE CALLBACK ONWARD (callback, GET, Continue, Cancel, refused POST,
`POST /login`): no log line
contains the loginToken, the `id_token`, the IdP refresh token, the cookie value or its hash, the CSRF token, the
redirect path, query or fragment (test redirect URL with distinctive markers); the confirm path's query string is
logged names-only; the request body of the POST is absent; the INFO lines of D12 appear with the host only. The
redirect leg's DEBUG line (`GET /sso/redirect`) keeps today's `redirectUrl` capture (story oauth-legacy-coexistence
L-2 masks only `action`); masking it is follow-up `ce`.

### AC14 Admin config
1. GET `/admin/config` shows the `sso-origins-form` with the label, the current value and the help text (also when
   unset: empty field). (oracle m4) The help text contains "Only list origins you control", the rendered
   `https://<server_name>` value with the sentence that it must be an origin the operator controls, and the
   unscoped-session caveat for approved OAuth clients.
2. POST `/admin/config/sso-origins` with `"https://Chat.Example.com:443/, https://web.example.com:8443,
   https://chat.example.com"` persists `"https://chat.example.com, https://web.example.com:8443"` and redirects with
   the success flash; `""` persists `""` (clears).
3. Each of these is rejected with a `200` re-render, a flash error, NO write: `http://x.example`, `https://*.example`,
   `https://x.example/path`, `https://x.example/?q`, `https://x.example#f`, `https://u@x.example`,
   `https://bücher.example` (message names the `xn--` form), `https://x.example.`, `https://[::1]`,
   `https://x.example:0`, `https://x.example:70000`, `https://x_y.example`, `"a,,b"` (empty token),
   `"https://x.example\n"` (trailing newline; `\z` anchor), 51 origins, a value > 4096 chars; the flash names the
   token truncated to 80 chars.
4. A save refreshes `Nebu.Web.OidcConfig` (the next classification on this node sees the new list) and broadcasts
   `{:invalidate_oidc_config}` to the `:pg` peers; `Nebu.Admin.DB.@scope_cache_keys` contains the key.
5. Validation is the single implementation in `Nebu.Matrix.SsoRedirect` reached through
   `Nebu.Matrix.normalize_sso_redirect_origins/1` (static test: the admin controller does not name
   `Nebu.Matrix.SsoRedirect`).

### AC15 Migration 000048 and the second save
1. Static: `000048_config_sso_redirect_keys_mutable.{up,down}.sql` exist and are the only `000048`; the up policy
   contains every key and both LIKE families of 000042's policy (parsed from the file, not hard-coded) plus
   `sso_extra_redirect_schemes` and `sso_redirect_allowed_origins`; the down policy equals 000042's (parsed); no
   `INSERT`, `BEGIN`, `COMMIT`, `CONCURRENTLY`, no other table; 000040-000047 files unchanged.
2. Integration as the runtime role (`nebu_app`, FORCE RLS): `Nebu.Admin.DB.upsert_server_config/1` writes
   `sso_extra_redirect_schemes` twice (`"a1"`, then `"a2"`) and `sso_redirect_allowed_origins` twice: the second
   value is stored each time and no error is raised (fails before the migration: RLS error on the second write).
   Every other key of 000042's list is still updatable (one parameterized test).
3. Integration through HTTP: saving the SSO schemes form twice and the SSO origins form twice (real DB, no writer
   seam) ends with the second values and the success flash.
4. `server/test/nebu/release_test.exs`: the migration list is contiguous and reaches 000048 (comment updated).

### AC16 Unchanged neighbours
1. UIA fallback (`/auth/m.login.sso/fallback/web`) completes the UIA session through the callback exactly as before
   (no confirm cookie, no confirmation, the completion page), also when the server name / allowlist would not list
   `uia.local`.
2. An `o2.`-tagged state still goes to the OAuth branch first (existing tests).
3. `POST /login` `m.login.token` behaviour and its rate limit are unchanged. (oracle m6) Pinned explicitly: a
   loginToken minted by Continue and redeemed once answers `403 M_FORBIDDEN` on a replay; an expired one (stored with
   a short TTL) and a forged / unknown one answer `403 M_FORBIDDEN`; none of them creates a session or a device.
4. The existing suites `server/test/nebu/matrix/*sso*`, `matrix_sso_test.exs`, `device_*_test.exs`,
   `server/test/nebu/oauth/oauth_legacy_coexistence*_test.exs`, `oauth_idp_callback_test.exs`,
   `oauth_request_logger_redaction_test.exs`, `oauth_binding_cookie_test.exs`, `unrecognized_routes_test.exs`,
   `admin/config_controller_test.exs` stay green; where a test asserted that an https target ends in a `302` with a
   `loginToken` straight from the callback it is adapted to list the target (AC3) or to go through the page (AC7),
   with a comment naming this story.

### AC17 Boundaries (static)
`lib/nebu/matrix/**` names no `Nebu.OAuth.<Submodule>` at all (only the `Nebu.OAuth` facade:
`trusted_redirect_url?/2`, `parse_form_post/1`, `check_fetch_metadata/2` and the existing facade functions);
`lib/nebu/web/**` names no `Nebu.OAuth.<Submodule>` except the EXISTING `Nebu.OAuth.Http` forwards (router,
`OAuthDiscovery`), nothing new; `lib/nebu/oauth/**` names no
`Nebu.Matrix.Sso*`; `lib/nebu/admin/**` reaches the new validation only via `Nebu.Matrix`; the three facade
functions are exported with `@doc`; `Nebu.Web.ArmScript` names no `Nebu.Matrix` / `Nebu.OAuth` module; new test
seams in `lib/` are compile-guarded (`if Mix.env() == :test`); no new
env variable (`NEBU_*`) is read.

### AC18 e2e
The two feature files below and their step definitions exist, pass `tsc --noEmit` and
`bddgen --tags "@legacy-sso-confirm or @sso-redirect-origins"` (Playwright itself cannot run in the isolated env;
they run on the reference stack).

### AC19 Docs (orchestrator, after dev)
The docs listed in Dev Notes are updated, including (oracle m4) the 07-deployment statement that
`https://<server_name>` is trusted automatically and must be an origin the operator controls (well-known
delegation case), and (D19) the 30 s loginToken deviation and the unknown-idpId behaviour in
`docs/matrix-api-scope.md`; `docs/stories/oauth-broker/follow-ups.md` row `by` is marked closed by this story and the
follow-ups of this story are appended with the ids stated there (`bz` unused). (The help-text requirement is
AC14.1.)

## Acceptance Tests / Test notes

New tests (names at most 254 characters, the Elixir 1.19 limit, CI runs Elixir 1.19; `:integration` where a DB is needed):

| File | ACs | Kind |
|---|---|---|
| `server/test/nebu/matrix/sso_redirect_classify_test.exs` | AC1 | unit, async, table-driven |
| `server/test/nebu/matrix/sso_redirect_leg_test.exs` | AC2 | plug (Router.call), seams |
| `server/test/nebu/matrix/sso_redirect_confirm_flow_test.exs` | AC3, AC4, AC7, AC8, AC10.1-2, AC16.1 | plug + `:integration` for `POST /login` and approved-client rows |
| `server/test/nebu/matrix/sso_redirect_confirm_page_test.exs` | AC5, AC6 | plug + render unit (hash pinning, escaping, the script is `Nebu.Web.ArmScript.script/0`, COOP absent everywhere) |
| `server/test/nebu/matrix/sso_append_login_token_test.exs` | AC1.6, AC7.1 | unit (D20) |
| `server/test/nebu/web/arm_script_test.exs` | AC5.6 | static (no `//` or `/*` comments, ES5 only, no network API, `data-arm` / `data-arm-hint` selectors, `pointerenter` / `touchstart` / `pointerType` handling present, 600 ms constant) |
| `server/test/nebu/matrix/sso_redirect_confirm_csrf_test.exs` | AC9, AC11 | plug |
| `server/test/nebu/matrix/sso_store_confirm_test.exs` | AC10.3-5 | unit (SsoStore, pg group member, forced crash report via `:sys.get_status` / `format_status`) |
| `server/test/nebu/matrix/sso_redirect_confirm_logging_test.exs` | AC13 | `capture_log` with DEBUG |
| `server/test/nebu/matrix/sso_redirect_confirm_static_test.exs` | AC12 (JsonBody / cors clauses), AC17 | static source scans (comments stripped, alias forms covered, as `oauth_legacy_coexistence_static_test.exs`) |
| `server/test/nebu/oauth/oauth_trusted_redirect_origin_test.exs` | AC3.1(e,f), AC3.2, AC4.3 | `:integration` (client rows via `Nebu.OAuth.TestSupport`; status pending/approved/rejected/revoked; DB failure seam) |
| `server/test/nebu/admin/config_controller_sso_origins_test.exs` | AC14 | controller, writer seam |
| `server/test/nebu/migration/000048_config_sso_redirect_keys_mutable_test.exs` | AC15.1-2 | static + `:integration` as runtime role (pattern: `000042_oauth_sessions_signing_keys_test.exs`, `likes_of/1`) |
| `server/test/nebu/admin/sso_config_second_save_test.exs` | AC15.3 | `:integration`, admin session helper, real DB |

Updated: `server/test/nebu/release_test.exs` (AC15.4), `server/test/nebu/web/unrecognized_routes_test.exs` (AC12),
`server/test/nebu/oauth/oauth_request_logger_redaction_test.exs` (names-only path list), the https-callback cases of
the existing SSO suites if any (AC16.4: today they use loopback `http://localhost:7070/#/home`, see
`Nebu.OAuth.TestSupport.legacy_login/4` and `@legacy_redirect`; the redirect-leg-only tests with
`https://app.example.com/#/home` stay valid because classification happens at the callback).

Seams (ATDD role adds them to test support; lib seams compile-guarded):
- `:sso_redirect_origins_reader` (0-arity -> string or list, like `:sso_redirect_schemes_reader`),
- `:sso_trusted_origin_check` (1-arity `fn origin -> boolean | raise end`, replaces the `Nebu.OAuth` call; absent =
  the real call),
- `:admin_config_sso_origins_writer` (1-arity, controller, compile-guarded),
- TTL: tests insert entries through `SsoStore.put_confirm/3` with a 1 s TTL; no TTL seam in `SsoLogin`,
- rate limit: drain the bucket with `RateLimit.take/3` in the test (as the consent tests do),
- server name: `Application.put_env(:nebu_http, :server_name, ...)` restored in `on_exit`,
- a test helper `confirm!(conn_or_cookie, decision, opts)` (GET + POST with cookie, CSRF from the page, the four
  fetch-metadata headers and `Origin`), analogous to `consent!/3` in `oauth_test_support.exs`; and
  `legacy_callback!(priv, sub, redirect_url)` returning the callback conn (redirect + stubbed exchange + callback).

### Gherkin: new `e2e/features/oauth/legacy-sso-redirect-confirmation.feature` (admin-ui project, real Dex)

```gherkin
@legacy-sso-confirm
Feature: Confirmation before a legacy SSO login is handed to an unknown web address
  As a Matrix user I want to be asked before my sign-in goes to a site this server does not know
  So that a link cannot silently log someone else's site into my account

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed
    And the browser stubs the client page "https://unlisted.e2e.example/cb"

  @ac4 @ac5 @ac6 @ac7
  Scenario: Continuing to an unlisted web address
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb?app=1#/login"
    And the user signs in at the IdP
    Then the SSO confirmation page names the target "https://unlisted.e2e.example"
    And the SSO confirmation page names the signed-in Matrix user
    And the SSO confirmation page does not contain "app=1"
    And the page has exactly one level-1 heading
    And the SSO confirmation page has one hash-pinned script and Continue starts disabled
    And the response has a Content-Security-Policy starting with "default-src 'none'"
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    When the user continues the SSO sign-in
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"
    And the redirect query has a "loginToken"
    And the redirect query has "app" = "1"

  @ac8
  Scenario: Cancelling sends nothing to the web address
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user cancels the SSO sign-in
    Then the page shows the SSO sign-in was cancelled
    And the browser is not redirected to "https://unlisted.e2e.example/cb"

  @ac5 @ac7
  Scenario: The confirmation cannot be used twice
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user continues the SSO sign-in
    And the browser goes back and submits the SSO confirmation again
    Then the page is marked as SSO confirmation error "invalid_state"

  @ac3 @ac14
  Scenario: A listed origin is not confirmed
    Given the browser stubs the client page "https://listed.e2e.example/cb"
    And the operator lists "https://listed.e2e.example" as an allowed SSO redirect origin
    When the browser starts a legacy SSO login with redirectUrl "https://listed.e2e.example/cb"
    And the user signs in at the IdP
    Then the client receives the redirect at "https://listed.e2e.example/cb"
    And the redirect query has a "loginToken"

  @ac5
  Scenario: Continue on a touch device
    Given the browser is a touch device
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user taps Continue on the SSO confirmation page right away
    Then the browser is still on the SSO confirmation page
    When the user taps the SSO confirmation page outside Continue
    And the user taps Continue on the SSO confirmation page
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"
    And the redirect query has a "loginToken"

  @ac5
  Scenario: A click without moving onto Continue after arming does not submit
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the mouse rests on Continue while the SSO confirmation page arms and then clicks without moving
    Then the browser is still on the SSO confirmation page
    When the user moves the mouse onto Continue and clicks it
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"

  @ac5 @ac6
  Scenario: A popup-based web client keeps its opener
    Given the browser stubs the client page "https://popup.e2e.example/app"
    When the stub client page "https://popup.e2e.example/app" opens a legacy SSO login popup with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP in the popup
    And the user continues the SSO sign-in in the popup
    Then the popup reaches "https://unlisted.e2e.example/cb" with a "loginToken"
    And the popup still has its opener

  @ac2
  Scenario: A disguised address is refused before the IdP
    # the step builds https://evil.e2e.example\@listed.e2e.example/cb in TypeScript (no backslash inside a Gherkin string)
    When the browser starts a legacy SSO login whose redirectUrl hides "evil.e2e.example" behind a backslash before "listed.e2e.example"
    Then the browser shows the SSO redirect error page with status 400
```

### Gherkin: new `e2e/features/admin/sso_redirect_origins.feature`

```gherkin
@sso-redirect-origins
Feature: Admin UI — allowed SSO redirect origins
  As an instance admin
  I want to list the web client origins my users sign in with
  So that their legacy SSO logins skip the confirmation page

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed
    And an admin is logged into the Admin UI

  @ac14 @ac15
  Scenario: The origins are normalized and a second save takes effect
    When the admin navigates to "/admin/config"
    Then the page shows the "Allowed SSO redirect origins" field
    When the admin enters "https://Chat.E2E.example:443/, https://web.e2e.example:8443" in the "Allowed SSO redirect origins" field
    And the admin saves the SSO origins form
    Then the page shows a success flash message
    And the "Allowed SSO redirect origins" field shows "https://chat.e2e.example, https://web.e2e.example:8443"
    When the admin enters "https://chat.e2e.example" in the "Allowed SSO redirect origins" field
    And the admin saves the SSO origins form
    Then the page shows a success flash message
    And the "Allowed SSO redirect origins" field shows "https://chat.e2e.example"

  @ac14
  Scenario: A wildcard origin is refused
    When the admin navigates to "/admin/config"
    And the admin enters "https://*.e2e.example" in the "Allowed SSO redirect origins" field
    And the admin saves the SSO origins form
    Then the page shows an error flash message containing "not valid"
    When the admin navigates to "/admin/config"
    Then the "Allowed SSO redirect origins" field does not show "*"

  @ac15
  Scenario: The SSO redirect schemes can be saved twice
    When the admin navigates to "/admin/config"
    And the admin enters "e2e-one" in the "Additional SSO redirect schemes" field
    And the admin saves the SSO schemes form
    And the admin enters "e2e-two" in the "Additional SSO redirect schemes" field
    And the admin saves the SSO schemes form
    Then the page shows a success flash message
    And the "Additional SSO redirect schemes" field shows "e2e-two"
```

Step definitions: `e2e/step-definitions/oauth/legacy-sso-redirect-confirmation.steps.ts` and
`e2e/step-definitions/admin/sso-redirect-origins.steps.ts`. Reuse (do not redefine): "the Nebu stack is running",
"bootstrap is already completed", "an admin is logged into the Admin UI", "the admin navigates to {string}", "the page
shows a success flash message", "the page shows an error flash message containing {string}", the "Additional SSO
redirect schemes" steps of `sso-schemes.steps.ts`, "the user signs in at the IdP", "the client receives the redirect
at {string}", "the redirect query has a {string}", "the redirect query has {string} = {string}", "the browser is not
redirected to {string}", "the page has exactly one level-1 heading", "the page has no detectable accessibility
violations", "the page does not scroll horizontally at a 320 px viewport", "the response has a Content-Security-Policy
starting with {string}". New steps stub the client target with `page.route(...)` (as `oauth-authorize.steps.ts`
does), start the login with `page.goto('/_matrix/client/v3/login/sso/redirect?redirectUrl=' +
encodeURIComponent(url))`, arm Continue by a real pointer move + wait before clicking, and set the operator list
through the admin form (its own browser context) or the admin HTTP API used by other admin steps. Note: the e2e
stack runs on plain http (`http://localhost:8008`), so the http cookie variant is exercised there; the `__Host-`
variant is covered by the plug tests.

## Dev Notes

### Files and functions (current state -> change -> preserve)

- `server/lib/nebu/matrix/sso_redirect.ex` (NEW): `classify/1`, `normalize_origin/1`, `normalize_origin_list/1`,
  `listed?/1` (sources 1-3 of D4 in order, the two seams), `origin_display/1`. Pure functions except `listed?/1`.
  Regexes `\z`-anchored. No `URI.parse/1` for the security decision (use it at most for the scheme of the HTML
  error page, as today); parse the authority yourself: `scheme://` + authority up to the first `/`, `?`, `#`.
- `server/lib/nebu/matrix/sso_login.ex`:
  - `redirect/1` (~L80): replace the `redirect_url_allowed?/1` condition by `classify/1` (reject -> unchanged
    `reject_redirect/2`); keep the error order.
  - `redirect_url_allowed?/1` (~L632): delegate to `SsoRedirect.classify/1`; `@scheme_denylist`,
    `@default_deep_link_schemes` and `extra_redirect_schemes/0` move to (or are read by) `SsoRedirect`;
    `scheme_denylist/0` stays public (the admin controller calls it today).
  - `do_callback/3` (~L473): in the non-UIA branch classify `entry.redirect_url` BEFORE `put_login_token`; direct /
    listed -> the existing lines unchanged (same response; `append_login_token/2` now applies D20); unlisted -> `Nebu.Matrix.SsoConfirm.begin/3`
    (store entry, cookie, `303`, INFO). Preserve: `o2.` dispatch first, IdP error branch, `complete_uia/3`, the
    `403 M_FORBIDDEN` failure branch.
  - `append_login_token/2` (~L698): D20 removal of existing `loginToken` parameters (query and fragment query);
    used by the direct / listed callback path and by Continue.
- `server/lib/nebu/matrix/sso_confirm.ex` (NEW): `begin(conn, entry_fields)`, `handle(conn)` (GET/POST of D9/D10),
  cookie helpers, CSRF derivation, the local Origin check, rate limit, INFO/WARNING lines.
- `server/lib/nebu/matrix/sso_confirm_page.ex` (NEW): page / cancel page / error pages, CSS constant with
  compile-time SHA-256, the script from `Nebu.Web.ArmScript` (hash computed at compile time), `put_headers/2` (NO
  COOP); model it on `Nebu.OAuth.ConsentPage` and `Nebu.OAuth.Pages` (read them; do not call them).
- `server/lib/nebu/web/arm_script.ex` (NEW, D9 / oracle m5): the generic arming script (`data-arm`,
  `data-arm-hint`, 600 ms, mouse / pen `pointerenter` rule, touch arming, keyboard), `script/0`.
- `server/lib/nebu/matrix/sso_store.ex`: `:confirm` tag (`put_confirm/3`, `peek_confirm/1`, `pop_confirm/1`,
  `@max_confirm_entries 10_000`, `confirm_count/1`), `format_status/1`; update the moduledoc (three stores). Preserve
  `put_state`/`pop_state`/`put_login_token`/`pop_login_token` behaviour and the replication protocol.
- `server/lib/nebu/matrix/http_public.ex`: `get "/sso/confirm"` / `post "/sso/confirm"` -> `Nebu.Matrix.SsoConfirm.handle/1`,
  placed before the `match _` marker clause (~L179); moduledoc line.
- `server/lib/nebu/matrix.ex`: `normalize_sso_redirect_origins/1` (`@doc`, delegate to `SsoRedirect`).
- `server/lib/nebu/oauth.ex`: `trusted_redirect_url?/2` (`@doc`, rescue/catch -> false), `parse_form_post/1`
  (`defdelegate ... to: Nebu.OAuth.FormPost, as: :parse`, `@doc`); moduledoc "Matrix -> OAuth" paragraph lists the
  new questions (the sentence "oauth_aware?/0 is the ONLY question" must be reworded; check `adr_033_test.exs` /
  static tests that pin moduledoc text).
- `server/lib/nebu/oauth/client_store.ex`: `approved_redirect_uris/1` (D6 query, bounded).
- `server/lib/nebu/web/oidc_config.ex`: key in `@empty_config`, `@sql_load_oidc_config`, `load_from_db/0`, getter.
- `server/lib/nebu/web/router.ex`: `cors/2` skip clause for the confirm path (next to the consent clause ~L270).
- `server/lib/nebu/web/plugs/json_body.ex`: skip clause for `["_matrix","client","v3","login","sso","confirm" | _]`
  (path_info at this plug is the FULL path; place it before the generic clauses, next to the consent clause ~L92).
- `server/lib/nebu/web/plugs/request_logger.ex`: `@names_only_query_paths` + comment.
- `server/lib/nebu/admin/db.ex`: `@scope_cache_keys` + comment.
- `server/lib/nebu/admin/config_controller.ex`: `save_sso_origins/2`, `persist_sso_origins/1` (seam
  `:admin_config_sso_origins_writer`); `server/lib/nebu/admin/config_html.ex`: `sso_origins_value/2`;
  `server/lib/nebu/admin/templates/config/index.html.heex`: the D14 form after `sso-schemes-form`;
  `server/lib/nebu/admin/router.ex`: `post "/config/sso-origins", ConfigController, :save_sso_origins` (~L225).
- `server/priv/migrations/000048_config_sso_redirect_keys_mutable.up.sql` / `.down.sql` (NEW, D13). After adding it
  reset the throwaway DB (`docker rm -f nebu-oauth-pg`) before running `quick.sh`.
- e2e: the two feature files + two step files (AC18).

### Guardrails
- ADR-018: inline SQL (the approved-client query lives in `ClientStore`); ADR-019: no new app; ADR-020: facade-only
  cross-domain calls (AC17); ADR-021: plain modules; ADR-022: no env var; OIDC Scopes Law untouched (the IdP request
  is not changed by this story).
- `oauth_enabled` stays off by default; nothing here reads it except through `Nebu.OAuth.trusted_redirect_url?/2`'s
  issuer part, which does NOT depend on `enabled`.
- Change `append_login_token/2` only as D20 says; do not change the loginToken TTL (30 s) or `POST /login`.
- Do not change the OAuth consent page (its G3-5 adoption of `Nebu.Web.ArmScript` is a later change) and do not add
  COOP anywhere in this flow.
- Every whitelist regex `\z`-anchored; trim only ASCII space/tab before validation.
- Pages: never `inspect/1` a value into HTML; `Plug.HTML.html_escape/1` for every rendered value.
- `id_token` may expire while the page is open (5 min page TTL vs the IdP's id_token lifetime, Dex 24 h): `POST /login`
  then fails as today with an expired token; no special handling.
- Keep test names at most 254 characters (Elixir 1.19); `--warnings-as-errors` in CI (reference modules created by this story in tests via
  `apply/3` or module attributes where the module may not exist during the ATDD red phase).

### Docs to update (orchestrator after dev, D17)
- `CHANGELOG.md` / release note: the behaviour change and operator impact (Summary), the new Admin field, migration
  000048 (fixes the second-save failure of "SSO redirect schemes").
- `docs/architecture/07-deployment.md`: "Activating OAuth" preconditions table row G3-3 -> closed by this story;
  (oracle m4) `https://<server_name>` is trusted automatically and must be an origin the operator controls
  (well-known delegation: the apex host gets tokens without confirmation); popup clients and the absent COOP;
  "Accepted risks" bullet for legacy `redirectUrl` trust rewritten to the D18 residuals; new runbook subsection
  "Legacy SSO confirmation page": which clients see it, how to read the INFO line, how to list origins, what is
  auto-listed, loopback / scheme residual.
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`: new section "Legacy SSO redirect
  confirmation (G3-3)" with D1-D20 in short form and the cross-domain additions to the facade.
- `docs/matrix-api-scope.md`: `/login/sso/redirect` row (stricter `redirectUrl`), `/login/sso/redirect/oidc` row
  (confirmation for unlisted https targets), a new row `GET|POST /_matrix/client/v3/login/sso/confirm` (Nebu
  extension, browser page, not a spec endpoint).
- `docs/architecture/08-concepts.md` / `05-building-blocks.md` (they describe `sso_extra_redirect_schemes`): add the
  origin list and the confirmation.
- Security docs (`skills/nebu-conventions/security-rules/` if it lists browser-form rules) and
  `docs/stories/oauth-broker/follow-ups.md` (row `by` closed; new rows below).

## Out of scope
- The loginToken lifetime (spec "around five seconds", Nebu 30 s; D19) and a pre-redirect browser binding cookie
  (spec "guard against unsolicited authentication attempts"; follow-up `ca`). (Removing pre-existing `loginToken`
  parameters is now IN scope: D20.)
- Accepting `http://[::1]` loopback, new default deep-link schemes (`io.element.desktop`, `io.element.elementx`, ...).
- Changing the HTML 400 rejection page text, the OAuth consent page, `BrowserPost`, or any OAuth flow.
- A per-client or per-user "remember this origin" choice (every unlisted login is confirmed).
- Deprecating legacy SSO (ADR-033 C20 path).

## Follow-ups (append to `docs/stories/oauth-broker/follow-ups.md`; ids as referenced by the oracle gate)
- (`bz` is NOT used: the loginToken-parameter removal it described is done in this story, D20 / oracle m3.)
- **ca** No pre-redirect binding of the legacy SSO flow to the browser (spec "SHOULD guard against unsolicited
  authentication attempts ... set a cookie when handling /sso/redirect"): login CSRF (victim ends up logged into
  the attacker's account) remains possible; the confirmation of this story does not address it.
- **cb** `server_config` keys written at runtime but not in `config_update_mutable` (found while checking D13):
  `admin_group_claim` (written by `/admin/config/role-mapping`, `Nebu.Admin.RoleMappingController`) was dropped from
  the policy by 000002; a second save fails like the SSO schemes did. Security-relevant (admin claim value): needs
  its own decision (make mutable with an audit row, or remove the edit path).
- **cc** `Nebu.Admin.ConfigController` calls `Nebu.Matrix.SsoLogin.scheme_denylist/0` directly (ADR-020 slip,
  pre-existing): route it through `Nebu.Matrix`.
- **cd** Default deep-link scheme list review (oracle answers 2-5): (a) `io.element.desktop` (newer Element Desktop,
  mostly used for OIDC; legacy SSO still uses `element://vector/webapp/?element-desktop-ssoid=...`); (b) FluffyChat's
  real native scheme, which is probably `im.fluffychat` (`im.fluffychat://login`), NOT the default
  `im.fluffychat.auth`: verify against the FluffyChat source and correct the default list (today such logins get the
  400 unless the operator adds the scheme); (c) Element Android / iOS classic `element://connect` (covered by
  `element`); (d) IPv6 loopback `http://[::1]` (RFC 8252 7.3; nheko / rust-sdk loopback clients). Non-gating.
- **ce** Mask `redirectUrl` in the redirect-leg DEBUG line (`GET /_matrix/client/v3/login/sso/redirect[/{idpId}]`,
  `RequestLogger` `sso_redirect_path?`): today its full value (path, query, fragment of the client URL) is captured;
  only `action` is masked (L-2). Non-gating (DEBUG only, no secret before the callback, but client state such as
  Element's fragment can be personal).

## Oracle gate result

Ran 2026-10-13, verdict PASS with 1 MAJOR and 6 MINOR; full answers and findings in
`_bmad-output/nebu/epics/oauth-broker/step-results/legacy-sso-redirect-confirmation/oracle-context.md`. Applied:
M1 (no COOP: D9, AC5.7, AC6), m1 (authority-scoped `@` / `%`, accepted rows: D2, AC1.5, AC2.3), m2 (canonical IPv4:
D2, AC1.4), m3 (loginToken removal now: D20, AC1.6, AC7.1; follow-up `bz` dropped), m4 (`https://<server_name>`
must be operator controlled: D4, D14, AC14.1, AC19), m5 (touch arming + G3-5 `pointerenter` rule in the shared
`Nebu.Web.ArmScript`: D9, AC5.6, e2e touch scenario), m6 (403 for replayed / expired / forged loginTokens, `302`
for `/{idpId}`: AC16.3, AC2.5); INFO items recorded in D19. Client answers in short: Element Web sends origin + path
+ query + `#/...` fragment (< 300 bytes, may contain `@` / `#`, may carry an old `loginToken`); Element Desktop
`element://vector/webapp/?element-desktop-ssoid=<id>#/login`; Element X does not use legacy SSO; FluffyChat native
`<scheme>://login` (follow-up cd), desktop `http://localhost:3001//login`, web `https://<host>/<base>/auth.html` as a
popup using `window.opener`; SchildiChat `schildichat://`, Cinny / Hydrogen https own origin, nheko loopback; the
2048-byte cap and the strict 400s are safe for all of them; post-IdP placement is spec conformant.

## Open questions for the oracle (ANSWERED, see "Oracle gate result")
1. **Element Web**: what exactly does it send as `redirectUrl` (origin + path + `?`-params + `#/login`? does it ever
   carry a `loginToken` already, or a `hs`-style parameter the spec's client CSRF example warns about)? Is any
   shape rejected by the D2 rules (control chars, backslash, non-ASCII, length > 2048)?
2. **Element Desktop**: `element://vector/webapp/` vs. the newer `io.element.desktop://vector/webapp/`: which
   versions use which? Should `io.element.desktop` become a default deep-link scheme (today: 400 unless the operator
   adds it; unchanged by this story)?
3. **Element X (iOS / Android)**: does it ever use legacy `m.login.sso` against a non-MAS server, and if so with which
   callback (`io.element.elementx:/...` custom scheme, an https universal link on an element.io host, loopback)? An
   https universal link would show the confirmation on every login unless listed.
4. **FluffyChat**: native `im.fluffychat.auth://login`; the web build (`https://fluffychat.im/web/...` or self-hosted):
   which https redirect does it use?
5. **SchildiChat / SchildiChat Next, Cinny, Hydrogen**: redirect shapes (scheme, loopback port, https origin).
6. **Route**: is a Nebu-specific `GET|POST /_matrix/client/v3/login/sso/confirm` acceptable inside the spec's
   `/_matrix/client/v3/login` namespace (collision risk with future spec endpoints), or should it move to a
   non-spec prefix that the reference nginx templates would then need to proxy (Synapse uses `/_synapse/client/`)?
7. **Spec**: "If it already includes one or more loginToken parameters, they should be removed before adding the
   new one": fix now (changes `append_login_token/2`) or follow-up bz? ANSWERED: fix now (D20).
8. **Spec**: the login token lifetime "SHOULD be limited to around five seconds" (Nebu: 30 s). Keep?
9. **Length cap 2048 bytes** for `redirectUrl`: safe for every client above?
10. **Strict 400s** for https `redirectUrl`s with userinfo, IPv6 literal hosts, trailing-dot hosts, underscores in
    hosts, non-ASCII characters or an empty port: any legitimate client affected?
11. **Placement**: confirmation after the IdP login (at the callback) as the spec's second option and Synapse do; any
    client that breaks when the IdP leg ends on a Nebu page with a `303` + Continue instead of an immediate redirect
    (embedded webviews / ASWebAuthenticationSession completing only on the callback scheme)? (Only https targets get
    the page; native custom-scheme and loopback flows are unaffected.)
12. **Auto-listing**: is listing the https redirect origins of APPROVED OAuth clients for the LEGACY flow acceptable
    from the spec's perspective (an admin approved that app for OAuth; the legacy flow then trusts its origin too)?

## Tasks
- [x] D1/D2: `Nebu.Matrix.SsoRedirect.classify/1` + redirect leg + `redirect_url_allowed?/1` delegate (AC1, AC2)
- [x] D3/D4/D6: callback branch, `listed?/2`, `Nebu.OAuth.trusted_redirect_url?/2`, `ClientStore.approved_redirect_uris/1` (AC3, AC4)
- [x] D7: SsoStore `:confirm` tag, cap, `format_status/1` (AC10)
- [x] D8-D10/D15: `SsoConfirm`, `SsoConfirmPage`, routes, cookie, CSRF, headers, arming, outcomes (AC5-AC9, AC11)
- [x] D11: HttpPublic routes, cors and JsonBody skips (AC12)
- [x] D12: logging lines, RequestLogger list (AC13)
- [x] D5/D14: OidcConfig key, Admin DB cache key, `Nebu.Matrix.normalize_sso_redirect_origins/1`, admin form + route (AC14)
- [x] D13: migration 000048 up/down, release test (AC15)
- [x] AC16/AC17: regression + static boundaries; e2e features + steps typecheck (AC18)

## Dev Agent Record

Dev-story run 2026-10-13 (Sonnet 5.5). Implemented D1-D20 / AC1-AC17; the e2e features and steps (AC18) were staged by the
ATDD role and typecheck (`tsc --noEmit` and `bddgen --tags "@legacy-sso-confirm or @sso-redirect-origins"`, run from a scratchpad
copy of `e2e` with the main checkout's `node_modules` symlinked) without findings. AC19 (docs) is the orchestrator's.

### Files changed (server)

New:
- `server/lib/nebu/matrix/sso_redirect.ex` - `classify/1`, `listed?/1` (D4 sources 1-3, compile-guarded seams
  `:sso_redirect_origins_reader` / `:sso_trusted_origin_check`), `normalize_origin_list/1`, `host_label/1`.
- `server/lib/nebu/matrix/sso_confirm.ex` - `begin/2` (callback side) and `handle/1` (GET page / POST decision).
- `server/lib/nebu/matrix/sso_confirm_page.ex` - the page, the cancelled page, the error pages, the flow headers (no COOP).
- `server/lib/nebu/web/arm_script.ex` - the shared ES5 arming script (`script/0`).
- `server/priv/migrations/000048_config_sso_redirect_keys_mutable.up.sql` / `.down.sql`.

Changed:
- `server/lib/nebu/matrix/sso_login.ex` (leg uses `classify/1`; callback branch `finish_legacy_login/5`; `mint_login_token/2`;
  `redirect_url_allowed?/1` and `scheme_denylist/0` delegate to `SsoRedirect`; D20 `append_login_token/2`),
  `sso_store.ex` (`:confirm` tag, `put_confirm/3`, `peek_confirm/1`, `pop_confirm/1`, cap 10 000, `format_status/1`),
  `http_public.ex` (`get`/`post "/sso/confirm"`), `matrix.ex` (`normalize_sso_redirect_origins/1`).
- `server/lib/nebu/oauth.ex` (`trusted_redirect_url?/2` since cycle 1, `parse_form_post/1`; moduledoc), `oauth/client_store.ex`
  (`approved_redirect_uris/1`), `oauth/config.ex` (`configured_issuer/1`).
- `server/lib/nebu/web/oidc_config.ex` (key, getter), `web/router.ex` (`cors/2` skip), `web/plugs/json_body.ex` (skip clause),
  `web/plugs/request_logger.ex` (`@names_only_query_paths`).
- `server/lib/nebu/admin/db.ex` (`@scope_cache_keys`), `admin/config_controller.ex` (`save_sso_origins/2`, compile-guarded seam
  `:admin_config_sso_origins_writer`), `admin/config_html.ex`, `admin/router.ex`, `admin/templates/config/index.html.heex`.

### Decisions taken while implementing (all inside the story's D-sections)

- Store key = RAW 32-byte SHA-256 digest of the cookie (D7); the test helpers accept both raw and hex.
- `SsoStore.put_confirm/3` keeps only the eight documented fields (`Map.take`); `format_status/1` redacts the state, every message payload
  (also inside `$gen_call` / `$gen_cast` and the sys log) and a `{:bad_cast, _}` reason; no `handle_cast`.
- The callback's direct / listed path keeps ignoring the (pre-existing) `{:error, :store_full}` of `put_login_token/4` (byte-identical);
  only Continue answers `503` for it (D10).
- `Nebu.OAuth.trusted_redirect_url?/2` reads the issuer through the new `Nebu.OAuth.Config.configured_issuer/1` (the static test of
  story oauth-hardening-hygiene pins `normalize_issuer(` to config.ex / metadata.ex). Cycle 0 matched approved clients by ORIGIN with a
  `metadata::text LIKE` prefilter (bent to a test fixture that stored the metadata as a jsonb string); cycle 1 replaced it with the
  registered-URI match of D6 on `jsonb_array_elements_text(metadata->'redirect_uris')` (the ATDD fixture now stores an object-typed
  jsonb, like production).
- `Nebu.Web.OidcConfig.@sql_load_oidc_config` is now a concatenated string instead of a heredoc: the static test strips heredocs before it looks for
  `'sso_redirect_allowed_origins'`.
- Normalizer messages: `Origin '<token, 80 chars + "..." when cut>' is not valid: <reason>.`; the non-ASCII reason names the ASCII (`xn--`) form
  without computing punycode.
- The arming script waits via a single `setTimeout` after the first qualifying interaction and uses a geometric hit test on the button rect
  (not only `target.contains`) so a tap on a disabled button that the browser retargets does not arm.

### Test results (isolated env: throwaway Postgres + `quick.sh`, `--include integration`)

- New/changed files together (classify, leg, confirm flow / page / csrf / logging / static, append_login_token, store confirm, arm script, trusted
  redirect origin, config controller sso origins, second save, migration 000048, release, unrecognized routes, request logger redaction): 566 / 592 pass,
  26 fail, all 26 are staged-test defects, see "Test / story conflicts" below.
- Neighbour suites (`test/nebu/{matrix,web,oauth,admin,migration}` + `release_test.exs`): matrix 1861/1866 (4 conflicts + the known
  `RegressionSyncLoadTest`), web 653/653, oauth 2441/2443 before the `configured_issuer/1` fix (the static `normalize_issuer(` test, fixed; the
  remaining one is the conflicting AC4.3 test), admin 761/804 (21 flash-location conflicts; the rest are known families: `RoomsFallbackNameTest`,
  `TemporaryCaptureManagerTest`, `WarRoomTest`, `TraceMapNodeControlsTest`, `AdminOidcLoginTest`), migration 217/217.
- `mix compile --warnings-as-errors`: only the pre-existing Elixir 1.20 type warning in `matrix/event_dispatcher/server.ex:4961` (not touched by this
  story, CI runs 1.19); no warning from the touched files. The project has no formatter configuration (`.formatter.exs` absent), nothing was reformatted.

### Review cycle 1 (code review MIN-1..7, UX gate B1/B2/N1-N10, security review SEC #1-#5, #9)

All 636 tests of the changed / new files are green (including the 61 tests the ATDD role added or turned red for this cycle), no test was edited, no conflict.

- **SEC #1 (MEDIUM, approved clients by origin) / MIN-1.** `Nebu.OAuth.trusted_redirect_origin?/1` became `trusted_redirect_url?(origin, raw_url)`
  (D4 source 3, D6): issuer by origin without a DB read; approved clients by REGISTERED redirect URI (raw URL equals it or extends it at a path
  boundary, case-sensitive path, dot segments and `%2e` / `%2f` / `%5c` in the path never match, status `approved` only). `ClientStore.approved_redirect_uris/1`
  is a `jsonb_array_elements_text(... 'redirect_uris')` query narrowed by host (escaped LIKE, 500 ms, `LIMIT 50`, error = `:error` + ONE value-free WARNING).
  `SsoRedirect.listed?/2` passes the raw URL; the seam `:sso_trusted_origin_check` is `fn origin, raw_url`.
- **SEC #2 (MEDIUM, Logging Law).** Every `SsoStore` call catches the `:exit` (`put_*` -> `{:error, :unavailable}`, `pop_*` / `peek_*` -> `:error`),
  timeout 5000 ms with the compile-guarded seam `:nebu_http, :sso_store_call_timeout_ms`. Redirect leg: `503 M_UNAVAILABLE`; callback: 400 (state miss) or the
  503 page; confirm routes: the `invalid_state` / `unavailable` pages; Continue with an unavailable token store: the 503 page (entry already consumed).
- **SEC #4 / UX B1 / B2 / N1-N6 (arming and page).** `Nebu.Web.ArmScript`: `focusin` arms, Continue is `aria-disabled` (the script never touches `.disabled`),
  keyboard activation only after the focus moved onto Continue after arming, live region `[data-arm-status]` with "Continue is now available." / why a click
  was blocked, hint visible by default. Page: aria-describedby ids (`arm-hint`, `target-origin`, `confirm-notice`), `<code data-role="target-origin">`, notice
  without `role=status`, new wording, noscript text, per-page titles. Beyond the tests (kept fail closed, D19c): Continue carries `form="sso-confirm-armed"`
  (no such form) that arming removes, so without JavaScript the `aria-disabled` button is inert instead of submitting.
- **SEC #5 (audit).** `save_sso_origins/2` writes one audit row through the `:compliance, :audit_writer` seam per successful save (see D14).
- **SEC #9.** `:sso_redirect_schemes_reader` is compile-guarded (`if Mix.env() == :test`) in `Nebu.Matrix.SsoRedirect`.
- **MIN-2.** The POST accepts a single `Origin` equal to the Host-derived origin OR `https://<server_name>` OR with `Sec-Fetch-Site: same-origin` (D9).
- **MIN-3.** `SsoRedirect.valid_https_host?/1` is the one host validator (`SsoConfirmPage` calls it, no second regex there; `Nebu.OAuth`'s own origin regex lives in the
  OAuth domain by ADR-020).
- **MIN-6.** Dead branch of `SsoConfirm.handle/1` removed. **MIN-5.** This story file (status `done`, tasks ticked, D4 / D6 / D8-D10 / D14 / D15 prose).
  **MIN-4 / MIN-7** (test prose, shared e2e step selector) are test / e2e files and belong to the ATDD role.
- **N8-N10 (admin form).** `<label for>` + `aria-describedby` help block, restructured help text, the submitted value kept with `aria-invalid` and
  `<p id="sso-origins-error" role="alert">` on a rejected save.
- **Follow-ups (ids checked against `follow-ups.md`: `co` and `cp` are free; `cf`..`cn` are reserved for the G3-2 story).**
  **co** per-subject cap / counter for the `:confirm` store instead of the per-node fold (SEC #3: one IdP account holder can keep the 10 000 cap full; a per-IP
  bucket would act globally while the client IP is unresolved, G3-2). **cp** touch arming residual (SEC #4: multi-tap lures on touch devices).

Test results (fresh throwaway Postgres): changed / new files 636/636; neighbour suites `test/nebu/{matrix,web,oauth,admin,migration}` + `release_test.exs`
(`--include integration`): oauth 2450/2450, migration 217/217, matrix 1892/1893, web 654/656, admin 790/811; every failure is a known family
(`RegressionSyncLoadTest`, `LogStore.RetentionTest`, `RoomsFallbackNameTest`, `TraceMapNodeControlsTest`, `WarRoomTest`, `TemporaryCaptureManagerTest`,
`AdminOidcLoginTest`). On a REUSED database the order-dependent known tests `SsoLoginTest` (extra_redirect_schemes), `MatrixSsoTest` (callback loginToken) and
`OidcPlugTest` (denylisted token) fail from residue of earlier suites and pass on a fresh one. `mix compile --warnings-as-errors`: only the pre-existing Elixir 1.20
warning at `event_dispatcher/server.ex:4961`. `tsc --noEmit` and `bddgen --tags "@legacy-sso-confirm or @sso-redirect-origins"`: clean.

### Review cycle 2 (Kassandra delta check, LOW-1, LOW-2, INFO-2, INFO-3)

- **LOW-1 (real production bug, audit never written).** The action `sso_redirect_origins_changed` was missing from `@known_actions` of
  `Nebu.Compliance.AuditWriter`, so the real writer answered `{:error, :audit_unknown_action}` and the controller ignored it; the stub-writer test could not notice.
  Added to `@known_actions` (with the documenting comment like the OAuth actions; there is no DB CHECK on `audit_log.action`). `save_sso_origins` now matches
  the return value (a refused / raising writer logs ONE value-free WARNING `admin: the audit row of the SSO redirect origins change could not be written` and never
  undoes the save) and takes the actor from `Nebu.Admin.OAuthAdminHelpers.actor_id/1` (nothing is written without an actor). New integration tests run the REAL
  `AuditWriter` and read the `audit_log` row (actor, action, target, metadata) plus a refusing-writer test. The audit action list in the docs
  (`06-runtime.md`, `07-deployment.md`, ADR-033) is the orchestrator's.
- **LOW-2 (opener can fragment-navigate the COOP-less popup).** `Nebu.Web.ArmScript`: `scroll` no longer arms; `entered` is set ONLY from a mouse / pen
  `pointermove` over Continue with non-zero movement relative to the previous pointer position, after arming (`pointerenter` removed: it also fires on a layout or scroll
  change under a parked pointer); `hashchange` resets the button to unarmed (`aria-disabled="true"`, `form` restored, hint shown, status cleared) and restarts the
  dwell (a generation counter stops a pending timer of the old state). Tests adapted: `arm_script_test.exs` (no `scroll`, no `pointerenter`, movement comparison,
  new hashchange test); e2e steps / feature: comments, plus the new scenario "A scroll or a fragment change from the opener does not arm Continue".
- **INFO-2.** `ClientStore.approved_redirect_uris/1` matches `https://<host>` only followed by the end or one of `/ : ? #` (never `https://<host>.other/...`) and has an
  `ORDER BY c.client_id, u` so the `LIMIT 50` is deterministic (new tests).
- **INFO-3.** `redirect_with_login_token` answers `503 M_UNAVAILABLE` when the store does not answer (`{:error, :unavailable}`) instead of redirecting with a token that was
  never stored; the pre-existing decision for `:store_full` (redirect as before) and the happy path are unchanged. `SsoStore` emits ONE WARNING per minute per node when it
  swallows an exit, naming only the exit tag (`reason=timeout` / `noproc`), never the reason or a value (new tests).

Cycle 2 tests added or adjusted (this cycle the dev role may touch tests): new in `config_controller_sso_origins_test.exs` (real `AuditWriter` integration: known action, the
`audit_log` row, refusing writer), `oauth_trusted_redirect_origin_test.exs` (`approved_redirect_uris/1` host tightening, ordering, failure), `sso_store_unavailable_test.exs`
(`mint_login_token` unavailable, callback 503 for a listed target, the throttled exit-tag WARNING), `arm_script_test.exs` (no `scroll` arming, no `pointerenter`, movement comparison,
hashchange reset; adapted two older tests), e2e feature + steps (scenario "A scroll or a fragment change from the opener does not arm Continue", comments). Results (fresh DB,
`--include integration`): changed / new files 646/646; oauth 2453/2453, matrix 1895/1896, web 657/657, migration 217/217, compliance 29/29, admin 792/814; every failure a known family
(`RegressionSyncLoadTest`, `RoomsFallbackNameTest`, `TraceMapNodeControlsTest`, `WarRoomTest`, `TemporaryCaptureManagerTest`, `AdminOidcLoginTest`); only the pre-existing Elixir 1.20
compile warning; `tsc --noEmit` and `bddgen` clean.

### Test / story conflicts (cycle 0, RESOLVED)

Cycle 0 reported three groups of staged-test defects (26 tests): the flash accessor `conn.private[:phoenix_flash]` (21 tests), the redirect
leg's DEBUG line inside `capture_log` (4 tests) and the AC4.3 `refute log =~ host` that contradicted the mandated INFO line (1 test). The ATDD role
fixed all of them before review cycle 1 (tests now read the flash from assigns / session and start the leg before the capture); no conflict is open.

### Completion Notes

Story context created 2026-10-13 from the G3-3 finding, follow-up `by`, the owner decision and the code of
`sso_login.ex`, `sso_store.ex`, `http_public.ex`, the consent flow modules, the admin config path, `OidcConfig`,
migrations 000040/000042 and the existing SSO / OAuth tests. Verified with Elixir 1.20 `URI.parse/1`: it accepts
`https://evil.example\@listed.example/` with host `listed.example`, `http://evil.example\@localhost/` with host
`localhost` (an open redirect TODAY), `https:evil.example` with no host, and hosts containing CR/LF, tab, space and
non-ASCII characters, which is why D2 does not rely on `URI.parse/1` for the decision.
