# UX gate: media-storage-uses-admin-config (nebu-ux-reviewer)

Scope: media_settings/index.html.heex hints, media_settings_controller.ex re-render errors, new status markers.

## Blocking
- **V1** The Save validation error (`render_storage_validation_error`, controller :343-348) uses `put_flash(:error, ...)`: rendered at the top of the page (T:11-13), ~180 lines above the Storage Target section and the key fields; the Test Connection result renders inside the storage section (T:228-237, role="alert"). No aria-invalid/aria-describedby on #endpoint/#access_key/#secret_key, focus is not moved; the controller comment (:316-317) claims the message "is read next to the endpoint". Fix: `storage_save_error` assign rendered as `<p id="media-storage-error" role="alert" class="alert alert-error mb-4">` in the Storage Target section like the Test Connection result; `aria-invalid="true"` + `aria-describedby="media-storage-error"` on endpoint (for :invalid_endpoint) / access_key + secret_key (for :secret_required, :key_pair_required); move focus to the message (tabindex="-1" + focus) or follow the existing autofocus pattern on admin pages.
- **V2** `:secret_required` message says "to use a different endpoint" also when only Use SSL changed (test media_settings_storage_save_test.exs:153-156); Test Connection's message names Use SSL correctly. Use consistent wording, e.g. "Enter the access key and secret key to use a different endpoint or a changed Use SSL setting: the stored credentials are only used for the stored endpoint and scheme. Nothing was saved." Update test constants.

## Advisories
- A1 Status marker vs hint contradiction ("Currently configured. Leave blank to keep the current value." next to an error that demands the keys; "Not currently configured." + "Leave blank to keep" meaningless). Suggested conditional copy (configured: "Currently configured. Leave blank to keep it. Required again if you change the endpoint or Use SSL (Save and Test Connection both need it)."; not configured: "Not currently configured. Required: Save and Test Connection both need it."); on a refused-save re-render a `keys_required` flag => "Required now: ...".
- A2 Hint wording: "Enter both keys again if you change the endpoint or Use SSL; Save and Test Connection both require them."
- A3 Message punctuation/"Nothing was saved." on both Save messages (like Test Connection).
- A4 Orphan warning step loses typed keys: add a sentence to the orphan alert ("Enter the access key and secret key again before saving.").
- A5 Hint inside `<label>` (existing pattern); optional aria-describedby move. A6 contrast not verified (existing pattern). A7 pass `params["endpoint"]` to describe_invalid_endpoint.

## Passed
No key values in the DOM; typed non-secret values kept (endpoint, bucket, region, use_ssl, template, archive_bucket, iam/sts); status text is words not colour; role=alert present; sign-in marker flow intact (gate before validation, marker kept on refusal, nothing written/audited); label/for/id unchanged.
