---
story_id: 5a-admin-media-table
title: "Admin Media Overview: /admin/media LiveView Table (Filter + Pagination)"
epic: media-security-admin-control
status: done
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

This story adds the admin-facing entry point to the entire `media-security-admin-control` epic:
a Phoenix LiveView table at `/admin/media` that lists every `media_files` row with server-driven
filters (state, MIME-type prefix, uploader, upload-date range) and keyset (cursor) pagination.
It is read-only and has no row actions of its own beyond a "view" link — Block/Unblock/Delete/
Rescan/Override land in Story 6a/6c, live PubSub row updates and nav attention badges land in
Story 5b. This story's job is exactly: query, filter, paginate, render, and — because Story 6d's
bulk cohort actions attach to this same table — row-level multi-select with a "select all
matching the current filter" affordance and an action bar shell (the actual bulk actions are
wired in 6d; this story only needs the selection state to survive that later wiring).

**Schema-reality correction (2026-07-18): `media_files.filename` now exists — this section
previously said otherwise.** An earlier draft of this story, written against Story 1a's schema
only, found that `media_files` had no human-readable filename column and treated the UX mockup's
"Dateiname" column as aspirational (identity column showing Media-ID only). That premise is now
stale: Story 2b (`put-media-upload`, landed, commit `4a1b67c6`) added migration
`server/priv/migrations/000025_media_files_filename.up.sql`
(`ALTER TABLE media_files ADD COLUMN filename TEXT`) as an explicit, coordinator-approved
guardrail exception, specifically so the async-upload PUT handler can persist the optional
`?filename=` query parameter. `Nebu.Media.DB` (`server/lib/nebu/media/db.ex`) actively reads and
writes this column today (`persist_upload/1`, the download-gate lookup, etc.). This is the same
class of drift the epic's own Review 3 already caught once (`file_path` → `storage_key`) — the
established pattern for this epic is to **update the story to match the real, committed schema**,
not to flag it back to Product/UX as an open design question.

