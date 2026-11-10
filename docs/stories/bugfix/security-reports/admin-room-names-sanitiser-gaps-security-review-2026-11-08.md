## Security Review — admin-room-names-sanitiser-gaps

**Diff scope:** `Nebu.Admin.RoomNames.sanitize/1` (drops all `\p{Cf}` except ZWJ/ZWNJ plus tag chars, collapses joiner runs, combining-mark limit counted across joiners, invisible-only names count as blank so the localpart is shown) and `RoomsController.normalize_search/1` (drops NUL bytes before trim/cap). Tests in admin_rooms_fallback_name_test.exs / room_names_test.exs.
**Date:** 2026-11-08

### Findings

No security issues found.

### Notes on what was checked

- **Prescan:** no candidates reported for this diff.
- **ReDoS:** input is cut to 512 bytes (`truncate_bytes/2`) before any regex runs. All new patterns are linear: `\p{Cc}|[tag]|(?![ZWJ/ZWNJ])\p{Cf}` is a single-codepoint alternation. The joiner-run pattern has one quantifier. The mark-limit pattern `(\p{M}(?:[J]?\p{M}){2})(?:[J]?\p{M})+` has an optional joiner followed by a required mark in each repetition. Joiners and marks are disjoint classes, and joiner runs are already collapsed, so each position matches in only one way and there is no catastrophic backtracking. `visible?/1` uses two single-class patterns.
- **Invisible / blank names (spoofing):** a name with no L/N/S/P character after removing the filler set (U+115F, U+1160, U+3164, U+FFA0, U+2800, U+1D159) returns "", so the caller falls back to the localpart. A blank or invisible row can no longer hide a member from the admin. Bidi overrides, isolates and marks are all inside `\p{Cf}` and are still removed, so they cannot reorder the text. Kept ZWJ/ZWNJ cannot reorder text and are capped at one in a row.
- **Size bound:** byte cap, then the grapheme caps (32 per name, 120 in total) as before. ZWJ chains are bounded by the 512-byte input cap.
- **Remaining impersonation (no finding):** display names are non-unique by design, and homoglyph or mixed-script names are still possible. The admin member list already shows the same data. This is not a new path and is out of this story's scope.
- **XSS:** the output stays unescaped text that the HEEx templates escape. No `raw/1` was added.
- **Search term:** NUL removal only. The term still goes in as a bind parameter (`ILIKE $1` via `like_pattern/1`), so there is no injection path. Removing NUL stops a PostgreSQL error from showing as an empty list, which is an integrity improvement. The route is admin-only and unchanged.
- **Logging / crypto / routes / migrations:** none touched.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED
