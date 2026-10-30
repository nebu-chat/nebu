# Security Review: media-storage-uses-admin-config (Kassandra, cycle 0)

Date: 2026-10-29. Scope: uncommitted worktree `open-chat-media-storage`, branch `bugfix/media-storage-uses-admin-config`.
**Verdict: APPROVED (CLEAN: 0 CRITICAL, 0 HIGH).** 2 MEDIUM, 2 LOW, 6 INFO.

| # | Severity | Location | Finding | Remediation |
|---|----------|----------|---------|-------------|
| 1 | MEDIUM | `storage_config.ex` `request_target/0`, `build_resolved/2` (per-field DB > env), `resolve_secret`/`decrypt_secret` (env fallback) | Endpoint and credentials can come from different sources: a saved endpoint with NULL credential columns, or a stored ciphertext that fails to decrypt, lets the boot-time `NEBU_MINIO_*` keys sign every operation sent to the admin-saved host (access key id, SigV4 signatures, replayable signed requests for the host). | Bind the credential source to the endpoint source: endpoint from the DB row => credentials only from the row; missing/undecryptable => `{:error, :storage_credentials_missing}`, no request. Test: saved endpoint + env credentials + decoy => no request. |
| 2 | MEDIUM | `admin/media_settings_controller.ex:455-456` (blank key = omit), `StorageConfig.upsert/2` | Save path reuses stored credentials for a changed endpoint/scheme (Test Connection refuses this via `same_target?`, D4). The credentials now sign real traffic to the new host. | Require access_key and secret_key in the same save whenever endpoint or use_ssl changes vs the stored value; reuse `same_target?/2` and the message "Enter the access key and secret key to use a different endpoint". |
| 3 | LOW | `storage.ex` request path; `11-risks.md` residual `ds` | The documented unpinned-operational-call residual (ADR-033 SO11) is live now: DNS rebinding after save (blind SSRF with signed requests), rows saved before the M-3 validation were never SSRF-checked. | Optional: `SSRF.checked_target/2` + PinnedHttpClient per call (cached with the config), or update `ds` to say the residual is live. |
| 4 | LOW (pre-existing) | `media_cleanup_worker.ex:309-314` `inspect(reason)`; ExAws `{:http_error, 403, %{body: xml}}` | AWS S3 error XML bodies (`<AWSAccessKeyId>`, `<StringToSign>`) reach error values and an ERROR log; AC5 holds only against the non-echoing test stub. | Map `{:http_error, s, _}` to `{:http_error, s}` in Storage (keep 404 mapping) or log only status in callers. |
| 5 | INFO | | Logging delta clean: credentials travel as before, the new warning is a static literal, ExAws logs only the safe URL, `debug_requests` not set. | |
| 6 | INFO | `parse_endpoint/2` | Odd formats fail closed (host:port/path, IPv6 literal, blank, `:9000`, port range; DB "" wins over env so no fallback to boot host). | |
| 7 | INFO | `request_target/0` | One snapshot per call: endpoint and credentials of a call come from one ETS tuple; stale node sends old endpoint with old credentials; only mixing is #1. | |
| 8 | INFO | `runtime.exs:170-182` | Boot-abort message static, no values; raise precedes secret reads. | |
| 9 | INFO | `config_overrides/1` | Test Connection unchanged (pinned client, pinned target fails closed, 1 attempt). | |
| 10 | INFO | | No caller of `request_target/0`/`get_for_connection/0` outside storage/storage_config; OIDC scopes law untouched; hackney does not follow redirects. | |

Pattern for memory: per-field DB>env resolution becomes credential exfiltration once the DB endpoint goes live. Check (a) credential source bound to endpoint source, (b) decrypt failure fails closed on the operational path, (c) the save path applies the same `same_target?` rule as Test Connection.

---

# Cycle 1 delta review (Kassandra, 2026-10-30)

**Verdict: APPROVED (CLEAN: 0 CRITICAL, 0 HIGH, 0 MEDIUM).** 3 LOW, 8 INFO. Cycle-0 #1, #2, #4 verified fixed; #3 documented as live residual (follow-ups `ds`, 11-risks, 10-quality, 07-deployment).

