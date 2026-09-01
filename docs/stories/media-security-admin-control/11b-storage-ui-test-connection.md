---
story_id: 11b-storage-ui-test-connection
title: "Object Storage Target Configuration: Storage UI — Test Connection + Warnings"
epic: media-security-admin-control
status: done
security_review: required
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 11a introduces the storage-target config (`endpoint`, `bucket`, `region`, `use_ssl`,
`access_key`, `secret_key`, `s3_key_prefix_template`, `archive_bucket`) with field-level
encryption for the two secrets, plus the `Nebu.Media.StorageConfig` public-API module
(`get/0`/`upsert/1`, ADR-020) that owns the new config table. This story adds the admin-facing
editor for that config, on the **same page** 9b already created at `/admin/media/settings`
(the epic's own dependency line for 11b is explicit: "Abhängigkeiten: 11a, 9b
(Settings-Infra/Muster)" — 11b extends 9b's page with a second, independent section, it does not
stand up a new route).

Two behaviors distinguish this from a plain settings form and are the actual reason this is its
own story rather than folded into 9b:

1. **Test Connection.** Before the admin commits an endpoint/bucket/credential change, a
   dedicated action performs a real S3 call (`ExAws.S3.head_bucket/1`) against the
   **submitted, not-yet-saved** values and reports success/failure — catching a typo'd endpoint
   or a revoked key before it silently breaks every future upload.
2. **Orphan-risk warning.** Because `media_files.storage_key` is a flat key resolved against
   the single active storage target (no per-file target reference, ADR-032), changing
   endpoint/bucket while files already exist under the current target makes those files
   permanently unreachable — the download handler will 404 against the new target for every key
   that was written under the old one. This is silent data loss with no error at save time
   unless the UI stops to ask. The warning is therefore a **hard requirement with a mandatory
   acknowledgment step**, not a dismissible toast.

**Deliberately a plain HTTP controller, not a LiveView** — following 9b's already-decided
convention (`Nebu.Admin.Router`'s moduledoc: only `DashboardLive`/`AuditLogLive`/`LogsLive` are
justified LiveView exceptions, each for a genuine real-time requirement). "Test Connection" is a
one-shot synchronous action — submit, wait for one round-trip S3 call, render the result — with
no ongoing/streaming state once the response comes back. That is the same shape as every other
plain-controller POST action in this codebase (`Nebu.Admin.ConfigController.save_scopes/2`,
`save_sso_schemes/2`): validate, act, re-render or redirect. There is no requirement for the
result to update without a form submission, no multi-user shared view, and no push update from
the server — so this story extends `Nebu.Admin.MediaSettingsController` (9b) with two new
actions instead of introducing a fourth LiveView exception.

## User Story

**As** a Nebu admin,
**I want** to edit the S3/MinIO storage target on `/admin/media/settings`, verify the entered
credentials actually work with a "Test Connection" action before saving, and be warned (and
required to confirm) if changing the endpoint or bucket would orphan existing files,
**so that** I can safely reconfigure where Nebu stores media without silently breaking uploads or
making already-stored files unreachable.

## Acceptance Criteria

