# Security Review — 6b-file-detail-storage-summary

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Date:** 2026-07-19 · **Epic:** media-security-admin-control
**Story flag:** `security_review: optional` — run anyway by coordinator decision (new admin surface
exposing `file_hash`/`uploader_user_id`/full transition-actor history; same precedent as 5a/6a).

## Verdict: APPROVED (0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 2 INFO)

## Scope

`server/lib/nebu/admin/media_live/detail.ex` (new — `Nebu.Admin.MediaLive.Detail`), `router.ex` diff
(+1 route), `media_live.ex` diff (three helpers promoted `defp` → `def` for reuse, no behavior change),
`server/test/nebu/admin/media_live/detail_test.exs` (new, 17 tests), and the story file's own AC7/AT8/AT10
correction.

## Sensitive-surface checklist (from my own BOND.md watch-list for this epic)

The watch-list I carry into this epic explicitly names "6b detail-view" as the trigger point to
re-check the still-open half of the attacker-controlled-content item: *"The FILE-CONTENT-preview/
cross-origin-asset/SRI half of this item is still fully open — re-check in full whenever a future
story (6b detail-view or later) adds an actual preview/thumbnail surface."*

- **Verified: this story does NOT close that watch-item, and does not need to.** `detail.ex` renders
  no image, no thumbnail, no content-type-conditional inline body, and fetches no bytes from the
  object store at all — the three SQL queries (`@sql_file`/`@sql_transitions`/`@sql_storage_totals`)
  read only `media_files`/`media_state_transitions` metadata columns. There is no preview surface in
  this diff for the watch-item to apply to. **The item stays open, correctly, for whichever future
  story (still 6c/6d per the epic's current story list, or a later one) actually adds a
  thumbnail/content preview.** I am not closing it here — closing it would require verifying a preview
  surface that does not exist in this diff.
- **Authz on the endpoint:** `router.ex` places `live "/media/:media_id", MediaLive.Detail, :show`
  INSIDE the existing `live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin} do ... end`
  block (confirmed by reading the actual diff context, not just the added line) — the same
  session-wide gate 5a/6a/every remaining admin LiveView uses (MEMORY pattern #67: `live_session`
  `on_mount` is the whole-subtree gate covering both static HTTP render and websocket connect — no
  bare `live` route sits outside it). `Nebu.Admin.Auth.on_mount(:require_admin, ...)` reads identity
  from the signed session (`session["current_user"]`), not from socket/URL params — no new trust
  boundary introduced. Confirmed by a dedicated test (`AT12`/permission test) asserting
  `live(non_admin_conn) == {:error, {:redirect, %{to: "/admin/login"}}}` — the LiveView process never
  mounts far enough to run a single query for an unauthenticated caller.
- **This story ships no destructive/mutating action** (AC10, verified — see "Read-only" below) — the
  "destructive cleanup ops need audit_log + four-eyes" watch-list item does not apply; nothing is
  written, so there is nothing to audit-log. Consistent with 6a's four real mutating actions living in
  a *separate* module (`Nebu.Admin.MediaLive`), untouched by this diff.

## Verified CLEAN (adversarial pass)

- **SQL injection:** all three module-attribute queries (`@sql_file`, `@sql_transitions`,
  `@sql_storage_totals`) bind `media_id` as `$1` — never string-interpolated into SQL text.
  `@sql_storage_totals` takes no external input at all (it aggregates over a fixed `state IN
  ('released','deleted')` predicate with zero caller-supplied values). Grepped the whole module for
  `<>`/`#{}` anywhere near a `@sql_*` block or `Ecto.Adapters.SQL.query` call site — none found.
- **XSS:** every rendered field goes through ordinary HEEx `{...}` interpolation
  (`content_type`, `uploader_display/1`, `humanize_bytes/1`, `truncated_hash/1`, `badge_label/1`,
  `compression_label/1`, `scan_signature/1`, `actor_display/2`, `format_ts/1`) — grepped for
  `raw(`/`Phoenix.HTML.raw`/`{:safe, ...}` across the file: zero matches. The one attribute-context
  interpolation (`title={@file.file_hash}`) also goes through HEEx's `Phoenix.HTML.Safe` escaping for
  attribute values, same protection as every `{...}` in element content — a hash containing `"` cannot
  break out of the attribute. Independently re-verified the dev's own regression test (seeds
  `content_type`/`uploader_user_id` = `<script>...</script>`, asserts the raw tag never appears
  unescaped and `&lt;script&gt;` does) actually exercises this path — it does (`live/1` + `html =~`
  against a real mounted page, not a unit test of the helper in isolation). Transition `metadata`
  (JSONB) is never rendered by this module at all (not in AC3's field list) — nothing to escape because
  nothing is shown; correctly scoped, not an omission.
- **Read-only (AC10, ADR-031 append-only):** confirmed no `INSERT`/`UPDATE`/`DELETE` anywhere in the
  three `@sql_*` blocks (all three are `SELECT`s). No call to `Nebu.Compliance.AuditWriter` anywhere in
  the module (no new `@known_actions` entry needed, matches AC10). Independently re-verified the dev's
  own regression test: it snapshots `COUNT(*)` on both tables plus the seeded row's exact column values
  BEFORE `live/1` mount+render and asserts byte-identical AFTER — a real behavioral proof, not just a
  static grep (the file also has a static grep as a second layer, which I independently re-ran by hand
  against the actual current file content — clean).
- **CSRF:** N/A — no `phx-click`/`phx-change`/form submit anywhere in this template (verified: zero
  `phx-*` event bindings in the whole render/1). A page with no mutating client event has nothing for
  CSRF to protect.
- **Open redirect:** the one `<.link navigate="/admin/media">` (rendered twice, not-found page and
  normal page) is a hardcoded literal string in both call sites — no user-controlled redirect target
  anywhere in this diff.
- **IDOR / cross-tenant read:** `media_id` from the URL path is used to look up ANY `media_files` row
  with no ownership scoping — this is the intended admin capability (the whole `/admin/media` surface,
  5a/6a/6b alike, is "an admin can see every file, gated by role, not by row ownership"), identical in
  shape to 5a's own unfiltered table and 6a's own block/unblock/delete-by-id actions. Not a new
  authorization gap introduced by this story — same gate, same intended cross-user visibility.
- **Independently re-verified both dev-side self-reported fixes** (did not take them at face value,
  per the coordinator's explicit ask):
  1. **AC7 scan_metadata key drift** (`"signature"` → `"clamav_signature"`): confirmed
     `Nebu.Workers.MediaScanWorker.infect/2` (`lib/nebu/workers/media_scan_worker.ex:145`) persists
     `%{clamav_signature: signature, scanned_at: ...}` — the real key is `clamav_signature`, exactly as
     the dev's fix now reads (`scan_signature/1` pattern-matches `%{"clamav_signature" => signature}`).
     As originally written against the story's stale text, the signature block would have silently
     never rendered for any real infected file in production — a real bug, correctly caught and fixed,
     not just claimed.
  2. **`SUM(bigint)` → `Decimal` cast**: confirmed `media_files.file_size` is `BIGINT`
     (`000001_init.up.sql`), and Postgres's `SUM(bigint)` aggregate does return `numeric` (Postgrex
     decodes as `%Decimal{}`), which would silently mis-render as `humanize_bytes/1`'s `"—"` fallback
     (guarded by `is_integer/1`) without the `::bigint` cast the dev added to `@sql_storage_totals`.
     Confirmed the cast is present in the current file (line 83) and confirmed via the dev's own CI-gate
     log that the fix was verified against a real Postgres run (2412 tests, 0 DetailTest failures) —
     both fixes are real and correctly applied, not just asserted.

## Watch-flag re-confirmation: 1b's I-1 (metadata stored-XSS constraint for Story 6)

Story 1b's own security review (2026-07-13) flagged `media_state_transitions.metadata` as
"stored verbatim... attacker-influenced downstream (ClamAV signature names, admin reason text)...
[r]endering it inline in the admin origin later (Story 6) is a stored-XSS surface" — and 6a's own
session log explicitly carried this forward as "6b (detail view) still owns... re-confirm when that
story's diff lands." **Re-confirmed: this story does NOT render `metadata` anywhere.** `@sql_transitions`
selects the column (it travels through `row_to_transition/1` into the `:metadata` map key), but
`render/1`'s transition-history table renders only `t.from_state`/`t.to_state`/`actor_display(t.actor_type,
t.actor_id)`/`format_ts(t.inserted_at)` — `t.metadata` is fetched but never interpolated into the
template. Since it is never rendered, HEEx's auto-escaping guarantee is not even needed to close this
one — there is nothing on the page for a stored payload in `metadata` to reach. **This watch-flag
remains open**, unchanged, for whichever future story actually surfaces `metadata` (e.g., showing an
admin's free-text block/delete reason) — that story must render it through ordinary HEEx interpolation
only, exactly as this story does for every other field.

## INFO (non-blocking)

- **INFO-1 — `fetch_transitions/1` has no `LIMIT`.** `Nebu.Admin.AuditLogLive`'s own sibling query caps
  at `LIMIT 200` as a defense-in-depth hygiene convention; this module's `@sql_transitions` fetches
  every row for one `media_id` unbounded. In practice this is bounded by the state machine's own legal
  edges (repeated block/unblock/rescan cycles, all admin-gated actions — an authenticated admin
  inflating their own audit trail, not an external/lower-privileged attacker), and AC3 is explicit
  ("Every row... is rendered") — a silent `LIMIT` would violate the story's own stated completeness
  requirement. Not a vulnerability, not blocking; a forward watch-flag if a future story ever needs
  pagination here (mirrors the `AuditLogLive` precedent without contradicting this story's own AC).
- **INFO-2 — `fetch_storage_totals/0` runs unconditionally, even for an unknown `media_id`.** The
  page-level aggregate query executes on every mount regardless of whether the file lookup succeeds
  (by design — AC5 scopes it to "all `media_files` rows", not the one being viewed), so a 404 costs the
  same one extra `GROUP BY` query as a hit. Bounded, admin-gated, and the identical query the success
  path already runs unconditionally — not a new DoS surface, just a minor efficiency note.

## Summary for pipeline log

APPROVED, 0 CRITICAL/HIGH/MEDIUM/LOW, 2 INFO (both accepted, non-blocking). Both dev-self-reported
fixes (AC7 schema-reality key drift, `SUM(bigint)`→`Decimal` cast) independently re-verified as real
and correctly applied — not rubber-stamped. Confirms my own BOND.md watch-item ("file-content-preview/
cross-origin-asset/SRI half of attacker-controlled-content-in-admin-origin") remains correctly OPEN —
this story adds no preview/thumbnail surface, so there was nothing here to close; the item stays live
for whichever future story actually adds one.
