# test-review admin-config-privileged-forms-sweep (nebu-test-reviewer, 2026-10-14; run after dev c0, tests were green)
0 MAJOR, 7 MINOR, 9 INFO. All MINOR applied: M1 behaviour test for the bootstrap routes + static check of login_controller; M2 notice page assertions (back link, nav, marker kept);
M3 callback / notice behaviour tests in admin_reauth_test.exs (both mapping pages); M4 exact statuses (200 + "Could not save", no write on validation error); M5 reverse binding
(a mapping marker does not unlock sso-origins / sso-schemes / oauth-switch), scopes / refresh neither need nor spend a marker; M6 Safari proof without marker = sign-in redirect;
M7 e2e step asserts reauthenticated === true. INFO: legacy playwright specs (role-mapping.spec.ts) are dead projects, not adapted.
