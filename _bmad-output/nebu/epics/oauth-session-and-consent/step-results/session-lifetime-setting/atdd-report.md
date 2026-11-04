# ATDD report - session-lifetime-setting (epic oauth-session-and-consent)

State left in the worktree: RED tests only (lib, migrations, config, docs reverted to the committed state; the working tree is dirty, nothing committed).
Proof of meaning: `reference-impl.diff` (throwaway implementation incl. migration 000056, docs, config/filter_parameters; NOT applied) turns all tests green;
`mutation-results.txt`: 65 mutants, 65 killed.

## Numbers

| run | red (no reference) | green (with reference) |
|---|---|---|
| 9 NEW test files, `--include integration` (fresh DB) | 98 failed / 119 (21 pass: regression guards of unchanged baseline behaviour) | 119 passed |
| 3 MODIFIED existing files (reauth config, cross page, click proof) | 38 failed / 102 | 102 passed (5 skipped as before) |
| `.session-ci/unit_nodb.sh` (full no-DB suite, warnings as errors, Elixir 1.20) | 103 failed / 6973, all in story files, no compile abort, no warnings | 6973 passed, exit 0 |
| full `--include integration` suite with reference (first pass) | - | 25-28 failures in unrelated files (rooms fallback, temporary capture, log retention, admin oidc login, sso/oidc plug, war room ...): the IDENTICAL families fail on the baseline (25 of 25 re-checked without my changes): pre-existing/environmental in the throwaway DB |

## Files

New (server/test):
- `admin/config_session_lifetime_test.exs` (no DB): page contract, stale/fresh marker states, gate, validation errors, save + audit, no-change, audit failure, hygiene.
- `admin/config_session_lifetime_db_test.exs` (integration): real DB, RLS (second save UPDATEs), real audit row, rollback on failing audit, refused values.
- `admin/session_lifetime_validation_test.exs` (pure): `OAuthSwitch.validate_session_lifetime/1`, `OAuthSwitch.lifetime_text/1` (called through `apply/3` so the red state compiles under `--warnings-as-errors`).
- `web/session_config_lifetime_test.exs` (no DB): order of sources saved > env > 8h, damaged values ignored, legacy `HttpPublic.session_expires_at/1`.
- `oauth/session_lifetime_login_test.exs` (integration): real OAuth flow, `matrix_sessions.session_expires_at`, scenarios 1, 2, 4, refresh keeps the ceiling.
- `oauth/session_lifetime_cache_test.exs` (integration): one query per TTL window, invalidation on the saving node, TTL expiry on other nodes, unreadable repo, damaged row warning.
- `migration/000056_config_session_lifetime_mutable_test.exs`: static policy analysis + runtime-role behaviour (copy of the 000049 test).
- `oauth/session_lifetime_docs_test.exs` (static): 07-deployment section + table row, CHANGELOG [Unreleased].
- `oauth/session_lifetime_oauth_test_support.exs`: helpers (name ends in `oauth_test_support.exs`, so mix.exs `test_ignore_filters` needs NO change); required from `test/test_helper.exs`.
New (e2e): `features/admin/session-lifetime.feature` (3 scenarios, tag `@session-lifetime`), `step-definitions/admin/session-lifetime.steps.ts`. Statically checked in a scratch copy: `bddgen --tags @session-lifetime` exit 0, `tsc --noEmit` clean (needs the compose stack with Dex to run).
Modified existing tests (extension, nothing weakened): `reauth_button_flow_oauth_test_support.exs` (+ form `:session_lifetime` in `forms/0`), `admin_reauth_button_flow_config_test.exs` and `_cross_page_test.exs` (hard-coded "3 forms/links" -> 4 / `length(@config_forms)`), `click_proof_script_test.exs` (config template: 5 -> 6 `_click_proof` fields), `test_helper.exs` (+ require of the new support file).

## Scenario -> test mapping

