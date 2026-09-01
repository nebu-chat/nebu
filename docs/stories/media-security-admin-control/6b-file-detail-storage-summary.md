---
story_id: 6b-file-detail-storage-summary
title: "Admin Media Actions: Detail View + Storage Summary"
epic: media-security-admin-control
status: done
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

`/admin/media` (Story 5a) lists every media file as a row in a filterable, paginated table.
This story adds the page a row links to: a read-only per-file detail view at
`/admin/media/:media_id` that shows (1) the file's own metadata and its **full, immutable
audit trail** from `media_state_transitions` (the append-only ledger established in Story 1a,
ADR-031), and (2) a **storage summary panel** — aggregate bytes stored for active (`:released`)
media versus soft-deleted, pending-hard-delete (`:deleted`) media, reported separately, per the
epic's Story 6b scope.

This is deliberately the one Story-6 slice that writes nothing: no state transitions, no audit
log entries, no admin actions. It is pure read/reporting, independent of 6a (routine actions),
6c (infected override), and 6d (bulk cohort actions) — an admin can view a file's history without
ever needing the ability to act on it. The action buttons those sibling stories add (Block/
Unblock/Delete/Rescan/Override) are expected to live on this same page as the natural place to
put per-file controls, but wiring them in is out of scope here; this story only has to leave room
for them, not implement them.

**Honest scope note on "compression ratio":** Story 1a/12 persist only a `compressed BOOLEAN`
flag on `media_files` — the actual compressed-on-disk byte count is never written anywhere.
`media_files.file_size` is the **original, pre-compression, pre-encryption** byte count (see
`Nebu.Media.DB`/`Nebu.Media.Storage` — it is `byte_size(original_body)`, computed before
`:zlib.gzip/1` runs, and it is also the value returned to Matrix clients as the file's logical
size). There is therefore no numeric compression ratio to compute from the schema without
re-fetching and decrypting the stored object — an expensive, security-sensitive operation this
read-only view does not perform. This story shows the `compressed` flag as a plain yes/no
indicator and does **not** fabricate a percentage or byte-delta next to it.

## User Story

As a Nebu admin investigating a specific file (e.g. following up on an alert, a user complaint,
or a compliance request), I want to open one file's full lifecycle history and see how much
storage active versus pending-deletion media is consuming, so that I can understand exactly what
happened to that file over time and gauge storage pressure — without having to reconstruct either
from raw SQL.

## Acceptance Criteria

1. **Route & module.** `GET /admin/media/:media_id` renders `Nebu.Admin.MediaLive.Detail`, added
   to the existing `live_session :admin` block (`on_mount: {Nebu.Admin.Auth, :require_admin}`) in
   `server/lib/nebu/admin/router.ex` — the same auth gate 5a/6a use, not a new one.
2. **File metadata.** The page shows: `media_id`, `content_type` (MIME), `file_size`
   (human-readable, e.g. `2.3 MB`), `uploader_user_id`, `uploaded_at`, current `state` (reusing
   5a's state-badge color convention: amber processing / teal `:released` / red `:infected` /
   coral `:admin_blocked` / gray terminal), and `file_hash` (SHA-256, monospace, truncated with a
   full value on hover/title — never linkified, it is not a resource identifier).
3. **Full audit trail.** Every row from `media_state_transitions` for this `media_id` is rendered,
   ordered **chronologically ascending** (oldest first — the natural reading order for "what
   happened to this file"), showing `from_state` (or "—" for the initial `reserved` transition,
   which has no prior state), `to_state`, actor (`"System"` when `actor_type = :system`; the raw
   `actor_id` UUID when `actor_type = :admin` — no name/email join, matching
   `Nebu.Admin.AuditLogLive`'s own existing `actor_user_id` display convention, no new
   cross-domain lookup), and `inserted_at` timestamp.
4. **Empty-history handling.** A `media_id` with zero rows in `media_state_transitions` (e.g. a
   pre-epic legacy row that predates Story 1a's migration and was never backfilled with
   transition history) renders an explicit "No transition history recorded" empty state — not a
   crash, not a silently empty table with no explanation.
