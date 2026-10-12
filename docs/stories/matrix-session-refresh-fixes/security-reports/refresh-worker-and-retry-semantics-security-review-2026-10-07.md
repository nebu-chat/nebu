# Security Review — refresh-worker-and-retry-semantics

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Epic:** matrix-session-refresh-fixes
**Story:** refresh-worker-and-retry-semantics (bug, `security_review: required`)
**Branch / worktree:** `bugfix/matrix-session-refresh` (`open-chat-bugfix`)
**Diff scope:** staged diff (`git diff --staged`). Production code: `server/lib/nebu/matrix/http_public.ex` (+168/-67),
`server/lib/nebu/matrix/session/matrix_session_store.ex` (+139/-33), new `server/lib/nebu/matrix/session/refresh_errors.ex` (+48),
`server/lib/nebu/matrix/session/refresh_worker.ex` (+93 changed), `server/lib/nebu/web/plugs/oidc_plug.ex` (comments only),
`server/lib/nebu/web/plugs/rate_limit.ex` (`retry_after_ms` in the 429 body). Plus tests (`refresh_semantics_test.exs` new, 3 updated),
`docs/architecture/08-concepts.md`, story and pipeline artifacts.
**Review state:** code-review cycles 0–2 done (no MAJOR). Only test/comment fixes still open; they do not touch production code.
**Date:** 2026-10-07
**Method:** I read the code only (no Docker/mix runs, because an integration run was going on in parallel). I read every changed
production function in full, not only the diff hunks, and followed the callers (`revalidate_with_idp/1`, `check_still_active/2`,
`TokenValidator.Postgres.validate/4`, `OidcPlug.call_opaque/2`, `delete_*` helpers, `SecretBox.encrypt/1`, router rate limits, `config/runtime.exs`).

---

## Executive Verdict

**CLEAN — APPROVED (no CRITICAL, no HIGH). The commit is not blocked.**
Two MEDIUM findings and one LOW finding are advisory. Fix them before the epic ends, or record them formally as accepted risks.

The core security properties hold:
- IdP re-validation runs on every token issuance: `:current`, `:replay`, and race-retry paths all go through `revalidate_with_idp/1`.
- Deprovisioning (`:deactivated`) is still enforced on `/refresh`, in the worker, and per request (OidcPlug `provision/2` with a TTL of 60 s or less).
- A transient failure never issues tokens and never extends a session.
- All SQL is parameterized.
- No token, OIDC refresh token, or IdP payload is logged.
- The OIDC refresh token stays SecretBox-encrypted (AES-256-GCM, random 96-bit nonce per call).
- The lock order is deadlock-free.

