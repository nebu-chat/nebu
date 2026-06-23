# Code Review — media-gateway-migration (cycle 0)

MAJOR/CRITICAL: 0. MINOR: 4 (F1-F4). INFO: 6. CI green (nebu_http 68 pass).
Per pipeline cycle rule, MINOR findings auto-cycle back to dev.

## MINOR — fix these

- **F1 (media.ex:365-366) — partial upload accepted as success.** `read_full_body`
  `{:error, _} -> {:ok, acc, conn}` treats a transport read error as a complete body:
  a truncated/aborted upload gets encrypted, stored, and returns 200 with a valid mxc
  for corrupt data. FIX: on read_body `{:error, reason}` return an error tuple and have
  `upload/1` respond 400 (or 502) instead of persisting a partial object.

- **F2 (ssrf.ex + http_fetch.ex) — DNS-rebinding TOCTOU.** `SSRF.check/1` resolves+checks
  all addresses, but `Finch.request` re-resolves the host at connect time, so a DNS server
  returning a public IP to the guard and a private IP to Finch defeats the check. FIX:
  resolve once in the guard, pass the validated IP(s) to the fetch, and connect by IP
  (Finch `:conn_opts`/host-pinning or rewrite URL host to the checked IP with Host header).
  Also correct the moduledoc claim. Hard to exploit but a genuine residual SSRF gap.

- **F3 (media.ex upload + router.ex JsonBody/Plug.Parsers) — JSON-content-type upload
  body consumed by Plug.Parsers.** An upload with `Content-Type: application/json` is parsed
  (and 1MB-capped) by the top-level `Plug.Parsers` before reaching `Media.upload`, whose
  `read_body` then sees an empty body and stores a zero-byte file returning 200. FIX:
  validate non-empty body in upload (reject empty/zero-length with 400), and/or ensure the
  media upload path is not subject to the JSON parser consuming its body (the handler must
  not rely on content-type-dependent body availability). Reject empty uploads explicitly.

- **F4 (media.ex:198 / db.ex:97 / membership.ex:44) — production room-scoping degraded.**
  `DB.to_map` always sets `room_id: nil` so production always calls `member?(nil, user)` =
  "member of any room": any authenticated user in >=1 room can download any media id. This
  is the documented MVP schema limitation (media_files has no room_id), fail-closed, and
  stricter than Matrix spec (unauth media). Reviewer classified MINOR. ACTION: keep behavior
  (schema cannot scope per-media without a follow-up linkage) but make the limitation explicit
  — confirm the moduledoc/story note is accurate, and ensure the zero-room denial path is
  tested. A true per-media room link is an accepted follow-up (note for security-review).

## INFO (no action required; do not regress)
- F5 suffix/multi-range degrade to 200 (acceptable MVP).
- F6 SSRF missing TEST-NET/NAT64 ranges (low value).
- F7 http_fetch moduledoc redirect-count claim is drift (Finch doesn't follow redirects — safe).
- F8 thumbnail no-resize (pre-cleared deviation).
- F9 error responses don't leak storage/DB detail (good).
- F10 blocked-content-type returns M_BAD_JSON errcode (cosmetic).

## Verified correct (do not re-litigate)
Crypto Go-parity (ct||tag, tag verified, fresh key/nonce per upload); Range off-by-one +
416 + Accept-Ranges; all routes behind OidcPlug; parameterized SQL, opaque random media_id
(no path traversal/SQLi); AC6 compose wiring; ADR-018 inline-SQL + injected boundaries.
