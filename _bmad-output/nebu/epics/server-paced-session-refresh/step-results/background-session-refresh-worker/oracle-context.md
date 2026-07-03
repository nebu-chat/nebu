# Oracle Gate — background-session-refresh-worker

## Q1 — Applicable CS API Surface & MUST Rules

**Client-facing API surface added/changed by this worker: NONE.** No new endpoint, event type, or request/response shape. Triggered by an internal timer, not any CS API HTTP request.

**Spec rules that still constrain the design (invariants the worker MUST preserve on the endpoints it indirectly affects):**
- Using access tokens (line 4274-4292): missing/invalid credentials MUST return 401 with `M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN`. `M_UNKNOWN_TOKEN` covers "needs to be refreshed" and "logged out". Worker MUST NOT change this: once bounded TTL is reached with no successful background refresh, requests with that access token MUST still 401 `M_UNKNOWN_TOKEN`.
- Refreshing access tokens (line 4309-4341): expired access token → `M_UNKNOWN_TOKEN`, "preferably with `soft_logout: true`". Refresh token grace: old refresh token remains valid until new tokens are used, then revoked. AC4's "active non-revoked latest-`expires_at` row" selection and AC3's revoked_at TOCTOU re-check MUST stay consistent with this rotation-grace semantics.
- Soft logout (line 4342-4357): `soft_logout` defaults `false`; `true` means persisted state may be reused; `false`/omitted means session destroyed, client MUST discard state. AC6 fail-closed MUST NOT downgrade the shape — the eventual 401 MUST match what the server already emits for natural expiry.
- Token↔device binding (line 4293-4308): tokens are device-scoped; refreshed tokens rebind to the same device. AC2 per-device isolation and AC8 device-deletion fail-safe MUST respect this scoping.

**Net answer:** no new compliance surface is added, but the worker MUST NOT violate the existing `M_UNKNOWN_TOKEN` / `soft_logout` / rotation-grace invariants that `POST /refresh` and access-token-validation already implement.

## Q2 — Error Codes / Status Codes / Edge Cases That MUST Be Test-Covered

- **401 + `M_UNKNOWN_TOKEN`** for a request whose bounded TTL was reached because background refresh gave up (AC6) — MUST be byte-identical in shape to the natural-expiry 401 (same errcode, same `soft_logout` value).
- **`soft_logout` field** present/absent exactly as the existing expiry path emits it — worker give-up must NOT flip `soft_logout` to a different value than ordinary expiry.
- **Session still valid → NO 401** while background refresh is succeeding (AC1).
- **TOCTOU: revoked_at set between select and IdP call** (AC3) → worker MUST skip the upstream call; token MUST still 401 `M_UNKNOWN_TOKEN`.
- **Rotation grace row selection** (AC4): only active non-revoked latest-`expires_at` row refreshed; superseded/revoked rows not extended.
- **Bounded TTL ceiling** = `min(oidc_exp, now+8h)`, identical to `session_expires_at/1` (AC5). Never extend beyond; at ceiling the 401 fires.
- **Upstream IdP rejection → fail-closed** (AC6): no extension, no fallback; subsequent request 401.
- **Device-deletion failure edge** (AC8): deletion error MUST NOT suppress the bounded-TTL fail-safe; token still 401s at ceiling.
- **Orthogonality of ≤60s liveness check** (AC7): unchanged, independent of worker interval.

Spec file: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` lines 4263-4360.

Code under test: `server/lib/nebu/matrix/http_public.ex` (`revalidate_with_idp/1`), `server/lib/nebu/matrix/session/matrix_session_store.ex` (`rotate_tokens/2`, `session_expires_at/1`), `server/lib/nebu/web/plugs/oidc_plug.ex` (liveness check).
