## Security Review — server-paced-session-refresh / background-session-refresh-worker

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged diff — new `Nebu.Matrix.Session.RefreshWorker` GenServer that proactively redeems each device's stored upstream OIDC refresh token before `matrix_sessions.expires_at`; `defp→def` visibility widening of three `HttpPublic` helpers; supervision-tree registration; two new tuning env vars.
**Date:** 2026-07-03
**Verdict:** **BLOCKED** — 1 HIGH finding.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | HIGH | `refresh_worker.ex:239-251` (`redeem/1` `{:error, reason}` branch) + `matrix_session_store.ex:328-346` (`delete_for_user_device/2`) | Cluster-concurrency race: the losing node's M1 hard-delete destroys the winning node's freshly-refreshed session row, forcing unnecessary re-login of legitimate users under the supported multi-node deployment. | Scope the fail-closed hard-delete to the exact row the worker re-selected (delete `WHERE access_token = $1 AND revoked_at IS NULL`, not `WHERE user_id AND device_id`), or gate the whole worker behind a cluster singleton (`:global`/`Highlander`) so only one node runs a cycle. |
| 2 | MEDIUM | `refresh_worker.ex:239-251`; classification originates in `oidc_token_exchange.ex:99-104` + `http_public.ex:662-671` | Transient IdP unreachability (network blip, discovery 503, timeout) is classified as a CONFIRMED rejection and hard-deletes the session. The worker amplifies this pre-existing `/refresh` behavior from per-client-request to mass-delete of every near-expiry session during a single outage window. | Widen the transient-error tag to also cover `{:token_endpoint_unreachable, _}` and `{:discovery_failed, _}` so infra outages leave sessions intact (they fall back to the bounded TTL) instead of hard-deleting en masse. |
| 3 | LOW | `refresh_worker.ex:166-179` (candidate query); schema `000001_init.up.sql:326-336` | "One non-revoked row per `(user_id, device_id)`" is convention-maintained by `rotate_tokens/1`, not DB-enforced. A future writer that breaks the convention silently makes the worker extend multiple "active" rows. | Add a partial unique index `CREATE UNIQUE INDEX ... ON matrix_sessions (user_id, device_id) WHERE revoked_at IS NULL` in a forward migration. Already flagged in the worker's own m3 comment as a known gap. |

### Detail

**Finding #1 — Losing-node hard-delete nukes the winner's refreshed session (cluster race)** [HIGH]

Every Nebu node runs the full supervision tree, and `RefreshWorker` is registered in `repo_children` (`application.ex:100`) as an **unnamed, un-singleton'd** GenServer. In the K8s/Helm deployment (`CLUSTER_STRATEGY=kubernetes`, `runtime.exs:224-262`) N nodes therefore run N independent workers, all scanning the same shared `matrix_sessions` table with the same lookahead and the same wall-clock. Overlapping candidate windows on the same near-expiry row are the common case, not an edge case.

