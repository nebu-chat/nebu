# Security review (SEC Gate 1): oauth-authorize-freshness, 2026-10-12

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator. Scope: staged diff of story `docs/stories/oauth-broker/oauth-authorize-freshness.md` (gates i, y, E-2, l, n, ak(1)-(3); ADR-033 FR1-FR20), 58 files.
Classification cycle 0: **CLEAN** (0 CRITICAL, 0 HIGH, 1 MEDIUM, 5 LOW, 5 INFO).

E-2 verdict: closed against the one-click / no-interaction chain. `CodeStore.insert` has exactly one caller (`Consent.mint`); every successful callback stops at a consent row + `303 /oauth2/consent`; callback/token cannot be driven without Allow; consent state is a 256-bit cookie, SHA-256-keyed row, single `DELETE..RETURNING`, CSRF derived from the cookie, constant-time compare, `__Host-` on https; clickjacking blocked (XFO DENY + frame-ancestors none); cross-site POST blocked (SameSite=Lax, Origin, Sec-Fetch-Site; `Origin: null` only with same-origin); no autofocus/script. Freshness reads `auth_time` only (never `iat`), clamps future values, binds to the server-side `created_at`; account page NULL auth_time never fresh. CSP `form-action` built only from regex-validated parts (no injection; `[::1]` -> `http:`). Same-client identity cannot be spoofed without the victim's exact redirect set. Logging law holds.

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| M-1 | MEDIUM | Double-clickjacking: attacker page opens a popup while navigating `window.opener` to `/oauth2/authorize` with an approved attacker client + victim device id; consent page lands behind the popup, the victim's second click of a double-click hits Allow (fixed position, real user activation: Sec-Fetch-User/Origin/CSRF all pass). Residual of E-2 | cycle 1: arm Allow only after real interaction (hash-pinned script, pointer movement/key press + minimum dwell), `Cross-Origin-Opener-Policy: same-origin`, Deny first, test that Allow starts disabled |
| L-1 | LOW | Device-holder check only at Allow; redemption does not re-check under the device lock (attacker controls timing within the 60 s code TTL) | cycle 1 if contained, else follow-up ay |
| L-2 | LOW | Consent table has only the global 10 000 cap (no per-user/per-source) | cycle 1: per-user and per-source cap inside the INSERT |
| L-3 | LOW | No fencing on the refresh lease; TTL 25 s can expire before a slow IdP leg ends -> second IdP redemption -> false logout | cycle 1: TTL 60 s; fencing follow-up |
| L-4 | LOW | First-upload branch (UIA-free) of `do_persist_cross_signing` still uses the error-blind unlocked `get_keys/1` (pre-existing, adjacent to ak) | cycle 1: error-aware locked read |
| L-5 | LOW | Wording "approved by your administrator" lends credibility to the unverified `client_uri`; no warning for an https destination that is not part of the claimed website; suffix-match "part of" on a bare suffix | cycle 1 |
INFO: rolling deploy (old nodes still mint codes right after the callback: cut over all nodes before `oauth_enabled`), CSP/redirect safe, freshness sound, same-client identity sound, logging law satisfied.
