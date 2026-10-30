# ATDD report: media-storage-uses-admin-config

Epic `media-storage-admin-target`, bug flow. Tests only; `server/lib` and `server/config` are at HEAD (reference
implementation kept as `reference-impl.diff`, mutation log in `mutation-results.txt`). Revision 2 (test-review fix pass:
MINOR 1, 2, 4, 6, 7, 8 and INFO 7 addressed; MINOR 3 documented below; MINOR 5 done in the story).

## Files (all under `server/test/nebu/`)

| File | Purpose |
|---|---|
| `media/storage_admin_target_support.exs` | Support: real local HTTP stub (127.0.0.1, ephemeral port; records method / target / headers / body size; `status:` and `get_body:` options; never echoes credentials), recording ExAws client, scoped env helpers, secret-file helper, saved-row builder, sync / async upload and download helpers through the real router |
| `media/media_storage_admin_target_test.exs` | S1, S2, S4, 404 mapping, row-beats-env |
| `media/media_storage_blank_endpoint_test.exs` | S3 |
| `media/media_storage_secrets_not_logged_test.exs` | S5 |
| `media/media_storage_router_errors_test.exs` | route level: sync upload, async upload, download against the saved target and failing storage |
| `runtime_storage_endpoint_test.exs` | S6, S7 (real `config/runtime.exs` via `Config.Reader.read!/2`; NEBU_* plus CLUSTER_STRATEGY / KUBERNETES_* cleared and restored) |

## Tests (64 total)

| Area | Tests | Red on HEAD |
|---|---|---|
| S1 saved target used at call time (upload via router, `put`, row change without restart, cache `:refresh`) | 4 | 4 |
| S2 nothing saved keeps env/default (defaults for all 5 ops, env values for all 5 ops, archive bucket fallbacks x2, scheme/port x4 incl. https + explicit port, partial row with bucket/archive/region from env, credentials from `NEBU_MINIO_*_FILE`) | 10 | 10 |
| Row wins over every env value (endpoint, bucket, archive bucket, region, credentials) | 1 | 1 |
| 404 from the saved storage: `get` / `get_from_archive` -> `{:error, :not_found}`, `delete` -> `:ok`, `put` / `put_object_copy` -> `{:error, _}` | 5 | 5 |
| S3 blank endpoint (5 variants x [stub, recording client], upload 500, blank env does not hide a saved endpoint) | 12 | 12 |
| S4 every operation resolves the saved target (+ `archive_bucket/0`) | 6 | 6 |
| S5 secrets never leaked (403, refused, blank, env-sourced) | 4 | 4 |
| Route level (sync upload 403 -> 500; async upload stored at saved target, 403 -> 500, blank -> 500; download served from saved target, 404 -> 404 "Media not found", 403 and blank -> 502 "Media storage unavailable") | 8 | 8 |
| S6 empty / blank `NEBU_MINIO_ENDPOINT` aborts boot (+ `:test` env and valid endpoints guards) | 10 | 8 |
| S7 unset keeps `minio:9000` | 4 | 0 |

Evidence: reference implementation: 64 / 64 green with `--warnings-as-errors`. Reverted tree (HEAD lib/config):
64 tests, 58 failed, 6 passed (S7 x4 and two S6 guards, behaviour to preserve). Full no-DB unit run on the reverted tree:
only the 58 new red tests fail (see "Full run" below).
Mutations: 20 original (19 killed, M12 equivalent) + 11 for the new tests (N01-N11, all killed); see `mutation-results.txt`.

## Seams used

`:media_storage_config_loader` (saved row, string-keyed, secrets encrypted with `Nebu.Web.SecretBox` under the
`:admin_secret_at_rest` seam), `:media_storage_env_reader` (stands in for `NEBU_MINIO_*`, including `*_FILE` paths),
`:ex_aws` / `:ex_aws, :s3` app env as the boot-time "decoy" pointing at a stub that must stay untouched, `:ex_aws,
:http_client` (recording double, see contract 3), `:nebu_http` `:media_bucket` / `:media_archive_bucket` (boot-time
bucket names), plus the existing media fakes for DB / state machine / membership / reservation lookup. No database,
no `:media_storage_config_source` (`get_for_connection/0` ignores it; only `get/0` honours it).
The supervised `StorageConfig` instance is stopped in setup and restarted (supervisor `restart_child`) in the LAST
`on_exit` of every test.