1. No saved value -> 8h: `session_lifetime_login_test` "scenario 1" (real session row), `session_config_lifetime_test` "scenario 1" (+ env fallback, no seam).
2. Saved 2h applies to next login: `session_lifetime_login_test` "scenario 2" (saved through the real form; 24h; bounds; saved beats env; damaged row; legacy accessor), `session_config_lifetime_test` "scenario 2", `config_session_lifetime_test` "scenarios 2 and 6", `config_session_lifetime_db_test`.
3. Out-of-range refused, nothing saved: `session_lifetime_validation_test`, `config_session_lifetime_test` "scenario 3" (error `p#session-lifetime-error[role=alert]` inside the section, `aria-invalid`, `aria-describedby`, value echoed + escaped, 200, nothing written/audited, marker kept), `config_session_lifetime_db_test` (row unchanged), e2e scenario 3.
4. Existing sessions keep their ceiling: `session_lifetime_login_test` "scenario 4" (DB row compared before/after save, after refreshes, new login gets the new ceiling).
5. Stale marker -> "Sign in again to save": `config_session_lifetime_test` "scenario 5" (page states; POST without/with expired/other-page/other-admin marker redirects to the sign-in, nothing written; 403 without strict fetch metadata), the generalised reauth suites (new form in `forms/0`), e2e scenario 1.
6. Audit: `config_session_lifetime_test` (action `session_lifetime_changed`, target `server_config`/`matrix_session_ttl_seconds`, metadata exactly `%{"before_seconds"=>n,"after_seconds"=>n}` integers only, same transaction, fail-closed), `config_session_lifetime_db_test` (real `audit_log` row), known-action check against the real writer.
Design points: hot path/cache/propagation `session_lifetime_cache_test`; damaged/unreadable fallback + warning without raw value `session_config_lifetime_test`, `session_lifetime_cache_test`; docs `session_lifetime_docs_test`; migration `000056_..._test`; log hygiene (field masked by Phoenix `filter_parameters`, canary values) in `config_session_lifetime_test`.

## Design decisions (pinned by the tests; dev may deviate only with a story Decisions note)

1. SEPARATE form/section/route, not a field in `oauth-switch-form`: `section#session-lifetime`, `form#session-lifetime-form`, `POST /admin/config/session-lifetime` -> `ConfigController.save_session_lifetime/2`, marker gate `:marker` bound to `/admin/config`, button "Save session lifetime" (story says "Save"; kept specific like "Save OAuth settings"). Reason: `SwitchStore`/`OAuthSwitch.validate` pin exactly two keys, an issuer acknowledgement and an OFF-kill-switch audit asymmetry that must not apply to a setting that also governs the legacy login. Story scenario 3 "saves the OAuth settings form" is read as "this form". Validation functions live in `Nebu.Admin.OAuthSwitch` (`validate_session_lifetime/1`, `lifetime_text/1`).
2. Input = whole seconds text field `matrix_session_ttl_seconds` (label "Session lifetime in seconds"), plain decimal digits, surrounding white space trimmed, 3600..7_776_000; `#session-lifetime-current` shows human text ("8 hours", "1 day 1 hour", "90 days"; not whole minutes -> seconds); `#session-lifetime-help` names bounds, "existing sessions keep", the env var.
3. Reuse of `server_config` machinery: write through `Nebu.Admin.DB.save_config_audited/2` (test seam `:admin_config_tx`), NEW migration 000056 (allowlist = 000049 + key; needed, RLS), new audit action in `AuditWriter @known_actions`, invalidate the node cache in `after_config_write`.
4. Read side: through `Nebu.OAuth.Config` (key added to the one `@sql`, per-node TTL cache, same seams). Test seam: `:oauth_config_source` map key `:matrix_session_ttl_seconds`. NOTE: that seam replaces the whole read, so integration tests must use real `oauth_*` rows (as `session_lifetime_login_test` does), not `T.enable_oauth/0`, when a saved lifetime must be seen. `SessionConfig.matrix_session_ttl_seconds/0` = saved (valid) > env > 8h; damaged/out-of-range/unreadable saved value ignored (never clamped), ONE warning naming the key, never the value. "Nothing saved" is a cached read too.
5. Audit is ALWAYS required (no way-back exemption, no retry without audit): a failing audit saves nothing. `before_seconds` = value in effect (saved, else env, else 8h). Same value as in effect = "No change" flash, no tx, no audit, marker kept.
6. Refused value keeps the marker and re-renders (200) with the Save button; marker consumed only after a successful write. Flash starts "Session lifetime saved" (the e2e step looks for it).
7. `config :phoenix, filter_parameters` must mask `matrix_session_ttl_seconds` (convention of every marker form, tested).

