## Security Review — media-download-content-type-and-filename (epic: matrix-spec-gaps)

**Diff scope:** staged diff on `bugfix/media-response-content-type`: `server/lib/nebu/media.ex` (download Content-Type passthrough, spec inline list, `@neutralized_types`, `content_disposition/2` + `sanitize_filename/1`, sync-upload filename persistence, thumbnail type allowlist), `server/lib/nebu/media/db.ex` (`@sql_lookup` + `to_map/1` gain `filename`), tests, architecture docs, story file.
**Date:** 2026-10-08
**Reviewer:** Kassandra (OWASP ASVS L2, STRIDE, CWE-79/116/113/434/918)
**Context:** this story deliberately replaces the Epic-12 HIGH-3 model ("octet-stream + attachment for everything not allowlisted", `_bmad-output/implementation-artifacts/epic-12-security-review-2026-05-12.md` Finding #3) with the Matrix v1.12+ model: trust the stored type and compute the disposition from it.

### Verdict on the core question

The new defense-in-depth combination is **sufficient on the server side** for this deployment topology:

1. **Load-bearing premise (verified):** every media route (`/_matrix/media/v3/*` and `/_matrix/client/v1/media/*`) sits behind `OidcPlug`, which accepts **only** `Authorization: Bearer` (`oidc_plug.ex:324-328`). There is no cookie auth, no `?access_token=` query auth, and no unauthenticated legacy v3 download. A browser therefore can never load a media URL through top-level navigation, `<script src>`, `<link rel=stylesheet>`, `<iframe>`, a Worker or a ServiceWorker without the client's bearer token. The "user opens the URL directly" scenario returns 401 before any bytes are sent.
2. Even if this premise ever failed: `Content-Disposition: attachment` blocks rendering on navigation for every type that is not on the inline list. `CSP: sandbox; default-src 'none'; script-src 'none'` gives any rendered document an opaque origin and no script execution. Global `nosniff` (`web/router.ex:196`) stops HTML sniffing of spoofed types, so a declared `image/png` containing HTML bytes renders as a broken image and never as HTML.
3. **Inline types:** `text/plain`, `text/css`, `text/csv`, `application/json`, `application/ld+json`, `image/{jpeg,gif,png,apng,webp,avif}`, `video/*` and `audio/*` from the list are all passive documents under navigation. With nosniff + sandbox none of them can become an active HTML/script context.
4. **Normalization is robust:** the served value is exactly the normalized `base_type/1` output (split on `;`, `String.trim`, `String.downcase`). It is then checked against a strict RFC 7231 token regex (`media.ex:1261`, `\A...\z`) before being echoed. Tab and whitespace padding are trimmed before the list lookup. Embedded space, NUL, comma, CR/LF and double `/` fail the regex and fall back to octet-stream. Parameters and case are normalized away. Unicode case folding (for example U+212A KELVIN SIGN to `k`) only converges toward the list. Because the browser receives exactly the string Nebu checked, there is no parser differential, and header injection through Content-Type is impossible.
5. **Writers:** only three paths write `content_type`: the sync upload (`base_content_type/1`), the async upload (`base_content_type/1` -> `persist_upload`), and the reservation genesis (`''`, which falls back to octet-stream). There is no federation, bridge or legacy `DB.insert` caller. Old rows were also stored as base types, and download re-normalizes anyway.
6. **Epic-12 #3 required acceptance tests still hold:** text/html -> octet-stream + attachment + nosniff (neutralized at download and still blocked at upload), svg blocked at upload, png inline with its type preserved, nosniff on every response.

The remaining residual risk sits **client-side**: clients that fetch with a bearer token and re-wrap the bytes into a `blob:` URL carrying the response type. That residual drives F-1.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/media.ex:53-56` (`@neutralized_types`), used at `:1253` | CWE-79 defense in depth: the neutralization list is an exact-match enumeration and misses whole WHATWG "XML MIME type" and "JavaScript MIME type" families. These are now served with their real type where they were previously served as octet-stream. | Neutralize by **category**, not by enumeration (see detail). Add tests. |
| 2 | LOW | `server/lib/nebu/media.ex:1289` (`sanitize_filename/1`); stored raw at `:232` / `:431`; displayed raw in `admin/media_live.ex:951` | CWE-451 download/filename spoofing: Unicode bidi and invisible format characters (U+202E RLO, U+202A-202D, U+2066-2069, U+200E/200F, U+061C, U+200B-200D, U+FEFF) are not stripped. | Also reject the bidi/format code points (or all of general category Cf) in `sanitize_filename/1`. Apply the same normalization when the admin list displays the name. |
| 3 | LOW | `server/lib/nebu/media.ex:232-237`, `:431` (persist); `:1268-1281` (emit) | CWE-400/CWE-770: the upload filename is persisted with no length limit (TEXT) and echoed in the response header, percent-encoded (about 1.3-3x growth). Names of about 10 KB give 13-30 KB Content-Disposition headers. Reverse proxies with 4-8 KB `proxy_buffer_size` then return 502 for that media to **every** room member. | Cap at the write boundary (for example 255 bytes after sanitizing, truncated on a codepoint boundary) on both upload paths, and cap again on output (path-segment `{fileName}` included). |
| 4 | INFO | `server/lib/nebu/web/plugs/oidc_plug.ex:324-328` | The sufficiency verdict depends on Bearer-only auth for media. If a future story adds `?access_token=` query auth or unauthenticated legacy v3 media (both allowed by the spec), F-1's JS-family types become a **same-origin `script-src 'self'` gadget** for the Admin UI (same Bandit origin, `admin/router.ex:86-92`). Spec-mandated `text/css` inline also becomes a `style-src 'self'` gadget. | Register as a watch-flag: any change to media authentication must re-run this review. Fixing F-1 removes the script half. |
| 5 | INFO | `server/lib/nebu/web/plugs/request_logger.ex:181,306` | `?filename=` (possibly personal data) appears in the DEBUG-level `query_string` capture, which redacts only the access token. This is pre-existing: clients already sent `?filename=` on sync upload, and the async path already persisted it. No delta from this diff. | Optional: add `filename` to the `PayloadRedactor` query-param redaction set, per the No-Sensitive-Data-in-Logs law. |
| 6 | INFO (positive) | `media.ex:1268-1307`, `:657-667` | Header encoding verified correct. Thumbnail fix verified. PDF change is a hardening gain. | No action needed. |

### Detail

**Finding #1 — Neutralization list incomplete for XML/JS MIME families** [MEDIUM]

`disposition_for/1` neutralizes only these 8 exact base types: `text/html`, `application/xhtml+xml`, `text/xml`, `application/xml`, `image/svg+xml`, `text/javascript`, `application/javascript`, `application/x-shockwave-flash`. Upload blocks only 6 of them. Every other type now passes through **with its real type** + `attachment`. Before this story such types were rewritten to `application/octet-stream`.

Types browsers treat as active content that now pass through:
- **XML MIME type** (WHATWG: any `*/*+xml`, plus `text/xml` and `application/xml`). Browsers render these as XML documents in which XHTML-namespace `<script>` runs. Passing through: `application/rss+xml`, `application/atom+xml`, `application/mathml+xml`, `application/xslt+xml`, `application/vnd.wap.xhtml+xml`, `application/rdf+xml`, `image/svg+xml-compressed`, and so on. `text/xsl` is also treated as XML by Firefox.
- **JavaScript MIME type** (WHATWG list): `application/ecmascript`, `application/x-ecmascript`, `application/x-javascript`, `text/ecmascript`, `text/javascript1.0`-`1.5`, `text/jscript`, `text/livescript`, `text/x-ecmascript`, `text/x-javascript`. With nosniff, a browser executes these as `<script>`/Worker/ServiceWorker sources. Previously octet-stream blocked that.
- `multipart/x-mixed-replace`, which has a history of CSP/nosniff bypass bugs in Firefox.

Exploitability today: the server-side headers do not reach a client-made `blob:` URL. A client that downloads with its bearer token and opens `URL.createObjectURL(new Blob([bytes], {type: response.headers['content-type']}))` in a tab or iframe executes the payload **in the client's origin**. That means a stored XSS against the chat client, triggered by any room member. Element Web defends itself (`getBlobSafeMimeType` allowlist), but Nebu cannot vouch for every client, and its compliance positioning previously gave server-side protection here. This requires a naive client in the chain, so MEDIUM, not HIGH. It is not blocking. Also see F-4 for the latent same-origin escalation.

Fix (a few lines, keeps spec compliance, because the spec allows "reasonably close" or octet-stream for obviously dangerous types):
```elixir
defp neutralize?(base) do
  base in @neutralized_types or
    String.ends_with?(base, "+xml") or
    base in ~w(text/xsl multipart/x-mixed-replace) or
    base in @js_mime_types   # full WHATWG JavaScript MIME type essence list
end
```
Use `neutralize?/1` at `media.ex:1253`. Add a table-driven test over the families. Optionally add the JS family to `@blocked_upload_types` too. Keep the two lists from drifting by deriving the upload blocklist from the same source.

**Finding #2 — Bidi/format characters survive filename sanitizing** [LOW]

`sanitize_filename/1` strips C0, DEL, C1 (including U+0085 NEL) and U+2028/2029. That fully closes header injection (CWE-113): the ASCII path is 32..126 with `"`/`\` escaped, and the non-ASCII path is percent-encoded. It does not strip U+202E and related characters, so `invoice‮fdp.exe` is offered for download as "invoiceexe.pdf". Chrome and Firefox partly sanitize download names themselves, but native clients, save dialogs and the Admin media list (raw `row.filename`, `media_live.ex:951`, HEEx-escaped so there is no XSS) display the spoofed name. The uploader controls the name either way (the `m.file` body), so the impact is social engineering only. Fix: add `0x061C`, `0x200B..0x200F`, `0x202A..0x202E`, `0x2066..0x2069`, `0xFEFF` to the reject set (or reject `\p{Cf}`). For the admin UI, render the same sanitized value.

**Finding #3 — Unbounded filename length reflected into the response header** [LOW]

This was pre-registered as a watch-flag by the 2b review ("persisted but not yet reflected"). This story turns the sink on. Escaping is now correct (that half of the watch-flag is closed), but the length bound was never added. Bandit's request-line limit (about 10 KB) is the only cap. The impact is availability of the attacker's own media for every recipient behind a small-buffer proxy, and storage bloat. Fix: truncate to 255 bytes (codepoint-safe) in `query_filename/1` and at `upload_async` `:431` (unify both on `query_filename/1`, which also maps `""` to nil consistently), and in `content_disposition/2` for the `{fileName}` path segment.

**Finding #6 — Verified-correct items (no action)**
- RFC 6266/5987: `filename="<ascii, \" and \\ escaped>"; filename*=UTF-8''<URI.char_unreserved? pct>`. Percent-encoding is a superset of the RFC's attr-char requirement, so the output is valid. Invalid UTF-8 is reduced to printable ASCII. A name that is empty after sanitizing produces no `filename` parameter, and the media_id is never used as the name. Plug.Router decodes `%0D%0A` in the `{fileName}` segment, and the sanitizer strips the result.
- Thumbnail: exact 5-type map, served as the stored base type, with an inline `thumbnail.<ext>` name. Everything else gets 400 M_UNKNOWN **after** the membership check (no type oracle for non-members). This resolves the forward-flag from the 2026-08-27 review ("thumbnail uses bare `image/` prefix"). Pixel-flood risk is unchanged: original bytes, no decoder or resizer.
- PDF moved from inline to attachment: a net hardening gain, since embedded PDF viewers no longer render inline.
- 404/403/451 (ADR-026 stall), Range 206/416, CORP `cross-origin`, the CSP string and nosniff are unchanged. The diff changes only the `serve_bytes` arguments and the header builder.
- No new route, migration, SQL interpolation (both SELECT and UPDATE are parameterized; the column comes from 000025), secret or audit action. No `raw(`/`{:safe` in the admin media view.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 — advisory, address before epic end (F-1, recommended in this story because it is a few lines)
LOW: 2 — advisory
INFO: 3

**Verdict:** APPROVED (CLEAN — no CRITICAL/HIGH). The deliberate replacement of the Epic-12 HIGH-3 model is security-sound **given Bearer-only media auth**. F-1 restores the strength of the old model for the XML/JS families at near-zero cost.

---

## Delta check 2026-10-08 (cycle 1, `git diff --staged`)

| # | Original | Status | Verification |
|---|----------|--------|--------------|
| F-1 | MEDIUM | **CLOSED** | `neutralize?/1` (`media.ex:1306-1309`): exact list, any `+xml` suffix (covers `application/xhtml+xml`, rss/atom/mathml/xslt/rdf, `vnd.wap.xhtml+xml`, `image/svg+xml`), `text/xsl`, `multipart/x-mixed-replace`, the full WHATWG JS essence list (16 entries) plus `application/wasm`, `text/x-component`, `text/cache-manifest`. It runs on `base_type/1` (split `;`, trim, downcase), so case and parameter variants (`TEXT/HTML; x`) are neutralized. Unparseable types (`valid_media_type?/1`, RFC 7231 token regex with `\A..\z`) become octet-stream. Sink check: `serve_bytes/4` is the only path that serves the stored type, and the thumbnail path uses an exact 5-type map. Residual types served with their real type + `attachment` (`image/svg+xml-compressed`, `text/vtt`, `text/markdown`, `font/*`, `application/pdf`, `application/x-msdownload`) are not executed by browsers as script or document under nosniff + `attachment` + CSP sandbox. A download-and-run exploit is a user action, not stored XSS, so out of scope. Not blocking JS at upload is **defensible**: there is a single sink, it neutralizes both new and legacy rows, and sharing `.js`/`.wasm` files is legitimate. The condition is F-4 (Bearer-only). |
| F-2 | LOW | **CLOSED** | `sanitize_filename/1` strips C0, DEL, C1 and U+2028/2029, then `~r/\p{Cf}/u`. Cf includes U+061C, U+200B-200F, U+202A-202E, U+2060-2064, U+2066-2069, U+FEFF, U+00AD, U+180E, U+FFF9-FFFB and the tag characters U+E0001/U+E0020-E007F. Order is sanitize, then cap, then trim. An empty result gives `nil`, which means no `filename` parameter. An empty path segment falls back to the stored name. The admin list uses `display_filename/1` (same function) and falls back to the media_id. Residual (INFO, no action): non-Cf invisible padding (U+3164/U+115F Hangul fillers, U+2800, variation selectors) survives. It cannot reorder text, so it is not spoofing-equivalent. |
| F-3 | LOW | **CLOSED** | `query_filename/1` (255 B, codepoint-safe, drops invalid UTF-8, maps map/list/`""` to nil) is used on **both** sync (`:243`) and async (`:473`) uploads. The output cap in `sanitize_filename/1` also covers the `{fileName}` path segment and legacy uncapped rows. Worst-case header: `filename="<=255"` + `filename*=UTF-8''<=765` is about 1.05 KB, so no proxy-buffer DoS. |
| F-4 | INFO | **CLOSED (documented)** | Watch-flag row added in `08-concepts.md`. Auth is unchanged in this diff (no new auth mode or route). The Bearer-only assumption still holds. |
| F-5 | INFO | **CLOSED** (query string) | `redact_query_style(@content_query_keys, @message_content)` runs on the DEBUG `query_string` capture. The value regex `[^&\s"']*` matches a raw (percent-encoded) query in full. No `Logger.*` call in `media.ex` interpolates the filename. The scan worker audit metadata (`media_scan_worker.ex:359`) carries the filename **by compliance design** (pre-existing, audit not log). It is HEEx-escaped in the admin UI. See N-1 for the remaining path-segment leak. |

### New findings

| # | Severity | Location | Issue | Recommendation |
|---|----------|----------|-------|----------------|
| N-1 | LOW (pre-existing, not introduced by this diff) | `server/lib/nebu/web/log_store/route_normalizer.ex:80-86` (`@anchor_rules`), used in `request_logger.ex:69,102` | The `{fileName}` segment of `/download/{server}/{mediaId}/{fileName}` is not normalized. The downloader-chosen name is persisted verbatim at **INFO** in `operational_logs.route_template` and `path`. The media_id is also kept, because it is not hex >= 32. This touches the No-Sensitive-Data-in-Logs law. It was already reachable before this story (`file_name \|\| media_id`). | Add `"download" => %{2 => ":media_id", 3 => ":file_name"}` (and the same for `"thumbnail"` media_id) in a follow-up. This is not blocking for this story. |
| N-2 | INFO | `media.ex:1338-1346` | New-surface check. `\p{Cf}` and charlist reject are linear, bounded by Bandit's request line (about 10 KB) for the path segment and by 255 B for stored names. No backtracking construct, so no ReDoS. `display_filename/1` is a pure public wrapper with no logging. Admin output is HEEx-escaped (no `raw`). | None. |

### Final classification

CRITICAL: 0 · HIGH: 0 · MEDIUM: 0 · LOW: 1 (N-1, pre-existing) · INFO: 1

**Classification: CLEAN.** All original findings F-1 to F-5 are closed. The diff can be committed.