The two MEDIUM findings are side effects of the spec-required semantics ("old RT valid until the new tokens are used") and of the switch from
rotation to in-place extension. Both lengthen the lifetime of stolen bearer tokens. Neither is a revocation bypass.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `matrix_session_store.ex:390-404` (`extend_in_place/3`), `refresh_worker.ex:369-377` (`extend/3`) | **The opaque AT no longer has an independent outer expiry bound.** The worker extends `expires_at` of the SAME access token again and again (`min(id_token exp, now+ceiling)`, where `now` moves on every cycle). A stolen opaque AT for a dormant or idle device stays valid as long as Nebu can redeem the OIDC RT at the IdP. Before this diff it died at the next worker rotation, or at the latest after the 8h ceiling. (CWE-613) | Cap the in-place extension at the issuance time of the row: `SET expires_at = LEAST($2, created_at + make_interval(secs => $4))`, with `$4 = SessionConfig.matrix_session_ttl_seconds()`. The worker then only bridges a short IdP exp inside the AT's natural ceiling window. A client that follows its `expires_in_ms` is unaffected. After the cap, a normal 401 + `soft_logout` → `/refresh` (rotation) follows. Add a test that a worker cycle on a row with `created_at = now - ceiling` does NOT extend. |
| F-2 | MEDIUM | `matrix_session_store.ex:167-186` (`resolve_refresh_token/1` → `active_sibling/1`), `http_public.ex:732-800` (`rotate_attempt/6`, `:replay`), `oidc_plug.ex:80-83` | **Session takeover window through a stolen PENDING (rotated-away) RT.** A replay of a pending RT rotates the device's ACTIVE row. The legitimate holder of those active tokens then gets `401 M_UNKNOWN_TOKEN` WITHOUT `soft_logout` ("Token has been logged out"), and the attacker keeps a fresh token pair. Reuse detection does not fire, because the legitimate client presents an AT, not a consumed RT. This is new attack surface: before the diff, an old-RT retry ALWAYS failed (`rotate_tokens` on the already revoked old row → `:error` → 401). The window lasts until the new AT is first used. For idle devices it is bounded only by the expiry of the active row, which the worker extends (see F-1). (CWE-384/CWE-613) | In `OidcPlug.call_opaque/2`, add a branch: soft-revoked AT whose row is still PENDING (`revoked_at IS NOT NULL AND grace_until IS NULL`) = the holder demonstrably received these tokens, so the row was superseded by a replay of an older RT → treat it as reuse: `delete_for_user_device/2` + log warning (metadata user_id/device_id only). This turns a silent takeover into a visible logout of both parties, as OAuth reuse detection intends. Trade-off: two parallel `/refresh` calls from the same legitimate client can then cause a logout. Alternative with fewer false positives: answer this case with `soft_logout: true`, so a refresh-capable client refreshes again with its pending RT and wins back the session (its next AT use consumes the attacker's RT). Test: refresh → attacker replays the old RT → victim uses its AT → device is deleted (or `soft_logout: true`). |
| F-3 | LOW | `matrix_session_store.ex:167` (`consumed? -> {:consumed, sess}`), `http_public.ex:579-588` | **Reuse detection has no time bound → old leaked RT = remote device logout.** Consumed rows stay in the table without limit (no sweeper; the `{:consumed, _}` branch checks neither `expires_at` nor whether an active sibling exists). Anyone holding ANY historical consumed RT of a device (client logs, proxy logs, crash reports, old backups) can delete that device's session with one unauthenticated `POST /refresh`. Before the diff that was a harmless 401. Legitimate client races (two refreshes, the second after the first AT use) also delete the device themselves. (CWE-400, availability) | Only treat a consumed token as reuse while the device still has an active, unexpired row and the consumed row is younger than a bound (for example `expires_at > NOW() - ceiling`). Otherwise return plain `:error` → 401 without deleting anything. Wire up the named sweeper follow-up (`cleanup_expired/0`) soon. That also limits the row growth from many pending/consumed RTs. |
| I-1 | INFO | `matrix_sessions` (schema, pre-existing) | Access and refresh tokens are stored in PLAINTEXT. **Known pre-existing finding, NOT a blocker for this diff** (separate bugfix `token-hashing-matrix-sessions` follows). Note: this diff makes old RTs functionally valuable again (pending = redeemable, consumed = can trigger a logout), and these rows now live much longer. That raises the stakes of the token-hashing fix. With hashing, the lookup `WHERE refresh_token = $1` also becomes timing-neutral. | Prioritize `token-hashing-matrix-sessions`. Hash pending and consumed rows too (SHA-256 of the token as the lookup key). |
| I-2 | INFO | `http_public.ex:691-694`, `http_public.ex:804-813` | Test seams `:matrix_oidc_refresh_override` / `:matrix_refresh_rotate_override`: grepped `lib/` + `config/`: no `put_env`/`config` outside `test/`. `config/runtime.exs` only maps fixed integer TTL keys. The guard is `is_function(fun, 1)`, and environment variables cannot produce a function. Not reachable in prod (same pattern as `:admin_oidc_refresh_override`). | None. Optionally compile the seam only under `Mix.env() == :test`. |
| I-3 | INFO | `http_public.ex` `check_still_active/2` + `refresh_errors.ex:399` | `TokenValidator.validate/4` errors other than `:deactivated` are now wrapped as `{:transient_check_failed, _}`, which means 503 instead of 401. That also covers persistent, non-transient failures (for example a PII decrypt error or a missing `pii_encryption_key`): the client then gets 503 forever and the row stays. This is **fail-closed on access** (no tokens issued, no `expires_at` extension; the old AT dies at its `expires_at`). An attacker cannot trigger this for someone else's session. It is a liveness/operations topic only. Likewise, an attacker cannot use an IdP outage or 429 to delete sessions (transient → no deletion) or to keep them alive (transient → no extension). | Optional: a counter/metric for repeated `transient_check_failed` per device, plus an alert. |
| I-4 | INFO | `http_public.ex:571-588` | Enumeration/timing: unknown, consumed, and confirmed-rejected all return an identical body (`refresh_denied/1`). The consumed path (DELETE) and the pending path (IdP round trip) differ in timing. That would only be an oracle if you already hold a 256-bit random token, so it has no practical value. | None (it disappears with I-1). |
| I-5 | INFO | Deploy transition (`resolve_refresh_token/1`) | Legacy rows with a future `grace_until` from the old 60 s design now count as consumed. A client inside the old 60 s window at deploy time gets reuse detection → device logout (once, in the safe direction). Already documented in the story (code review I-A). | Mention it in the release notes. |
| I-6 | INFO | `rate_limit.ex:41-43,162`, `http_public.ex:107-118` | `/refresh` stays rate-limited (30/min, burst 10, tier `refresh`). The key is `conn.remote_ip`, with no X-Forwarded-For trust (no XFF spoofing possible). Behind a reverse proxy, all clients share one bucket. That is pre-existing, an availability topic, and not in this diff. `retry_after_ms` in the 429 body is static (`retry_after_s * 1000`) and leaks nothing. The race-retry loop (`@refresh_race_retries 12`, at most about 24 DB round trips, no extra IdP calls) is bounded by the rate limit. | Trusted-proxy configuration is a separate follow-up. |

**Severity count:** CRITICAL 0 · HIGH 0 · MEDIUM 2 · LOW 1 · INFO 6

---

## Detail

### F-1 — In-place extension without an independent outer bound [MEDIUM]

`RefreshWorker.extend/3` calls `Store.extend_in_place(sess.access_token, HttpPublic.session_expires_at(fresh_claims), enc_oidc_rt)`.
`session_expires_at/1` computes `min(claims["exp"], now + matrix_session_ttl_seconds)`. Because `now` moves forward on every cycle and the AT
is no longer rotated, there is no point in time at which this specific AT necessarily expires. The only remaining outer bound is the IdP:
Keycloak SSO Session Max (absolute, default 10h) ends the refresh grant. With Dex (no `absoluteLifetime` by default) or a long Keycloak
configuration, the AT is effectively unlimited, and every worker redemption also resets the IdP's idle timeout.

This **explicitly breaks condition 1** of my own architecture verdict on server-paced refresh (2026-07-03, sanctum/agent memory
"server-paced-refresh-vs-liveness"): *"Background refresh must NOT push expires_at forward indefinitely on the SAME opaque AT — either an
absolute cap OR rotation."* Rotation turned out to be impossible here: the worker cannot deliver the new tokens to the client, which is the
bug this story fixes. So the absolute cap has to take its place.

Why only MEDIUM, and not the HIGH that verdict foresaw: the HIGH case there was *unbounded access after revocation* (decrypt-gated grace).
Here conditions 2 and 3 still hold, and I verified both:
- the per-request deactivation check in `OidcPlug.call_opaque/2` (`provision/2`, TTL of 60 s or less) is unchanged;
- a confirmed IdP rejection in the worker deletes the row (`delete_by_access_token/1`);
- logout, device delete, and admin deactivation delete all rows.

