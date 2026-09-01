---
story_id: bugfix-fix-matrix-media-upload-post-verb
title: "Bug: Matrix media upload 404s — /_matrix/media/v3/upload wired as PUT instead of POST"
type: bug
severity: high
epic: fix-matrix-media-upload-post-verb
status: done
security_review: optional
created: 2026-07-30
branch: bugfix/fix-matrix-media-upload-post-verb
---

## Summary

Uploading a file from the Matrix Web client (Element) fails with a **404
`M_NOT_FOUND` / "Unrecognized request"**:

```
POST /_matrix/media/v3/upload?filename=... -> 404 {"errcode":"M_NOT_FOUND","error":"Unrecognized request"}
```

The classic one-shot upload endpoint is registered with the wrong HTTP verb in
`server/lib/nebu/web/router/media.ex:55` — `put "/v3/upload"` instead of
`post "/v3/upload"`. Per the Matrix Client-Server spec, and as sent by
Element/matrix-js-sdk, this endpoint is `POST`. Because `Plug.Router` matches
method + path exactly, the request falls through to the generic 404
catch-all at `media.ex:77-81` instead of reaching the already-implemented
`Nebu.Media.upload/1` handler (`server/lib/nebu/media.ex:160`).

This is not a missing feature — the handler is fully implemented and correct.
It is a one-line router verb mismatch.

## Story

As a Matrix client (Element Web) user,
I want to upload files/images via the standard `POST /_matrix/media/v3/upload`
endpoint,
so that sending attachments in a room works instead of failing with a 404.

## Root Cause Analysis

`server/lib/nebu/web/router/media.ex:55` declares:

```elixir
put "/v3/upload" do
  ...
  Media.upload(conn)
end
```

It should be `post "/v3/upload"`. The forwarding chain is otherwise correct
(`server/lib/nebu/web/router.ex:98` forwards `/_matrix/media` to
`Nebu.Web.Router.Media`), and the handler (`Nebu.Media.upload/1`,
`server/lib/nebu/media.ex:160`) is fully implemented.

