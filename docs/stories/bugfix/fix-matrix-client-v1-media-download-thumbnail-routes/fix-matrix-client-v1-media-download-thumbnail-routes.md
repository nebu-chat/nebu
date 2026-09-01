---
story_id: bugfix-fix-matrix-client-v1-media-routes
title: "Bug: Element attachments/thumbnails 404 — /_matrix/client/v1/media/{download,thumbnail} routes never ported from the Go media gateway"
type: bug
severity: high
epic: fix-matrix-client-v1-media-download-thumbnail-routes
status: done
security_review: required
created: 2026-07-31
branch: bugfix/fix-matrix-client-v1-media-download-thumbnail-routes
---

## Summary

After fixing the upload verb bug (`bugfix-fix-matrix-media-upload-post-verb`),
uploads work, but downloading/viewing an uploaded attachment in Element fails:

```
GET /_matrix/client/v1/media/download/localhost/<mediaId>?allow_redirect=true       -> 404
GET /_matrix/client/v1/media/thumbnail/localhost/<mediaId>?width=800&height=600&method=scale&allow_redirect=true -> 404
```

Modern Element Web (spec v1.11+ aware) does not use the deprecated
`/_matrix/media/v3/download|thumbnail` endpoints for authenticated media — it
uses the authenticated `/_matrix/client/v1/media/download` and
`/_matrix/client/v1/media/thumbnail` endpoints. Nebu has no route registered
for this path prefix at all, so every request falls through to
`Nebu.Web.Router.Protected`'s generic 404 catch-all.

## Story

As a Matrix client (Element Web) user,
I want to view images/files I or others have uploaded in a room,
so that attachments render instead of failing to load.

## Root Cause Analysis

- `server/lib/nebu/web/router.ex:98` forwards only the `/_matrix/media` prefix
  (deprecated v3 endpoints) to `Nebu.Web.Router.Media`.
- `server/lib/nebu/web/router.ex:146` forwards everything else under
  `/_matrix` (including `/_matrix/client/v1/media/...`) to
  `Nebu.Web.Router.Protected`, which has no route for `client/v1/media/*` —
  the request falls through to `Protected`'s catch-all (`protected.ex:1309`)
  and returns the generic 404.
- `server/lib/nebu/web/router/media.ex:60-70` only defines
  `get "/v3/download/:server_name/:media_id[/:file_name]"` and
  `get "/v3/thumbnail/:server_name/:media_id"` — no `/v1/...` equivalents.

**This is a known regression, not a new feature.** The Go media gateway
previously implemented these authenticated endpoints in full (story
`docs/stories/phase2/epic-12/12-16-authenticated-matrix-media-endpoints.md`,
status `review`/done, `security_review: required`), and
`docs/matrix-api-scope.md` still lists them as ✅ implemented. When the media
gateway was rewritten in Elixir (`full-elixir-stack` epic,
`_bmad-output/nebu/epics/full-elixir-stack/step-results/media-gateway-migration/
oracle-context.md:8-9`), the migration explicitly scoped itself to
"the deprecated `/_matrix/media/v3/` endpoints only" and flagged the
authenticated `client/v1/media` endpoints as an "open follow-up" — but that
follow-up was never done, so the previously-working feature regressed to 404.
`docs/matrix-api-scope.md`'s ✅ marks for these rows are therefore stale and
should be corrected once this story lands.

**Handlers are already reusable — this is a routing-only fix.**
`Nebu.Media.download/2` and `download/3` (`server/lib/nebu/media.ex:528`) and
`Nebu.Media.thumbnail/3` (`server/lib/nebu/media.ex:623`) are plain
`conn, server_name, media_id[, file_name]` functions, not coupled to the v3
router. They already emit the required `content-security-policy` and
`cross-origin-resource-policy: cross-origin` headers via the shared
`serve_bytes/4` / `serve_inline_image/4` helpers (`media.ex:1054-1082`) — no
handler changes needed. `OidcPlug` (already the pipeline for
`Nebu.Web.Router.Media`) already emits the exact `M_MISSING_TOKEN` /
`M_UNKNOWN_TOKEN` 401 semantics the Matrix spec requires for these endpoints.

## Scope

**In scope:** `GET /_matrix/client/v1/media/download/:server_name/:media_id`,
`GET /_matrix/client/v1/media/download/:server_name/:media_id/:file_name`, and
`GET /_matrix/client/v1/media/thumbnail/:server_name/:media_id` — the two
endpoints Element is actually calling and failing on.

