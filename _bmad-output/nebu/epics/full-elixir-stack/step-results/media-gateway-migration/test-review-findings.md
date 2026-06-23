# Pre-Dev Test Review — media-gateway-migration

Gate result: **PASS** (0 MAJOR, 2 MINOR, 3 INFO).

All behavioral ACs (1,2,3,4,5,7) have >=1 meaningful, deterministic test. AC6 is infra
(compose removal, no test expected). SSRF no-fetch and Range byte/Content-Range assertions
are correct; AC4 asserts exact errcode + message. No hard waits, no real network/DB.

## Findings the dev agent MUST act on

- **MIN-1 (red-phase validity):** `media_download_test.exs` "unknown media -> 404 M_NOT_FOUND"
  may be a false-green: `NebuHttp.Router.Protected`'s `match _` already returns
  `404 {"errcode":"M_NOT_FOUND"}`. After implementing the media handler, ensure the
  media lookup path itself produces the 404 (not just the catch-all). Confirm it goes red
  before impl / green after for the right reason.
- **MIN-2 (red-phase validity):** The three 401 tests (M_MISSING_TOKEN, M_UNKNOWN_TOKEN,
  unauth download) assert the OidcPlug gate and are already green. They remain valid as a
  regression guard that media routes sit BEHIND OidcPlug. Therefore: download/thumbnail/
  preview_url MUST be on the authenticated (OidcPlug) pipeline. Upload too (AC1 requires auth).
- **INF-1:** `x-content-type-options: nosniff` is set globally in router.ex `security_headers/2`.
  Media-specific assertions still valid as regression guards.
- **INF-2:** AC7 asserts response contract (200/image-*/bytes>0), not pixel dimensions — OK.
- **INF-3:** Injected-boundary pattern (app-env module swaps) is the ADR-018-sanctioned seam.

## Implementation seams the tests expect (dev must honor)

App-env keys read by production code, swapped by tests:
- `:media_storage_module` (ExAws.S3) — `get/1`, `put/2`
- `:media_membership_module` — `member?/2` (LOCAL OTP call, replaces gRPC CheckMembership; AC2/AC4)
- `:media_db_module` — `lookup/2` (inline SQL on media_files per ADR-018)
- `:media_http_fetch_module` (Finch) — `fetch/1`; **SSRF guard runs in handler BEFORE this**
- `:media_max_upload_bytes` — upload size limit (413 M_TOO_LARGE)

Handler module: `NebuHttp.Media`, routed via `NebuHttp.Router.Media` forwarded from `router.ex`,
under the authenticated (OidcPlug) pipeline; download serves from in-memory AES-GCM-decrypted bytes.
