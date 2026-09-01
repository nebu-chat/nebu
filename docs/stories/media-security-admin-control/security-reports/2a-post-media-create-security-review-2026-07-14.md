# Security Review — media-security-admin-control / 2a-post-media-create

**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-14
**Diff scope:** `git diff --staged` — `server/lib/nebu/media.ex` (+101/-4), `server/lib/nebu/matrix.ex` (+23), `server/lib/nebu/media/state_machine.ex` (+78), `server/lib/nebu/media/permission.ex` (new, +27), `server/lib/nebu/media/db.ex` (+20), `server/lib/nebu/web/router/media.ex` (+9), and the test files (`media_create_test.exs` new, `media_fakes.exs`, `state_machine_test.exs`). Non-code artifacts (pipeline-state, findings, sanctum, story md) excluded.
**Story:** 2a — `POST /_matrix/media/v1/create`, the reservation half of Matrix's async upload flow. Reserves a `media_id`, writes one `media_files` row in `:reserved`, returns `mxc://` + server-chosen `unused_expires_at`. Stores no file bytes.

---

## Verdict: APPROVED — no CRITICAL/HIGH. Commit not blocked.

The endpoint is a small, read-body-free, authenticated write that reserves a row through the single sanctioned genesis writer. Every design decision the pipeline flagged for extra scrutiny was verified against the code and holds up:

- The `media_state_transitions` actor-type contract was **not** widened — `{:system, nil}` was already legal under 1b's `@type actor` and `@transitions`/`transition/4` are byte-for-byte unchanged. The genesis row (`actor_type: 'system', actor_id: NULL`) is a faithful use of the pre-existing shape, not a new one.
- The empty-crypto placeholders (`aes_key_hex: ''`, `nonce_hex: ''`) are provably **unreachable** by any decrypt path today: `download_gate/1` serves ONLY `:released` (allow-list), and `:reserved` hits the catch-all `451 M_NOT_YET_UPLOADED` before `fetch_and_decrypt/3` is ever entered.
- `Nebu.Matrix.active?/1` is a read-only `SELECT is_active`, reached only via `Nebu.Media.Permission.can_upload?/1`, which is called only with the **caller's own** `conn.assigns.current_user` — no arbitrary-MXID probing surface is exposed.
- Accountability is intact: "who reserved `media_id` X" is answerable directly from `media_files.uploader_user_id`, and **no** compliance/audit reader consults `media_state_transitions.actor_id` today (grep-confirmed), so the NULL actor_id creates no silent traceability gap.
- `media_id` is 128-bit `:crypto.strong_rand_bytes/1`, base64url, PK-unique, with exactly one bounded collision retry.

No finding rises above **LOW/INFO**. Four advisory notes and one watch-flag for later stories.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | LOW/INFO | `db.ex:88` (`count_pending_reservations/1`) | Pending-cap counter fails OPEN (returns `0`) on any DB error, so a transient counting failure lets a reservation through uncapped | Acceptable as-is — the cap is a soft business limit and the failure is self-limiting (see detail). Optionally fail the *request* (not the count) closed on error. Keep the "soft limit, not security control" framing. |
| F-2 | LOW/INFO | `router/media.ex:65` | `POST /v1/create` carries no per-IP `RateLimit` plug, unlike its sibling write endpoints (`upload`, `preview_url`) | Bounded by auth + the per-user pending cap; not a leak. Consider a modest per-IP cap for parity/defence-in-depth against authenticated request-rate abuse. |
| F-3 | INFO (watch-flag) | `media.ex:265` / `state_machine.ex` genesis | No server-side reaper for expired `:reserved` rows in this story; stale reservations count against the 20/user cap indefinitely → self-lockout + minor row retention | Track for the cleanup/expiry story (2b or later): a reaper that hard-deletes rows past `unused_expires_at` OR excludes expired rows from `count_pending_reservations`. |
| F-4 | INFO | `matrix.ex:141` (`active?/1`) | New PUBLIC `Nebu.Matrix.active?/1` takes an arbitrary `user_id`; today only called with the caller's own identity, but the signature invites future account-existence-oracle misuse | No change now. Watch-flag: any future caller passing a *client-supplied* MXID would turn this into a deactivation/existence oracle (cf. the M_USER_DEACTIVATED accepted-risk in MEMORY). |
| F-5 | INFO | `media.ex:239`, `permission.ex:24` | `can_upload?/1`/`active?/1` guard on `is_binary(user_id)`; a `nil` `current_user` would raise → 500 rather than a clean 401 | Non-exploitable — OidcPlug guarantees a binary `current_user` or halts with 401 before the handler runs. Noted for robustness only. |

---

## Detail

### F-1 — `count_pending_reservations/1` fails open on DB error [LOW/INFO]

`db.ex` maps any non-`{:ok, %{rows: [[count]]}}` result of the COUNT query to `0`, and the moduledoc states this is deliberate ("a DB error degrades to `0` … a soft business limit, not a security control"). The coordinator asked whether an attacker who can force transient DB errors could thereby bypass the pending cap and flood `media_files` with `:reserved` rows.

