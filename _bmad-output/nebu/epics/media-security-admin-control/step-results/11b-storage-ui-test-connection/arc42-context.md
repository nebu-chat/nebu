## User Story

**As** a Nebu admin,
**I want** to edit the S3/MinIO storage target on `/admin/media/settings`, verify the entered
credentials actually work with a "Test Connection" action before saving, and be warned (and
required to confirm) if changing the endpoint or bucket would orphan existing files,
**so that** I can safely reconfigure where Nebu stores media without silently breaking uploads or
making already-stored files unreachable.

## Technical Requirements

- **Controller (extended, not new):** `Nebu.Admin.MediaSettingsController`
  (`server/lib/nebu/admin/media_settings_controller.ex`, from 9b). Adds:
  - `save_storage/2` — validates + persists the storage-target form.
  - `test_connection/2` — resolves candidate values, calls the S3 test, re-renders with the
    result; never persists.
  `index/2` (9b) is extended to also assign `:storage_config` (from
  `Nebu.Media.StorageConfig.get/0`) for the template's second section.
- **Controller vs LiveView — decision, justified against 9b's convention.** Plain controller.
  9b already established that `/admin/media/settings` is a page with "no genuine real-time
  requirement," matching `ConfigController`/`LogsController`. Test Connection does not change
  that calculus: it is a single request/response cycle (submit → one S3 round-trip → render),
  identical in shape to `ConfigController.save_scopes/2`. Nothing about it needs a persistent
  socket, server-push, or multi-client shared state — the three conditions that justify this
  project's three LiveView exceptions (`DashboardLive`, `AuditLogLive`, `LogsLive`). Introducing
  a LiveView here to get a nicer non-reloading UX would be a **new, unjustified fourth
  exception**, not a requirement of this story.
- **Template:** `server/lib/nebu/admin/templates/media_settings/index.html.heex` (9b's file,
  extended with a second `<form>`). Two submit buttons on the storage form:
  - `<button type="submit">Save</button>` — default action, posts to
    `/admin/media/settings/storage`.
  - `<button type="submit" formaction="/admin/media/settings/storage/test-connection">Test
    Connection</button>` — native HTML `formaction` override, no JavaScript required, fully
    keyboard-operable (matches AC8).
  `Nebu.Admin.MediaSettingsHTML` (`media_settings_html.ex`) needs no change — it is only the
  `embed_templates` wrapper; the new markup lives in the `.heex` file.
- **Router:** add to the existing `scope "/admin", Nebu.Admin do … pipe_through :browser` block
  in `server/lib/nebu/admin/router.ex` (plain `post`, not `live`):
  ```elixir
  post "/media/settings/storage", MediaSettingsController, :save_storage
  post "/media/settings/storage/test-connection", MediaSettingsController, :test_connection
  ```
  No nav change needed — 9b's "Settings" child nav item already points at
  `/admin/media/settings`, which now renders both sections.
- **Test Connection — a lightweight S3 call, not an upload/download round-trip.** Implemented as
  `Nebu.Media.StorageConfig.test_connection/1` (an addition to 11a's public API surface this
  story depends on, alongside `get/0`/`upsert/1`): accepts a candidate map
  (`endpoint`, `bucket`, `region`, `use_ssl`, `access_key`, `secret_key`), resolves any blank
  secret against the currently stored decrypted secret internally (never returning it to the
  caller), and calls `ExAws.S3.head_bucket(bucket) |> ExAws.request(config_overrides)` — a single
  `HEAD` against the bucket root, not `put_object`/`get_object`. `config_overrides` (ExAws's
  per-request config-override keyword list: `access_key_id`, `secret_access_key`, `host`,
  `scheme`, `port`, `region`) is built from the *candidate* values so the call exercises exactly
  what would be saved, not the currently-active `Application`-env-configured connection that
  `Nebu.Media.Storage` (existing upload/download path) uses. Returns `:ok` or
  `{:error, reason}`; the controller renders a fixed, non-leaking message per outcome
  (`reason` is logged server-side, never interpolated into the rendered HTML verbatim, to avoid
  echoing endpoint/credential detail from a raw `ExAws`/`:hackney` error struct back to the
  browser).
- **Test seam (mirrors `Nebu.Web.MediaFakes`'s fn-backed fake pattern — Mox is not a
  dependency):** production `test_connection/1` calls the real `ExAws.request/2`; tests inject
  `Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate -> :ok |
  {:error, :some_reason} end)` and the controller/`StorageConfig.test_connection/1` reads that
  seam when set, falling back to the real ExAws call otherwise — identical shape to
  `:media_storage_get_fun`/`:media_storage_put_fun` in `media_fakes.exs`.
- **Existing-files-check query.** `SELECT COUNT(*) FROM media_files WHERE storage_key IS NOT
  NULL` (per the epic's exact wording — every non-null `storage_key` was written under the
  *current* single active target, since there is no per-file target reference, ADR-032). Lives
  as inline SQL (ADR-018) inside `Nebu.Admin` — either a small private helper in
  `media_settings_controller.ex` or a new `Nebu.Admin.DB.count_media_with_storage_key/0`
  function (matching `Nebu.Admin.DB`'s existing role as the admin module's query helper, e.g.
  `get_server_config/0`/`upsert_server_config/1` used by `ConfigController`) — this is the same
  documented exception 5a already established for `Nebu.Admin.MediaLive` reading `media_files`
  directly, not a `Nebu.Media` public-API call.
- **No `Ecto.Changeset`.** Per ADR-018, validation is plain Elixir functions on the raw params
  map, matching `Nebu.Admin.LogsController`/`Nebu.Admin.ConfigController`'s pattern — not a
  changeset/schema.
- **Persistence seam:** `Nebu.Media.StorageConfig.get/0` (read, pre-fill + orphan-check
  comparison baseline) and `Nebu.Media.StorageConfig.upsert/1` (write, on confirmed save) — the
  only calls this controller makes into the `Nebu.Media` namespace for the storage-config form
  (ADR-020). No `Postgrex`/`Ecto.Adapters.SQL` call against `media_storage_config` from this
  module or its template.
- **Test file:** `server/test/nebu/admin/media_settings_controller_test.exs` (9b's file,
  extended with the `describe` blocks above) — same `Plug.Test` conn-building convention as
  `config_controller_test.exs`/`logs_controller_test.exs`, no `Phoenix.LiveViewTest`.
