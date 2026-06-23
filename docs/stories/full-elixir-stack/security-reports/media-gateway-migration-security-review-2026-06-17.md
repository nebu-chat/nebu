# Security Review — media-gateway-migration (SEC Gate 1, story-level)

**Reviewer:** Kassandra (adversarial security review)
**Diff scope:** `git diff --staged` — Go media gateway ported into Elixir `core/apps/nebu_http` (`media.ex`, `media/{crypto,db,membership,storage,http_fetch,ssrf}.ex`, `router/media.ex`, `router.ex`, `runtime.exs`, `test.exs`, `docker-compose.yml`, `mix.exs`, `mix.lock`, `Dockerfile`). Targets deprecated `/_matrix/media/v3/*`.
**Date:** 2026-06-17
**Epic:** full-elixir-stack

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | **HIGH** | `router/media.ex` (no RateLimit plug) + `media.ex:150` `preview_url/1` | No rate limit on `preview_url` — authenticated outbound-fetch amplifier. Go gateway had one. | Add `NebuHttp.Plugs.RateLimit` to the media router pipeline (or inline on `preview_url`) with a strict per-IP tier. |
| F-2 | MEDIUM | `http_fetch.ex:58-69` `request/2` + `cap/1:80` | `preview_url` response body is fully buffered in memory by `Finch.request/2` before `cap/1` truncates → memory-DoS via a large/slowloris public response. | Stream the response and abort at `@max_body_bytes`, or set a transport-level max. |
| F-3 | MEDIUM | `http_fetch.ex:53-56` `do_fetch/2` (https branch) | Residual https-SNI DNS-rebinding TOCTOU: https targets re-resolve at Finch connect time; the pinned IP is not used. Documented but live. | Accept as documented LOW-risk follow-up OR implement SNI-preserving IP-pinned TLS (`Mint`/`Finch` `:hostname`/`conn_opts`). See assessment. |
| F-4 | MEDIUM | `media.ex:252-258` `serve_inline_image/4` (thumbnail) | Thumbnail serves decrypted bytes `inline` WITHOUT the `Content-Security-Policy: sandbox; default-src 'none'…` header that the download path sets; forces `image/png` Content-Type on arbitrary bytes. | Apply the same CSP+CORP header set as `serve_bytes/4` to the thumbnail response. |
| F-5 | LOW | `media.ex:209` + `db.ex` / `membership.ex` | IDOR-by-design: `member?(nil, user)` degrades to "member of ANY room". Bounded by unguessable 128-bit `media_id` (PK) capability-URL. Documented, fail-closed. | Accept as documented follow-up (schema `media_files.room_id`). See assessment. |
| F-6 | LOW | `runtime.exs` ExAws config / `storage.ex` | `NEBU_MINIO_USE_SSL` defaults to `false`; S3 credentials traverse the Compose network in cleartext on the MinIO hop. | Operator-only knob, internal network. Document that production object-store hops must set `USE_SSL=true`. |

---

## Detail

### F-1 — `preview_url` has NO rate limit (outbound-fetch amplifier) — **HIGH**

`NebuHttp.Plugs.RateLimit` exists and is applied to `POST /login` (`matrix_public.ex:67`, 30/min) and `/sync` (`protected.ex:44`, 600/min). It is **NOT** applied to the media router (`router/media.ex` pipeline is only `OidcPlug → match → dispatch`). The top-level `NebuHttp.Router` pipeline also carries no RateLimit plug.

`GET /_matrix/media/v3/preview_url?url=…` makes Nebu perform an **outbound HTTP fetch** to an attacker-chosen URL on every request. Any single authenticated user (a low bar — see threat model: a member of one room) can drive the core into making unbounded outbound requests:

* **SSRF-amplification / port-scanning:** even though `ssrf.ex` blocks private targets, an attacker can hammer arbitrary *public* hosts through Nebu's egress IP — using the server as a DoS reflector / scanner against third parties, with Nebu's reputation attached.
* **Resource exhaustion on the core:** each request allocates a Finch connection, a DNS lookup, and (per F-2) buffers up to 2 MB. Without a cap, concurrent `preview_url` calls exhaust the core's memory/sockets — and this is now the *same* OTP node that serves all chat traffic (no separate media process to absorb the blast).

This is the exact MEMORY pattern recorded against Epic 12: *"preview_url is an outbound-fetch amplifier — is there a rate limit? the Go gateway had one"* and *"Unauthenticated media endpoint + unbounded resource…every endpoint MUST have hard caps on input dimensions, output size, and concurrency."* The Go gateway enforced this; the migration dropped it. This is a **regression vs the Go original** and therefore in-scope as a HIGH (not an accepted gap).

**Why HIGH not MEDIUM:** exploitable with the lowest standard credential the system issues (any authenticated user in ≥1 room), no chaining required, directly weaponizes the server's egress. Same severity class as the Epic-12 XFF rate-limit-bypass HIGH.

**Remediation:** add a strict per-IP (or per-user) rate limit to the media router, e.g.
```elixir
@preview_rl NebuHttp.Plugs.RateLimit.init(rate_per_min: 12, burst: 4, tier: "media_preview")
# in preview_url/1, before SSRF.check:
conn = NebuHttp.Plugs.RateLimit.call(conn, @preview_rl)
if conn.halted, do: conn, else: ...
```
Upload should likewise carry an abuse cap (Go gateway parity).

### F-2 — `preview_url` buffers the full upstream body in memory before capping — MEDIUM

`http_fetch.ex` uses `Finch.request/2` (the non-streaming API). Finch accumulates the **entire** response body in memory and only then returns `%Finch.Response{body: body}`; `cap/1` truncates *after* the full body is already resident. A malicious (or compromised) public page can return a multi-gigabyte body (or a slow drip within the 5 s `receive_timeout` per chunk) and force the core to allocate it all before `cap/1` runs. `@max_body_bytes = 2_000_000` is therefore advisory, not enforced at ingress. Combined with F-1 (no rate limit) this is a clean memory-DoS of the core node.

**Remediation:** use `Finch.stream/5` and abort when the running total exceeds `@max_body_bytes` (mirror the streamed-counting pattern already used correctly in `media.ex:read_full_body/3` for uploads).

### F-3 — Residual https-SNI DNS-rebinding TOCTOU — MEDIUM (assessment: documented MEDIUM, acceptable as tracked follow-up; **not** CRITICAL/HIGH)

`ssrf.ex` is well-built: it resolves once via `checked_target/1`, checks **all** resolved addresses (closing the multi-record rebind), and `http_fetch.ex` pins the validated IP for `http` while preserving the `Host` header. For `https`, the hostname is kept in the URL (correct — IP-pinning breaks SNI/cert validation), so Finch re-resolves at connect time. A DNS server an attacker controls can hand the guard a public IP and Finch a private IP in the rebind window.

**Adversarial assessment of severity:**
* The window is small and requires attacker-controlled authoritative DNS with a sub-TTL flip timed to Nebu's resolve→connect gap.
* Even on a successful rebind to a private https endpoint, the attacker gets back only **OG meta tags parsed from the response body** (`extract_og_tags/1` surfaces only `meta[property^="og:"]`), not raw bytes/headers — so blind-SSRF exfil is heavily constrained (the internal target would have to serve attacker-readable `og:*` tags). It is **not** a general internal-content read primitive.
* `http` (the easier rebind, no TLS) **is** closed by IP-pinning.
* Finch does not follow redirects (confirmed: no `:follow_redirect`/`Finch` has no redirect option in `request/2`), so 3xx into a private host is not chased.

This is a genuine residual risk but is **MEDIUM**, acceptable as an explicitly-documented follow-up — it is not exploitable without attacker-controlled DNS infrastructure and yields constrained output. **It does not block the commit on its own.** Track the SNI-preserving-pin follow-up.