| # | Severity | Location | Finding | Remediation |
|---|---|---|---|---|
| 1 | LOW (functional impact high) | `media_settings_controller.ex` `handle_storage_save` `:fresh` branch; `storage_config.ex:296` `operation_credentials/2` | Media outage after a fresh first save: the first save writes `endpoint` and `use_ssl`; when equal to the env values no keys are needed (`same_target?`), the row then has an endpoint but no keys and every operation fails with `:storage_credentials_missing` (e.g. an admin who only sets the key prefix template). Existing rows with endpoint + NULL keys fail after deploy. No credential reaches a wrong host. | Use env credentials when the row's endpoint and use_ssl are `same_target?` with the env's own endpoint/use_ssl; else fail closed. Test: `request_target/0` is `{:ok,_}` after a fresh save. Deploy note for legacy rows. |
| 2 | LOW | `storage_config.ex:1331-1349` (`resolve_candidate_secrets`), `:1051-1102` | Test Connection still pairs a saved endpoint with env credentials (old per-field fallback) when row keys are NULL/undecryptable and the form keys are blank. One pinned, SSRF-checked HEAD, env key id + signature as guessing oracle; contradicts the moduledoc claim. | Resolve stored credentials for the test through the same `operation_credentials/2` rule; error `:secret_required`/`:storage_credentials_missing`. Test: NULL row keys + env keys + blank form keys => test fun never called. |
| 3 | LOW | `storage_config.ex:405-415`, `:885` (validator uses lenient cached `row_and_env/0`) | TOCTOU: key check against a cached/stale snapshot, not the row being written; a case variant of the old endpoint without keys can overwrite the endpoint while keeping the old keys. Needs an admin plus a race or DB read fault. | Strict fresh `load_row()` in the validator, fail closed (`{:error, :storage_config_unavailable}`); better a conditional write. |
| 4 | INFO | `storage.ex:141-142` | Non-HTTP ExAws error shapes (`{type, message}` from JSON bodies) pass through unstripped (storage-server-controlled text, no secret of ours). | Catch-all clause mapping to a fixed atom. |
| 5 | INFO | `operation_credentials/2` | Row keys without a row endpoint follow the env endpoint (including after a redeploy changes it); operator controls both. | State in 07-deployment. |
| 6 | INFO | `get/0`/`mask_map`, `decrypt_secret` warnings | Admin page shows the masked env key for a row with endpoint + NULL keys (looks like saved credentials); decrypt warning still says "falling back to env-var credential". | Show "not set"; reword. |
| 7 | INFO | `parse_endpoint` | Parser clean; decimal/hex IPv4 forms pass the regex but SSRF.resolve normalizes and blocks them; `same_target?` mismatches are conservative. | |
| 8 | INFO | `do_refresh` | Keeping the last snapshot is a consistent tuple; a failed refresh after upsert leaves a node on the old target with the old credentials (orphans possible, no mixing). | |
| 9 | INFO | grep lib | IAM/STS endpoints are not called by anything; join `same_target?` if ever called. | |
| 10 | INFO | logging | Clean: static warnings/flash, no paths or ciphertext. | |
| 11 | INFO | test diffs | Adapted tests weaken nothing. Gaps: operational call after a fresh save (#1), Test Connection NULL-key case (#2). | |

Pattern for memory: a credential-binding rule must be reviewed at (a) every resolver of credentials (Test Connection kept the old per-field fallback), (b) the "nothing changed" shortcut at first save (persists an endpoint without keys => self-inflicted outage; env credentials for the env target are legitimate when targets match), (c) the save-time comparison base (strict, fresh/locked read, not a lenient cached snapshot).

---

# Cycle 2 delta review (Kassandra, 2026-10-30)

**Verdict: APPROVED (CLEAN: 0 CRITICAL, 0 HIGH, 0 MEDIUM).** 1 LOW, 2 INFO. Cycle-1 #1 (fresh-save outage: env credentials only for the env's own endpoint/use_ssl), #2 (Test Connection uses the same rule), #4, #6 fixed; #3 partly fixed (residual = LOW #1 below). No legacy row shape sends env credentials to a host other than the env's own; Test Connection is not an oracle for env credentials; logging/flash static; no new caller of `get_for_connection/0`; adapted tests not weakened.

| # | Severity | Location | Finding | Remediation |
|---|---|---|---|---|
| 1 | LOW | `media_settings_controller.ex:309-312` (+ `:268`, `:287`), `storage_config.ex:435-446`, `:387-391` | The key/endpoint binding is only as atomic as the write. (a) The controller's cache-based diff (`changed_storage_keys/1`) drops an unchanged endpoint, so a keys-only save (key rotation for endpoint A on a node whose cache still says A while the DB already holds B) writes only the key columns next to whatever endpoint is in the DB: A's keys sign requests to B. (b) The endpoint-only save without keys checks the row first, writes later (not atomic): a concurrent save can leave KB next to endpoint A. Needs two concurrent admin saves; B is admin-chosen and SSRF-checked; only key id + signatures leak. | When keys are in the save, always keep `endpoint` and `use_ssl` in `changes` (same row write). For (b) a CAS or one transaction with `SELECT ... FOR UPDATE` (residual accepted as documented race otherwise). |
| 2 | INFO | `storage_config.ex:329-331` | `env_credentials_apply?/2` short-cuts on `row endpoint == nil` without comparing use_ssl. No app path writes a row without an endpoint. | Document or require the use_ssl match. |
| 3 | INFO | `storage_config.ex:1024-1041` vs `:313-323` | Display (`get/0`) still falls back to env keys when a saved key cannot be decrypted and env applies ("Currently configured."); the operational path answers :storage_credentials_missing. Display only, fails closed. | Optionally reuse the 3-state `saved_secret` logic in `build_resolved`. |

Pattern for memory: a binding rule enforced on a diff-filtered partial upsert holds only if the bound columns go into the same row write; a controller that removes unchanged fields against a cached view turns "rotate keys" into a keys-only write. Checklist: secret columns written => target columns in the same statement; validation read and write atomic; the diff baseline must never decide which bound column is dropped.
