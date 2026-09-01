# Security Review — 5a-admin-media-table

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Date:** 2026-07-18 · **Epic:** media-security-admin-control
**Story flag:** `security_review: optional` — run anyway by coordinator decision (first admin surface
exposing `uploader_user_id`/`filename` PII in this epic's admin-media UI; same precedent as 9b/11b).

## Verdict: APPROVED (0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 2 INFO)

## Scope

`server/lib/nebu/admin/media_live.ex` (new — `Nebu.Admin.MediaLive`), `router.ex`/`layouts.ex` diffs,
`server/assets/tailwind.config.js`/`css/app.css`, `server/priv/static/assets/app.js`
(`MediaLoadMoreFocus` hook), `server/test/nebu/admin/media_live_test.exs`,
`e2e/features/admin/admin-media-overview.feature` + `steps.ts`, `e2e/fixtures/db.ts`
(`insertMediaFile`/`clearMediaFiles`).

## Sensitive-surface checklist (from my own BOND.md watch-list for this epic)

The watch-list I carried into this epic flags exactly this class of screen: "Attacker-controlled
content in the admin same-origin context... uploaded files (arbitrary Content-Type, filenames, EXIF,
SVG) rendered/previewed in the admin UI = stored-XSS + content-injection." This story is the first to
render `filename` — a value that arrives via the async-upload PUT handler's client-supplied
`?filename=` query parameter (Story 2b), making it a genuinely attacker-controlled string, not merely
admin-authored data.

- **Verified CLOSED for this story's scope:** AC6 explicitly excludes preview/thumbnail rendering —
  `filename`, `media_id`, and `uploader_user_id` are rendered exclusively through ordinary HEEx `{...}`
  interpolation (`media_live.ex` render/1 — identity column, uploader column). Grepped the whole file
  for `raw(`/`Phoenix.HTML.raw`/`{:safe, ...}` — zero matches. HEEx auto-escapes `{...}` unconditionally,
  so a `filename` of `<script>alert(1)</script>` renders as literal escaped text
  (`&lt;script&gt;...`), never executed markup. Confirmed by a dedicated regression test (AT20,
  `media_live_test.exs`) that seeds exactly this payload into both `uploader_user_id` and `filename`
  and asserts the raw tag never appears unescaped in the rendered HTML. The remaining, still-open half
  of the watch-list item (actual file *content* preview/thumbnail, cross-origin asset serving, SRI) is
  correctly **out of scope** — this story ships no preview/thumbnail surface at all (AC6, Guardrails),
  so there is nothing here for that half of the watch-list to apply to yet. Still open for whichever
  future story adds a preview/thumbnail.
- **Authz on the endpoint:** `router.ex` places `live "/media", MediaLive, :index` inside the existing
  `live_session :admin do ... end` block, gated by the session-wide `on_mount: {Nebu.Admin.Auth,
  :require_admin}` — the SAME gate every other remaining admin LiveView uses, not a bespoke or
  action-scoped check that could be misconfigured to exempt this one route. Confirmed via a dedicated
  test (AT19) asserting a non-admin session is redirected to `/admin/login` before any row ever renders
  (not merely before some action — `live/2` itself returns `{:error, {:redirect, ...}}`, i.e. the
  LiveView process never mounts far enough to run a single query).
- **This story ships no destructive/mutating action** (Block/Unblock/Delete/Rescan/Override are
  explicitly out of scope — Guardrails) — the "destructive cleanup ops need audit_log + four-eyes"
  watch-list item does not apply here; there is nothing to audit-log since nothing is written. Every
  query in this diff is a `SELECT`/`SELECT COUNT(*)` against `media_files`.

## Verified CLEAN (adversarial pass over the query-composition layer)

- **SQL injection:** `build_where/2` (media_live.ex) never string-interpolates a filter VALUE into SQL
  text — only the parameter INDEX (a compile-time-bounded integer the function itself computes) is
  interpolated. `condition_sql/2` produces the SQL template (`state = ANY($n::media_state[])`,
  `content_type LIKE $n`, `uploader_user_id ILIKE $n`, `uploaded_at >= /<= $n`); `bound_value/2` builds
  the actual runtime value (wrapping `mime_prefix`/`uploader` with `%` wildcard markers IN ELIXIR, not
  in the SQL string) and that value always travels as a `Postgrex` bind parameter. Traced every one of
  the 5 filter dimensions plus the cursor predicate (`cursor_clause/2`) — all parameterized, none
  concatenated.
- **State-filter enum-injection guard:** `parse_states/1` filters the incoming `state[]` URL param
  against a compile-time allowlist (`@all_states`, the module's own 9 real `media_state` ENUM values)
  BEFORE it ever reaches the `::media_state[]`-cast query. An attacker cannot smuggle an arbitrary string
  into that cast (which would just raise a Postgres error harmlessly anyway, given it's still a bound
  param — but the allowlist closes even that noisy failure mode).
- **Cursor tampering:** `parse_cursor/1` base64-decodes and pattern-matches an opaque, attacker-suppliable
  `cursor` URL param; any malformed/tampered value falls through to `nil` (safe default: restart from
  page 1), never crashes, never reaches SQL unvalidated (the decoded `{ts, media_id}` tuple, if
  successfully parsed, still only ever becomes bound parameters in `cursor_clause/2`, same as every
  other filter value). Since the caller is already a fully-privileged admin with unrestricted read
  access to the same table via the unfiltered/no-cursor path, a crafted cursor cannot reveal anything
  the admin session could not already query directly — no confidentiality boundary crossed.
- **"Select all matching filter" is bounded:** `fetch_all_matching_ids/1` caps at
  `@select_all_cap + 1` (5,001) rows and truncates client-side-visible selection to 5,000 with an
  explicit notice — matches the Technical Requirements' own stated bound; not an unbounded-result DoS
  vector.
- **CSRF:** LiveView's own socket-connect-time CSRF token verification applies uniformly to every
  `phx-click`/`phx-change` event on this page — no custom bypass, no `admin_csrf_bypass` interaction (that
  seam only affects the plain-HTTP `:browser` pipeline's `protect_from_forgery` plug for POST-form
  controllers, not the LiveView socket handshake).
- **E2E fixture (`fixtures/db.ts` `insertMediaFile`):** reuses the already-vetted `sqlLiteral`/`runSql`
  helpers this file established for `operational_logs`/`war_room_sessions` seeding (single-quote
  escaping via `.replace(/'/g, "''")`); values passed at call sites are Gherkin-feature-file literals,
  not externally-supplied input, and this file never ships to production (test-harness-only, outside
  the deployed server). Same accepted trust boundary as the rest of this file.

## INFO (non-blocking)

- **INFO-1:** No dedicated rate limit on the `toggle_select_all` handler beyond the general admin-auth
  gate — an authenticated admin could repeatedly trigger the capped (5,001-row) query. Acceptable: the
  actor is already fully privileged and the query is bounded; matches the same non-rate-limited posture
  every other admin filter/count query on this page (and sibling admin pages) already has.
- **INFO-2:** `mime_prefix`/`uploader` substring filters let an admin embed literal `%`/`_` LIKE
  wildcards, broadening their own match beyond the literal string typed. Not a vulnerability — the actor
  already has unrestricted read access to every row in `media_files` regardless of filter (there is no
  per-admin row-level restriction this could bypass), so a broader-than-intended match reveals nothing
  the admin couldn't already see via an unfiltered page load.

## Summary for pipeline log

APPROVED, 0 CRITICAL/HIGH/MEDIUM/LOW, 2 INFO (both accepted, non-blocking). Confirms my own BOND.md
watch-list item ("attacker-controlled filenames rendered in the admin origin") is correctly closed for
THIS story's read-only, no-preview scope via HEEx auto-escaping + a dedicated regression test — the
still-open half (actual file-content preview/thumbnail, cross-origin asset CSP/SRI) remains a live watch
item for whichever future story adds a preview surface, not resolved by this one.