**Consequence for this story:** the table's identity column now shows the real **`filename`**
when present, rendered as plain text via ordinary HEEx auto-escaping (never `raw/1` — `filename`
is client-supplied via the upload's `?filename=` query param, making it a *more* attacker-controlled
value than `media_id`, not less). `filename` is nullable — genesis/`reserved` rows (created before
any bytes or query params arrive) and any upload that omitted `?filename=` have no value here — so
the column **falls back to the Media-ID** (`media_id`, the MXC URI's local part) in `<code>`
styling whenever `filename IS NULL`. There is no remaining "add a filename column" guardrail to
observe (that migration already shipped via 2b); the actual constraint now is: never assume
`filename` is present, and always render the null case gracefully.

**Secondary, related schema-reality correction: `uploader_user_id` is now nullable too.**
Story 2e's migration `000027_media_files_uploader_user_id_nullable.up.sql`
(`ALTER COLUMN uploader_user_id DROP NOT NULL`) nulls this column when a `:reserved` row
transitions to `:hard_deleted` (accountability data is cleared once a row reaches that terminal
state, per the epic's GDPR framing). The Uploader column must therefore render a placeholder
(`"—"`, matching this table's existing "no value" convention for the Scanned/ClamAV columns) when
`uploader_user_id IS NULL`, rather than assuming a Matrix ID is always present.

## User Story

As an admin, I want to browse all media files in a filterable, paginated table — by state,
uploader, MIME-type, and upload date — so that I can find files needing attention (an infected
upload, a stuck scan, a specific user's uploads) without scrolling through the entire
`media_files` table.

## Acceptance Criteria

1. **Route.** `GET /admin/media` is added inside the existing `live_session :admin` block in
   `server/lib/nebu/admin/router.ex` (`on_mount: {Nebu.Admin.Auth, :require_admin}` — the same
   gate every other admin LiveView uses), served by a new `Nebu.Admin.MediaLive` module.
2. **Columns.** State-Badge, **Filename** (`filename` when present, plain text via ordinary HEEx
   auto-escaping — never `raw/1`, since `filename` is client-supplied via the upload's
   `?filename=` query param; falls back to **Media-ID** (`media_id`, in `<code>` styling) when
   `filename IS NULL` — see Summary), Uploader (`uploader_user_id`, Matrix ID; renders `"—"` when
   `NULL`, which happens once a `:reserved` row is nulled on transition to `:hard_deleted` — see
   Summary), MIME-Type (`content_type`), file size (`file_size`, human-readable, e.g. "2.4 MB"),
   Uploaded (`uploaded_at`, human-readable local time), Scanned (derived from
   `scan_metadata->>'scanned_at'`, "—" if absent or state has no scan yet), ClamAV signature
   (`scan_metadata->>'clamav_signature'` — schema-reality correction, 2026-07-18: the only real
   writer, `Nebu.Workers.MediaScanWorker.infect/2` (Story 4b, landed), persists the key as
   `clamav_signature`, not the plain `signature` an earlier draft of this AC assumed; "—" if
   absent).
3. **Filters**, all URL-driven (bookmarkable, back/forward-safe) via `push_patch/2` +
   `handle_params/3` — the same pattern `Nebu.Admin.LogsLive.TraceMap` already established for
   this codebase (see that module's moduledoc):
   - State: multi-select pill group (bracket-array URL param `state[]=...`, decoded with
     `Plug.Conn.Query.decode/1`, last-wins semantics documented by `TraceMap` apply here too).
   - MIME-type: prefix match (`content_type LIKE $1 || '%'`).
   - Uploader: substring/exact search on `uploader_user_id`.
   - Upload date range: `uploaded_at` (BIGINT epoch-ms) between an optional from/to date.
   - Filters apply live — no submit button — each input change triggers a `push_patch`.
4. **Cursor (keyset) pagination, not OFFSET.** 50 rows per page via a "Weitere laden" (Load More)
   control — matching the UX mockup and `EXPERIENCE.md`'s documented `media-table` pattern (no
   next/prev pager UI exists for this table). Keyset on `(uploaded_at DESC, media_id DESC)`,
   opaque cursor also carried in the URL so a bookmarked/back-navigated URL reproduces the same
   page. **Why keyset and not OFFSET:** `media_files` accrues new rows continuously (uploads) and
   the state of existing rows changes continuously (scan results, admin actions); OFFSET
   pagination silently skips or duplicates rows whenever the ordered result set shifts between
   two page fetches (a classic "phantom row" bug under concurrent inserts) — keyset pagination
   anchors on the last-seen row's own sort key, which is stable regardless of concurrent writes
   elsewhere in the table.
5. **Inline SQL only** (ADR-018) — every query (filtered/paginated `SELECT`, and the count for
   the `aria-live` result announcer) lives as inline SQL strings in `Nebu.Admin.MediaLive`'s own
   handler functions. No Ecto schema, no repository/service module.
6. **No preview/thumbnail; HEEx auto-escaping only.** Filenames/identifiers render as plain text
   through normal HEEx interpolation (`{...}`) — never `raw/1` — since admin-visible uploader
   input (were a filename ever added) must not be treated as trusted HTML.
7. **State-badge colors**, per `DESIGN.md`'s `media-badge--*` token classes (new
   `@layer components` block, `<span class="badge badge-sm media-badge--{group}">`, DaisyUI
   `table table-zebra` inside `overflow-x-auto`): amber (`media-processing`) for
   `reserved`/`quarantined`/`scanning`, teal (`media-released`) for `released`, red
   (`media-infected`) for `infected`, coral (`media-blocked`) for `admin_blocked`, gray
   (`media-terminal`) for `deleted`/`hard_deleted`. Color is never the only signal — icon + text
   accompany every badge (colorblind rule, DESIGN.md D7/M1).
8. **Multi-select for bulk actions (Story 6d precondition).** A checkbox per row plus a
   "select all matching the current filter" control with a live count. Selection is **transient**
   — it lives only in LiveView `socket.assigns`, never in the URL (unlike filter/sort/cursor) —
   and must survive Story 5b's future per-row PubSub updates (i.e. selection state keys off
   `media_id`, not row position/index). An action bar appears once ≥1 row is selected; this story
   renders the bar shell with the selection count only — the actual bulk actions (Rescan/Block/
   Delete/Override) are Story 6d's scope, not this one.
9. **Admin-only access control.** Enforced by the existing `Nebu.Admin.Auth, :require_admin`
   on_mount — no bespoke authorization logic in this LiveView.
10. **Accessibility (hard constraint, not optional — project convention, `EXPERIENCE.md`
    "Accessibility Floor"):**
    - Keyboard-complete: every filter control, the Load More button, and (once wired) every row
      action must be operable without a mouse.
    - Semantic table: `<table>` with `<th scope="col">` per column and a `<caption
      class="sr-only">` describing the active filter (mirrors `AuditLogLive`'s existing table
      shape).
    - A visually-hidden `aria-live="polite"` node announces the result count on every
      filter/sort/cursor change (e.g. "14 Medien gefunden" / "Keine Treffer — Filter anpassen").
    - After a "Weitere laden" append, focus moves to the first newly-appended row (or stays on
      the button while announcing "50 weitere geladen, 100 von 240 geladen") — never silently
      drops focus.
    - Uniform focus ring (`focus-visible:ring-2 ring-primary ring-offset-2
      ring-offset-base-200`), matching the rest of the Admin UI nav/components.
    - Filter pill group uses `role="group"` with a visible, associated label (not
      `aria-label`-only).

## Acceptance Tests

Write these ExUnit (`Phoenix.LiveViewTest`) tests FIRST, under
`server/test/nebu/admin/media_live_test.exs` (mirrors the existing `logs_live_test.exs` /
`audit_log_live_test.exs` shape in the same directory):

1. `"mount renders the empty state when media_files has no rows"` — asserts the "Noch keine
   Medien hochgeladen." empty-state copy (`EXPERIENCE.md` State Patterns B), not a bare empty
   table.
2. `"mount renders a row per seeded media_files entry with all 8 columns"`.
3. `"state filter: selecting :infected via state[]=infected shows only infected rows"`.
4. `"state filter: multiple states via state[]=infected&state[]=admin_blocked shows the union"`.
5. `"mime filter: content_type prefix match narrows results (e.g. application/pdf)"`.
6. `"uploader filter: substring match on uploader_user_id narrows results"`.
7. `"date-range filter: uploaded_at between from/to excludes rows outside the range"`.
8. `"combined filters (state + mime + uploader + date range) compose with AND semantics"`.
9. `"no filter matches → renders 'Keine Treffer — Filter anpassen', not an empty table"`.
10. `"filter changes round-trip through the URL: push_patch followed by a fresh mount with the
    same query string reproduces the identical filtered result set"` (the `TraceMap` filter-state
    contract — `trace-map-filter-reset-bugfix` is the cautionary precedent this test guards
    against regressing here too).
11. `"pagination: with 60 seeded rows (uploaded_at strictly descending), page 1 returns exactly
    the 50 most recent rows in uploaded_at DESC order"`.
12. `"pagination: 'Weitere laden' with the returned cursor returns exactly the remaining 10 rows,
    no duplicate and no skipped media_id"` — the keyset-correctness test.
13. `"pagination cursor boundary: a row inserted between page 1 and the Load More fetch, with a
    uploaded_at newer than the cursor, does not appear on page 2 and does not shift any
    already-seen row"` — proves OFFSET-style phantom-row drift cannot happen.
14. `"pagination cursor boundary: two rows share the exact same uploaded_at value — the media_id
    tiebreaker in the keyset still produces a stable, non-overlapping split across pages"`.
15. `"scanned_at and ClamAV signature columns render '—' when scan_metadata is NULL"`.
16. `"scanned_at and ClamAV signature columns render the scan_metadata JSONB values when present"`.
17. `"multi-select: checking two rows then toggling a third filter-independent row keeps all
    three selected"`.
18. `"multi-select: 'select all matching current filter' selects only the rows visible under the
    active filter, not the full table"`, with a visible selection count.
19. `"non-admin access control: a session without the admin role is redirected away from
    /admin/media (or receives a 403), never rendering the table"` — mirrors the existing
    `require_admin` on_mount test pattern used by other admin LiveViews (e.g.
    `admin_bootstrap_live_test.exs`).
20. `"HEEx auto-escaping: a media_id, filename, or uploader value containing '<script>' renders as
    escaped text, never executed markup"` — regression guard for AC6 (no `raw/1`); `filename` is
    the most attacker-controlled of the three (client-supplied via `?filename=`), so it is the
    primary case this test must cover, not an afterthought.
21. `"identity column: renders the real filename in plain text when media_files.filename is not
    null"` — schema-reality correction (Summary): Story 2b's migration 000025 column, now read.
22. `"identity column: falls back to Media-ID in <code> styling when filename is NULL"` (e.g. a
    `:reserved` genesis row created before any `?filename=` query param arrives).
23. `"uploader column renders '—' when uploader_user_id is NULL"` (e.g. a `:hard_deleted` row
    nulled by Story 2e's migration 000027 cleanup transition).

**Playwright/E2E (UX gate — this is a `ui: true` story, project convention requires E2E growth
per UI story):** add
`e2e/features/admin/admin-media-overview.feature` (new file, following the existing
`e2e/features/admin/admin-ui-liveview.feature` / `admin-ui-room-toggle.feature` Gherkin shape —
`Background` with an authenticated admin session, `@media-security-admin-control` +
per-scenario `@ac*` tags) covering at minimum: the page renders the table for a seeded infected
file (mirrors the mockup's "Kai triages an infected upload" Key Flow step 1), a state-filter pill
click narrows the visible rows, and "Weitere laden" appends more rows without a full page
reload. Step definitions go in `e2e/step-definitions/admin/admin-media-overview.steps.ts`.

## Technical Requirements

Follows ADR-018 (inline SQL, no Ecto schema/service layer) and ADR-020 (this LiveView lives
inside `Nebu.Admin`, the only namespace allowed to read `media_files` directly for admin-facing
concerns — it does not go through a `Nebu.Media` public-API call because ADR-018 already puts the
query inline here, same as every other admin LiveView's `@sql` module attribute pattern seen in
`Nebu.Admin.AuditLogLive`).

### 1. Module

`server/lib/nebu/admin/media_live.ex` — `Nebu.Admin.MediaLive`, `use Phoenix.LiveView, layout:
{Nebu.Admin.Layouts, :live}` (same shape as `AuditLogLive`/`LogsLive`). Router wiring in
`server/lib/nebu/admin/router.ex`, inside the existing `live_session :admin` block:

```elixir
live "/media", MediaLive, :index
```

### 2. Filter + pagination query composition

Build the `WHERE` clause and params list incrementally (never string-interpolate user input):

```elixir
defp build_query(filters, cursor) do
  {conditions, params, _idx} =
    [
      {filters.states, "state = ANY($~p::media_state[])"},
      {filters.mime_prefix, "content_type LIKE $~p"},
      {filters.uploader, "uploader_user_id ILIKE $~p"},
      {filters.uploaded_from, "uploaded_at >= $~p"},
      {filters.uploaded_to, "uploaded_at <= $~p"}
    ]
    |> Enum.reduce({[], [], 1}, fn
      {nil, _tmpl}, acc -> acc
      {[], _tmpl}, acc -> acc
      {value, tmpl}, {conds, params, idx} ->
        {[String.replace(tmpl, "~p", Integer.to_string(idx)) | conds], params ++ [value], idx + 1}
    end)

  {cursor_sql, cursor_params} = cursor_clause(cursor, length(params) + 1)

  where = Enum.join(conditions ++ List.wrap(cursor_sql), " AND ")
  {where, params ++ cursor_params}
end

# Keyset predicate: strictly "older" than the last row seen, tie-broken by media_id.
defp cursor_clause(nil, _next_idx), do: {nil, []}

defp cursor_clause(%{uploaded_at: ts, media_id: id}, next_idx) do
  {"(uploaded_at, media_id) < ($#{next_idx}, $#{next_idx + 1})", [ts, id]}
end
```

```sql
SELECT media_id, filename, uploader_user_id, content_type, file_size, uploaded_at, state,
       scan_metadata
FROM media_files
WHERE <composed conditions from build_query/2>
ORDER BY uploaded_at DESC, media_id DESC
LIMIT 50
```

`filename` (Story 2b, migration 000025) and `uploader_user_id` (nullable since Story 2e, migration
000027) may both be `NULL` — the identity column falls back to `media_id` (`<code>` styling) when
`filename IS NULL`; the Uploader column renders `"—"` when `uploader_user_id IS NULL`.

`scanned_at`/signature are read out of the `scan_metadata` JSONB column at render time
(`scan_metadata["scanned_at"]`, `scan_metadata["clamav_signature"]` — see AC2's schema-reality
correction) — there is no dedicated
`scanned_at` column (per 1a's schema; only `scan_metadata JSONB` exists).

The result-count announcer runs the same `WHERE` (minus `LIMIT`/cursor) wrapped in
`SELECT COUNT(*) FROM media_files WHERE <conditions>` for the `aria-live` text — cheap enough at
this scale; do not attempt a windowed count-over-limit trick here (YAGNI, matches the epic's
S-sizing discipline).

### 3. URL/filter state (`handle_params/3`)

Mirrors `Nebu.Admin.LogsLive.TraceMap`'s already-established contract in this codebase: URL is
the single source of truth for filters/sort/cursor. `mount/3` does no query work itself;
`handle_params/3` decodes `params` (via `Plug.Conn.Query.decode/1` for the bracket-array
`state[]` param, following the exact precedent `TraceMap`'s moduledoc documents for its own
`endpoint[]` param), builds the filter map, runs `build_query/2`, and assigns the row set. Every
filter-control `phx-change`/pill click issues a `push_patch(socket, to: media_path(new_filters))`
— never a direct `assign` of query results — so `handle_params/3` remains the only place rows are
fetched (the same discipline that keeps `TraceMap` filter state bookmarkable).

### 4. Rows as a LiveView stream

Use `stream(socket, :media_rows, rows)` (not a plain `assign(:rows, ...)`) — this repo's
established pattern for row-level live-updatable tables (`Nebu.Admin.LogsLive` already does
exactly this with `stream/3` + `stream_insert/4` + `phx-update="stream"` on the row container,
see `server/lib/nebu/admin/logs_live.ex` around its `@sql`/stream-setup and its `#request-rows`
container). This story only needs the stream *set up* correctly (stable per-row DOM id = the
`media_id`, so `phx-update="stream"` works) — Story 5b is the one that adds
`stream_insert(socket, :media_rows, updated_row)` on PubSub events. Getting the stream shape
right here avoids 5b having to refactor this story's rendering.

### 5. Multi-select state

A plain `MapSet` of selected `media_id`s in `socket.assigns.selected_ids` — keyed by `media_id`,
not row index/position, so a `stream_insert` from Story 5b never invalidates an existing
selection. "Select all matching filter" runs the same `WHERE` (without `LIMIT`) to fetch just the
`media_id` column and unions it into the set — capped at a sane bound (e.g. `LIMIT 5000`) with a
truncation notice if exceeded, since a compliance officer selecting "all" during a false-positive
storm (Story 6d's scenario) could otherwise select an unbounded set.

### 6. DaisyUI/Tailwind reuse

- Table shell: `<div class="overflow-x-auto"><table class="table table-zebra">` — identical to
  `AuditLogLive`'s existing markup, do not invent a new table wrapper.
- Filter pill group + inputs: new markup (no prior admin page has a filter bar), but reuse the
  existing focus-ring utility class combination already used by `Nebu.Admin.Layouts.nav_item/1`
  (`focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base-200`) for every interactive
  filter control, so keyboard focus is visually consistent across the whole Admin UI.
- State badges: new `media-badge--*` `@layer components` classes per `DESIGN.md` — do not reuse
  DaisyUI's own `badge-success`/`badge-error` tokens directly (DESIGN.md D2: ops "success" green
  is reserved for a different semantic than `released`'s teal; ops "error" red is reserved
  differently than `admin_blocked`'s coral).

### 7. Human-readable formatting helpers

No existing byte-size humanizer exists in the codebase (`grep` across `server/lib/` found none)
— add a small private `humanize_bytes/1` in `Nebu.Admin.MediaLive`. For the `uploaded_at`
BIGINT-epoch-ms timestamp, reuse the `DateTime.from_unix(ts, :millisecond)` pattern already used
by `server/lib/nebu/admin/users_html.ex` for the same column shape, rather than inventing a new
conversion.

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/lib/nebu/admin/media_live.ex` | CREATE | `Nebu.Admin.MediaLive` — mount/handle_params/render, inline SQL, filters, keyset pagination, multi-select |
| `server/lib/nebu/admin/router.ex` | UPDATE | Add `live "/media", MediaLive, :index` inside the existing `live_session :admin` block |
| `server/assets/css` (or wherever `DESIGN.md`'s `@layer components` block for `media-badge--*` lives — check `docs/architecture` / existing Tailwind config for the right entry point) | UPDATE | Add the `media-badge--*` token classes per DESIGN.md |
| `server/test/nebu/admin/media_live_test.exs` | CREATE | Acceptance Tests 1–20 above |
| `e2e/features/admin/admin-media-overview.feature` | CREATE | E2E scenarios (UX gate) |
| `e2e/step-definitions/admin/admin-media-overview.steps.ts` | CREATE | Step definitions for the above feature |

## Dev Agent Guardrails

**Do Not Change:**

- The existing admin nav/layout structure (`Nebu.Admin.Layouts`, `nav_item/1`, the
  `live_session :admin` gate, the topbar/sidebar shell). Reuse it as-is — do not fork a parallel
  layout or a bespoke auth check for this one page. Wiring the "Medien" parent nav item with its
  Übersicht/Health/Settings/Approvals children (per the epic's Review 9 IA note) is a separate
  concern (Story 0 / UX-Foundation territory) — if that story has not landed yet when this one is
  implemented, add this page as a plain leaf `nav_item` for now rather than inventing the nested
  parent/children markup yourself; do not duplicate `logs_nav_children`/`config_nav_children`'s
  pattern speculatively.
- `media_files`'s schema. Do **not** add an index or any other migration in this story — that is
  out of scope for a UI story and migrations are pipeline-protected. (The filename column itself
  already exists — see Summary's schema-reality correction — so there is nothing left to "fix"
  here; the actual guardrail is the one below.)
- Do not assume `filename` or `uploader_user_id` are always present. Both are nullable columns
  (see Summary) — render both gracefully for the `NULL` case (fall back to Media-ID for the
  identity column when `filename IS NULL`; render `"—"` for Uploader when `uploader_user_id IS
  NULL`) rather than crashing or rendering a blank/`nil`-interpolated cell.
- `Nebu.Admin.AuditLogLive`, `Nebu.Admin.LogsLive`, and their tests — this story adds a sibling
  module, it does not touch existing admin LiveViews.
- Accessibility is a **hard constraint**, not a nice-to-have, per this project's Admin UI
  convention (`EXPERIENCE.md` "Accessibility Floor", WCAG 2.1 AA, PRD NFR-A1/A2/A3 — legally
  required for the DE/EU public-sector target audience). A code-review pass that finds a missing
  `<th scope="col">`, a color-only badge, or a Load More that drops focus is a correctness defect
  in this story, not a follow-up nice-to-have.
- Do not implement any row action beyond a read-only "view" link in this story — Block/Unblock/
  Delete/Rescan is Story 6a, Override is Story 6c, bulk actions are Story 6d, and live PubSub row
  updates + nav attention badges are Story 5b. Keep this story's scope to query/filter/paginate/
  render/select.

## Dependencies

**Depends on:** `1a-media-files-migration` — this story queries the `media_files` table and its
`state`/`scan_metadata` columns directly; it cannot be implemented (or even meaningfully tested)
before that migration lands.

**Enables:**
- `5b` (Live-Row-Updates + Nav-Attention-Badges) — adds PubSub-driven `stream_insert/4` calls onto
  the `:media_rows` stream this story sets up, and nav badges alongside the nav entry this story
  leaves as a plain leaf.
- `6a` (Routine-State-Aktionen), `6b` (Detail-View), `6c` (Infected-Override) — all attach their
  row actions to the table rendered here.
- `6d` (Bulk Cohort Actions) — reuses this story's multi-select/"select all matching filter"
  mechanism and its signature filter as the natural bulk-override cohort selector.
