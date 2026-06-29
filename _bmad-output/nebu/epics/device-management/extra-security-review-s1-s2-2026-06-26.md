# Extra Mid-Epic Security Review — device-management S1 + S2 (combined)

**Reviewer:** Kassandra (adversarial security reviewer)
**Date:** 2026-06-26
**Branch:** feature/device-management
**Diff scope:** `git diff 1cb4b240..6c77a8a6 -- server/`
**Nature:** EXTRA mid-epic review explicitly requested by Phil, covering the COMBINED S1+S2 work
BEFORE S3/S4 proceed. In addition to (not a replacement for) the mandatory epic-end SEC Gate 2.
Per-story SEC Gate 1 reviews (S1 APPROVED/CLEAN, S2 APPROVED/CLEAN) were re-verified against the
actual code here — not trusted — and both hold. This review's added value is the **combined
surface**: what the two per-story reviews structurally could not see in isolation.

Covers two committed stories:
- **S1** (`d90bccca`): migration 000010 (`devices` first-class table + idempotent backfill from
  `device_keys`); `DeviceKeyStore` re-sourced from `devices`.
- **S2** (`6c77a8a6`): login owns device lifecycle; server-authoritative token→device binding via
  new SHA-256-keyed `DeviceBinding` store + migration 000011; `sole_device_id` heuristic removed;
  cross-device transfer rejected; `/sync` last_seen throttle.

---

## Verdict: APPROVED / CLEAN — no CRITICAL, no HIGH.

The two security goals at the heart of this epic so far are **MET** and independently re-verified:
- **Token↔device binding integrity** (G1): a request's device is resolved SOLELY server-side
  (opaque → `matrix_sessions.device_id`; raw-JWT → `DeviceBinding.get_device(SHA-256(token))`),
  never from request input. Cross-device transfer is rejected (`/keys/upload` up-front 403),
  re-bind of a bound token is blocked, refresh copies device_id verbatim (cannot re-bind).
- **IDOR**: every device read/write is scoped to `conn.assigns[:current_user]`; `user_id` is never
  body-supplied on a write; `GET /devices/{id}` returns 404 (no existence oracle) for foreign/unknown.

Findings are MEDIUM/LOW hardening + watch-flags. The MEDIUMs are advisory (address before epic end);
none blocks the commit. The combined-surface MEDIUM (F-1, unbounded binding growth) is the
carry-forward concern Phil flagged — assessed below as a latent issue for S1+S2 itself, NOT only a
prerequisite for S3.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `device_binding.ex` (whole module) + `000011_jwt_device_bindings.up.sql` | **Unbounded, never-expiring `jwt_device_bindings` growth.** The table has NO `exp`/`expires_at` column and NO DELETE/sweeper of any kind. The PK is `token_hash`, so EACH distinct JWT gets its OWN row; Element uses raw OIDC JWTs directly (no refresh), and the IdP re-issues a fresh id_token on every login → a new `token_hash` → a new permanent row. Rows for long-expired tokens are never removed. Monotonic growth = slow resource exhaustion (disk/index bloat) and a permanently-retained `user_id → device_id → login-time` map. | Add an `exp BIGINT` (or `expires_at`) column populated from the verified token's `exp` at `put/3`; add a sweeper (`DELETE FROM jwt_device_bindings WHERE exp < now()`), mirroring `MatrixSessionStore.cleanup_expired/0`. This ALSO satisfies the S3 device-delete denylist enumeration (pattern #70) in one change — do it in S2's table now rather than retrofitting in S3. NOT an auth bypass (see Detail). |
| F-2 | MEDIUM | `http_public.ex:236-240` (login) → `devices` PK, `jwt_device_bindings.device_id`, `GET /devices` echo | **Client-supplied `device_id` is unbounded and unsanitised.** `params["device_id"]` is accepted on `is_binary` + non-empty ONLY — no length cap (≤255), no control-char/newline rejection. It lands in the `devices` composite PK, in `jwt_device_bindings.device_id`, is bound into the JWT device association, and is echoed back in the login response, `GET /devices`, `GET /devices/{id}`, and `whoami`. S1 explicitly deferred this to S2 ("correct home is S2"); **S2 did not close it** — the broken-handoff that project memory predicts for deferred input bounds. | Validate at the login write boundary: `byte_size(device_id) <= 255` and reject control chars (e.g. `String.match?(device_id, ~r/[\x00-\x1f\x7f]/) → 400`). Mirror onto the `/keys/upload` body `device_id` sink. Low exploitability today (parameterised SQL blocks injection; values are echoed only to the same authenticated user), but it is an unbounded attacker-controlled string in a PK and in multiple response bodies — close it before the Admin UI (S4) renders `device_id` as text. |
| F-3 | LOW | `protected.ex:1175-1186` (`maybe_bind_jwt_device`) | **Intra-user device-key clobber via an UNBOUND raw-JWT** (carried from S2 F-1, re-verified). A same-user token with no binding can name an existing device and overwrite its directory key blob + lazily bind to it. Same principal, no cross-user/cross-tenant crossing, non-E2EE directory (ADR-011). Window closes once a token is bound (login always binds). | Optionally refuse lazy-bind to a device that already has a different bound token, or require the device be keyless. Track to S3 (device endpoints land there). |
| F-4 | LOW | `device_binding.ex:96-139` (ETS cache) | **Per-node ETS TTL cache is unbounded in entry count** (carried from S2 F-2, re-verified). Eviction is only a staleness check on read; entries for never-re-read tokens persist until node restart. Memory growth under high token churn. Distinct from F-1 (F-1 is the DB table; F-4 is the per-node cache) but the SAME root cause — no lifecycle on token-keyed state. | Periodic ETS sweep or size cap. Bundle with F-1's lifecycle work. |
| F-5 | LOW | `000010_devices.up.sql`, `000011_jwt_device_bindings.up.sql` | **No RLS on `devices` or `jwt_device_bindings`** (carried from S1 F-1 / S2 F-3, re-verified). Family-wide gap shared with `matrix_sessions` (000001) and `device_keys` (000009). Consistent, NOT a regression; every query is application-scoped by `user_id` from the validated session. | Family-wide defense-in-depth follow-up, or document the deliberate omission in each migration header. |

