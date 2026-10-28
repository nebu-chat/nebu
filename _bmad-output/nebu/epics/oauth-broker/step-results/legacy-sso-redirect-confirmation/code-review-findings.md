# Code review cycle 0: legacy-sso-redirect-confirmation (nebu-code-reviewer, 2026-10-13)

No MAJOR / CRITICAL. 7 MINOR, 8 INFO. Classification verified by reading code and probing `SsoRedirect.classify/1` / `normalize_origin_list/1` with about 45 adversarial rows.

MINOR
- MIN-1 `client_store.ex:472` approved-client SQL was bent to a test fixture (`lower(c.metadata::text) LIKE ... LIMIT 50`); restore a `jsonb_array_elements_text` query on `redirect_uris` (tolerate string-typed jsonb with a CASE or fix the fixture) and update D6 prose.
- MIN-2 `sso_confirm.ex:195-209` Origin check compares against the request Host; the reference nginx sets `Host $host` (no port): accept a single Origin when it equals the Host-derived origin OR `https://<server_name>` OR `Sec-Fetch-Site: same-origin` is present; document "forward the original Host".
- MIN-3 host regex duplicated in four places (`sso_redirect.ex`, `sso_confirm_page.ex`, `oauth.ex`, `consent_page.ex`): expose `SsoRedirect.valid_https_host?/1` and make `SsoConfirmPage.valid_target/1` use it.
- MIN-4 stale "RED-phase" prose in 14 test files and 2 e2e step files: reword to "ATDD tests for story ...".
- MIN-5 story file: status ready, tasks unchecked, conflicts section outdated, D6 SQL prose.
- MIN-6 dead `_other` branch in `SsoConfirm.handle/1`.
- MIN-7 e2e shared step "the page shows a success flash message" selector too broad (`[role="status"].alert-success`).
INFO: no audit trail for allowlist changes (INFO-1, see Kassandra #5); admin save failure flash unreachable on DB error (pre-existing); moved seam `:sso_redirect_schemes_reader` not compile-guarded; arming UX gap when pointer already rests on Continue; confirm store keeps id_token/IdP RT 300 s in memory on every node (same precedent as the loginToken store); rolling-deploy window (an old node mints the loginToken directly, `GET /sso/confirm` 404 on an old node: release note); `format_status/1` redacts `:reason` only for `{:bad_cast, _}`.
Verified without finding: classification table, callback never mints for an unlisted target, pop before mint, POST check order, cookie/CSRF, headers (no COOP), escaping, approved-client lookup bounds, SsoStore, routing, admin validation + cache refresh, migration 000048 (000042 list + 2 keys, down = 000042), ADR-020 boundaries, no new env variable, seams compile-guarded.