**Verified-CLEAN SSRF aspects (adversarial pass):**
* Scheme allowlist: `file://`, `gopher://`, etc. → `:bad_scheme` (line 57). ✓
* `169.254.169.254` cloud-metadata → `{169,254,_,_}` blocked (line 107). ✓
* IPv4 `0.0.0.0/8`, `10/8`, `127/8`, `172.16/12`, `192.168/16`, CGNAT `100.64/10`, multicast/reserved `≥224` all blocked. ✓
* IPv6 `::1`, `::`, `fc00::/7` ULA, `fe80::/10` link-local, and **IPv4-mapped `::ffff:a.b.c.d`** (re-checks embedded v4 — line 125) all blocked. ✓
* IPv6 literal in URL `http://[::1]/` → `URI.parse` strips brackets → `:inet.parse_address('::1')` → blocked. ✓
* Octal/decimal IP obfuscation (`http://0177.0.0.1`, `http://2130706433`) → `:inet.parse_address` is strict dotted-decimal and rejects these; they fall to `:inet.getaddrs`, which standard resolvers also reject. ✓ (Low residual — a non-standard resolver could differ; note only.)
* Default-deny fallthrough `defp blocked_ip?(_), do: true` (line 130). ✓

### F-4 — Thumbnail response missing CSP/sandbox header — MEDIUM/LOW

`serve_bytes/4` (download) sets `cross-origin-resource-policy: cross-origin` and a strict `content-security-policy: sandbox; default-src 'none'; script-src 'none'; …`. `serve_inline_image/4` (thumbnail, `media.ex:252`) sets CRP but **omits the CSP/sandbox** header, and serves bytes with `inline` disposition while forcing `Content-Type: image/png` for any non-image upload. The global `x-content-type-options: nosniff` (router before_send) is what actually prevents a `text/plain`-uploaded-HTML blob from rendering as HTML through the thumbnail endpoint — so this is **not** an active stored-XSS (nosniff holds), but it is an inconsistent defense-in-depth posture: the download path is hardened, the thumbnail path is not. Classify MEDIUM (defense-in-depth on a content-serving path).

**Remediation:** apply the same CSP+CORP headers to `serve_inline_image/4` as `serve_bytes/4`.

### F-5 — IDOR by design: `member?(nil, user)` = "member of any room" — LOW (assessment)

`db.ex` returns `room_id: nil` for every production row (the `media_files` table has no `room_id` column — confirmed in `gateway/migrations/000001_init.up.sql:288`), so `with_authorised_media/4` calls `Membership.member?(nil, user)`, which is true for any user in ≥1 room. Net: any authenticated user who belongs to at least one room can download any media id whose 128-bit random `media_id` they possess.

**Adversarial assessment — why LOW, not HIGH:**
1. `media_id` is the table PRIMARY KEY, generated as `:crypto.strong_rand_bytes(16) |> url_encode64` (128 bits, CSPRNG). The lookup requires the exact `media_id`; there is no enumeration vector. This is a **capability-URL**: an attacker cannot fetch "any media" — only media whose unguessable id they already hold, which in practice means media shared into a room they can see the event for.
2. It is **fail-closed**: a user in zero rooms or an unknown user is denied 403 (verified by test `media_access_control_test.exs:100`).
3. Matrix `/_matrix/media/v3/*` is an **unauthenticated** content repo per spec; the 403 membership gate is a Nebu *extension* (stricter than spec, per AC4 and oracle context). The migration is therefore strictly more restrictive than the protocol baseline.
4. It is **not a regression** vs the Go gateway (the Go path used a gRPC `CheckMembership` but `media_files` never carried `room_id` either — the per-media scoping never existed).
5. Documented loudly in `db.ex` and `membership.ex` moduledocs as a known, tracked, schema-blocked follow-up.