## Reference design (throwaway, `reference-impl.diff`, unchanged in revision 2)

* `Nebu.Media.StorageConfig.operation_target/0` -> `{:ok, %{overrides, bucket, archive_bucket}}` or
  `{:error, :storage_endpoint_blank}` from `get_for_connection/0` (trimmed endpoint, host/port split, port default
  443/80 by `use_ssl`, overrides `access_key_id`, `secret_access_key`, `host`, `scheme`, `port`, `region`; archive
  bucket = saved, else `:media_archive_bucket` app env, else `"nebu-media-archive"`).
* `Nebu.Media.Storage` calls `ExAws.request(op, overrides)` for all five operations, same result mapping as before
  (404 -> `:not_found` for the two gets, 404 -> `:ok` for delete); blank endpoint -> `{:error, :storage_endpoint_blank}`
  before any request; `archive_bucket/0` returns the effective archive bucket.
* `config/runtime.exs`: `NEBU_MINIO_ENDPOINT` unset -> `"minio:9000"`; set and blank after trim -> `raise` naming it.

## Pinned contract (no new function names are pinned)

1. `Storage.put/2`, `get/1`, `delete/1`, `put_object_copy/2`, `get_from_archive/1` keep their signatures and result
   mapping (404: `get` / `get_from_archive` -> `{:error, :not_found}`, `delete` -> `:ok`); on a blank effective endpoint
   each returns `{:error, _}` without any request (no fallback to the boot-time config). Routes keep their error
   mapping: upload 500 "Failed to store media file", download 404 "Media not found" for a storage 404 and 502
   "Media storage unavailable" for any other storage error.
2. `Storage.archive_bucket/0` returns the effective archive bucket (saved > env / app env > `"nebu-media-archive"`) and
   must not raise on a blank endpoint.
3. **Operational requests must go through the configured ExAws `:http_client`** (the default hackney client in
   production; the recording client in the tests). Do NOT set a custom `http_client` (e.g. a pinned client) in the
   operational overrides: the S2 default-value tests and the "nothing handed to the transport" S3 tests rely on it and
   would otherwise pass vacuously or fail. (Test review MINOR 3: kept on purpose.)
4. Effective values are resolved per call with `get_for_connection/0` semantics (per field: row > env reader > default);
   no memoization outside the StorageConfig cache; a cache `:refresh` must be enough. Per-request overrides, never a
   write of the saved target into the global `:ex_aws` app env (not detectable by black-box tests; code review must check).
5. "Nothing saved" falls back per field: bucket / archive bucket via `:media_bucket` / `:media_archive_bucket` app env or
   the reader keys `NEBU_MINIO_BUCKET` / `NEBU_MINIO_ARCHIVE_BUCKET` (tests set both to the same value); credentials via
   `NEBU_MINIO_*_FILE` (wins) then the plain variables; region via `NEBU_S3_REGION`.
6. `config/runtime.exs` (prod and dev): raise (message contains `NEBU_MINIO_ENDPOINT`, no credentials) when the
   variable is set and empty or whitespace-only; unset -> host `minio`, port `9000` (`use_ssl` only changes the scheme);
   other values unchanged; `:test` env untouched.

## How to run

`.media-ci/quick.sh "mix test --warnings-as-errors test/nebu/media/media_storage_admin_target_test.exs test/nebu/media/media_storage_blank_endpoint_test.exs test/nebu/media/media_storage_secrets_not_logged_test.exs test/nebu/media/media_storage_router_errors_test.exs test/nebu/runtime_storage_endpoint_test.exs"`

## Open points