**Correction (found by the ATDD subagent during test-writing):** an initial
investigation claimed this mismatch was "previously noted and deliberately
deferred" in favor of a separate async upload route (`PUT
/v3/upload/:server_name/:media_id`, v1.7+) and cited
`docs/stories/media-security-admin-control/2c-sync-upload-shared-pipeline.md`.
Neither the referenced story file nor that async route exist anywhere in the
repo — `server/lib/nebu/web/router/media.ex` is 82 lines and defines exactly
one upload route: `put "/v3/upload"` (no path params). That claim was
incorrect and is struck from this story; there is no separate async route to
protect. The fix is simply: this is the only upload route, and its verb is
wrong.

## Acceptance Criteria

**AC1 — Correct verb:** `POST /_matrix/media/v3/upload` reaches
`Nebu.Media.upload/1` and returns `200 {"content_uri": "mxc://..."}` for a
valid authenticated upload request (mirrors the existing behavior once
reachable — no change to `Media.upload/1` itself).

**AC2 — Old verb removed:** `PUT /_matrix/media/v3/upload` (the wrong,
never-spec-compliant verb) no longer matches this route and returns the
generic 404 like any other unrecognized request — it must not silently keep
working as an undocumented alias.

**AC3 — No path-param route accidentally created:** `PUT
/_matrix/media/v3/upload/<anything>` (a path with extra segments) still
returns the generic 404 — the fix must not accidentally widen the `/v3/upload`
match to also catch path-parameterized requests. (No such route exists in
this codebase today; this AC is a guard against scope creep in the fix, not a
regression test for pre-existing behavior.)

**AC4 — Rate limiting preserved:** the existing `@upload_rate_limit` plug
still applies to the corrected route.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`POST /_matrix/media/v3/upload` → 200, reaches `Media.upload/1`** —
   regression test proving the fix (RED before the verb change, GREEN after).
2. **`PUT /_matrix/media/v3/upload` → 404 generic catch-all** — proves the
   old, wrong verb no longer matches.
3. **`PUT /_matrix/media/v3/upload/<extra-segment>` → generic 404** — guards
   against widening the match unintentionally.
4. **Rate limit still enforced** on the corrected `POST` route.

## Dev Notes

### Files likely changed
- `server/lib/nebu/web/router/media.ex:55` — change `put "/v3/upload"` to
  `post "/v3/upload"`. No change to the handler body or the
  `@upload_rate_limit` plug call.
- `server/test/nebu/media/media_upload_verb_test.exs` — new regression test
  file covering AC1–AC4 (already written, RED).
- `server/test/nebu/media/media_upload_test.exs` — **MAJOR, found by
  test-review:** all 6 existing tests in this file drive `Media.upload/1` via
  `conn(:put, @upload_path, body)`. Once the router verb changes to `post`,
  every one of these tests will 404. Update this file's requests from `:put`
  to `:post` (and any `PUT`-referencing test names/comments) in the same
  change as the router fix — otherwise the fix ships with a self-inflicted
  regression.

### Reuse / parity references
- Handler already correct and unaffected: `Nebu.Media.upload/1`
  (`server/lib/nebu/media.ex:160`).
- Generic 404 catch-all: `media.ex:77-81`.

### Security review scope (security_review: optional)
Verb-only change on an existing, already-authenticated/rate-limited upload
route; no new attack surface. Optional review — run if the dev/code-review
step surfaces anything unexpected (e.g. rate-limit or auth plug ordering
changed by the edit).

## Discovery context
Reported 2026-07-30: user attempted to send a file via the Matrix Web client
(Element) and got a 404 on `/_matrix/media/v3/upload`. Root cause located via
read-only investigation of the media router before this pipeline run.

## Dev Agent Record

### Implementation Plan
One-line router verb fix plus the required companion update to the
pre-existing test file that was driving the same route via the wrong verb
(flagged MAJOR by test-review pre-dev). No handler, plug, or rate-limit
changes.

### Completion Notes
- `server/lib/nebu/web/router/media.ex:55` — changed `put "/v3/upload" do` to
  `post "/v3/upload" do`. No other route in this router file was touched
  (`get "/v3/download/..."`, `get "/v3/thumbnail/..."`, and
  `get "/v3/preview_url"` are unchanged), and the handler body /
  `@upload_rate_limit` plug call inside the route were left as-is.
- `server/test/nebu/media/media_upload_test.exs` — updated per test-review
  MAJOR finding: all 6 pre-existing tests drove the route via
  `conn(:put, @upload_path, body)`; switched the shared `put_upload/2` helper
  to `conn(:post, @upload_path, body)` and renamed the 6 test names /
  assertion message / moduledoc from "PUT upload..." to "POST upload..." so
  they keep exercising the real (now `post`-only) route instead of 404ing.
  The helper function name `put_upload/2` was intentionally left unchanged to
  minimize diff — it is private to this test module and its body no longer
  performs a PUT.
- Verified no other test or e2e fixture assumes the old `PUT` verb for this
  endpoint: `grep -rn "v3/upload" server/test e2e` shows only (a) the two
  files touched above, (b) three admin trace-map/log-grouping tests
  (`trace_map_leitstand_test.exs`, `trace_map_node_controls_contract_test.exs`,
  `trace_map_geometry_test.exs`) that use `/_matrix/media/v3/upload` purely as
  a static route-template label for log grouping, not an HTTP call, and (c)
  `e2e/step-definitions/element/crypto/recovery-setup.steps.ts`, whose one
  "upload" reference is to the unrelated `/keys/device_signing/upload`
  cross-signing endpoint.

### Test Results
- Scoped run: `mix test test/nebu/media/media_upload_verb_test.exs
  test/nebu/media/media_upload_test.exs` → 10 passed (4 new ATDD + 6 updated
  existing), 0 failures.
- Full suite: `make test-unit-elixir` (elixir:1.20-alpine container, per
  Makefile) → exit code 0, **1585 passed, 2 skipped, 423 excluded**, no
  compiler warnings (warnings-as-errors gate green), no regressions.

## File List
- `server/lib/nebu/web/router/media.ex` (modified — line 55 verb fix)
- `server/test/nebu/media/media_upload_test.exs` (modified — PUT → POST per
  test-review MAJOR finding)
- `server/test/nebu/media/media_upload_verb_test.exs` (pre-existing ATDD file,
  no changes needed — already green after the router fix)

## Change Log
- 2026-07-30: Fixed `POST /_matrix/media/v3/upload` router verb mismatch
  (`put` → `post`) in `server/lib/nebu/web/router/media.ex:55`; updated the
  pre-existing `media_upload_test.exs` suite (6 tests) from PUT to POST in
  the same change so it does not regress; full unit suite green
  (1585 passed, 0 failed).
