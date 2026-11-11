# Oracle context (spec v1.18) — media-download-451-scan-race
- `timeout_ms` on all 6 media endpoints (v1 download, download+fileName, thumbnail; legacy v3 equivalents): client's max wait if content not yet uploaded; DEFAULT 20000 ms. Server SHOULD cap, MAY respond early.
- After wait still unavailable: spec = 504 M_NOT_YET_UPLOADED. 451 is NOT in the CS spec (Nebu deviation; out of scope, ADR-026).
- Thumbnail has no exception: must stall like download.
- Tests required: absent+released mid-window → 200 (download/thumbnail, v1/v3); absent+never released → errcode M_NOT_YET_UPLOADED after window; timeout_ms=0 immediate; > max clamped; malformed (Nebu choice, document); already released no wait; unknown id 404 no wait; unauth v1 → 401 before stall; thumbnail edges unchanged (400/413/429).
