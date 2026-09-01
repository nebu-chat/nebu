# Test Review Report — server/test/nebu/admin/media_settings_controller_test.exs (Story 11b)

**Scope:** 26 new tests (lines 888-1631), 7 describe blocks, extending 9b's existing test file.

**RED-phase sanity check:** Confirmed save_storage/2, test_connection/2 do not exist on the controller;
router has only index/save; StorageConfig has no test_connection/1; the two new test seams
(media_storage_test_connection_fun, media_files_storage_key_count_fun) appear nowhere in lib/.
Legitimate ATDD red state, not a broken test file.

**AC coverage:** All 8 ACs have real, non-vacuous tests. AC1 (3), AC2 (3), AC3 (4), AC4 (7),
AC5/AC6 (2), AC7 (2), AC8 (5) = 26, matching the story's own enumerated list exactly.

**9b's M1 regression check:** Not repeated. field_rendered_with_value?/3 and find_input_tag/2 are
tag-scoped, not whole-body substring — reused/extended from 9b's own M1 fix.

**AC4 orphan-risk gate:** Tested in both directions — fires on endpoint/bucket change with existing
files, correctly does NOT fire in all three negative cases (fresh/empty config, zero-count files,
non-endpoint/bucket field changes). Checkbox-ack persist path and re-submission-without-checkbox
also covered. All "does NOT fire" tests are state-based (assert_received), not just body absence.

**AC2 secret write-only:** Verified against real rendered <input> tag strings, not whole-body.

**AC3 test-connection seam:** Exercised for both success and failure. Non-persistence proven via
spy/state-check, not just "no error." Blank-secret resolution test uses a genuine SecretBox
round-trip against the real :media_storage_config_loader seam.

**Playwright/UI:** No Playwright feature added, matching 9b (same page, same plain-controller
shape) which also shipped without one and was not flagged blocking in this epic's pipeline
history. Judged non-blocking by the same precedent (see INFO-2).

## Findings

**MINOR-1** — `media_settings_controller_test.exs:1210,1464`: bare single-digit whole-body
substring match for orphan count (`=~ "7"` / `=~ "6"`) — collision risk with Tailwind/DaisyUI
utility classes (gap-7, mb-6). Recommend scoping to the alert fragment or a word-boundary regex.
Not blocking — surrounding persistence assertions already discriminate correctly.

**MINOR-2** — `media_settings_controller_test.exs:1099-1129`: Test-Connection failure-path test
lacks an explicit no-persist writer-spy (unlike the success-path and dedicated "does not call
upsert" tests). Low risk, worth a one-line addition for completeness.

**INFO-1** — Minor test redundancy: `:1164-1183` vs `:1075-1097` (both assert non-persistence via
the same spy pattern); `:1380-1403` vs `:1191` (behaviorally identical re-submission-without-ack
checks). Each maps to a distinct name in the story's own AT list — traceable to spec, not sloppy.

**INFO-2** — No Playwright coverage added for this UI story. Sibling precedent (9b, same page,
same shape, also ui:true) shipped without Playwright and wasn't flagged blocking. Treated
consistently as non-blocking; flagged only as a backlog note for the epic's UX/E2E pass (AC8's
native-formaction keyboard-operability can't be verified by Plug.Test in a real browser).

**No MAJOR findings.** All 8 ACs have real, discriminating test coverage; no vacuously-true tests;
orphan-risk gate tested in both directions with all negative cases; secret write-only contract
checked against real HTML attributes; test-connection seam exercised both ways with spy-based
non-persistence proof.