## Open questions / notes for the dev and reviewers

- Legacy sessions: `matrix_session_store` (`resolve_refresh_token` reuse window, `extend_in_place` cap `created_at + ttl`) and `RefreshWorker.candidates` also read the accessor, so a LOWERED setting shortens the reuse/extension bound of existing legacy rows (their `expires_at` is never shortened: `GREATEST(...)`). Not covered by the story's scenarios (OAuth `session_expires_at` is what is pinned); tell the owner if the legacy rows must be frozen too.
- The legacy login cannot be tested end to end for a lifetime > 1h because the stubbed IdP token expires in 1h (`min(exp, ceiling)`); covered at `HttpPublic.session_expires_at/1`.
- Cross-node propagation is proven by the TTL-expiry test (single VM), not with two nodes.
- The 07-deployment text of "Enter key in the Sign in again state (accepted trade-off)" lists the single-text-field marker forms: the new form is another one (not pinned by a test).
- Full integration suite on the throwaway DB has 25-28 pre-existing, unrelated failures (see numbers) - identical without the story.

## Commands

```
# no-DB (red: 96 failures; green after dev: exit 0)
.session-ci/unit_nodb.sh
.session-ci/nodb_one.sh "test/nebu/web/session_config_lifetime_test.exs test/nebu/admin/session_lifetime_validation_test.exs test/nebu/admin/config_session_lifetime_test.exs test/nebu/oauth/session_lifetime_docs_test.exs test/nebu/migration/000056_config_session_lifetime_mutable_test.exs test/nebu/admin/admin_reauth_button_flow_config_test.exs test/nebu/admin/admin_reauth_button_flow_cross_page_test.exs test/nebu/oauth/click_proof_script_test.exs"
# with DB (the container nebu-osess-pg was removed: the next call creates and migrates it; after adding migration 000056 run `.session-ci/quick.sh --migrate`)
.session-ci/quick.sh "mix test test/nebu/admin/config_session_lifetime_test.exs test/nebu/admin/config_session_lifetime_db_test.exs test/nebu/migration/000056_config_session_lifetime_mutable_test.exs test/nebu/oauth/session_lifetime_login_test.exs test/nebu/oauth/session_lifetime_cache_test.exs test/nebu/web/session_config_lifetime_test.exs test/nebu/admin/session_lifetime_validation_test.exs test/nebu/oauth/session_lifetime_docs_test.exs test/nebu/admin/admin_reauth_button_flow_config_test.exs test/nebu/admin/admin_reauth_button_flow_cross_page_test.exs test/nebu/oauth/click_proof_script_test.exs --include integration 2>&1 | tail -40"
```

## Fix pass after the test review (test-review-findings.md): M1, M2, M3, m1-m8

