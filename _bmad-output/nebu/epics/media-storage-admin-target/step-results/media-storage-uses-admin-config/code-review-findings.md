# Code review (cycle 0): media-storage-uses-admin-config

Reviewer: nebu-code-reviewer (read-only, tests not executed by the reviewer). 1 MAJOR (design), 6 MINOR, 8 INFO. All 7 scenarios implemented; no credential reaches a log line, inspected term or GenServer message.

## MAJOR
- **MAJOR-1** storage_config.ex:830-850 (`do_refresh`/`safe_load`), :796-815 (`row_and_env`), :1053-1073 (`default_loader`): a failed cache refresh (loader error, pool timeout, Repo not up) caches `{nil, env}` over the last good snapshot, so for up to 60 s every operational call silently goes to the env/default endpoint, bucket and credentials instead of the saved target (uploads land in a different store, reads then 404). Fix: keep the last good row when the loader returns an error and cache `nil` only for a confirmed "no row"; same for the missing-ETS branch.

## MINOR
1. Save-time endpoint validation (URI.parse, :326-331/:1138-1164) is weaker than `parse_endpoint/2` (:1294-1311): `host:9000/`, `host:9000/path`, `[2001:db8::1]:9000` pass save and then fail every operation (:storage_endpoint_invalid). Use the same parser at save (upsert) time.
2. Credential reads now sit on the per-call path (`File.read!` of NEBU_MINIO_*_FILE, SecretBox at-rest key file): a missing/unreadable file raises `File.Error` out of `Storage.*` (download route has no rescue). `archive_bucket/0` calls the full `get_for_connection/0` (decrypt/file reads) although it only needs a bucket name. Fix: rescue in `request_target/0` into an error atom without credentials; bucket-only resolver for `archive_bucket/0`.
3. Decrypt failure of a saved secret falls back to env credentials on real traffic (sends env access key id + signature to the saved host) and warns twice per operation (no throttle). Fail closed for operational calls; log once.
4. S3 error bodies (`{:http_error, 403, %{body: xml}}`, AWSAccessKeyId/StringToSign in SignatureDoesNotMatch) are returned unsanitized and reach MediaScanWorker `inspect(reason)` / audit metadata. Reduce to `{:http_error, status}` in Storage (keep 404 mapping); check callers pattern-matching on the 3-tuple.
5. Two parsers for one host[:port] contract (`split_endpoint`, raising, Test Connection only vs `parse_endpoint/2`); `default_port/1` matches only `true` while `connection_overrides/3` uses truthiness. Use `parse_endpoint/2` in `config_overrides/1`.
6. Stale docs/dead config: docs/architecture/10-quality.md:95 ("unwired today", zero production callers; MUST-VERIFY for wiring stories not addressed), docs/architecture/05-building-blocks.md:1086-1092 ("does NOT rewire Nebu.Media.Storage"), storage_config.ex:501 (compute_key "not wired yet"), runtime.exs:192 `:media_bucket` has no reader in lib (only tests use it as a decoy; comment it like the iam/sts "zero readers" block), storage_config.ex:82-83 broken moduledoc wrap.

## INFO
1. request_target/0 once per operation; decrypt per call acceptable (Media.upload already decrypts once via StorageConfig.get()); archive worker resolves three times per file (audit bucket name could differ from the one used if the target changes mid-file; benign).
2. ETS/GenServer down: direct loader call per request (DB query + decrypt), no crash; raising loader rescued to nil (feeds MAJOR-1).
3. Test Connection unchanged (pinned client, 1 attempt, SSRF, same_target?).
4. Precedence per field DB > env > default; nil credentials become "" and are signed (403, not anonymous), same as runtime.exs.
5. Endpoint edge cases: user:pass@h:9000 invalid; warning never includes the endpoint; env/SQL-sourced `user@host` unvalidated (operator-trusted).
6. Seams/callers/cluster-safety clean; `:media_storage_module` untouched.
7. Deploy: docker-compose literal minio:9000; upcloud/stackit emit NEBU_MINIO_ENDPOINT only under enable_media_gateway; "" now aborts boot (intended).
8. 07-deployment.md row accurate; does not say existing objects stay at the old target when the endpoint changes (11b orphan-risk gate already warns).

---

# Delta code review (cycle 1)

Reviewer: nebu-code-reviewer (static read; sandbox blocked mix). Claimed cycle-1 fixes verified in code (MAJOR-1 last-good snapshot, one parse_endpoint, error atoms for Storage, credential binding, save-time key rule, error bodies stripped, Test Connection unchanged, existing tests only adapted). 1 NEW MAJOR, 6 MINOR, 10 INFO.