Revocation therefore stays effective. What is lost is only the time bound for a **stolen** AT (precondition: token theft) on a dormant device.
Refresh-capable clients still rotate on their own `/refresh` cadence (based on the `expires_in_ms` they received), which kills a stolen AT for
active devices.

Remediation: a cap on `created_at + ceiling` (see the table). That needs no migration, because `created_at` is set on insert. It preserves the
bug fix: a well-behaved client never notices anything.

### F-2 — Takeover window through a pending old RT [MEDIUM]

Flow (attacker A has a stolen old RT `R0`; victim V has refreshed and holds `AT1/RT1` but has not used them yet):
1. A: `POST /refresh {R0}` → `resolve_refresh_token` → R0 is pending → `active_sibling` = row(AT1) → IdP re-validation OK →
   `rotate_tokens(old=AT1, replay=R0, consume_pending_siblings=false)` → A gets `AT2/RT2`. Row(AT1) is now soft-revoked and pending.
2. V: request with AT1 → `call_opaque` → `revoked_at` is set → `401 M_UNKNOWN_TOKEN "Token has been logged out"`, **without** `soft_logout`.
   By spec, V must discard its state. If V does not try another refresh, V is logged out and A keeps the session.
3. Only if V presents RT1 (pending → replay) does a tug-of-war start. That eventually ends in reuse detection (whoever uses an AT first
   consumes all other pending RTs, and the other party then presents a consumed RT → device deleted).

The spec allows this for the lost-response case, and the server cannot distinguish that case from an attack. The precondition is theft of an
older RT. In practice the window is usually short (clients use the new AT right away). For idle devices it can last a long time, coupled with F-1.

The decisive signal the server is not using today: **a presented AT whose row is soft-revoked but still pending.** That row was never consumed,
so its holder has demonstrably received the tokens. The supersession came from a replay of an OLDER RT by someone else. Recommended handling:
see the table (hard reuse response, or `soft_logout: true` as the variant with fewer false positives).

### F-3 — Reuse detection without a time bound [LOW]

The `{:consumed, sess}` branch deletes `(user_id, device_id)` without checking whether the consumed row is still young or whether the device
still has an active row. Consumed rows are never cleaned up (`cleanup_expired/0` is not wired). The `delete_for_user_device` target comes from
the DB row, not from the request (no IDOR). The attacker therefore always needs a real token of that device. With plaintext storage (I-1) and
the lifetime of these rows, it is still a cheap targeted logout vector. It is also self-DoS-prone with real client races, which RFC 9700
accepts for reuse detection; Matrix clients now treat it as a full logout without `soft_logout`.

---

## Verified controls (CONFIRMATIONS)

| Topic | Result |
|---|---|
| **IdP re-validation not bypassed** | `:current`, `:replay`, and the race-retry re-resolution go through `revalidate_with_idp/1` (decrypt → `OidcTokenExchange.refresh/2` incl. ID-token re-verify → `check_still_active/2`). For a replay, the OIDC RT of the ACTIVE row is redeemed, never that of the old row. The worker uses the same function. |
| **Deprovisioning enforced** | `:deactivated` → classified as CONFIRMED (`RefreshErrors.transient?/1` → false) → `delete_for_user_device/2` + 401 (refresh) or `delete_by_access_token/1` (worker). Per-request `provision/2` check in `OidcPlug` unchanged. |
| **Transient vs. confirmed** | Single source of truth `RefreshErrors.transient?/1`; the old copy in the worker was deleted, and `get_by_refresh_token/1` was removed entirely (grep = 0 callers in `lib/` and `test/`). Transient → 503 + `Retry-After`, no write, no token issuance, no `expires_at` extension. Unknown reasons → confirmed (fail-closed in the right direction). An attacker cannot provoke session deletion or keep-alive through IdP failures. |
| **Cluster safety / TOCTOU (ADR-020)** | `rotate_tokens/1`: the guarded UPDATE on the active row (`revoked_at IS NULL`) gives exactly one winner. Replay check `SELECT … FOR UPDATE` on the presented RT AFTER the active-row lock (lock order always active → siblings). Sibling UPDATEs use `IN (SELECT … ORDER BY access_token FOR UPDATE)`, which is deadlock-free. Pending/consumed is decided purely by `IS NULL` (no `NOW()` comparison, which is correct under READ COMMITTED + EvalPlanQual). `extend_in_place/3` and `store_rotated_oidc_rt/3` are single statements guarded by `revoked_at IS NULL`, so no revoked or deleted device is resurrected. A failed transaction (CaseClause/MatchError) is rolled back; `safe_rotate/1` → 503, and a retry is served as a replay, which is consistent. |
| **SQL injection** | All new statements are bound with `$n`. `select_sql/1` only interpolates static string literals from the module. No user input in the SQL text. |
| **Logging law (tokens, OIDC RT, chat content)** | New and changed log lines are static literals plus metadata `user_id`/`device_id` plus `RefreshErrors.describe/1` (tag or HTTP status only, never the payload; non-atom → `"unknown"`). The former `inspect(reason)` in the refresh path and worker was removed. No token in an HTTP response except the newly issued pair to the legitimate requester. Ecto parameter logging is disabled globally (`Repo log: false` + `QueryTelemetry`). No chat content in scope. Pre-existing `inspect(e)` lines in the worker (`refresh_worker.ex:213,263`) are not in the diff; the `Postgrex.Error` structs reachable there contain no bound parameters. |
| **OIDC RT encryption** | Worker: `SecretBox.encrypt/1` (random 12-byte nonce per call), `nil` keeps the stored blob (`COALESCE`). Refresh: `maybe_put_new_oidc_rt/2` unchanged. No plaintext OIDC RT is persisted or logged. |
| **Spec: soft_logout semantics** | Destroyed session → 401 without `soft_logout` (correct: the client must discard its state). Expired AT with a live RT → 401 + `soft_logout: true` (`OidcPlug`, unchanged). |
| **Rate limit** | `/refresh` stays behind `@refresh_rate_limit` (30/min, burst 10) before any DB/IdP access. |
| **Test seams** | Not reachable in prod (see I-2). |