Interleaving that destroys a healthy session (assumes the IdP rotates refresh tokens on redemption — the RFC 9700 / RFC 6749 §10.4 recommended default, and Dex's behavior):

1. Node A and Node B both list `access_token = T_old` (`revoked_at IS NULL`) in `candidates/0`.
2. Both re-select via `get_by_access_token(T_old)` (TOCTOU re-check) — both still see `revoked_at IS NULL`.
3. Node A: `revalidate_with_idp/1` redeems the upstream RT, IdP rotates it, `rotate_tokens/1` soft-revokes `T_old` (`WHERE access_token=T_old AND revoked_at IS NULL` → 1 row) and inserts new row `T_new`. Session is now healthy on `T_new`.
4. Node B: `revalidate_with_idp/1` calls the IdP with the **same** upstream RT, which A already consumed → IdP returns 400/401 → `exchange_oidc_refresh_token/1` yields `{:error, {:token_endpoint_status, 401}}`. This is NOT tagged `{:transient_check_failed, _}` (that tag only wraps `check_still_active/2` DB failures, `http_public.ex:669`), so it falls into `redeem/1`'s confirmed-rejection branch.
5. Node B calls `Store.delete_for_user_device(sess.user_id, sess.device_id)` → `DELETE FROM matrix_sessions WHERE user_id=$1 AND device_id=$2` (`matrix_session_store.ex:331`) → deletes **T_new**, A's freshly-inserted healthy row.

Net: a session that was just successfully refreshed is hard-deleted by the node that lost the redemption race. The user gets a `401 M_UNKNOWN_TOKEN` + `soft_logout: true` on their next request and must re-login — the exact outcome this story exists to prevent, now triggered *by* the worker on legitimate, active users, with no attacker involvement.

Why the moduledoc's cluster-safety analysis misses it: that analysis (lines 80-90) reasons only about `rotate_tokens/1`'s `WHERE ... revoked_at IS NULL` guard, which correctly makes the *rotation loser* a safe no-op. But the M1 hard-delete path (added cycle-1) is **not** guarded by that predicate and **not scoped to a single row** — `delete_for_user_device/2` deletes by `(user_id, device_id)`, so it reaches across and deletes the winner's brand-new row. The safe non-rotating-RT case (both nodes' `rotate_tokens` guarded by the revoked_at predicate) was analyzed; the rotating-RT case that drives the delete branch was not. There is no test for this two-node interleaving (`refresh_worker_test.exs` covers the single-node `{:token_endpoint_status, 400}` hard-delete and grace-period selection only).

This is fail-closed in direction (a valid session is destroyed, not illegitimately extended — no confidentiality/auth breach), so it is not CRITICAL. But it is a reliable, attacker-independent, self-inflicted denial of service on legitimate users under the supported clustered topology, and it defeats the story's entire purpose. HIGH.

Remediation (either):
- **Preferred / minimal:** scope the fail-closed delete to the exact row the worker re-selected and is acting on — `DELETE FROM matrix_sessions WHERE access_token = $1 AND revoked_at IS NULL` on `sess.access_token`. The row-level `revoked_at IS NULL` guard then gives the same true-atomicity the rotation path has: if A already soft-revoked/replaced it, B's delete matches 0 rows and cannot touch `T_new`. (Note the client `/refresh` path `do_refresh_with/2` has the same `delete_for_user_device` call, but there it is safe because a client presents exactly one live session and there is no sibling winner racing it — the worker's fan-out over all devices from every node is what makes the wide-scoped delete unsafe.)
- **Alternative:** run the worker as a cluster singleton (`:global` name / `Highlander` / leader-elected) so only one node executes cycles, eliminating cross-node redemption of the same RT entirely. This also removes the double-IdP-charge and Finding #2's mass-amplification.

**Finding #2 — Transient IdP outage mass-hard-deletes sessions** [MEDIUM]

`revalidate_with_idp/1` returns `{:error, {:token_endpoint_unreachable, _}}` / `{:error, {:discovery_failed, _}}` for network timeouts, IdP-down, and discovery-endpoint failures (`oidc_token_exchange.ex:99-104`, `76-80`). These are plain `{:error, reason}` — only `check_still_active/2` DB failures get the `{:transient_check_failed, _}` tag (`http_public.ex:669`). So a transient IdP outage lands in `redeem/1`'s confirmed-rejection branch and hard-deletes the session. Because the worker iterates **every** session inside the lookahead window on each tick, a brief IdP restart during one cycle mass-deletes all of them — whereas the client `/refresh` path only ever hits one session per user-initiated request. The classification matches the existing client path faithfully (so it is a pre-existing design choice, mirrored — not a new invention), but the fan-out amplification is new and materially changes the blast radius. MEDIUM. Fix: treat `{:token_endpoint_unreachable, _}` and `{:discovery_failed, _}` as transient (leave the row to expire via the bounded TTL) rather than as confirmed deprovisioning.

