# code-review — cycle 1
INFO | review-prescan.md | prescan has no MAJOR/MINOR/HINT lines | -
INFO | server/lib/nebu/admin/room_names.ex:141 | previous MINOR (U+1D159 invisible-only) FIXED: \x{1D159} added to @filler_chars, case added to AC1 @invisible_only table (room_names_test.exs:156, exercises sanitize/1 and member_label/2); probed regex: "\u{1D159}" -> not visible, "\u{1D159}x" -> visible | -
INFO | server/lib/nebu/admin/room_names.ex:150 | previous INFO (flag-emoji / Arabic number-sign trade-off undocumented) now documented in the sanitize/1 comment | -
INFO | server/lib/nebu/admin/room_names.ex:18 | moduledoc rewrap only partly done: line 18 is still 195 chars (lines 16-17 now ~112) | optional: break after "text is returned unescaped;"
INFO | delta | no problems introduced by the delta (one regex char, one comment, one test row) | -
