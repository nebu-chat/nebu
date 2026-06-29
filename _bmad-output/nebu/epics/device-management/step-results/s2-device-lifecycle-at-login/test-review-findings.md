# TEA Test Review — device_lifecycle_login_test.exs (S2)

Verdict: Strong red-phase suite. One MAJOR gap (AC5 uncovered), a few MINOR robustness issues. No forbidden auth shortcuts. G1 security test well-constructed.

## AC coverage
- AC1 ✅ (login registers device; display_name + created_at + last_seen present)
- AC2 ✅ (reuse keeps same row; display_name ignored on reuse)
- AC3 ✅ (whoami opaque + raw-JWT)
- AC4 ✅ (OTK-only upload to bound device, multi-device)
- AC5 ❌ MAJOR — zero coverage (last_seen update on /sync + throttle untested)
- AC6 ✅ (G1 reject + DEV_B unchanged)
- AC7 ✅ (G2 whoami before/after refresh; G3 grace-window 401 + soft_logout)

## MAJOR-1 — AC5 throttled last-seen update: ZERO coverage
AC1 tests only assert last_seen_ts is *present* at login; nothing asserts a later authed request *advances* it, and the throttle is unverified. Required before done.
Deterministic approach (no sleep): capture last_seen_ts after login, force it into the past via SQL `UPDATE devices SET last_seen_ts = ...` (file already does this for matrix_sessions.expires_at), issue /sync, assert it advanced; then a second immediate /sync does NOT advance it (proves throttle).

## MINOR-1 — vacuous `if Process.whereis(Nebu.Repo) … else assert true end` guards
Whole module is @moduletag :integration, so the else branch is dead weight and can produce green `assert true` false-positives if run without the integration filter. Prefer dropping the guard so a missing Repo fails loudly.

## MINOR-2 — G1 attack uses a forged key, so rejection could fire on signature, not device-mismatch
Add an inverse case: a validly self-consistent DEV_B device_keys body under token_a must ALSO be rejected — pins G1 to the token↔device binding check, not an incidental signature defect.

## INFO — otk/1 hardcodes ed25519:DEV / @x signatures (pre-existing convention; latent if OTK sig validation added).

## Clean: no hard waits, no order-dependence (async:false, unique sub, full cleanup), no cookie forging / no DB-seeded auth (real SSO→loginToken→/login), error codes asserted, no GenServer state (no crash test needed), no Playwright (ui:false).

## Required before done: close MAJOR-1. Recommended: MINOR-1, MINOR-2.
