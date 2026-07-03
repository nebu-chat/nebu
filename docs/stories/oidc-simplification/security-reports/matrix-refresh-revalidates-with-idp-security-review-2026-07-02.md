# Security Review — matrix-refresh-revalidates-with-idp — 2026-07-02

**Agent:** Kassandra
**Diff base:** `git diff --staged`
**Classification:** CLEAN
**Config:** `blocking_severity=CRITICAL`, `model=claude-opus-4-8[1m]`

## Executive Summary

This story converts `POST /_matrix/client/v3/refresh` from a purely-local opaque-token
rotation into a full OIDC resource-server re-validation: on every refresh the stored
`oidc_refresh_token` is decrypted, redeemed at the IdP (`grant_type=refresh_token`), and the
returned `id_token` is re-verified (`iss`/`aud`/`exp`/alg/signature) before any local rotation.
The fail-closed design is correct: every failure path returns an identical 401
`M_UNKNOWN_TOKEN` + `soft_logout: true` envelope, and the new confirmed-vs-transient branch does
not create an information leak or a session-longevity abuse path. Shared token-exchange logic
(AC5) removes the prior duplicate copy cleanly. No CRITICAL or HIGH findings. Two INFO notes and
one LOW (defense-in-depth) are recorded below.

## Findings

### [LOW] Kill-switch hard-delete is best-effort; a DB error on the confirmed-deprovisioning path leaves the session row intact

- **CWE / OWASP:** CWE-703 (Improper Check or Handling of Exceptional Conditions) / A04:2021
- **Datei:** `server/lib/nebu/matrix/http_public.ex:596`; `server/lib/nebu/matrix/session/matrix_session_store.ex:328-346`
- **Beschreibung:** The confirmed-deprovisioning / IdP-rejection branch executes
  `:ok = Store.delete_for_user_device(sess.user_id, sess.device_id)`. `delete_for_user_device/2`
  is best-effort by design — on a DB error it logs and still returns `:ok`. Consequently the
  `:ok =` match can never fail, and if the DELETE itself errors, the `matrix_sessions` row
  survives. For that single request the client still receives a 401, so no new tokens are minted,
  but the still-live opaque access token continues to work until its own `expires_at` and a later
  refresh must re-confirm deprovisioning before the row is finally removed.
- **Impact:** Bounded. No new token is issued on any failure branch, and the surviving opaque AT
  is independently capped by `expires_at` (min(oidc_exp, now+8h)). A retried `/refresh` re-runs
  the full IdP round-trip and re-attempts the delete. There is no path to mint fresh tokens for a
  deprovisioned user. This is a defense-in-depth gap on a security-critical kill-switch, not an
  exploitable bypass.
- **Empfehlung:** Optional. If stronger kill-switch guarantees are desired, have
  `delete_for_user_device/2` surface `{:error, reason}` and have the caller retry or alarm rather
  than silently proceeding. Not required for this story.
- **Referenz:** OWASP ASVS V3.3.1 (session termination), NIST AC-12.

### [INFO] Fail-closed transient/confirmed branch: no information leak and no session-longevity abuse

- **Datei:** `server/lib/nebu/matrix/http_public.ex:564-598, 644-653`
- **Beschreibung:** Reviewed the m1 code-review nuance specifically. Both fail-closed branches
  (transient `{:transient_check_failed, _}` and confirmed `{:error, reason}`) terminate in
  `deny_soft_logout(conn, "Unknown or expired refresh token")` — byte-identical status (401),
  errcode (`M_UNKNOWN_TOKEN`), message, and `soft_logout: true`. An attacker probing `/refresh`
  cannot distinguish "transiently unsure" from "confirmed revoked" from the response.
  The transient branch is only reachable AFTER a successful IdP refresh-token redemption AND
  successful `id_token` re-verification (the `with` chain in `revalidate_with_idp/1` short-circuits
  on any earlier failure); it fires only when the LOCAL `is_active` DB re-check returns a
  non-`:deactivated` error. A user deprovisioned in Nebu's DB returns `{:error, :deactivated}`
  → confirmed branch → hard-delete; a user deprovisioned at the IdP fails the exchange →
  confirmed branch → hard-delete. Neither is routed through the transient path. The transient
  path never reaches `do_rotate/4`, so no new tokens are ever minted — a truly-deprovisioned
  session cannot be kept alive or extended by forcing repeated transient errors; it merely
  postpones the row deletion while every request still returns 401.
- **Impact:** None (positive finding).

### [INFO] New IdP round-trip on refresh — attack surface and secret hygiene reviewed clean

