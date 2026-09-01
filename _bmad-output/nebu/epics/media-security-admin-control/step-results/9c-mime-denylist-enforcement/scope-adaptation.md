# Scope adaptation — 9c-mime-denylist-enforcement (decided before ATDD, confirmed by codebase inspection)

**Verified fact (2026-07-13):** Story 2b (`PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`,
`Nebu.Media.upload_async/3`) has NOT landed on this branch yet.
- `server/lib/nebu/web/router/media.ex` has no `:media_id`-parameterized PUT route — only the
  legacy `put "/v3/upload"` → `Media.upload/1` (synchronous, Story 1/AC1 handler).
- `server/lib/nebu/media.ex` has no `upload_async/3` function.
- `server/test/nebu/media/media_fakes.exs` has no reservation/async-upload fakes yet.

**Decision:** 9c's literal Acceptance Tests (PUT against `upload_async/3`, asserting on storage
fakes / state transitions / scan-job enqueue) cannot be implemented against real production code
that does not exist yet. Per direction, this story instead:

1. Implements the mime_denylist enforcement decision as a **standalone, fully unit-tested pure
   function** in `Nebu.Media`: `mime_denylist_rejected?/1`, taking the ALREADY-RESOLVED
   `Content-Type` string (matching AC3 — no header parsing/defaulting inside this function, that
   remains the caller's job, mirroring how 2b/`upload/1` resolve `Content-Type` before checking
   `@blocked_upload_types`).
2. Reads `Nebu.Media.Config.get/0` per call (AC1/AC5 — no local caching; Config's own
   ETS/`:pg`/TTL mechanism, already built in 9a, is what delivers "no restart needed" once this
   function is actually called from a request path).
3. Parses `mime_denylist` (comma-separated, trim tokens, drop empty tokens → `""` parses to `[]`)
   and matches via `String.starts_with?/2` against every prefix (AC3/AC4).
4. Is NOT wired into any handler in this story — `upload_async/3` does not exist to wire it into.
   The Dev Agent Record MUST document, explicitly and specifically, that once Story 2b lands,
   its handler must call `Nebu.Media.mime_denylist_rejected?/1` immediately after resolving
   `Content-Type` (2b AC1) and before the size check (2b AC6/413), rejecting with
   `error(conn, 400, "M_BAD_JSON", "Content-Type not permitted by admin policy")` on `true` —
   i.e. exactly the validation-order slot the story's Technical Requirements section already
   specifies (step 5, between the state guard and the size check).
5. Tests exercise `mime_denylist_rejected?/1` directly (unit-level), using the EXISTING
   `Application.get_env(:nebu_http, :media_config_source)` seam already built into
   `Nebu.Media.Config` (9a) — no new MediaFakes seam is needed for the config side.
6. `@blocked_upload_types` in `upload/1` is untouched (per Dev Agent Guardrails) — no test in
   this story's suite may assert new behavior on the synchronous `upload/1` path beyond the
   existing regression-guard AC6 (unrelated-check independence), which can be verified by reading
   `upload/1`'s existing code (it already rejects `text/html` etc.) without needing a new test if
   one doesn't already exist — dev-story should check for an existing equivalent before adding a
   duplicate.

**What does NOT change from the story's literal ACs:**
- AC1 (reads via `Config.get/0` per-call, no caching) — fully testable as specified, just at the
  function level instead of through a PUT request.
- AC3 (prefix match, no sniffing) — fully testable.
- AC4 (empty denylist → never rejects) — fully testable.
- AC5 (no-restart) — testable as "two consecutive calls to `mime_denylist_rejected?/1` reflect an
  intervening config source change with no process restart or extra step" — the essence of AC5
  (no caching layer of its own) is preserved even without a real PUT endpoint to drive it through.

**What is deferred (cannot be tested until 2b exists):**
- AC2's "before storage / before size check / no row written" ordering claims — these describe
  `upload_async/3`'s internal call order, which doesn't exist yet. Documented as a wiring
  instruction, not tested here.
- Acceptance Tests #1, #2, #5 as literally written (full PUT request/response assertions,
  storage-fake non-call assertions, state-machine transition assertions) — superseded by
  function-level tests against `mime_denylist_rejected?/1` covering the same AC1/AC3/AC4/AC5
  intent.
- Acceptance Test #4 (config change mid-flight across two PUTs) — adapted to two direct calls to
  `mime_denylist_rejected?/1` around a config source mutation.
- Acceptance Test #6 (regression: `@blocked_upload_types` unaffected) — kept as a genuine
  regression check but at the `upload/1` handler level (already-existing coverage may suffice).

This note is authoritative context for ATDD, test-review, dev-story, and code-review steps.