5. **Storage summary panel.** A page-level (not per-file) panel shows two aggregates, computed
   across **all** `media_files` rows, not just the one being viewed:
   - **Active** — `SUM(file_size)` and `COUNT(*)` where `state = 'released'`.
   - **Pending Hard-Delete** — `SUM(file_size)` and `COUNT(*)` where `state = 'deleted'`.

   Both are human-readable byte totals; a bucket with zero matching rows renders `0 B` / `0
   files`, not blank or an error.
6. **Compression indicator, not a ratio.** The file's own `compressed` column renders as a plain
   yes/no badge/label (e.g. "Compressed" / "Not compressed"). No percentage, ratio, or
   bytes-saved figure is displayed or computed — see the Summary's "honest scope note": the
   schema does not persist the data needed to compute one.
7. **Scan metadata (ClamAV signature).** If `scan_metadata` is non-`NULL` **and** contains a
   `"clamav_signature"` key (the shape actually written by
   `Nebu.Workers.MediaScanWorker.infect/2`, Story 4b, landed — **schema-reality correction,
   code-review 2026-07-19**: an earlier draft of this AC assumed a plain `"signature"` key; the
   only real writer persists `%{clamav_signature: signature, scanned_at: ...}`, the exact same
   drift Story 5a's own moduledoc already documents and corrected for its table view), render the
   signature name. If `scan_metadata` is `NULL` (never scanned as infected) or present but without
   a `"clamav_signature"` key (e.g. `%{"skipped" => "size_limit"}`), the signature block is
   omitted entirely — no `"N/A"`/`"—"` placeholder clutter for the common case.
8. **Admin-only access.** An unauthenticated request (or a session that fails
   `Nebu.Admin.Auth.require_admin`) is redirected the same way every other `live_session :admin`
   page redirects unauthenticated access — no bespoke auth logic in this LiveView.
9. **Unknown `media_id`.** A `media_id` with no matching `media_files` row renders a clear
   not-found state on the page (not a LiveView crash/500).
10. **Read-only page — no writes.** This LiveView issues `SELECT` statements only. It performs no
    `INSERT`/`UPDATE`/`DELETE` against `media_files` or `media_state_transitions`, registers no new
    `Nebu.Compliance.AuditWriter.@known_actions` entry, and renders no action buttons of its own
    (6a/6c/6d's action controls are a separate, later wiring concern on the same page).
11. **XSS-safety.** `content_type`, `uploader_user_id`, and any transition `metadata` text
    rendered on the page go through ordinary HEEx interpolation (auto-escaped) — no `raw/1`,
    matching 5a's filename-rendering convention.
12. **Accessibility (WCAG 2.1 AA, `skills/nebu-conventions/ux-conventions/SKILL.md`).** The
    transition-history table uses a `<caption>` and `<th scope="col">` headers; the state badge
    and compression indicator never rely on color alone (each carries a text label); all
    interactive elements (e.g. the "back to list" link) are keyboard-reachable with visible focus
    styles; text contrast meets 4.5:1.

## Acceptance Tests

New test file: `server/test/nebu/admin/media_live/detail_test.exs` (`Phoenix.LiveViewTest`,
`live_isolated/3`, mirrors the conventions of `test/nebu/admin/logs_live_test.exs` and
`test/nebu/admin/admin_bootstrap_live_test.exs` for admin-session setup).

1. `"GET /admin/media/:media_id as an authenticated admin renders the file's own metadata (hash,
   size, MIME, uploader, uploaded_at, state badge)"` — seeds one `media_files` row, asserts each
   field appears in the rendered HTML.
2. `"transition history renders in chronological order (oldest first), showing
   from_state/to_state/actor/timestamp per row"` — seeds three `media_state_transitions` rows
   with `inserted_at` timestamps deliberately out of insertion order, asserts the rendered row
   order matches ascending `inserted_at`, not insertion order.
3. `"a transition with actor_type: :system renders actor as 'System'; actor_type: :admin renders
   the raw actor_id"` — one row of each kind, asserts both display forms.
4. `"a media_id with zero media_state_transitions rows renders the empty-history state, not an
   error"`.
5. `"storage summary numbers are correct against a fixture with known :released and :deleted
   file_size values"` — seeds N `:released` rows summing to a known total X and M `:deleted` rows
   summing to a known total Y (with a mix of `compressed: true`/`false` among them, to prove the
   sum uses `file_size` — the logical/original size — regardless of the compression flag), asserts
   the rendered "Active" total equals X and "Pending Hard-Delete" total equals Y exactly.
6. `"storage summary renders '0 B' / '0 files' for a bucket with no matching rows"` — seeds only
   `:released` rows, asserts the "Pending Hard-Delete" bucket renders zero, not blank.
7. `"compressed: true renders a compression indicator without any percentage or ratio text"` —
   regex/string-refute check that no `%`-suffixed or "ratio"-labelled text appears near the
   indicator.
8. `"scan metadata renders the ClamAV signature when scan_metadata contains one (infected
   fixture)"` — seeds `scan_metadata: %{"clamav_signature" => "Eicar-Test-Signature"}` (schema-reality
   correction, code-review 2026-07-19 — see AC7), asserts the signature string appears.
9. `"scan metadata block is absent when scan_metadata is nil (clean, never-flagged fixture)"`.
10. `"scan metadata block is absent when scan_metadata has no clamav_signature key (e.g. skipped by size
    limit)"` — seeds `scan_metadata: %{"skipped" => "size_limit"}`, asserts no signature block
    renders.
11. `"an unknown media_id renders a not-found state, not a crash"`.
12. `"an unauthenticated request to /admin/media/:media_id redirects to /admin/login"` (permission
    test — mirrors the existing `on_mount {Nebu.Admin.Auth, :require_admin}` redirect assertion
    pattern used by other `live_session :admin` pages' tests).
13. `"the page issues no INSERT/UPDATE/DELETE against media_files or media_state_transitions"` — a
    regression guard asserting the module's only DB calls are the three `SELECT`s (e.g. by
    asserting on a DB-call-counting fake, or by static-analysis grep over the module source
    similar to `Nebu.Matrix.MigrationsGrantTest`'s style, dev agent's choice).

## Technical Requirements

Follows ADR-018 (inline SQL, no Repository/Service layer) and ADR-020 (no cross-domain calls
needed here — everything this story reads lives in `Nebu.Media`'s own tables).

### Module & route

- New file `server/lib/nebu/admin/media_live/detail.ex`, `defmodule Nebu.Admin.MediaLive.Detail`,
  `use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}` — same shape as
  `Nebu.Admin.LogsLive.TraceMap`/`Nebu.Admin.LogsLive.WarRoom` (a dedicated submodule under an
  existing "area" LiveView's namespace for a distinct URL with its own path param, rather than a
  new top-level module).
- Router addition in `server/lib/nebu/admin/router.ex`, inside the existing `live_session :admin`
  block (alongside `live "/audit-log", AuditLogLive, :index` etc.):

  ```elixir
  live "/media/:media_id", MediaLive.Detail, :show
  ```

- **Entry point from 5a.** Story 5a's table (`Nebu.Admin.MediaLive`) is expected to wrap each
  row's filename/media_id cell in `<.link navigate={~p"/admin/media/#{row.media_id}"}>`. If 5a
  lands first, add that link there; if this story lands first, add the minimal link to 5a's
  existing row markup as part of this story's scope — either way, exactly one of the two stories
  must leave the link in place so the detail view is actually reachable.

### Inline SQL (mount/handle_params)

Three read-only queries, each a module attribute per the existing `@sql`/`@sql_lookup` convention
(`Nebu.Admin.AuditLogLive`, `Nebu.Media.DB`):

```elixir
@sql_file """
SELECT media_id, server_name, content_type, file_size, uploader_user_id, uploaded_at,
       state, file_hash, scan_metadata, storage_key, compressed, archived_at,
       deleted_at, hard_deleted_at
FROM media_files
WHERE media_id = $1
LIMIT 1
"""

@sql_transitions """
SELECT from_state, to_state, actor_type, actor_id, metadata, inserted_at
FROM media_state_transitions
WHERE media_id = $1
ORDER BY inserted_at ASC, id ASC
"""

@sql_storage_totals """
SELECT state, COALESCE(SUM(file_size), 0), COUNT(*)
FROM media_files
WHERE state IN ('released', 'deleted')
GROUP BY state
"""
```

`@sql_storage_totals` returns at most 2 rows (one per matching state); the LiveView reduces them
into `%{active: {bytes, count}, pending_hard_delete: {bytes, count}}`, defaulting either bucket to
`{0, 0}` when Postgres returns no row for that state (AC5/AC6 — `GROUP BY` omits states with zero
matching rows entirely, it does not return a zero row, so the Elixir-side default is required).

### Storage size computation & display

- `file_size` (the existing pre-epic column, unchanged by Story 1a/12) is the **original,
  pre-compression** byte count in every case — this is what both the per-file "Größe" field and
  the storage-summary aggregates read. It is intentionally the same value regardless of the
  `compressed` flag (AC6, AT5).
- Human-readable formatting (`2.3 MB`, `512 B`, etc.): a private `human_bytes/1` helper in this
  module. If Story 5a already defines an equivalent helper on `Nebu.Admin.MediaLive` (its own AC
  requires a human-readable "Dateigröße" column), reuse/extract it rather than re-deriving the
  same rounding logic twice — dev agent's call based on what 5a's code looks like at
  implementation time.
- No new migration, no new column. This story reads exactly the columns Story 1a already added;
  it adds no schema.

### Rendering

- Metadata block, transition-history `<table>` (with `<caption>`/`<th scope="col">` per AC12),
  and the storage-summary panel are three visually distinct sections on one page — no tabs/modals
  needed for an S-sized read-only view.
- State badge color reuse: match 5a's badge-color convention exactly (do not invent a second
  palette for the same 8 states).

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/lib/nebu/admin/media_live/detail.ex` | CREATE | `Nebu.Admin.MediaLive.Detail` — mount/render, the three inline SQL queries above |
| `server/lib/nebu/admin/router.ex` | UPDATE | Add `live "/media/:media_id", MediaLive.Detail, :show` inside the existing `live_session :admin` block |
| `server/lib/nebu/admin/media_live.ex` | UPDATE (conditional) | Only if Story 5a already exists and its table rows don't yet link to the detail route — add the `<.link navigate={~p"/admin/media/#{media_id}"}>` wrapper |
| `server/test/nebu/admin/media_live/detail_test.exs` | CREATE | LiveView tests, AT1–AT13 above |

## Dev Agent Guardrails

**Do Not Change:**

- **`media_state_transitions` is append-only (ADR-031).** This story is read-only by design (AC10,
  AT13) — it must never issue an `UPDATE`/`DELETE` against `media_state_transitions`, and it must
  not attempt to "fix up" or backfill missing history rows from this LiveView. Even if AC4's
  empty-history case looks like it wants a repair action, it does not: it is a display-only empty
  state. The `BEFORE UPDATE OR DELETE` trigger from Story 1a would reject a mutation attempt
  anyway (`SQLSTATE 23001`), but the correct fix if this ever feels tempting is "don't write to
  this table here," not "catch the trigger's exception."
- **Do not add a new `media_files` column** (e.g. a "compressed byte count" or "stored size"
  column) to make the compression-ratio math work. AC6 is explicit: show the flag, not a
  fabricated ratio. If a real ratio is ever wanted, that is a new story with its own migration and
  its own decision about how/when the actual compressed size gets captured (most likely at upload
  time in Story 2b/12, not reverse-engineered later from this read-only view).
- **Do not register a new `Nebu.Compliance.AuditWriter.@known_actions` entry.** This story performs
  no admin action and writes nothing — unlike 6a/6c/6d, there is no audit-log entry for "viewed a
  file's detail page."
- **Do not implement any of 6a/6c/6d's action buttons here.** Block/Unblock/Delete/Rescan (6a),
  infected-override (6c), and bulk cohort actions (6d) are separate stories. This page may
  eventually host their controls, but wiring them in is explicitly out of scope for this story.
- **Do not join to a users/admins table to resolve `actor_id` to a name/email.** Match
  `Nebu.Admin.AuditLogLive`'s existing convention of displaying the raw actor identifier — no new
  cross-domain lookup for this S-sized story.
- This LiveView lives under `server/lib/`, which is pipeline-protected per `CLAUDE.md`. Do not
  hand-apply changes outside an active `nebu-pipeline` run.

## Dependencies

- **1a-media-files-migration** — hard dependency. This story reads `media_files`' Story-1a columns
  (`state`, `file_hash`, `scan_metadata`, `compressed`, `storage_key`, `archived_at`, `deleted_at`,
  `hard_deleted_at`) and the `media_state_transitions` table verbatim; none of it exists before 1a
  lands.
- **5a-admin-media-table** — the detail view is reached by clicking a row in 5a's table (see
  "Entry point from 5a" above); per the epic, 6b is otherwise independent of 5a's own
  filter/pagination logic — it only needs 5a's rows to link somewhere.
- **12-gzip-compression-at-rest** (loose relation, not a hard dependency) — this story displays
  the `compressed` flag Story 12 sets, but does not depend on Story 12's compression pipeline
  being implemented: `compressed` already exists (defaulted `false`) from Story 1a's migration
  regardless of whether Story 12 has landed yet, so this story can be built and tested against
  fixture rows independently of Story 12's own timeline.

## Dev Agent Record

### Corrections

- **AC7/AT8/AT10 scan_metadata key schema-reality correction (self-caught in code-review, same
  class as 5a's own `clamav_signature` fix):** this story's own AC7/Acceptance-Tests text assumed
  the ClamAV signature JSON key is plain `"signature"`. The only real writer,
  `Nebu.Workers.MediaScanWorker.infect/2` (Story 4b, landed), persists
  `%{clamav_signature: signature, scanned_at: ...}` — the real key is `"clamav_signature"`. As
  originally specified, the signature block would never have rendered for any real infected file
  in production. Fixed `scan_signature/1` (`detail.ex`), the test fixtures (`detail_test.exs`), and
  the AC7/AT8/AT10 text above in place. Kassandra's security review independently re-traced this
  fix to the actual worker source rather than accepting it at face value — confirmed correct.
- **`SUM(bigint)` → `Decimal` cast (self-caught in CI-gate, before commit):** Postgres's
  `SUM(bigint)` aggregate (`media_files.file_size` is `BIGINT`) returns `numeric`, which Postgrex
  decodes as `%Decimal{}` — without an explicit cast, `@sql_storage_totals`'s byte totals would
  have silently fallen through `Nebu.Admin.MediaLive.humanize_bytes/1`'s `is_integer/1` guard to
  its `"—"` placeholder instead of ever rendering a real total. Fixed via an explicit `::bigint`
  cast in the SQL. Kassandra independently re-verified the cast is present and CI-confirmed.
- **AT7 test-regex false positive (self-caught, before CI-gate):** an early draft of the
  compression-indicator test used `refute html =~ ~r/[Rr]atio/`, which matched the substring
  "ratio" inside "Configuration" (this admin layout's own nav item) — fixed to a word-boundary
  `~r/\bratio\b/i`.
- **Entry point from 5a:** no change needed — 5a's table already wraps each row's identity cell in
  a `<.link navigate={"/admin/media/" <> row.media_id}>` ("Ansehen") from 6a's own dev pass, so this
  story's route is reachable without touching `media_live.ex`'s render/1 template (only 3 helper
  functions were promoted `defp` → `def` for reuse — no behavior change).
