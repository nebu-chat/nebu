# Pre-dev test-review — 9b-media-settings-ui

Reviewed: `server/test/nebu/admin/media_settings_controller_test.exs` (16 tests, 8 describe blocks, AC1-AC8).

**RED-for-right-reason: CONFIRMED.** All 16 tests fail with 404 (route/controller/HTML module
missing). No wrong-reason failures (no Repo-not-started, no compile error). Seam-based
(`:media_config_source`/`:media_config_writer`/`FakeAuditRepo`), no live DB, no `:integration` tag.
Verified the real `Nebu.Media.Config.upsert/2-3` API and `Nebu.Media.SSRF.check/1` behavior are
correctly modeled (not the story's stale `upsert/1` reference).

## MAJOR

**M1 — AC1 pre-fill assertions can pass without the feature working (false-positive risk).**
Lines 284–296 and 314–325 assert `body =~ "<value>"` against the WHOLE response body using short
numeric strings that are substrings of OTHER fields' values:
- Test "renders all nine media_config fields...": fixture values `"12"`, `"6"`, `"45"` are
  substrings of `max_upload_size_bytes = "12345678"` — so `deleted_days`, `orphaned_hours`, and
  `released_delete_after_days` are effectively unverified; a controller that omits rendering those
  inputs entirely would still pass this test.
- Test "...falls back to its config.exs default": `"20"` is a substring of `"20000"`; `"24"` is a
  substring of `"52428800"` — `max_pending_per_user` and `orphaned_hours` are effectively
  unverified for this test too.

Net effect: this test nominally "covers" AC1, but the coverage is illusory for ~2-3 of the 9
fields per test — a materially incomplete implementation could still go green. Classified MAJOR
per the pipeline's own definition ("missing AC coverage") since the assertions do not actually
prove the claimed behavior.

**Fix (cheap, test-only):** scope each assertion to the specific field's own rendered input, e.g.
`assert body =~ ~s(name="orphaned_hours" value="6")` (or a per-field regex/anchor), rather than a
bare whole-body substring check.

## MINOR

**m1 — AC3 webhook_url atomicity refute is narrower than AC2's, permits an undetected partial
persistence.** AC2's "negative value rejected" test uses `refute_received {:media_config_written,
_key, _value}` (ANY key — enforcing that a single bad field blocks ALL writes, matching AC6's "not
silently discarded" / AC2's "before the request reaches upsert" language). AC3's two webhook tests
(lines 416, 439) only `refute_received {:media_config_written, "webhook_url", _value}` — a
controller that pre-validates the 7 numeric fields, persists them, and only THEN delegates
webhook_url validation to `Config.upsert` (which would fail and abort) could persist 7 keys before
failing on webhook_url, yet still pass this test. Widen both refutes to the ANY-key form used in
AC2, for consistency with the atomicity contract the story implies project-wide.

**m2 — Double-negative assertion (readability nit).** Line 347:
`refute get_resp_header(conn, "location") != []` — works, but prefer
`assert get_resp_header(conn, "location") == []`.

## INFO

- No positive-path test for a valid public HTTPS `webhook_url` (would require real DNS in a
  no-DB/no-network unit test — reasonably deferred; not a gap that needs closing here).
- AC2 covers upper-bound/negative/non-numeric but not "positive-but-below-lower-bound" — acceptable
  since per-field bounds are dev-story's own invented values (LogsController precedent), not yet
  fixed by the story text.
- Playwright/Gherkin e2e coverage (`e2e/features/admin/`) was explicitly considered: unlike
  `logs-config.feature` (client-side-JS-only toggle behavior AC7/AC8/AC11, unobservable by ExUnit),
  this story's AC4 "stronger warning" is computed and rendered entirely server-side at save time —
  no genuine JS-only behavior exists on this page that ExUnit cannot already exercise. Judged N/A
  for this story, subject to independent confirmation at the Step 5b UX Gate (ui:true triggers it).

## Verdict

APPROVE WITH ONE MAJOR (M1) + one MINOR (m1) + one nit (m2) to fix before this suite can be
trusted as the GREEN-phase gate. Recommends a test-only fix cycle (no story-intent issue, no
implementation exists yet) rather than blocking indefinitely — escalating to caller per standing
instruction since M1 is classified MAJOR.
