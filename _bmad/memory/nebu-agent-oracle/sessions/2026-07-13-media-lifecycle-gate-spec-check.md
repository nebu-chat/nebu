# Session 2026-07-13 — media-security-admin-control: download/thumbnail lifecycle gate

Asked (by nebu-pipeline dev step, headless-style query) for spec grounding on a story that gates
`GET .../media/download` + `.../thumbnail` on `media_files.state` before streaming bytes:
AC1 pending states → 451 M_NOT_YET_UPLOADED, AC2 admin_blocked → 451 M_NOT_FOUND (body identical
to 404), AC3 terminal-negative → 404 M_NOT_FOUND, AC4 :released → 200, AC5 allow-list not deny-list,
AC6 unknown states → deny (451), AC7 gate before storage fetch.

## Key finding: 451 is NOT a Matrix spec status

Grepped `client-server-api/index.html` for `451` — zero real hits (only a false-positive timestamp
substring). The spec pairs `M_NOT_YET_UPLOADED` with **HTTP 504** in the response tables for both
`GET /_matrix/client/v1/media/download/{serverName}/{mediaId}` (line ~32070) and the deprecated
`/_matrix/media/v3/download/...` (line ~33494) — "The content is not yet available" → 504, not 451.
`timeout_ms` query param (default 20000ms) exists specifically so clients long-poll this 504 case.

`M_NOT_FOUND` is a "common error code" (line 3428) with NO status mandated by spec at all — and the
spec explicitly tells clients to trust errcode over HTTP status (lines 3405-3413: a client seeing
`M_NOT_FOUND` on a 400 should still treat it as not-found). The only spec precedent for 404+M_NOT_FOUND
on media is the deprecated-endpoint freeze case (v1.11, "MAY return 404 M_NOT_FOUND for media which
exists, but is after the server froze unauthenticated media access") — i.e. the spec already endorses
an intentional 404 lie for a legitimate-but-inaccessible file. That's good precedent for AC2/AC3's
"admin_blocked looks like 404" design.

**Verdict:** 451 for pending/admin_blocked states is a Nebu-specific overlay, not spec-mandated and
not spec-forbidden (errcode-first client behavior makes it technically safe), but it's a real
divergence from the documented 504 pairing for `M_NOT_YET_UPLOADED`. Not a compliance bug — the CS
API doesn't reserve 451 for anything — but worth remembering as an intentional deviation so it's
never "fixed" back to 504 by a future contributor who greps the spec table literally.

## Other MUSTs relevant to AC4 (no regression on :released → 200)
- `Content-Disposition` and `Content-Type` are **Required** response headers since v1.12 (were
  optional/SHOULD before) — both download endpoints.
- `Content-Type` MUST be exact-or-reasonably-close to original upload (spec gives an explicit
  bounded list of what counts as "reasonable").
- CSP + `Cross-Origin-Resource-Policy: cross-origin` are SHOULD headers per §Media Repository —
  already a known gap noted in MEMORY.md against the old Go handlers; confirm the Elixir
  `Nebu.Media` port carried them forward, since AC4 explicitly requires no regression there.

## Not re-flagged as findings (recorded in reply, not new to memory)
AC5/AC6 (explicit allow-list, deny-by-default for unknown states) have no spec correlate at all —
`media_files.state` is a pure Nebu-internal lifecycle model the CS API doesn't know about, so this
is implementation-safety guidance, not spec compliance.