**Out of scope (not reported, not touched by this story):**
`GET /_matrix/client/v1/media/config` (AC-1/AC-2/AC-3 of story 12.16) — no
symptom reported for it; Nebu currently has no `/v3/config` route either, so
adding only the `v1` variant would be inconsistent scope creep. Track as a
separate follow-up if Element's upload-size preflight is later found broken.
`width`/`height`/`method` thumbnail resizing — the existing `v3/thumbnail`
handler already ignores these and serves the original image inline (documented
pre-existing limitation, `media.ex:625-630`); this story does not change that
behavior for either prefix, it only makes the `v1` path reachable at all.

## Acceptance Criteria

**AC1 — Authenticated download:** `GET
/_matrix/client/v1/media/download/:server_name/:media_id` with a valid Bearer
token reaches `Nebu.Media.download/2` and returns 200 with the decrypted
bytes, same as the existing v3 route.

**AC2 — Authenticated download, filename variant:** `GET
/_matrix/client/v1/media/download/:server_name/:media_id/:file_name` with a
valid Bearer token reaches `Nebu.Media.download/3` and returns 200 with
`Content-Disposition` containing the URL-provided `file_name`.

**AC3 — Authenticated thumbnail:** `GET
/_matrix/client/v1/media/thumbnail/:server_name/:media_id` with a valid Bearer
token reaches `Nebu.Media.thumbnail/3` and returns 200 with the image bytes
(query params `width`/`height`/`method`/`allow_redirect` are accepted/ignored,
matching existing v3 thumbnail behavior).

**AC4 — 401 without token:** all three routes above, without an
`Authorization` header, return `401 {"errcode":"M_MISSING_TOKEN",...}` (via
the existing `OidcPlug`, not a new auth check).

**AC5 — 401 with invalid token:** all three routes, with an invalid/expired
Bearer token, return `401 {"errcode":"M_UNKNOWN_TOKEN",...}`.

**AC6 — v3 routes unaffected:** the existing `/_matrix/media/v3/download` and
`/_matrix/media/v3/thumbnail` routes continue to work exactly as before — this
story only adds new routes, it does not modify or remove the v3 ones.

**AC7 — CSP/CORP headers present:** responses from the new `v1` routes
include the same `content-security-policy` and
`cross-origin-resource-policy: cross-origin` headers as the v3 routes (this
should fall out for free from reusing `Media.download/thumbnail`, verify with
a test rather than assume).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. AC1 — authenticated `GET /_matrix/client/v1/media/download/:server_name/:media_id` → 200 + correct bytes/content-type.
2. AC2 — same with `/:file_name` → 200 + `Content-Disposition: ...filename="<file_name>"`.
3. AC3 — authenticated `GET /_matrix/client/v1/media/thumbnail/:server_name/:media_id` → 200.
4. AC4 — all three routes, no Authorization header → 401 `M_MISSING_TOKEN`.
5. AC5 — all three routes, invalid Bearer token → 401 `M_UNKNOWN_TOKEN`.
6. AC6 — regression guard: existing v3 download/thumbnail tests still pass unmodified.
7. AC7 — CSP + CORP headers asserted on at least one v1 download and one v1 thumbnail response.

## Dev Notes

### Files likely changed
- `server/lib/nebu/web/router/media.ex` — add `get "/v1/download/:server_name/:media_id[/:file_name]"` and `get "/v1/thumbnail/:server_name/:media_id"` (mirroring the existing `/v3/...` routes, same handler calls), OR add a sibling router forwarded from a new `/_matrix/client/v1/media` prefix in `router.ex` — whichever keeps `Nebu.Web.Router.Media`'s existing `OidcPlug` pipeline and rate-limit setup intact. Prefer extending the existing `Media` router/forward if the path structure allows it, since it already has the right plug pipeline; only introduce a new forward + router module if `/_matrix/client/v1/media` can't cleanly nest under the existing one.
- `server/lib/nebu/web/router.ex` — if a new forward is needed, add it **before** the catch-all `forward "/_matrix", to: Protected` (currently line 146), analogous to the existing `forward "/_matrix/media", to: Nebu.Web.Router.Media` (line 98).
- `server/test/nebu/media/...` — new regression test file covering AC1–AC7.

### Reuse / parity references
- `Nebu.Media.download/2,3` (`media.ex:528`), `Nebu.Media.thumbnail/3` (`media.ex:623`) — reuse as-is, no signature changes.
- `serve_bytes/4` / `serve_inline_image/4` (`media.ex:1054-1082`) — already emit CSP/CORP headers, reused automatically.
- `OidcPlug` 401 semantics (`server/lib/nebu/web/plugs/oidc_plug.ex:63,78`) — `M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN`, already correct, no changes needed.
- Original Go implementation (historical reference only, not present in this Elixir codebase): `docs/stories/phase2/epic-12/12-16-authenticated-matrix-media-endpoints.md`.

