---
story: admin-room-names-sanitiser-gaps
epic: bugfix
status: ready
security_review: required
matrix: false
ui: false
---

# Bugfix — display-name sanitiser of the admin room names has two gaps (delta review of d7914da5)

A delta review of `admin-rooms-fallback-name` (d7914da5) found two MINOR gaps in `Nebu.Admin.RoomNames.sanitize/1`
(`server/lib/nebu/admin/room_names.ex`) and one rough edge in the rooms index search.

## Problem

1. A display name made only of invisible characters survives the sanitiser as a non-empty string, so the member is shown blank and the localpart
   fallback never runs (breaks AC2 "never blank" of the parent story, allows blank / invisible impersonation). Inputs that come back unchanged:
   ZWJ / ZWNJ only (U+200D, U+200C); Hangul fillers (U+3164, U+115F, U+1160, U+FFA0); braille blank U+2800; tag characters U+E0000-E007F;
   interlinear annotation marks U+FFF9-FFFB; combining marks only.
2. The "at most 3 combining marks in a row" rule is bypassed by a kept ZWJ between marks: `a` + (4 marks + ZWJ) repeated gives one ~511-byte grapheme
   with about 400 marks that passes the 32-character cap.
3. A NUL byte (U+0000) in the search term `q` of the rooms index makes PostgreSQL fail (22021); the failure is swallowed and the page silently shows an empty list.

## Acceptance criteria

```gherkin
Scenario: AC1 invisible-only display names fall back to the localpart
  Given a member whose display name consists only of invisible characters
        (ZWJ / ZWNJ, Hangul fillers, braille blank, tag characters, interlinear annotation marks, combining marks only)
  When the member name is computed
  Then the display name counts as empty and the member is shown by the localpart of the user id (never blank)

Scenario: AC2 legitimate names are unchanged
  Given display names in ASCII, with accents, CJK, an emoji ZWJ sequence, Persian with ZWNJ, or Indic text with virama + ZWJ
  When the names are sanitised
  Then they come back unchanged (invisible format characters are dropped, but ZWJ / ZWNJ inside real text are kept)

Scenario: AC3 the combining-mark limit holds across kept format characters
  Given a display name whose combining marks are interleaved with ZWJ / ZWNJ
  When the name is sanitised
  Then at most 3 combining marks remain in a row (counted across the ZWJ / ZWNJ), so the result stays small and short

Scenario: AC4 a NUL byte in the rooms search term is ignored
  Given an admin opens the rooms index with a search term that contains a NUL byte
  When the page renders
  Then the NUL byte is dropped, the remaining term still filters, and the page does not silently show an empty list
```

## Notes

- Explicit room names stay verbatim and unsanitised (AC4 of the parent story; known LOW follow-up, out of scope).
- Only `server/lib/nebu/admin/room_names.ex` and `server/lib/nebu/admin/rooms_controller.ex` change. No migration, no template change, no Matrix API change.