The combination of (CSPRNG capability id) + (fail-closed) + (stricter-than-spec) + (no regression) + (documented) makes this a **LOW** accepted-gap, not a HIGH IDOR. It does **not** block the commit. Recommend the tracked follow-up adds `media_files.room_id` (or a join table) so the membership check pins the actual room.

### F-6 — MinIO transport defaults to plaintext — LOW

`runtime.exs` defaults `NEBU_MINIO_USE_SSL` to `"false"` → ExAws `scheme: "http://"`. S3 credentials (SigV4-signed, so the secret key is not on the wire, but the access key id and object bytes are) traverse the internal Compose network in cleartext. This mirrors the existing Go/MinIO Compose posture and matches the MEMORY pattern *"fence USE_SSL=true as a non-overridable template constant in production-targeting cloud-init blocks"* (stackit-objectstore). Internal-network-only, operator-controlled, no attacker influence. LOW/advisory.

---

## Specifically-cleared items (adversarial verification)

* **Crypto correctness (`crypto.ex`):** AES-256-GCM via `:crypto.crypto_one_time_aead`; key 32B / nonce 12B enforced by guard; encrypt returns `ciphertext <> tag` (Go `gcm.Seal` parity); decrypt splits trailing 16B tag and passes it as the GCM tag with the `false` (verify) flag — **tag verification is mandatory and not bypassable** (a mismatch returns the `:error` clause → `{:error, :decrypt_failed}`). Per-object fresh `key = strong_rand_bytes(32)` and `nonce = strong_rand_bytes(12)` (`media.ex:89-90`) → **nonce uniqueness per object** holds (random 96-bit nonce, unique key per object — no nonce-reuse-under-same-key risk). No key/nonce/plaintext is logged (grep of all media modules: zero Logger/IO calls). ✓
* **Key escrow (ADR-011):** `aes_key_hex`/`nonce_hex` stored plaintext in `media_files` — this is the sanctioned server-side managed-E2EE model and matches the Go original; **not** a finding per the coordinator's accepted-list. Verified the keys are handled no worse than Go (strong RNG, no reuse, no logging). ✓
* **SQL injection (`db.ex`, `membership.ex`):** all queries use `Ecto.Adapters.SQL.query/3` with `$1/$2` parameter binding; `server_name`/`media_id`/`user_id`/`room_id` flow only as bound params — no interpolation. ADR-018 inline SQL is sanctioned. ✓
* **Path traversal into S3 key:** `storage_key = media_id`, and `media_id` is server-generated CSPRNG (`url_encode64`, charset `[A-Za-z0-9_-]`, no `/` or `.`) — never attacker-controlled. On download, `media_id` comes from the URL but is used only as an S3 object key + SQL bound param; a crafted `../` cannot escape the bucket (S3 keys are flat; and the lookup must first match a DB row). No path traversal. ✓
* **Body-size limit (F1/F3 dev fixes — verified holding):** `read_full_body/3` accumulates in 1 MB chunks and bails on `byte_size(acc) > max_bytes` → **a lying low Content-Length with a huge body is caught by the streamed counter** (`over_content_length?` is only an early-reject). `{:error, _}` mid-stream → `{:read_error}` → 400, never persists a partial body (F1). Empty body / Plug.Parsers-consumed JSON body → `{:ok, ""}` → 400, nothing stored (F3). Both verified against `media_upload_test.exs:129/147`. ✓
* **JsonBody 1 MB cap interaction:** the top-level `JsonBody` plug (`length: 1_000_000`, `pass: ["*/*"]`) runs before the media forward, but with `pass: ["*/*"]` it does **not** read non-JSON bodies, so binary uploads (`image/*`, `application/octet-stream`) reach the handler's own 50 MB limiter unimpeded; a JSON-typed upload is consumed by the parser → handler sees empty → 400 (F3). Correct. ✓
* **Blocked upload types (stored-XSS prevention):** `text/html`, `application/xhtml+xml`, `text/javascript`, `application/javascript`, `image/svg+xml`, `application/x-shockwave-flash` rejected at upload (`media.ex:43`). Download serves a server-controlled inline allowlist (`@safe_inline_types`) with `attachment` + `application/octet-stream` for everything else; global `nosniff`. ✓ (thumbnail CSP gap → F-4.)
* **Range handling (`parse_range_spec/2`):** negative start → `:unsatisfiable` (416); start ≥ total → 416; `end` clamps to `total-1` via `min`; `stop < start` → 416; suffix/multipart not supported → `:none` (full body). `binary_part/3` indices are pre-clamped so no huge/overlapping allocation or out-of-range crash. Object is already fully decrypted in memory (settled design), so no extra alloc from ranges. No DoS / no info-leak beyond the (already-authorized) object. ✓
* **S3 endpoint config:** `NEBU_MINIO_ENDPOINT` / ExAws host is operator-set via env/Compose, not attacker-influenceable. Safe. ✓
* **Secrets handling:** MinIO keys read from file-based Docker secrets (`runtime.exs` `File.read! |> String.trim`); not echoed to env in the rendered config beyond ExAws app-env (standard); S3/DB errors map to generic `502 M_UNKNOWN` / `404 M_NOT_FOUND` (`storage.ex`, `db.ex`, `media.ex:230`) — **no credential/endpoint/stack detail leaks to the client**. ✓
* **Auth gate:** every media route sits behind `OidcPlug` in `router/media.ex` (verified 401 tests for upload/download). The `forward "/_matrix/media"` is ordered before the catch-all `/_matrix` forward (top-down match). No NEW JWT issue introduced — media reuses `current_user` (the canonical `@user:server`) as the trusted identity. ✓
* **Open redirect / SSRF on S3 / command injection:** none present. ✓

