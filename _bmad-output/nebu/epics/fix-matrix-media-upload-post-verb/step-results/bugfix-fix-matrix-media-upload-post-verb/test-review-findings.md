# Test Review — bugfix-fix-matrix-media-upload-post-verb

**Reviewer:** Master Test Architect (bmad-testarch-test-review)
**Scope:** Staged files for this bugfix — focus on
`server/test/nebu/media/media_upload_verb_test.exs` (new ATDD regression file).
**Status of code under test:** RED phase — `server/lib/nebu/web/router/media.ex:55`
still reads `put "/v3/upload"`; the one-line fix (`put` → `post`) has not been
applied yet. This review evaluates test quality/coverage, not pass/fail state.

Staged diff reviewed:
- `_bmad-output/.../pipeline-state.yaml`
- `docs/stories/bugfix/fix-matrix-media-upload-post-verb/fix-matrix-media-upload-post-verb.md`
- `server/test/nebu/media/media_upload_verb_test.exs` (new, 204 lines)

---

## AC ↔ Test Coverage Matrix

| AC | Requirement | Test | Verdict |
|----|---|---|---|
| AC1 | `POST /v3/upload` → 200, reaches `Media.upload/1`, `content_uri` shaped `mxc://...` | `AC1: authenticated POST upload -> 200 with mxc:// content_uri and file stored` (line 93) | Covered |
| AC2 | `PUT /v3/upload` → generic 404, no undocumented alias | `AC2: PUT /_matrix/media/v3/upload -> generic 404 M_NOT_FOUND catch-all...` (line 117) | Covered |
| AC3 | `PUT /v3/upload/<extra-segment>` → generic 404, no accidental path-param widening | `AC3: PUT /_matrix/media/v3/upload/:server_name/:media_id is unaffected...` (line 135) | Covered |
| AC4 | `@upload_rate_limit` still applies to corrected route | `AC4: @upload_rate_limit (burst 5) still applies to POST /_matrix/media/v3/upload` (line 155) | Covered |

All four ACs have at least one test, each test asserts the correct Matrix
`errcode`/HTTP status (not just a bare status code), and the moduledoc (lines
1–36) explicitly cross-references each AC to its RED→GREEN expectation. This
is good ATDD hygiene.

---

## Findings

### MAJOR — Applying this fix will turn an existing, currently-green test file red, and nothing in this story's scope addresses it

`server/test/nebu/media/media_upload_test.exs` (existing file, **not** part of
this diff) drives `Media.upload/1` exclusively via `PUT` — see line 66:

```elixir
conn(:put, @upload_path, body)
```

and every test name in that file (`"authenticated PUT upload → 200..."`,
`"PUT upload with NO Bearer token → 401..."`, `"PUT upload exceeding the
configured size limit → 413..."`, etc. — lines 77, 103, 110, 123, 141, 159)
sends the request via `PUT`. Once the router verb is changed from `put
"/v3/upload"` to `post "/v3/upload"` (the entire scope of this bugfix), every
one of these 6 tests will hit the generic 404 catch-all instead of
`Media.upload/1` and fail.

This is not hypothetical — it's the same file/fixture pair
(`Nebu.Web.MediaTestSupport`, `Nebu.Web.MediaFakes`) and the same route this
story is fixing. The story's Dev Notes → "Files likely changed" (story doc,
lines 104–108) lists only:
- `server/lib/nebu/web/router/media.ex:55`
- "new regression test file/module covering AC1–AC4"

`server/test/nebu/media/media_upload_test.exs` is not mentioned anywhere.
The new ATDD file's moduledoc even asserts "no change to `Media.upload/1`... no
change to the `@upload_rate_limit` plug call" (lines 13–14) — true for
production code, but it doesn't account for the *existing test suite's*
hard dependency on the old verb.

**Impact:** the fix, as currently scoped, will make CI red (or force the dev
step to discover and patch `media_upload_test.exs` out-of-band, unreviewed).

**Recommendation:** before/with the router verb change, update
`media_upload_test.exs` to issue `POST` instead of `PUT` (and update its
moduledoc/test names accordingly, since they currently say "PUT upload" throughout).
This should be called out explicitly in the story's Dev Notes / Files-likely-changed
list so the dev step doesn't miss it, and the CI gate step should treat a red
`media_upload_test.exs` after the fix as an expected-but-required cleanup, not
a surprise regression.

---

### MINOR — AC4's blocked (429) request doesn't assert non-persistence

