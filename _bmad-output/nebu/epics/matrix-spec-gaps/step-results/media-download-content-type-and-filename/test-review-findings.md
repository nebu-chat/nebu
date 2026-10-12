# Test review — media-download-content-type-and-filename (pre-dev)
Verdict: 0 MAJOR, 6 MINOR, 6 INFO. AC1–AC6 covered (26 spec inline types verified exact against spec v1.18), AC7 docs untested by design. Header-injection tests are realistic (Plug decodes %0D%0A to real CR/LF; unsanitized put_resp_header raises InvalidHeaderError → red for the right reason). Old tests tightened, nothing weakened. No crash/restart test needed (stateless).

## MINOR (dev applies in tests where noted)
- M1: CR/LF in the STORED filename allows only 200, while the path-segment variant allows 200|400: document the asymmetry in a comment (a download should not 400 because of stored data).
- M2: filename escaping assertion is too rigid (`filename="a\"b.pdf"`, ~l.429/442): ALSO accept an equally RFC-conformant encoding (e.g. `"` replaced in the ASCII fallback plus the exact original name in `filename*=UTF-8''...`). Assert instead: header parses, no quote breakout, no extra parameters/headers, the original name is recoverable (via escaped quoted-string or filename*).
- M3: exact header comparison (`cd == ~s(attachment; filename="a b.pdf")`, ~l.380/387) forbids an additional `filename*` for an ASCII name with a space; loosen to "starts with `attachment; filename=\"a b.pdf\"`" and no breakout. Keep `inline|attachment` token exactness.
- M4: Content-Length guard is weak (Plug.Test sets no header; ~l.695-704 accepts missing): note it as a known gap in the test comment (real header covered in CI/e2e only); do not pretend to guard Content-Length.
- M5: thumbnail membership check (403) runs before the type check (400) — reasonable (no type leak) but not derivable from the AC: keep and document; a 451/reserved-state thumbnail probe is missing (optional add).
- M6: ResponseFilenameLookupTest (integration) leaves rows in the test DB (unique run_id, harmless): add cleanup in on_exit if trivial.

## INFO
- Parameters on non-text stored types (`application/pdf; foo=bar`) and original `text/plain; charset=utf-8` not tested; thumbnail with uppercase type and invalid UTF-8 path segment not tested; async persist test is a regression guard; scan-worker path not covered.