---

## Note for epic-end (SEC Gate 2)

Per the MEMORY pattern *"Per-story CLEAN reviews can stack into combined HIGH at epic-end"*: F-1 (no media rate limit) and F-2 (unbounded preview buffer) are individually scoped here but **compound** into a memory/egress DoS of the single core OTP node now that no separate media process absorbs the blast. The matrix-api-migration story already flagged that no proxy fronts `core:4000`. Re-evaluate the aggregate DoS surface of the un-rate-limited `core:4000` listener at epic end.

---

## Summary

CRITICAL: 0
HIGH: 1 — F-1 (preview_url has no rate limit; outbound-fetch amplifier; regression vs Go) — **blocks commit**
MEDIUM: 3 — F-2 (unbounded preview body buffer), F-3 (residual https-SNI rebind TOCTOU, documented/acceptable), F-4 (thumbnail missing CSP)
LOW: 2 — F-5 (member-of-any-room IDOR, documented capability-URL-bounded accepted gap), F-6 (MinIO plaintext transport default)

**Verdict: BLOCKED** — F-1 (HIGH) must be remediated (add a rate limit to the media router / `preview_url`) before commit. F-2 and F-4 should be fixed in the same pass (both cheap). F-3 and F-5 are accepted, documented follow-ups and do not block.

---

## Re-review (cycle 2) — 2026-06-17

**Scope:** Verification re-review of the dev's fixes for F-1, F-2, F-4 against the cycle-2 staged diff (touches only `core/apps/nebu_http` media files + `router.ex`/`application.ex`). Adversarial scan for NEW issues introduced by the fixes.

### Resolution status

