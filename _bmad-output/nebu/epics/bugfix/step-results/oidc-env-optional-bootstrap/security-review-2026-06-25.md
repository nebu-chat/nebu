# Security Review — oidc-env-optional-bootstrap

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Date:** 2026-06-25
**Branch:** `bug/ssl-and-audience`
**Scope:** Make OIDC env vars optional at boot; Bootstrap-Wizard configures issuer/audience/JWKS URI; DB-backed `OidcConfig` fallback for `OidcPlug`.
**Verdict:** **PASS / CLEAN — no CRITICAL/HIGH/MEDIUM. 0 blocking findings.** 2 LOW, 2 INFO advisories.

---

## Summary

This is a mature cycle-2+ implementation. The obvious traps in this exact bug class — the
OIDC fail-open family that has recurred across multiple epics in this codebase (MEMORY
patterns #43, #57, #60, #66) — have all been pre-empted by the implementers, with inline
annotations crediting prior review cycles (M-1, M-2, C-1, C-2, MAJOR-1, MINOR-1, C1). I
attempted to break the fail-closed invariant, the bootstrap trust boundary, the new DB
fallback seam, and the new redirect; all held.

The central change — moving `NEBU_OIDC_ISSUER`/`NEBU_OIDC_AUDIENCE` from boot-time `raise`
to nil-default with a `server_config` DB fallback — is **fail-closed by construction** and
does not reintroduce the fail-open class.

---

## What was verified (all PASS)

### 1. Fail-closed invariant preserved (the headline risk)
`OidcPlug.oidc_issuer/0` and `oidc_audience/0` (oidc_plug.ex:444-456) read Application env
first, fall back to `OidcConfig.get()`. When BOTH sources are nil/empty:
- `check_issuer/1` (oidc_plug.ex:406-411) → `{:error, :issuer_not_configured}`
- `check_audience/2` (oidc_plug.ex:416-422) → `{:error, :audience_not_configured}` (covers both `nil` and `""`)
→ token rejected, 401 `M_UNKNOWN_TOKEN`. A pre-bootstrap deployment with no env vars
rejects 100% of tokens — fail CLOSED, not open. This is the inverse of MEMORY #57
("iss/aud check skips silently when config nil") — that exact hole is closed here.

Token verification path (`verify_token/2`, oidc_plug.ex:322-339) is unchanged: alg
allowlist (no `none`/HMAC, #MEDIUM-2), JWKS signature, exp-required, iss/aud fail-closed,
sub-required. No alg-confusion, no missing-claim acceptance.

### 2. New `OidcConfig` GenServer + ETS fallback — fail-closed under every failure mode
- ETS table is `:protected` (oidc_config.ex:164) — only the owning GenServer writes; no
  cross-process or attacker write path. Closes the M-4 concern from the scope.
- If the GenServer never started / crashed (table `:undefined`), `read_from_ets/0`
  (oidc_config.ex:143-158) returns `%{issuer: nil, audience: nil, jwks_uri: nil}` →
  fail-closed 401. The `rescue` arm also returns all-nil.
- `init/1` (oidc_config.ex:110-117) calls `do_refresh` → `load_from_db`, which guards on
  `Process.whereis(Nebu.Repo)` and catches `{:error, _}` returning all-nil (oidc_config.ex:176-195).
  It does NOT raise → a DB-down boot does not crash the supervisor; ETS holds all-nil →
  fail-closed.
- Supervision order (application.ex:50-71): `repo_children()` → `OidcConfig` → `JwksCache`.
  Repo is up before `OidcConfig.init`. Strategy `:one_for_one` → an OidcConfig crash
  restarts only it and re-reads the DB.
- `nilify/1` (oidc_config.ex:198-203) trims whitespace before the nil-check, so a
  whitespace-only stored value is treated as absent (fail-closed) and a trailing-space
  audience cannot cause a silent mismatch.

### 3. The `:oidc_config_source` seam is NOT attacker-reachable
The seam (oidc_config.ex:65) is read via `Application.get_env`. Grep confirms it — like the
sibling `:oidc_jwks` and `:bootstrap_cache_refresh_hook` seams — is written ONLY in tests,
never via any HTTP/runtime/config path. Application env is set at boot/test only. No
endpoint mutates it. Not abusable.

### 4. Bootstrap trust boundary intact (auth bypass / IDOR check)
- `BootstrapLive` route is INSIDE `live_session :admin, on_mount: {:require_admin}`
  (router.ex:73-86). Post-bootstrap, the wizard is admin-gated on BOTH static render and
  socket connect (MEMORY #61).
- Pre-bootstrap the wizard is intentionally world-reachable (`on_mount` deadlock-breaker,
  auth.ex:928-938) — but an anonymous actor driving steps 1–3 can only fill
  `bootstrap_draft`. **Completion** (`bootstrap_confirm_claim`, auth.ex:517-581) requires:
  (a) `bootstrap_completed?()` false, (b) a verified-OIDC `bootstrap_sub` in the draft,
  (c) the chosen admin claim ∈ `discovered_claim_values` of the verified ID token (the C1
  claim-injection guard). The minted admin session is bound to the verified `bootstrap_sub`.
  No anonymous takeover.
- `bootstrap_completed?/0` (auth.ex:957-989) fails CLOSED on DB error (returns true → wizard
  re-gated) — the prior HIGH-1 fix. Unchanged by this diff.
- No runtime path repoints the issuer post-bootstrap: `ConfigLive.save_refresh_mode`
  (config_live.ex:39-51) whitelists ONLY the two refresh-mode enum keys — it does NOT write
  `oidc_issuer`/`oidc_audience`/`oidc_jwks_uri`. Those keys are written exactly once, in the
  `bootstrap_completed?`-gated `do_complete_bootstrap`. No admin-repoints-IdP escalation.

### 5. Open redirect / reflected XSS — none
The new `/admin/login?error=auth_failed` redirect target (auth.ex:534, 547, 577) is a static
literal — no user input interpolated. `LoginController.index/2` (login_controller.ex:75-79)
ignores params entirely and serves a static HTML page; the `error` query param is never
reflected. No open redirect, no reflected XSS.

### 6. JWKS URI fallback (`JwksCache.http_fetch/0`) — sound
`uri = env :oidc_jwks_uri || OidcConfig.jwks_uri()` (jwks_cache.ex). nil URI → `{:ok, []}`
(no keys) → `select_key/1` returns `:no_keys` → fail-closed 401. The wizard's
`jwks_uri_valid?` guard (bootstrap_live.ex:149) + `do_complete_bootstrap` audience guard
prevent completing into a permanently-keyless state. (Note: the `:httpc` TLS-verify hardening
from MEMORY #55/#58 is in the pre-existing `do_fetch` and is out of this diff's scope — not
re-touched here.)

### 7. No plaintext secrets in logs
The only new log line logs `inspect(reason)` where `reason` is an atom
(`:audience_required` etc.) — never a secret. OidcConfig logs only DB/ETS error structs. The
OIDC client secret is AES-256-GCM-encrypted via `encrypt_secret` (MINOR-3, byte-parity with
Go) before draft storage and is never logged.

---

## Findings

### LOW-1 — `OidcConfig.refresh/1` is a public unauthenticated GenServer call (no network surface)
`refresh/1` (oidc_config.ex:94-97) is a public API forcing a DB re-read + cluster `:pg`
broadcast. There is no HTTP route to it; callers are `do_complete_bootstrap` (post-completion)
and tests. Not network-reachable, so not exploitable today. Advisory: if a future story ever
exposes a "reload config" admin endpoint, route it through the `:require_admin` gate and
rate-limit it (the `:pg` broadcast is a cheap cluster-wide amplification primitive).
**Non-blocking.**

### LOW-2 — `matrix_sessions` still has no RLS; `OidcConfig` adds a second node-local ETS auth-input cache
Carry-over advisory (already tracked). The new `OidcConfig` ETS cache joins `OidcClaimCache`
and the session caches as node-local auth-input state with no RLS on the source
`server_config` rows beyond the existing key-scoped UPDATE policy (MEMORY #24 — verify
`server_config` UPDATE policy still scopes `oidc_*` keys; this diff does not add a migration,
so no new RLS gap is introduced). **Non-blocking, informational.**

### INFO-1 — Cross-node `:pg` invalidation is broadcast-only, no version/quorum
`broadcast/0` (oidc_config.ex:207-215) sends `{:invalidate_oidc_config}` to peers, each
re-reading the DB. A peer that misses the message (transient partition) keeps stale config
until its next restart — there is no TTL-based periodic refresh on `OidcConfig` (unlike
`JwksCache`). In practice OIDC issuer/audience change exactly once (at bootstrap), so staleness
is bounded to the bootstrap moment and self-heals on any node restart. Acceptable for a
write-once value. If `oidc_*` ever becomes runtime-mutable, add a TTL refresh tick.

### INFO-2 — Story bundles two concerns on one branch
`bug/ssl-and-audience` also carries `postgres-ssl-env-var` (runtime.exs DB-SSL changes, not in
the OIDC scope). The SSL change was not reviewed here beyond confirming it does not touch the
OIDC/token path. Flag for the SSL story's own gate if not already covered.

---

## MEMORY patterns checked (no recurrence)

| Pattern | Status this diff |
|---|---|
| #57 OIDC iss/aud skips when config nil (Elixir fail-open) | **CLOSED here** — `check_issuer`/`check_audience` fail-closed on nil from BOTH env and DB |
| #43/#60 fail-open / empty-key-fallback at startup | Not reintroduced — all-nil ETS → 401 |
| #66 deactivation/bypass via skipped per-request re-check | Out of scope; token path unchanged |
| enum-as-selector-not-value (2026-06-23 session) | Held — issuer/audience are stored values, not output-string interpolants; no injection sink |

No new MEMORY pattern warranted — the team got the fail-closed shape right by construction.
