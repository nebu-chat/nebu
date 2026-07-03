# Test Quality Review — `server/test/nebu/web/oidc_scopes_test.exs`

**Scope:** Staged new test file (461 lines, 40 tests), RED-phase ATDD for story `centralize-scope-resolution` (epic `oidc-simplification`). Reviewed against story ACs at `docs/stories/oidc-simplification/centralize-scope-resolution.md` and cross-checked against the current (pre-refactor) production source it targets.

## AC coverage map

| AC | Describe block | Tests | Verdict |
|---|---|---|---|
| AC1 | `AC1: module + public API shape` | 8 | Covered |
| AC2 | `AC2: scope cache reuses...` | 4 | Covered, with a caveat (see MAJOR-1... wait MAJOR-2) |
| AC3 | `AC3: offline_access does not leak...` | 4 | Covered, precise |
| AC4 | `AC4: ...thin call-sites` | 9 | Covered, but one test is unsatisfiable (see MAJOR-1) |
| AC5 | `AC5: ...call the ONE validator` | 4 | Covered |
| AC6 | `AC6: OIDC Scopes Law...` | 7 | Covered, strong |
| AC7 | `AC7: \z anchor...` | 4 | Covered |

40 tests total, matches `git diff --staged --stat` (461 insertions). Every AC has multiple tests — no AC is uncovered.

Not applicable, noted explicitly: this is not a GenServer-state story (no new GenServer is introduced by `OidcScopes` — it reads through the existing `Nebu.Web.OidcConfig` GenServer/ETS cache) and not a UI story (no `ui: true` frontmatter, no Playwright/e2e artifacts expected). Crash/restart and Playwright checks are correctly and intentionally absent.

## Findings

### MAJOR-1 — AC4 "no Nebu.Matrix reference at all" test is permanently unsatisfiable, even by a correct implementation
`server/test/nebu/web/oidc_scopes_test.exs:356-367`, test `"grep: admin/auth.ex no longer calls into the Nebu.Matrix domain (ADR-020)"`:

```elixir
refute source =~ ~r/Nebu\.Matrix\b/,
       "AC4: Nebu.Admin.Auth must contain NO reference to the Nebu.Matrix domain at all " <>
         "(direct or facade-mediated) after centralization"
```

`server/lib/nebu/admin/auth.ex` currently contains two legitimate, story-unrelated references to `Nebu.Matrix`:
- `Nebu.Matrix.UserId.from_claims(claims, server_name())` (line 290) — identity/claim resolution, explicitly out of scope for this story (see story Non-Goals: "Kein Claim-Mapping").
- `Nebu.Matrix.OidcMetadata.fetch(issuer)` (line 1099) — TLS-verifying OIDC metadata fetch, unrelated to scopes.

The story text (AC4) and Implementation Map only require removing the `matrix_oidc_extra_scopes/0` facade call (line 1010) and the `union_scopes/2` fold — not these two other calls. A correct, complete, story-scoped implementation will still leave `Nebu.Matrix.UserId` and `Nebu.Matrix.OidcMetadata` references in `admin/auth.ex`, so this specific `refute` will still fail after the real fix is done. Recommend narrowing this assertion to the two lines actually in scope (already-present separate assertions: `refute source =~ "Nebu.Matrix.matrix_oidc_extra_scopes"` and `refute source =~ "union_scopes"`) — the broad `~r/Nebu\.Matrix\b/` refute should be deleted or scoped only to the scope-resolution call site.

### MAJOR-2 — AC2 cache-invalidation "smoke test" does not exercise ETS or `:pg` at all, and cannot detect the exact regression it claims to guard against
`server/test/nebu/web/oidc_scopes_test.exs:276-293`, test `"cache invalidation is cluster-wide: refreshing OidcConfig also refreshes scope values..."`.