- **Datei:** `server/lib/nebu/web/oidc_token_exchange.ex`; `server/lib/nebu/web/secret_box.ex`;
  `server/lib/nebu/matrix/http_public.ex:602-676`
- **Beschreibung:** The shared `Nebu.Web.OidcTokenExchange.refresh/2` POSTs to the discovered
  token endpoint with TLS peer verification for all `https://` URLs (`verify_peer` +
  `cacerts_get` + hostname match); plain `http://` is only the dev-internal Dex container,
  matching the pre-existing admin posture. The returned `id_token` is verified via
  `OidcPlug.verify_token/2` with `audience: client_id`, enforcing alg (alg-confusion blocked),
  `iss`, `aud`, `exp`, subject and signature. `oidc_refresh_token` is stored via
  `Nebu.Web.SecretBox` (AES-256-GCM, fresh random 12-byte nonce per encryption, GCM auth-tag
  verified on decrypt, fail-closed key derivation that refuses `SHA-256("")`). Provider-rotated
  RTs are re-encrypted before storage (AC4); absent rotation the old blob carries over unchanged
  (`enc_oidc_rt = new_oidc_rt || old_enc_oidc_rt`). PII extraction from fresh claims
  (`preferred_username`/`name`, `email`) is byte-identical to the login path
  (http_public.ex:329-330 vs 645-646). All `Logger.warning(..., reason: inspect(reason))` sites
  were traced: every possible `reason` is an atom or a tuple of atoms/status-codes
  (`:decrypt_failed`, `:no_oidc_refresh_token`, `{:transient_check_failed, db_reason}`,
  `{:token_endpoint_status, N}`, `:bad_signature`, `:bad_audience`, ...) — the plaintext refresh
  token and the `id_token` never appear in any logged reason. The `:matrix_oidc_refresh_override`
  seam is read only in `http_public.ex` and is never set anywhere in `lib/` or `config/`
  (test-only, prod-unreachable). All session-store SQL is parameterized;
  `delete_for_user_device/2` is correctly scoped to `(user_id, device_id)`.
- **Impact:** None (positive finding). Note the newly-live `:new_oidc_refresh_token` param on
  `rotate_tokens/1` — this story is its first real caller; the encrypted blob threaded in is
  produced by `SecretBox.encrypt/1` at the single call site (`maybe_put_new_oidc_rt/2`).

## Nebu Invariants Check

| Invariant                                   | Status |
|---------------------------------------------|:------:|
| Compliance RSP coverage                     | ✅ (no compliance-scoped table touched) |
| `reason` field on compliance access         | ✅ (no compliance access added) |
| Audit-log immutability                      | ✅ (no audit-table grant change) |
| `instance_admin` notification (if in-scope) | ✅ (not in scope) |
| OIDC token validation (`iss`/`aud`/`exp`)   | ✅ (fresh `id_token` re-verified via `OidcPlug.verify_token/2`, `audience: client_id`) |
| Matrix Power Level checks                   | ✅ (no room state mutation) |
| No hardcoded secrets                        | ✅ (client_secret resolved from server_config; no literals) |
| TLS 1.3 enforcement                         | ⚠️ (token-endpoint POST uses `verify_peer` but does not pin `MinVersion`; mirrors existing JwksCache/admin posture — see note) |
| AES-256-GCM correctness                     | ✅ (random nonce per encryption, tag verified, fail-closed key) |
| Ed25519 verify-before-accept                | ✅ (not applicable — no signed-event ingestion) |
| No secrets in logs / error messages         | ✅ (all logged `reason` values are atoms/status tuples; no token/PII) |

⚠️ TLS: `tls_opts_for/1` in `oidc_token_exchange.ex` sets `verify: :verify_peer` with CA and
hostname verification but does not set an explicit minimum protocol version. This mirrors the
pre-existing `JwksCache.http_opts_for/1` and admin posture and is not a regression introduced by
this story; the OTP `:ssl` default negotiates TLS 1.2/1.3. Recorded as ⚠️ (not verifiable as a
new defect from the diff), not as a finding.

## Overall Risk

| Severity  | Count |
|-----------|:-----:|
| CRITICAL  | 0 |
| HIGH      | 0 |
| MEDIUM    | 0 |
| LOW       | 1 |
| INFO      | 2 |

## Pipeline Decision

- **CLEAN** — no CRITICAL / HIGH findings. Pipeline may proceed. The single LOW is a
  defense-in-depth note on the best-effort kill-switch delete; no new token is ever minted on any
  failure branch, so it is not release-blocking.

---

*Generated by Kassandra — BMAD Security Review Agent. This report is an immutable audit artifact — do not edit retrospectively; create a new review if re-analysis is required.*