* S7 and two S6 guards pass on HEAD (behaviour to preserve); mutation M15 shows a changed default is caught.
* M12 survives only because the reference also trims the host part (equivalent); M20 (no trim at all) is killed.
* ExAws's own `debug_requests: true` logs the access key ID inside the SigV4 header; never enabled here, not asserted.
* The saved endpoint is not subject to the SSRF guard on operational calls (admin-trusted, ADR-033 SO11 addendum).
* Download of an archived object (`archived_at`) through the router is covered at Storage level (`get_from_archive`), not as a route test.
* `MediaArchiveWorker` already calls `storage().archive_bucket()`, so it needs no change.

---

# Cycle 1 (tests for the decided fixes A-F; red against the dev's cycle-0 tree)

Tests only (support module extended: stub `error_body:`, `corrupt_ciphertext/0`, `put_os_env_scoped/2`). The throwaway
reference for these fixes is `reference-impl-cycle1.diff` (a patch ON TOP of the dev's cycle-0 tree; reverted again, the
tree equals the cycle-0 state). The 64 cycle-0 tests stay green with it (152 / 152, `--warnings-as-errors`).

## New files and counts (88 tests: 63 red on the cycle-0 tree, 25 guards that already pass and must keep passing)

| Fix | File (server/test/nebu/...) | Tests | Red |
|---|---|---|---|
| A credentials bound to the endpoint source, fail closed | `media/media_storage_credential_binding_test.exs` | 13 | 9 |
| B save needs both keys for a changed endpoint / use_ssl (model) + D parser (model, Test Connection) | `media/storage_config_endpoint_save_test.exs` | 31 | 17 |
| B + D controller (save form, Test Connection button) | `admin/media_settings_storage_save_test.exs` | 19 | 16 |
| C failed refresh keeps the last good snapshot | `media/media_storage_refresh_resilience_test.exs` | 13 | 11 |
| E unreadable credential / at-rest key files, `archive_bucket/0` | `media/media_storage_unreadable_credentials_test.exs` | 8 | 7 |
| F no S3 error bodies | `media/media_storage_error_bodies_test.exs` | 4 | 3 |

Mutations (cycle 1, P01-P19, see `mutation-results.txt`): 18 killed, 1 equivalent (P19: the Test Connection split can no
longer see a bad port because validation rejects it first).

## Minimal pinned contract added in cycle 1

* **A** `Storage.*` return exactly `{:error, :storage_credentials_missing}` and send nothing (to the saved host, the
  environment host or the boot-time host) when the effective endpoint comes from the saved row and a row credential is NULL
  (either one) or cannot be decrypted (corrupt ciphertext, other at-rest key). The `NEBU_MINIO_*` / `*_FILE` credentials are
  never substituted. Row WITHOUT endpoint: both row credentials present win; both NULL: the environment credentials; one
  NULL or undecryptable: the same error. At most ONE warning/error log line per operation (the whole call, not per
  secret), without secret, ciphertext or environment credential.
* **B** `StorageConfig.upsert/2` returns `{:error, :secret_required}` (nothing written, no audit entry) when `fields` has
  `:endpoint` or `:use_ssl` that differs from the effective (row > env > default, so also on a fresh config) value
  (`same_target?`: trimmed + ASCII-downcased endpoint, `use_ssl == true`) and `:access_key` AND `:secret_key` are not both
  non-blank binaries in the same call (nil / "" / one key = not given). Same endpoint and use_ssl, or no such key in `fields`:
  untouched. The controller answers 200 with the flash text "Enter the access key and secret key to use a different
  endpoint", writes and audits nothing, keeps the fresh sign-in marker. The error atom is shared with `test_connection/1`.
