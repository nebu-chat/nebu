# Epic device-management Security Review (SEC Gate 2 — epic-end) — 2026-06-26

**Reviewer:** Kassandra (adversarial security reviewer)
**Type:** MANDATORY epic-end SEC Gate 2 (CLAUDE.md Gate 4). Independent of the four
per-story SEC Gate 1 reviews and the mid-epic extra S1+S2 review. Prior CLEAN/APPROVED
verdicts were NOT trusted — every exploit path was re-derived against the shipped code.

## Scope
- **Epic:** device-management (S1–S4)
- **Base:** `ca4600b3`
- **HEAD:** `aabad7e8`
- **Diff:** `git diff ca4600b3..aabad7e8 -- server/` (4753 insertions across 32 files; all
  changed non-test files read in full, not just hunks)
- **Stories covered:**
  - **S1** `d90bccca` — migration 000010 (`devices` first-class table + idempotent backfill from `device_keys`); `DeviceKeyStore` re-sourced from `devices`.
  - **S2** `6c77a8a6` — login-owned device lifecycle; server-authoritative token→device binding (SHA-256-keyed `DeviceBinding`); migration 000011; `sole_device_id` heuristic removed.
  - **S3** `d24c120d` — Matrix PUT/DELETE `/devices/{id}` + POST `/delete_devices`; `m.login.sso` UIA step-up (Option B, identity-bound, 15-min fresh-auth); per-device JWT kill-switch; `device_id` ingress validation; migration 000012; `Session.Sweeper`.
  - **S4** `aabad7e8` — Admin-UI per-user device view/rename/revoke (Phoenix LiveView controller via `Nebu.Matrix` facade); audit actions; S3 kill-switch reuse.

## Verdict: CLEAN — no CRITICAL, no HIGH.

The three HIGH risks this epic was always going to live or die on — all pre-registered in
my design-phase watch-list — are **closed and independently re-verified in code**:

1. **UIA fresh-auth is identity-bound** (the S3 H-1 fix). `Uia.complete/2` enforces
   `AND user_id = $authenticated_user`, where `authenticated_user` is derived server-side
   from the FRESHLY-VERIFIED id_token claims (`UserId.from_claims/2`) and NO request input
   (`session_id` only SELECTs the row; identity is checked independently). A foreign-sub
   completion matches 0 rows → stage not flipped, `auth_time` not refreshed, 403 page, no
   `onAuthDone()`. The exact cross-sub regression test exists. **Recurring pattern #69/#71
   is genuinely defeated, not theater.**
