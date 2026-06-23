# Pre-Dev Test-Review — oidc-refresh-mode-config, 2026-06-23
## Verdict: CLEAN (0 MAJOR)
All AC1-AC7 covered via PUBLIC surfaces (scope param in SSO/admin authorize 302), real DB on
:integration path (real upsert_server_config/1, no mocks), no sleeps/forged cookies. Dex-caveat hint
asserted; no-silent-weakening guard (online → offline_access ABSENT + openid PRESENT, incl. custom-scope case).
## MINOR
- config_live_refresh_mode_test.exs:107 selected-option regex assumes native <select>/<option selected>.
  Dev: render a real <select> with `selected` (or relax). Round-trip persistence independently asserted (line 102). Not blocking.
## INFO / dev guidance
- Reader seams MUST be under :nebu_http: :matrix_oidc_refresh_mode_reader, :admin_oidc_refresh_mode_reader.
- AC4: add both keys to do_complete_bootstrap/2 keys list (auth.ex:1089) with the existing non-empty-binary guard
  (empty/invalid must NOT overwrite default).
- SECURITY (for Kassandra/dev): validate persisted value to enum offline|online on the WRITE path (no scope injection
  via server_config). Add a test for junk-value rejection during dev.
- e2e @pending-feature: fill steps against live IdP before done.
test-review subagent id: a7042fe1e66c958f4