- M1 `config_session_lifetime_test.exs` describe "access and order of checks": gate BEFORE validation (invalid value -> 403 / redirect, never the 200 re-render), neutral 403 page, `require_admin` first (anon, non-admin, admin false), CSRF still enforced (bypass removed), other methods not routed. Mutants N01, N02, N08.
- M2 e2e: Before hook remembers the `server_config` row of the key (or its absence), After hook restores it BY SQL (`restoreServerConfigRow` in `e2e/fixtures/db.ts`) and asserts it is back; no cleanup save through the UI any more; the feature carries no `@short-ttl` tag, so it never runs in `make test-e2e-refresh` (that run selects `@short-ttl` only; the default run excludes it); scenario state reset in the Before hook.
- M3 (owner decision: accept + document): docs section "Matrix session lifetime" now scopes the absolute guarantee to OAuth sessions and says legacy sessions follow the CURRENT setting (extension / reuse bound `created_at + current lifetime`, lowered and raised, `expires_at` never shortened) - pinned by `session_lifetime_docs_test.exs`; hint text on the page says so (pinned); NEW characterisation test `oauth/session_lifetime_legacy_follow_test.exs` (real DB, `MatrixSessionStore.extend_in_place/3`: lowered caps, raised extends, lowered later never shortens, default baseline). Mutant N07, N09, N10. Story Decisions note added (see below).
- m1 story `## Decisions` addendum (5 bullets: separate form + route + button text, storage/audit/migration/read path, "no change" = saved value, legacy follow, unreadable config) - added to docs/stories/oauth-session-and-consent/session-lifetime-setting.md.
- m2 human-text pins relaxed (mixed values: `=~` per unit, page row "30 minutes"); behaviour cases kept.
- m3 "no change" compares with the SAVED value only (reference: `{:ok, ^saved}`); tests: nothing saved + 28800 saves and audits (unit + real DB), damaged saved value counts as nothing saved, env 30 on the page (prefill "30", text "30 seconds", POST "30" refused, 28800 saved with `before_seconds` 30). Mutants N03, N11.
- m4 `session_lifetime_cache_test.exs`: cache owner stopped -> saved 3600 still served, table not created by the caller. Mutant N04.
- m5 recorded as Decision (story bullet + docs "Unreadable configuration", docs test).
- m6 e2e retagged with the story numbering (`@scenario-2 @scenario-6`, `@scenario-3`, `@scenario-5`), audit assertion added (metadata `before_seconds` = remembered number, `after_seconds` 7200, numbers only), DB assertions for "stored row is 7200" / "unchanged after a refused value"; state reset in Before. `bddgen --tags @session-lifetime` exit 0, `tsc --noEmit` clean (scratch copy).
- m7 isolation: `L.real_seams!/0` saves and restores `:admin_config_tx`, `:admin_server_config_reader` and `:compliance, :audit_writer`; `T.put_env_scoped(:audit_writer, FailingAudit, :compliance)`; `L.put_env_ttl!/1` replaces bare `Application.put_env` of the env value; unique canaries (`7313`). The support file mentions `async: false` because `audit_writer_seam_race_regression_test.exs` scans every file that injects the audit writer key.
- m8 `session_config_lifetime_test.exs`: saved Matrix lifetime does not change `admin_session_ttl_seconds/0`; static check that `lib/nebu/admin/auth.ex` does not read the key. Mutants N05, N06.

Reference changes in this pass (reference-impl.diff regenerated): `{:ok, ^saved}` in the controller, hint text in the template, docs / CHANGELOG sentences. No other lib change.
Open question for the orchestrator: none new; the legacy-follow behaviour is now a documented, tested decision.

## Cycle 1 (security / code / UX review findings): red tests against the staged dev state

lib, docs, CHANGELOG and config are exactly the staged dev state (the reference was applied and reverted with `git checkout`; `reference-impl-cycle1.diff` is the throwaway reference, 11 files incl. the new `lib/nebu/oauth/last_good.ex`). Only tests / test support / e2e were added or changed.

| file | red against the staged lib | green with the reference |
|---|---|---|
| `oauth/session_lifetime_last_good_test.exs` (NEW, integration) | 11 of 16 fail | 16 pass |
| `oauth/session_lifetime_warning_rate_test.exs` (NEW, no DB) | 3 of 4 | 4 |
| `admin/config_session_lifetime_concurrency_test.exs` (NEW, integration) | 2 of 2 | 2 |
| `admin/session_lifetime_parser_test.exs` (NEW; 7 no-DB + 1 integration) | 8 of 8 (7 no-DB) | 8 |
| `admin/config_session_lifetime_test.exs` (changed, 49 tests) | 7 fail (help block, common values, bounds from the assign, note, autofocus, describedby order, success flash) | 49 |
| `oauth/session_lifetime_docs_test.exs` (changed, 7 tests) | 5 fail | 7 |
| `oauth/session_lifetime_cache_test.exs`, `_login_`, `_legacy_follow_`, `config_session_lifetime_db_test.exs`, `session_lifetime_validation_test.exs`, `web/session_config_lifetime_test.exs` | unchanged / green (cache test: damaged-warning loop now resets the rate-limit bucket per value) | green |
| `unit_nodb.sh` (warnings as errors) | 22 failed of 6993 (ConfigSessionLifetime 7, Parser 7, Docs 5, WarningRate 3), no warning | exit 0, 6993 passed |
| `quick.sh` over test/nebu/{admin,oauth,web,matrix/session} + migration test, with reference | - | 5434 of 5458; the 24 failures are the known pre-existing unrelated families (rooms fallback, temporary capture, log retention, trace map, admin oidc login, war room, oidc plug) |