2. **The per-device JWT kill-switch is complete** (pattern #70). Both the Matrix self-delete
   path (`protected.ex` `delete_one_device`) and the Admin facade (`Nebu.Matrix.delete_user_device/2`)
   enumerate `DeviceBinding.list_for_user_device/2` and `TokenDenylist.revoke_by_hash(hash, exp)`
   each bound JWT until its own `exp`, then delete the binding rows AND the opaque session row
   AND the key material. Cross-node lag is closed by `OidcPlug` → `revoked?` DB fallback.
3. **Refresh cannot defeat the freshness gate.** `rotate_tokens/1` copies `auth_time`
   verbatim old→new row; only a fresh login (`login_auth_time`) or a verified UIA completion
   (`refresh_auth_time`) ever writes it.

Findings below are MEDIUM/LOW hardening + standing family-wide gaps — none blocks the epic.

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| F-1 | LOW | S2/S3 | `oidc_plug.ex:136` + `device_binding.ex` ETS cache (60s TTL) | Cross-node binding-cache lag: a deleted device's binding may resolve from a peer node's 60s cache, but the bound JWT is independently denylisted (DB fallback) so no auth is granted. Bounded, not a kill-switch hole. | New (re-confirmed S3 L-2) |
| F-2 | LOW | S3 | `uia.ex:190` + `matrix_session_store.refresh_auth_time` | A UIA completion refreshes `auth_time` for ALL of the user's opaque sessions, not just the re-authenticating device. Benign post-H-1 (only the legitimate user can trigger it); slightly widens the window cluster-wide. | New (re-confirmed S3 L-1) |
| F-3 | LOW | S3 | `sso_login.ex:269` | `do_redirect` posts `postMessage("authDone","*")` with a wildcard target origin. The page posts only the constant string `"authDone"` (no token/session id/claims), so a malicious `window.opener` learns only "an auth completed". No secret leaks. | New (re-confirmed S3 INFO) |
| F-4 | LOW | S1–S3 | `000010`/`000011`/`000012` migrations | No RLS on `devices`, `jwt_device_bindings`, `uia_sessions` — consistent family-wide gap shared with `matrix_sessions` (000001) and `device_keys` (000009). Every query is application-scoped by `user_id` from the validated session. Not a regression. | Carried (family-wide) |
| F-5 | LOW | S3 | `sso_login.ex:151-166` (`uia_fallback`) + `protected.ex:45` | The UIA auth-fallback `GET /_matrix/client/v3/auth/m.login.sso/fallback/web` drives an IdP round-trip + DB writes and has no dedicated per-IP rate limit (only the global 1 MB body cap + `SsoStore` 10k-pending-state cap with 429). Unauthenticated by design (it IS the auth step); session id is a 256-bit secret so no oracle. Defence-in-depth only. | New (advisory) |

## Detail

### The three pre-registered HIGHs — re-verified CLOSED (the point of this gate)

**(1) UIA identity binding — `uia.ex` + `sso_login.ex`.** Chain re-derived:
`do_callback` runs `exchange → OidcPlug.verify_token(id_token) → claims → check_nonce`,
then (UIA branch) `complete_uia(conn, entry.uia_session, claims)` computes
`authenticated_user = UserId.from_claims(claims, server_name)` — byte-identical to the
login derivation. `Uia.complete/2` UPDATEs `WHERE session_id=$1 AND user_id=$2 AND
consumed=FALSE AND expires_at>$3`. `session_id` only selects the row; `$2` is the verified
sub. Mismatch → 0 rows → `:error` → 403 page, stage NOT flipped, `auth_time` NOT refreshed,
no `onAuthDone()`. The reusable-row property is preserved (mismatch leaves
`stage_complete=FALSE, consumed=FALSE`), so the legitimate user can still complete later.
Only one `Uia.complete/2` caller (`sso_login.ex:260`) — no stale arity-1. The cross-sub
regression test (`device_endpoints_test.exs`) signs the callback with a random
`fresh_sub() ≠ victim`, window 86_400 so identity-binding is the ONLY gate, asserts cb 403 +
re-submit stays 401. M-1 `max_age=0` is added ONLY on the UIA path (`is_binary(uia_session)`),
login UX unchanged.

Residual (accepted, NOT a finding): `from_claims` prefers a configured claim /
`preferred_username` / `name` over raw `sub`, so two IdP accounts sharing that claim map to
one Matrix user_id — but this is IDENTICAL to primary login (such an attacker could already
log in AS the victim). The UIA binding is no weaker than the auth it gates. IdP/claim-mapping
trust property, not an epic defect.

**(2) Kill-switch completeness — `protected.ex:1330-1359`, `matrix.ex:328-348`,
`token_denylist.ex:118-134`, `device_binding.ex:97-133`.** `revoke_by_hash` inserts ETS
`{:hash, hex}` + DB plain-hex — the SAME key `revoked?` computes from a live token via
`hash_key/1` / `hash_db_key/1`, so no silent no-op. `exp` carried from the verified JWT
(login `http_public.ex:416`, lazy-bind `protected.ex:1408`) into the binding and on into
the denylist entry, live until the token's own expiry. The Matrix self-delete preserve is
`nil` unless the op was satisfied by a FRESH re-auth (`via_auth=true`), and even then spares
ONLY the exact `{preserve_device, preserve_token_hash}` (the live request credential) — all
OTHER JWTs on that device are revoked. The Admin facade has NO preserve (an admin acts on
another user's device → EVERY token revoked) and reuses the IDENTICAL teardown — it does NOT
reimplement a weaker revoke (S4 watch-list item closed). `DeviceBinding.delete_for_user_device`
`cache_delete`s each hash BEFORE the DB delete, so no stale "bound" cache.

**(3) Refresh non-regression — `matrix_session_store.ex` `rotate_tokens`, `uia.ex` `fresh?`.**
`rotate_tokens` reads `auth_time` from the old row and inserts it verbatim; `create/1` sets it
from `login_auth_time(claims)` (auth_time → iat → nil); the only other writer is
`refresh_auth_time/2` (UIA completion, H-1-gated). `fresh?/1` uses unix-seconds throughout,
STRICT `<` (0 window always stale), `fresh?(nil)`/non-integer → false (fail-closed). runtime.exs
applies only a strictly-positive `NEBU_UIA_FRESH_AUTH_SECONDS`; junk/≤0 → 900s default.

### Cross-story integration (auth gaps invisible to single-story reviews)

- **Migration composition 000010→000012:** all forward-only, idempotent
  (`CREATE TABLE/INDEX IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, `ON CONFLICT DO NOTHING`),
  never editing the shipped 000009. S1 backfills `devices` from `device_keys` row-wise
  (composite-key copy, no cross-user contamination). S2 adds `jwt_device_bindings`. S3 adds
  `auth_time`/`exp` (nullable → pre-migration rows read STALE = fail-closed) + `uia_sessions`
  + the `(user_id,device_id)` index the kill-switch enumerates by. `release_test.exs` covers
  000001–000012. Down migrations reverse cleanly; the only data loss is keyless-device
  identity on a `devices` drop (explicitly warned in the header) — acceptable for a down path.
- **extra-review F-1 (unbounded binding growth) CLOSED:** 000012 added `exp BIGINT`; the new
  supervised `Session.Sweeper` (`DELETE FROM jwt_device_bindings WHERE exp IS NOT NULL AND exp
  < now` + `Uia.cleanup_expired`, hourly) is wired into `application.ex` `repo_children` next
  to `Nebu.Repo`. NULL-exp (pre-000012) rows left untouched. This was the one MEDIUM the
  mid-epic review asked to fix before epic-end — done, in S3's table, exactly as recommended.
- **extra-review F-2 (unbounded/unsanitised client device_id) CLOSED:** `Nebu.Matrix.DeviceId.valid?/1`
  enforces `byte_size ≤ 255` + rejects `\x00-\x1f`/`\x7f`, applied at BOTH ingress sinks —
  login (`http_public.ex:269`, present-but-invalid → 400 BEFORE verify/provision) and
  `/keys/upload` body `device_keys.device_id` (`protected.ex:328`, before any store touch).
  This closed before S4 rendered `device_id` in the Admin UI — the predicted handoff is fixed.
- **Kill-switch + sweeper + UIA interaction:** independent and idempotent. The sweeper only
  deletes rows whose token can no longer authenticate (exp passed → OidcPlug rejects before
  the binding lookup). The kill-switch denylists by hash+exp (DB-persisted, cluster-correct).
  UIA state is DB-backed (cluster-correct, ADR-020), single-use via atomic conditional UPDATE.
  No ordering hazard found across the three.

### Standard-scope sweep (re-run against the full epic diff)

- **SQL injection:** all new SQL parameterised. The one interpolation —
  `device_key_store.ex` `DELETE FROM #{table}` — iterates a HARDCODED literal table list,
  never attacker-influenced. SAFE.
- **XSS (Admin UI, S4):** `show.html.heex` renders `device_id` / `display_name` via HEEx
  `{...}` (auto HTML-escaped in text position) and via escaped attribute interpolation
  (`id=`, `aria-label=`, `data-confirm=`, form `action=`). Form `action` URLs build the
  device_id segment with `URI.encode(.., &URI.char_unreserved?/1)`. The `confirm()` onsubmit
  message is a FIXED string (no interpolation). With device_id now ingress-validated (no
  control chars, ≤255), no stored-XSS sink. CLEAN.
- **CSRF (S4 state-changing POSTs):** both rename and revoke forms carry
  `_csrf_token = Plug.CSRFProtection.get_csrf_token()`; the admin `:browser` pipeline runs
  `:protect_from_forgery`. Revoke uses POST + `_method=DELETE` (Plug.MethodOverride). CLEAN.
- **Auth bypass / IDOR:** Matrix device endpoints scope every read/write to
  `conn.assigns[:current_user]` (never body/path-supplied); `belongs_to_other_user?` → 404
  BEFORE any UIA challenge (no existence/timing oracle); foreign ids in `/delete_devices`
  silently skipped. Admin endpoints gated by `plug Nebu.Admin.Auth, :require_admin` on every
  action and always act on the ROUTE `user_id` (admin choosing target is by-design, not IDOR;
  audit captures the actor). `/delete_devices` capped at 100 (checked on raw length before
  filter) + deduped.
- **Token↔device binding integrity:** device resolved SOLELY server-side — opaque from
  `matrix_sessions.device_id`, raw-JWT from `DeviceBinding.get_device(SHA-256(token))`. Body
  `device_id` is only equality-checked (`/keys/upload` 403 up-front on mismatch), never
  authority. `device_id` never embedded in the IdP JWT; bound server-side.
- **JWT validation:** unchanged single `verify_token` path — explicit asymmetric-only alg
  allowlist (no `none`/HS*), fail-closed iss/aud, exp + sub enforced. Login and request paths
  share it. No alg-confusion / missing-exp/aud regression.
- **Timing attacks:** nonce + SSO state compared via `Plug.Crypto.secure_compare`. Token-hash
  comparison is a DB/ETS key equality on a non-secret SHA-256 digest (not a secret compare).
- **Weak crypto:** none — SHA-256 for non-reversible token-hash/PKCE, `strong_rand_bytes`
  for all ids/session ids (256-bit), asymmetric JWT verify. No md5/sha1/DES.
- **Secrets/tokens in logs:** raw tokens never logged (SHA-256-only keys); login logs
  `user_id`/`device_id` only; SSO failures log `inspect(reason)` (no token); the H-1 mismatch
  warning carries no PII/sub/session id; denylist logs a key, not the raw token. CLEAN.
- **Open redirect:** the SSO redirect path enforces the scheme allow/deny-list
  (`redirect_url_allowed?`: https always, http loopback only, deep-link allowlist, javascript/
  data/file/vbscript/blob denied); the UIA fallback uses a fixed internal `https://uia.local/
  complete` marker (renders a page, never redirects to it). CLEAN.
- **Body-size:** global 1 MB JSON cap; `/keys/upload` per-request key cap (100); createRoom
  `initial_state` cap (64); `/delete_devices` cap (100).
- **Audit trail (project gotcha):** `device_renamed` + `device_deleted` registered in
  `AuditWriter.@known_actions` at the SAME commit; S4 emits an audit row on success AND
  failure for both rename and delete. CLEAN.

## Cross-Story Patterns
No NEW systemic pattern. This epic is the resolution of THREE pre-existing watch patterns:
- **#69/#71** (fresh-auth must verify identity, not an SSO round-trip) — resolved correctly by
  H-1's `AND user_id = $authenticated_user` + `max_age=0` on the UIA path.
- **#70** (revoke a logical entity → enumerate every token FORM) — resolved by the dual-path
  kill-switch (opaque row delete + JWT denylist-by-hash) reused identically by Matrix and Admin.
- **#72** (port a single choke-point → patch every branch) — the Admin facade explicitly reuses
  the S3 teardown rather than forking a weaker one.

## Accepted Risks
None requiring new sign-off. F-4 (no RLS on the auth-table family) remains a standing,
previously-noted defense-in-depth gap, consistent across `matrix_sessions`/`device_keys`/
`devices`/`jwt_device_bindings`/`uia_sessions` — every query is application-scoped. Candidate
for a family-wide hardening follow-up, not a device-management blocker.

## Follow-up Stories Required
None (no CRITICAL/HIGH).

Optional hardening (non-blocking, may be bundled into a future auth-hardening story):
- Family-wide RLS on the auth tables (F-4).
- Per-IP rate limit on the UIA auth-fallback endpoint (F-5).
- Tighten `postMessage` target origin from `"*"` to the server origin (F-3).

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 5
Follow-up stories required: 0
Accepted risks: 0 (1 standing family-wide gap carried as advisory)

**Epic security gate: PASS.** All three pre-registered design-phase HIGHs (UIA identity
binding, kill-switch completeness, refresh non-regression) are closed and re-verified against
the shipped code — not trusted from prior verdicts. Both mid-epic MEDIUMs (binding-table
growth + device_id validation) are closed. Migrations compose cleanly; the kill-switch,
sweeper, and UIA interact safely; no auth gap emerges only when S1–S4 are combined.