**Finding #3 — "One active row per device" is convention, not a DB constraint** [LOW]

`candidates/0` relies on a plain `revoked_at IS NULL` filter to pick exactly the active row, which is correct only because `rotate_tokens/1` always soft-revokes the old row in the same transaction as the insert. No partial unique index enforces this (`000001_init.up.sql:326-336`). Already self-documented in the worker's m3 comment. Defense-in-depth: add the partial unique index in a forward migration. LOW.

### Design-property verification (supplementary emphasis items 1-10)

| # | Property | Verdict | Evidence |
|---|----------|---------|----------|
| 1 | Per-device grain, per-row failure isolation | HOLDS | `refresh/0` iterates rows via `Enum.each(&refresh_row/1)`; `refresh_row/1` wraps each row in `rescue` (`:186-203`); one row's crash/rejection logs and returns `:ok`, never aborting the cycle or sibling rows. |
| 2 | Bounded, rolling TTL — never open-ended | HOLDS | `rotate/3` sets `new_expires_at = HttpPublic.session_expires_at(fresh_claims)` = `min(oidc_exp, now + matrix_session_ttl_seconds)` (`http_public.ex:479-490`). `rotate_tokens/1` INSERTs a NEW row with that value; it is never derived from the old row's `expires_at`, so no accumulation is possible across any number of cycles. |
| 3 | TOCTOU-safety | HOLDS | `refresh_row/1` re-selects via `get_by_access_token` and matches `%{revoked_at: nil}` immediately before `redeem→revalidate_with_idp` (no earlier). True atomicity on the write: `rotate_tokens/1`'s `UPDATE ... WHERE access_token=$1 AND revoked_at IS NULL` → 0 rows → rollback → `:error` if a delete/revoke races in between. (Caveat: the fail-closed DELETE is NOT similarly row-guarded — Finding #1.) |
| 4 | Grace-window-safe row selection | HOLDS (for current code) | Candidate query and re-check both filter `revoked_at IS NULL`; a soft-revoked grace sibling (`revoked_at IS NOT NULL`) is never selected. Guaranteed only by the rotate_tokens convention, not a DB constraint — see Finding #3. |
| 5 | Fail-closed dispatch (M1 hard-delete scoping) | PARTIAL | Not attacker-exploitable for cross-session harm: `sess.user_id`/`sess.device_id` are DB-derived from the re-selected row, so a malicious/compromised IdP can only cause deletion of *its own* session (correct deprovisioning semantics), never someone else's; the `{:transient_check_failed, _}` tag is producible only by an internal DB failure, not attacker input. BUT the branch mis-classifies transient IdP outages (Finding #2) and the unscoped delete drives the cluster race (Finding #1). |
| 6 | Orthogonality of the ≤60s liveness check | HOLDS | `git diff --stat -- server/lib/nebu/web/plugs/oidc_plug.ex` is empty (byte-for-byte unmodified). Worker env vars (`parse_ttl` requires `n > 0`; junk/0/negative → compiled defaults) affect only cycle cadence and lookahead; they cannot touch `matrix_session_ttl_seconds` or the OidcPlug re-check. A larger lookahead only widens which sessions get proactively refreshed — each refresh still applies the bounded cap and still requires a successful IdP round-trip + `check_still_active`. No bypass path. |
| 7 | Cluster safety / concurrent execution | FAILS | See Finding #1. The rotation path is race-safe (guarded UPDATE); the M1 hard-delete path is not, and destroys the winner's row. |
| 8 | defp→def visibility widening (ADR-020) | HOLDS | All three funcs are `@doc false`, remain in `Nebu.Matrix.HttpPublic`, and are called only from `Nebu.Matrix.Session.RefreshWorker` (grep confirms no caller outside `server/lib/nebu/matrix/`). Same-domain; ADR-020 unaffected. Preconditions preserved: the worker re-selects a live session immediately before `revalidate_with_idp/1`; `session_expires_at/1` and `maybe_put_new_oidc_rt/2` are pure/stateless. |
| 9 | Logging hygiene | HOLDS | Worker Logger calls emit only `user_id`, `device_id`, and `reason: inspect(reason)`. `reason` values (`:deactivated`, `{:token_endpoint_status, n}`, `{:token_endpoint_unreachable, _}`, `:no_id_token`, `:no_oidc_refresh_token`, decrypt-error atoms) never carry the raw access token, the encrypted/decrypted OIDC RT, or fresh claims. Access tokens are used only as SQL params. No sensitive material logged at any level. |
| 10 | Standard framework coverage (OWASP/ASVS/CWE/STRIDE/Nebu invariants) | See below | |