Mutants: 95 killed, 1 equivalent (C11, justified in mutation-results.txt), 0 survivors.

Contracts the dev must satisfy (pinned by the tests; names are the only interface decisions made here):
- `Nebu.OAuth.Config.reset_last_good_for_test/0` (test builds only) and the node-global last-known-good state (A). `SessionLifetime.TestSupport.clear_env_ttl!/0` calls it in setup AND on exit; tolerant of its absence.
- `Nebu.OAuth.parse_matrix_session_ttl/1` (`{:ok, seconds} | :error`) in `Nebu.OAuth.Config`, delegated by the `Nebu.OAuth` facade, used by the form (`validate_session_lifetime/1`), the DB reader AND the seam reader (D).
- `#session-lifetime-note` (paragraph with the UX M5 wording + the legacy / identity provider caveat) OUTSIDE `#session-lifetime-help`; help = range (from the bounds assign) + units + env fallback + "Common values", class `break-words`; input `autofocus` only on error; `aria-describedby` = `session-lifetime-error session-lifetime-help` on error, `session-lifetime-help` otherwise (E).
- Rate limit of the damaged-value warning through `Nebu.Web.Plugs.RateLimit.take/3` (1 per minute per node, test clock seam `:rate_limit_clock_fn`) (B).
- Static guard `oauth_versions_static_test.exs` ("Must #19") forbids `:persistent_term` / `Process.put` in `oauth/config.ex`, `oauth.ex`, `matrix/http_public.ex`: the last-known-good state must live in another module (reference: `Nebu.OAuth.LastGood`, `:persistent_term`) or in the ETS owner.
- Docs (F): 07-deployment "Matrix session lifetime" (last-known-good, "no good value ever loaded", in-flight refill race, `NEBU_OAUTH_CONFIG_CACHE_MS=0` query per login/call, legacy login capped by the IdP token `exp`), the `NEBU_OAUTH_CONFIG_CACHE_MS` paragraph (mentions `matrix_session_ttl_seconds`, session lifetime, last-known-good), 08-concepts (no "inert in production" / "test seam", names the Admin setting + last-known-good), CHANGELOG (last-known-good), moduledocs of `Nebu.OAuth.Config` (`matrix_session_ttl_seconds`, `last-known-good`) and `Nebu.Web.SessionConfig` (`Admin`, `last-known-good`).

