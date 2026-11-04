# Code review (cycle 0): persistent-consent-grants

Reviewer: nebu-code-reviewer (read-only, static). 0 CRITICAL, 0 MAJOR, 5 MINOR, 5 INFO. All 9 scenarios and the Decisions implemented as written.

Clean: one-statement skip (consent_grant_store.ex:27-33, 80-86) fail-closed (authorize.ex:472-476 skips only on `{:ok, true}`); skip runs after gate l, provisioning, freshness, device check, refresh-token encrypt; prompt=consent carried via authorize_request.ex:248 and authz_store.ex; Consent still the only CodeStore.insert caller (`issue_remembered/4` reuses `mint/5`); grant upsert after insert (consent.ex:280), failure only logs value-free; revoke deletes grants in its transaction (client_store.ex:901, fail-closed rollback); withdrawal (account.ex:170-200, 800-830) via checked_post, user_id + client_id keyed; migration 000057 consistent with 000045 (FK cascade, CHECKs, REVOKE + column UPDATE, FORCE RLS, symmetric down); UserDeletion order; logs value-free; ADR-018; no node-local state; OIDC scopes law untouched; markup matches sibling pages.

## MINOR
1. consent.ex:7-8 stale moduledoc ("ONLY caller of CodeStore.insert: no code without the user's click", "BEFORE any authorization code exists"): reword "no code without an Allow or a remembered Allow".
2. authorize.ex:~42-46, ~378-380 stale moduledoc/comment ("A successful IdP login does NOT issue a code ... only after the user clicks Allow", "(f) consent row (g) 303 never here"): add the remembered branch and its decision point.
3. Stale docs: client_store.ex:851 revoke step list omits the grants delete; docs/architecture/06-runtime.md:~1904, ~1919 (callback sequence, revoke steps) omit the skip branch and the grants delete; 05-building-blocks.md:2140 still says "consent on every authorization"; 07-deployment.md:679/689/690 gate rows: add "(relaxed by persistent-consent-grants)".
4. account.ex:16-22 moduledoc route list lacks `GET /account/apps` and `POST /account/apps/withdraw`.
5. GET /account/apps without a session (account.ex:~172) calls start_login with return target {nil,nil}; user lands on the profile page. return_target/1 (account.ex:243-248) has no apps case: add one or note as a known limit.

## INFO
1 freshness skip is the owner's deliberate choice (Kassandra reviews; crafted authorize URL with the victim's real client_id no longer meets a consent screen, only the IdP login/redirect/device rules remain); 2 upsert vs revoke race can leave an orphan row, harmless (joins status/approved_at); 3 list LIMIT 500, orphan rows invisible; 4 valid_client_id?/1 duplicates AuthorizeRequest helpers (cosmetic); 5 story `status: ready` and DoD boxes unchecked (set at commit). Doc-drift pattern: "consent on every authorization" prose survives in moduledocs/ADR gate rows/05-building-blocks.

---

# Delta review (cycle 1): persistent-consent-grants

Reviewer: nebu-code-reviewer (read-only, static). No MAJOR, 4 MINOR, 4 INFO. All cycle-1 claims closed and correct: `remembered?/3` false for `force_consent` and `{:replace,_}` (authorize.ex:479-480); `prompt=login` sets force_consent (authorize_request.ex:249, `none login` stays invalid_request); rollout note in 07-deployment + CHANGELOG; Website column from `client_host`; migration 000057 CHECK widening exact name + five values + 'apps' (idempotent, down deletes 'apps' rows, no new grants); old node reading `return_action='apps'` falls through to `/account` (no crash); `return_location` constant path, no open redirect; logging value-free; revoke deletes grants in the same transaction.

## MINOR
1. docs/architecture/08-concepts.md:740 still says "consent on every authorization compensates at login" (annotate/reword).
2. docs/stories/oauth-broker/follow-ups.md:316 row `av` ("Optional remembered consent ... only on an explicit product decision") still open: close it / point at persistent-consent-grants.
3. server/priv/migrations/000057_oauth_consent_grants.up.sql:1-14 header omits the CHECK widening, the `login` value and the old-node fallback to `/account`.
4. authorize.ex:401 comment says "(and no `prompt=consent`)": add `prompt=login` and the `{:replace,_}` condition; the `@doc` of `AuthorizeRequest.validate/2` (authorize_request.ex:126-127) omits the `force_consent:` key.

## INFO
5. apps.html.eex:15 Website cell `g.client_host || "Unknown"` vs `grant_host/1` fallback "unknown website" (and empty string): use one helper for both. 6. `prompt=login` only forces the consent screen, it is not forwarded to the IdP (SSO session still reused silently); 07-deployment wording is accurate but does not say the IdP login itself is not forced. 7. column name `force_consent` is historic now (noted in 07-deployment). 8. No dead code.
