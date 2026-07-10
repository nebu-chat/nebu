# Pre-implementation Design Decisions — admin-logs-retention-settings

Resolved by the pipeline coordinator (headless session) by reading the actual
already-shipped sibling code (operational-log-store, admin-logs-monitoring-view),
NOT by guessing. Treat these as authoritative — they override any conflicting
guess in the story's own Dev Notes (which was written before the siblings existed).

## 1. Real server_config keys (do NOT use the story's placeholder names)

`operational-log-store` already shipped these 5 keys (see
`server/lib/nebu/web/log_store/policy_cache.ex` @defaults and
`server/lib/nebu/admin/db.ex` `@log_policy_cache_keys`):

- `log_collect_info` (boolean)
- `log_retention_info_days` (integer or nil)
- `log_collect_debug` (boolean)
- `log_retention_debug_days` (integer or nil)
- `log_retention_debug_max_count` (integer or nil)

The story's AC8/AC9 require an INFO "max entries" field too (mirroring DEBUG),
but NO such key exists yet. Add ONE new key, `log_retention_info_max_count`
(integer or nil) — same shape/semantics as `log_retention_debug_max_count` —
via this story's migration, and add it to `Nebu.Admin.DB.upsert_server_config/1`'s
`@log_policy_cache_keys` cache-invalidation list AND to
`Nebu.Web.LogStore.PolicyCache.@defaults`. Extend
`Nebu.Web.LogStore.Retention.prune_operational_logs/0` with a symmetrical
`prune_max_count("info", policy.log_retention_info_max_count)` call (the
`prune_max_count/2` helper is already level-generic — no new SQL needed).

Do NOT use `info_enabled`/`info_days`/`info_max_entries`/`debug_enabled`/etc.
(the story's placeholder names) or `info_collection_enabled`/
`debug_collection_enabled` (the Dev Notes' guessed names) as actual DB keys.
The HTML *form field* names in AC13's example JSON (`info_enabled`, `info_days`,
etc.) are fine to keep as form param names — just map them to the real
`log_*` keys in the controller before persisting.

## 2. Route architecture: plain Controller, NOT LiveView (per AC13, literally)

AC13 is explicit and unambiguous: "The page is a traditional POST form (not
LiveView)." Follow `Nebu.Admin.ConfigController` exactly (plug-based
`:require_admin`, `render_config/1` pattern, injectable writer seam via
`Application.get_env(:nebu_http, ...)`).

Known tension: `Nebu.Admin.LogsLive.TraceMapBubble`'s moduledoc (written by
the *previous* story's dev agent, speculatively, before this story existed)
assumes `:configure` mode will be driven by a bare `phx-click` event name —
i.e. it assumed this story would be a LiveView. That assumption in a code
comment is NOT authoritative over this story's own explicit AC13. Resolve
per THIS story's own Dev Notes (`### Notes on the Phoenix.Component Pattern`,
point 4): reuse `<.trace_map_bubble>` ONLY for visual styling (color/size/
shape via `mode={:configure}`), not for interaction. Concretely:

- `phx-click`/`on_click` on the reused bubble is INERT on this page (no
  LiveView socket is ever established for a plain controller-rendered
  template) — pass any harmless placeholder value (e.g. a literal string);
  it will never fire.
- Real interactivity (AC7: click toggles ON/OFF, reveals/hides retention
  fields; AC8: pre-fill defaults on first-enable) is implemented with a
  small vanilla-JS wiring function added to `priv/static/assets/app.js`,
  following the EXISTING pattern used for `wireConfirmForms`/
  `wireTraceMapFilters` (CSP `script-src 'self'`, no inline `<script>`):
  a `wireLogsConfigToggles()` function that, on click of a bubble button,
  toggles a sibling hidden `<input type="checkbox" name="info_enabled">`'s
  checked state, toggles the retention-fields `<div>`'s visibility, updates
  `aria-pressed`/visual active class, and (for DEBUG only) toggles the
  warning text's visibility.
- The actual persistence round-trip is a REAL native form submit (a
  `<button type="submit">Save</button>` at the bottom of the form) — no
  AJAX, no LiveView — matching AC13/AC14/AC15 exactly.

## 3. AC17 — PubSub: Option A (no PubSub), per the story's own explicit fallback

