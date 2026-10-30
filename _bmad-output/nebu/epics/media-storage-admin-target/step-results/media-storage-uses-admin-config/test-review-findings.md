# Test review (pre-dev): media-storage-uses-admin-config

Reviewer: nebu-test-reviewer (read-only). Verdict: **no MAJOR findings**. All 7 scenarios covered (S1 4, S2 5, S3 12+2, S4 6, S5 4, S6 10, S7 4). Real 127.0.0.1 stub plus a decoy at the boot-time endpoint kills wrong-fallback implementations. Mutation log accepted (M12 equivalent).

## MINOR
1. 404 mapping untested: get/get_from_archive -> {:error, :not_found}, delete -> :ok on 404 (ADR-032 idempotency). Stub supports `start_stub(status: 404)`; add one test per operation.
2. Supervised StorageConfig stopped in setup (support:78-86, :107-117) and never restarted (child is restart: :transient, stop :normal leaves it down for later sync modules). Restart in on_exit via Supervisor.restart_child, or do not stop it.
3. `:http_client` pin excludes an operational pinned-client implementation (S2 :146/:225, blank_endpoint:71 would pass vacuously). Note only; keep, document in the report.
4. runtime.exs evaluation leaks non-NEBU env (CLUSTER_STRATEGY, KUBERNETES_NAMESPACE/SELECTOR/SERVICE_NAME, runtime.exs:390-415): clear/pin them in the S6/S7 setup.
5. S6 over-pins whitespace-only endpoint as blank; add the rule to the story (accepted extension).
6. Error statuses only covered for the blank-endpoint upload (500 M_UNKNOWN). Add: non-blank failing storage (403) upload 500; async PUT upload path; download with `{:error, :storage_endpoint_blank}` (or any storage error) answers cleanly, no crash.
7. Partial saved row: per-field fallback to env only tested for archive bucket. Add row with only endpoint+credentials, bucket/region from env; credentials from NEBU_MINIO_*_FILE through Storage.
8. admin_target_test.exs:227/:233 `row(%{port: 0}, %{endpoint: ...})` hack; use an explicit builder; add https with explicit port.

## INFO
1. `GenServer.call(StorageConfig, :refresh)` pins a private message (stand-in for upsert, SSRF guard blocks 127.0.0.1). Accepted.
2. Negative assertions use 50/100 ms windows; deterministic for the synchronous design.
3. Stub is not flaky (ephemeral port, close after response).
4. A per-call write of the saved target into :ex_aws app env instead of per-request overrides cannot be detected by black-box tests (unsafe under concurrency); code review must check.
5. S5 stub never echoes credentials; credential-scope assertion proves the canaries were in use; Nebu.Media log lines on upload failure not driven through the router.
6. Implicit pins fine (archive_bucket/0 must not raise on blank endpoint; key = media_id; put_object_copy source bucket = primary effective bucket).
7. `put_os_env_scoped/2` unused helper.
8. No crash/restart test required (Storage stateless; StorageConfig crash covered by storage_config_test AT13).
9. ex_aws warning on refused connection logs only the safe URL.