## MAJOR
- **MAJOR-1 (same trap as Kassandra cycle-1 #1):** a first save on a fresh config (`media_settings_controller.ex:~273` `:fresh -> persist_storage_config(conn, changes)`, unfiltered form: endpoint, bucket, use_ssl always present, form pre-filled with the env endpoint) or a lone-key save writes a row with an endpoint but no (or half a) key pair; `operation_credentials/2` (storage_config.ex:296) then fails closed (`:storage_credentials_missing`) for every upload/download/delete/archive while the admin sees "Storage settings saved". The form hint ("Currently configured. Leave blank to keep the current value", index.html.heex:368-374; `access_key_configured` from the env-resolved value, controller :939) invites it. Existing deployments that saved an endpoint without keys (page was cosmetic until now) fail after upgrade. No test chain "controller fresh save with env credentials, then Storage.put succeeds". Options: row endpoint/use_ssl equal to the env's own => env credentials allowed; reject in upsert any save leaving "endpoint without full key pair" or "exactly one key"; or filter unchanged fields on the :fresh branch.

## MINOR
1. media.ex:565 `StorageConfig.get()` -> `resolved()` -> `resolve_env_secret` uses `File.read!` (storage_config.ex:1110): an unreadable `NEBU_MINIO_*_FILE` raises (500 crash with the path in the message) before `Storage.put` on upload; also decrypts both secrets on every upload. Use a non-secret accessor (`plain_fields`) for the template; test an upload through the router.
2. No test of `default_loader/0` returning `{:error,_}` (e.g. `Process.whereis(Nebu.Repo) == nil` => `{:error, :repo_unavailable}`).
3. The `{:error, :secret_required}` (controller :330-335) and existing `:invalid_endpoint` branches re-render with `state_from_config(Config.get())` and no `storage_config:` option: typed non-secret values are lost, the admin sees the OLD endpoint next to a message about a "different endpoint". `persist_storage_config` does not receive `params`.
4. Form hint index.html.heex:372-373 says "...change the endpoint or Use SSL and press Test Connection"; Save now enforces the rule too.
5. Stale "ATDD (red phase, cycle 1)" moduledocs in 11 new test files (media_storage_{admin_target,blank_endpoint,credential_binding,error_bodies,refresh_resilience,router_errors,secrets_not_logged,unreadable_credentials}_test.exs, storage_config_endpoint_save_test.exs, media_settings_storage_save_test.exs, runtime_storage_endpoint_test.exs).
6. 10-quality.md storage-target row: first cell "is wired" but third cell still "forward-looking on an entirely unwired module (zero callers today)".

## INFO
1. runtime.exs now aborts the whole boot on an empty NEBU_MINIO_ENDPOINT; upcloud server.tf falls back to "" (`try(...)`, cloud-init writes NEBU_MINIO_ENDPOINT whenever enable_media_gateway): crash-loop instead of media-only failure; intended, needs a release note.
2. Host rule `\A[A-Za-z0-9._-]+\z`: no regression (a saved IPv6/path endpoint never worked: old String.to_integer raised).
3. Never-refreshed state (DB down at boot): every call reads the DB directly, one default_loader warning per failed query, no rate limit on the "request not sent" warning.
4. After a successful upsert whose immediate refresh read fails the stale snapshot stays <= 60 s (consistent tuple).
5. Per-request cost: key-file read + two decrypts or two File.read! per operation: fine.
6. Logging clean (static strings; only DB error inspect).
7. Existing tests only adapted, nothing weakened (AT6 no longer proves endpoint change leaves secrets untouched: inherent to rule B).
8. Docs match code; break-glass SQL (endpoint+keys NULL => env) still consistent.
9. No dead code; `:media_bucket` stays (pinned by a runtime test, commented).
10. Design: saved keys without a saved endpoint follow a later-changed env endpoint (documented key-rotation rule).

---

# Delta code review (cycle 2)

Reviewer: nebu-code-reviewer (static). **0 MAJOR, 5 MINOR, 8 INFO.** Every cycle-2 claim (G, H, I, J, K, L, N, O) correct in code; no wrongly-open credential case.

## MINOR
1. Stale `request_target/0` @doc (storage_config.ex:249-253: "never replaced by the NEBU_MINIO_* credentials") contradicts the env-equal exception; check the Interface bullet and `upsert/2` @doc (:363-372) (no mention of :key_pair_required / :storage_config_unavailable).
2. Stale "never used with env credentials" text: docs/stories/oauth-broker/follow-ups.md row `ds`, docs/architecture/05-building-blocks.md:~1091 ("only with its saved credentials"), 11-risks.md:62 (milder): add "except the environment's own target".
3. Settings page display disagrees with the operational path (`build_resolved/2` :1024-1041 vs `operation_credentials/2`): env-equal/no-endpoint + undecryptable saved keys shows masked env keys as "Currently configured" while operations fail; a half pair mixes the saved access key with the env secret on screen. Derive the display from the same classification (anything not `{:ok,_}`/`{:none,:none}` shows nil); add tests (env-equal + undecryptable, half pair).
4. Misleading copy: Save `:secret_required` says "different endpoint" also for Use-SSL-only changes; Test Connection's `:secret_required` also fires for a half/undecryptable/unreadable stored pair on the SAME endpoint, where "to test a different endpoint or a changed Use SSL setting ... Nothing was saved" is wrong: use "endpoint or Use SSL" and a neutral "stored credentials are missing or unusable" variant.
5. Orphan-risk confirmation round trip loses typed keys (maybe_gate_on_orphan_risk :276-289, template :249-263): ticking the confirmation and re-submitting without retyping gives :secret_required, whose re-render has no orphan_warning (checkbox gone): third submit needed. Add a hint in the orphan alert ("retype the keys") or pass the warning through.

## INFO
1. Changed endpoint + both keys with an unreadable row proceeds to the write: acceptable (endpoint plus the full pair are written together).
2. `get_for_connection/0` has no production caller; its @doc ("intended for ExAws construction") is now false: correct or remove (tests reference it).
3. `get/0` leniency vs strict operational path is intentional.
4. `upsert/2` accepts `%{secret_key: nil}` alone (validate_key_pair treats nil/blank as absent while build_columns writes nil/encrypts ""): "exactly one key is never saved" does not hold for direct callers; controller never sends it; fail-closed.
5. validate_keys_for_target_change edge cases (use_ssl nil read as false, "host:80" vs "host") are fail-closed/harmless.
6. Log volume: decrypt warning on every get(), Storage warning per operation while degraded.
7. env_credentials/1 and resolve_secret/3 duplicate the _FILE-then-plain resolution; comment at :311-312 garbled ("sign with empty strings when none is configured").
8. Story file has no AC for the key rules / binding / env-equal exception (only CHANGELOG + 07); CHANGELOG bullet packs three behaviours into one.

---

# Final narrow delta review (cycle 3)

Reviewer: nebu-code-reviewer (static). **0 MAJOR, 5 MINOR, 8 INFO.** (V, R, W, U, Q/S/T) correct in code: no raise path, no plaintext exposure, no broken caller; `storage_save_error` assigned on every render path; orphan gate decides on the raw changes before the merged endpoint.

## MINOR
1. Audit `changed_fields` over-reports on every key save: `write_audit` uses `Map.keys(fields)` (storage_config.ex:891-898), and since U a pure key rotation audits `[:access_key, :secret_key, :endpoint, :use_ssl]`; @doc (:394) says "ONLY the fields that changed"; controller comment :302-312 claims inflation was removed; no test pins the names. Record the really changed names (diff against the fresh row) or state the exception. => FIX (cycle 4).
2. Doc drift: "key rotation follows the environment endpoint" (request_target/0 @doc :261-262; 07-deployment row) is no longer reachable from the UI since U pins endpoint/use_ssl on every key save (only legacy/SQL rows); after a UI rotation a later NEBU_MINIO_ENDPOINT change is not followed. Say so (incl. CHANGELOG). => FIX (cycle 4, docs).
3. Early controller validation errors (required endpoint/bucket, scheme prefix, IAM/STS: controller :464-472, :504-506, put_flash :209-213) still use the top flash without aria-invalid/focus; CHANGELOG/07 overclaim "A refused save is shown inside the Storage Target section". => narrow the wording (cycle 4, docs) / follow-up.
4. Copy accuracy pinned by tests: "Required now: enter both keys" after ANY refused save incl. :invalid_endpoint; "Required: Save and Test Connection both need both keys" overstates; orphan alert sentence also for bucket-only changes; a legacy row with endpoint and no keys can still be saved for an unrelated field. => follow-up (contract change), not in this story.
5. U side effect: every key save runs the SSRF/DNS check on the stored endpoint: a rotation is refused when the stored endpoint does not currently resolve or a stored private endpoint is no longer allowed; the admin sees "Endpoint rejected" on a field they did not touch; no UI workaround. Documented trade-off (07-deployment); suggested hint text => follow-up.

## INFO
1. `describe_invalid_endpoint(params["endpoint"])` (controller :345) uses the untrimmed param; a leading space turns a private IP into a DNS failure message; pass the trimmed value. => FIX (cycle 4).
2. `upsert(%{access_key: "", secret_key: ""})` passes validate_key_pair and writes `SecretBox.encrypt("")` for both; treat both-blank like absent. => FIX (cycle 4).
3. `mask_secret` shows the whole secret for values <= 4 chars (pre-existing, pinned).
4. `get()` no longer logs for an undecryptable pair (page silently shows "Not currently configured."); operational path logs.
5. Test Connection still accepts ONE typed key plus the stored other key for the same target (asymmetry with Save; no hole).
6. Moduledoc Interface bullets lack stored_target?/2, key_prefix_template/0, describe_invalid_endpoint/1.
7. env_credentials_apply? short-circuit on nil row endpoint without use_ssl comparison (carried, env host only).
8. Row with endpoint NULL (legacy/SQL): any save of endpoint/bucket may show an orphan warning (pre-existing).

Patterns for memory: an "always write bound columns" rule widens audit `Map.keys(fields)`; a single-path accessible error UX leaves early controller validations on the old flash.