---

## Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 2 — advisory, address before epic end (F-1, F-2)
LOW: 1 — advisory (F-3)
INFO: 6

**Verdict: APPROVED (CLEAN)** — no blocker. **Owner decision needed on F-1:** it deviates from a MUST-condition I stated earlier.
The recommended fix is small (one `LEAST(...)` in `extend_in_place/3` + one test). If it is not fixed, it should be recorded as an accepted risk in the sanctum.

---

## Follow-up review 2026-10-07 (delta, code-review cycle 3)

**Scope:** cycle-3 fixes for F-1/F-2/F-3 in the staged diff: `matrix_session_store.ex` (`resolve_refresh_token/1` :150-189,
`superseded_at_grace_seconds/0` :397-415, `superseded_beyond_grace?/1` :427-439, `extend_in_place/3` :455-474), `oidc_plug.ex`
`call_opaque/2` :80-104, tests `describe "review cycle 3"` (`refresh_semantics_test.exs` :1209-1368). Code reading only (no mix/Docker run).
I replayed each attack scenario step by step against the SQL (row states pending = `revoked_at NOT NULL AND grace_until IS NULL`,
consumed = `grace_until NOT NULL`).

### Status of the findings

| # | Status | Assessment |
|---|--------|-----------|
| F-1 | **CLOSED** (with a residual LOW → N-3) | `SET expires_at = LEAST($2, created_at + ttl)` caps every in-place extension absolutely at the issuance time of the row. `created_at` is `NOT NULL DEFAULT NOW()` (schema `000001_init.up.sql:335`), and both INSERTs set `NOW()` explicitly, so the cap cannot be bypassed through NULL (`LEAST` would ignore NULL). A stolen opaque AT is again bounded at ≤ `matrix_session_ttl_seconds` after its issuance. Tests cover above and below the cap. |
| F-2 | **PARTIAL** (residual = N-1, MEDIUM) | **Passive** attacker closed: replay of RT0 → AT1 pending; victim presents AT1 → < 30 s `soft_logout` (victim recovers with pending RT1 via replay and wins the device back), ≥ 30 s → reuse → `delete_for_user_device`. **Active** attacker NOT closed: as soon as the attacker uses AT2 once (any `/sync`, milliseconds after the replay), `has_open_grace_window?(AT2)` → `mark_access_token_used(AT2)` consumes ALL pending siblings, including row(AT1). The victim's AT1 then has `grace_until NOT NULL` → `true` branch (`oidc_plug.ex:102`) → hard `401 "Token has been logged out"` **without** `soft_logout`, with no deletion. That is exactly the original takeover. Only a client that refreshes anyway on a hard 401 (not spec-compliant) would trigger reuse detection with RT1 (consumed, young, live device). A real attacker uses the session at once, so the fix covers the less relevant variant. Test gap: no test covers "attacker uses AT2 before the victim presents AT1". |
| F-3 | **CLOSED** | `{:consumed, _}` only when the row is young (`created_at + ttl > NOW()`) and the device has an active, unexpired row (`EXISTS …`). Otherwise `:error` → identical `refresh_denied` body, no DELETE. An old leaked RT, or one from a dead device, is no longer a logout vector. Residual: young consumed RT (≤ ttl) + live device = deliberate RFC 9700 reuse detection (accepted). `young?` is never NULL (NOT NULL column), so no `BadBooleanError` in `and`. The race-retry path (`http_public.ex:771-776`) uses the same bounded `resolve_refresh_token/1`. Tests: outside the bound, without a live device, inside the bound. |

