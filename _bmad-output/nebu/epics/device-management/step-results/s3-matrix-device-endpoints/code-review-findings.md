# Code Review — S3 (cycle 1 re-review): CLEAN

Verdict: CLEAN. 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 INFO. Build clean (--warnings-as-errors).
Prior cycle-0 MINOR-1 (JWT self-delete preserve asymmetry) and INFO-1 (dead sso_state column) both
correctly resolved.

Verified:
- Symmetric token-preserve: delete_one_device/3 skips ONLY the binding row whose
  token_hash == hash(caller's live token) AND device == caller's current device. Opaque + JWT consistent.
  Deleting OTHER devices revokes them; single-DELETE recent-window path (preserve=nil) still revokes the
  presented token per AC3/F-1. No under-revocation, no unexpected logout.
- Hash alignment confirmed both directions: DeviceBinding.hash/1 (now public) == TokenDenylist key scheme
  == jwt_device_bindings.token_hash. caller_credential/1 reads conn.assigns[:access_token] (set for both
  opaque + JWT by OidcPlug). No false-skip, no silent never-match.
- F-1 not weakened: a SECOND JWT bound to the caller's deleted device is still revoked (different hash).
- INFO-1: grep sso_state = 0 hits; column+index gone from 000012 up/down; SsoStore CSRF `state` untouched.
- 2 new regression tests pin the JWT bulk self/other delete behavior. release_test pins 1..12.
- All ACs intact; migrations 000009-000011 immutable.

Ready to mark done.
