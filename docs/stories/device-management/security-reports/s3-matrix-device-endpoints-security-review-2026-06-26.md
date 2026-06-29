# Security Review — device-management S3 (Matrix device endpoints + UIA-gated delete)

**Reviewer:** Kassandra (adversarial security reviewer)
**Date:** 2026-06-26
**Branch:** feature/device-management
**Diff scope:** `git --no-pager diff --staged -- server/` (full changed files read, not just hunks)
**Story:** s3-matrix-device-endpoints — device rename/delete/bulk-delete behind a UIA
fresh-auth gate (Option B, `m.login.sso`, 15-min window), a per-device bound-JWT
kill-switch (F-1), and device_id ingress validation (F-2).

This review carries the pre-registered S3 SEC-Gate-1 watch-list (MEMORY.md "Epic
Watch-List — device-management", S3 block) and the S1+S2 mid-epic carry-forwards. Each
watch-list item is adjudicated CLOSED / OPEN below. The per-story green tests were NOT
trusted — the exploit paths were re-derived from the code.

---

## Verdict: BLOCKED — 1 HIGH.

The kill-switch (F-1), device_id validation (F-2), IDOR posture (G3), single-use UIA
consume (G2), refresh-does-not-reset-auth_time (G1), and the unbounded-growth carry-
forwards (S1+S2 F-1/F-4) are all CLOSED and independently re-verified. **One watch-list
HIGH is OPEN and shipped exactly as predicted:** the UIA `m.login.sso` completion does
NOT bind the freshly-authenticated IdP identity (`sub`) to the UIA session's user — so a
fresh login by ANY IdP account satisfies the step-up for ANY user's pending sensitive op.
This is the precise "fresh-auth that trusts an SSO round-trip instead of a verified
identity is theater" defect (recurring pattern #69) the design-phase review flagged for
S3. It blocks the commit.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| H-1 | **HIGH** | `sso_login.ex:200-205,234-247` (`do_callback`/`complete_uia`) + `uia.ex:157-181` (`complete/1`) | **UIA `m.login.sso` completion is not bound to the freshly-authenticated identity.** `complete_uia` calls `Uia.complete(session_id)` with NO claims; `complete/1` flips `stage_complete = TRUE` and refreshes `auth_time` for the UIA session's bound `user_id` keyed only by `session_id`, never comparing `UserId.from_claims(claims)` to that `user_id`. Any IdP account that completes the fallback SSO satisfies the step-up for a victim's pending op. Defeats the step-up against the exact threat it exists for (hijacked / walked-up-to open session). | Thread the verified `claims` from `do_callback` into `complete/1`; require `UserId.from_claims(claims, server) == uia_sessions.user_id` (add `AND user_id = $sub` to the `complete` UPDATE) — mismatch → `:error`, render no completion. Also bind to `conn.assigns[:current_user]` at consume time (already holds via `user_id = $2`). |
| M-1 | MEDIUM | `sso_login.ex:91-105` (`do_redirect` authorize query) | **UIA SSO authorization request omits `max_age`.** Only `prompt=login` is sent. `prompt=login` is advisory — several IdPs honour an existing SSO-session cookie and re-issue without a real credential re-challenge. The story's Option-B freshness then rests on an `auth_time` the IdP may set to an OLD value, yet the gate treats stage-complete as fresh regardless. Sending `max_age=<window>` forces the IdP to re-authenticate (or refuse) within the window and makes the returned `auth_time` trustworthy. | Add `"max_age" => Integer.to_string(Nebu.Matrix.Uia.window_seconds())` to the authorize query on the UIA-fallback path; on the callback, additionally assert `now - claims["auth_time"] <= window` (fail-closed on missing/non-integer). Pairs with H-1's sub-binding. |
| L-1 | LOW | `uia.ex:175` + `matrix_session_store.ex:361-371` (`refresh_auth_time`) | **A UIA completion refreshes `auth_time` for ALL of the user's opaque sessions, not just the device that re-authenticated.** Once H-1 is fixed this is benign (only the legitimate user can trigger it), but it widens the fresh-auth window cluster-wide for every device the user holds, slightly beyond the "this caller just re-proved themselves" intent. | Acceptable post-H-1; optionally scope the refresh to the requesting session's device, or accept as a documented design choice. |
| L-2 | LOW | `device_binding.ex` ETS cache + `token_denylist.ex` ETS | **Cross-node revocation lag on the JWT kill-switch (DB-backed, bounded).** `revoke_by_hash/2` writes ETS (local node) + DB. A bound JWT presented on a DIFFERENT node misses that node's ETS but is caught by `OidcPlug` → `revoked?` DB fallback (`db_revoked_any?`), so it fails closed. The binding cache TTL (60s) could briefly resolve a deleted device on another node, but the token is independently denylisted, so no auth is granted. Not a kill-switch hole. | None required — DB fallback closes it. Noted for completeness. |

---

## Detail

### H-1 — UIA completion is identity-unbound (HIGH, blocks commit)

**The chain (re-derived from code):**

1. A sensitive op (`DELETE /devices/:id`, `POST /delete_devices`) with a stale window
   hits `uia_gate` → `challenge/4` → `Uia.mint_session(user_A, "delete_devices",
   canonical)` (`protected.ex:1272-1274`). A row is written to `uia_sessions` bound to
   `user_id = A`, and the `session_id` is returned to the client in the `401` challenge
   body (`uia.ex:96-99`). The `session_id` is a bearer-grade string handed to the client.

2. Completion is out-of-band and **UNAUTHENTICATED**: `GET /_matrix/client/v3/auth/
   m.login.sso/fallback/web?session=<id>` → `SsoLogin.uia_fallback/1`
   (`http_public.ex:73-75`, `sso_login.ex:137-152`). It only checks `Uia.load(session_id)`
   (row exists + not expired) — it does **not** require the caller to already hold A's
   token. It then `do_redirect(conn, "https://uia.local/complete", session_id)`, tagging
   the SSO `state` with `uia_session = session_id` (`sso_store.ex:279-282`).

3. The IdP callback `do_callback` (`sso_login.ex:184-227`) verifies the returned
   `id_token` via the shared `OidcPlug.verify_token/2` and checks the `nonce`. Because
   `entry.uia_session` is set, it calls **`complete_uia(conn, entry.uia_session)`**
   (line 205). `complete_uia` (lines 234-247) calls **`Uia.complete(uia_session)`** —
   passing only the session id, discarding `claims` entirely.

4. `Uia.complete/1` (`uia.ex:157-181`) runs
   `UPDATE uia_sessions SET stage_complete = TRUE WHERE session_id = $1 AND consumed =
   FALSE AND expires_at > $2 RETURNING user_id`, then `refresh_auth_time(user_id, now)`.
   **There is no `AND user_id = <verified sub>` clause and no comparison of
   `UserId.from_claims(claims)` to the row's `user_id`.** Whoever authenticated — any
   valid IdP account — flips A's session to stage-complete and resets A's `auth_time`.

5. The op re-submit with `auth: {"session": <id>}` reaches `uia_gate` →
   `Uia.consume(session, user_A, op, params)` (`protected.ex:1254-1259`). `consume`
   requires `user_id = $2` = A and `stage_complete = TRUE` — both now hold — so it
   succeeds and the devices are deleted.

**Why it is exploitable / why the step-up fails:** The step-up exists to stop a holder of
a victim's *open session* (shared/hijacked device, stolen opaque AT, a walked-up-to
logged-in client) from performing a sensitive op without re-proving the human. With H-1,
the attacker who holds A's token but does NOT know A's IdP credentials completes the
`m.login.sso` fallback with **their own** IdP account; the server marks A's session fresh;
the attacker re-submits A's token and the consume passes. The "fresh m.login.sso"
requirement is satisfied by an unrelated identity — exactly recurring pattern #69 ("a
fresh-auth gate that trusts an SSO round-trip instead of a verified, identity-bound
auth_time is theater"). The design-phase watch-list pre-registered this as a HIGH MUST-FIX
for S3 ("UIA SSO completion must bind the freshly-authenticated `sub` to the UIA session's
user AND the access-token user … REQUIRE `UserId.from_claims(claims) == uia_session.user_id
== conn.assigns.current_user`"). It was not implemented.

**Test gap that masked it:** `device_endpoints_test.exs` `complete_uia_sso!/2`
(lines 390-417) always signs the completion id_token with `current_sub()` — i.e. the SAME
user. The one "foreign session" test (lines 881-917) tests the *other* direction (user B
presenting A's session for B's own op, which `consume`'s `user_id = $2` correctly blocks).
No test signs the completion with a DIFFERENT sub than the session owner, so the missing
sub-binding in `complete/1` is never exercised. Add: A challenged → completion id_token
signed for attacker B's sub → A re-submits A's token → MUST be `401` (session never went
stage-complete for A).

**Remediation:** pass `claims` from `do_callback` into `complete_uia`/`complete`, derive
`UserId.from_claims(claims, server_name)`, and add `AND user_id = $sub` to the `complete`
UPDATE (so a mismatched sub flips nothing and `complete/1` returns `:error`); render no
completion page on mismatch. Combine with M-1 (`max_age` + `auth_time` window assertion)
to anchor freshness to verifiable evidence.

### M-1 — missing `max_age` on the UIA authorize request

`do_redirect` builds the authorize query with `"prompt" => "login"` only
(`sso_login.ex:101-105`). `prompt=login` is a request, not a guarantee: an IdP with a live
SSO cookie may re-issue an id_token whose `auth_time` is old without a human re-challenge.
The Option-B gate then treats the completed stage as fresh and resets `auth_time = now`
regardless of the id_token's actual `auth_time`. Sending `max_age=<window>` forces the IdP
to re-authenticate within the window (or error), and the callback should additionally
assert `now - claims["auth_time"] <= window` (fail-closed on missing/non-integer
`auth_time`). The login-path `auth_time` capture itself is correct
(`http_public.ex:477-488`: prefer `auth_time`, fall back to `iat`, nil → stale).

### Watch-list adjudication (S3 SEC-Gate-1 + S1/S2 carry-forwards)

| Watch-list item | Result |
|---|---|
| **G1 — refresh must NOT reset auth_time** | **CLOSED.** `rotate_tokens/1` reads `auth_time` from the old row and inserts it VERBATIM (`matrix_session_store.ex:173-190`); `create/1` sets it from the login claim only; the ONLY other writer is `refresh_auth_time/2` (UIA completion, gated by H-1). No path writes `NOW()` into `auth_time` on refresh. |
| **G1 — fresh? boundary / units / nil / window<=0** | **CLOSED.** `fresh?/1` uses `System.system_time(:second) - auth_time < window_seconds()` — seconds throughout (auth_time, exp, UIA TTL all unix seconds); STRICT `<` so a 0 window is always stale (`now-at >= 0` is never `< 0`); `fresh?(nil)`/non-integer → `false` (stale). runtime.exs only applies a strictly-positive `NEBU_UIA_FRESH_AUTH_SECONDS`. |
| **G2 — single-use / TOCTOU on consume** | **CLOSED.** `consume` is one atomic `UPDATE … SET consumed=TRUE WHERE … consumed=FALSE` returning `num_rows`; PostgreSQL row-lock makes the consume race single-winner on a node, and the row is the authoritative shared state (DB-backed, ADR-020), so two concurrent re-submits cannot both consume. |
| **G2 — session bound to (user, op, params); foreign user / wrong op / retarget** | **CLOSED for the consume leg.** `consume` filters `user_id = $2 AND op = $3 AND params = $4`; `canonical_params` sorts+JSON-encodes the device-id list so a different target set or op never matches. **OPEN for the completion leg — see H-1** (completion is the unbound step, not consume). |
| **G2 — session id entropy / fixation / client-chosen** | **CLOSED.** `random_id/0` = 32 bytes `:crypto.strong_rand_bytes` hex (256-bit). The client never supplies a session id at mint; `mint_session` always generates it. The fallback only LOADS an existing id, never creates one with a client value. |
| **G3 — IDOR rename/delete; foreign device 404, no oracle** | **CLOSED.** rename scopes `WHERE user_id=$1 AND device_id=$2` → 0 rows → `:error` → 404. delete checks `belongs_to_other_user?` (foreign → 404 BEFORE any UIA challenge, so no existence/timing oracle differing from the idempotent-200 absent case — both go through identical paths shape-wise). Bulk: each element `unless belongs_to_other_user?` → foreign ids silently skipped, scoped to caller. `user_id` is always `conn.assigns[:current_user]`, never body-supplied. |
| **F-1 — kill-switch completeness (hash alignment)** | **CLOSED.** `DeviceBinding.list_for_user_device/2` returns the stored `token_hash` (= `SHA-256(token)` lower-hex, `hash/1`); `TokenDenylist.revoke_by_hash/2` inserts ETS `{:hash, hex}` + DB plain-hex, the SAME key `revoked?` computes from the live token via `hash_key/1`/`hash_db_key/1`. Aligned — no silent no-op. |
| **F-1 — denylist exp outlives token; can't be un-revoked early** | **CLOSED.** `exp` carried from the verified JWT into the binding (`put/4`, login `http_public.ex:416`, lazy-bind `protected.ex:1399`), then into `revoke_by_hash(token_hash, exp)`; `revoked?` treats the entry live while `exp > now` — i.e. until the token's own expiry. A nil exp → no kill-switch entry but the token expires anyway. |
| **F-1 — self-delete "symmetric preserve" doesn't keep a token that should die / skip wrong token** | **CLOSED.** Preserve is `nil` UNLESS the op was satisfied by a FRESH re-auth (`via_auth=true`) — i.e. the user just re-proved themselves this request, so sparing the live request credential is correct. The skip is keyed on BOTH `device_id == preserve_device AND token_hash == preserve_token_hash` (`protected.ex:1334`), so only the exact live token on the exact own device is spared; all OTHER JWTs on that device are still revoked. The recent-login (`via_auth=false`) path preserves nothing → the presented token bound to the deleted device IS revoked (AC3). |
| **F-1 — fail-open if DB write fails** | **LOW residual (L-2).** `revoke_by_hash` is best-effort; an ETS-only write on a single node + a failed DB write means another node's `revoked?` DB fallback would miss it. Single-node: ETS suffices. Multi-node: a DB outage during delete could leave a bound JWT valid on a peer node until its exp. Same best-effort contract as the rest of the denylist; bounded by token exp. Not a new S3 regression. |
| **F-1 — unbounded jwt_device_bindings growth (S1/S2 carry-forward)** | **CLOSED.** 000012 adds `exp BIGINT`; the new supervised `Nebu.Matrix.Session.Sweeper` (`DELETE … WHERE exp IS NOT NULL AND exp < now`, hourly) is wired into `application.ex` `repo_children` (started with the Repo). |
| **F-2 — device_id <=255 / control-char at BOTH sinks** | **CLOSED.** `DeviceId.valid?/1` checks `byte_size <= 255` (byte length, not graphemes — multibyte cannot inflate past the cap) and rejects `\x00-\x1f` + `\x7f`. Applied at login (`http_public.ex:269`, present-but-invalid → 400 BEFORE verify/provision) AND `/keys/upload` body `device_keys.device_id` (`protected.ex:328`, before any store touch). The authoritative device sink (bound device from OidcPlug) is server-generated/validated. |
| **F-4 — ETS binding cache invalidated on delete** | **CLOSED.** `DeviceBinding.delete_for_user_device/2` calls `cache_delete(h)` for each token-hash before the DB delete (`device_binding.ex:124`), so a deleted device's binding is not served stale from cache. |
| **/delete_devices array cap / dedupe** | **OPEN — MEDIUM-adjacent, downgraded to NOTE.** The watch-list asked for a ≤100 array cap → 400. The handler filters to binaries but applies NO length cap and NO dedupe (`protected.ex:436-450`); each element runs `belongs_to_other_user?` + `delete_one_device` (several DB ops each). A single body could pack thousands of ids → amplification. Authenticated + UIA-gated + per-IP-rate-limited-elsewhere mitigates, and the global 1 MB body cap bounds it to ~tens of thousands of ids. Recommend adding `length(ids) > 100 → 400` and `Enum.uniq`. Not commit-blocking on its own, but should land with the H-1 fix. |

### Standard-scope sweep

- **SQL injection:** all new SQL is parameterised. The one interpolation —
  `delete_device/2` `DELETE FROM #{table}` (`device_key_store.ex:355`) — iterates a
  HARDCODED literal list `["device_one_time_keys","device_fallback_keys","device_keys","devices"]`;
  `table` is never attacker-influenced. SAFE.
- **Unauthenticated fallback endpoint:** `uia_fallback` validates `session` exists/not-
  expired (unknown → 400, no oracle beyond "is this a live session id", which is a 256-bit
  secret). `redirectUrl` is a fixed internal marker (`https://uia.local/complete`), so no
  open redirect on this path; the normal SSO redirect path still enforces the scheme
  allow/deny-list (`redirect_url_allowed?`). Body-size: global 1 MB `JsonBody` cap (GET, no
  body anyway). Rate limit: not on the `/auth` forward specifically — recommend a per-IP
  limit since it drives an IdP round-trip + DB writes (defence-in-depth; SsoStore is
  capped at 10k pending states with 429). CSRF/fixation: state is server-minted 128-bit,
  single-use, nonce-checked — sound; the H-1 sub-binding is the open item, not state CSRF.
- **postMessage("authDone","*"):** wildcard target origin (`sso_login.ex:244`). The page
  posts only the constant string `"authDone"` (no token, no session id, no claims), so a
  malicious `window.opener` learns only "an auth completed" — no secret leaks. LOW/info;
  could tighten to the server origin but no data exposure.
- **Secrets in logs:** no token / auth_time / session id / id_token logged. SSO failures
  log `inspect(reason)` (no token); login logs `user_id`/`device_id` only; denylist logs a
  key (jti or hash, not the raw token). Clean.
- **Migration safety:** 000012 is a NEW forward migration (000009-000011 untouched),
  idempotent (`ADD COLUMN IF NOT EXISTS`, `CREATE TABLE/INDEX IF NOT EXISTS`), inline SQL
  (ADR-018), `release_test.exs` bumped to `[1..12]`. `auth_time`/`exp` nullable → pre-
  migration rows read as stale (fail-closed). Down migration reverses cleanly.
- **Weak crypto:** none. SHA-256 for token-hash/PKCE (appropriate, non-reversible
  identifier use), `:crypto.strong_rand_bytes` for all ids, Ed25519/asymmetric JWT verify
  unchanged. No md5/sha1/DES.
- **RLS:** `uia_sessions` ships with no RLS — consistent with the whole auth-table family
  (`matrix_sessions`, `device_keys`, `devices`, `jwt_device_bindings`); every query is
  application-scoped by `user_id`/`session_id`. Standing family-wide defense-in-depth gap
  (S1/S2 F-5), not an S3 regression.

---

## Summary

- CRITICAL: 0
- HIGH: 1 — **H-1** (UIA completion not bound to the freshly-authenticated identity;
  `sso_login.ex:200-205,234-247` + `uia.ex:157-181`) — **blocks commit**
- MEDIUM: 1 — M-1 (missing `max_age` on the UIA authorize request) [+ the /delete_devices
  array-cap NOTE, fix alongside H-1]
- LOW: 2 — L-1 (auth_time refresh broadened to all of the user's sessions; benign post-H-1),
  L-2 (cross-node kill-switch lag, DB-fallback-bounded)

**Verdict: BLOCKED.** Fix H-1 before commit: bind the verified `sub` from the UIA SSO
completion to the `uia_sessions.user_id` (add `AND user_id = <UserId.from_claims(claims)>`
to `complete/1`, threading `claims` through `complete_uia`), and add the cross-sub
completion regression test. Land M-1 (`max_age` + `auth_time`-window assertion) in the same
change to anchor freshness to verifiable evidence rather than "an SSO round-trip happened"
(recurring pattern #69). Everything else in S3 — the kill-switch, device_id validation,
IDOR, single-use consume, refresh-non-regression, and the S1/S2 unbounded-growth carry-
forwards — is CLOSED and re-verified.

---

## Re-review (cycle 2) — 2026-06-26

The dev applied fixes for H-1, M-1, and the array-cap NOTE. Each was re-verified
adversarially against the staged diff and the full changed files (not the green tests).

### New verdict: CLEAN — ship.

CRITICAL: 0 · HIGH: 0 · MEDIUM: 0 · LOW: 2 (unchanged: L-1 benign post-H-1, L-2 DB-bounded).
No new finding introduced by the fix.

### Per-finding re-adjudication

**H-1 — CLOSED.** `Uia.complete/2` (`uia.ex:169-198`) now carries
`AND user_id = $2` in the UPDATE, with `$2 = authenticated_user`. The completion path
(`sso_login.ex:256-258`) derives `authenticated_user` server-side from the FRESHLY-VERIFIED
id_token: `do_callback`'s `with` chain runs `exchange → OidcPlug.verify_token(id_token) →
claims → check_nonce`, then `complete_uia(conn, entry.uia_session, claims)` computes
`UserId.from_claims(claims, server_name)` — byte-identical to the login derivation
(`http_public.ex:323-324`, same `server_name` env, same `UserId.from_claims/2`). No
query/state/body input feeds `authenticated_user`; `entry.uia_session` only selects WHICH
row (`session_id = $1`), and the identity match is enforced INDEPENDENTLY against the
verified `sub` via `AND user_id = $2`. A foreign-sub completion matches 0 rows → `:error` →
stage NOT flipped, `auth_time` NOT refreshed, 403 page rendered, no `onAuthDone()`. Verified:
  * Mismatch leaves the row reusable (`stage_complete=FALSE, consumed=FALSE, expires_at`
    untouched), so the LEGITIMATE user can still complete later — no legit-flow brick.
  * Arity change is safe: the ONLY caller of `Uia.complete` is `sso_login.ex:260` (new
    arity-2); the only caller of `complete_uia` is `do_callback`. No stale arity-1 caller.
  * DoS-on-malformed-claims: `claims` is the map returned by `verify_token/2`; `from_claims`
    `is_map` guard holds → no raise on the unauthenticated fallback.
  * Regression test (`device_endpoints_test.exs:993-1040`) signs the callback id_token with
    `fresh_sub()` (a random sub ≠ the victim's `den_sub`; with only `sub`+`nonce` in the
    token, `from_claims` falls to `sub` → a genuinely different user_id), asserts cb_status
    403, the re-submit stays 401, and `VICTIM_HW` survives — with the window set to 86_400
    so identity-binding is the ONLY thing that can block it. This is the exact missing test.

  Collision residual (judged LOW/accepted, NOT a new finding): `from_claims` prefers a
  configured claim / `preferred_username` / `name` over `sub`, so two IdP accounts sharing
  that claim map to one Matrix user_id. But this exposure is IDENTICAL to primary login —
  such an attacker could already log in AS the victim via `POST /login`. The UIA completion
  binding is therefore no weaker than the auth it gates. It is an IdP/claim-mapping trust
  property, not an H-1 regression. No action for S3.

**M-1 — CLOSED.** `do_redirect/3` (`sso_login.ex:78`) adds `max_age=0` ONLY when
`is_binary(uia_session) and uia_session != ""` (`sso_login.ex:114-119`). The normal login
redirect (`sso_login.ex:74`) calls `do_redirect/2` → `uia_session = nil` → max_age NOT added,
login UX unchanged. The dev did NOT add the callback-side `auth_time`-window assertion (my
suggested belt-and-braces). Judged SUFFICIENT: with H-1's `sub`-binding now anchoring identity
server-side, the residual ("an IdP that silently ignores `max_age=0` returns an old
`auth_time`") cannot be exploited by a DIFFERENT identity — only the legitimate user's own
session can be completed. The worst case is a slightly-stale-but-same-user re-auth, a LOW
freshness-strength concern, not a step-up bypass. Downgraded from MEDIUM to accepted-LOW.

**Array-cap NOTE — CLOSED.** `protected.ex` `delete_devices` rejects `length(devices) > 100`
→ `400 M_INVALID_PARAM` (`devices must contain at most 100 entries`), checked on the RAW
array length BEFORE `Enum.filter(&is_binary/1) |> Enum.uniq()`, so a 10_000-element / padded
array cannot smuggle >100 real ids through. `not Map.has_key?(params,"devices")` → 400
M_MISSING_PARAM and `not is_list` → 400 M_INVALID_PARAM are unchanged (empty list still a
gated 200 no-op). Test `device_endpoints_test.exs:770-793` sends 101 entries → asserts 400
M_INVALID_PARAM.

### NEW-issue sweep (did the fix open a hole?)

None found.
  * No new caller breakage from the arity change (verified above).
  * 403 mismatch page + the warning log carry NO PII / token / session id / sub / user_id —
    constant strings only.
  * `SsoStore.pop_state` adds `uia_session: entry[:uia_session] || entry["uia_session"]`;
    for a normal login the key is absent → `nil`, so `entry.uia_session` is always a present
    key (no `KeyError`) and the normal login branch is unaffected.
  * `uia_fallback` unchanged in posture: unknown/expired session → 400, no auth oracle beyond
    "is this a live 256-bit session id"; the internal `https://uia.local/complete` marker is
    not attacker-reachable as an open redirect.

### Previously-CLOSED items re-verified (not assumed)

F-1 kill-switch (`token_denylist.ex` `revoke_by_hash` + DB fallback, `device_binding`
cache-delete-before-DB), F-2 device_id validation (both sinks), G2 consume atomicity
(`uia.ex:109-129`, unchanged conditional UPDATE requiring `stage_complete=TRUE AND
consumed=FALSE`), G3 IDOR (owner-scoping + `belongs_to_other_user?` before challenge),
G1 refresh-non-regression, and the unbounded-growth `Session.Sweeper` (`DELETE … WHERE exp
IS NOT NULL AND exp < now` + `Uia.cleanup_expired`, hourly) — all remain CLOSED. None of the
fix hunks touched these paths.

**Cycle-2 verdict: CLEAN. S3 is cleared to ship.**
