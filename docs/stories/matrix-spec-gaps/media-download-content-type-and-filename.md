---
story_id: media-download-content-type-and-filename
title: "Bug: media download/thumbnail rewrite Content-Type, drop the upload filename and mislabel thumbnails"
type: bug
severity: medium
epic: matrix-spec-gaps
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-08
branch: bugfix/media-response-content-type
---

## Summary

Origin: pflichten-audit v1.11→v1.15 ("Content-Type is rewritten, charset appended"). Oracle verification (2026-10-08, see
`_bmad-output/nebu/epics/matrix-spec-gaps/step-results/media-download-content-type-and-filename/oracle-context.md`): the finding is partly
wrong (PDF is NOT octet-stream: `application/pdf` is in `@safe_inline_types`) but the real state is worse. Spec v1.12+: the download
Content-Type MUST be "exactly the same as the original upload, or reasonably close"; Content-Disposition MUST be inline|attachment and, if the upload
had a filename, MUST contain the same filename.

Real deviations in `server/lib/nebu/media.ex`:
1. **MUST:** `disposition_for/2` (~l.1210) rewrites every Content-Type not in `@safe_inline_types` to `application/octet-stream`
   (audio/mp4, video/quicktime, application/zip, image/heic, ...). The spec's inline allowlist steers only the DISPOSITION, never the Content-Type.
