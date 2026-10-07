# Bug: UpCloud S3 driver missing IAM/STS endpoint wiring

## User report (German, verbatim)

"ich habe einen bug bei der media integration gegeben gegen einen upcloud bucket muss endpoint url, iam ural und sts url an den S3 treiber übergeben werden. nimm das sowohl in die s3 integration als auch in den upcloud stack ein, dass dies gleich direkt in die env variablen der vm übergeben werden."

Translation: against a real UpCloud Managed Object Storage bucket, the endpoint URL, IAM URL, and STS URL must all be passed to the S3 driver. Wire this into both the S3 integration (Elixir driver config) and the UpCloud deployment stack (Terraform), so the VM's env vars carry all three directly.

## Verified architecture context

- `server/lib/nebu/media/storage_config.ex` (`Nebu.Media.StorageConfig`) is the admin-DB-override-with-env-fallback config module (stories 11a/11b/11c). `default_env_reader/0` (~line 1029) currently reads `NEBU_MINIO_ENDPOINT`/`NEBU_MINIO_USE_SSL`/`NEBU_MINIO_BUCKET`/`NEBU_S3_REGION`/`NEBU_MINIO_ACCESS_KEY[_FILE]`/`NEBU_MINIO_SECRET_KEY[_FILE]`. `build_resolved/2` (~line 688) merges DB row > env var > compiled default per field into the returned map (`@defaults`, ~line 167).
- `server/config/runtime.exs` lines 84-129: the `config_env() in [:prod, :dev]` block reads the same `NEBU_MINIO_*`/`NEBU_S3_REGION` vars and sets `config :ex_aws` / `config :ex_aws, :s3` (host/port/scheme/keys/region) — this is the actual ExAws.S3 connection config `Nebu.Media.Storage` (`server/lib/nebu/media/storage.ex`) uses on every S3 call. Not loaded in `:test` env.
- `deploy/tofu/examples/upcloud/main.tf` lines 53-77 provision `upcloud_managed_object_storage` + bucket + user + a LONG-LIVED `upcloud_managed_object_storage_user_access_key`.
- `deploy/tofu/examples/upcloud/server.tf` lines 11-21: `locals.s3_endpoint` extracts `ep.domain_name` from the `"public"`-typed entry of `upcloud_managed_object_storage.nebu_media[0].endpoint`, via `try(..., "")`.
- CONFIRMED (UpCloud docs/provider schema, web research): each entry in that `endpoint` list has `domain_name`, `type`, `iam_url`, `sts_url` (e.g. `iam_url = "https://7mf5k.upcloudobjects.com:4443/iam"`, `sts_url = "https://7mf5k.upcloudobjects.com:4443/sts"`). `server.tf` currently discards `iam_url`/`sts_url`.
- `deploy/tofu/examples/upcloud/cloud-init.tftpl` lines 488-494: `enable_media_gateway` docker-compose `environment:` block injects `NEBU_MINIO_ENDPOINT`/`NEBU_MINIO_ACCESS_KEY_FILE`/`NEBU_MINIO_SECRET_KEY_FILE`/`NEBU_MINIO_BUCKET`/`NEBU_MINIO_USE_SSL`. No IAM/STS vars.
- `deploy/tofu/examples/upcloud/outputs.tf` line 57-60: `media_s3_endpoint` output mirrors `local.s3_endpoint`, `"disabled"` when `enable_media_gateway = false`.
- `Makefile` `test-iac-validate` target (line 419-427) runs `tofu validate` for `aws`, `stackit`, `k8s` — `upcloud` is NOT included (pre-existing gap).
- Scope boundary: S3 integration + UpCloud stack only. Do NOT touch StackIT/AWS/k8s deployment paths.
- Explicitly OUT of scope: whether `Nebu.Media.Storage`'s ExAws calls must actively perform a runtime STS AssumeRole exchange against `sts_url`. No live UpCloud account available to verify. Scoped to plumbing the three URLs through as config end-to-end (Terraform → VM env vars → runtime.exs → StorageConfig) — literal reading of "muss... an den S3 treiber übergeben werden" (must be PASSED to the driver, not necessarily actively called by it). Flag loudly as follow-up if evidence of a required runtime STS exchange turns up; don't silently expand scope.

## Acceptance Criteria

**AC1** (ExUnit-testable — RED-phase target, ATDD complete): `Nebu.Media.StorageConfig`'s resolved config map (`get/0`, `get_for_connection/0`) gains `iam_endpoint`/`sts_endpoint` keys, `nil` by default, resolved from `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` via the same env-var-fallback machinery as `endpoint` — but as full URLs (no scheme-stripping / no `validate_candidate_endpoint/1` reuse, unlike `endpoint`'s bare `host[:port]` contract). No DB-admin override column. Not secrets — never masked.

**AC2** (config wiring, not ExUnit-testable — runtime.exs never loads under `:test`): `server/config/runtime.exs` S3 block reads the two new env vars, exposes `Application.get_env(:nebu_http, :media_iam_endpoint)`/`:media_sts_endpoint` (`nil` when unset).

**AC3-AC5** (Terraform, not ExUnit-testable): `server.tf` locals `s3_iam_endpoint`/`s3_sts_endpoint` (same `try(..., "")` pattern as `s3_endpoint`, reading `ep.iam_url`/`ep.sts_url`); `cloud-init.tftpl` injects `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` env lines; `outputs.tf` gains `media_s3_iam_endpoint`/`media_s3_sts_endpoint` outputs mirroring `media_s3_endpoint`.

**AC6** (regression guard): all existing Elixir unit tests stay green; no new env var required anywhere (StackIT/AWS/k8s/dev-MinIO unaffected when unset).

**AC7** (optional, scope-permitting): add `deploy/tofu/examples/upcloud` to the Makefile's `test-iac-validate` target, mirroring `aws`/`stackit`/`k8s`. Only if it validates cleanly without unrelated fixes — otherwise leave a one-line follow-up note.

## ATDD result (Step 2, complete)

Extended `server/test/nebu/media/storage_config_test.exs`:
1. Moduledoc: added `## bugfix-upcloud-s3-iam-sts-endpoints (AC1)` section.
2. `AT1` (exact-equality default-shape assertion) updated to include `iam_endpoint: nil, sts_endpoint: nil`.
3. New `describe "bugfix-upcloud-s3-iam-sts-endpoints: AC1 iam/sts endpoint keys"`:
   - `iam-sts-AT1`: both `get/0`/`get_for_connection/0` default to `nil` when unset.
   - `iam-sts-AT2`: both resolve from `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` via the `:media_storage_env_reader` seam, verbatim, unmasked.

Confirmed RED: `mix test test/nebu/media/storage_config_test.exs` → 15/18 passed, 3 failed exactly as expected (`iam-sts-AT1`, `iam-sts-AT2`, updated `AT1` — all `KeyError, key :iam_endpoint not found` / map-equality mismatch). No regression in the other 15 pre-existing tests in that file.

Dev-story scope:
- AC1: `server/lib/nebu/media/storage_config.ex` — add `iam_endpoint: nil, sts_endpoint: nil` to `@defaults` (~167), extend `build_resolved/2` (~688) to resolve from env with no DB lookup and no `validate_candidate_endpoint/1` call, add both keys to `default_env_reader/0` (~1029) via `maybe_put_env/2`.
- AC2: `runtime.exs` S3 block — code review verified, no ExUnit.
- AC3-AC5: Terraform files — code review + manual `tofu validate`, no ExUnit.
- AC7: optional Makefile addition.
