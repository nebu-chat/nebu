# Test-Review (pre-dev) — fix-device-key-registration

CLEAN (0 MAJOR). Every AC has ≥1 test:
- AC1 (upload stateful + counts): round-trip + otk-accumulation
- AC2 (query echoes / unknown-user omitted): round-trip + unknown-user
- AC3 (whoami device_id): opaque-session integration test
- AC4 (/sync OTK count): sync integration test (best-effort single-device resolution)
- AC5 (GET /devices): list test
- AC6 (E2EE guardrail): 2 unit tests (no state_key + trailing-slash), no DB
- AC7 (durability): DeviceKeyStore put/query direct test

Quality notes:
- Layering correct: guardrail is DB-less unit (rejects before Core); stateful paths are :integration.
- Empty-input short-circuit lets existing matrix_client_compat_test.exs unit tests stay green
  (they POST empty bodies → no DB).
- No hard waits, no cookie forging. Durability test calls the store API directly — legitimate for
  a store-level contract test, not an E2E shortcut.
- Deterministic: unique_integer suffixes avoid cross-test collisions.