1. **Storage section renders on `/admin/media/settings`.** `GET /admin/media/settings` (9b's
   existing route) additionally renders a second, independent form for the 11a storage-target
   fields (`endpoint`, `bucket`, `region`, `use_ssl`, `s3_key_prefix_template`, `archive_bucket`,
   plus the two secret fields below), pre-filled from `Nebu.Media.StorageConfig.get/0`. When no
   `media_storage_config` row exists yet, the non-secret fields pre-fill from the `NEBU_MINIO_*`
   env-var fallback (11a's "Env-Var-Fallback bleibt erhalten" contract) — this is a **read-once
   migration convenience**, not an ongoing per-request override: once a value has been saved to
   the DB, the DB value is authoritative on every subsequent load, exactly like 9a/9b's
   `media_config` fallback semantics.
2. **Secret fields are write-only and never pre-filled with plaintext.** `access_key` and
   `secret_key` render as `<input type="password">` with **no `value` attribute at all** —
   matching the existing OIDC-client-secret convention in `Nebu.Admin.BootstrapLive` (which never
   sets `value=` on the client-secret field). `Nebu.Media.StorageConfig.get/0` itself must never
   return the decrypted plaintext to this controller for rendering purposes — it returns only a
   presence indicator per secret field (e.g. `access_key_set: true/false`,
   `secret_key_set: true/false`), so there is no decrypted value in this controller's process at
   all when only rendering the form. A form label/hint indicates "leave blank to keep the
   current value" next to each secret field.
3. **"Test Connection" performs a real S3 call against the submitted (unsaved) values.** A
   "Test Connection" button submits the form to a distinct action that resolves any **blank**
   secret field against the currently stored (decrypted) secret — server-side only, the
   plaintext is never sent back to the browser — merges it with the submitted non-secret fields,
   and issues `ExAws.S3.head_bucket/1` against that candidate configuration (not the persisted
   one). Success or failure is reported on the re-rendered page **before** anything is written to
   `media_storage_config`. A network/auth failure shows a specific, non-leaking message (no
   secret material, no raw exception dump) with `role="alert"`; success shows a `role="status"`
   confirmation. Test Connection never persists — a subsequent explicit Save is still required.
4. **Orphan-risk warning on endpoint/bucket change, gated by a mandatory acknowledgment.** On
   save, if the submitted `endpoint` or `bucket` differs from the currently persisted value AND
   `COUNT(*) FROM media_files WHERE storage_key IS NOT NULL` is greater than zero, the save is
   **not** persisted on the first submission. Instead the page re-renders at HTTP 200 with:
   - an explicit warning (`role="alert"`) stating the exact count N and explaining the
     orphan risk in plain language — changing the target does not migrate existing objects, so
     the N existing files will return 404 on download because their `storage_key`s will no
     longer resolve against the new endpoint/bucket;
   - a required, unchecked checkbox ("I understand N existing file(s) will become unreachable
     and want to proceed") that must be checked before a second submission of the same form is
     accepted;
   - the submitted non-secret field values preserved (not reset), so the admin does not have to
     retype them to confirm.
   Checking the box and resubmitting persists the change. This gate applies **only** to
   `endpoint`/`bucket` changes while existing files are present — it must not fire when the
   config is empty/fresh (no row yet, or zero files reference `storage_key`), and it must not
   fire for changes to any other field (`region`, `use_ssl`, `s3_key_prefix_template`,
   `archive_bucket`, secrets) in isolation.
5. **Save persists exclusively via `Nebu.Media.StorageConfig.upsert/1`.** This controller and
   its template never issue SQL against `media_storage_config` directly (ADR-020 — 11a owns the
   table and is the only write seam). The audit-log entry (`media_storage_config_updated`,
   11a's AC) is written inside `upsert/1`, not duplicated here.
6. **The existing-files count query is the one documented ADR-018 exception.** Per the precedent
   already established for `Nebu.Admin.MediaLive` (Story 5a — "the only namespace allowed to
   read `media_files` directly for admin-facing concerns"), the `COUNT(*) FROM media_files WHERE
   storage_key IS NOT NULL` query is inline SQL inside the `Nebu.Admin` namespace (not a
   `Nebu.Media` public-API call) — it is a read-only admin-facing check, not a cross-domain
   mutation.
7. **Admin-only access.** Both new POST actions (`save_storage`, `test_connection`) are gated by
   the same `Nebu.Admin.Auth`, `:require_admin` plug already applied to
   `Nebu.Admin.MediaSettingsController` — an unauthenticated or non-admin request redirects to
   `/admin/login`, matching 9b AC7.
8. **Accessibility (hard constraint per this project's Admin UI convention, matching 9b AC8).**
   Every input has an associated `<label>`; both the storage form and the policy form (9b) remain
   fully operable by keyboard using native controls only — the Test Connection / Save distinction
   uses two submit buttons (`formaction`), not a JS click handler, so both actions work with
   `Tab`+`Enter`/`Space` alone; the orphan-risk checkbox is a native `<input type="checkbox">`,
   never a custom widget; the test-connection result and the orphan-risk warning use
   `role="status"`/`role="alert"` respectively so assistive technology announces the outcome
   without a focus move being required.

## Acceptance Tests

Concrete test names added to
`server/test/nebu/admin/media_settings_controller_test.exs`
(`Nebu.Admin.MediaSettingsControllerTest`, extended — same `describe "ACn: …"` / `test "…"`
convention as 9b, `Plug.Test`-conn-building, no `Phoenix.LiveViewTest`):

- `describe "AC1: storage section renders on GET /admin/media/settings"`
  - `test "renders the storage form pre-filled with the current media_storage_config values"`
  - `test "a fresh/empty storage config pre-fills endpoint/bucket/region from NEBU_MINIO_* env vars"`
  - `test "once a media_storage_config row exists, env vars no longer override the stored value on reload"`
- `describe "AC2: secret fields are write-only"`
  - `test "access_key and secret_key inputs render with no value attribute, regardless of a configured secret"`
  - `test "the rendered HTML never contains the actual stored plaintext access_key or secret_key"`
  - `test "each secret field renders a presence hint (configured/not configured) without the plaintext"`
- `describe "AC3: Test Connection against submitted, unsaved values"`
  - `test "test-connection success (mocked S3 client) renders a role=status confirmation and does not persist"`
  - `test "test-connection failure (mocked S3 client returning an error) renders a role=alert message without leaking secret material"`
  - `test "test-connection with a blank secret field resolves it against the currently stored secret server-side, never round-tripping plaintext to the response"`
  - `test "test-connection does not call Nebu.Media.StorageConfig.upsert/1"`
- `describe "AC4: orphan-risk warning on endpoint/bucket change"`
  - `test "changing endpoint with existing media_files (storage_key IS NOT NULL) blocks the first save and renders the warning with the correct count N"`
  - `test "changing bucket with existing media_files blocks the first save and renders the warning"`
  - `test "checking the acknowledgment checkbox and resubmitting persists the endpoint/bucket change"`
  - `test "the warning does NOT appear when the storage config is fresh/empty (no media_storage_config row yet)"`
  - `test "the warning does NOT appear when media_files has zero rows with a non-null storage_key"`
  - `test "the warning does NOT appear when only region, use_ssl, s3_key_prefix_template, or archive_bucket change without an endpoint/bucket change"`
  - `test "submitting without checking the acknowledgment checkbox a second time still does not persist"`
- `describe "AC5/AC6: persistence and existing-files count ownership"`
  - `test "a valid save calls Nebu.Media.StorageConfig.upsert/1 and never issues a direct media_storage_config INSERT/UPDATE"`
  - `test "the existing-files count is read via inline SQL in the Nebu.Admin namespace, not a Nebu.Media public-API call"`
- `describe "AC7: admin-only access"`
  - `test "an unauthenticated POST to /admin/media/settings/storage is redirected to /admin/login, not persisted"`
  - `test "an unauthenticated POST to /admin/media/settings/storage/test-connection is redirected to /admin/login"`
- `describe "AC8: accessibility"`
  - `test "every storage-form input has an associated label"`
  - `test "the Test Connection and Save buttons are both native submit buttons with distinct formaction attributes, no onclick handler"`
  - `test "the acknowledgment checkbox is a native input[type=checkbox]"`
  - `test "the test-connection result carries role=\"status\" on success and role=\"alert\" on failure"`
  - `test "the orphan-risk warning carries role=\"alert\""`

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

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/admin/media_settings_controller.ex` | Modified | Add `save_storage/2`, `test_connection/2`; extend `index/2` to assign `:storage_config` |
| `server/lib/nebu/admin/templates/media_settings/index.html.heex` | Modified | Add storage-target form section: fields, write-only secret inputs, Test Connection button (`formaction`), orphan-risk warning + acknowledgment checkbox |
| `server/lib/nebu/admin/router.ex` | Modified | Add `POST /admin/media/settings/storage` and `POST /admin/media/settings/storage/test-connection` |
| `server/lib/nebu/admin/db.ex` | Modified (or controller-local helper) | Add `count_media_with_storage_key/0` inline-SQL helper |
| `server/test/nebu/admin/media_settings_controller_test.exs` | Modified | ATDD tests per the Acceptance Tests section |

## Dev Agent Guardrails

### Do Not Change

- Never render a stored secret in plaintext in any form field, response body, log line, or
  error message — `access_key`/`secret_key` inputs never carry a `value` attribute, and
  `Nebu.Media.StorageConfig.get/0` must not return the decrypted plaintext to this controller
  for display purposes. This applies to the Test Connection failure path too: a raw
  `ExAws`/`:hackney` error struct MUST NOT be interpolated verbatim into the rendered HTML if it
  could contain the request's signed-URL query string (which embeds the access key ID) — render
  a fixed, generic failure message and log the detailed reason server-side only.
- The orphan-risk warning (AC4) is a **hard requirement, not optional UX polish** — a submission
  that changes `endpoint`/`bucket` while `media_files` rows with a non-null `storage_key` exist
  must never persist on the first submission, regardless of any other validation passing. Do not
  "simplify" this into a dismissible flash or a JS `confirm()` dialog — it must be a server-side
  gate backed by a real form re-render and a real second submission, so it cannot be bypassed by
  disabling JavaScript or resubmitting a cached page.
- Do not implement this as a LiveView — see the Technical Requirements justification. Do not add
  a fourth LiveView exception alongside `DashboardLive`/`AuditLogLive`/`LogsLive`.
- Do not introduce `Ecto.Changeset` or a schema-backed form (ADR-018).
- Do not query or write `media_storage_config` directly from this controller or its template —
  always go through `Nebu.Media.StorageConfig.get/0`/`upsert/1` (ADR-020; 11a owns the table).
- Do not make the Test Connection call using the currently-*active* connection config that
  `Nebu.Media.Storage` uses for real uploads/downloads — it must test the *submitted* candidate
  values, including an unsaved endpoint/bucket/region/credential change, not the persisted one.

## Dependencies

- **11a-storage-config-schema-secrets** — the `media_storage_config` table,
  `Nebu.Media.StorageConfig.get/0`/`upsert/1`, and the field-level secret encryption this story
  reads from and writes through exclusively. This story also depends on 11a additionally
  exposing `Nebu.Media.StorageConfig.test_connection/1` (candidate-value S3 check with
  server-side blank-secret resolution) as part of that same public-API module — if 11a's initial
  scope does not yet include this function, it must be added there (owned by the `Nebu.Media`
  namespace per ADR-020, not reimplemented here) before this story can land.
- **9b-media-settings-ui** — the `/admin/media/settings` page (route, controller, template,
  nav entry) this story extends with a second, independent form section. Must land first; this
  story does not stand up its own route or nav item.
