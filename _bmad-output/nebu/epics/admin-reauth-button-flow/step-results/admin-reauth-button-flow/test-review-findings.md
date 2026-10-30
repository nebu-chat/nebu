# Test review (pre-dev): admin-reauth-button-flow

Reviewer: nebu-test-reviewer (read-only). Verdict: **no MAJOR findings**, 12 MINOR, a few INFO. Crash/restart and Matrix error codes N/A (marker lives in the session cookie, no GenServer state).
Paths relative to `server/test/nebu/admin/` unless noted.

## Coverage per scenario (all 9 forms)
1 stale link, 2 fresh button + validity line, 3 link returns after save, 4 expiry while page open, 5 other marker does not unlock: all covered in config / mappings / media / confirm files plus the 4x11 matrix (cross_page). Consumption goes through the real session cookie (mutant M17 kills a missing consumption). Scenario 4 pins the exact redirect and asserts nothing written/audited. Plain submits (scopes, refresh mode, Test Connection) covered in every state.

## MINOR findings
- **m-A no replay / no prefill:** after the refused POST no test checks that session/flash/next GET holds no canary (config:261, mappings:134/251, media:258, confirm:151/273).
- **m-B keyboard reachability:** `assert_stale!` (support:200-235) does not refute `tabindex="-1"`, `aria-disabled`, `hidden`; also nothing refutes `hidden`/`sr-only` on the validity line (INFO).
- **M5 media:223:** `assert post.resp_body =~ "7"` is near-vacuous (orphan-risk render path); assert the orphan warning text/selector. No mutant for "orphan render path missing assign".
- **M6 over-pinned wording:** support:279-282 requires `\bfirst\b`; `admin_media_settings_gate_test` pins `~r/sign in again first/i`; four amended tests pin the prefix `Your fresh sign-in is valid for` (config_sso_trust_hardening AC4, config_privileged_forms_sweep, config_oauth_switch AC1, media gate). Helper needs only `\bvalid\b`. Relax to key phrases.
- **M7 accessor coupling:** `reauth_remaining_minutes/2` pinned by name/shape (16 tests); story says only "if needed, a read-only accessor". Add the name to the story contract.
- **M8 support:326 `assert_plain_submit!`** refutes `fresh sign-in|valid for` on the whole form text; scope to hint ids.
- **M9 isolation:** new setups call `Application.delete_env(:nebu_http, :admin_csrf_bypass)` on exit (config:60, mappings:49, media:71, cross_page:36, confirm:35); `config/test.exs:64` sets it globally. Use `T.put_env_scoped(:admin_csrf_bypass, true)`.
- **M10 oauth_admin_clients_test (revoke notice):** "again" pin dropped (`~r/type the host and the reason/`); stale confirm-page hint wording not pinned (`assert_stale_hint!` only refutes the old phrases), "again" is misleading now. Pin new wording (refute `/again/` after "type") or record as Decision.
- **M11 e2e fallback masks a missing link:** helpers `submitWithAdminReauth`, `saveConfigFormWithAdminReauth`, `saveMappingFormWithAdminReauth` (e2e/fixtures/oauth-admin.ts) and `saveWithAdminReauth` (oauth-switch.steps.ts) use `if (link.count() > 0)` else old route; `outcome.reauthenticated` true on both paths (claim-mapping.steps.ts:101, role-mapping.steps.ts:31, media-settings-gate.steps.ts:31, oauth-client-revocation.steps.ts:275); keyboard revoke scenario skips Tab block without link. Fix: `viaLink: boolean` in the outcome and assert it, or make the link mandatory when no marker is known.
- **M12 e2e Gherkin thin:** only `@reauth-button` (one form) covers AC1/AC2; AC3 link returns, AC4, AC5 have no scenario. Add at least approve or revoke link + validity line, and a "link comes back after a save" scenario.
- **M13 sso-redirect-origins.steps.ts (~101):** hint check `/sign[ -]?in/i` matches nearly any hint; tighten (e.g. `/sign in again first|valid for/`).
- **M14 log canaries:** claim mapping canary only on `oidc_user_id_claim` (mappings:137); add canaries for `oidc_displayname_claim`, `oidc_email_claim` or a direct filter test.

## INFO
- 290 s "less than a minute" checks (config:160/286, media:285) have a 10 s margin; use 270.
- admin_reauth_test.exs notice loop passes trivially for approve/revoke (no flash there).
- confirm_test is `@moduletag :integration` (DB lane only), same as existing approve/revoke tests.
- Role mapping: marker without fingerprint renders fresh but the save is refused again (mappings:206): pinned together with the inline link; UX oddity for the dev.

## Open points of the ATDD report
1. **Form values in the DEBUG log (Phoenix `filter_parameters`, `server/config/config.exs:30`)**: becomes a story Decision/AC (story says "presentation only", now false; security_review required). Add a direct, cheap test over every field name of the 9 forms (so a failing run says "filter_parameters"), decide deny-list vs `{:keep, [...]}`, keep existing keys (revoke AC11).
2. **Enter key in the stale state**: story Decision + UX note, no new test (browser behaviour; server contract covered). Optional e2e check on the storage form.
3. Other points (reauth-state id, `@reauth_link` unification, 9 render sites, notice wording, docs): dev notes. Docs: `nebu/oauth/admin_*_docs_test.exs` check "fresh sign-in" and "Save OAuth settings" in the docs, `07-deployment.md` update must keep them.
