# Code Review — bugfix-upcloud-s3-iam-sts-endpoints (cycle 0)

**Verdict: 0 MAJOR / 0 CRITICAL. 2 MINOR. 5 INFO.** All 7 ACs met. Scope clean.

## MINOR

**MINOR-1 — Stale RED-phase comments contradict the now-GREEN implementation.**
`server/test/nebu/media/storage_config_test.exs:339` — `# This assertion currently fails (RED): the real map has neither key yet.` — false; `@defaults` now has both keys.
`server/test/nebu/media/storage_config_test.exs:845-851` — `Both tests below currently fail (RED) ... until the dev-story step adds both fields` — false, and now also miscounts: there are **three** tests under that banner (`iam-sts-AT1/AT2/AT3`). Fix: rewrite both to past tense and say "three tests".

**MINOR-2 — Empty-string leaks where the AC promises `nil`.**
`deploy/tofu/examples/upcloud/cloud-init.tftpl:490-491` emits `NEBU_MINIO_IAM_ENDPOINT: ""` unconditionally whenever `enable_media_gateway = true`. If `server.tf`'s `try(..., "")` fallback fires (no `"public"` endpoint entry, or a provider version without `iam_url`), the VM gets a **set-but-empty** var. `System.get_env/1` then returns `""`, `maybe_put_env/2` stores it, `pick(nil, "", nil)` returns `""` — so `iam_endpoint` resolves to `""`, not `nil`. No consumer exists today so nothing breaks now, but it's a trap for a future ExAws consumer (`is_nil(cfg.iam_endpoint)` would read "configured"). The template already has the right idiom at lines 476-487 (`%{ if oidc_issuer != "" ~}` guards) — apply the same pattern to the two new lines (and same for `runtime.exs:126-127`, treat `""` as unset there too). Note: mirrors `s3_endpoint`'s pre-existing behavior, so this is a consistency-preserving choice, not a regression — fix anyway since it's cheap and prevents a real future footgun.

## INFO (no action required, noted for the record)

1. Follow-up explicitly flagged per bug-context.md's own request: nothing reads `iam_endpoint`/`sts_endpoint` yet — `config :ex_aws, :s3` untouched, `Nebu.Media.Storage` never performs an STS exchange. Dead config by deliberate, pre-dev scope decision. A real UpCloud deploy needing runtime STS AssumeRole is NOT fixed by this change — out of scope, flagged for a possible follow-up story if ever confirmed necessary against a live UpCloud account.
2. Masking verified safe — `mask_map/1` only ever touches `access_key`/`secret_key`.
3. SSRF/security: `validate_candidate_endpoint/1` correctly NOT applied to the two new fields (it would reject every UpCloud `https://` URL). No new attack surface — env/Terraform-only, `upsert/1`'s `column_for/2` has no clause for either key (falls through to `nil`, silently dropped), so there's no admin-UI write path reaching these fields at all.
4. Test-review's MINOR (independent per-field resolution) was adequately addressed by `iam-sts-AT3`.
5. Moduledoc `## Interface` section not updated to mention the two env-only keys (only the inline `@defaults` comment documents them) — optional polish.

## Verified clean
AC2-AC5, AC7, AC6/scope discipline all confirmed correct (see full agent report for file:line detail) — no StackIT/AWS/k8s/Helm/docker-compose touched, all new vars optional with unchanged behavior when unset.

---

# Code Review — cycle 1 (VERIFICATION pass)

**Verdict: CLEAN.** MINOR-1 RESOLVED, MINOR-2 RESOLVED. 0 new MAJOR/MINOR. 1 new INFO.

**MINOR-1 — RESOLVED.** `storage_config_test.exs:339` now reads "This assertion now passes (GREEN): `@defaults` has both keys." The banner at 842-849 now reads "The three tests below (`iam-sts-AT1`, `iam-sts-AT2`, `iam-sts-AT3`) now pass (GREEN)" — count correct, names correct. `grep -n "RED\|currently fail"` over the file leaves only pre-existing hits (lines 3, 711-726, 783-788) belonging to stories 11a/11c, outside this diff's hunks.

**MINOR-2 — RESOLVED (both halves).**
- `cloud-init.tftpl:491-496`: both lines now wrapped in `%{ if s3_iam_endpoint != "" ~}` / `%{ endif ~}`, byte-identical idiom to the `oidc_issuer != ""` guards at 476-487. Nested inside the existing `%{ if enable_media_gateway ~}` — nesting already has heavy precedent in this file (dex block 65/108-133, alb block 174/199-279). `server.tf` locals correctly left on `try(..., "")` as instructed; `local.s3_*_endpoint` are always defined strings (ternary on `enable_media_gateway`), so the `!= ""` comparison can never hit an undefined var.
- `runtime.exs:126-135`: new `normalize_optional_env` anon fn (`nil -> nil`, `"" -> nil`, `value -> value`) applied to both new vars only. Diff is `+20 -0` — the existing `NEBU_MINIO_ENDPOINT`/`USE_SSL`/`BUCKET`/`S3_REGION`/key reads are byte-for-byte untouched.

**New INFO-6 (no action).** Residual `""` path in `StorageConfig`: `maybe_put_env/2` (storage_config.ex:1060) still passes `""` through, so a hand-set `NEBU_MINIO_IAM_ENDPOINT=""` yields `iam_endpoint: ""` from `get/0` while `runtime.exs` yields `nil` for the same var. Not reachable from the UpCloud stack any more (the tftpl guard closes it at the source) and `maybe_put_env/2` is shared pre-existing infra used by all other `NEBU_MINIO_*` reads — changing it would be a broader behavior change than this bugfix's scope. Noted, not fixed.

**Independent re-runs (not taken from the dev agent's self-report):**
- `mix test test/nebu/media/storage_config_test.exs --warnings-as-errors` → **19 passed, exit 0**. (The `:nebu_http` / `:compliance` "application not available" notices are pre-existing config-load noise, present in `config/test.exs` since before this branch; not warnings, exit code 0.)
- `tofu fmt -check -recursive deploy/tofu/examples/upcloud/` → exit 0.
- `tofu init -backend=false && tofu validate` → "Success! The configuration is valid.", exit 0.
- `git status --porcelain` → only the 6 intended files + pipeline artifacts staged; no stray working-tree edits.