| # | Prior | Status | Verification |
|---|-------|--------|--------------|
| F-1 | HIGH | **RESOLVED** | `router/media.ex` now applies `NebuHttp.Plugs.RateLimit` inline to both expensive routes. `preview_url` = strict tier **30/min burst 10** (Go `strict` parity); `upload` = **600/min burst 5** (Go media upload-tier parity). Pattern mirrors `protected.ex`: module-attr `init/1` + `RateLimit.call` + `if conn.halted, do: conn`. Limiter halts with **429 `M_LIMIT_EXCEEDED` + `Retry-After`** (`rate_limit.ex:121-129`) and keys on `conn.remote_ip` (`ip_key/1`, not a spoofable header). Deterministic test (`url_preview_test.exs:146`) fires burst (10×200) then asserts the 11th → 429 + errcode + `Retry-After ≥ 1`, pinning a fixed peer IP. **HIGH closed.** |
| F-2 | MEDIUM | **RESOLVED** | `http_fetch.ex` replaced `Finch.request/2` with `Finch.stream_while/5`. `on_chunk/2` keeps a running `byte_size(body)` total and **halts mid-stream** (`{:halt, acc}` when `remaining <= 0`; partial-chunk truncation via `binary_part(data, 0, remaining)`) — the full upstream body is never materialized. Cap = **1 MiB** (`@max_body_bytes 1_048_576`), `receive_timeout` 5 s preserved, SSRF IP-pin (http) + SNI handling (https) unchanged. Trailers ignored (`{:trailers, _} -> {:cont, acc}`, no accumulation); headers are bounded by Mint/Finch's own limits, not by this code — no unbounded-header OOM. **OOM vector closed.** |
| F-4 | MEDIUM | **RESOLVED** | `media.ex:252 serve_inline_image/4` (thumbnail) now sets the identical `content-security-policy: sandbox; default-src 'none'; script-src 'none'; …` plus `cross-origin-resource-policy: cross-origin` that `serve_bytes/4` sets. Test (`media_thumbnail_test.exs:112`) asserts CSP contains `sandbox` + `default-src 'none'` and CORP == `cross-origin`. **Parity achieved.** |
| F-3 | MEDIUM | **STILL ACCEPTED** | https-SNI rebind TOCTOU caveat intact and clearly documented in `http_fetch.ex` moduledoc (lines 16-24). Behavior unchanged. Documented follow-up, not a blocker. |
| F-5 | LOW | **STILL ACCEPTED** | member-of-any-room note unchanged; capability-URL bound (128-bit CSPRNG `media_id`) + fail-closed intact. Documented follow-up, not a blocker. |

### Adversarial scan of the cycle-2 diff (NEW issues)

- **Limiter ordering / bypass:** Upload limiter runs **before** `Media.upload` (`router/media.ex:56-57`) → a 429'd upload never reads the body, encrypts, or hits S3 (cheap reject — correct). Both amplification-bearing routes (upload, preview_url) are limited; download/thumbnail are cheap DB+S3-GET paths with no egress amplification and no body read, consistent with the Go tiering — **no single-route bypass.**
- **Finch.stream_while edge cases:** non-200 / redirect (Finch no-follow, unchanged) / empty body / connection error all flow through `on_chunk` or the `{:error, reason}` clause without crashing; status/headers/body are returned verbatim for the handler to classify. No 500/stack-trace leak introduced. SSRF IP-pin + `Host` header preservation unchanged.
- **Secret/endpoint leak:** none introduced. The new `application.ex media_children/0` starts the Finch pool by name only; no credentials.
- **Warnings-as-errors:** `mix test --warnings-as-errors` for `nebu_http` is **clean** (no warnings).
- **New CRITICAL/HIGH:** none.

### Test result

`nebu_http` (isolated, `--warnings-as-errors`): **75 passed, 0 failures, 29 excluded** (integration tag). The event_dispatcher UpgradeRoomTest / Repo-not-started / `:db_down` failures are pre-existing Horde/DB-down test noise in other umbrella apps, unrelated to this diff — not treated as findings or regressions.

### Re-review summary

CRITICAL: 0
HIGH: 0 (F-1 resolved)
MEDIUM: 0 open (F-2, F-4 resolved; F-3 accepted/documented follow-up)
LOW: 0 open (F-5, F-6 accepted/documented follow-ups)
NEW findings: 0

**Re-review verdict: CLEAN — APPROVED.** F-1/F-2/F-4 fixes close their findings, are covered by deterministic tests, and introduce no new CRITICAL/HIGH. F-3/F-5/F-6 remain documented, accepted follow-ups and do not block the commit.
