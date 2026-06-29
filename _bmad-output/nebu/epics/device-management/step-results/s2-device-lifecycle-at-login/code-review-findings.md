# Code Review — S2

## Cycle 1 — CLEAN (verification)
MINOR-C RESOLVED (DeviceBinding.put/3 now best-effort via safe_query, no raise; happy path + cache prime unchanged; query still referenced; hash-keyed binding intact). MINOR-B RESOLVED doc-only (stale moduledoc rewritten to historical note; zero test assertions changed). MINOR-A + INFO unchanged. No new findings. Clear to proceed.

---

# Code Review — S2 (cycle 0)

Verdict: **MINOR-only**. No CRITICAL/MAJOR. All 7 ACs + security goals G1/G2/G3 implemented correctly and tested. Token stored only as SHA-256 hash (no raw token at rest); all new SQL parameterized; the device a request acts as comes solely from the server-side token binding.

## Per-AC: all ✅ (covered + correctly implemented)
AC1 register_device/4 (display_name first-sight only, created_at on insert, last_seen refreshed). AC2 client_device_id honored, reuse passes display_name:nil → COALESCE keeps original, PK prevents dup. AC3 opaque→sess.device_id, JWT→DeviceBinding.get_device. AC4 sole_device_id removed, attribution via assigns. AC5 touch_last_seen/3 DB-side throttle (60s WHERE clause), best-effort. AC6/G1 up-front 403 on body!=bound before any write. AC7/G2/G3 refresh rotates opaque via rotate_tokens (preserves device_id), never touches jwt_device_bindings.

## Findings to fix this cycle

### MINOR-B — stale RED-phase moduledoc in test file
server/test/nebu/matrix/device_lifecycle_login_test.exs:10-37. "Why these MUST FAIL against the current code" block describes pre-S2 behavior and stale line refs (router/protected.ex:1140/:185). Post-GREEN it misleads. Fix: trim/update to note it describes the pre-implementation state.

### MINOR-C — DeviceBinding.put/3 raises on DB error in the login path
server/lib/nebu/matrix/session/device_binding.ex:35 uses `{:ok, _} = query(...)` (hard match → raises). Login caller wraps `_ = DeviceBinding.put(...)` (http_public.ex:386) and lazy-bind (protected.ex:346) also wrapped `_ =` but still raises. An unavailable jwt_device_bindings table would 500 the login instead of degrading to "no bound device". Fix: make put/3 best-effort (use safe_query / rescue) consistent with get_device.

## Accept-as-designed
MINOR-A — lazy JWT first-upload binding: secure across users (persistence keyed on verified token user, not body). Intra-user first-upload can name any own device — spec-permitted. Optional: add a comment / lock-in test. No code change required.

## INFO (no action)
- Body device_keys.user_id not rejected on mismatch but cannot cross users (persisted under trusted user). Pre-existing.
- ETS cache is a cache (60s TTL) over Postgres source of truth — cluster-correct.
- SQLi/IDOR/timing: clean. Token only SHA-256 hex at rest.

## Test-review fold-in (Gate-3)
Every AC has ≥1 test (AC5 throttle test closes prior MAJOR-1). No hard waits. G1 asserts rejection status AND DEV_B keys byte-unchanged. MINOR-2 confirmed: device mismatch checked before signature/key handling. MINOR-1 (vacuous Repo-guard else) left as pre-existing convention.