The test only re-sets the `:matrix_oidc_extra_scopes_reader`/`:matrix_oidc_refresh_mode_reader` Application-env seams (which bypass ETS/`:pg` entirely per `Nebu.Web.OidcConfig`'s own documented seam design) and asserts the resolved scope changes. It never calls `Nebu.Web.OidcConfig.refresh/0`, never touches the ETS table, and never joins/asserts on the `:pg` group. An implementation that adds a brand-new, node-local-only, `:pg`-unaware ETS table for the four new scope keys — precisely the anti-pattern AC2 explicitly forbids — would pass this test, because the seam override short-circuits before any cache is touched either way. Recommend: either (a) add an integration-style test that calls `Nebu.Web.OidcConfig.refresh/0` with a seeded `server_config` row and asserts `OidcScopes.resolve_scope/1` reflects the DB value via the real ETS path (no reader-seam override), or (b) strengthen the grep check to require the four keys appear specifically within the ETS read/write functions.

### MINOR-1 — Redundant/overlapping assertions in AC6 "law" tests
Lines 158-176. Three `refute scope =~ "..."` substring checks immediately followed by `assert scope == "openid"` on the same value — the equality assertion already subsumes the substring refutes. Not incorrect, just redundant.

### MINOR-2 — AC6 grep test only guards two specific literal patterns, not the general "no literal beyond openid" rule
Lines 178-193. The story's AC6 text says no literal string beyond `"openid"` may appear anywhere in the diff; the test only refutes two specific regexes. Would miss e.g. a hardcoded `"openid groups"` default. Given this bug class has recurred multiple times per team memory (`feedback_oidc_scopes_law.md`), a more general check would be a stronger backstop. Behavioral tests (lines 136-176) provide the stronger backstop independent of this grep.

### INFO-1 — Substring (`=~`) matching for `offline_access` acceptably precise here (no colliding scope name exists today).

### INFO-2 — `async: false` correctly set given global `Application.put_env` mutation; no hard waits; `on_exit` cleanup present. Solid hygiene.

### INFO-3 — Regex-pattern grep checks for "no local validator copy" correctly calibrated against actual current regex literal in source files.

### INFO-4 — GenServer/UI checks correctly N/A, confirmed explicitly (no new GenServer, no ui:true frontmatter).

## AC3 regression-test precision: STRONG
Core regression test (lines 201-209) matches the story's exact case, reinforced by 3 more tests (reverse-direction leak, own-mode-still-works, mode-crossed variant). No gaps.

## AC6 "law" enforcement strength: MIXED BUT NET POSITIVE
Behavioral tests (lines 136-176) are strong — exact equality to `"openid"` / `"openid offline_access"` with sorted-list comparison avoiding order-dependent trap. Static grep test (lines 178-193) is a weaker secondary backstop (see MINOR-2) but not a fig leaf given the behavioral coverage.

## Summary
- 2 MAJOR: AC4 unsatisfiable-by-design grep assertion (test bug, needs narrowing before it can gate GREEN); AC2 cache-invalidation test doesn't exercise the actual ETS/`:pg` mechanism.
- 2 MINOR: redundant AC6 assertions; AC6 grep pattern narrower than story's stated rule.
- 4 INFO: substring-matching note, hygiene confirmed good, regex-calibration confirmed correct, GenServer/UI-N/A confirmed explicit.

**Recommendation:** Fix MAJOR-1 before relying on this suite as the RED gate for AC4 — as written, a developer doing a fully correct, in-scope refactor will still see this suite red and may be tempted to over-remove legitimate `Nebu.Matrix.UserId`/`Nebu.Matrix.OidcMetadata` calls to satisfy it, which would itself be a regression.

---

## Resolution (post-review fix, before dev-story)

Both MAJOR findings fixed directly in `server/test/nebu/web/oidc_scopes_test.exs`:

**MAJOR-1 fixed:** Narrowed the blanket `refute source =~ ~r/Nebu\.Matrix\b/` to
`refute source =~ ~r/Nebu\.Matrix\.matrix_oidc_extra_scopes|matrix_oidc_extra_scopes\(\)/` — scoped
to the actual scope-resolution call site. Legitimate out-of-scope `Nebu.Matrix.UserId.from_claims/2`
and `Nebu.Matrix.OidcMetadata.fetch/1` references in `admin/auth.ex` are now correctly left alone.
Verified RED today (facade call still present), and confirmed it will flip GREEN without requiring
removal of the two unrelated calls.

**MAJOR-2 fixed:** Added a new `@describetag :integration` describe block ("AC2 (integration)")
with 3 tests that seed real `server_config` rows via the same `INSERT ... ON CONFLICT DO UPDATE`
upsert pattern the app itself uses (`Nebu.Admin.DB.upsert_server_config/1`), start the REAL
`Nebu.Web.OidcConfig` GenServer (gated off under `mix test` by `start_jwks_cache: false`, so
started explicitly here), call `Nebu.Web.OidcConfig.refresh/0` with no seam override, and assert
`resolve_scope/1` observes the DB-backed value only after that real refresh call — plus a `:pg`
group-membership guard. 2 of the 3 new tests are confirmed RED (UndefinedFunctionError) via
`make test-integration`-equivalent containerized run; the third (`:pg` membership) is a legitimate
already-true precondition guard (documented inline), analogous to the reviewer's INFO-3 finding.

**Bug caught while building the fix:** `server_config` has `FORCE ROW LEVEL SECURITY` with
SELECT/INSERT/UPDATE policies but no DELETE policy at all — a bare `DELETE` silently affects 0 rows
for the `nebu_app` role rather than raising. The first draft of the AC2 integration tests used
delete-then-insert cleanup, which silently failed to reset state between tests and caused a
pkey-collision cascade. Fixed by switching to the same upsert pattern the production code uses.

Full regression check after the fix: 39/40 unit tests RED (1 legitimate pre-existing-invariant
pass, 3 integration tests excluded from the unit run), 2/3 new integration tests RED + 1 legitimate
pass, all 6 named AC7 regression suites green (36 passed), full `test/nebu/web/` directory
111 pre-existing passed + 39 new RED = 150 total (20 excluded), zero collateral damage.

**Status: RESOLVED — cleared to proceed to dev-story.**
