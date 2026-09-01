---
story_id: 9b-media-settings-ui
title: "Media Policy Settings: /admin/media/settings UI"
epic: media-security-admin-control
status: done
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 9a introduces the `media_config` table and `Nebu.Media.Config` (the sole public-API
seam — ADR-020) for the media policy values that today are hardcoded in `config.exs`. This
story exposes those values as an admin-editable settings page at `/admin/media/settings`,
following the pattern the codebase already established for `/admin/config`
(`Nebu.Admin.ConfigController`) and, even more closely, `/admin/logs/config`
(`Nebu.Admin.LogsController` — bounds-validated numeric settings, same plug-based admin gate,
same flash-only success/error messaging).

**Deliberately a plain HTTP controller, not a LiveView.** The framing in the epic ("Story 9b —
`/admin/media/settings` UI") predates the codebase's AC12 conversion; `Nebu.Admin.Router`'s
moduledoc is explicit that `ConfigLive` and sibling settings LiveViews were converted to plain
controllers, and that only three LiveViews remain, each justified by an explicit real-time
requirement (`DashboardLive`, `AuditLogLive`, `LogsLive`/`LogsLive.TraceMap`). Media policy
settings have no such requirement — a value is read on page load and written on submit, exactly
like `/admin/logs/config`. This story therefore implements `Nebu.Admin.MediaSettingsController`,
matching `Nebu.Admin.LogsController`'s and `Nebu.Admin.ConfigController`'s conventions
byte-for-byte rather than introducing a fourth LiveView exception.

## User Story

**As** a Nebu admin,
**I want** to view and edit the media policy values (upload/scan size limits, pending-upload
limit, stall timeout, retention windows, webhook URL) at `/admin/media/settings`,
**so that** I can tune these limits at runtime — without a redeploy — as usage patterns and
compliance requirements change.

## Acceptance Criteria

1. **Route & rendering.** `GET /admin/media/settings` renders a form pre-filled with the
   current value of every `media_config` key from Story 9a: `max_upload_size_bytes` (413
   boundary, Story 2b), `max_file_size_bytes` (ClamAV scan boundary, Story 3 — rendered with a
   hint that files above this size are never scanned), `max_pending_per_user` (429 limit,
   default 20), `max_stall_ms` (default 20000), `deleted_days` / `infected_days` /
   `orphaned_hours` (retention, Story 8a/8b), `webhook_url` (Story 7), and
   `released_delete_after_days` (Story 8d, default `nil`). Values come from
   `Nebu.Media.Config.get/0` (DB override with fallback to the `config.exs` default) — i.e.
   env-var pre-fill on first load, before any value has ever been saved to `media_config`.
2. **Server-side validation matches 9a's contract.** Every numeric field is validated
   server-side for a lower/upper bound and rejects negative values before the request reaches
   `Nebu.Media.Config.upsert/1` — client-side (HTML `min`/`max` or JS) hints are convenience
   only, never a substitute for the server check, matching this project's plain-HTTP-form
   convention (no LiveView `handle_event("validate", …)` exists on this page).
3. **`webhook_url` save-time validation.** HTTPS is required; private, loopback, link-local,
   and other non-routable IP ranges are blocked at save time (same class of check already
   implemented for outbound fetches in `Nebu.Media.SSRF`, and the same posture the project
   already applies to SCIM/OIDC directory URLs).
4. **Stronger warning on `released_delete_after_days` nil → value.** When the submitted value
   changes `released_delete_after_days` from unset (`nil`, meaning "never auto-delete released
   files") to a concrete number of days, the page surfaces an explicit, harder-to-miss warning
   (not merely the generic success flash) before/at the point of save, since this newly enables
   automatic deletion of released media that previously persisted indefinitely.
5. **Persistence only via `Nebu.Media.Config`.** Every save goes through
   `Nebu.Media.Config.upsert/1` (Story 9a's public API). This controller and its template never
   issue SQL against `media_config` directly (ADR-020 — cross-domain calls only through the
   owning namespace's public-API module).
6. **Flash messaging.** A successful save shows a success flash (short, past tense, matching
   `Nebu.Admin.ConfigController`/`Nebu.Admin.LogsController` copy style, e.g. "Media settings
   saved"); a failed validation shows an error flash with the first specific validation message
   and re-renders the form at HTTP 200 with the submitted (invalid) values preserved, not
   silently discarded.
7. **Admin-only access.** The page is gated by `Nebu.Admin.Auth`'s `:require_admin` plug,
   identical to every other admin settings controller; an unauthenticated or non-admin request
   is redirected to `/admin/login` with a flash, not served a 403.
8. **Accessibility (hard constraint, not a guideline, per this project's Admin UI convention).**
   Every input has an associated `<label>` (or `aria-label`, matching the established
   `ConfigController` pattern); the form is fully operable by keyboard using native form
   controls only (no custom widgets that bypass native tab order); the success/error flash uses
   `role="status"` / `role="alert"` respectively so assistive technology announces the outcome
   of a save without requiring focus to move.

## Acceptance Tests

Concrete test names for
`server/test/nebu/admin/media_settings_controller_test.exs`
(`Nebu.Admin.MediaSettingsControllerTest`), following the `describe "ACn: …"` /
`test "…"` convention and the `Plug.Test`-conn-building style already used in
`config_controller_test.exs` and `logs_controller_test.exs` — no `Phoenix.LiveViewTest` helpers,
since this is a plain controller, not a LiveView:

- `describe "AC1: GET /admin/media/settings renders current values"`
  - `test "renders all nine media_config fields pre-filled with their current stored values"`
  - `test "a key with no media_config row falls back to its config.exs default (env-var pre-fill on first load)"`
- `describe "AC2: numeric bounds validation"`
  - `test "max_upload_size_bytes out of bounds fails validation, re-renders at 200, does not persist"`
  - `test "a negative value for any numeric field is rejected without reaching Nebu.Media.Config.upsert/1"`
  - `test "non-numeric input for a numeric field is rejected with a specific error message"`
- `describe "AC3: webhook_url save-time validation"`
  - `test "a webhook_url with an http:// (non-HTTPS) scheme is rejected"`
  - `test "a webhook_url resolving to a private or link-local IP range is rejected"`
- `describe "AC4: released_delete_after_days nil-to-value warning"`
  - `test "changing released_delete_after_days from unset to a concrete value renders the stronger warning copy, not just the generic success flash"`
  - `test "changing released_delete_after_days between two concrete values does not trigger the stronger warning"`
- `describe "AC5: persistence goes through Nebu.Media.Config exclusively"`
  - `test "a valid submission calls Nebu.Media.Config.upsert/1 and never issues a direct media_config INSERT/UPDATE"`
- `describe "AC6: flash messaging"`
  - `test "a valid update persists and shows a success flash"`
  - `test "an invalid submission shows an error flash and re-renders with the submitted values preserved"`
- `describe "AC7: admin-only access"`
  - `test "an unauthenticated request to GET /admin/media/settings is redirected to /admin/login"`
  - `test "a non-admin session's POST /admin/media/settings is redirected to /admin/login, not persisted"`
- `describe "AC8: accessibility"`
  - `test "every form input has an associated label or aria-label"`
  - `test "the success flash carries role=\"status\" and the error flash carries role=\"alert\""`

## Technical Requirements

- **Controller:** `Nebu.Admin.MediaSettingsController`
  (`server/lib/nebu/admin/media_settings_controller.ex`). Mirrors
  `Nebu.Admin.LogsController`'s structure (module-attribute `{min, max}` bounds tuples per
  numeric field, a `validate_and_normalize/1` pipeline built from small per-field
  `validate_bound/4`-style helpers) and `Nebu.Admin.ConfigController`'s plug/flash conventions.
  `use Phoenix.Controller, formats: [:html]`; `plug Nebu.Admin.Auth, :require_admin`.
- **Template:** `Nebu.Admin.MediaSettingsHTML`
  (`server/lib/nebu/admin/media_settings_html.ex`, `embed_templates` wrapper, same shape as
  `config_html.ex`/`logs_html.ex`) + `server/lib/nebu/admin/templates/media_settings/index.html.heex`.
- **Router:** add to `server/lib/nebu/admin/router.ex`, in the existing `scope "/admin",
  Nebu.Admin do … pipe_through :browser` block (plain `get`/`post`, not `live`):
  ```elixir
  get "/media/settings", MediaSettingsController, :index
  post "/media/settings", MediaSettingsController, :save
  ```
  No entry is added to `live_session :admin` — per AC12/the router moduledoc, this page is
  deliberately not one of the three real-time LiveView exceptions.
- **No `Ecto.Changeset`.** Per ADR-018 (No Domain Model), validation is plain Elixir functions
  operating on the raw params map, exactly like `Nebu.Admin.LogsController.validate_and_normalize/1`
  / `validate_level/2` / `validate_bound/4` — not a changeset/schema.
- **`webhook_url` validation:** reuse (do not re-derive) the private/loopback/link-local
  IP-blocking logic already implemented in `Nebu.Media.SSRF`
  (`server/lib/nebu/media/ssrf.ex`) rather than writing a second SSRF guard; this is a save-time
  check on a stored config value, not a per-request outbound fetch, but the underlying
  "resolve and reject non-routable ranges" logic must not be duplicated.
- **Persistence seam:** `Nebu.Media.Config.get/0` (read, to pre-fill the form) and
  `Nebu.Media.Config.upsert/1` (write, on save) — the *only* calls this controller makes into
  the `Nebu.Media` namespace (ADR-020). No `Postgrex`/`Ecto.Adapters.SQL` call against
  `media_config` from this module or its template.
- **Nav wiring:** add a "Settings" child link into the nested "Medien" parent nav item
  established by Story 0 (media-admin-ux-foundation) in `server/lib/nebu/admin/layouts.ex`,
  following the existing `@logs_nav_children` / `@config_nav_children` module-attribute-list
  pattern. This story does not create the "Medien" parent nav item itself — only the child
  entry pointing at `/admin/media/settings`.
- **Test file:** `server/test/nebu/admin/media_settings_controller_test.exs`
  (`Nebu.Admin.MediaSettingsControllerTest`), built the same way as
  `config_controller_test.exs`/`logs_controller_test.exs` — a `Plug.Test` conn against
  `@endpoint Nebu.Admin.Endpoint` with a session-seeded `current_user`, no
  `Phoenix.LiveViewTest`.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/admin/media_settings_controller.ex` | New | `index/2`, `save/2`, per-field bounds/`webhook_url` validation helpers |
| `server/lib/nebu/admin/media_settings_html.ex` | New | `embed_templates` wrapper (mirrors `config_html.ex`/`logs_html.ex`) |
| `server/lib/nebu/admin/templates/media_settings/index.html.heex` | New | Settings form + flash rendering |
| `server/lib/nebu/admin/router.ex` | Modified | Add `GET`/`POST /admin/media/settings` routes |
| `server/lib/nebu/admin/layouts.ex` | Modified | Add "Settings" child to the "Medien" nested nav item (Story 0) |
| `server/test/nebu/admin/media_settings_controller_test.exs` | New | ATDD tests per the Acceptance Tests section |

## Dev Agent Guardrails

### Do Not Change

- Do not query or write the `media_config` table directly from this controller or its
  template — always go through `Nebu.Media.Config.get/0` / `Nebu.Media.Config.upsert/1`
  (ADR-020 public-API rule; Story 9a owns the table and is the only write seam).
- Do not implement this page as a LiveView. Per AC12 and the `Nebu.Admin.Router` moduledoc,
  settings pages without a genuine real-time requirement are plain HTTP controllers
  (`ConfigController`/`LogsController` precedent) — do not add a fourth LiveView exception
  alongside `DashboardLive`/`AuditLogLive`/`LogsLive`.
- Do not introduce `Ecto.Changeset`, an Ecto schema, or any schema-backed form for validation
  — ADR-018 (No Domain Model). Use plain validation functions, matching
  `Nebu.Admin.LogsController`'s pattern.
- Do not duplicate the private/link-local/loopback IP-blocking logic for `webhook_url` — reuse
  the check already implemented in `Nebu.Media.SSRF` instead of writing a second SSRF guard.
- Do not create the "Medien" parent nav item in this story — only add the "Settings" child
  entry; the parent item is Story 0's scope.

## Dependencies

- **9a-media-config-table-module** — the `media_config` table and `Nebu.Media.Config` public
  API (`get/0`/`upsert/1`) this controller reads from and writes to exclusively. Must land
  first; this story has no other read/write path into media policy config.

## Dev Agent Record

### Corrections applied (pre-dev, verified against the shipped codebase)

- **`Nebu.Media.Config.upsert/1` does not exist.** The real Story 9a public API is
  `upsert(key, value, actor \\ @audit_actor) :: :ok | {:error, atom()}`, one call per key.
  `save/2` calls it once per submitted key (all 9 keys, always — the form is a full-state
  submit, matching `LogsController`'s pattern) with the real admin's identity as `actor`.
- **No "Medien" parent nav item exists** (no Story 0 landed on this branch). Added a plain
  top-level `<.nav_item navigate="/admin/media/settings" key="media-settings">Media
  Settings</.nav_item>` in `layouts.ex` (mirrors the `Dashboard`/`Compliance` leaves) instead
  of nesting under a non-existent parent. Documented inline as a `<%!-- ... --%>` comment in
  `layouts.ex` so a future Story 0 can re-home this leaf as that parent's child. Not covered
  by any Acceptance Test.

### Implementation notes

- **Actor sourcing:** `actor_id/1` mirrors `Nebu.Admin.UsersController.actor_id/1` verbatim —
  reads `conn.assigns[:current_user]`, prefers `"matrix_user_id"`, falls back to `"sub"`, and
  falls back to the literal `"system:media_config"` (matching `Nebu.Media.Config`'s own
  default) only if neither is present (should not happen behind `:require_admin`).
- **Numeric bounds** (`@bounds` in `media_settings_controller.ex`) are this story's own choice
  (the story does not mandate specific numbers), chosen generously enough to never reject any
  `config.exs` default: `max_upload_size_bytes`/`max_file_size_bytes` 1..5 GiB
  (`5_368_709_120`), `max_pending_per_user` 1..1000, `max_stall_ms` 1 ms..1 hour
  (`3_600_000`), `deleted_days`/`infected_days` 0..3650 (10y), `orphaned_hours` 0..8760 (1y).
  Every bound sits strictly inside `Nebu.Media.Config.upsert/3`'s own `>= 0` contract, so this
  controller's rejection is always the FIRST rejection reached (AC2's "before it reaches
  `upsert`" contract) rather than a redundant second check.
- **Two-phase validate-then-persist:** `validate_and_normalize/1` validates and coerces all 9
  fields before `save/2` calls `Nebu.Media.Config.upsert/3` even once (AC2/AC3 atomicity —
  zero keys persisted if any field is invalid).
- **AC4 warning:** implemented as a second `:warning` flash (in addition to the generic
  `:info` "Media settings saved" flash), rendered with `role="alert"` in the template,
  triggered only on a `nil` → concrete-value transition of `released_delete_after_days`.

### Verification

- `mix test test/nebu/admin/media_settings_controller_test.exs --warnings-as-errors` — 16/16
  passed.
- `mix test --warnings-as-errors` (full suite) — 1688 passed, 4 skipped, 449 excluded, 0
  failed (no regressions).
- `mix compile --warnings-as-errors` — clean.

### File List (actual)

- `server/lib/nebu/admin/media_settings_controller.ex` (new, ~300 lines)
- `server/lib/nebu/admin/media_settings_html.ex` (new, 11 lines)
- `server/lib/nebu/admin/templates/media_settings/index.html.heex` (new, ~170 lines)
- `server/lib/nebu/admin/router.ex` (modified — +3 lines)
- `server/lib/nebu/admin/layouts.ex` (modified — +1 nav item, +1 explanatory comment)
- `server/test/nebu/admin/media_settings_controller_test.exs` (pre-staged by ATDD step, not
  modified by dev)