### New findings (delta)

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| N-1 | MEDIUM | `oidc_plug.ex:102-103` (`true ->` branch for soft-revoked **consumed** ATs) together with `matrix_session_store.ex:338-367` (`mark_access_token_used/1`) | **F-2 residual: an active attacker erases the detection signal.** The attacker's first AT2 use turns the victim's row from pending into consumed. The victim then gets a hard logout without `soft_logout`, the attacker keeps the device session, and reuse detection never fires. (CWE-384/CWE-613) | Answer soft-revoked ATs in the plug **uniformly with `soft_logout: true` and do not delete in the plug** (pending AND consumed). Then move detection entirely to the already bounded `/refresh` path (F-3): active attacker → victim gets soft_logout → refreshes with RT1 (consumed, young, live device) → reuse → device deleted (both parties out). Passive attacker → victim refreshes with pending RT1 → replay → wins the device back. As a side effect this removes N-2 and the extra `superseded_beyond_grace?` query. Alternative (minimal): only change the `true` branch to `deny_soft_logout`. Test: replay RT0 → `whoami(AT2)` = 200 → `whoami(AT1)` → `soft_logout: true` → `refresh(RT1)` → 401 + `device_rows == []`. |
| N-2 | LOW | `oidc_plug.ex:92-100` | **Unbounded device deletion in the plug + false positive on lost-response.** The ≥ 30 s branch deletes without the F-3 bound (`young?`/`has_active?`) and is reachable from every authenticated endpoint. Who can trigger it: (a) the legitimate client from the lost-response case (refresh response lost, offline > 30 s, then presents its old AT0 again, which happens with proactive refresh): its own device is deleted, although a `soft_logout` + replay of R0 would have recovered it cleanly. (b) A thief with an old, still-pending AT. Practically limited: pending rows die on the first use of any newer AT of the device, so only idle devices are affected. No privilege gain, availability only. (Before cycle 3, case (a) was a hard 401 without soft_logout, so the client-visible result was similar. The server-side deletion is new.) | Resolved by N-1 (no delete in the plug). If the branch stays, at least mirror the F-3 bound (`created_at + ttl > NOW()` and an active, unexpired sibling) in `superseded_beyond_grace?/1`. |
| N-3 | LOW | `refresh_worker.ex:230-243` (`candidates/0`: `revoked_at IS NULL AND expires_at <= NOW() + lookahead`), interaction with `extend_in_place/3` :460 | **F-1 cap without a worker stop: perpetual IdP redemption for capped/expired rows.** Once a row hits the cap, it stays in the candidate set forever (it is never extended beyond `created_at + ttl`, so it stays below `now + lookahead`, even after expiry). Every 5 min the worker calls `revalidate_with_idp/1` → OIDC refresh grant at the IdP → no-op extension → log "session extended". Effects: (1) IdP load grows linearly with the number of dormant devices (12 calls/h each); (2) the IdP **idle timeout** (Keycloak SSO Session Idle) is reset continuously, so the Matrix RT of a dormant device stays redeemable until the IdP absolute max (Dex: unbounded). That partly undoes the purpose of the cap ("worker stops extending"). Not a revocation bypass (deactivation/rejection still delete). | Exclude capped rows from the worker: in `candidates/0` add `AND created_at + ($2::bigint * INTERVAL '1 second') > NOW()` (ttl), or `AND expires_at < created_at + ttl`. The client's own `/refresh` then re-validates at the IdP when it next uses the session. Test: row with `created_at = now - ttl - 100` → `run_one_refresh_cycle()` makes **no** IdP call (override counter). |
| N-4 | INFO | `matrix_session_store.ex:430` | `revoked_at` is set with `NOW()` (transaction start, `rotate_tokens/1`) and compared against `clock_timestamp()`. Both sides use the same DB clock, so there is no node skew. The IdP round trip happens BEFORE the transaction, so the offset is negligible. The heuristic only decides the response variant (soft_logout vs. reuse) and never grants authentication. On a DB error it returns `false` → soft_logout (no access, only detection skipped), which is acceptable. | None. |
| N-5 | INFO | `extend_in_place/3`, deploy | **Availability on deploy:** rows that the worker had already extended past `created_at + ttl` before the deploy are set to `created_at + ttl` (possibly in the past) at the next worker cycle → one `401 soft_logout` → client `/refresh` (`:current` does not check `expires_at` of the active row, see `resolve_refresh_token/1` :177) → new row. One extra refresh per device, no logout. Clients without refresh support have no opaque session. | Note it in the release notes (together with I-5). |
| N-6 | INFO | `oidc_plug.ex:88`, `matrix_session_store.ex:156-161` | Extra DB load: the plug branch adds 1 SELECT (+ at most 1 DELETE), but only for **real** soft-revoked tokens. Unknown/random tokens end at `get_by_access_token` → `:error` as before. `resolve_refresh_token` gains an `EXISTS` subquery on `(user_id, device_id)` (index `idx_matrix_sessions_user_id`); `/refresh` stays rate-limited. Amplification factor ≤ 2, not a relevant DoS lever. | None (disappears with N-1). |

### Re-checked controls (still valid)

- **Logging law:** the new log line is a static literal + metadata `user_id`/`device_id`. No AT/RT/OIDC RT. The test (`:1289-1292`) asserts `refute log =~` for the victim AT and the attacker AT+RT. No chat content in scope.
- **Parameter binding:** all new statements use `$n`; `($n::bigint * INTERVAL '1 second')` with integer parameters, no interpolation.
- **SecretBox:** unchanged (worker `encrypt/1`, `COALESCE($3, …)` keeps the blob).
- **Fail-closed:** no new path issues tokens or extends `expires_at` without IdP re-validation. A soft-revoked AT never authenticates (all three branches deny). DB failure in `superseded_beyond_grace?` → deny with soft_logout. `resolve_refresh_token` DB failure → 503 without writing.
- **Grace as abuse (2a):** the 30 s window grants no authentication and no token issuance. It only changes the 401 variant, so it gives an attacker no extra capability beyond the pre-existing replay window. The test seam `:matrix_superseded_at_grace_seconds` is not set in `lib/`/`config/` (grep = 0) and only accepts integers via `Application.get_env`. Setting it in prod would only delay detection.
- **Plaintext storage (I-1) still applies:** AT/RT are still stored unhashed in `matrix_sessions`. The separate bugfix `token-hashing-matrix-sessions` follows and stays a priority, all the more because pending/consumed rows (no sweeper) keep their functional value (replay / reuse trigger).

### Severity count (delta)

CRITICAL 0 · HIGH 0 · MEDIUM 1 (N-1 = F-2 residual) · LOW 2 (N-2, N-3) · INFO 3 (N-4..N-6)

### Final classification (delta)

**CLEAN — APPROVED (no CRITICAL/HIGH, commit not blocked).**
F-1 CLOSED · F-2 PARTIAL · F-3 CLOSED.
**Recommendation to the owner:** F-2 is closed only for the passive attacker. The realistic attacker (uses the stolen session immediately)
gets the same takeover window as before. N-1 is a small change (plug: soft_logout instead of hard deny/delete for soft-revoked ATs + 1 test)
and resolves N-2 at the same time. Fix it in this cycle, or explicitly record F-2/N-1 as an accepted risk in the sanctum.

---

## Final review 2026-10-07 (cycle 4)