**Assessment: acceptable, and self-limiting.** The bypass requires the COUNT query to fail while the immediately-following genesis INSERT (`state_machine.create/1`, same `Nebu.Repo`, same connection pool) succeeds. Those two operations hit the same database — a DB unhealthy enough to fail the SELECT will, in the overwhelmingly common case, also fail the INSERT (`Repo.transaction` → `{:error, _}` → `500 M_UNKNOWN`, no row written). So the fail-open window is a narrow, non-attacker-steerable race, not a durable bypass primitive. Even if it fires, the impact is bounded to empty, byte-less rows behind an authenticated (OIDC-gated) endpoint. This is a rate/business limit, not a confidentiality or integrity control, so fail-open is a defensible posture. If hardening is desired, fail the *request* (return the 429, or a 503) on a count error rather than the count itself — but this is optional.

### F-2 — No per-IP rate limit on `POST /v1/create` [LOW/INFO]

`upload` (600/min b5) and `preview_url` (30/min b10) each get an inline per-IP `RateLimit`; `create` gets none. The story reasons that AC3's 429 is a per-user pending-count business check, not a per-IP token bucket, and that is a valid design distinction. The residual exposure: an authenticated user can issue unlimited `create` requests. Below the cap each triggers one indexed COUNT + one two-INSERT transaction; at/above the cap each short-circuits to a single indexed COUNT + 429 (no write). The COUNT is backed by `media_files_uploader_idx (uploader_user_id)` (000001_init.up.sql:306), so it is not a full-table scan, and durable row growth is hard-capped at 20/user. Net effect is a generic authenticated request-rate load, bounded in storage impact. Not a vulnerability; a per-IP cap here would be defence-in-depth parity with the sibling endpoints. Advisory.

### F-3 — No reaper for expired `:reserved` rows this story [INFO / watch-flag]

`unused_expires_at` is computed server-side (`now + 86_400_000`) and returned to the client, but nothing in this branch enforces it: a `:reserved` row lives forever until Story 2b's PUT transitions it. `count_pending_reservations/1` counts ALL `:reserved` rows regardless of expiry, so a user who reserves 20 ids and never uploads is permanently capped at the limit (self-inflicted availability) and leaves 20 empty rows behind. Bounded and low-impact (auth-gated, 20/user, byte-less rows), but it should not be lost: the eventual cleanup/expiry story must either hard-delete rows past `unused_expires_at` or exclude expired rows from the pending count. Watch-flag for the epic.

### F-4 — `Nebu.Matrix.active?/1` is a new public arbitrary-user account-state read [INFO]

