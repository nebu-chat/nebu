# Code review cycle 0 — oauth-metadata-dcr-admin-approval
No CRITICAL. ACs + Oracle MUSTs covered; no missing error codes / wrong HTTP statuses.

## MAJOR (user decision pending — do NOT implement in the fix cycle)
1. Unbounded pending rows + silently truncating approval list: client_store.ex:38-44 `ORDER BY created_at DESC LIMIT 500`, no pagination/count; register is unauthenticated, throttles node-local ETS 50/h per IP + 500/h global (http.ex:58-60); no cap/TTL/purge; ~60 KB/row. Attacker can fill the newest-500 window so older legit pending clients vanish from the UI. Options: pending cap or TTL purge, pagination + total count, per-client_uri-host dedup/limits, "N more pending" indicator. (Pending rows have no sessions, so purge does not violate Matrix "MUST NOT delete".)
11/A1. CSP img-src https: on /admin/oauth/registrations (admin IP/UA leak + blind GET probe) — security decision; at minimum document in ADR-033.

## MINOR (fix now)
2. NUL/control chars in client_name -> Postgres jsonb error -> 503 + error log (registration.ex:161-167 optional_string only checks size; client_store.ex:155-159 rescues only RuntimeError/ConnectionError; http.ex:190-193). Reject control (incl. bidi, zero-width) chars in client_name (covers UX A8); map Postgrex data errors to 400.
3. Non-ASCII hosts accepted verbatim (registration.ex:285-303); Unicode lookalikes for / . @ (e.g. https://evil.com／.example.com) can pass host_under? string suffix. Require ASCII LDH host (reject non-ASCII or punycode), reject bidi/zero-width; add tests.
4. Router-level 1 MB JSON parse (plugs/json_body.ex) runs before the rate limiter on /oauth2/register; Jason no depth limit; oversize -> plain-text 413 instead of OAuth error shape. Add a lower body cap for this path, return {"error":"invalid_request"} (like account-data paths); fix doc claim in http.ex:30.
5. DB failure in admin list renders empty state (client_store.ex:124-127). Surface error flash.
6. Audit write result ignored (oauth_registrations_controller.ex:92,124): log error + tell admin when audit write fails.
7. Stale "RED-phase ATDD" moduledocs at line 3 of all new test files (adr_033_test, oauth_client_store_test, oauth_admin_test, oauth_config_test, oauth_dcr_validation_test, oauth_metadata_test, oauth_dcr_integration_test, oauth_dcr_rate_limit_cors_test, oauth_payload_redaction_test, 000040_oauth_clients_test) + "does not exist yet" prose at oauth_client_store_test.exs:24, oauth_config_test.exs:32,65. Reword.
8. Test gaps: IDN/punycode/unicode-lookalike hosts, \u0000/control/bidi in client_name, oversized body / deep nesting -> OAuth error shape.
9. Add CHECK (status IN ('pending','approved','rejected')) and CHECK (application_type IN ('web','native')) to migration 000040 up.
10. Nebu.OAuth.Config at lib/nebu/config/oauth_config.ex -> belongs in lib/nebu/oauth/config.ex (ADR-020 style). Move (keep module name Nebu.OAuth.Config) or document why not.
INFO (no action unless trivial): 201 lacks Cache-Control: no-store (add, trivial); RateLimit remote_ip behind proxy (follow-up); metadata advertises /oauth2/authorize|token|revoke which 404 until stories 2-4 (gate rollout: oauth_enabled must stay off until then); Config.get one DB read per metadata request; created_from_ip/user_agent retention (GDPR follow-up); redundant metadata_hash index (required by static test); no revoke UI for approved clients; no public-suffix check.