Decisions made (tell the orchestrator): (1) a SUCCESSFUL read that finds NO row clears the last good value (the operator removed it on purpose: env / 8 h apply); only failed reads and damaged rows keep it. (2) `invalidate_cache/0` does NOT forget it (only the TTL entry is dropped); a deliberate admin save replaces it at once, with no read in between. (3) the seam (`:oauth_config_source`) and `:no_repo` do not take part in last-known-good. (4) C is pinned as BEHAVIOUR (two concurrent saves with an existing row chain: `before` = first save's `after`; a concurrent save of the same value is "no change"), forced through a blocking audit writer and `pg_locks`; the reference does it with `Nebu.Admin.DB.with_locked_config/2` (row lock `FOR UPDATE` around the nested `save_config_audited`; the existing `:narrowing` option is NOT usable: it only runs on the unaudited retry path). Two FIRST saves (no row to lock) still race, not pinned. (5) The reference calls `note_saved_matrix_session_ttl/1` from `after_config_write`, which now runs inside the outer lock transaction (before the commit); the dev may move it after the commit.
Open: none blocking; the INFO naming collision (`Nebu.OAuth.matrix_session_ttl_seconds/0` saved-or-nil vs `SessionConfig.matrix_session_ttl_seconds/0` effective) is not pinned.

## Cycle 2 (delta reviews: Kassandra LOW #1-#3, code review MINOR 1-6): red tests against the staged dev state

lib / docs / CHANGELOG / config are the staged dev state (reference applied and reverted with `git checkout`; `reference-impl-cycle2.diff`: db.ex, config.ex, last_good.ex, matrix.ex, runtime.exs, 07-deployment, 08-concepts, ADR-033). Tests added: `oauth/session_lifetime_stale_refill_test.exs`, `admin/admin_db_locked_config_test.exs`; changed: `oauth/session_lifetime_last_good_test.exs` (+:no_repo), `oauth/session_lifetime_docs_test.exs` (+5 docs tests). Story Decision text edited (file: docs/stories/oauth-session-and-consent/session-lifetime-setting.md, last bullet, see report to orchestrator), so its docs test is a regression guard, not red.

| file | red | green with reference |
|---|---|---|
| `session_lifetime_stale_refill_test.exs` (integration, 6) | 4 fail (stale LastGood put, stale "no row" clear, stale cache refill x2; the 2 controls pass) | 6 |
| `session_lifetime_last_good_test.exs` (19) | 2 fail (:no_repo answers last good, switch stays disabled with it) | 19 |
| `admin_db_locked_config_test.exs` (11; 9 integration, 2 no DB) | 9 fail | 11 |
| `session_lifetime_docs_test.exs` (12) | 4 fail (before_seconds wording, access-token row, ADR pointer, matrix.ex / runtime.exs / 08-concepts) | 12 |
| `unit_nodb.sh` (warnings as errors) | 5 fail of 7000 (1 locked-config `:unlocked`, 4 docs), no warning | exit 0, 7000 passed |
| `quick.sh` admin + oauth + web + matrix/session + 000056 with reference | - | 5468 of 5484; the 16 failures are the known unrelated families |

Mutants: 25 new (D01-D26 without D18), 25 killed (two test gaps found by the first run and closed: effect order, one flaky run).

Interfaces / decisions pinned (names are mine):
- Stale refill: generation (compare-and-set) in `Nebu.OAuth.LastGood` (`generation/0`, `put_if/2`, `clear_if/1`, `put_saved/1`), captured BEFORE the query in `Config`; a save (`note_saved_matrix_session_ttl/1`) bumps it; cache write only when unchanged. The tests need no seam: a telemetry handler on `[:nebu, :repo, :query]` parks ONE reader after its query returned.
- `:no_repo` answers last good (switch stays `:disabled`, `enabled: false`).
- `Nebu.Admin.DB.with_locked_config/2`: `{:commit|:rollback, result}`; rollback runs no effect; NESTING REFUSED with `ArgumentError` (outer rolled back, queue dropped); an exception of `fun` is RE-RAISED after rollback (no longer swallowed into `{:error, :db}`); effects run in save order, a raising effect is logged (one `[error]` line, exception type only) and does NOT stop the others, the call returns `fun`'s result; process key `{Nebu.Admin.DB, :deferred_after_commit}` absent after commit / rollback / raise; `:unlocked` branch: effects run immediately; infra failure (Postgrex.Error from the lock query, e.g. a NUL in a key) = `{:error, :db}` + ONE value-free line (`postgres <sqlstate name>`), `fun` not called.
- Test seam (test builds only) `:nebu_http, :admin_after_config_write` (1-arity, called with `changes` at the start of `after_config_write/1`) to observe effects.
- Docs: 07-deployment ("`before_seconds` is the saved value read inside the transaction, else the value this node had in effect", access-token row points to the Admin setting), ADR-033 pointer sentence (decision text kept), `matrix.ex` @doc of `oauth_issue_session`, `runtime.exs` comment, `08-concepts.md` `expires_at` line. `stringify_keys(changes)` computed once in `after_config_write/1` (reference).
