# test-review sso-confirm-bucket-order (nebu-test-reviewer, 2026-10-14)
1 MAJOR (the numeric budgets 60 / 600 were only pre-seeded by helpers) + 8 MINOR, all applied: exact 60 / 600 budgets through the plug with Retry-After ranges, ETS snapshot for cookie-less / malformed (boundary lengths, chars, empty),
POST with an unknown cookie (invalid_state whatever body / Origin), consumed + expired = miss, stronger flood test (100 misses, 55 live), GET 429 keeps the cookie, store-unavailable tests, doc ids.