**Scope:** cycle-4 fixes in the staged diff: `oidc_plug.ex` `call_opaque/2` :74-123 (uniform `soft_logout` for soft-revoked ATs, no
delete in the plug, 30 s grace removed), `matrix_session_store.ex` `resolve_refresh_token/1` :150-189 (F-3 bound), `extend_in_place/3`
:412-432 (`GREATEST(expires_at, LEAST($2, created_at + ttl))`), `refresh_worker.ex` `candidates/0` :230-246 (cap exclusion),
tests `describe "review cycle 3/4"` (`refresh_semantics_test.exs` :1209-1470). Code reading only (no mix/Docker run).
Grep check: `superseded_at_grace`, `superseded_beyond_grace`, `"Token has been logged out"` = 0 hits in `lib/`, `config/`, `test/`
(the grace window was removed completely, the seam is gone).

Notation: row state pending = `revoked_at NOT NULL AND grace_until IS NULL`; consumed = `grace_until NOT NULL`. Initial state for
(a)-(c): victim V rotated RT0 -> holds AT1/RT1 and has not used them yet; attacker A replays the stolen pending RT0 -> `active_sibling` =
Row1 -> `rotate_tokens(old=AT1, replay=RT0, consume_pending_siblings=false)` -> Row1 pending, Row2 (AT2/RT2) active, Row0 still pending.

### Scenario replay

| # | Scenario | Result |
|---|----------|--------|
| (a) | Passive attacker (A does not use AT2) | V: AT1 -> `revoked_at` set -> `401 soft_logout:true` (:90), nothing deleted. V refreshes RT1 -> pending -> replay on Row2 -> Row2 pending, Row3 active for V. V's first use of AT3 -> `mark_access_token_used` consumes Row0/1/2. A: AT2 -> soft_logout; RT2 -> consumed, young, live -> reuse -> device deleted. **V wins the device back. A's tokens are dead; A can only trigger a logout (DoS by a token holder, accepted RFC 9700 behavior).** Test N-1 (a). |
| (b) | Active attacker (A uses AT2 at once) | A: `whoami(AT2)` -> `has_open_grace_window?` -> Row0+Row1 consumed. V: AT1 -> `401 soft_logout:true` (previously a hard 401 = takeover). V refreshes RT1 -> consumed + young + `has_active?` (Row2) -> `{:consumed,_}` -> `delete_for_user_device` -> both out. If A consumes RT1 during V's IdP round trip, the `FOR UPDATE` re-check in `rotate_tokens` -> `{:error,:consumed}` -> delete. **The takeover ends visibly.** Test N-1 (b) checks the full chain, including `refresh(RT2) = 401` afterwards. |
| (c) | A refreshes permanently with RT2/RT3/... instead of using AT2 | Every `:current` refresh runs with `consume_pending_siblings=true` -> consumes V's RT1 the same way an AT use does. V's next contact -> soft_logout -> RT1 consumed -> reuse -> delete. The only non-consuming action available to A is replaying a pending RT, and the tokens from that are unusable without an AT use or `:current` refresh, both of which consume. **Ping-pong gives no stable, undetected takeover.** Each round, A has to win the millisecond race between V's refresh response and V's first AT use. Residual: see N-7. |
| (d) | V offline, A holds the session past the worker cap | The worker does not help A: `candidates/0` excludes rows with `created_at + ttl <= NOW()`, and `extend_in_place` caps at `created_at + ttl`. A only gets past the cap with his own `/refresh`. Each of those does a full IdP re-validation (OIDC refresh grant + ID-token verify + `check_still_active`), so deactivation and IdP revocation still apply. That is the inherent "stolen RT = session" property, bounded by the IdP absolute session max. **Gap:** when V comes back more than `ttl` (default 8h) after its rotation, its consumed RT1 is outside the F-3 bound -> plain 401 without deletion -> V is logged out and **A stays undetected** -> N-7. |
| (e) | soft_logout loop for legitimate clients | Soft-revoked ATs only come from rotation. Logout, device delete, deactivation, IdP rejection and reuse all DELETE (-> `:error` -> hard 401). In-flight old AT (pending or consumed) -> soft_logout -> client refreshes with its CURRENT RT -> 200 (tests N-1 (c)/(d), nothing deleted). This fixes the N-2 false positive. A superseded AT with a dead device -> refresh -> `active_sibling` empty / F-3 bound -> hard 401, so the loop ends after one round trip. Transient -> 503 + `Retry-After`. A repeated loop is only possible through an attacker who keeps winning the replay race (see (c)), and `/refresh` is rate-limited. **No legitimate loop.** |
| (f) | Race between worker extension and `/refresh` | `extend_in_place` = one UPDATE guarded by `revoked_at IS NULL`. If `/refresh` commits first -> EvalPlanQual re-check -> 0 rows -> `:error` -> `store_rotated_oidc_rt` on the current active row (guarded, no resurrection). If the worker runs first -> `/refresh` waits on the row lock, then rotates normally; the extended `expires_at` of the old row has no effect (row revoked). `GREATEST` never shortens. **No inconsistent state, no resurrection, no double active row.** Pre-existing residual: with a strictly rotating IdP, the side that loses the OIDC RT redemption gets `invalid_grant` -> confirmed -> deletion (N-8, availability only). |

### Status of all findings

