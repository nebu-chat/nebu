# Security Review: persistent-consent-grants (Kassandra, cycle 0)

Date: 2026-10-30. Scope: staged diff in worktree `open-chat-oauth-session`, branch `bugfix/oauth-session-lifetime-and-consent`. **Verdict: APPROVED (CLEAN: 0 CRITICAL, 0 HIGH).** 1 MEDIUM (advisory, fix in this story), 2 LOW, 1 INFO.

| # | Severity | Location | Finding | Remediation |
|---|----------|----------|---------|-------------|
| 1 | MEDIUM | authorize.ex:395-300 (`{:remembered,...}` built after `device_check`), consent.ex:255 | The skip also runs when `device_check` returns `{:replace, holder}`. The consent page shows "Another session will be signed out" (consent_page.ex:278) for that case, the skip never shows the page. A client the user allowed once can request `device:<id>` of the user's legacy or session-less device (device ids visible to room members via /keys/query); with an active IdP SSO session this signs that session out and takes over the device id with zero clicks. | Skip only when the device state is `:new` or `{:same_client,_}`; for `{:replace,_}` go to the consent screen (pass `device` into `remembered?/3`). Add a test. |
| 2 | LOW | authorize_request.ex:236-244, authorize.ex:231 | Pre-existing, worsened by this story: `prompt=login` is dropped (not forwarded to the IdP, does not force the screen). The consent screen with its stale notice was the only re-auth guard; with a remembered grant a client asking for re-authentication gets a code silently from the SSO session. | Treat `login` in `prompt` like `force_consent`, or forward it to the IdP leg. |
| 3 | LOW | migration 000057:32, authz_store.ex insert | Rolling deploy: a `prompt=consent` request started on an old node (no `force_consent` write, default false) can be skipped on a new node's callback; lasts for the deploy window. | Document in the rollout notes or accept. |
| 4 | INFO | consent_grant_store.ex:99 | "Website" column prefers app-claimed `client_uri` host over stored `client_host`; escaped, but the header does not say it is a claim. | Prefer `c.client_host`, or label as claimed. |

## Answers
1. Freshness (owner decision): the code row carries the same raw `auth_time`, so id_token `auth_time` is truthful and RP max_age checks keep working; Nebu has no server-side max_age; step-up limited by #2. Silent issuance for a client with consent is normal OIDC. **Recommend: keep, do not add `login_fresh`, but fix #2.** Conservative option: gate only `:absent`, not `:stale`.
2. Unauthorized code: one SQL statement joins status='approved' and approved_at = client_approved_at; user_id from the verified provisioned IdP login; exact redirect_uri; `covers?` compares token sets (other Matrix prefix not covered, empty request never covered); device regex anchored; device-holder `:refused` ends the flow, token endpoint re-checks under the device lock; other users and pending/rejected/revoked/re-approved clients cannot get a code. Exception: #1.
3. Revoke race: same window as the Allow path; token.ex:158/314 refuses codes of a client that is no longer approved; revoke deletes grants in its transaction (client_store.ex:901); upsert filtered on approved. Acceptable.
4. prompt: force_consent stored in oauth_authz_requests; case-sensitive; `login consent` forces the screen; prompt=none unchanged. OK apart from #2/#3.
5. Withdraw: CSRF + lenient BrowserPost checks; DELETE keyed on session user_id + client_id (no IDOR, max one row); client_id validated; uniform responses (no enumeration); not fresh-gated and not ending sessions acceptable.
6. XSS/clickjacking: Phoenix.HTML.Engine escaping, no raw; existing send_page headers. Clean.
7. Logging: no code/state/nonce/scope/redirect URI/token logged; only error types/PG codes. Clean.
8. Fail-closed + DoS: read failure -> consent screen; failed upsert never fails Allow; CHECK caps on scope (2048) and redirect; one row per (user, client); LIST LIMIT 500; stale grants neutralised by FK cascade, revoke DELETE and approved_at binding.
9. GDPR/migration: table in the erasure list; FK only to oauth_clients; runbook count and sweep SQL correct; column-level UPDATE + FORCE RLS like 000040/000045.
10. OIDC scopes law untouched.
