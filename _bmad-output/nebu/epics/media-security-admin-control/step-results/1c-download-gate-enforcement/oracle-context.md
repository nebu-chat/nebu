## Endpoints / MUST requirements
- `GET /_matrix/client/v1/media/download/{serverName}/{mediaId}` (+ `/{fileName}`) — auth required, v1.11
- `GET /_matrix/client/v1/media/thumbnail/{serverName}/{mediaId}` — auth required, v1.11
- Deprecated (unauth, frozen post-v1.12): `/_matrix/media/v3/download/...`, `/_matrix/media/v3/thumbnail/...`
- 200 MUST: `Content-Disposition` header **Required** since v1.12 (inline/attachment)
- 200 MUST: `Content-Type` header **Required** since v1.12, MUST be exact-or-reasonably-close to original upload
- Error body MUST always contain `errcode` + `error` (common error format)
- `timeout_ms` query param — client's long-poll wait budget for not-yet-available content (default 20000ms)

## Spec-defined error codes / status pairing
- `M_NOT_YET_UPLOADED` — spec pairs this with **HTTP 504**, on both v1 auth and deprecated v3 download endpoints. `451` does **not** appear anywhere in the CS API v1.18 media section.
- `M_NOT_FOUND` — "common error code" (§Common error codes); spec mandates **no fixed HTTP status** — explicitly says clients should trust errcode over status code (§Standard error response).
- Deprecated v3 download/thumbnail: "MAY return `404 M_NOT_FOUND` for media which exists, but is after the server froze unauthenticated media access" (v1.11) — spec precedent for an intentional "looks like 404" response to a real-but-inaccessible file.
- v1 auth endpoint's own response table: only 200/307/308/429/502/504 enumerated — 404 not catalogued there (not forbidden, just not listed).
- `429 M_LIMIT_EXCEEDED` + `retry_after_ms`; `502 M_TOO_LARGE` — generic, unrelated to lifecycle gating.

## Verdict on the story's ACs
- AC1/AC2 (451) — spec-safe (errcode-first client behavior) but a **deliberate deviation** from the documented 504 pairing for `M_NOT_YET_UPLOADED`. Not a compliance bug; flag so nobody "fixes" it back to 504 later. (Story references ADR-026 for this decision.)
- AC2/AC3 (identical body, status-only difference) — matches the spec's own precedent (frozen-media 404 lie) and the "trust errcode not status" principle.
- AC4 — no-regression requirement covers two **Required** headers (Content-Disposition, Content-Type) plus SHOULD headers (CSP, `Cross-Origin-Resource-Policy: cross-origin`) — CSP/CORP were a known gap in the old Go handlers; must-verify the Elixir port carried them forward.
- AC5/AC6 (allow-list, deny-by-default) — `media_files.state` has **no spec correlate**; CS API doesn't model upload/scan lifecycle states. This is implementation-safety guidance, not a spec compliance requirement — nothing to test-cover from the spec side beyond "the 200 path must still emit the Required headers."
- AC7 (gate before storage fetch) — pure implementation ordering, not spec-observable.