`active?/1` runs `SELECT is_active FROM users WHERE user_id = $1` and returns `true` only on `[[true]]`, `false` otherwise (fail-closed on unknown/deactivated/DB-error). ADR-020 is respected — `Nebu.Media` reaches Matrix account state ONLY through this public function, never `Nebu.Matrix.Session.*` directly. Today the sole caller, `Permission.can_upload?/1`, passes `conn.assigns.current_user` (the caller's own OIDC-derived MXID), so there is **no** path for an authenticated user to probe an arbitrary *other* user's deactivation status. The note is forward-looking: the function's signature accepts any binary, so a future caller wiring it to a client-supplied MXID would create a deactivation/existence oracle. That would still sit within the already-accepted M_USER_DEACTIVATED existence-disclosure risk (MEMORY, Story 14.4, 2026-05-17), but the finer-grained `is_active` bit and the arbitrary-target reachability would be a new surface — flag any such future caller.

### F-5 — `is_binary` guard turns a nil identity into a 500 not a 401 [INFO]

`can_upload?(user_id) when is_binary(user_id)` and `active?(user_id) when is_binary(user_id)` would raise `FunctionClauseError` (→ Plug 500) if `current_user` were ever `nil`. Verified non-reachable: `Nebu.Web.Router.Media` runs `plug Nebu.Web.Plugs.OidcPlug` before `:match`/`:dispatch`, and OidcPlug either assigns a non-nil binary `current_user` (`user_id`/`sess.user_id`) or halts with a 401 (`deny/*`). No unauthenticated or nil-identity path reaches `Media.create/1`. Robustness note only.

---

## Adversarial probe results (coordinator watch-list)

1. **Actor-type contract widening (compliance/audit integrity, ADR-031):** CLEAN. `@type actor :: {:system, nil} | {:admin, Ecto.UUID.t()}` (state_machine.ex:43) is unchanged; `{:system, nil}` pre-dates this story. `@transitions` (the guard table) and `transition/4` are untouched — the genesis `create/1` is an additive INSERT-from-NULL path that does not (and need not) consult the guard table, and its `to_state`/`actor_type` are hardcoded string literals (`'reserved'`/`'system'`), not caller-influenced. No accidental widening of the append-only ledger's actor contract.

2. **Genesis atomicity:** CONFIRMED. `media_files` INSERT + `media_state_transitions` INSERT run inside one `Repo.transaction/1`. The transition insert is `Ecto.Adapters.SQL.query!` (bang) — a failure raises inside the transaction and rolls back the whole thing, so a `media_files` row can never exist without its genesis audit row. The `media_files` insert itself is non-bang with explicit `:unique_violation` → `Repo.rollback(:media_id_taken)` and a catch-all `Repo.rollback(reason)`. Either both rows commit or neither does.

3. **Empty crypto placeholders reachable today?** NO. `download_gate/1` (media.ex:415) makes `:released` the SOLE `:serve` clause; `:reserved` falls to the catch-all `{451, "M_NOT_YET_UPLOADED"}` (media.ex:429), which is returned by `with_authorised_media/4` BEFORE `fetch_and_decrypt/3` / `Crypto.decrypt` is entered (verified against 1c's gate analysis, gate unchanged in this diff). `preview_url` performs an outbound fetch and never reads `media_files` bytes; the only admin reader (`admin/db.ex`) does `COUNT(*) … WHERE storage_key IS NOT NULL` and never decrypts. So `aes_key_hex: ''`/`nonce_hex: ''` never reach a cipher — no crash, no garbage-decrypt, no disclosure. `content_type: ''`/`file_size: 0` are likewise gated out of every serve path.

4. **`active?/1` as an information-disclosure vector:** CLEAN (see F-4). Read-only; ADR-020-compliant; only ever called with the caller's own identity; fail-closed on unknown/error.

5. **Accountability / "who reserved X":** ANSWERABLE. `media_files.uploader_user_id` is set to the calling MXID on the genesis INSERT (AC1). No code reads `media_state_transitions.actor_id` for attribution today (grep: zero readers of `media_state_transitions` outside `state_machine.ex`; admin/compliance touch only `media_files` counts). NULL `actor_id` on the system-genesis row therefore misleads no existing tool. No gap.

6. **`media_id` collision / entropy (AC5):** SOUND. `:crypto.strong_rand_bytes(16)` = 128 bits, `Base.url_encode64(padding: false)`. PRIMARY-KEY uniqueness enforced by the DB; a `:unique_violation` triggers exactly ONE regeneration retry (`retried?` flag), a second collision surfaces as 500 (no unbounded loop). No new `UNIQUE(server_name, media_id)` constraint is needed — Nebu is single-server / non-federated (ADR-021), `server_name` is a constant, and the PK already covers `media_id`.

7. **Client-controlled input / no-body-trust (AC2/AC6):** CONFIRMED. `create/1` reads only `conn.assigns[:current_user]`; it never reads the request body and never consults query/path params. `unused_expires_at` is server-computed from `System.system_time/1 + config`; no client-supplied expiry is accepted. `server_name` and all limits come from `Application.get_env`. No injection surface: the four INSERT bind params (`media_id`, `server_name`, `uploader_user_id`, `now_ms`) plus the `%{}` metadata are all `$n` placeholders.

8. **Auth gate (AC7) / CSRF:** CONFIRMED. Route sits behind `OidcPlug` (401 for missing/invalid/expired/revoked/deactivated tokens). Bearer-token auth (no ambient cookie), so CSRF is not applicable. Deactivated accounts are already rejected at the plug; `can_upload?/1` is an independent, uncached second boundary (freshness ≥ the plug's ~60s TTL cache) — good defence-in-depth, no conflict.

9. **Check ordering (403 before 429):** CONFIRMED (media.ex `cond`). Permission is evaluated first, so a forbidden user cannot infer their pending-upload count from a differing error code.

10. **Timing side-channel:** no finding. The 403/429/200 branches differ in observable work by design (a 200 does 2 INSERTs), already signalled by the status code; nothing leaks a secret via timing on a 128-bit-random unguessable id.

---

## Summary

- **CRITICAL:** 0
- **HIGH:** 0
- **MEDIUM:** 0
- **LOW:** 2 — F-1 (fail-open pending counter, acceptable/self-limiting), F-2 (no per-IP cap on `create`, defence-in-depth parity)
- **INFO:** 3 — F-3 (no reaper for expired reservations — epic watch-flag), F-4 (`active?/1` arbitrary-user oracle if future-misused), F-5 (nil-identity → 500 robustness, non-reachable)

**Verdict: APPROVED.** Every design decision flagged for scrutiny — the genesis writer, the untouched actor contract, the empty-crypto placeholders, `active?/1`'s reachability, the NULL-actor accountability question, and the PK-only collision defence — was verified in the code and is sound. The endpoint reads no request body, trusts no client input, is auth-gated, orders its checks correctly, and reserves exactly one row atomically with its audit trail. All findings are advisory; F-3 is the one to carry forward as an epic watch-flag for the reservation-cleanup/expiry story.
