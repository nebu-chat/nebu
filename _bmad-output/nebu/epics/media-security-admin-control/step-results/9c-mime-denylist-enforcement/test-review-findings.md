# Test Review: `mime_denylist_test.exs` (Story 9c-mime-denylist-enforcement)

## AC Coverage (against adapted scope: `Nebu.Media.mime_denylist_rejected?/1`)

| AC | Covered? | Notes |
|---|---|---|
| AC1 (reads `Config.get/0` per call, no caching) | Yes | "no memoization" test (lines 86-109) mutates the seam mid-test and re-asserts. |
| AC2 (4xx before storage) | Partially, correctly deferred | The predicate's true/false outcome is tested; the "before storage / no row written" *ordering* claim is explicitly deferred to Story 2b wiring, documented in both the moduledoc and `scope-adaptation.md`. Reasonable. |
| AC3 (prefix match, no sniffing) | Yes | Exact match, non-match, case-sensitivity, and trailing-params (`; charset=...`) cases all present — good edge-case coverage. |
| AC4 (empty denylist → never rejects) | Yes | Loops over 5 representative content-types against `""`. |
| AC5 (no-restart) | Yes | Dedicated test toggling the seam from `""` → `"application/zip"`. |

## Findings

**MAJOR — Acceptance Test #6 (regression: `@blocked_upload_types` unaffected) is not actually covered anywhere, despite the scope-adaptation assuming it "may suffice."**
`scope-adaptation.md` defers AT#6 with "kept as a genuine regression check but at the `upload/1` handler level (already-existing coverage may suffice)." Verified: no test in the suite exercises `Nebu.Media.upload/1`'s `@blocked_upload_types` path at all (`server/test/nebu/media/media_upload_test.exs`'s moduledoc *mentions* "a blocked/disallowed content type is rejected" as an intended AC — line 11 — but no such test exists in the file — only 401/413/400-empty-body/400-JSON tests are present). So the regression this story is supposed to protect (new `mime_denylist` logic must not interfere with, or be conflated with, the pre-existing hardcoded blocklist) has zero test coverage before or after this change. Easy to add as a two-line PUT test (`content-type: text/html` → `400 M_BAD_JSON "Content-Type not permitted for upload"`) using the existing `media_upload_test.exs` harness; its absence lets a future refactor silently merge or break the two independent lists without any test catching it.

**MINOR — "drop empty tokens" parsing rule is untested for the mid-list case.**
Technical Requirements say parsing must "trim whitespace per token, discard empty tokens." The whitespace-trim test covers `"a, b"`; the all-empty case (`""` → `[]`) is covered via AC4. But a garbage/trailing-comma input like `"application/zip,,text/html"` or `"application/zip,"` (which produces an empty-string token if not filtered) is never tested. This matters because `String.starts_with?(content_type, "")` is always `true` — a parsing bug that fails to drop empty tokens would silently deny *everything*, and no test would catch it.

**INFO — No Matrix errcode/HTTP status assertions.** Correctly out of scope (no PUT handler exists yet); the deferral is explicit and well-documented in both the moduledoc and `scope-adaptation.md`, not silently dropped.

**INFO — No hard waits, sleeps, or brittle selectors.** Deterministic, app-env-seam based, `async: false` appropriately used given global state mutation. Teardown via `on_exit` is correct.

## Summary
Core function-level AC1-AC5 coverage is solid and well-adapted to the standalone-function scope. The one real gap is the missing `@blocked_upload_types` regression test — flagged MAJOR because the adaptation doc assumed existing coverage that turns out not to exist, and it's cheap to add.
