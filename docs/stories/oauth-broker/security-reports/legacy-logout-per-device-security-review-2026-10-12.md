# Security review (SEC Gate 1): legacy-logout-per-device, 2026-10-12

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator. Scope: staged diff of bugfix story `docs/stories/oauth-broker/legacy-logout-per-device.md` (gates r, x; ADR-033 LL1-LL12).
Classification cycle 0: **CLEAN** (0 CRITICAL, 0 HIGH, 0 MEDIUM, 3 LOW, 6 INFO).

Holds: only the caller's own device is ended (user/device from auth assigns, body ignored; re-check scoped to hash + user + device; Bearer auth so no CSRF route); OAuth take-over leaves the victim's OAuth device intact and the stale credential is denylisted; refresh racing logout in both orders (rotation takes devices FOR UPDATE first: logout first -> 401, rotation first -> teardown deletes the new row); lock order devices -> matrix_sessions everywhere, no cycle with revoke_client/lease/delete_for_user; denylist falls through to the DB cluster-wide, failed write -> 500; ended/unknown both 200 `{}` (no oracle); `/logout/all` and OAuth logout unchanged.

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| L1 | LOW | when the device has no `devices` row `lock_device` locks nothing: a refresh can survive a logout (a legacy login ignores register_device failures, so such rows exist after a transient DB error); window tight | cycle 1: when lock_device matches 0 rows take `SELECT 1 FROM matrix_sessions WHERE user_id AND device_id FOR UPDATE` before the DELETE (or an advisory xact lock in both paths) + test |
| L2 | LOW | `DeviceBinding.lookup/1` caches `{nil,false}` for 60 s on a DB error: a bound JWT then takes the unbound path (JWT denylisted, device/keys remain, log says ended) | cycle 1: do not cache lookup errors / fail closed |
| L3 | LOW | log line built by string interpolation (protected.ex ~392): a device id with spaces can fake key=value fields | cycle 1: static message + Logger metadata |
INFO: no lock_timeout on the new device lock (same-user short txs only; consider SET LOCAL lock_timeout as lock_client!), bound JWT with failed denylist after committed teardown = 500 (accepted cache-TTL class), empty device id only deletes the presented row (unreachable), delete_for_user without devices lock (pre-existing, OidcPlug deactivation check covers), no audit row (matches conventions), denylist keys namespaced.