| # | Status | Assessment |
|---|--------|-----------|
| F-1 | **CLOSED** | Cap `created_at + ttl` unchanged. In addition, `GREATEST(expires_at, …)` (M-1) never shortens, so the deploy effect N-5 (one-time soft_logout) no longer occurs. Rows that older worker versions extended keep their value, which is bounded at last extension + ttl, and are no longer candidates. |
| F-2 | **CLOSED** (residual N-7 LOW, accepted) | Active and passive takeover both end in recovery (a) or in visible device destruction (b). The signal is now evaluated on the bounded `/refresh` path. |
| F-3 | **CLOSED** | Unchanged: `consumed? and young? and has_active?`, otherwise `:error` without DELETE. The plug no longer deletes at all, so `/refresh` is the only reuse path and the F-3 bound applies everywhere. |
| N-1 | **CLOSED** | `oidc_plug.ex:81-90`: every soft-revoked AT -> `deny_soft_logout` (body identical to `deny` except for `soft_logout:true`), no write. Test (b) reproduces exactly the active scenario I described in cycle 3. |
| N-2 | **CLOSED** | No delete in the plug any more (`git diff`: the `delete_for_user_device` call and `superseded_beyond_grace?/1` were removed). The lost-response client (old AT0 after > 30 s) now recovers through soft_logout + replay/current refresh. |
| N-3 | **CLOSED** | `candidates/0` :241 `AND created_at + ($2::bigint * INTERVAL '1 second') > NOW()`. Test N-3 asserts that no IdP call happens. Residual (INFO): between "expires_at reaches the cap" and "NOW() > cap", the row stays a candidate for at most `lookahead/interval` = 12 cycles (one-time, bounded), and each cycle is a no-op extension with an IdP call. |
| N-4 | obsolete | The grace heuristic was removed. |
| N-5 | obsolete | `GREATEST` prevents the shortening. |
| N-6 | **CLOSED** | Hot path: the revoked branch no longer adds a query (`get_by_access_token` was already there). The valid branch is unchanged (`has_open_grace_window?` = 1 SELECT, a write only when a pending sibling exists). `resolve_refresh_token` = 1 query with `EXISTS` (index on `user_id`), rate-limited. |

### New findings (cycle 4)

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| N-7 | LOW | `matrix_session_store.ex:156-161,181-182` (`young?` / `has_active?` in `resolve_refresh_token/1`) | **Reuse detection is skipped in two edge cases, so a takeover stays undetected.** (1) The victim comes back more than `ttl` (default 8h) after its last rotation: its consumed RT is no longer "young" -> plain 401 -> the victim discards its state, and the attacker keeps refreshing with his `:current` RT. (2) **Inconsistency:** `has_active?` requires `expires_at > NOW()`, but `:current` (:177) accepts an active row whose `expires_at` has passed (an expired AT is meant to be refreshable). If the attacker's active row happens to be expired when the victim presents its consumed RT (for example a short IdP exp plus a worker cycle gap, or an attacker who does not use the session for a while), the device counts as "dead" -> no detection -> the attacker later refreshes his expired active row normally. Precondition: RT theft plus winning the pending-window race. No privilege gain, and no effect on revocation or deactivation. (CWE-384) | (2) is a cheap fix: change the EXISTS condition so it matches the redeemability of `:current`. Either drop `AND a.expires_at > NOW()`, or bound it consistently with `:current` (for example `a.created_at + ttl > NOW()`, if `:current` gets the same bound). Then "live device" means "has a redeemable RT". Test: replay RT0 -> `whoami(AT2)` -> backdate Row2 `expires_at` into the past -> `refresh(RT1)` -> device deleted. (1) is an accepted trade-off against F-3 (an old leaked RT must not be a logout vector). Document it as an accepted risk. |
| N-8 | INFO | `refresh_worker.ex` (`extend/3`) together with `http_public.ex:592-616` | Pre-existing: concurrent redemption of the same OIDC RT by the worker and `/refresh` against a strictly rotating IdP (no reuse interval) -> the loser gets `invalid_grant` -> classified as confirmed -> `/refresh` deletes the device (a legitimate logout). Availability only, cannot be triggered by a third party. It is already documented in the worker moduledoc as an accepted limitation. | Optional: before deleting after `invalid_grant`, re-read the active row; if its OIDC RT blob has changed since `resolve`, treat it as transient (503) instead of a rejection. |
| N-9 | INFO | `oidc_plug.ex:79` vs. `:90` | The response variants "unknown" (hard 401) and "superseded" (soft_logout) differ. That is an existence oracle only for someone who already holds a 256-bit token, so it has no practical value. It disappears together with I-1 (hashing). | None. |

### Q2: new attack surface from cycle 4?

- **Can a third party delete or lock a device without valid token knowledge?** No. DELETE paths in scope: `/refresh` reuse (requires a real consumed, young RT of a live device), `/refresh` or worker confirmed IdP rejection (requires a real current/pending RT or the server-side worker), logout, device delete, deactivation (authenticated or admin). The plug writes only `grace_until` (consumption) on a VALID AT of the same device. Unknown tokens -> `:error` without a write. "Locking" (soft_logout loop) requires a pending RT, i.e. a token holder (see (c)).
- **Reuse detection bounded by F-3?** Yes. It is the only reuse path (plug delete removed, race-retry :775 uses the same `resolve_refresh_token/1`). No cheap targeted logout with old or leaked tokens.
- **DB load:** see N-6. No extra query in the plug, `/refresh` unchanged, worker load reduced (N-3).

### Re-checked controls (cycle 4, still valid)

- **Logging law:** the plug branch no longer logs anything. The new worker line `"session revalidated (expiry extended up to the absolute cap)"` is a static literal + metadata `user_id`/`device_id`. `RefreshErrors.describe/1` (tag/status only) everywhere. Tests (a)/(b) `refute log =~` for AT/RT of victim and attacker. No chat content in scope.
- **Parameter binding:** `candidates/0` `$2::bigint` (integer from `SessionConfig`), `extend_in_place` `$4::bigint`, `resolve_refresh_token` `$2::bigint`. No interpolation of user input.
- **SecretBox:** worker `SecretBox.encrypt/1` (random nonce), `COALESCE($3, …)`. `/refresh` `maybe_put_new_oidc_rt/2` unchanged. No plaintext OIDC RT persisted or logged.
- **Fail-closed:** a soft-revoked AT never authenticates. Tokens are only issued after `revalidate_with_idp/1`. Transient -> 503 without a write. `resolve_refresh_token` DB error -> 503. `rotate_tokens` CaseClause -> rollback -> `:unavailable`. `extend_in_place` only with `revoked_at IS NULL`.
- **Plaintext token storage (I-1):** still OPEN as a known pre-existing finding, and not a blocker for this diff. The bugfix `token-hashing-matrix-sessions` follows and stays a priority, because pending and consumed rows remain functionally valuable (replay / reuse trigger) and there is no sweeper yet.

