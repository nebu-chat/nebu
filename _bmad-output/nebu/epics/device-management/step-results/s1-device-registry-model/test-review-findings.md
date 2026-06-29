# Test Quality Review — S1 Device registry model (RED phase)

Gate: PASS (RED), 0 MAJOR. 4 MINOR to fix before green.

## AC coverage: all ACs have >=1 test (AC5 delegated to existing device_keys_test.exs).

## MINOR findings (fix during dev-story):
- MINOR-1: Backfill test (T3, device_store_test.exs:269) seeds a device_keys row and checks devices-sourced surfaces, but does NOT exercise the actual 000010 backfill INSERT...SELECT (migrations run once at boot). Add a migration-level :integration assertion: every device_keys (user_id, device_id) has a matching devices row (no orphan). This puts the backfill SQL itself under test.
- MINOR-2: AC4 says GET /devices AND GET /devices/{id} share the shape. New suite tests GET /devices for keyless, but never calls GET /devices/{deviceId} over HTTP for a keyless device (only get_device/2 at store layer). Add one GET /devices/{deviceId} call for the keyless device asserting 200 + shape parity.
- MINOR-3: AC1 calls out idempotency but no test calls upsert_device/3 twice. Add "calling upsert_device/3 twice updates display_name, no duplicate row".
- MINOR-4 (IMPORTANT — CI gate): otk/1 helper copied into device_store_test.exs is UNUSED → unused-private-function compiler warning → warnings-as-errors CI gate aborts after "N passed". DELETE otk/1.

## INFO:
- AC5 regression delegated to device_keys_test.exs (correct — no duplication). Implementer MUST run both suites; device_keys_test.exs must stay green after the store refactor.
- DB-less skip pattern (assert true under Process.whereis(Nebu.Repo)) is the codebase convention; these tests only signal under make test-integration.
- Determinism/isolation good (unique_integer IDs, async: false, no hard waits).