* **C** Loader seam `:media_storage_config_loader` may return `{:error, term}` or raise = a FAILED read (`nil` = confirmed
  "no row", still replaces the snapshot). A failed read keeps the last good snapshot on the GenServer `:refresh` call, the
  `{:invalidate_media_storage_config}` message and the `:ttl_tick` message, and heals on the next good refresh. With no
  snapshot at all (cache stopped or never loaded) `Storage.*` return `{:error, _}` without any request; `get/0` and
  `get_for_connection/0` still answer a map. (The default loader should report a failed query / Repo not available as an
  error, not `nil`; unit tests cannot see that, it is the dev's call.)
* **D** `StorageConfig.upsert/2` and `test_connection/1` return `{:error, :invalid_endpoint}` for `host:9000/`,
  `host:9000/path`, `[2001:db8::1]:9000`, port 0, 65536, non-numeric (Test Connection never calls its request function and
  never raises); the controller save / Test Connection render an alert and write / call nothing. `host`, `host:9000` and
  uppercase hosts are accepted. The operational parser (`parse_endpoint/2`) is the single source of truth.
* **E** With a missing / unreadable `NEBU_MINIO_*_FILE` file (also a directory) or an unreadable at-rest key file
  (`NEBU_INTERNAL_SECRET_FILE`) `Storage.*` return `{:error, :storage_credentials_unreadable}` (or `:storage_credentials_missing`
  when the cause is a saved secret that cannot be decrypted), never raise, send nothing, and the file path never appears in a
  log line; the download route answers its existing 502. `Storage.archive_bucket/0` never reads a credential or file and
  logs no warning (returns the saved / env / default archive bucket even with undecryptable secrets).
* **F** `Storage.*` return `{:http_error, status}` instead of `{:http_error, status, body}` (also 500; put /
  put_object_copy keep the error with status 404); get / get_from_archive 404 -> `:not_found`, delete 404 -> `:ok` unchanged.
  No fragment of the S3 error body (`AWSAccessKeyId`, `StringToSign`, ...) in any returned term or log line (debug included).
  Callers checked: nothing in `server/lib` outside `Nebu.Media.Storage` / `PinnedHttpClient` (Test Connection, untouched)
  matches on `{:http_error, _, _}`; `Nebu.Media.fetch_and_decrypt/3` matches `{:error, :not_found}` and `_`, the workers
  `inspect/1` an opaque reason.

## Existing tests that conflict with fix B (the dev must update them; found by running them against the reference)

All save a changed endpoint, or the first save on a fresh config, with blank keys, and now get `{:error, :secret_required}`:
`storage_config_test.exs` "AT6: upsert/1 with only endpoint/bucket leaves ... untouched" and "opt-in: CGNAT/RFC1918 iam_endpoint and
endpoint are persisted"; `storage_pinned_target_test.exs` "AC1: ... upsert/1 (save) validates ... no request ..."; 18 tests of
`admin/media_settings_controller_test.exs` (AC4 orphan-risk group x6, the AC5/AC6 "valid save calls ... upsert/1" test, the
bugfix-add-sts-iam-endpoints AC3/AC4 group, the F-1 R-1 / valid https iam-sts regression tests). Fix: type both keys in those
saves (`typed_keys/1` exists in the controller test) or keep the stored endpoint. The new tests do not depend on the list.

## Open points (cycle 1)

* The fresh-config rule (an endpoint other than the environment's needs keys too) is a decision pinned by the model and
  the controller tests; it follows from rule A (a saved endpoint never uses env credentials).
* `StorageConfig.persisted_target/0` / `persisted_iam_sts/0` still map a failed read to "fresh" / nil (the controller's
  orphan-risk gate would be skipped while the DB is down). Not pinned here; Kassandra / dev decide.
* No docs test added (no `*_docs_test.exs` family naturally covers `07-deployment.md`).

---

# Cycle 2 (tests G-P; red against the dev's cycle-1 tree)

Tests only (no change to `server/lib`, `server/config`, `docs`). The throwaway reference is `reference-impl-cycle2.diff`
(a patch ON TOP of the dev's cycle-1 tree: storage.ex, storage_config.ex, media.ex, the controller and the form template);
it was applied, proven, and reverted with `git apply -R`; the lib / config / docs diff is byte-identical to the dev's cycle-1
state again. With the reference every new test and every earlier test is green (`--warnings-as-errors`); a full no-DB run
with the reference fails only the three existing tests listed below (all consequences of the decisions).

## New files and counts (62 tests: 34 red on the cycle-1 tree, 26 guards that already pass, 2 `:no_repo` guards)

| Fix | File (server/test/nebu/...) | Tests | Red |
|---|---|---|---|
| G operational chains (env-equal row, other endpoint, env change, half pair), K display via `get/0` | `media/media_storage_env_equal_credentials_test.exs` | 17 | 7 |
| G `upsert` half pair, H Test Connection rule, I strict save-time check | `media/storage_config_key_rules_test.exs` | 17 | 10 |
| G chain through the controller (fresh save then `Storage.put/get`), G half-pair form, N typed values, K page markers, O hint, H controller | `admin/media_settings_fresh_save_test.exs` | 13 | 10 |
| J closed error set | `media/media_storage_error_shapes_test.exs` | 8 | 3 |
| L upload with unreadable credentials, template lookup reads no secret, K log | `media/media_storage_upload_credentials_test.exs` | 5 | 4 |
| M default loader without Repo (`:no_repo`) | `media/storage_config_default_loader_test.exs` | 2 | 0 (see below) |
| P | 11 moduledocs rewritten as plain descriptions (no "ATDD / red phase") | | |

Support: `nodb_one.sh` (git-excluded helper under `.media-ci/`) runs targeted tests WITHOUT a database like the unit job
(`.media-ci/nodb_one.sh "test/nebu/media/storage_config_default_loader_test.exs"`).

Mutations (cycle 2, Q01-Q20, `mutation-results.txt`): all 18 run killed (Q07 and Q11 were not written). Q20 (default loader
answers `nil` for an unavailable Repo) is killed in the no-DB run only.

## Minimal pinned contract added in cycle 2

* **G** Credential rule on the operational path: row endpoint AND Use SSL `same_target?` (trimmed, ASCII-downcased endpoint,
  `use_ssl == true`; a NULL row `use_ssl` follows the environment) with the environment's OWN endpoint / Use SSL and both
  saved keys NULL: the `NEBU_MINIO_*` credentials sign (also after a first save that kept the environment endpoint).
  Another endpoint / another Use SSL / another port, a half pair, undecryptable keys: `{:error, :storage_credentials_missing}`,
  nothing sent. If the environment endpoint later changes so that it no longer matches: fail closed again. Row keys (both
  saved, decryptable) always win. `upsert/2` returns `{:error, :key_pair_required}` for exactly one non-blank key (nothing
  written or audited; a changed endpoint / Use SSL with one key keeps `{:error, :secret_required}`, evaluated first).
  Controller: 200, flash "Enter both the access key and the secret key", marker kept, typed non-secret values kept.
* **H** `test_connection/1` with blank form keys: `same_target?` with the stored target, then the stored credentials by the
  rule above (row pair; both NULL + environment's own target: environment credentials; else `{:error, :secret_required}`, the test
  function is never called). Typed keys are always used. Controller: alert, test function not called.
* **I** The save-time key check (only when `fields` has `:endpoint` / `:use_ssl` and not both keys) compares against a strict
  fresh read of the row being written, never the cache: a stale cache neither lets a changed endpoint keep the old keys nor
  rejects an unchanged one; an unreadable row (loader `{:error, _}` or raise) gives `{:error, :storage_config_unavailable}`,
  nothing written or audited (pinned with a healthy cache and with no cache; the answer when both keys are given is not pinned).
* **J** `Storage.*` errors are `{:error, atom}` or `{:error, {:http_error, integer}}`, never ExAws's `{type, message}` pairs or
  other shapes (no storage-controlled text in a term or a log line, debug included). The atom for the unmapped shapes is free.
* **K** `StorageConfig.get/0` (the settings page) shows the credentials the operational path would use: no key for another
  endpoint with NULL / undecryptable keys; the (masked) environment keys when the row's endpoint is the environment's own target,
  or has no endpoint; no log line in `get/0` (or on upload) claims a fallback to the environment credentials (`~r/fall(ing)? ?back/i`).
  The page text is the existing marker: both key fields say "Not currently configured." (and no "Currently configured.") for a
  row with another endpoint and no usable keys, "Currently configured." when the environment keys are what is used.
* **L** An upload through the router with an unreadable `NEBU_MINIO_*_FILE` file or an unreadable at-rest key file answers the
  existing 500 "Failed to store media file" (no crash, no path in the response or logs); the key prefix template lookup reads
  and decrypts no secret and writes no `Nebu.Media.StorageConfig:` log line; a saved template is honoured. NOTE for the dev:
  the template accessor must still honour the `:media_storage_config_source` seam (`MediaAsyncUploadTest` "computes the storage
  key via StorageConfig.compute_key/2 ..." sets it); the reference's `key_prefix_template/0` does.
* **M** `default_loader/0` answers `{:error, :repo_unavailable}` without `Nebu.Repo` (observable: `request_target/0` and all
  five operations return `{:error, :storage_config_unavailable}`; `get/0` and `archive_bucket/0` still answer). Already true in
  the dev tree: this is a guard, tagged `:no_repo` (runs in the unit job, excluded when a database is up).
* **N** The `:secret_required`, `:key_pair_required` and `:invalid_endpoint` save re-renders put the typed endpoint, bucket,
  region, Use SSL (checked) and template into the form and never echo a key.
* **O** The hint of both key fields mentions "Save" and "Test Connection".

## Existing tests the dev must adapt (found with the reference; the dev's own design may differ in detail)

* `server/test/nebu/admin/media_settings_controller_test.exs`: "test-connection with a blank secret field resolves it against the
  currently stored secret ..." stores ONLY `secret_key_encrypted` for a saved endpoint (a half pair): give the row both keys.
* `server/test/nebu/media/storage_config_test.exs`: "AT12: SecretBox.encrypt/1 raises (fail-closed) ..." calls `upsert(%{access_key: ...})`
  with one key, which is now `{:error, :key_pair_required}` before the encrypt raise: pass both keys.
* With the reference no further test fails (full no-DB run: 6914 / 6917, the third failure was the template seam note above,
  fixed in the reference).

## Open points (cycle 2)

* The answer of `upsert/2` for a changed endpoint WITH both keys while the row is unreadable is not pinned.
* `persisted_target/0` / `persisted_iam_sts/0` (orphan-risk baselines) still read an unreadable row as fresh (from cycle 1).

---

# Cycle 3 (tests Q-W; red against the dev's cycle-2 tree)

Tests only. Throwaway reference: `reference-impl-cycle3.diff` (storage_config.ex, the controller, the form template, on top of
the dev's cycle-2 tree); applied, proven, reverted with `git apply -R`; the lib / config / docs / CHANGELOG diff is
byte-identical to the dev's cycle-2 state again. Full no-DB run on the dev tree plus the new tests: 6925 / 6947 passed, 22 failed,
all in the two new files. With the reference every new and every earlier test is green (`--warnings-as-errors`) except the 9
existing controller tests listed below.

## New files (30 tests: 22 red, 8 guards)

| File (server/test/nebu/...) | Tests | Red | Covers |
|---|---|---|---|
| `admin/media_settings_storage_errors_test.exs` | 26 | 21 | Q, R, S, T, U, V (page) |
| `media/storage_config_one_key_test.exs` | 4 | 1 | W |

Mutations (cycle 3, R01-R18, `mutation-results.txt`): all 18 killed.

## Pinned markup and strings

**Q** A refused Save (`:invalid_endpoint`, `:secret_required` for a different endpoint or a Use SSL toggle, `:key_pair_required`) answers 200
with exactly one `<p id="media-storage-error" role="alert" tabindex="-1" autofocus class="alert alert-error ...">` inside the Storage
Target section, after its heading and before `<form id="media-storage-form">` (the position of the Test Connection result); text:
the invalid-endpoint reason is `StorageConfig.describe_invalid_endpoint(endpoint)`, the other two are below. `aria-invalid="true"` and
`aria-describedby="media-storage-error"` on `#endpoint` for `:invalid_endpoint`, on `#access_key` AND `#secret_key` for the two key errors,
absent on the other inputs. A plain GET, a Test Connection result and a successful save (redirect) have no `#media-storage-error`, no
`[aria-invalid]`. (`autofocus` is the existing admin pattern, see `role_mapping/index.html.heex`; whether it is a flash as well is not pinned.)

**R** Save `:secret_required` (also for a Use SSL toggle only):
`Enter the access key and secret key to use a different endpoint or a changed Use SSL setting. The stored credentials are only used for the stored endpoint and scheme. Nothing was saved.`
Save `:key_pair_required`: `Enter both the access key and the secret key. Nothing was saved.`
Test Connection (blank keys, `p[role=alert]`): the SAME target (endpoint and Use SSL equal the stored ones) with a stored pair that is
half, missing or undecryptable: `The stored access key and secret key are missing or unusable. Enter both keys to test. Nothing was saved.`;
a different endpoint or a changed Use SSL keeps `Enter the access key and secret key to test a different endpoint or a changed Use SSL setting: the stored credentials are only used for the stored endpoint and scheme. Nothing was saved.`
The model answer of `test_connection/1` stays `{:error, :secret_required}` (the controller tells the two cases apart; the reference
adds `StorageConfig.stored_target?/2`, the name is not pinned).

**S** Hint of BOTH key fields (`label[for=access_key|secret_key] span.label-text-alt`, whitespace squished, exact):
configured: `Currently configured. Leave blank to keep it. Enter both keys again if you change the endpoint or Use SSL; Save and Test Connection both require them.`
not configured: `Not currently configured. Required: Save and Test Connection both need both keys.`
after any refused Save: `Required now: enter both the access key and the secret key.`
"Configured" follows the operational rule (saved pair, or the environment keys for the environment's own target).

**T** The orphan-risk alert (`p[role=alert]`) contains `5 existing file(s)` (the count) and `Enter the access key and secret key again before saving.`; the
checkbox `#confirm_orphan_risk` is not ticked on the gate render; a re-submit with the box ticked and no keys (`:secret_required`)
re-renders the error AND the orphan warning with the checkbox rendered and `checked`; the next submit with the keys is saved and the
writer gets endpoint and both encrypted keys.

**U** A save that carries any key writes `endpoint` and `use_ssl` in the same `:media_storage_config_writer` call (also when equal to the cached
view); without keys unchanged fields are still filtered (only `bucket` is written for a bucket rename).

**V** `StorageConfig.get/0` (and so the page) shows no key (`nil`; both fields "Not currently configured.") for undecryptable keys or a half pair,
also where the environment credentials would apply (env-equal endpoint, row without endpoint) and for another endpoint; `Nebu.Media.Storage.put/2` for
the same rows answers `{:error, :storage_credentials_missing}`.

**W** `upsert/2` returns `{:error, :key_pair_required}` (nothing written or audited) when the fields mention exactly one of `:access_key` /
`:secret_key` (non-blank, `nil` or blank, also `%{bucket: .., secret_key: nil}`) or when one is non-blank and the other nil / blank; both keys `nil`
is legal and clears the pair; no key mentioned is unaffected; both non-blank is saved.

## Existing tests the dev must adapt

Consequence of U: a save with keys now ALWAYS writes `endpoint`, which `upsert/2` validates (SSRF / DNS); these nine tests of
`server/test/nebu/admin/media_settings_controller_test.exs` type keys (`typed_keys/1`) with an UNCHANGED stored endpoint that cannot be
resolved (`stable-endpoint:9000` and similar) and get `:invalid_endpoint`: give the stored row and the form a literal public IP
endpoint (e.g. `93.184.216.34:9000`) or save without typing keys:
"AC4 ... the warning does NOT appear when only region, use_ssl, s3_key_prefix_template, or archive_bucket change ...",
"bugfix-add-sts-iam-endpoints AC4 ... changing only iam/sts (no endpoint/bucket change) does not trigger the orphan-risk gate",
"... changed_storage_keys/1 includes iam/sts in the written columns only when they change",
and the AC3 "optional form params" tests (MAJOR-1 blank clears an existing override, "blank iam/sts is written as an explicit NULL ...",
MAJOR-N1, N2-MINOR-2, N3-M4) and "F-1 ... R-1: a blank submission can still clear an EXISTING DB override ...".
Tests pinning the old texts: none found outside the cycle-1/2 tests of this story, which keep passing (their message constants are prefixes of
the new texts; `media_settings_storage_save_test.exs` / `media_settings_fresh_save_test.exs` assert `=~` on the old substrings).
Remark for the dev: with the reference the decrypt warning of `get/0` is gone (`build_resolved` uses `operation_credentials/2`); a log line for an
undecryptable stored secret on the settings page is optional.

## Open points (cycle 3)

* The model answer for the neutral Test Connection case is not a separate atom (the controller must compare the candidate with the stored target).
* `autofocus` on a `<p tabindex="-1">` is pinned as the testable HTML part of the focus move; actual focus behaviour is not testable here.

---

# Cycle 4 (tests X, Y, Z; red against the dev's cycle-3 tree)

Tests only. Throwaway reference: `reference-impl-cycle4.diff` (storage_config.ex and the controller, 80 lines, on top of the dev's cycle-3
tree); applied, proven, reverted with `git apply -R`; the lib / config / docs / CHANGELOG diff is byte-identical to the dev's cycle-3
state. With the reference: 472 tests (all new and earlier ones incl. the dev-adapted existing controller / storage_config tests) green with
`--warnings-as-errors`. Full no-DB run on the dev tree plus the new tests: 6956 / 6973 passed, 17 failed, all in the two new files.

## New files (26 tests: 17 red, 9 guards)

| File (server/test/nebu/...) | Tests | Red | Covers |
|---|---|---|---|
| `media/storage_config_audit_fields_test.exs` | 16 | 12 | X (model), Z |
| `admin/media_settings_storage_audit_test.exs` | 10 | 5 | X (controller), Y (Save and Test Connection) |

Mutations (cycle 4, S01-S07, `mutation-results.txt`): all 7 killed.

## Pinned contract

* **X** `metadata.changed_fields` (atoms, names only; no `old_value` / `new_value`, no value anywhere in `inspect(metadata)`) names only the fields whose
  submitted value differs from the row as it was read before the write (nil row: every submitted field); the keys count whenever submitted
  (non-blank pair, or the explicit both-`nil` clear). A pure key rotation through the controller (endpoint and Use SSL equal the stored row; the writer still
  receives `endpoint` and `use_ssl` next to the keys, pinned) audits `[:access_key, :secret_key]`; a changed endpoint `[:access_key, :endpoint, :secret_key]`;
  a Use SSL toggle `[:access_key, :secret_key, :use_ssl]`; a bucket-only change `[:bucket]` (also when unchanged region / endpoint / use_ssl are submitted
  along). The existing AT9 (`[:access_key, :secret_key]` then `[:bucket]`) stays green.
* **Y** The reason for a rejected endpoint (Save: `p#media-storage-error`; Test Connection: `p[role=alert]`) equals
  `StorageConfig.describe_invalid_endpoint(trimmed value)`; for `" 10.0.0.5:9000"`, `"10.0.0.5:9000 "`, `"  10.0.0.5:9000  "` (private addresses not allowed) it names
  the private address and says nothing about DNS / resolving.
* **Z** `upsert/2` with BOTH keys blank (`""`, whitespace only) or a blank string with a `nil` (either order): `:ok`, no `access_key_encrypted` /
  `secret_key_encrypted` column (no `SecretBox.encrypt("")`), the keys are not named, other fields (e.g. bucket) are written and named. Both `nil`: the explicit clear
  (both columns nil, both named). Exactly one non-blank key (the other `""`, whitespace, `nil` or absent): `{:error, :key_pair_required}` (unchanged). A call with
  only blank keys may or may not call the writer (with empty columns); only the absence of key columns is pinned.

## Existing tests the dev must adapt

None: with the reference no existing test asserted `changed_fields` including `endpoint` / `use_ssl` on key saves (AT9 and the controller tests stay green).