2. `put_resp_content_type/2` (~l.1127, 1143) appends `; charset=utf-8` to EVERY type (spec only allows adding a charset to text/*; wrong charset for non-UTF-8 text).
3. **MUST:** the upload filename is never delivered: `Nebu.Media.DB.lookup` does not read the `filename` column, the sync upload stores `filename` as nil, the
   response uses `file_name || media_id` (~l.540). Without a filename the `filename` parameter must be excluded.
4. Thumbnails: Nebu returns the ORIGINAL bytes; for non-images (PDF, zip) they are labeled `image/png; charset=utf-8` and disposition inline; heic/avif/bmp originals violate the allowed thumbnail types.
5. SHOULD: `application/pdf` is served inline although it is not on the spec's inline list (should be attachment). The inline list should match the spec.
6. Robustness: the filename is put unescaped into `filename="..."` (quote breaks the header, non-ASCII raw, no `filename*=`).

Security context: the octet-stream fallback is a deliberate Stored-XSS defense (Epic 12 security review HIGH-3, `docs/stories/phase2/epic-12/12-7-*.md` AC3-6,
`docs/architecture/08-concepts.md` ~l.1102). The spec supports a different model: trust the user-defined type as long as the disposition is computed from it.
Defense in depth stays: attachment for everything not on the inline list, CSP sandbox, global `X-Content-Type-Options: nosniff`, CORP, upload blocklist.

## Story

As a user of Element or FluffyChat,
I want media to be delivered with its real Content-Type and original filename,
so that downloads, audio/video playback and file names work and the server honors the Matrix content repository contract.

## Acceptance Criteria

**AC1 — Content-Type is preserved (MUST):**
Download (`/_matrix/client/v1/media/download/...` incl. `/{fileName}`, legacy `/_matrix/media/v3/download/...`) returns the stored upload Content-Type unchanged (base type;
no charset appended for non-text types, no `application/octet-stream` rewriting for types such as audio/mp4, video/quicktime, application/zip, application/x-tar, image/heic).
Reasonable adjustments only as the spec allows: `application/octet-stream` for missing/unparseable types (no `/`), no charset parameter appended anywhere except
for text/* where the ORIGINAL upload declared one (store and return the original charset parameter for text/*, or return the bare type; never a wrong `utf-8`).
`put_resp_content_type(..., nil)` (no automatic charset).

**AC2 — Disposition follows the spec inline list:**
`inline` only for the spec's allowlist: text/css, text/plain, text/csv, application/json, application/ld+json, image/jpeg, image/gif, image/png, image/apng, image/webp, image/avif,
video/mp4, video/webm, video/ogg, video/quicktime, audio/mp4, audio/webm, audio/aac, audio/mpeg, audio/ogg, audio/wave, audio/wav, audio/x-wav, audio/x-pn-wav, audio/flac, audio/x-flac.
Everything else (including application/pdf, zip, octet-stream) → `attachment`. Disposition is computed from the type actually served.

**AC3 — Renderable types stay neutralized (defense in depth):**
Legacy rows or types that browsers render as active content (text/html, application/xhtml+xml, text/xml, application/xml, image/svg+xml, text/javascript, application/javascript, application/x-shockwave-flash)
are served as `application/octet-stream` with `attachment` (spec: "obviously wrong"/HTML detection). The upload blocklist (400) is unchanged.

**AC4 — Filename (MUST):**
The upload `filename` (query parameter) is persisted for both the sync and the async/reserved upload paths and read back by `Nebu.Media.DB.lookup`.
`Content-Disposition` carries, in priority order: the `{fileName}` path segment of the request, the stored upload filename; if neither exists NO `filename` parameter at all (never the media_id).
Encoding: ASCII-safe `filename="..."` with `"` and `\` escaped plus `filename*=UTF-8''<percent-encoded>` for non-ASCII; CR/LF and control characters can never reach the header (header injection).

**AC5 — Thumbnails:**
Thumbnail responses are only served when the stored content is one of the spec's thumbnail types (image/jpeg, image/png, image/apng, image/gif, image/webp) and carry exactly that Content-Type with `inline`
and a filename (e.g. `thumbnail.png`, extension matching the type). Anything else (PDF, zip, heic, avif, bmp, audio, video) → `400 M_UNKNOWN`
(spec: "the server cannot thumbnail the content"). Never relabel non-images as image/png.

**AC6 — No regression:**
`X-Content-Type-Options: nosniff` (global), the CSP (sandbox ...) and `Cross-Origin-Resource-Policy: cross-origin` headers, 404 M_NOT_FOUND, 403 M_FORBIDDEN (membership), 451 stall behavior (ADR-026), Range 206/416, Content-Length, authenticated v1 route behavior and
all existing media tests stay green (adapt only tests that pinned the old octet-stream/charset/media_id behavior, and say so).

**AC7 — Docs:**
`docs/architecture/08-concepts.md` (~l.1102 "Prevents inline rendering of pre-allowlist uploads" and the media download section), the arc42 building-block text, and `docs/stories/phase2/epic-12/12-7-*.md`-referenced behavior are updated to the new model. Do NOT rewrite the old security review (audit trail); add a note in the Dev Notes.

## Acceptance Tests

- Upload then download for each of: image/png, image/jpeg, image/heic, audio/mpeg, audio/mp4, video/mp4, video/quicktime, application/pdf, application/zip, application/x-tar, text/plain (with and without charset), text/csv, application/json, no Content-Type → exact Content-Type and disposition per AC1/AC2 (table-driven).
- Legacy/rendered types (stored directly in the DB): text/html, svg → octet-stream + attachment.
- Filename: `?filename=a b.pdf`; `{fileName}` path overriding; none → no filename param; names with `"`, non-ASCII, CR/LF → correctly encoded / rejected; filename survives async upload + scan path.
- Thumbnail: png/jpeg/webp/gif → same type + inline + filename; pdf/zip/heic → 400.
- Headers regression: nosniff, CSP, CORP, 404, 403, 451, 206, 416.

## Dev Notes

- Oracle: `_bmad-output/nebu/epics/matrix-spec-gaps/step-results/media-download-content-type-and-filename/oracle-context.md`. Code: `server/lib/nebu/media.ex` (@safe_inline_types ~37-48, upload content-type handling ~82/165/375, store_upload/create_and_store ~205-245, download ~1100-1230, disposition_for ~1210, filename ~540, thumbnail ~632), `server/lib/nebu/media/db.ex` (lookup ~53-55), `server/lib/nebu/web/router/media.ex`, `client_v1_media.ex`.
- A migration is only needed if the `filename` column does not exist/needs changes (check `media` table DDL); next free migration number, verify at merge (parallel pipelines add migrations).
- Out of scope (Oracle notes): 502 M_TOO_LARGE, thumbnail 413, 504-vs-451 stall status (ADR-026 is a deliberate deviation), ETag/304, CSP `plugin-types`.
- This story deliberately changes the deliberate Epic-12 HIGH-3 octet-stream behavior; Kassandra must re-confirm that the combination attachment + CSP sandbox + nosniff + CORP + blocklist is sufficient.

### Implementation notes (dev)

- Behavior change is deliberate: the Epic-12 security review (HIGH-3, `docs/stories/phase2/epic-12/12-7-*.md` AC3-6) mandated octet-stream for everything off the allowlist. Not rewritten (audit trail). New model per the Matrix spec: trust the stored type, compute the disposition from it; defense in depth = attachment + CSP sandbox + `nosniff` + CORP + upload blocklist + neutralization of active-content types at download.
- Stored type is always the base type (the upload strips parameters), served bare; text/* therefore never gets a wrong charset.
- Filename: sync upload now persists `?filename=`; `Nebu.Media.DB.lookup/2` reads `media_files.filename` (no migration; column from 000025). Control characters (C0, DEL, C1, U+2028/9) are stripped (sanitize, never 400/500); invalid UTF-8 keeps only printable ASCII; name empty after sanitizing -> no `filename` parameter. Non-ASCII -> `filename="<ascii with _>"; filename*=UTF-8''<pct>`.
- Thumbnail: type check follows the membership check (403 before 400).
- Test adaptation: `media_download_gzip_decompression_test.exs` `to_map/1` fixture gained the 14th (`filename`) column.
- Out of scope (unchanged): 502 M_TOO_LARGE, thumbnail 413, 504 vs. 451, ETag/304, CSP `plugin-types`, real thumbnail resizing.

### Review cycle 1 notes (dev)

- Neutralization is by category (`neutralize?/1`: exact list, any `+xml`, `text/xsl`, `multipart/x-mixed-replace`, WHATWG JS family, wasm, `text/x-component`, `text/cache-manifest`). The JS family is NOT added to the upload blocklist (legitimate to share; download neutralizes, legacy rows included).
- Filename: `query_filename/1` is shared by sync and async upload (non-binary/empty -> nil, 255-byte codepoint-safe cap); output sanitizer strips Unicode `Cf` (bidi/invisible) and caps at 255 bytes; the admin list uses `Nebu.Media.display_filename/1`; `?filename=` is redacted in DEBUG query-string logs.
- WATCH-FLAG (Kassandra F-4): this design relies on ALL media routes accepting only the `Authorization: Bearer` header (OidcPlug). Any change adding `?access_token=`, cookie auth or unauthenticated v3 media MUST re-trigger the security review (JS-typed uploads would become same-origin scripts; Admin UI CSP `script-src 'self'`).
- Follow-up bugfix (Kassandra N-1 LOW, pre-existing, out of scope): the `{fileName}` path segment is stored verbatim in `operational_logs.route_template`/`path` (`server/lib/nebu/web/log_store/route_normalizer.ex` ~80-86 `@anchor_rules`). Add `"download" => %{2 => ":media_id", 3 => ":file_name"}` and a media_id rule for `thumbnail`.
- Documented trade-off: Unicode `Cf` stripping in filenames intentionally also removes ZWJ/ZWNJ/soft hyphen (affects emoji ZWJ sequences and Persian names); accepted to block bidi/invisible spoofing.
- Request logging: the `filename` query param is masked even when its NAME is percent-encoded (`?fil%65name=`), since Plug decodes names (review MIN-1).