### Security review scope (security_review: required)
New authenticated routes reusing existing, already-reviewed handlers and auth
plug — low risk, but this is a new externally-reachable path prefix, so
Kassandra should confirm: (1) the new routes actually sit behind `OidcPlug`
(no accidental bypass), (2) no path-traversal via `:file_name`/`:media_id`
beyond what the v3 routes already guard against, (3) rate limiting parity
with v3 if applicable, (4) no cross-tenant/cross-room media leak (should
inherit the same membership checks as v3 `download`/`thumbnail`, verify).

## Discovery context
Reported 2026-07-31, immediately after the upload-verb bugfix
(`bugfix-fix-matrix-media-upload-post-verb`) was merged and tested: user
uploaded a file successfully in Element, then got 404s trying to view it.
Root cause located via read-only investigation before this pipeline run.

## Dev Agent Record

### Implementation Plan

Followed the Dev Notes' preferred approach: extended the existing
`Nebu.Web.Router.Media` router (which already runs `OidcPlug` in its
pipeline) instead of introducing a new router module.

1. Added three new `get` route clauses to `server/lib/nebu/web/router/media.ex`
   — `/download/:server_name/:media_id/:file_name`,
   `/download/:server_name/:media_id`, `/thumbnail/:server_name/:media_id` —
   calling the exact same `Nebu.Media.download/3,4` and
   `Nebu.Media.thumbnail/3` functions the existing `/v3/...` clauses call.
   No handler code was touched.
2. Added `forward "/_matrix/client/v1/media", to: Nebu.Web.Router.Media` in
   `server/lib/nebu/web/router.ex`, placed directly after the existing
   `forward "/_matrix/media", to: Nebu.Web.Router.Media` and well before the
   generic catch-all `forward "/_matrix", to: Nebu.Web.Router.Protected` —
   Plug.Router matches top-down, so ordering before the catch-all is
   required for the new prefix to ever be reached.
3. Since `forward` strips the matched prefix from `conn.path_info` before
   dispatching, the new route clauses inside `Media` are defined as
   `/download/...` / `/thumbnail/...` (not `/v1/download/...`) — the `v1`
   segment is already consumed by the forward prefix
   `/_matrix/client/v1/media`. This differs slightly from the Dev Notes'
   literal route-pattern wording but is the combination that actually
   resolves the full public path
   `/_matrix/client/v1/media/download/:server_name/:media_id` correctly;
   verified green against all 13 ATDD tests.
4. No rate limiting was added to the new `v1` routes, matching the existing
   `v3` `download`/`thumbnail` clauses (only `upload` and `preview_url` carry
   explicit `RateLimit` plugs) — this preserves parity rather than adding an
   inconsistent new control.

### Completion Notes

- All 13 tests in `media_client_v1_routes_test.exs` pass (AC1–AC7 satisfied).
- Full `test/nebu/media/` directory: 40 passed, 0 failed — no v3 regressions
  (AC6 confirmed both by the story's own smoke tests and by the untouched
  `/v3/...` clauses in the diff).
- Full unit suite (`mix test --warnings-as-errors` in the
  `elixir:1.20-alpine` container, per `make test-unit-elixir`): 1594 passed,
  2 skipped, exit code 0 — no compiler warnings, no regressions from the new
  `forward` clause ordering in `router.ex`.
- `docs/matrix-api-scope.md`'s stale ✅ marks for these endpoints (flagged in
  Root Cause Analysis) were **not** touched by this story — left as a
  follow-up since it's documentation-only and out of the routing-fix scope.

### File List

- `server/lib/nebu/web/router/media.ex` — modified (added `v1` route
  clauses + moduledoc note; no existing `/v3/...` clauses changed)
- `server/lib/nebu/web/router.ex` — modified (added
  `forward "/_matrix/client/v1/media", to: Nebu.Web.Router.Media` before the
  `/_matrix` catch-all; no existing forwards changed)
- `server/test/nebu/media/media_client_v1_routes_test.exs` — pre-existing
  RED-phase ATDD test file (staged before this implementation), now green;
  not modified by this story

## Change Log

- 2026-07-31 — Implemented `v1` media download/thumbnail routes by
  extending `Nebu.Web.Router.Media` + adding one new `forward` in
  `router.ex`. 13/13 new tests green, 40/40 in `test/nebu/media/`,
  1594/1594 in the full suite. Status → review.
