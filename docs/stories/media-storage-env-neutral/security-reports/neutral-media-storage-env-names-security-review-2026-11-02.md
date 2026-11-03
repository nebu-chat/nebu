## Security Review — neutral-media-storage-env-names

**Diff scope:** Staged diff only (env rename `NEBU_MINIO_*` -> `NEBU_MEDIA_STORAGE_*`, `NEBU_TEST_MINIO_ENDPOINT` -> `NEBU_TEST_MEDIA_STORAGE_ENDPOINT`): server/config/runtime.exs, server/lib/nebu/media/storage_config.ex, server/lib/nebu/media/storage.ex, server/lib/nebu/admin/media_settings_controller.ex (comments only), docker-compose.yml, deploy/tofu/examples/{upcloud,stackit}/cloud-init.tftpl, deploy/tofu/examples/upcloud/outputs.tf, docs/CHANGELOG, tests. Earlier branch commits excluded.
**Date:** 2026-11-02

### Prescan candidates

The candidates file contained only the header (path trigger on stackit cloud-init.tftpl, no candidate rows). The trigger file was reviewed manually (see section 3 below).

### Verification against the requested focus

1. **Credential loading:** `runtime.exs` and `StorageConfig.resolve_env_secret/3` are name-for-name renames. The logic is unchanged. `*_FILE` still takes precedence: the case matches on the FILE var, and the plain var is read only when it is `nil`. An unreadable or empty-path FILE var raises `File.read!` at boot in runtime.exs, so boot aborts (fail closed). In StorageConfig it is rescued to `{:error, :storage_credentials_unreadable}`, and no credential or path ends up in the error term. A FILE that is readable but blank yields `""`, which is unchanged behaviour. There is no fallback to `NEBU_MINIO_*` anywhere. The repo-wide grep finds legacy names only in the new test's mapping table, a docker-compose comment and CHANGELOG/docs. `default_env_reader/0` reads only the new names. The new operator-facing texts in `Storage.problem/1` name only variable names, never values. `mask_map/1` and the admin page masking are untouched. The diff adds no Logger or inspect calls, and the existing log sites are unchanged.
2. **Fail-closed with legacy names left set:** The server boots with defaults (`minio:9000`, use_ssl=false, bucket `nebu-media`, empty credentials). It does not pick up the legacy credentials, so they cannot be signed with or sent anywhere. Operational risk: see finding #1.
3. **Deploy artefacts:** In upcloud and stackit cloud-init, and in docker-compose, the credentials are still `*_FILE` -> `/run/secrets/...`. No plain `*_ACCESS_KEY`/`*_SECRET_KEY` values were added to the environment. `USE_SSL: "true"` stays hardcoded in both cloud templates. `outputs.tf` changes only description text; the `sensitive = true` markers are kept. Nothing new is logged. (The access-key and secret-key output descriptions are pre-existing copy-paste text describing the endpoint. This is cosmetic.)
4. **SSRF / endpoint validation:** `validate_candidate_endpoint`, `parse_endpoint`, `invalid_endpoint_scheme?` and the IAM/STS SSRF checks are unchanged, apart from comments and the env key names they read. The trust split is the same as before: admin/DB values are validated, env values are trusted.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/config/runtime.exs:156-185, storage_config.ex:1516-1538 | A deployment that misses the rename silently falls back to plaintext `http://minio:9000` with empty credentials. This hostname is resolved through DNS (search domains) outside compose. | At boot, log a warning that names (not values) any `NEBU_MINIO_*` vars that are still set. Optionally refuse to boot in prod when the legacy names are set and the new ones are not. |

### Detail

**Finding #1 — Silent default target for unmigrated deployments** [LOW]
The intended hard break means that a host that still sets `NEBU_MINIO_*` boots against the default `minio:9000` over plain HTTP. The access key and secret key are empty strings. No credential leaves the process: the legacy values are never read, and the requests are signed with empty keys. Outside the compose network, the bare name `minio` is resolved through the resolver's search domains. If someone else controls a matching `minio.<search-domain>` record, uploads and downloads (object keys, bucket name, request metadata, and the media ciphertext, which `Nebu.Media.Crypto` encrypts with AES-GCM) would go to that host over plaintext. Downloads could also be served from there. In the expected case the target does not resolve and media operations simply fail.

This does not create a new exploit primitive. The same default existed before for an unset `NEBU_MINIO_ENDPOINT`. The diff does make it reachable for every deployment that has not migrated, and the CHANGELOG states the old names are "silently ignored". A deployment that saved a target under /admin/media/settings is not affected, because the saved target with its own credentials takes precedence.

Remediation: in runtime.exs, emit a one-line `IO.warn`/Logger warning listing the legacy variable NAMES that are still present, and never their values. This keeps the hard break, since nothing is read, and removes the silent part.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 1 — advisory

**Verdict:** APPROVED
