## Session — bugfix-upcloud-s3-iam-sts-endpoints (SEC Gate 1)

**Scope:** staged diff on `bugfix/upcloud-s3-iam-sts-endpoints`. Two new optional config fields
`iam_endpoint`/`sts_endpoint` on `Nebu.Media.StorageConfig` (env-only, from
`NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT`), exposed via `runtime.exs`
(`:nebu_http, :media_iam_endpoint`/`:media_sts_endpoint`), threaded through
`deploy/tofu/examples/upcloud/` (server.tf locals ← provider `endpoint[].iam_url`/`sts_url` →
cloud-init.tftpl VM env → outputs.tf), plus `Makefile test-iac-validate` extended to the upcloud
example. Report: `docs/stories/security-reports/bugfix-upcloud-s3-iam-sts-endpoints-security-review-2026-10-01.md`

**Finding summary:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW. Verdict APPROVED / CLEAN.
- F-1 LOW: the two new URL fields get neither the scheme assertion nor `SSRF.checked_target/1`
  that `endpoint` gets, AND the upcloud stack's hardcoded `NEBU_MINIO_USE_SSL: "true"` fence does
  not cover them (their scheme lives inside the value). No consumer today ⇒ watch-flag.
- F-2 LOW: `runtime.exs` normalizes `"" -> nil`; `StorageConfig.maybe_put_env/2` does not ⇒ the two
  readers of the same env var disagree on `""`. Latent fail-open for the future consumer.

**Directed question answered (SSRF reasoning audit):** the code review's conclusion HOLDS, its stated
reason does not. "`validate_candidate_endpoint/1` would reject every UpCloud `https://` URL" is true
of the *wrapper only* — `Nebu.Media.SSRF.checked_target/1` natively takes full `http(s)://` URLs and
would validate them fine. The argument that actually carries it is the trust boundary, verified in
three legs: (1) no DB/admin writer exists structurally — `column_for/2`'s catch-all (`:559`) silently
drops the keys, `media_settings_controller.validate_storage_params/1` builds a closed key set;
(2) `build_resolved/2:696` already resolves `endpoint` from env with NO validation — the module's
deliberate contract is *DB-sourced values are SSRF-validated, env-sourced ones are not*, and the new
fields land wholly on the already-trusted side; (3) zero consumers — no request to redirect.

**New patterns discovered:** see MEMORY.md row added this session ("Trusted-env-only config field is
genuinely exempt from the SSRF guard — but the exemption expires at the first consumer, and a
value-internal scheme escapes the `USE_SSL` fence").

**Accepted risks this session:** none.

**Follow-up:**
- MUST-VERIFY at the anticipated STS-AssumeRole follow-up story's SEC gate: assert `https://` on both
  values, run `SSRF.checked_target/1` on both, reconcile the `""`/`nil` divergence, and confirm the
  STS creds actually REPLACE (not supplement) the long-lived
  `upcloud_managed_object_storage_user_access_key`.
- O-5 pre-existing (NOT this diff): `upcloud_managed_object_storage_bucket.nebu_media` (main.tf:60-64)
  has no `prevent_destroy` — MEMORY #55 verbatim, same gap flagged MEDIUM-1 against the Stackit bucket
  on 2026-05-26, now confirmed in the UpCloud example too. Fold into the same follow-up as the STS work.
- O-2: the stack provisions long-lived static S3 keys; the new outputs' descriptions can read as if STS
  short-lived creds are in play. Recommend the output descriptions say "not currently consumed".

**Verified clean (so a later session need not redo it):** no secret enters the new paths (Docker-secret
file refs untouched); `mask_map/1` correctly untouched (two-field rewrite, these are not secrets);
no `Logger`/`inspect` of the resolved config; `Nebu.Media.Storage` never calls `get_for_connection/0`
so the new keys never reach the ExAws option set; cloud-init `%{ if ... ~}` guards are the byte-identical
`oidc_issuer != ""` idiom at column 0 with always-defined string vars; stackit's cloud-init.tftpl is a
separate file (no cross-example `templatefile` breakage); `.terraform.lock.hcl` for upcloud is
git-tracked and pins `upcloudltd/upcloud 5.39.1` with h1+zh hashes, so the new `tofu init` adds no
unpinned provider fetch.