---

## Detail — combined-surface analysis (the value of a mid-epic review)

### F-1 — Unbounded, never-expiring binding table. Why MEDIUM, not HIGH. (the carry-forward)

This is the concern raised during S2 (pattern #70) and the explicit focus of Phil's request. Assessed
for the **S1+S2 surface itself**, independent of S3's future kill-switch:

**The facts (re-verified in code):**
- `put/3` (device_binding.ex:32-55) is the only writer — called at JWT login (http_public.ex:388)
  and lazy-bind (protected.ex:1183). `get_device/1` is the only reader. There is **no DELETE,
  no sweeper, no `cleanup_expired` analogue** anywhere (`grep` across `server/lib/` confirms only
  `matrix_sessions` has a `cleanup_expired/0`, and even that table HAS an `expires_at` column;
  `jwt_device_bindings` has neither column nor function).
- PK = `token_hash = SHA-256(token)`. Two different JWTs → two rows. Element drives the raw-JWT
  path (MEMORY: "Element doesn't request refresh tokens"). Every IdP re-issue creates a new row;
  the prior row is orphaned forever the instant its token expires.

**Why it is NOT HIGH (no auth/replay escalation):**
- **No auth bypass via stale rows.** `OidcPlug.call_jwt` calls `get_device(token)` only AFTER
  `verify_token(token)` succeeds (oidc_plug.ex:120,136) — and `verify_token` enforces `exp`
  (`check_exp`, oidc_plug.ex:414-420, rejects missing/non-integer/past `exp`). An expired token
  never reaches the binding lookup. A stale row can only ever resolve a device for a token that
  STILL cryptographically verifies — i.e. it grants nothing the token didn't already have.
- **No replay gain.** The row maps token_hash→device; it confers no authentication by itself. The
  bearer token is the credential and is independently verified every request.

**Why it IS a real MEDIUM for S1+S2 now (not just an S3 prerequisite):**
- **Resource exhaustion over time.** A monotonically-growing table with a per-token row and zero
  reclamation is a slow-burn disk/index-bloat DoS. On a busy deployment (thousands of users, daily
  IdP re-issues) the dead-row count dwarfs the live one within weeks. This is a standing
  availability risk of the S2 design as shipped, not a deferred S3 problem.
- **Indefinite retention of an identity map.** `user_id → device_id → login-time` is retained
  forever even after the device is gone and the token long dead — a data-minimisation/PII-retention
  concern that compounds the more it grows.

**Why fixing it NOW is the right call:** S3's device-delete needs to denylist every JWT bound to a
device, which (pattern #70) requires `exp` to feed `TokenDenylist.revoke(jti, token, exp)` and a
`(user_id, device_id)` lookup. Adding `exp` + a sweeper to **this** S2 table closes the S1+S2
availability/retention issue AND lays the exact column S3 needs — one change instead of a retrofit.
Recommend doing it in S2's migration before S3 builds on top.

### F-2 — Unbounded client device_id, end-to-end. The deferred-input-bound handoff broke.

Traced the sink completely. `params["device_id"]` (http_public.ex:236) → `client_device_id` →
`device_id` (http_public.ex:318) flows, unbounded and unsanitised, into ALL of:
- `devices` composite PRIMARY KEY (via `register_device` → `upsert_device`),
- `jwt_device_bindings.device_id` (via `DeviceBinding.put`),
- the login response `device_id` field, `GET /devices`, `GET /devices/{id}`, `whoami`.

The only gate is `is_binary(d) and d != ""`. No `byte_size` cap, no control-char filter. S1's F-2
LOW said the "correct home is S2"; the S2 diff added device_id *honouring* but no device_id
*validation*. SQL injection is blocked (all sinks parameterised), and values are echoed only to the
same authenticated caller — so exploitability is low TODAY. But this is precisely the unbounded
attacker-controlled-string-in-a-PK class, and S4 will render `device_id` in the Admin UI as text
(MEMORY watch-list S4: "`last_seen_ip` rendered as text only" — `device_id` is the sibling field).
Bound + sanitise at the login write boundary now; close before S4 makes it a stored-output sink.

### F-3 / F-4 / F-5 — re-verified carry-overs

All three were raised at the per-story gates and are re-confirmed unchanged. F-3 (intra-user clobber)
and F-5 (no RLS) are unchanged in severity. F-4 (ETS cache unbounded) is grouped with F-1 because
both are "token-keyed state with no lifecycle" — fixing them together is the clean architectural move.

---

## Re-verification of the per-story CLEAN verdicts (did NOT trust them)

| Prior claim | Re-verify result |
|---|---|
| S1: all new SQL parameterised; backfill row-wise (no cross-user contamination); INNER JOIN can't hide a key-bearing device | CONFIRMED — `INSERT…SELECT … FROM device_keys ON CONFLICT DO NOTHING` is param-less server-internal copy; `query_devices` `JOIN … USING (user_id,device_id)` + `WHERE dk.user_id = ANY($1)`. |
| S1: IDOR-safe; `sole_device_id` scoped to caller's own rows | CONFIRMED — `sole_device_id` is now REMOVED entirely (S2), so the residual mis-attribution concern is moot. |
| S2 G1: device resolved solely server-side; `/keys/upload` mismatch 403 up-front; bound-device ordered FIRST in `upload_device_id`; lazy-bind no-ops on already-bound token | CONFIRMED — oidc_plug.ex:110,136; protected.ex:328-330 (403 before any write); upload_device_id orders bound-device first (protected.ex:1208-1216); maybe_bind_jwt_device no-ops when device_id set (protected.ex:1177-1180). |
| S2 G2: `rotate_tokens` copies user_id/device_id old→new, never touches bindings | CONFIRMED — refresh path does not write `jwt_device_bindings`. |
| S2: token never stored in clear (SHA-256 hex PK); never logged | CONFIRMED — `hash/1` = `:crypto.hash(:sha256, token) |> Base.encode16(:lower)`; no token value in any `Logger` call in the diff. |
| S2: last_seen_ip from `conn.remote_ip`, not XFF; touch throttled 60s, best-effort | CONFIRMED — `client_ip` reads `conn.remote_ip`; `touch_last_seen` is `WHERE last_seen_ts < cutoff`, `safe_query` never raises. |
| Migrations forward-only, idempotent, inline (ADR-018), `release_test` bumped to 10 and 11 | CONFIRMED. |
| alg-confusion / iss / aud / exp / sub | CONFIRMED unchanged from matrix-api-migration: explicit `@allowed_algs` asymmetric-only (no `none`/HS*), fail-closed iss/aud, exp + sub enforced. Login and request paths share the one `verify_token`. |

The per-story reviews were accurate. No prior CLEAN verdict was over-stated.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 2 (F-1 unbounded never-expiring binding table — combined-surface availability/retention,
  AND the S3 enabler; F-2 unbounded/unsanitised client `device_id` — deferred-input-bound handoff
  not closed)
- LOW: 3 (F-3 intra-user clobber on unbound JWT; F-4 ETS cache unbounded; F-5 no RLS — family-wide)

**Verdict: APPROVED / CLEAN.** No commit-blocking findings. The token↔device binding integrity and
IDOR posture of the combined S1+S2 surface are sound. The two MEDIUMs are advisory and should be
addressed before the epic-end SEC Gate 2 — and F-1 is best fixed in S2's table NOW (add `exp` + a
sweeper) because it simultaneously closes the S1+S2 unbounded-growth/retention issue AND provides the
`exp` column S3's device-delete denylist requires (pattern #70), turning a future retrofit into a
single coherent change. F-2 should be closed before S4 renders `device_id` in the Admin UI.

Carry to S3 SEC Gate 1 (unchanged from the design watch-list): UIA fresh-auth must verify IdP
`auth_time` (+ `prompt=login`/`max_age`), bind fresh `sub` == UIA-session user == access-token user,
device-delete must revoke opaque rows AND denylist every JWT bound to the device, `auth_time` must
not be reset by refresh, `/delete_devices` array cap.
