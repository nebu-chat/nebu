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
