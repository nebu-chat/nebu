## Security Review — admin-rooms-fallback-name

**Diff scope:** new `Nebu.Admin.RoomNames` (fallback room names from member display names, one batched query), `RoomsController` (`q` search param with ILIKE, detail page title via RoomNames), `RoomsHTML`, rooms index/show HEEx templates, e2e feature.
**Date:** 2026-11-08

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/lib/nebu/admin/room_names.ex:56-61 | Explicit `rooms.name` is returned verbatim (no bidi/control-char strip, no length cap), unlike the member-name fallback. Pre-existing behaviour, now centralised. | Optionally run explicit names through `sanitize/1` + `cap/2` as well (display only). |

### Detail

**Finding #1 — Explicit room name not sanitised for bidi/zero-width** [LOW]
`display_name/1` returns a non-blank `name` unchanged. A room creator can put RLO/zero-width characters or a very long name into the room name, which the admin index, detail `<h1>` and `<title>` show. HEEx still escapes it (no XSS); the impact is visual spoofing on an admin-only page and was already the case before this diff. Hardening only.

### Verified / dismissed

- **XSS:** all outputs of `room_display_name/1` are HEEx `{...}` interpolations (link text, `<h1>`), `title={room.room_id}` and `value={assigns[:search]}` are attribute interpolations (escaped), layout `<title>{assigns[:page_title]}</title>` is escaped. No `raw/1` in rooms templates or RoomsHTML.
- **SQL injection:** `where_clause/2` interpolates only fixed literals (status filter whitelisted via `@valid_filters`); search term goes in as bind `$1`. Member query uses `ANY($1)` with bind params.
- **LIKE wildcard injection:** `\`, `%`, `_` escaped with backslash, Postgres default LIKE escape char is `\` — wildcards literal. Non-string `q` (list/map) -> nil. Length capped at 100 graphemes; invalid UTF-8 at worst produces a DB error which the `_ -> []` branch absorbs.
- **Query DoS:** leading-wildcard ILIKE = seq scan over `rooms`, still `LIMIT 500`, admin-authenticated only; the member-name lookup is one query for all listed rooms (no N+1), at most 4 rows per room, only for unnamed rooms with 1..4 members.
- **Memory/CPU:** at most 500 x 4 names; sanitize regexes are linear (no nested quantifier backtracking); combining-mark runs capped at 3, names capped at 32 graphemes, fallback at 120.
- **Info exposure:** only `profiles.displayname` / localpart of joined members are read — the same data the admin member list already shows. No new routes; existing admin pipeline (`Nebu.Admin.Auth`) unchanged.
- **Logs:** `Logger.warning` logs only `Exception.message/1` of the DB error (no display names, no tokens, no message content).
- **CSRF:** search form is GET, read-only.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 1 — advisory

**Verdict:** APPROVED