The story says clarify, but also explicitly pre-authorizes Option A ("For
this story, Option A (simple, no PubSub) is acceptable as a first
implementation"). Running headless with no strong signal favoring Option B
(no other part of the codebase depends on a `admin:logs:config:change`
topic yet) — choosing Option A. Acceptance Test 16 explicitly allows this
("If Option A: test is skipped or marked as `:pending`"). Do not block on
this; mark AT16 `@tag :pending` with a one-line comment citing this decision.

## 4. WARN/ERROR unbounded retention gap (Kassandra follow-up, operational-log-store review)

Kassandra's review of operational-log-store flagged (MEDIUM, explicitly
deferred to THIS story): WARN/ERROR are pruned by NOTHING —
`Nebu.Web.LogStore.Retention.prune_operational_logs/0` only prunes INFO
(TTL) and DEBUG (TTL + max-count). This story's own AC6 forbids adding a
UI control for WARN/ERROR ("non-interactive... do not expand to reveal
retention fields") — so the fix must NOT be a new admin-configurable
setting/toggle. Resolution: add a hardcoded (not admin-configurable, no new
server_config key, no UI) backend safety-net TTL in
`Nebu.Web.LogStore.Retention` — prune WARN and ERROR rows older than 90 days
(matching the same upper bound (90) already used elsewhere in this story's
own AC10 validation for INFO/DEBUG days, so it is not an arbitrary new
magic number). This closes the disk-exhaustion/GDPR-storage-limitation gap
without touching AC6's "always-on, non-interactive" UI contract at all —
it is pure backend housekeeping, symmetrical with the existing `prune_ttl/2`
helper (already level-generic).

## 4b. Migration mechanics — RLS allowlist, not a generic key-allowlist

`Nebu.Admin.DB.upsert_server_config/1` itself does NOT gate which keys can be
written in Elixir code — the gate is a Postgres RLS policy on `server_config`:
`config_update_mutable` (see `server/priv/migrations/000017_operational_logs.up.sql`,
which already added the 5 existing log-policy keys, following the precedent
in `000013_config_oidc_scopes_mutable.up.sql`/`000016_...`). A first-ever
INSERT of a brand-new key is always allowed (separate `config_insert_only`
policy, unconditional) — but a SECOND write (UPDATE, i.e. every write after
bootstrap/first-set) requires the key to be in `config_update_mutable`'s
`key IN (...)` list, or the UPDATE silently affects 0 rows (RLS `USING`
clause fails, no error raised — just a no-op).

This story's new migration (next sequence number, e.g.
`000018_config_log_info_max_count_mutable.up.sql`) must `DROP POLICY IF
EXISTS config_update_mutable` and `CREATE POLICY ... USING (key IN (...))`
with the FULL existing key list (copy verbatim from 000017) PLUS the one new
key `log_retention_info_max_count`. Write a matching `.down.sql` that
recreates the policy with the list from 000017 (i.e. without the new key).
This is the exact gap Kassandra's security review will check for on this
story — a controller that writes a key NOT in this RLS allowlist fails
silently (UPDATE affects 0 rows) after the first write, which is itself a
subtle, easy-to-miss bug class in this codebase; do not skip the migration.

## 4c. app.js wiring — confirmed pattern, exact insertion point

`server/priv/static/assets/app.js`'s `boot()` (around line 594) unconditionally
calls `wireConfirmForms()`, `wireUserAutocomplete()`, `wireTraceMapFilters()`,
`wireDetailPanelFocus()`, `wireLiveUpdatesPause()` BEFORE the `window.Phoenix`/
`window.LiveView` presence check — i.e. these all run even on "dead controller
render" pages with no LiveView socket (the moduledoc for `wireConfirmForms`,
around line 15-27, explicitly documents this: CSP is `script-src 'self'`, no
`unsafe-inline`, so this external file is the only place client interactivity
can live on such pages — exactly this story's `/admin/logs/config` page).
Add `wireLogsConfigToggles()` to that same list in `boot()`, implemented
using the same `document.addEventListener("submit"/"click", ..., true)`
delegated-listener style as `wireConfirmForms`/`wireUserAutocomplete` (no
`onclick=` inline attributes, CSP-safe).

## 5. Nav link placement (AC3)

`admin-logs-monitoring-view`'s `Nebu.Admin.LogsLive.render/1` (monitoring
page) currently has NO link to a config page (it didn't exist yet when that
story shipped). This story must ADD the "Sammlung konfigurieren →" link
into `logs_live.ex`'s existing render/1, near the `<h1>Logs</h1>` heading
(e.g. immediately after it, as a small `<.link navigate="/admin/logs/config">`
or plain `<a href="/admin/logs/config">`). This is an in-scope, expected
modification to the sibling's already-shipped file — the sibling's own File
List / Dependencies section anticipates it.

## 5b. Exact router.ex insertion point

`server/lib/nebu/admin/router.ex`, inside the same `scope "/", ...` block
that holds the other converted-controller routes, immediately after the
"Config" block (after `post "/config/sso-schemes", ConfigController,
:save_sso_schemes"`, around line 191, before the "Claim mapping" comment):

```elixir
# Logs configuration (enhanced-logging/admin-logs-retention-settings)
get "/logs/config", LogsController, :index
post "/logs/config/retention", LogsController, :save_retention
```

Module name: `Nebu.Admin.LogsController` (matches the story's own File List).
Do NOT place these inside the `live_session :admin do ... end` block a few
lines down (that block is exclusively for the 3 remaining real LiveViews —
DashboardLive/AuditLogLive/LogsLive — this is a plain controller, per
design-decisions.md #2).

View module: name it `Nebu.Admin.LogsConfigHTML` (avoids ambiguity with the
sibling `Nebu.Admin.LogsLive` module) with `embed_templates
"templates/logs_config/*"` and a single `templates/logs_config/index.html.heex`
template — mirrors `Nebu.Admin.ConfigHTML`'s exact pattern
(`embed_templates "templates/config/*"` + `templates/config/index.html.heex`
+ controller calls `render(:index)`), rather than the story's own guessed
path (`templates/logs/config.html.heex`) which doesn't match this
codebase's established per-controller-subdirectory convention.

## 6. Level display order for THIS page only (AC5)

`Nebu.Admin.LogsLive.@levels` is `["error", "warning", "info", "debug"]`
(monitoring page's own order — do not change it, out of scope). This
story's OWN config page must render bubbles in the literal AC5 order: WARN,
ERROR, INFO, DEBUG. Use a local `@levels` order specific to the new
controller/template, independent of the monitoring page's list.
