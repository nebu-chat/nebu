# Code Review Report — Story 9c-mime-denylist-enforcement (Cycle 0)

**Verdict:** No MAJOR issues. Guardrails met. Findings are documentation-accuracy issues.

### MAJOR
None.

### MINOR

**M1 — Wiring doc + test comments mischaracterize `base_content_type/1`'s normalization (security-relevant for the future 2b wiring).**
`server/lib/nebu/media.ex` (the `mime_denylist_rejected?/1` `@doc`, wiring example) and `server/test/nebu/media/mime_denylist_test.exs` (comment near the case-sensitivity test: "Plug already normalizes Content-Type header casing before this function ever sees it") both treat `base_content_type(conn)` as a plain passthrough resolver. It is not: `base_content_type/1` -> `base_type/1` (media.ex) **downcases** (`String.downcase()`) **and strips `;`-parameters**. The "Plug normalizes header casing" claim is factually wrong — Plug lowercases header *field names*, not *values*; the case-insensitivity actually comes from `base_type/1`'s explicit downcase. `mime_denylist_rejected?/1` itself is strictly case-sensitive, so correct enforcement DEPENDS on the caller routing Content-Type through `base_content_type` (or an equivalent downcaser) — this is a load-bearing dependency the wiring instruction does not call out. A future Story 2b `upload_async/3` that resolves Content-Type differently could silently produce a case-sensitive denylist bypass (client sends `Content-Type: Application/X-MSDownload`, admin blocked `application/x-msdownload`, upload slips through). Given `security_review: required`, the wiring instruction should explicitly state the passed value MUST be lowercased/param-stripped before calling this function.

**M2 — Stale RED-phase moduledoc in `mime_denylist_test.exs`.**
The moduledoc still asserts "Every test below fails to compile/run right now... that IS the required RED state" and "Do NOT implement the function... that is dev-story's job." The function is now implemented and tests are green — this text is now factually false and misleading to a future reader.

### INFO

**I1 — "Trailing parameters" test frames a scenario the documented caller cannot produce.** The test calls `mime_denylist_rejected?("text/plain; charset=utf-8")` directly, but `base_content_type` (the resolver the moduledoc itself cites) strips params before this function ever sees the value. Valid unit test of the pure function's prefix semantics, but the framing implying this reflects the real 2b call path is inaccurate (same root cause as M1).

**I2 — Dev Agent Record test-count wording.** States "7 pre-existing media_upload tests" — the `@blocked_upload_types` regression test is newly added in this diff, so labeling all 7 as "pre-existing" is imprecise (only pre-existing relative to the test-review step, not to this changeset).

**I3 — Mixed-case denylist config values won't match.** If an admin enters e.g. `Application/Zip`, Config stores it verbatim (no downcasing in config.ex validation) and it will never match a lowercased incoming Content-Type. Out of this story's scope (config.ex untouched, 9b owns the editing UI) — noted for a future config/9b follow-up, not actionable here.

### Confirmed correct / guardrails met
- Config usage, parsing (comma-split/trim/discard-empty, AC4), matching semantics (AC2/AC3), no-memoization (AC1/AC5) all verified correct against config.ex and test assertions.
- Regression test in media_upload_test.exs verified real (not a false positive).
- `config.ex` not touched; `@blocked_upload_types`/`upload/1` untouched; no MIME sniffing added; no second config cache added.
- No ADR-018/ADR-020 violations, no dead code, no unused imports.