AC2's test asserts `refute_received {:stored, _key, _bytes}` (line 130) to
prove a rejected request never reaches the storage boundary. AC4's blocked
6th request (line 196, `blocked = post_upload.()`) checks `status == 429` and
the `errcode`, but never asserts `refute_received {:stored, ...}` for that
specific request. Given the test process already receives `{:stored, ...}`
messages from the prior 5 successful uploads, a mixed-up ordering bug (e.g.
rate limit checked *after* store) wouldn't be caught by a bare `refute_received`
without also draining/counting the prior messages — so the omission is
understandable — but consider counting received `:stored` messages (expect
exactly 5, not 6) to fully close the loop that the 429 truly halted before
`Media.upload/1`/storage.

### MINOR — Shared rate-limit ETS table keys on bare IP, not `{ip, tier}`

Confirmed in `server/lib/nebu/web/plugs/rate_limit.ex` (`:ets.lookup(@table,
ip)`, `:ets.insert(@table, {ip, ...})`): the token bucket is keyed on IP only —
tier is not part of the bucket key, even though multiple tiers exist
(`login`, `preview_url`, `media_upload`, ...). This means any two tests in the
suite (regardless of tier) that reuse the same `remote_ip` and don't
explicitly clear the shared `:nebu_http_rate_limit_buckets` table can silently
cross-contaminate each other's bucket state.

The new test avoids this correctly:
- dedicated IP `{203, 0, 113, 77}` (verified unique — not reused by
  `matrix_router_test.exs` or `url_preview_test.exs`, which both use
  `{203, 0, 113, 7}`),
- explicit `:ets.delete_all_objects/1` on the table both before the burst and
  in `on_exit`,
- `async: false` (required, since this is process-global state).

This matches the established pattern in `url_preview_test.exs` exactly, so
it's not a new risk — flagging as MINOR/documentation-only: there is no
central registry of "reserved test IPs" for this shared table, so a future
test author could accidentally reuse `.7` or `.77` without knowing the bucket
key ignores tier. Worth a one-line comment or shared constant in
`MediaTestSupport`, not blocking for this story.

### INFO — No hard waits / timing-based flakiness

The AC4 burst test relies purely on token-bucket *count* (burst = 5, 6th
request blocked), not on `Process.sleep` or wall-clock timing, and doesn't
need the `rate_limit_clock_fn` seam since it never expects a refill within the
test. This is the deterministic approach and matches
`server/lib/nebu/web/plugs/rate_limit.ex`'s documented test seam guidance.

### INFO — GenServer crash/restart test: not applicable, confirmed

This is a stateless `Plug.Router` verb change (`put` → `post`), not a
GenServer-backed feature. `Nebu.Web.Plugs.RateLimit`'s own moduledoc already
documents its ETS-backed state as intentionally volatile/reset-on-restart —
there is no new state machine introduced by this fix, so no
crash/restart test is warranted here. Agree with the story's implicit
framing.

### INFO — UI/Playwright coverage: not applicable, confirmed

Backend-only router fix; no template, JS, or Admin-UI surface is touched by
this story. No Playwright/E2E test is required for this change.

### INFO — Matrix error codes asserted, not just HTTP status

Every negative-path test asserts the Matrix `errcode` in addition to the HTTP
status (`M_NOT_FOUND` for AC2/AC3, `M_LIMIT_EXCEEDED` for AC4), and AC1 asserts
the `content_uri` shape (`mxc://<server_name>/...`) rather than just `200`.
This is solid Matrix-spec-aware assertion depth, consistent with sibling media
test files.

### INFO — AC3 test framing is unusual but well-justified

AC3 asserts a 404 for a route that has never existed in this codebase (no
`put "/v3/upload/:server_name/:media_id"` route currently exists, per the
story's corrected Root Cause Analysis, lines 56–66). The test's own comment
(lines 25–33) is explicit that this is a regression guard against
scope-creep in the fix, not a RED→GREEN assertion — good traceability, matches
the story doc's AC3 framing exactly ("this AC is a guard against scope creep
in the fix, not a regression test for pre-existing behavior").

---

## Summary

- AC coverage: 4/4 ACs have at least one test — good.
- No hard waits, no brittle selectors (n/a, backend-only), no non-deterministic
  timing assertions.
- GenServer crash/restart: not applicable, agreed.
- UI/Playwright: not applicable, agreed.
- Matrix error codes + HTTP status both asserted throughout.
- Rate-limit test: robust against the specific flakiness modes checked
  (shared ETS table, IP collision, timing) — follows the same pattern already
  validated in `url_preview_test.exs`.

**One MAJOR finding**, and it is the most important thing in this review: the
router verb fix this story implements will regress **6 existing, currently
green tests** in `server/test/nebu/media/media_upload_test.exs`, which is
outside this diff and not mentioned in the story's "Files likely changed."
This should be resolved (update that file's verb + names from `PUT` to `POST`)
in the same commit/story as the router fix, or the CI gate will surface an
unplanned regression.
