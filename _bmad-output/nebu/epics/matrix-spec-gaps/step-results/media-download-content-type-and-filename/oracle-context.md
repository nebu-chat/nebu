# Oracle context — media-download-content-type-and-filename (verified 2026-10-08 against bundled spec v1.18)
Finding "PDF served as octet-stream": FALSE (application/pdf is in @safe_inline_types); real deviations are worse (see below).

## Spec (GET /_matrix/client/v1/media/download/{serverName}/{mediaId}; v3 and /{fileName} equal)
- Content-Disposition (required since v1.12): MUST be inline or attachment, SHOULD contain a file name; SHOULD use inline if the Content-Type is on the inline allowlist else attachment; "If the upload was made with a filename, this header MUST contain the same filename. Otherwise, filename is excluded from the header."
- Content-Type: "The server MUST return a Content-Type which is either exactly the same as the original upload, or reasonably close." Reasonable: adding a charset to text/*; detecting HTML and using text/html instead of text/plain; application/octet-stream when the content type is obviously wrong; octet-stream when unknown/unprovided. "Actions not in the spirit of the above are not considered reasonable."
- Thumbnail: Content-Disposition MUST be inline, SHOULD contain a file name (e.g. thumbnail.png); Content-Type one of image/jpeg, image/png, image/apng, image/gif, image/webp; 400 if the server cannot thumbnail the content.
- Serving inline content: SHOULD restrict Content-Type to: text/css, text/plain, text/csv, application/json, application/ld+json, image/jpeg, image/gif, image/png, image/apng, image/webp, image/avif, video/mp4, video/webm, video/ogg, video/quicktime, audio/mp4, audio/webm, audio/aac, audio/mpeg, audio/ogg, audio/wave, audio/wav, audio/x-wav, audio/x-pn-wav, audio/flac, audio/x-flac. PDF is NOT on the list. "There is no risk in trusting the user-defined content type, as long as the Content-Disposition is calculated based on that type." Servers may respond with attachment to everything.
- Content repository intro: CSP SHOULD `sandbox; default-src 'none'; script-src 'none'; plugin-types application/pdf; style-src 'unsafe-inline'; object-src 'self';` and SHOULD `Cross-Origin-Resource-Policy: cross-origin` (v1.4).

## Nebu today (server/lib/nebu/media.ex)
- Upload normalizes to lowercase base type, strips parameters (base_content_type/base_type ~1224-1230, 1272); missing header -> application/octet-stream (~165, 375).
- Download: disposition_for/2 (~1210-1218) -> safe-inline types served as is with inline, everything else application/octet-stream + attachment; then put_resp_content_type(ct) (~1127, 1143) -> Plug appends "; charset=utf-8" to EVERY type.
- Filename: `file_name || media_id` (~540); DB.lookup does not read `filename` (media/db.ex ~53-55); sync upload stores filename nil (~235). Path {fileName} is inserted unescaped into filename="...".
- Thumbnails: original bytes returned; non-images labeled image/png; heic/avif/bmp originals violate the allowed list.
- Headers fine: CORP cross-origin (~1122,1134), CSP sandbox (~1123-1126, 1139-1142; no plugin-types), nosniff global (web/router.ex ~189-197), Range 206/416 (~1147-1197), 404/403/451 (ADR-026 deviates from spec 504 M_NOT_YET_UPLOADED on purpose).
- Upload blocklist (400): text/html, application/xhtml+xml, text/javascript, application/javascript, image/svg+xml, application/x-shockwave-flash.

## Table (upload type -> served now)
png/jpeg: image/x; charset=utf-8, inline, filename=<mediaId> | pdf: application/pdf; charset=utf-8, INLINE (SHOULD be attachment) | text/plain;charset=iso-8859-1: text/plain; charset=utf-8 (wrong) | audio/mpeg: +charset | audio/mp4, video/quicktime: octet-stream; charset=utf-8 attachment (MUST violation; should be inline original type) | zip, tar, heic: octet-stream (MUST violation of type; attachment correct) | octet-stream/none: ok except charset | thumbnails of pdf/zip: original bytes as image/png inline (wrong) .

## Decisions/risks for the story
- octet-stream fallback was a deliberate Stored-XSS defense (epic-12 security review HIGH-3, docs/stories/phase2/epic-12/12-7 AC3-6, 08-concepts ~l.1102-1103). Spec model: trust type, compute disposition from it. No conflict as long as attachment + CSP sandbox + nosniff + CORP + upload blocklist stay. Keep mapping legacy renderable types (text/html, xml, svg, js...) to octet-stream.
- Out of scope: 502 M_TOO_LARGE, thumbnail 413, 504 vs 451, 304/ETag, CSP plugin-types.