### Residual risks (documented as accepted)

1. **R-1 (= N-7 (1))**: reuse detection is skipped when the victim returns more than `ttl` after its rotation. Trade-off against F-3.
2. **R-2**: the takeover window through a stolen pending RT itself (spec "old RT valid until the new tokens are used"). It now always ends in recovery or visible destruction, except for R-1/N-7 (2).
3. **R-3 (= N-8)**: OIDC RT redemption race worker vs. `/refresh` with strictly rotating IdPs -> rare legitimate logout.
4. **R-4**: reuse self-DoS through client races (two refreshes, the second after the first AT use). Accepted RFC 9700 behavior.
5. **R-5 (= I-1)**: plaintext AT/RT in `matrix_sessions` until `token-hashing-matrix-sessions`.
6. **R-6**: the attacker's own `/refresh` chain lasts until the IdP absolute session max (inherent property of a stolen RT; deactivation/revocation still apply).

### Severity count (cycle 4)

CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 1 (N-7) · INFO 2 (N-8, N-9)

### Final classification

**CLEAN — APPROVED (no CRITICAL/HIGH, commit not blocked).**
F-1 CLOSED · F-2 CLOSED (residual N-7 LOW) · F-3 CLOSED · N-1 CLOSED · N-2 CLOSED · N-3 CLOSED.
Recommendation: N-7 (2) is a one-line SQL alignment of `has_active?` with the `:current` semantics, plus 1 test. Do it in this cycle
or as a follow-up before the epic ends. Record N-7 (1) and R-2..R-6 in the sanctum as accepted risks.

---

## N-7 check 2026-10-08 (cycle 5, delta only)

Scope: `git diff --staged`, delta = `resolve_refresh_token/1` (`matrix_session_store.ex:150-188`), new test
`refresh_semantics_test.exs:1428-1445`, rewritten F-3 test `:1463-1478`, `08-concepts.md` reuse bullet.
Code reading only (no mix/Docker run).

### 1. Is N-7 closed?

`has_active?` (:157-160) is now `EXISTS(... a.revoked_at IS NULL)`, with no `expires_at` condition. That is exactly the
predicate `:current` (:176, `is_nil(sess.revoked_at)`) redeems: `do_refresh_with/2` (`http_public.ex:590-593`) runs
`{:ok, sess, :current}` without an expiry check. Scenario: A replays RT0 -> uses AT2 (consumes RT1) -> Row2
`expires_at` passes -> V presents RT1. Now `consumed? and young? and has_active?` -> `{:consumed, _}` -> `delete_for_user_device/2`
-> A's RT2 is dead as well. The test reproduces exactly this, including `refresh(attacker RT) == 401`.
**N-7 (2) CLOSED.** N-7 (1) (victim returns more than `ttl` later) remains an accepted risk, R-1 (unchanged, trade-off against F-3).

### 2. New attack surface from the looser condition?

- **Who can trigger it:** only someone who holds a real consumed RT (256 bit) of the device, i.e. the legitimate client
  or a thief. A third party without the token gets `:error` (no write), unchanged.
- **Additional window:** previously, a consumed young RT did nothing if the active row had expired. Now it deletes. That
  device is NOT dead, though. It is dormant and still redeemable through its `:current` RT, so this is the same reuse
  semantics as with a live row, and no new class. The window is bounded twice. (a) `young?` = `consumed.created_at + ttl > NOW()`
  (the F-3 bound, unchanged). (b) The active row's `created_at >= consumed.created_at`, and its `expires_at` is capped at
  `created_at + ttl` by `session_expires_at/1` and the worker cap. So the extra window only exists when the IdP `exp` is shorter than the ceiling, and it always
  stays inside the same F-3 bound that already applied to live rows.
- **F-3 preserved:** historical tokens (> ttl) -> `:error` without DELETE (test `:1447`). A truly dead device (active row
  deleted by logout, device delete, deactivation, IdP rejection, or the 7-day sweeper `:596`) -> `has_active? = false`
  -> no DELETE (test `:1463`, now with a real DELETE instead of backdating, which is semantically correct). **No cheap
  targeted logout through historical tokens.**
- Asymmetry, by design and not a finding: `active_sibling/1` (:192, `:replay` path) keeps `expires_at > NOW()`, so a
  PENDING RT never extends beyond the session's `expires_at` (AC3). This is the more restrictive side and grants nothing extra.

### 3. Parameter binding / fail-closed / docs

- The query is unchanged in its parameterization: `$1` RT, `$2::bigint` TTL integer from `SessionConfig`. The subquery only correlates
  columns. No interpolation.
- Fail-closed: DB error -> `{:error, :unavailable}` -> 503 without a write. The `cond` order is unchanged (`:current`
  before reuse; consumed outside the bound -> `:error`).
- Docs: `08-concepts.md` (reuse bullet, "any non-revoked row, i.e. exactly what the `:current` path would redeem, even if its
  access token has already expired; N-7") and the `resolve_refresh_token` moduledoc (:141-145) match the code.
- Logging: the reuse warning is a static literal + metadata `user_id`/`device_id`, with no token value (unchanged).

### New findings (cycle 5)

None.

### Severity count (whole diff, after cycle 5)

CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 0 · INFO 2 (N-8, N-9; unchanged)

### Final classification

**CLEAN — APPROVED.** N-7 CLOSED (part (2) fixed; part (1) = accepted risk R-1). F-1/F-2/F-3/N-1/N-2/N-3 remain CLOSED.
Accepted risks R-1..R-6 unchanged. I-1 (plaintext tokens) stays the next priority (`token-hashing-matrix-sessions`).
