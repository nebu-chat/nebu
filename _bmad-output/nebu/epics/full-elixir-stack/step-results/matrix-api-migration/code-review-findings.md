# Code Review — matrix-api-migration (cycle 1 — fix verification)

**Verdict: NOT fully CLEAN — 1 remaining MINOR (MINOR-6, newly introduced). No MAJOR.**

## Cycle-0 findings — verification
- MAJOR-1 (GET /login flows): RESOLVED. login_flows/1 returns exact Go GetLogin shape (m.login.sso + identity_providers + m.login.token). Routing disambiguation on conn.request_path is correct (forward rewrites path_info not request_path); auth_issuer/auth_metadata/POST login unaffected. Test present.
- MINOR-1 (dead since-branch): RESOLVED.
- MINOR-3 (provisioning gated by ETS): functionally resolved BUT introduced MINOR-6.
- MINOR-4 (auth_metadata 503): RESOLVED — 503 M_UNAVAILABLE on fetch failure, matches Go; tested.
- MINOR-5 (50 distinct clients + comment): RESOLVED.
- MINOR-2 (invite/leave %{} in /sync): acceptable as documented — proto SyncRoom has no membership field; data genuinely not in delta.rooms; Go built it from separate DB queries. Tracked follow-up. INFO.

## NEW finding
**MINOR-6 (NEW) — provisioning ETS cache has no TTL; mid-session deactivation not enforced until node restart (oidc_plug.ex ~92-149).**
Go's makeStatusChecker (gateway/internal/middleware/auth.go) caches is_active with a 60s TTL → deactivated user blocked within 60s. The new :nebu_http_provisioned_users ETS set has no TTL: once cached, provision/2 short-circuits and never re-invokes TokenValidator.validate, so {:error, :deactivated} is never re-reached. A user deactivated AFTER first successful authed request is accepted for the whole node lifetime. The fix comment claiming "deactivation mid-session takes effect" is incorrect. exp still bounds short-lived tokens; recoverable on restart → MINOR not MAJOR, but weakens a security control vs Go parity (Kassandra-relevant).
FIX: store {user_id, expires_at} in ETS, treat expired as cache miss (mirror Go 60s TTL); correct the misleading comment; add a regression test (deactivated-after-cached → still rejected after TTL).

## Disposition
MINOR-6 → auto-cycle to dev (cycle 2), small safe fix. MAJOR genuinely fixed.