### Standard-framework notes

- **Injection (SQLi):** All worker SQL uses parameterized `$1` placeholders (`Ecto.Adapters.SQL.query` with a params list); no string interpolation of user/row data. Clean.
- **Crypto:** OIDC RT round-trips through `Nebu.Web.SecretBox` (AES-256-GCM) for both decrypt-on-read and encrypt-on-store (`maybe_put_new_oidc_rt/2`); opaque tokens minted via `:crypto.strong_rand_bytes(32)`. TLS peer verification is enforced on the IdP token endpoint (`oidc_token_exchange.ex:123-137`, `verify: :verify_peer` + hostname match) — the recurring `:httpc` empty-ssl-opts gap (MEMORY patterns from oidc-middleware-migration / full-elixir-stack) does NOT recur here. Clean.
- **AuthN/AuthZ:** No new endpoint, route, or plug; the worker is an internal supervised process with no request surface. Deactivation kill-switch is honored via `check_still_active/2` → `{:error, :deactivated}` → hard-delete (consistent with MEMORY pattern #75, oidc-session-refresh deactivation-bypass closure).
- **STRIDE — Denial of Service:** Finding #1 and #2 are the DoS surface (self-inflicted, on legitimate users). No unbounded loop/allocation; one bounded query + per-row work per interval.
- **Compliance / audit immutability:** No `audit_log` writes and no changes to RLS-protected tables; append-only invariants untouched.
- **ADR-018/019/021:** Plain GenServer, inline SQL, no service layer, pure Elixir — conformant.

### Summary

CRITICAL: 0
HIGH: 1 — **blocks commit** (Finding #1, cluster-concurrency hard-delete of the winner's refreshed row)
MEDIUM: 1 — address before merge (Finding #2, transient-outage mass-delete amplification)
LOW: 1 — advisory (Finding #3, missing partial unique index)

**Verdict: BLOCKED.** Finding #1 must be fixed (scope the fail-closed delete to `access_token = $1 AND revoked_at IS NULL`, or make the worker a cluster singleton) before this ships to the clustered deployment. Fixing #1 via the singleton route also resolves #2's amplification and the double-IdP-charge.

---

## Re-Review Addendum — cycle-2 fix verification

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Date:** 2026-07-03 (re-review, same day)
**Trigger:** RE-REVIEW of my own prior BLOCKED verdict after fixes for HIGH #1 and MEDIUM #2 were applied. Independent re-verification — traced the actual code, did not trust the fix summary or the cycle-3 code-reviewer clearance.
**Verdict:** **APPROVED (unblocked)** — HIGH #1 and MEDIUM #2 (as originally scoped) are genuinely closed. One NEW MEDIUM residual of the same class as #2 identified (Finding #4, advisory, non-blocking). LOW #3 unchanged.

### Re-verification results

**Finding #1 (HIGH) — CLOSED.**
- `MatrixSessionStore.delete_by_access_token/1` (`matrix_session_store.ex:380-396`) is genuinely row-scoped: `DELETE FROM matrix_sessions WHERE access_token = $1 AND revoked_at IS NULL`, parameterized via `safe_query` (`Ecto.Adapters.SQL.query` with a params list — no interpolation), `is_binary/1` guard, best-effort (never raises). No SQL-injection surface; `access_token` is a DB-derived opaque value from the worker's own re-select, never attacker input.
- `refresh_worker.ex:320` — the confirmed-rejection branch of `redeem/1` calls `Store.delete_by_access_token(sess.access_token)`, NOT the old wide `delete_for_user_device/2`. Confirmed by grep: `delete_by_access_token/1` has exactly one production caller (this branch); the wide `delete_for_user_device/2` is untouched and still used only by single-actor / single-request paths (`protected.ex` device removal, `http_public.ex` `do_refresh_with/2`, `matrix.ex`, `event_dispatcher/server.ex`) where no sibling-node fan-out races the delete — exactly as my original report reasoned.
- Race re-traced against the NEW code step-by-step: node A wins, `rotate_tokens/1` soft-revokes T_old (guarded `WHERE access_token=T_old AND revoked_at IS NULL`) and inserts T_new; node B's redemption fails → confirmed-rejection branch → `delete_by_access_token(T_old)` where T_old is now `revoked_at IS NOT NULL` → matches **0 rows** → T_new (winner) untouched. The `revoked_at IS NULL` guard gives the delete the same true per-row atomicity `rotate_tokens/1` has. Hold confirmed.
- Race-regression test (`refresh_worker_test.exs:955-1028`) is **deterministic**, not timing-dependent: it forces the exact interleaving synchronously from inside the `:matrix_oidc_refresh_override` callback (the real production seam = "the instant before the IdP call") — node A's `rotate_tokens/1` runs, then node B's error is returned, within one synchronous cycle. Asserts the winner's row survives with `revoked_at: nil`, correct `expires_at`, **remains usable for auth** (a real `GET /_matrix/client/v3/sync` with the winner's token returns 200 — not merely "a row exists"), and exactly one live row remains for the device. This is the exact scenario from my original report, closed correctly.

**Finding #2 (MEDIUM) — CLOSED as originally scoped.**
- `transient?/1` (`refresh_worker.ex:277-280`) matches `{:transient_check_failed, _}`, `{:token_endpoint_unreachable, _}`, `{:discovery_failed, _}` → transient (leave row intact); everything else → `false` (fail-closed hard-delete).
- Verified against the ACTUAL error taxonomy (read, not assumed) from `revalidate_with_idp/1` → `check_still_active/2` (`http_public.ex:662-671`) and `exchange_oidc_refresh_token/1` → `OidcTokenExchange.refresh/2` (`oidc_token_exchange.ex:79,100,103,113,116`).
- Confirmed-rejection signals are NOT swept into transient: `:deactivated` → `transient?` = false → hard-delete (correct deprovisioning — verified by the `:deactivated` test at `refresh_worker_test.exs:843`); `{:transient_check_failed, _}` → true (correct). The pattern match is precise (tagged 2-tuples with exact tag atoms), no overly-broad catch that could accidentally spare a genuinely dead/deactivated session.
- Both new transient shapes exercised via the REAL seam (`put_matrix_oidc_refresh_override` → the same `:matrix_oidc_refresh_override` production callback inside `exchange_oidc_refresh_token/1`) returning the exact tuples `OidcTokenExchange.refresh/2` produces (`refresh_worker_test.exs:1038-1104`) — not a fake/mocked shortcut. Both assert the row survives un-revoked and un-extended.

**Finding #3 (LOW) — UNCHANGED, no escalation.** Partial unique index deliberately not added; the `revoked_at IS NULL` single-active-row invariant remains convention-maintained by `rotate_tokens/1` and is documented in the worker (m3 comment, `refresh_worker.ex:191-203`). Still an acceptable advisory.

### NEW Finding

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 4 | MEDIUM | `refresh_worker.ex:277-280` (`transient?/1`); origin `oidc_token_exchange.ex:100` (`{:token_endpoint_status, status}` carries the raw non-2xx status) | The Finding-#2 fix closed only the two shapes I originally named (`:token_endpoint_unreachable`, `:discovery_failed`). But `{:token_endpoint_status, status}` carries the RAW HTTP status for **any** non-2xx — including IdP **5xx / 429** (server error / throttling during a restart, deploy, or rate-limit spike, common behind an ingress that returns 502/503 while pods cycle). Those are IdP-unavailability, NOT proof the IdP rejected THIS refresh token, yet `transient?/1` defaults them to `false` → confirmed-rejection hard-delete. Under the worker's per-cycle fan-out this mass-hard-deletes every near-expiry session during a 5xx/429 window — the SAME self-inflicted mass-re-login DoS as the original Finding #2, merely gated on a different (and arguably more common) error shape. Fail-closed in direction (no auth/confidentiality breach), requires an IdP 5xx/429 window to trigger → MEDIUM, advisory. | Classify `{:token_endpoint_status, s}` where `s >= 500 or s == 429` (and, defensibly, `s == 408`) as transient; keep `400 / 401 / 403` (explicit token-level rejection of THIS RT) as confirmed hard-delete. Equivalently, narrow the confirmed-rejection set to token-rejection status codes rather than "any non-2xx". Also consider `:issuer_not_configured` / `:client_id_not_configured` (config-not-loaded → transient-ish, same fan-out amplification) — lower priority. The bounded TTL already fail-safes the transient case, so leaving these rows alone is the correct conservative direction. |

**Finding #4 detail.** My original Finding #2 remediation under-specified the transient set — I named the two connection-level shapes but not the HTTP-status-level equivalent. The applied fix faithfully implemented my named list, so the *class* (transient IdP unavailability must not be treated as token rejection under fan-out) is not fully closed: a 5xx/429/408 response still hard-deletes. This is not a regression introduced by the fix; it is a residual the narrow fix left open, and I am naming it now because a re-review's duty is correctness, not rubber-stamping my own prior incomplete list. Non-blocking: same fail-closed direction and same MEDIUM severity as the original #2, triggered only during an IdP server-error/throttling window.

### No new issues introduced by the fix

- `delete_by_access_token/1`: no new SQL-injection surface (parameterized `$1`), single legitimate caller, `is_binary` guard, never raises. Clean.
- `transient?/1`: no new fail-OPEN path. Unknown/unexpected shapes default to `false` (confirmed rejection / hard-delete), i.e. the conservative fail-CLOSED direction — it never accidentally spares a genuinely dead session. The residual (Finding #4) is that this same conservative default over-deletes for transient 5xx/429; there is NO case where an unknown shape wrongly EXTENDS a session.
- env-var knobs (`runtime.exs`): parsed via existing `parse_ttl/1` (strictly-positive-integer; junk/≤0 → compiled defaults; never raises). No boot-break, no injection. The `sha512` pipe reflow is cosmetic.
- Worker remains per-node / un-singletoned — now SAFE for Finding #1 because the delete is row-scoped (my original report offered row-scoping OR singleton; row-scoping was chosen and is sufficient).

### Final Summary (post-fix)

CRITICAL: 0
HIGH: 0 — Finding #1 CLOSED (row-scoped `delete_by_access_token/1`, verified against a deterministic two-node race regression test)
MEDIUM: 1 open — Finding #4 (transient IdP 5xx/429 still hard-deletes under fan-out; advisory, address before epic end). Finding #2 CLOSED as originally scoped.
LOW: 1 — Finding #3 unchanged (advisory)

**Final verdict: APPROVED / UNBLOCKED.** The BLOCKING HIGH #1 is genuinely fixed and the originally-scoped MEDIUM #2 is closed, both with real regression tests exercising the true code seams. Finding #4 is a newly-surfaced MEDIUM sibling of #2 (my original remediation list was incomplete) — advisory, non-blocking, fail-closed in direction; recommended to close before epic end by widening the transient set to IdP 5xx/429 status codes.

---

## Final Confirmation Pass — Finding #4 fix (2026-07-03)

**Scope:** narrow confirmation of the applied `transient?/1` fix for MEDIUM #4 only. Not a full re-review.

**Verified against current source (`refresh_worker.ex:306-310`):**

```elixir
defp transient?({:transient_check_failed, _reason}), do: true
defp transient?({:token_endpoint_unreachable, _reason}), do: true
defp transient?({:discovery_failed, _reason}), do: true
defp transient?({:token_endpoint_status, status}) when status >= 500 or status == 429, do: true
defp transient?(_other), do: false
```

1. **Clause ordering / guard syntax — CORRECT.** The new `{:token_endpoint_status, status} when status >= 500 or status == 429` clause is placed on line 309, BEFORE the catch-all `_other` on line 310. Elixir evaluates function clauses top-to-bottom; no earlier clause matches a `{:token_endpoint_status, _}` tuple (the three preceding clauses match distinct tags), so there is no shadowing. Guard is valid Elixir (`>=`, `==`, `or` are all guard-safe). No clause-ordering bug.
2. **400/401/403 and unexpected statuses still fall through — CONFIRMED.** A `{:token_endpoint_status, 400}` (or 401/403) fails the `>= 500 or == 429` guard, skips line 309, and lands on the catch-all `_other -> false` = confirmed rejection = hard-delete. The conservative fail-closed default for genuinely-unknown shapes is preserved.
3. **Tests exercise the REAL dispatch seam — CONFIRMED.** `put_matrix_oidc_refresh_override/1` (`refresh_worker_test.exs:323`) sets `:matrix_oidc_refresh_override`, the exact production callback consumed inside `exchange_oidc_refresh_token/1` (`http_public.ex:681-683`), which sits in the `with` chain of `revalidate_with_idp/1` — the same function the worker's `redeem/1` calls (`refresh_worker.ex:313`). The override replaces only the HTTP+JWT-verify leg; the returned `{:error, {:token_endpoint_status, N}}` propagates through the identical production path into `transient?/1`. This is the true tuple `OidcTokenExchange.refresh/2` emits — not a mock bypass. The 503 and 429 tests assert the row survives un-revoked and un-extended; the 400/401 boundary test asserts both rows are hard-deleted (SQL row count == []).
4. **No regression — CONFIRMED.** The change is a single added clause; the three pre-existing transient clauses and the catch-all are byte-for-byte unchanged. `oidc_plug.ex` diff empty. Verification reported: targeted suite 17/17 pass, full unit suite 1202/0. No fail-open path introduced (unknown shapes still default to hard-delete).

**Finding #4: CLOSED.** The residual I named in the addendum (transient IdP 5xx/429 hard-deleting under fan-out) is now correctly classified as transient, closing the full class of the original Finding #2 (transient IdP unavailability must not be treated as token rejection).

### Overall Story Verdict — CLEAN / APPROVED

| Finding | Severity | Status |
|---|---|---|
| #1 | HIGH | CLOSED — row-scoped `delete_by_access_token/1`, two-node race regression test |
| #2 | MEDIUM | CLOSED — `:token_endpoint_unreachable` / `:discovery_failed` classified transient |
| #4 | MEDIUM | CLOSED — `{:token_endpoint_status, s}` where `s >= 500 or s == 429` classified transient |
| #3 | LOW | Accepted advisory — convention-maintained single-active-row invariant, no escalation |

CRITICAL: 0 · HIGH: 0 · MEDIUM: 0 open · LOW: 1 (accepted advisory)

**Final sign-off: APPROVED / CLEAN.** All blocking and MEDIUM findings for this security-required story are closed with real regression tests exercising the true production code seams. The only remaining item is the LOW #3 advisory, explicitly accepted. No blocker remains.
